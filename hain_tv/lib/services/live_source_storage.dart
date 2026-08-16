import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/live_source_config.dart';

/// 本地直播源配置持久化服务。
class LiveSourceStorage {
  static const String _key = 'live_source_configs';

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
}
