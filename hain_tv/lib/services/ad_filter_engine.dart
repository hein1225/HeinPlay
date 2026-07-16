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

    // Windows 端部分播放器（libmpv/fvp）对非标准端口 HTTPS 兼容性差，
    // 即使去广告开关关闭，也强制走本地 HTTP 代理，把 HTTPS 源转成本地 HTTP 流。
    final needsProxy = enabled || isWindows;
    if (!needsProxy) {
      WindowsLogger.log('AdFilterEngine', ' 去广告已关闭且非 Windows，直接播放');
      return null;
    }

    try {
      String fetchUrl = originalUrl;
      final proxyUrl = await UserDataService.getM3u8ProxyUrl();
      if (proxyUrl.isNotEmpty) {
        fetchUrl = '$proxyUrl${Uri.encodeComponent(originalUrl)}';
        WindowsLogger.log('AdFilterEngine', ' 使用 M3U8 代理下载: $fetchUrl');
      }

      final uri = Uri.parse(fetchUrl);
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
          .get(uri, headers: requestHeaders)
          .timeout(const Duration(seconds: 15));
      debugPrint(
        'AdFilterEngine: M3U8 下载完成 status=${response.statusCode} length=${response.bodyBytes.length}',
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

  static Future<void> dispose() async {
    await _proxy?.stop();
    _proxy = null;
  }
}
