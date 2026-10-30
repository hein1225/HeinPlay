import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'ad_filter_service.dart';
import 'local_m3u8_proxy.dart';
import 'm3u8_ad_filter.dart';
import 'm3u8_utils.dart';
import 'ts_pts_normalizer.dart';
import 'user_data_service.dart';
import '../platform/device_utils.dart';
import '../player/player_backend_factory.dart';
import '../utils/windows_logger.dart';

/// 预探测结论的三态枚举（2026-10-18 引入）。详见 _probeSourcePtsDrift。
enum PtsProbeVerdict {
  /// 测出来了，且各段 delta 一致 ⇒ 源轴可信，无需平移。
  trustworthy,

  /// 测出来了，且 delta 逐段剧烈变动 ⇒ 源轴错乱，必须平移。
  drifted,

  /// **没测出来**（超时 / 样本不足 / 读不出 PTS / 异常）。
  /// 不等于「可信」，按兜底策略处理。
  inconclusive,
  }


class AdFilterEngine {
  static LocalM3u8Proxy? _proxy;

  static Future<String?> filterM3u8({
    required String sourceType,
    required String originalUrl,
    Map<String, String> headers = const {},
    bool? ptsNormalize,
    /// 起播位置（ms）。用于把「源 PTS 轴探测」的取样点放在**用户实际要看
    /// 的那一段附近**，而不是播放列表开头。
    ///
    /// 为什么要这个参数：从第 1299 秒起播时，若只探测列表开头那几段，就完全
    /// 测不到用户真正会遇到的那一段 —— 源轴错乱若只发生在后段，探测会漏判
    /// （真机日志 XiaoPaiTech BA001 2026101711 的错乱覆盖 990s~1330s 区间，
    /// 开头几段不一定能反映）。传 null 则退回「取列表最前若干段」。
    int? probeAtMs,
  }) async {
    final enabled = await AdFilterService.isEnabled();
    final isComputer = DeviceUtils.isComputer;
    // 去广告后残留的孤立 EXT-X-DISCONTINUITY 会让 fvp/libmpv 重置时间轴、从头重播，
    // 仅特定后端需要清理 discontinuity；ExoPlayer(安卓/TV 默认) 依赖 discontinuity 避免
    // UnexpectedDiscontinuityException，必须保留。按"实际生效的后端"判定，而非仅 Windows。
    final selBackend = await UserDataService.getPlayerBackend();
    final effectiveBackend =
        PlayerBackendFactory.availableBackends.contains(selBackend)
            ? selBackend
            : PlayerBackendFactory.platformDefault;

    // 🔴 PTS 归一化（进度偏移根治）的默认判定。
    //
    // 为什么按后端而非全局恒开：主工程有 mpv / exo / vlc 三种后端共存，历史
    //   行为是无平移；改写分片字节对 exo/vlc 未必无害，故**默认只对 mpv 开**，
    //   其余后端由调用方显式覆盖。exo/vlc 若将来验证无副作用，再放开。
    //
    // 为什么必须走代理才有意义：本机制作用在代理转发的分片字节上。后端直连
    //   CDN 时（去广告关闭的 Android 默认路径）分片不经过本进程，机制无从介入。
    final effectivePtsNormalize = ptsNormalize ?? (effectiveBackend == PlayerBackendType.mpv);
    WindowsLogger.log(
      'AdFilterEngine',
      '去广告开关=$enabled, 电脑版=$isComputer, 后端=$effectiveBackend, '
      'PTS归一化=$effectivePtsNormalize',
    );

    // 🔴 2026-10-16：原「fvp 强制走本地代理透传」逻辑（needProxyPassthrough）已删除。
    //   fvp 全平台摘除后原判据恒为 false，该分支永不可达。
    //   历史上它是为绕过 libmdk 在 Windows/Linux/鸿蒙直连 CDN 时的 TLS/DNS 握手
    //   失败与 reader 死寂期而设；mpv 后端不存在该缺陷（走 mpv 自身网络栈 +
    //   http-header-fields 下发），故无需保留透传绕行。

    // 🔴 需要「孤立 discontinuity 清理 + 分段重编号」的后端：fvp 血统的 libmpv。
    //   去广告删段后会留下孤立 EXT-X-DISCONTINUITY，libmpv 会因此重置时间轴、从头重播。
    //   ExoPlayer 反而**依赖** discontinuity 避免 UnexpectedDiscontinuityException，
    //   故不可对它清理 —— 判据必须是「实际生效的后端」，不能按操作系统。
    //   历史上这里写的是 `useFvp`（== fvp 后端）；fvp 摘除后 mpv 是同类内核，
    //   故判据改为 mpv，语义与行为保持等价。
    final needDiscontinuityCleanup = effectiveBackend == PlayerBackendType.mpv;

    // 🔴 2026-10-16：fvp 的「强制本地代理透传」已删除。
    //   mpv 后端直连 CDN 正常（走 mpv 自身网络栈 + http-header-fields），
    //   无需为它保留透传绕行。故 passthrough 恒为 false。

    final lowerUrl = originalUrl.toLowerCase();
    var isM3u8 =
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('/hls/') ||
        lowerUrl.contains('application/vnd.apple.mpegurl') ||
        lowerUrl.contains('audio/x-mpegurl');
    // 透传平台（fvp/Windows/Linux/鸿蒙）即便 URL 没有 .m3u8 后缀（如 catchup
    // 回放地址 ?playbackbegin=...）也可能返回 M3U8/TS 流，需要下载后按内容判定，
    // 不能仅凭后缀就跳过；其余平台保持历史行为：不像 M3U8 直接跳过。
    //
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
    // 其余（无后缀/未知后缀）先下载一次嗅探内容，确认是 HTML 就把内嵌的
    // m3u8 取出来继续走代理流程。
    final skipByExtension = M3u8Utils.looksLikeDirectMediaUrl(originalUrl);
    if (!isM3u8 && skipByExtension) {
      WindowsLogger.log('AdFilterEngine', ' 直链媒体地址，跳过');
      return null;
    }

    // 去广告关闭时：非透传平台（安卓/TV 等直连正常的后端）直接播放原始 URL，
    // 恢复历史行为；fvp 在 Windows/Linux/鸿蒙直连 CDN 会 TLS/DNS 握手失败，
    // 即使关闭去广告也强制走本地代理透传（复用 App 的 Dart HTTP 客户端拉流），
    // 仅不做去广告过滤。
    if (!enabled) {
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
        // URL 已带 .m3u8 特征 → 直接完整下载（M3U8 文本很小）。
        WindowsLogger.log('AdFilterEngine', ' 开始下载 M3U8: $fetchUrl (去广告=$enabled)');
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
            // 嗅探时已把整个 playlist 读完了，直接用，不用再下��次。
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
      // 🔴🔴 实际裁掉的广告片段数。用于决定**是否还需要 PTS 归一化**。
      //
      // 归零场景（本工程最常见的片源就是这一种）：去广告开关开着，但该源
      //   根本没有广告被裁 ⇒ 时间轴与原始源**逐字节一致**，此时再做 PTS
      //   平移没有任何东西可补偿，反而因为 mpv 的 `duration` 走 EXTINF 名义
      //   轴、`time-pos` 走真实 PTS 轴，两条轴之间的浮点/取整差异会在分片边界
      //   累积成「进度条突然往前跳一段（实测 +26s 左右），但画面连续不跳」。
      //
      // 实测证据（2026-10-16 两台设备）：
      //   `[AdFilterEngine] 已过滤 0 个片段` + `PTS 元数据已重建：1 段`
      //   心跳 `time-pos` 约每 2 拍跳一次 +25.5s / +28.1s，其余拍恒为 +3.00。
      //   `seek` / `loadfile` 日志计数均为 0 ⇒ 排除应用侧主动 seek。
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
          cleanDiscontinuities: needDiscontinuityCleanup,
        );
        if (filteredContent != null && filteredContent != content) {
          content = filteredContent;
          removedAdCount = filter.currentAdCount;
          WindowsLogger.log('AdFilterEngine', ' 已过滤 $removedAdCount 个片段');
        } else {
          WindowsLogger.log('AdFilterEngine', ' 无需过滤或过滤失败');
        }
      }

      // 🔴🔴 2026-10-17 修正：这里原先只有「裁掉几个片段」一个判据，
      //   没裁掉就整体关掉归一化（连基准探测一起停）。前半句对、后半句错：
      //
      //     「时间轴没变」≠「时间轴是准的」
      //
      //   源自身 PTS 轴错乱时，EXTINF 名义轴是对的、真实 PTS 轴是乱跳的，
      //   两轴不一致恰恰**最需要**归一化纠偏。而关掉开关后连 `_deltaFor`
      //   都不跑了（它在 `!_ptsNormalize` 时立刻 return 0），于是错乱原样
      //   暴露给播放器 —— 真机日志 XiaoPaiTech BA001 2026101711 的表现：
      //     time-pos: 1299 → 1327 → 1330 → 1292 → 1299 → 1140 → 1128 → 990
      //   用户观感即「进度条固定往后偏 20 秒」。
      //
      //   故拆成两个正交开关：
      //     · needPtsNormalize —— 是否**施加**平移（裁掉广告才需要）
      //     · needPtsProbe     —— 是否**探测**源轴可信度（始终需要）
      //   典型组合：
      //     裁掉广告   ⇒ normalize=true,  probe=false（真平移，无需额外探测）
      //     没裁掉广告 ⇒ 先 probe，探测判定源轴错乱则升为真平移
      //
      //   🔴 故这里必须是 `var`：探测结果可能把它从 false 提升为 true。
      var needPtsNormalize = effectivePtsNormalize && removedAdCount > 0;
      final bool needPtsProbe = effectivePtsNormalize && !needPtsNormalize;
      if (needPtsProbe) {
        WindowsLogger.log(
          'AdFilterEngine',
          ' PTS 不平移（本次未裁掉广告片段），但启用探测模式：仍会解析每段真实 PTS '
          '与名义轴的偏差，用于发现源自身时间轴错乱',
        );
      }

      _proxy ??= LocalM3u8Proxy();
      // 子 M3U8 过滤状态与去广告开关保持一致；
      // Windows 非去广告场景直接播放原始 URL，不再经过本地代理。
      _proxy!.setFilterEnabled(enabled);      // fvp/libmpv 需清理去广告后残留的孤立 discontinuity，避免重新播放；
      // ExoPlayer 必须保留 discontinuity，故仅 fvp 后端开启。
      if (needDiscontinuityCleanup) _proxy!.setDiscontinuityCleanup(true);
      // fvp 专属：分段全局重编号 + 结构性 discontinuity 丢弃，规避 libmdk
      // 跨断点复用同名分片（如 plist0.ts）命中段缓存、停止续预取而卡死。
      _proxy!.setFvpRenumber(needDiscontinuityCleanup);
      // 🔴 PTS 归一化（进度偏移根治）：把去广告后的名义轴交给代理。
      //
      // 为什么是「可选」而非恒开：主工程有 mpv / exo / vlc 三种后端共存，且
      //   历史行为是无平移；改写分片字节对 exo/vlc 未必无害。默认关闭，
      //   由 buildPlaylistUrl 的 ptsNormalize 参数按后端与用户设置决定。
      _proxy!.setPtsNormalize(needPtsNormalize);
      // 🔴 探测模式：不施加平移，但仍解析每段真实 PTS 并与名义轴对比。
      _proxy!.setPtsProbeOnly(needPtsProbe);
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
        // 🔴🔴 PTS 元数据必须在**绝对化之后**重建：代理侧查表用的键是
        //   `?url=` 的绝对地址，若在相对形态上重建，键就对不上 ⇒ 查表全 miss
        //   ⇒ 平移静默失效（无报错，只是不生效）。
        // 🔴 探测模式也需要元数据：没有「分片 → 名义轴起点」的对照表，
        //   就算出了真实 PTS 也无从判断偏差。
        if (needPtsNormalize || needPtsProbe) {
          // 🔴🔴 2026-10-17 第二次修正：master playlist 必须先展开成 media。
          //
          // 现场证据（真机 XiaoPaiTech BA001 2026101711，新日志 e46d94cb）：
          //     M3U8 下载完成 status=200 length=118      ← master，只有 118 字节
          //     M3U8 内容摘要: #EXTM3U
          //     PTS 元数据已重建：1 段（待探测）          ← 只有 1 段！
          //     预探测判定源 PTS 轴可信                    ← 无任何取样明细
          //   而真正的 media 列表要到 mpv 首次拉 playlist.m3u8 时，由**代理内部**
          //   展开（`11:36:01.231 PTS 元数据已重建（最终 media 列表）：1326 段`），
          //   那时预探测早已结束。
          //
          //   `resolved` 是 master 文本，只含一行 `#EXT-X-STREAM-INF` + 变体 URL，
          //   `rebuildSegMetaOn(resolved)` 只能登记出 1 条键。于是取样窗口
          //   `take(3)` 只拿到 1 段 ⇒ 极差恒为 0 ⇒ **必然判「可信」**，探测形同虚设。
          //
          //   修法：探测前自己把 master 展开成 media，在**最终 media 列表**上
          //   重建元数据。这与代理侧 L723-749 记录的 2026-10-15 修根因完全同源
          //   ——「全流程中唯一能拿到最终媒体列表的位置」在 master 展开之后。
          //   展开失败则退回原文本（宁可少探测，也不能拖垮起播）。
          var metaSource = resolved;
          if (LocalM3u8Proxy.isMasterPlaylistText(content)) {
            final variantUrl = LocalM3u8Proxy.extractFirstVariantUrl(content);
            if (variantUrl != null) {
              final sub = await LocalM3u8Proxy.fetchPlaylistText(
                LocalM3u8Proxy.resolveRelativeUrls(variantUrl, effectiveUrl),
                headers: headers,
              );
              if (sub != null && sub.trim().startsWith('#EXTM3U')) {
                metaSource =
                    LocalM3u8Proxy.resolveRelativeUrls(sub, effectiveUrl);
                WindowsLogger.log(
                  'AdFilterEngine',
                  ' master 已展开用于元数据重建：'
                  '${_countExtinf(sub)} 个片段（master 仅 1 条变体行）',
                );
              } else {
                WindowsLogger.log(
                  'AdFilterEngine',
                  ' master 展开失败（子列表不可用），元数据仍建在 master 上'
                  '（此时探测样本数不足会判「样本不足」而非「可信」）',
                );
              }
            }
          }
          M3u8AdFilter.metaBaseUrl = effectiveUrl;
          M3u8AdFilter.clearSegMeta();
          M3u8AdFilter.rebuildSegMetaOn(metaSource);
          final meta = M3u8AdFilter.takeSegMeta();
          _proxy!.setSegmentMeta(meta);
          WindowsLogger.log(
            'AdFilterEngine',
            ' PTS 元数据已重建：${_proxy!.segmentMetaCount} 段'
            '（${needPtsNormalize ? '平移模式' : '待探测'}）',
          );
          // 🔴🔴 2026-10-17 新增：起播前预探测源 PTS 轴是否可信。
          //
          // 【为什么必须在这里做】不能等到播放中才发现源轴错乱 —— 那时
          //   播放器已经按原字节消费了一段，中途改轴会制造新的跳变（见
          //   `local_m3u8_proxy.dart` 中 `_deltaFor` 里那段「为什么不自动升级」
          //   的说明）。唯一正确时机是**把播放列表交给播放器之前**。
          //
          // 【判据】取前若干个分片，各算一次
          //     delta(n) = (名义轴起点 + 基准真实PTS) - 该段真实PTS
          //   健康源：各段 delta 基本一致（只差首帧对齐误差，几百 ms 内）。
          //   错乱源：delta 逐段剧烈变化（真机实测相邻段跳 ±28s/−158s）。
          //   这里用「极差(max-min) 超阈值」判定，比看单段绝对值更稳 ——
          //   单段 delta 大但恒定只是整体偏移，那属于正常且无害的情形。
          //
          // 【失败即放行】探测本身要发几次网络请求，任何异常都不能影响起播
          //   （历史教训：起播链路上加阻塞调用会让人以为软件打不开）。故全程
          //   try/catch，探测失败就保持原判据。
          // 🔴🔴 2026-10-29：加密源**跳过预探测**（省一次起播前的网络等待）。
          //
          //   【为什么】预探测是「直接回源下载分片 → 读它的视频 PES PTS」。
          //   而 AES-128 源的分片在 CDN 上是**密文** ⇒ PTS 读不出来 ⇒
          //   结论**必然**是 inconclusive ⇒ 分支结果**必然**是
          //   「启用真平移兜底」。也就是说：探测**只可能**得到既定结论，
          //   却要付出 6 次分片下载 + 等待。
          //
          //   实测（小米 12S Pro 2026-10-29 22:44）：
          //     22:44:46.983 预探测取样点 → 22:44:49.062 结论（**2.08s**）
          //     结论=「分片读不出视频 PTS（封装不支持）」= inconclusive
          //   ⇒ 这 2.08s 纯属浪费，且它就在**点击播放 → open**的关键路径上。
          //
          //   改成：识别到 AES-128 就直接走同一条兜底分支（结论与行为完全一致），
          //   只是**不再白等**。真机日志 21:31 那次探测只花 0.37s，
          //   说明这段耗时完全取决于当时的 CDN 速度（0.4~2.1s 波动）。
          final isAesSource = _isAes128Playlist(content) ||
              _isAes128Playlist(metaSource);
          if (needPtsProbe && isAesSource) {
            needPtsNormalize = true;
            _proxy!.setPtsNormalize(true);
            _proxy!.setPtsProbeOnly(false);
            WindowsLogger.log(
              'AdFilterEngine',
              ' 源为 AES-128 加密（分片是密文，预探测必然读不出 PTS）'
              '⇒ 跳过探测，直接启用真平移兜底（结论与探测后一致，省掉 6 次分片下载）',
            );
          } else if (needPtsProbe && meta.isNotEmpty) {
            final verdict = await _probeSourcePtsDrift(
              meta,
              effectiveUrl,
              nearMs: probeAtMs,
              headers: headers,
            );
            // 🔴🔴🔴 2026-10-18：三态分支。**未定论按「错乱」处理**（启用平移）。
            //
            //   真机 2026101816 的教训：超时被当成「可信」⇒ 不平移 ⇒
            //   time-pos 走真实 PTS 轴、duration 走名义轴 ⇒ 双轴分离 ⇒
            //   心跳 3 秒走 42 秒、再 3 秒走 160 秒（用户说的「往后偏移」）。
            //   平移对健康源是幂等对齐（代价仅 CPU），对错乱源是必需；
            //   不平移对健康源无事、对错乱源必然出错。故未定论时宁可平移。
            if (verdict == PtsProbeVerdict.drifted ||
                verdict == PtsProbeVerdict.inconclusive) {
              // 源轴确实错乱，或**未能证明可信** ⇒ 升级为真平移，
              // 让整条时间轴从第一段起就对齐。
              needPtsNormalize = true;
              _proxy!.setPtsNormalize(true);
              _proxy!.setPtsProbeOnly(false);
              WindowsLogger.log(
                'AdFilterEngine',
                verdict == PtsProbeVerdict.inconclusive
                    ? ' 预探测未定论 ⇒ 启用 PTS 平移兜底'
                    : ' 预探测判定源 PTS 轴错乱 ⇒ 启用真平移',
              );
              WindowsLogger.log(
                'AdFilterEngine',
                ' ⚠️ 预探测结论=${verdict.name} ⇒ 已启用真平移纠偏（整条时间轴按名义轴对齐）',
              );
            } else {
              WindowsLogger.log(
                'AdFilterEngine',
                ' 预探测判定源 PTS 轴可信 ⇒ 保持不平移（仅保留运行期探测告警）',
              );
            }
          }
        } else {
          _proxy!.setSegmentMeta(const <String, int>{});
        }
        // fvp 后端开启分段重编号（注入 &hseg=N 唯一序号 + 丢弃 discontinuity），
        // 规避 gsuus 等「跨 #EXT-X-DISCONTINUITY 复用同名分片」源卡死。
        finalContent = LocalM3u8Proxy.rewriteToLocalProxy(
          resolved,
          baseUrl,
          renumberSegments: needDiscontinuityCleanup,
        );
      } else {
        WindowsLogger.log('AdFilterEngine', ' 非 M3U8 内容，包成单分片代理播放列表');
        _proxy!.setSegmentMeta(const <String, int>{});
        finalContent =
            '#EXTM3U\n#EXTINF:-1,\n$baseUrl/segment?url=${Uri.encodeComponent(effectiveUrl)}\n';
      }
      // 🔴 HLS 并发分片预取（移植自 hain_tv_ohos）。
      //
      // 鸿蒙侧条件为 `Platform.operatingSystem == 'ohos' && hlsPrefetchEnabled`
      // —— 必须限制平台，因为开启预取意味着**强制走本地代理透传**，而鸿蒙
      //   只有 avplayer/fvp 走代理。主工程 Android 端 mpv/exo/fvp **本来
      //   就走本地代理**（分片天然流经 Dart 侧，这是预取生效的命门），
      //   故无需平台限制，只按用户开关决定。
      //
      // ⚠️ 仅对 M3U8 内容生效：非 M3U8 被包成单分片，没有「后续分片」可预取，
      //    开了也只是白占 50MB 缓存额度。
      final hlsPrefetch = contentIsM3u8 &&
          await UserDataService.getHlsPrefetchEnabled();
      // 🔴🔴 2026-10-29：mpv 后端**提前**启动「建索引头部段」预热。
      //
      //   【为什么必须提前到这一步】真机日志（小米 12S Pro 2026-10-29 22:44）：
      //     22:44:46.971  拿到完整 media 列表（621 段）
      //     22:44:49.078  MpvBackend open（**2.1s 之后**）
      //     22:44:51.384  plist0 才拿到（open 后 2.28s）
      //   plist0 是 mpv 建索引的**阻塞项**（file-loaded 直接等它），
      //   若预热等到 open 才开始，就只能跟 mpv 抢同一条下载。
      //   在这里（= open 前约 2s）就把头部段备好，mpv 首次请求直接命中缓存。
      final primeHead = effectiveBackend == PlayerBackendType.mpv;
      _proxy!.setPlaylist(finalContent, requestHeaders,
          prefetch: hlsPrefetch, primeHead: primeHead);
      WindowsLogger.log(
        'AdFilterEngine',
        ' HLS 并发预取: ${hlsPrefetch ? "开启" : "关闭"}',
      );

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
    if (proxy != null) {
      unawaited(proxy.stop());
    }
  }

  /// 起播前探测：源自身的 PTS 轴是否与 EXTINF 名义轴一致。
  ///
  /// 返回 `true` 表示**源 PTS 轴错乱**（需要开启真平移纠偏）。
  ///
  /// 【算法】
  ///   在名义轴上**跨区段分散**取样（起播点 1 组 + 全片等距 2 组，每组 2 段），逐段：
  ///     · 下载分片 → 解出首帧视频 PES 的 PTS（`firstPesPtsMs`）
  ///     · delta(n) = (首段首帧PTS + (该段名义起点 − 首段名义起点)) − 该段首帧PTS
  ///   等价于「以首段为原点，该段的真实位置与名义位置差多少」。
  ///
  ///   · 健康源：所有 delta 相互接近（首帧对齐误差，实测 < 300ms）
  ///   · 错乱源：delta 之间相差数秒乃至数分钟
  ///
  ///   判据用**极差**（max − min）而非绝对值：整体恒定偏移是无害的（播放器
  ///   会自己吸附到起点），只有「逐段变动」才会让进度条越播越偏。
  ///
  /// 【为什么只取前几段】探测发生在起播链路上，每多一段就多一次网络往返，
  ///   直接体现为「点了播放要等一下」。3 段足以判出量级差异，代价可控。
  ///
  /// 🔴🔴🔴 2026-10-18 三态返回值 —— **「没结论」不等于「通过」**。
  ///
  ///   现场教训（真机 XiaoPaiTech BA001 2026101816）：
  ///     16:27:31.480 预探测取样：3 组 × 2 段
  ///     16:27:35.486 预探测异常（放行）: TimeoutException after 0:00:04.000000
  ///     16:27:35.486 预探测判定源 PTS 轴可信 ⇒ 保持不平移   ← 失败被当成通过
  ///   后果：`time-pos` 走真实 PTS 轴、`duration` 走名义轴，两轴分家 ⇒
  ///   心跳实测 3 秒走 42 秒、再 3 秒走 160 秒，即用户说的「往后偏移」。
  ///
  ///   旧签名 `Future<bool>` 只有「可信 / 错乱」两态，**无法表达「没测出来」**，
  ///   于是超时、样本不足、读不出 PTS 全被压缩成 `false`（= 可信 = 不平移），
  ///   把「放弃探测」伪装成「探测通过」。这是本次复发的直接原因。
  ///
  ///   现在三态显式区分，且**未定论时启用平移兜底**（用户 2026-10-18 拍板）：
  ///   平移是幂等的对齐操作，对健康源最多多花一点 CPU；而不平移遇上错乱源
  ///   必然双轴分离 —— 两害相权，宁可平移。
  /// 判断播放列表是否声明了 **AES-128** 加密（`#EXT-X-KEY:METHOD=AES-128`）。
  ///
  /// 用于「加密源跳过 PTS 预探测」：加密分片在 CDN 上是密文，
  /// 直接回源读 PTS 必然失败（实测日志：「分片读不出视频 PTS（封装不支持）」），
  /// 探测结论必然是 inconclusive ⇒ 白等一轮下载。
  static bool _isAes128Playlist(String content) {
    if (!content.contains('#EXT-X-KEY')) return false;
    final m = RegExp(r'#EXT-X-KEY:[^\n]*METHOD=([A-Z0-9-]+)').firstMatch(content);
    return m != null && m.group(1) == 'AES-128';
  }

  static Future<PtsProbeVerdict> _probeSourcePtsDrift(
    Map<String, int> meta,
    String baseUrl, {
    int driftThresholdMs = 3000,
    int? nearMs,
    Map<String, String> headers = const {},
  }) async {
    try {
      // 按名义轴起点排序。
      final entries = meta.entries.toList()
        ..sort((a, b) => a.value.compareTo(b.value));
      // 🔴🔴 样本数不足必须**明确报出来**，不能悄悄返回 false。
      //
      // 现场教训（真机 2026-10-17）：`meta` 里只有 1 条（元数据建在 master 上），
      // `take(3)` 只取到 1 段 ⇒ 极差恒为 0 ⇒ 静默返回 false ⇒ 外层打印
      // 「预探测判定源 PTS 轴可信」。**没有取样明细却给出「可信」结论**，
      // 让排查时误以为探测跑过且通过了，白白多花一轮定位。
      // 现在把「样本不足」与「探测通过」在日志上彻底分开。
      if (entries.length < 2) {
        WindowsLogger.log(
          'AdFilterEngine',
          ' ⚠️ 预探测跳过：可用样本仅 ${entries.length} 段（<2），无法计算极差'
          ' —— 这是「样本不足」，**不是**「源轴可信」',
        );
        return PtsProbeVerdict.inconclusive;
      }

      // 🔴🔴 2026-10-17 第三次修正：取样必须**跨区段分散**，不能只看起播点。
      //
      // 【为什么】上一版只从起播点连续取 3 段，实测真机（XiaoPaiTech BA001
      //   2026101713）在此判据下报 `delta=[0, 0, 0] 极差=0 ⇒ 源轴可信`，
      //   但同一时刻**代理运行期** probe 正在持续报警：
      //     n=3  filtered=318000ms trueFirst=341480ms delta=-18000ms ⚠️
      //     n=5  filtered=90000ms  trueFirst=103480ms delta=-8000ms  ⚠️
      //   即该源漂移**随区段变化**（319s 附近 −18s，90s 附近 −8s），
      //   只看起播点那几段（恰好都对齐）必然得出「可信」的错误结论。
      //
      // 【改为】起播点一组 + 全片等距若干组，每组内**连续**：
      //   · 组内连续 ⇒ 仍能捕捉「相邻段突变」；
      //   · 组间分散 ⇒ 能捕捉「不同区段漂移不同」。
      //   用户的播放记录恢复 / 快退 / 快进会落在任意区段，只验起播点等于没验。
      const int kSamplePerGroup = 2;
      final List<List<MapEntry<String, int>>> groups =
          <List<MapEntry<String, int>>>[];
      final int span = entries.length;
      int startIdx = 0;
      if (nearMs != null && nearMs > 0) {
        for (var i = 0; i < span; i++) {
          if (entries[i].value >= nearMs) {
            startIdx = i;
            break;
          }
        }
        startIdx = startIdx.clamp(0, span - 1);
        groups.add(
            entries.skip(startIdx).take(kSamplePerGroup).toList(growable: false));
        WindowsLogger.log(
          'AdFilterEngine',
          ' 预探测取样：起播=${nearMs}ms → 从第 $startIdx 段起'
          '（该段名义起点=${entries[startIdx].value}ms）',
        );
      }
      // 全片等距铺点（起播组已占一个，故总数仍为 3 组，起播耗时不变）。
      final int extraGroups = 3 - groups.length;
      for (var g = 0; g < extraGroups; g++) {
        final int idx =
            ((span - 1) * (g + 1) / extraGroups).floor().clamp(0, span - 1);
        final grp =
            entries.skip(idx).take(kSamplePerGroup).toList(growable: false);
        if (grp.isNotEmpty) groups.add(grp);
      }
      final samples = <MapEntry<String, int>>[];
      for (final g in groups) {
        samples.addAll(g);
      }
      if (samples.length < 2) return PtsProbeVerdict.inconclusive;
      WindowsLogger.log(
        'AdFilterEngine',
        ' 预探测取样点：${groups.length} 组 × $kSamplePerGroup 段'
        '（全片 $span 段），各组名义起点='
        '${groups.map((g) => g.isEmpty ? -1 : g.first.value).toList()}ms',
      );

      final client = http.Client();
      final sw = Stopwatch()..start();
      final List<int> deltas = <int>[];
      int? baseFirstPts;
      int? baseNominal;
      try {
        for (final e in samples) {
          if (sw.elapsed > const Duration(seconds: 6)) {
            WindowsLogger.log(
              'AdFilterEngine',
              ' 预探测超时（已用 ${sw.elapsedMilliseconds}ms）'
              ' ⇒ 结论=未定论（启用平移兜底）',
            );
            return PtsProbeVerdict.inconclusive;
          }
          final segUrl = e.key;
          final nominal = e.value;
          // 必须带上与播放器一致的请求头：CDN 普遍校验 Referer/UA，
          // 裸请求会被 403，导致探测恒失败并放行（等于白做）。
          final reqHeaders = <String, String>{
            'User-Agent': headers['User-Agent'] ??
                'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
            'Accept': '*/*',
            ...headers,
          };
          if (!reqHeaders.containsKey('Referer') &&
              !reqHeaders.containsKey('referer')) {
            final u = Uri.parse(segUrl);
            reqHeaders['Referer'] = '${u.scheme}://${u.host}/';
          }
          final resp = await client
              .get(Uri.parse(segUrl), headers: reqHeaders)
              .timeout(const Duration(seconds: 4));
          // 🔴🔴 2026-10-17：206 Partial Content 是**正常**响应，不能当失败。
          //   真机证据（XiaoPaiTech BA001 2026101719 源2）：
          //     `预探测：分片返回异常 status=206，放弃探测并放行`
          //   → 本该取到 6 段，实际只有 2 段就中断，极差恒 0 ⇒ 谎报「源轴可信」。
          //   CDN/源站对带 Range 的请求回 206 是标准行为，只要 bodyBytes 非空
          //   就说明拿到了真实 TS 数据，可以直接解析 PES PTS。
          final okStatus = resp.statusCode == 200 || resp.statusCode == 206;
          if (!okStatus || resp.bodyBytes.isEmpty) {
            WindowsLogger.log(
              'AdFilterEngine',
              ' 预探测：分片返回异常 status=${resp.statusCode} '
              'len=${resp.bodyBytes.length} ⇒ 结论=未定论（启用平移兜底）',
            );
            return PtsProbeVerdict.inconclusive;
          }
          final firstPts = firstPesPtsMs(resp.bodyBytes, videoOnly: true);
          if (firstPts == null) {
            WindowsLogger.log(
              'AdFilterEngine',
              ' 预探测：分片读不出视频 PTS（封装不支持）'
              ' ⇒ 结论=未定论（启用平移兜底）',
            );
            return PtsProbeVerdict.inconclusive;
          }
          if (baseFirstPts == null) {
            baseFirstPts = firstPts;
            baseNominal = nominal;
            deltas.add(0);
            continue;
          }
          // 以首段为原点的相对偏差。
          final expected = baseFirstPts + (nominal - baseNominal!);
          deltas.add(expected - firstPts);
        }
      } finally {
        client.close();
      }

      if (deltas.length < 2) return PtsProbeVerdict.inconclusive;
      final maxD = deltas.reduce((a, b) => a > b ? a : b);
      final minD = deltas.reduce((a, b) => a < b ? a : b);
      final spread = maxD - minD;
      WindowsLogger.log(
        'AdFilterEngine',
        ' 预探测结果：${deltas.length} 段 delta=$deltas 极差=${spread}ms '
        '阈值=${driftThresholdMs}ms ⇒ '
        '${spread > driftThresholdMs ? '源轴错乱（平移）' : '源轴可信（不平移）'}',
      );
      return spread > driftThresholdMs
          ? PtsProbeVerdict.drifted
          : PtsProbeVerdict.trustworthy;
    } catch (e) {
      WindowsLogger.log(
        'AdFilterEngine',
        ' 预探测异常 ⇒ 结论=未定论（启用平移兜底）: $e',
      );
      return PtsProbeVerdict.inconclusive;
    }
  }

  /// 统计 M3U8 文本里的 `#EXTINF` 条数（即分片数）。
  ///
  /// 仅用于日志取证：展开 master 后必须能看到「实际拿到多少个片段」，
  /// 否则无法区分「展开成功但源本身只有 1 段」与「展开根本没生效」。
  static int _countExtinf(String content) {
    var n = 0;
    for (final line in content.split('\n')) {
      if (line.trim().startsWith('#EXTINF')) n++;
    }
    return n;
  }
}
