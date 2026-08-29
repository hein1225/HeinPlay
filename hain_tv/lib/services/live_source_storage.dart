import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/live_source_config.dart';

/// 本地直播源配置持久化服务。
class LiveSourceStorage {
  static const String _key = 'live_source_configs';
  static const String _lastChannelKeyPrefix = 'live_last_channel_';

  static Future<SharedPreferences> _prefs() async {
    return SharedPreferences.getInstance();
  }

  /// 获取所有直播源配置，按 order 升序排列。
  static Future<List<LiveSourceConfig>> getConfigs() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_key);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      final configs = list
          .map((e) => LiveSourceConfig.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => a.order.compareTo(b.order));
      return configs;
    } catch (_) {
      return [];
    }
  }

  /// 保存单个配置；若已存在则更新，否则新增。
  static Future<void> saveConfig(LiveSourceConfig config) async {
    final configs = await getConfigs();
    final index = configs.indexWhere((c) => c.id == config.id);
    if (index >= 0) {
      configs[index] = config;
    } else {
      // 新配置放到末尾
      final maxOrder =
          configs.isEmpty ? 0 : configs.map((c) => c.order).reduce((a, b) => a > b ? a : b);
      configs.add(config.copyWith(order: maxOrder + 1));
    }
    await _saveAll(configs);
  }

  /// 删除指定配置。
  static Future<void> deleteConfig(String id) async {
    final configs = await getConfigs()..removeWhere((c) => c.id == id);
    await _saveAll(configs);
    // 同步清理该源记住的最近观看频道，避免残留脏数据。
    await clearLastChannel(id);
  }

  /// 批量更新配置顺序。
  static Future<void> reorderConfigs(List<LiveSourceConfig> configs) async {
    final ordered = List<LiveSourceConfig>.from(configs);
    for (int i = 0; i < ordered.length; i++) {
      ordered[i] = ordered[i].copyWith(order: i);
    }
    await _saveAll(ordered);
  }

  static Future<void> _saveAll(List<LiveSourceConfig> configs) async {
    final prefs = await _prefs();
    await prefs.setString(
      _key,
      json.encode(configs.map((e) => e.toJson()).toList()),
    );
  }

  /// 记住某个直播源上次退出时观看的频道，下次进入该源自动定位。
  /// [url] 为主播放地址，[name] 为频道名；两者用于源内频道列表变化时仍能尽量匹配。
  static Future<void> saveLastChannel(
    String sourceId,
    String url,
    String name,
  ) async {
    final prefs = await _prefs();
    await prefs.setString(
      '$_lastChannelKeyPrefix$sourceId',
      json.encode({'url': url, 'name': name}),
    );
  }

  /// 读取某直播源上次观看的频道（url + name），无记录返回 null。
  static Future<Map<String, String>?> getLastChannel(String sourceId) async {
    final prefs = await _prefs();
    final raw = prefs.getString('$_lastChannelKeyPrefix$sourceId');
    if (raw == null || raw.isEmpty) return null;
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      final url = map['url']?.toString() ?? '';
      final name = map['name']?.toString() ?? '';
      if (url.isEmpty && name.isEmpty) return null;
      return {'url': url, 'name': name};
    } catch (_) {
      return null;
    }
  }

  /// 清除某直播源记住的上次频道（如删除源时使用）。
  static Future<void> clearLastChannel(String sourceId) async {
    final prefs = await _prefs();
    await prefs.remove('$_lastChannelKeyPrefix$sourceId');
  }
}
