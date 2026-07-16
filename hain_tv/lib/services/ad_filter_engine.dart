import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'ad_filter_service.dart';
import 'local_m3u8_proxy.dart';
import 'm3u8_ad_filter.dart';
import 'user_data_service.dart';
import '../utils/windows_logger.dart';

class AdFilterEngine {
  static LocalM3u8Proxy? _proxy;

  static Future<String?> filterM3u8({
    required String sourceType,
    required String originalUrl,
    Map<String, String> headers = const {},
  }) async {
    final enabled = await AdFilterService.isEnabled();
    final isWindows = Platform.isWindows;
    WindowsLogger.log('AdFilterEngine', '去广告开关=$enabled, Windows=$isWindows');

    final lowerUrl = originalUrl.toLowerCase();
    final isM3u8 =
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('/hls/') ||
        lowerUrl.contains('application/vnd.apple.mpegurl') ||
        lowerUrl.contains('audio/x-mpegurl');
    if (!isM3u8) {
      WindowsLogger.log('AdFilterEngine', ' 非 M3U8 地址，跳过');
      return null;
    }

    // 参照 Selene 播放源处理方式：仅当去广告开启时才走本地 HTTP 代理。
    // Windows 端直接播放原始 URL，由 flutter_mpv/FVP 自身处理 HLS。
    final needsProxy = enabled;
    if (!needsProxy) {
      WindowsLogger.log(
        'AdFilterEngine',
        ' 去广告已关闭，直接播放原始 URL (Windows=$isWindows)',
      );
      return null;
    }

    try {
      String fetchUrl = originalUrl;
      final proxyUrl = await UserDataService.getM3u8ProxyUrl();
      if (proxyUrl.isNotEmpty) {
        fetchUrl = '$proxyUrl${Uri.encodeComponent(originalUrl)}';
        WindowsLogger.log('AdFilterEngine', ' 使用 M3U8 代理下载: $fetchUrl');
      }

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

      WindowsLogger.log('AdFilterEngine', ' 开始下载 M3U8: $fetchUrl');
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

      final originalContent = utf8.decode(
        response.bodyBytes,
        allowMalformed: true,
      );
      if (originalContent.isEmpty) {
        WindowsLogger.log('AdFilterEngine', ' M3U8 内容为空');
        return null;
      }
      WindowsLogger.log(
        'AdFilterEngine',
        ' M3U8 内容摘要: ${_summarizeContent(originalContent)}',
      );

      String content = originalContent;
      if (enabled) {
        final filter = M3u8AdFilter();
        final filteredContent = filter.purify(originalUrl, originalContent);
        if (filteredContent != null && filteredContent != originalContent) {
          content = filteredContent;
          WindowsLogger.log('AdFilterEngine', ' 已过滤 ${filter.currentAdCount} 个片段');
        } else {
          WindowsLogger.log('AdFilterEngine', ' 无需过滤或过滤失败');
        }
      } else {
        WindowsLogger.log('AdFilterEngine', ' Windows 代理模式，不过滤广告');
      }

      _proxy ??= LocalM3u8Proxy();
      // 子 M3U8 过滤状态与去广告开关保持一致；
      // Windows 非去广告场景直接播放原始 URL，不再经过本地代理。
      _proxy!.setFilterEnabled(enabled);
      final baseUrl = await _proxy!.start();
      WindowsLogger.log('AdFilterEngine', ' 本地代理已启动: $baseUrl');
      // 先把相对 URL 解析为绝对 URL，避免 libmpv/fvp 读到相对路径后向本地代理根目录请求。
      final resolved = LocalM3u8Proxy.resolveRelativeUrls(content, originalUrl);
      final rewritten = LocalM3u8Proxy.rewriteToLocalProxy(
        resolved,
        baseUrl,
      );
      _proxy!.setPlaylist(rewritten, requestHeaders);

      final playlistUrl = '$baseUrl/playlist.m3u8';
      WindowsLogger.log('AdFilterEngine', ' 代理地址: $playlistUrl');
      return playlistUrl;
    } catch (e, stack) {
      WindowsLogger.log('AdFilterEngine', ' 过滤/代理失败 $e');
      debugPrint('$stack');
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
