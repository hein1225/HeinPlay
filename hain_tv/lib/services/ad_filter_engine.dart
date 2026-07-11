import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import 'ad_filter_service.dart';
import 'local_m3u8_proxy.dart';
import 'm3u8_ad_filter.dart';
import 'user_data_service.dart';

class AdFilterEngine {
  static LocalM3u8Proxy? _proxy;

  static Future<String?> filterM3u8({
    required String sourceType,
    required String originalUrl,
    Map<String, String> headers = const {},
  }) async {
    final enabled = await AdFilterService.isEnabled();
    debugPrint('AdFilterEngine: 去广告开关=$enabled');
    if (!enabled) {
      debugPrint('AdFilterEngine: 去广告已关闭');
      return null;
    }

    final lowerUrl = originalUrl.toLowerCase();
    if (!lowerUrl.contains('.m3u8') &&
        !lowerUrl.contains('/hls/') &&
        !lowerUrl.contains('application/vnd.apple.mpegurl') &&
        !lowerUrl.contains('audio/x-mpegurl')) {
      debugPrint('AdFilterEngine: 非 M3U8 地址，跳过过滤');
      return null;
    }

    try {
      String fetchUrl = originalUrl;
      final proxyUrl = await UserDataService.getM3u8ProxyUrl();
      if (proxyUrl.isNotEmpty) {
        fetchUrl = '$proxyUrl${Uri.encodeComponent(originalUrl)}';
        debugPrint('AdFilterEngine: 使用 M3U8 代理下载: $fetchUrl');
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

      final response = await http
          .get(uri, headers: requestHeaders)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('AdFilterEngine: 下载 M3U8 失败 ${response.statusCode}');
        return null;
      }

      final originalContent = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (originalContent.isEmpty) return null;

      final filter = M3u8AdFilter();
      final filteredContent = filter.purify(originalUrl, originalContent);
      if (filteredContent == null || filteredContent == originalContent) {
        debugPrint('AdFilterEngine: 无需过滤或过滤失败');
        return null;
      }

      _proxy ??= LocalM3u8Proxy();
      final baseUrl = await _proxy!.start();
      final rewritten = LocalM3u8Proxy.rewriteToLocalProxy(filteredContent, baseUrl);
      _proxy!.setPlaylist(rewritten, requestHeaders);

      final playlistUrl = '$baseUrl/playlist.m3u8';
      debugPrint(
        'AdFilterEngine: 已过滤 ${filter.currentAdCount} 个片段，代理地址: $playlistUrl',
      );
      return playlistUrl;
    } catch (e, stack) {
      debugPrint('AdFilterEngine: 过滤失败 $e');
      debugPrint('$stack');
      return null;
    }
  }

  static Future<void> dispose() async {
    await _proxy?.stop();
    _proxy = null;
  }
}
