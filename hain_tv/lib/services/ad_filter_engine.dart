import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'ad_filter_service.dart';
import 'user_data_service.dart';

class AdFilterEngine {
  static JavascriptRuntime? _jsRuntime;

  static Future<String?> filterM3u8({
    required String sourceType,
    required String originalUrl,
    Map<String, String> headers = const {},
  }) async {
    if (!await AdFilterService.isEnabled()) {
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
        final encoded = Uri.encodeComponent(originalUrl);
        fetchUrl = '$proxyUrl$encoded';
        debugPrint('AdFilterEngine: 使用 M3U8 代理下载: $fetchUrl');
      }

      final uri = Uri.parse(fetchUrl);
      final originUri = Uri.parse(originalUrl);
      final origin = '${originUri.scheme}://${originUri.host}';
      final requestHeaders = Map<String, String>.from(headers);
      requestHeaders.putIfAbsent('Origin', () => origin);
      requestHeaders.putIfAbsent('Referer', () => origin);
      requestHeaders.putIfAbsent('Accept', () => '*/*');
      requestHeaders.putIfAbsent('User-Agent', () => 'Mozilla/5.0');

      final response = await http
          .get(uri, headers: requestHeaders)
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) {
        debugPrint('AdFilterEngine: 下载 M3U8 失败 ${response.statusCode}');
        return null;
      }

      final originalContent = utf8.decode(response.bodyBytes, allowMalformed: true);
      if (originalContent.isEmpty) return null;

      String filteredContent;
      final customCode = await AdFilterService.getCachedCode();
      if (customCode != null && customCode.isNotEmpty && customCode.contains('filterAdsFromM3U8')) {
        final customResult = await _applyCustomFilter(sourceType, originalContent, customCode);
        filteredContent = customResult ?? AdFilterService.applyDefaultFilter(sourceType, originalContent);
      } else {
        debugPrint('AdFilterEngine: 使用默认去广告规则');
        filteredContent = AdFilterService.applyDefaultFilter(sourceType, originalContent);
      }

      if (filteredContent == originalContent) {
        debugPrint('AdFilterEngine: 无需过滤');
        return null;
      }

      final rewritten = _rewriteUrls(filteredContent, originalUrl);
      final tempUrl = await _saveToTemp(rewritten);
      debugPrint('AdFilterEngine: 已过滤并保存到 $tempUrl');
      return tempUrl;
    } catch (e, stack) {
      debugPrint('AdFilterEngine: 过滤失败 $e');
      debugPrint('$stack');
      return null;
    }
  }

  static Future<String?> _applyCustomFilter(
    String type,
    String content,
    String code,
  ) async {
    try {
      _jsRuntime ??= getJavascriptRuntime();
      final runtime = _jsRuntime!;

      runtime.evaluate(code);
      final escapedContent = content
          .replaceAll('\\', '\\\\')
          .replaceAll("'", "\\'")
          .replaceAll('\n', '\\n');
      final result = runtime.evaluate("filterAdsFromM3U8('$type', '$escapedContent')");
      final filtered = result.stringResult;
      if (filtered.isEmpty || filtered == content) {
        debugPrint('AdFilterEngine: 自定义代码未返回有效结果，降级默认规则');
        return null;
      }
      debugPrint('AdFilterEngine: 已使用自定义去广告代码');
      return filtered.replaceAll('\\n', '\n');
    } catch (e, stack) {
      debugPrint('AdFilterEngine: 自定义代码执行失败 $e');
      debugPrint('$stack');
      return null;
    }
  }

  static String _rewriteUrls(String content, String baseUrl) {
    final baseUri = Uri.parse(baseUrl);
    final lines = content.split('\n');
    final result = <String>[];

    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('data:') ||
          trimmed.startsWith('http://') ||
          trimmed.startsWith('https://')) {
        result.add(line);
        continue;
      }
      final resolved = baseUri.resolve(trimmed).toString();
      result.add(resolved);
    }

    return result.join('\n');
  }

  static Future<String> _saveToTemp(String content) async {
    final dir = await getTemporaryDirectory();
    final prefix = '${dir.path}/hain_tv_filtered_';
    final now = DateTime.now();

    // 清理 1 小时前生成的旧过滤文件
    try {
      final tempDir = Directory(dir.path);
      if (await tempDir.exists()) {
        await for (final entity in tempDir.list()) {
          if (entity is File && entity.path.startsWith(prefix)) {
            final stat = await entity.stat();
            if (now.difference(stat.modified).inHours >= 1) {
              await entity.delete();
            }
          }
        }
      }
    } catch (e) {
      debugPrint('AdFilterEngine: 清理旧过滤文件失败 $e');
    }

    final file = File('${prefix}${now.millisecondsSinceEpoch}.m3u8');
    await file.writeAsString(content, encoding: utf8);
    return 'file://${file.path}';
  }

  static void dispose() {
    _jsRuntime?.dispose();
    _jsRuntime = null;
  }
}
