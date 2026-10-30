import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'ad_filter_service.dart';
import 'local_m3u8_proxy.dart';
import 'm3u8_ad_filter.dart';
import 'm3u8_utils.dart';
import 'user_data_service.dart';
import '../platform/device_utils.dart';
import '../player/player_backend_factory.dart';
import '../utils/windows_logger.dart';

class AdFilterEngine {
  static LocalM3u8Proxy? _proxy;

  // 🔴🔴🔴 2026-10-26（第二十轮）：**M3U8 下载短时缓存**。
  //
  // 【真机实锤】hilog 2026-10-26 11:25:57（鸿蒙 TV 真机，第23集 46:03）：
  //   11:25:57.005 [SEEK-REBUILD] 目标=1040574ms 落在裁剪落点之前 ⇒ 重建播放器
  //   11:25:57.0xx [AdFilterEngine] 开始下载 M3U8: https://vv.jisuzyv.com/.../index.m3u8
  //   11:26:00.0xx [AdFilterEngine] M3U8 下载完成 status=200 length=49807   ← ★ 白等 3.0 秒
  //   11:26:02.2xx 起播耗时[首帧送显] 总计=1298ms
  //   ⇒ 「快退到裁剪落点之前 ⇒ 重建播放器」这条自愈路径的总代价 **5.2 秒**，
  //     其中 **3.0 秒纯粹浪费在重新下载同一份 master M3U8 上**。
  //
  // 【为什么可以复用】① 同一 URL 的 VOD master playlist 内容不变；
  //   ② 代理层早已做了「master 内容未变，复用展开缓存与分片缓存」，
  //      唯独 AdFilterEngine 这一层的**下载**没被复用（重复劳动）；
  //   ③ 重建 / 重进播放页 / 切回同一源，URL 完全相同 ⇒ 命中。
  //
  // 【安全边界】· 只缓存**原始下载文本**（过滤前的 effectiveContent），
  //   过滤结果一律重算 ⇒ 不会因「去广告开关 / 实际后端」变化而拿到错内容；
  //   · key = 完整 fetchUrl（含 M3U8 代理前缀）⇒ 换源 / 换代理自动不命中；
  //   · TTL 60 秒：重建是秒级行为，60 秒足够覆盖；VOD 内容在此窗口内不会变；
  //   · **直播不走这条路径**（filterM3u8 只在播放页对点播源调用，
  //     直播走 live_service）⇒ 不存在直播窗口过期问题；
  //   · 只保留 1 条（几十 KB）⇒ 不会涨内存。
  static String? _m3u8CacheKey;
  static String? _m3u8CacheText;
  static DateTime? _m3u8CacheAt;
  static const Duration _kM3u8CacheTtl = Duration(seconds: 60);

  static Future<String?> filterM3u8({
    required String sourceType,
    required String originalUrl,
    Map<String, String> headers = const {},
    PlayerBackendType? playerBackend,
  }) async {
    final enabled = await AdFilterService.isEnabled();
    final isComputer = DeviceUtils.isComputer;
    // 去广告后残留的孤立 EXT-X-DISCONTINUITY 会让 fvp/libmpv 重置时间轴、从头重播，
    // 仅 fvp 后端需要清理；ExoPlayer(安卓/TV 默认) 依赖 discontinuity 避免
    // UnexpectedDiscontinuityException，必须保留。按"实际生效的后端"判定，而非仅 Windows。
    //
    // 🔴🔴🔴 2026-10-24 关键修正：**必须用「实际用于本次播放的后端」，不能只读全局设置**。
    //
    // 【真机实锤（hilog 2026-10-24 08:21，鸿蒙 TV 真机）】
    //   16:17:59.465 [AdFilterEngine] PTS 归一化后端门控=true（后端=PlayerBackendType.mpv
    //   16:17:59.489 [AvPlayerBackend] open url=http://127.0.0.1:43747/playlist.m3u8
    //   16:17:59.489 MobilePlayerScreen 尝试播放 [PlayerBackendType.avplayer]
    //
    //   即：门控按**全局设置**（mpv）判定 ⇒ 给 avplayer 也开了 PTS 归一化，
    //   而实际播放的是 **avplayer**（按视频/按源设置的后端，与全局不同）。
    //
    // 【后果 —— avplayer 死锁 34 秒，实锤】
    //   · avplayer 收到的是「PTS 整体前移 25.28 秒」的字节；
    //   · 16:18:49 position 冻结在 1154033ms、**buffered 同时不涨**，
    //     16:18:49~16:19:23 连续 20 次 `AVP_DECODE_STALL`（position 卡在 1154033ms）；
    //   · 同期代理侧日志显示播放器在 16:18:49 / 16:18:53 **反复重拉同一批 17 个分片**
    //     （`Prefetch: 缓存命中(整段)` 各 17 次）⇒ 典型的「拿到数据但不认、反复重试」；
    //   · 16:18:49 之后代理**再未吐出任何分片**（整整 34 秒）⇒ 播放器彻底停摆。
    //
    // 【为什么只有 avplayer 会死锁，mpv 不会】
    //   · mpv（ffmpeg）有 `demuxer-ts-offset` **一次性整文件校准**机制 ⇒ 能吸收 25 秒绝对偏移；
    //   · AVFoundation 是**逐分片**对齐「EXTINF 累加轴」的：分片 PTS 与它算出的期望区间
    //     偏差过大时，会把该分片判为时间戳异常并**等待/重试**，buffered 不前进 ⇒ 死锁。
    //
    // 【对照验证（同一台真机，三份日志）】
    //   12:47 门控=avplayer ⇒ 不归一化 ⇒ avplayer 拿原始字节 ⇒ **零死锁**（仅首字节延迟型卡顿）
    //   07:52 门控=mpv     ⇒ 归一化 + **整段缓冲** ⇒ avplayer 零死锁（整段一次写完，AVFoundation 能接受）
    //   08:21 门控=mpv     ⇒ 归一化 + **流式改写** ⇒ avplayer **死锁 34 秒** ← 本次故障
    //
    // 【修法】调用方（播放页）把「本次实际使用的后端」传进来，门控按它判定：
    //   · avplayer ⇒ **既不做 PTS 归一化、也不做代理解密**（它自带解密器，且 position
    //     由源自身时间轴驱动）⇒ 代理对它是**纯流式透传**，字节零改写 ⇒ 不可能死锁，
    //     且首字节延迟最低；
    //   · mpv / fvp ⇒ 保持现状（代理解密 + PTS 归一化 + 流式平移）。
    //
    // 【avplayer 的进度条会偏吗？——不会（12:47 那份日志已验证）】
    //   12:47 门控=avplayer 时，avplayer 的 position 落在**源自身时间轴**上，
    //   进度条显示的正是「源的真实时间」，用户当时未报 avplayer 进度条偏移。
    final selBackend = await UserDataService.getPlayerBackend();
    final fallbackBackend =
        PlayerBackendFactory.availableBackends.contains(selBackend)
            ? selBackend
            : PlayerBackendFactory.platformDefault;
    final effectiveBackend = playerBackend != null &&
            PlayerBackendFactory.availableBackends.contains(playerBackend)
        ? playerBackend
        : fallbackBackend;
    final useFvp = effectiveBackend == PlayerBackendType.fvp;
    // 🔴🔴 2026-10-24：mpv 后端同样需要「代理解密 + PTS 归一化」。
    //
    // 【为什么 mpv 也要代理解密】加密源的分片是**密文**，代理不先解密就
    //   **读不出 PTS** ⇒ 算不出 delta ⇒ 无法做 PTS 归一化 ⇒
    //   分片真实 PTS（含广告时间线）与播放列表 EXTINF 累加（去广告时间线）
    //   两条轴不同源 ⇒ **进度条必然偏移**（用户 2026-10-24 实报）。
    //   原实现把「代理解密」绑死在 fvp 的 `renumberSegments` 上，
    //   而鸿蒙的 mpv 后端两者都不开 ⇒ 加密源永远走不到归一化。
    //   详见 `LocalM3u8Proxy._decryptAes` 的完整推导。
    final useMpv = effectiveBackend == PlayerBackendType.mpv;
    // 需要**代理侧**做 AES-128 解密的后端：
    //   · fvp —— 绕开 libmdk 解密卡死
    //   · mpv —— 为了能在**明文**上读出 PTS 并做归一化
    // avplayer 自带解密器，且它的 position 直接由 EXTINF 累加驱动，
    // 不需要（也不该）做 PTS 归一化 ⇒ 不走这条。
    final useProxyDecrypt = useFvp || useMpv;
    WindowsLogger.log(
      'AdFilterEngine',
      '去广告开关=$enabled, 电脑版=$isComputer, 后端=$effectiveBackend, 清理断点=$useFvp',
    );

    // fvp 在 Windows/Linux/鸿蒙 直连 CDN 会因 TLS/DNS 握手失败导致起播慢/失败，
    // 故即便关闭去广告，也强制走本地代理透传（复用 App 的 Dart HTTP 客户端拉流）；
    // 其余平台/后端保持历史行为：去广告关闭时直接播放原始 URL。
    // Android fvp 不强制走代理：去广告开启时仍走代理（去广告过滤），关闭时直连 CDN
    // （2026-09-24 曾试把 Android 也并入强制代理以掩盖 libmdk reader 死寂期，
    // 实测对含大量 discontinuity 的 CDN 点播源无效，故回退到直连）。
    final needProxyPassthrough =
        useFvp && (isComputer || Platform.operatingSystem == 'ohos');

    final lowerUrl = originalUrl.toLowerCase();
    var isM3u8 =
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('/hls/') ||
        lowerUrl.contains('application/vnd.apple.mpegurl') ||
        lowerUrl.contains('audio/x-mpegurl');
    // 透传平台（fvp/Windows/Linux/鸿蒙）即便 URL 没有 .m3u8 后缀（如 catchup
    // 回放地址 ?playbackbegin=...）也可能返回 M3U8/TS 流，需要下载后按内容判定，
    // 不能仅凭后缀就跳过；其余平台保持历史行为：不像 M3U8 直接跳过。
    // 🔴🔴 2026-10-23：**HTML 播放器页入口**也不能跳过。
    //
    // 实测（Windows 真机，jinyingzy.com 源）：
    //   播放地址 `https://hd.kuktxu.com/play/eXD5yD8e` 无 .m3u8 后缀，
    //   服务器返回 1593 字节的 HTML（content-type: text/html），
    //   页面内用 hls.js 播放 `.../eXD5yD8e/index.m3u8`。
    //
    // 旧逻辑在这里直接 return null → 播放器**直连 HTML**：
    //   mpv 把 HTML 当媒体打开 → **画面卡住、总时长读不出来**。
    //
    // 现在改为：像直链媒体文件（.mp4/.ts/…）的 URL 才直接跳过；
    // 其余（无后缀/未知后缀）先限量嗅探内容，确认是 HTML 就把内嵌的
    // m3u8 取出来继续走代理流程。
    final skipByExtension = M3u8Utils.looksLikeDirectMediaUrl(originalUrl);
    if (!isM3u8 && !needProxyPassthrough && skipByExtension) {
      WindowsLogger.log('AdFilterEngine', ' 直链媒体地址，跳过');
      return null;
    }

    // 去广告关闭时：非透传平台（安卓/TV 等直连正常的后端）直接播放原始 URL，
    // 恢复历史行为；fvp 在 Windows/Linux/鸿蒙直连 CDN 会 TLS/DNS 握手失败，
    // 即使关闭去广告也强制走本地代理透传（复用 App 的 Dart HTTP 客户端拉流），
    // 仅不做去广告过滤。
    if (!enabled && !needProxyPassthrough) {
      WindowsLogger.log('AdFilterEngine', ' 去广告已关闭，直接播放原始 URL');
      return null;
    }

    // 构造下载请求头（去广告开启时用于解析 master playlist 选择最高清晰度变体）。
    final originUri = Uri.parse(originalUrl);
    final origin = '${originUri.scheme}://${originUri.host}';
    final requestHeaders = Map<String, String>.from(headers);
    requestHeaders.putIfAbsent('Origin', () => origin);
    requestHeaders.putIfAbsent('Referer', () => '$origin/');
    requestHeaders.putIfAbsent('Accept', () => '*/*');
    requestHeaders.putIfAbsent(
      'User-Agent',
      () =>
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
          ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
    );

    try {
      String fetchUrl = originalUrl;
      final proxyUrl = await UserDataService.getM3u8ProxyUrl();
      if (proxyUrl.isNotEmpty) {
        fetchUrl = '$proxyUrl${Uri.encodeComponent(originalUrl)}';
        WindowsLogger.log('AdFilterEngine', ' 使用 M3U8 代理下载: $fetchUrl');
      }

      var effectiveUrl = originalUrl;
      var effectiveContent = '';

      if (isM3u8) {
        // 🔴 2026-10-26（第二十轮）：**先查短时缓存**，命中则省掉整段下载。
        //
        //   重建播放器（快退到裁剪落点之前的自愈路径）时 URL 完全相同，
        //   重新下载一次 master M3U8 要 3 秒（真机 11:25:57→11:26:00 实测），
        //   而这份内容在 60 秒内不会变 ⇒ 直接复用。
        final cacheKey = fetchUrl;
        final cachedText = _m3u8CacheText;
        final cachedAt = _m3u8CacheAt;
        final now = DateTime.now();
        if (cachedText != null &&
            cachedAt != null &&
            _m3u8CacheKey == cacheKey &&
            now.difference(cachedAt) < _kM3u8CacheTtl) {
          effectiveContent = cachedText;
          WindowsLogger.log(
            'AdFilterEngine',
            ' M3U8 命中短时缓存（省一次下载，'
            'age=${now.difference(cachedAt).inMilliseconds}ms，'
            'length=${effectiveContent.length}）',
          );
        } else {
          // URL 已带 .m3u8 特征 → 直接完整下载（M3U8 文本很小）。
          WindowsLogger.log(
            'AdFilterEngine',
            ' 开始下载 M3U8: $fetchUrl (去广告=$enabled)',
          );
          final response = await http
              .get(Uri.parse(fetchUrl), headers: requestHeaders)
              .timeout(const Duration(seconds: 15));
          WindowsLogger.log(
            'AdFilterEngine',
            ' M3U8 下载完成 status=${response.statusCode} length=${response.bodyBytes.length}',
          );
          if (response.statusCode != 200) {
            WindowsLogger.log('AdFilterEngine', ' 下载 M3U8 失败 ${response.statusCode}');
            return null;
          }
          effectiveContent = utf8.decode(response.bodyBytes, allowMalformed: true);
          // 🔴 2026-10-26（第二十轮）：写入短时缓存（仅原始文本，过滤结果不缓存）。
          _m3u8CacheKey = cacheKey;
          _m3u8CacheText = effectiveContent;
          _m3u8CacheAt = DateTime.now();
        }
      } else {
        // 🔴🔴 2026-10-23：**限量嗅探**（最多 64KB），不整份下载。
        //
        // 为什么要限量：URL 不带 .m3u8 后缀时，可能是
        //   (a) HTML 播放器页 → 里面藏着真正的 m3u8；
        //   (b) 直链媒体（mp4/flv…）→ 整份下载可能几百 MB，绝不能这么干。
        // 所以先只读 64KB 判断内容类型，再决定下一步。
        WindowsLogger.log(
          'AdFilterEngine',
          ' 开始嗅探内容: $fetchUrl (去广告=$enabled)',
        );
        final head = await _fetchHeadBytes(
          fetchUrl,
          requestHeaders,
          64 * 1024,
        );
        if (head == null) {
          WindowsLogger.log('AdFilterEngine', ' 嗅探失败，跳过代理');
          return null;
        }
        if (!M3u8Utils.looksLikeM3u8Content(head.text)) {
          // 🔴🔴 2026-10-23：HTML 播放器页 → 取出内嵌的真正 m3u8。
          //
          // 实测（jinyingzy.com）：`https://hd.kuktxu.com/play/eXD5yD8e` 返回
          // 1593 字节的 HTML 播放器页，真正的 m3u8 是页面里 hls.js 用的
          // `https://hd.kuktxu.com/play/eXD5yD8e/index.m3u8`。
          //
          // 不处理的话：mpv 直连 HTML → 画面卡住、总时长读不出来。
          final embedded = M3u8Utils.extractM3u8FromHtml(
            head.text,
            baseUrl: originalUrl,
          );
          if (embedded == null) {
            WindowsLogger.log(
              'AdFilterEngine',
              ' 内容不是 M3U8 且未内嵌 m3u8，跳过代理（按原 URL 直连）',
            );
            return null;
          }
          WindowsLogger.log('AdFilterEngine', ' HTML 播放器页 → 内嵌 m3u8: $embedded');
          effectiveUrl = embedded;
          final m3u8Response = await http
              .get(Uri.parse(embedded), headers: requestHeaders)
              .timeout(const Duration(seconds: 15));
          if (m3u8Response.statusCode != 200) {
            WindowsLogger.log(
              'AdFilterEngine',
              ' 内嵌 m3u8 下载失败 ${m3u8Response.statusCode}',
            );
            return null;
          }
          effectiveContent = utf8.decode(
            m3u8Response.bodyBytes,
            allowMalformed: true,
          );
        } else {
          // 内容确实是 M3U8（URL 无后缀的 catchup 回放地址常见）
          WindowsLogger.log('AdFilterEngine', ' 内容判定为 M3U8（URL 无后缀）');
          if (head.complete) {
            // 嗅探时已把整个 playlist 读完了，直接用，不用再下一次。
            effectiveContent = head.text;
          } else {
            final response = await http
                .get(Uri.parse(fetchUrl), headers: requestHeaders)
                .timeout(const Duration(seconds: 15));
            if (response.statusCode != 200) {
              WindowsLogger.log(
                'AdFilterEngine',
                ' M3U8 下载失败 ${response.statusCode}',
              );
              return null;
            }
            effectiveContent = utf8.decode(
              response.bodyBytes,
              allowMalformed: true,
            );
          }
        }
      }

      if (effectiveContent.isEmpty) {
        WindowsLogger.log('AdFilterEngine', ' M3U8 内容为空');
        return null;
      }
      if (!M3u8Utils.looksLikeM3u8Content(effectiveContent)) {
        WindowsLogger.log('AdFilterEngine', ' 最终内容仍不是 M3U8，跳过代理');
        return null;
      }
      WindowsLogger.log(
        'AdFilterEngine',
        ' M3U8 内容摘要: ${_summarizeContent(effectiveContent)}',
      );

      // ⚠️ 不要在这里把播放 URL 强制替换成「最高清晰度变体」。
      //
      // 本批改动曾在此处用 M3u8Utils.pickBestVariantUri 把 effectiveUrl/effectiveContent
      // 整体换成最高码率子 playlist，再交给本地代理播放。实测后果：该路 Media playlist
      // （2814 行 / 1398 分片）经 m3u8_ad_filter 的 _removeMinorityUrl 被误判「少数派 URL」，
      // 删掉 86 个正片分片 → 时间轴断裂 → fvp/libmdk 卡死无法播放（ExoPlayer 容错更强仍可播）。
      //
      // 1.3.5（发布版，融合代码）此处保持原始 master URL 交给播放器，由播放器 ABR 自行选流；
      // 「分辨率识别」能力由 M3u8Utils.analyzeM3u8ForSpeedTest / pickBestVariantUri 在
      // **测速与展示**路径提供，与本处播放路径解耦，因此移除强制替换不影响分辨率显示。
      //
      // 若将来确需固定清晰度，必须同时保证：被指定的子 playlist 不经过 _removeMinorityUrl，
      // 或该过滤器对同源分片名不再产生「少数派」误判。

      // 过滤的输入与代理的播放地址都保持原始 master，与 1.3.5 行为一致。
      String content = effectiveContent;
      final filterBaseUrl = effectiveUrl;
      // 实际裁掉的广告片段数 —— 决定**是否需要**做 PTS 归一化。
      // 没裁掉广告 ⇒ 时间轴与原始源逐字节一致 ⇒ 无东西可补偿，
      // 而强行平移反而会把两条轴之间的取整差异放大成「进度条突然往前跳」。
      var removedAdCount = 0;
      // 仅去广告开启时过滤广告片段；透传（去广告关闭）直接转发原始内容，
      // 避免误删点播/回放流中的正常片段。
      if (enabled) {
        final filter = M3u8AdFilter();
        final filteredContent = filter.purify(
          filterBaseUrl,
          content,
          // 按「实际生效的后端」判定：孤立 discontinuity 只对 fvp/libmpv 有害，
          // ExoPlayer 反而依赖它。此前误用 isWindows，会让 Linux 的 fvp 不去清理。
          cleanDiscontinuities: useFvp,
        );
        if (filteredContent != null && filteredContent != content) {
          content = filteredContent;
          removedAdCount = filter.currentAdCount;
          WindowsLogger.log('AdFilterEngine', ' 已过滤 $removedAdCount 个片段');
        } else {
          WindowsLogger.log('AdFilterEngine', ' 无需过滤或过滤失败');
        }
      }

      _proxy ??= LocalM3u8Proxy();
      // 🔴 2026-10-24 第七轮：登记全局实例，供播放后端把 seek 目标位置
      //   告诉代理（预热目标区域的分片，避免 seek 落点现等 CDN）。
      LocalM3u8Proxy.currentInstance = _proxy;
      // 子 M3U8 过滤状态与去广告开关保持一致；
      // Windows 非去广告场景直接播放原始 URL，不再经过本地代理。
      _proxy!.setFilterEnabled(enabled);
      // fvp/libmpv 需清理去广告后残留的孤立 discontinuity，避免重新播放；
      // ExoPlayer 必须保留 discontinuity，故仅 fvp 后端开启。
      if (useFvp) _proxy!.setDiscontinuityCleanup(true);
      // 🔴🔴 2026-10-24（HeinPlay 本地 fork）：**avplayer 专属**的快起播模式。
      //
      // 【真机对照（hilog 2026-10-24 20:34~20:36，同源同代理）】
      //   · mpv：open → 出画面 **2.0s**（`--start` 走 ffmpeg 输入侧跳读）
      //   · avp：open → 出画面 **11.5s**，另两次 **15s 超时**判「播放失败」
      //
      // 【avp 慢在哪（已拆解到具体项）】
      //   ① 代理把 16 段落点窗口 + 8 段建索引段插队首（队列 24 段 / worker 4 路）
      //      ⇒ 落点段排在第 9~24 位，且 AVPlayer 自己也��打 CDN
      //      ⇒ 上游掐断连接（日志 `sent=32768`）⇒ 索引建不起来 ⇒ 超时。
      //   ② 原生侧「等 PLAYING(2s 兜底) + 等 SEEK_DONE + 等首帧(1.5s 兜底)」
      //      三层兜底叠加，白白多花 3.5s。
      //
      // 【本开关的职责】只收窄代理的预取参数（落点窗口 16→2、建索引段 8→4、
      //   关闭投机插队），让 AVPlayer 与代理**同时**开跑、不互相排队。
      //
      // 🔴🔴🔴 2026-10-26（第十八轮）：**必须无条件下发 true/false**，
      //   不能只在 avplayer 分支里置 true。
      //
      // 【真机实锤】hilog 2026-10-26 08:03:06~08:03:08（鸿蒙 TV 真机，第23集 46:03）：
      //   08:03:06.549  MpvBackend 进度 position=0ms
      //   08:03:08.081  MobilePlayerScreen 尝试播放 [PlayerBackendType.mpv]:
      //                  http://127.0.0.1:43035/playlist.m3u8 startAt=1418.722s
      //   08:03:08.131  [LocalM3u8Proxy] Proxy: 起播裁剪 ⇒ 列表第 0 片 = 原第 302 片，
      //                  offset=1416224ms（**mpv 会话也拿到了被裁的列表！**）
      //   08:03:08.4xx  MpvBackend 进度 duration=1346917ms
      //   ⇒ mpv 读到的总时长 = 2763138 - 1416224 = 1346914ms（22:27 / 46:03 = 48.8%）
      //     ⇒ 用户看到的「mpv 总时长只有一半」。
      //
      // 【为什么没复位】① 本开关**只在 avplayer 分支里置 true，从不复位**；
      //   ② 切后端时 `AdFilterEngine.dispose()` 不会被调用（只在退出播放页/销毁时调），
      //   `_proxy ??= LocalM3u8Proxy()` 会**复用同一个代理实例**，
      //   于是 avp 会话打开的「起播裁剪」状态原样带进了 mpv 会话。
      //   ③ 「默认就用 mpv、从详情页直接进」时本开关从未打开 ⇒ 时长正常，
      //   正好反证污染源在 avp 侧。
      //
      // 【修法】按「本次播放实际用的后端」**总是**下发；
      //   置 false 时由 setAvPlayerFastStart 内部一并作废裁剪状态。
      _proxy!.setAvPlayerFastStart(effectiveBackend == PlayerBackendType.avplayer);
      // fvp 专属：分段全局重编号 + 结构性 discontinuity 丢弃，规避 libmdk
      // 跨断点复用同名分片（如 plist0.ts）命中段缓存、停止续预取而卡死。
      _proxy!.setFvpRenumber(useFvp);
      // 🔴🔴 2026-10-24：代理解密（fvp 绕 libmdk 卡死；mpv 为了在明文上归一化 PTS）。
      _proxy!.setDecryptAes(useProxyDecrypt);
      // 🔴🔴 2026-10-24：PTS 归一化（进度条偏移根治）——**按后端门控**。
      //
      //   · mpv：`time-pos` 走分片里的真实 PTS，`duration` 走 EXTINF 累加，
      //     去广告删了列表行、没改分片字节 ⇒ 两条轴不同源 ⇒ **必须**归一化。
      //   · avplayer：position 直接由 EXTINF 累加驱动，**不读**分片 PTS ⇒
      //     本就不需要归一化；且一旦归一化，每个分片都要付「整段缓冲 + 解析
      //     + 改写」的主 isolate 代价（= 用户所报「avp 也时不时卡一下」）。
      //   与主工程 `hain_tv` 的 `needPtsNormalize = effective && removedAdCount > 0`
      //   同语义：只有真裁掉了广告才需要补偿。
      // 🔴🔴 2026-10-24 第二次修正：这里**只给后端门控**，不再用
      //   `removedAdCount > 0` 决定是否**施加**平移。
      //
      //   【为什么必须改 —— 真机实锤（2026-10-24 15:03 本片）】
      //     `removedAdCount` 统计的是**顶层**播放列表上被 `M3u8AdFilter` 删掉的
      //     段数；本片源是 master→media 两级，广告段在**子 media 列表**里 ⇒
      //     顶层统计恒为 0 ⇒ `useMpv && removedAdCount > 0` 恒为 false ⇒
      //     PTS 平移自始至终**一次都没执行**（日志：`裁掉广告=0 段`、
      //     `归一化开关=false`、93 个分片全部零平移流式转发），
      //     而进度条照样「定位后往后漂 20 多秒」。
      //
      //   【那实际要不要平移，由谁决定】由**代理内部**在展开最终 media 列表后
      //   按确凿证据判定：两套名义轴是否分叉（已删广告累计）/ 源是否含
      //   `#EXT-X-DISCONTINUITY`。见 `local_m3u8_proxy.dart` 的 `_buildSegMeta`。
      //   与主工程 `hain_tv` 的「probe→flip」机制同目标，但不需要额外网络探测。
      final needPtsNormalize = useMpv;
      _proxy!.setPtsNormalize(needPtsNormalize);
      WindowsLogger.log('AdFilterEngine',
          ' PTS 归一化后端门控=$needPtsNormalize（后端=$effectiveBackend, '
          '顶层裁掉广告=$removedAdCount 段（口径有限，实际以代理内部轴判定为准）, '
          '代理解密=$useProxyDecrypt）');
      final baseUrl = await _proxy!.start();
      WindowsLogger.log('AdFilterEngine', ' 本地代理已启动: $baseUrl');
      // 按内容（而非仅 URL 后缀）判定是否为 M3U8：部分回放/catchup 地址无
      // .m3u8 后缀但返回的是 M3U8，必须重写分片走代理；真正非 M3U8 的裸流则
      // 包成单分片播放列表，经代理流式拉流绕开 fvp 直连 TLS。
      final contentIsM3u8 = content.trim().startsWith('#EXTM3U');
      String finalContent;
      if (contentIsM3u8) {
        // 先把相对 URL 解析为绝对 URL，避免 libmpv/fvp 读到相对路径后向本地代理根目录请求。
        final resolved = LocalM3u8Proxy.resolveRelativeUrls(content, effectiveUrl);
        // fvp 后端开启分段重编号（注入 &hseg=N 唯一序号 + 丢弃 discontinuity），
        // 规避 gsuus 等「跨 #EXT-X-DISCONTINUITY 复用同名分片」源卡死。
        finalContent = LocalM3u8Proxy.rewriteToLocalProxy(
          resolved,
          baseUrl,
          renumberSegments: useFvp,
          // 🔴 2026-10-24：代理解密（fvp / mpv）—— 剥离 EXT-X-KEY 并给分片
          //   代理 URL 注入 &decrypt=aes128&key=&iv=，由代理在**明文**上做
          //   PTS 归一化。详见 LocalM3u8Proxy._decryptAes 注释。
          decryptAes: useProxyDecrypt,
        );
      } else {
        WindowsLogger.log('AdFilterEngine', ' 非 M3U8 内容，包成单分片代理播放列表');
        finalContent =
            '#EXTM3U\n#EXTINF:-1,\n$baseUrl/segment?url=${Uri.encodeComponent(effectiveUrl)}\n';
      }
      // 🔴🔴🔴 2026-10-24：**接通 HLS 并发分片预取**。
      //
      // 【为什么必须接】主工程 `hain_tv` 的同源实现里，这段是：
      //     final hlsPrefetch = contentIsM3u8 && await UserDataService.getHlsPrefetchEnabled();
      //     _proxy!.setPlaylist(finalContent, requestHeaders, prefetch: hlsPrefetch);
      // 注释里明写「预取生效的**命门**是分片天然流经 Dart 侧代理」。
      // 而本工程（hain_tv_ohos）**根本没传 prefetch** ⇒ `_prefetchEnabled`
      // 恒 false ⇒ 真机日志里 `Prefetch:` 一条都没有 ⇒ 每个分片都要
      // 「回源下载 → 整段缓冲 → 吐出」⇒ 首字节延迟中位 1168ms
      // ⇒ 播放器缓冲在每个分片边界被反复饿空 ⇒ 画面偶尔卡住（声音正常）。
      //
      // 【mpv 后端也满足命门】本工程的 mpv 同样走本地代理
      // （真机日志 `proxySegment request:` 即 mpv 发起），不像早期版本
      // 只有 avplayer/fvp 走代理 ⇒ mpv/exo 不再需要平台限制。
      //
      // 【仅对 M3U8 生效】非 M3U8 被包成单分片，没有「后续分片」可预取，
      // 开了只是白占 50MB 缓存额度。
      final hlsPrefetch =
          contentIsM3u8 && await UserDataService.getHlsPrefetchEnabled();
      _proxy!.setPlaylist(finalContent, requestHeaders, prefetch: hlsPrefetch);
      WindowsLogger.log('AdFilterEngine',
          ' HLS 并发预取: ${hlsPrefetch ? "开启" : "关闭"}');

      final playlistUrl = '$baseUrl/playlist.m3u8';
      WindowsLogger.log('AdFilterEngine', ' 代理地址: $playlistUrl');
      return playlistUrl;
    } catch (e, stack) {
      WindowsLogger.log('AdFilterEngine', ' 过滤/代理失败 $e');
      debugPrint('$stack');
      return null;
    }
  }

  /// 🔴🔴 2026-10-23：限量读取响应的前 [maxBytes] 字节，用于内容嗅探。
  ///
  /// 返回 `({String text, bool complete})`：
  ///   · `text`     —— 已读到的内容（UTF-8 解码，容错）
  ///   · `complete` —— 是否**读完了整个响应体**（true 时内容可直接使用）
  ///
  /// 失败（网络异常 / 非 200）返回 null。
  static Future<({String text, bool complete})?> _fetchHeadBytes(
    String url,
    Map<String, String> headers,
    int maxBytes,
  ) async {
    try {
      final client = http.Client();
      try {
        final request = http.Request('GET', Uri.parse(url));
        if (headers.isNotEmpty) request.headers.addAll(headers);
        final response = await client.send(request).timeout(
          const Duration(seconds: 15),
        );
        if (response.statusCode != 200) {
          return null;
        }
        final bytes = <int>[];
        await for (final chunk in response.stream) {
          bytes.addAll(chunk);
          if (bytes.length >= maxBytes) break;
        }
        return (
          text: utf8.decode(bytes, allowMalformed: true),
          complete: bytes.length < maxBytes,
        );
      } finally {
        client.close();
      }
    } catch (e) {
      WindowsLogger.log('AdFilterEngine', ' 嗅探请求失败: $e');
      return null;
    }
  }

  /// 取 M3U8 内容前若干行用于诊断，避免日志过大。
  static String _summarizeContent(String content, {int maxLines = 20}) {
    final lines = content.split('\n');
    final head = lines.take(maxLines).join('\n');
    if (lines.length <= maxLines) return head;
    return '$head\n... (${lines.length} 行)';
  }

  static Future<void> dispose() async {
    // 停止代理时不阻塞当前调用方，避免退出播放或关闭应用时因网络请求等待而卡顿。
    final proxy = _proxy;
    _proxy = null;
    if (LocalM3u8Proxy.currentInstance == proxy) {
      LocalM3u8Proxy.currentInstance = null;
    }
    if (proxy != null) {
      unawaited(proxy.stop());
    }
  }
}
