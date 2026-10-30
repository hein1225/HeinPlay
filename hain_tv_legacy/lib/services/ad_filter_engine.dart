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

  static Future<String?> filterM3u8({
    required String sourceType,
    required String originalUrl,
    Map<String, String> headers = const {},
  }) async {
    final enabled = await AdFilterService.isEnabled();
    final isComputer = DeviceUtils.isComputer;
    // 去广告后残留的孤立 EXT-X-DISCONTINUITY 会让 fvp/libmpv 重置时间轴、从头重播，
    // 仅 fvp 后端需要清理；ExoPlayer(安卓/TV 默认) 依赖 discontinuity 避免
    // UnexpectedDiscontinuityException，必须保留。按"实际生效的后端"判定，而非仅 Windows。
    final selBackend = await UserDataService.getPlayerBackend();
    final effectiveBackend =
        PlayerBackendFactory.availableBackends.contains(selBackend)
            ? selBackend
            : PlayerBackendFactory.platformDefault;
    final useFvp = effectiveBackend == PlayerBackendType.fvp;
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
          WindowsLogger.log('AdFilterEngine', ' 已过滤 ${filter.currentAdCount} 个片段');
        } else {
          WindowsLogger.log('AdFilterEngine', ' 无需过滤或过滤失败');
        }
      }

      _proxy ??= LocalM3u8Proxy();
      // 子 M3U8 过滤状态与去广告开关保持一致；
      // Windows 非去广告场景直接播放原始 URL，不再经过本地代理。
      _proxy!.setFilterEnabled(enabled);
      // fvp/libmpv 需清理去广告后残留的孤立 discontinuity，避免重新播放；
      // ExoPlayer 必须保留 discontinuity，故仅 fvp 后端开启。
      if (useFvp) _proxy!.setDiscontinuityCleanup(true);
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
        finalContent = LocalM3u8Proxy.rewriteToLocalProxy(resolved, baseUrl);
      } else {
        WindowsLogger.log('AdFilterEngine', ' 非 M3U8 内容，包成单分片代理播放列表');
        finalContent =
            '#EXTM3U\n#EXTINF:-1,\n$baseUrl/segment?url=${Uri.encodeComponent(effectiveUrl)}\n';
      }
      // 🔴 2026-10-29：mpv 后端**提前**启动「建索引头部段」预热
      //   （plist0 是 mpv 建索引的阻塞项，必须在 open 之前备好）。
      _proxy!.setPlaylist(finalContent, requestHeaders,
          primeHead: effectiveBackend == PlayerBackendType.mpv);

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
}
