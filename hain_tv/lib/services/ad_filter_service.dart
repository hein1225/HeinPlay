import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'user_data_service.dart';

class AdFilterService {
  static const String _adFilterVersionKey = 'ad_filter_version';
  static const String _adFilterCodeKey = 'ad_filter_code';
  static const String _adFilterEnabledKey = 'ad_filter_enabled';

  static final List<String> _defaultAdKeywords = const [
    'sponsor',
    '/ad/',
    '/ads/',
    'advert',
    'advertisement',
    '/adjump',
    'redtraffic',
  ];

  static final List<String> _defaultAdMarkers = const [
    '#EXT-X-CUE-OUT',
    '#EXT-X-SCTE35',
    '#EXT-OATCLS-SCTE35',
  ];

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    // 默认关闭，避免默认规则误伤正常播放；用户可在设置中手动开启
    return prefs.getBool(_adFilterEnabledKey) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_adFilterEnabledKey, enabled);
  }

  static Future<String?> getCachedCode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_adFilterCodeKey);
  }

  static Future<int> getCachedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_adFilterVersionKey) ?? 0;
  }

  static Future<void> _saveCache(int version, String code) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_adFilterVersionKey, version);
    await prefs.setString(_adFilterCodeKey, code);
  }

  static Future<void> checkAndUpdate() async {
    final serverUrl = await UserDataService.getServerUrl();
    if (serverUrl == null || serverUrl.isEmpty) return;

    try {
      final baseUrl = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
      final versionUrl = '${baseUrl}api/ad-filter';
      debugPrint('AdFilterService: 检查去广告版本 $versionUrl');

      final versionResponse = await http
          .get(Uri.parse(versionUrl), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (versionResponse.statusCode != 200) {
        debugPrint('AdFilterService: 版本检查失败 ${versionResponse.statusCode}');
        return;
      }

      final versionJson = jsonDecode(versionResponse.body) as Map<String, dynamic>;
      final remoteVersion = (versionJson['version'] as num?)?.toInt() ?? 0;
      final cachedVersion = await getCachedVersion();
      debugPrint('AdFilterService: 远程版本 $remoteVersion, 本地版本 $cachedVersion');

      if (remoteVersion <= cachedVersion) return;

      final fullUrl = '$versionUrl?full=true';
      final fullResponse = await http
          .get(Uri.parse(fullUrl), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));

      if (fullResponse.statusCode != 200) {
        debugPrint('AdFilterService: 完整代码获取失败 ${fullResponse.statusCode}');
        return;
      }

      final fullJson = jsonDecode(fullResponse.body) as Map<String, dynamic>;
      final code = (fullJson['code'] as String?) ?? '';
      await _saveCache(remoteVersion, code);
      debugPrint('AdFilterService: 已更新去广告代码到版本 $remoteVersion');
    } catch (e, stack) {
      debugPrint('AdFilterService: 检查更新失败 $e');
      debugPrint('$stack');
    }
  }

  static String applyDefaultFilter(String type, String m3u8Content) {
    if (m3u8Content.isEmpty) return m3u8Content;

    final lines = m3u8Content.split('\n');
    final filteredLines = <String>[];
    var inAdBlock = false;

    var i = 0;
    while (i < lines.length) {
      final line = lines[i];

      if (_defaultAdMarkers.any((m) => line.contains(m))) {
        inAdBlock = true;
        i++;
        continue;
      }

      if (line.contains('#EXT-X-CUE-IN')) {
        inAdBlock = false;
        i++;
        continue;
      }

      if (inAdBlock) {
        i++;
        continue;
      }

      if (line.contains('#EXT-X-DISCONTINUITY')) {
        i++;
        continue;
      }

      if (line.contains('#EXTINF:') && i + 1 < lines.length) {
        final nextLine = lines[i + 1];
        final containsAd = _defaultAdKeywords.any(
          (k) => nextLine.toLowerCase().contains(k.toLowerCase()),
        );
        if (containsAd) {
          i += 2;
          continue;
        }
      }

      filteredLines.add(line);
      i++;
    }

    return filteredLines.join('\n');
  }
}
