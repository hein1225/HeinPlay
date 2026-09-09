import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/live_source_config.dart';

/// 本地直播源配置持久化服务。
class LiveSourceStorage {
  static const String _key = 'live_source_configs';
  static const String _lastChannelKeyPrefix = 'live_last_channel_';

  /// 服务端（内置）直播源的手动排序映射：sourceId -> 组内位置。
  /// 内置源每次从服务端实时拉取，无法像用户源那样整体持久化，
  /// 因此单独用一份 id->order 映射来记录用户的手动排序结果。
  static const String _builtinOrderKey = 'live_source_builtin_order';

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

  /// 读取服务端（内置）直播源的手动排序映射。
  static Future<Map<String, int>> getBuiltinOrderMap() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_builtinOrderKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final map = json.decode(raw) as Map<String, dynamic>;
      return map.map((k, v) => MapEntry(k, (v as num).toInt()));
    } catch (_) {
      return {};
    }
  }

  /// 持久化服务端（内置）直播源的手动排序结果（按列表下标写入 id->order）。
  static Future<void> saveBuiltinOrder(List<LiveSourceConfig> builtins) async {
    final map = <String, int>{};
    for (int i = 0; i < builtins.length; i++) {
      map[builtins[i].id] = i;
    }
    final prefs = await _prefs();
    await prefs.setString(_builtinOrderKey, json.encode(map));
  }

  /// 对「内置源在前、用户源在后」的组合列表执行分段感知重排。
  ///
  /// 拖拽/长按排序时调用：内置源只在内置段内移动，用户源只在用户段内移动，
  /// 两类源不互相穿插（[newIndex] 会被夹取到所属段内）。
  static Future<void> reorderCombined(
    List<LiveSourceConfig> combined,
    int oldIndex,
    int newIndex,
  ) async {
    final b = combined.where((c) => c.isBuiltin).length;
    final total = combined.length;
    if (oldIndex < b) {
      final newClamped = newIndex.clamp(0, b - 1);
      if (newClamped == oldIndex) return;
      final builtins = combined.where((c) => c.isBuiltin).toList();
      final item = builtins.removeAt(oldIndex);
      builtins.insert(newClamped, item);
      await saveBuiltinOrder(builtins);
    } else {
      final newClamped = (newIndex - b).clamp(0, total - b - 1);
      final userOld = oldIndex - b;
      if (newClamped == userOld) return;
      final users = combined.where((c) => !c.isBuiltin).toList();
      final item = users.removeAt(userOld);
      users.insert(newClamped, item);
      await reorderConfigs(users);
    }
  }

  /// 在组合列表中把 [index] 处的项向上(delta=-1)/向下(delta=+1)移动一格（仅段内）。
  ///
  /// TV 版「排序模式」的上下移动调用：超出段边界时自动停在该段首尾。
  static Future<void> moveCombined(
    List<LiveSourceConfig> combined,
    int index,
    int delta,
  ) async {
    final b = combined.where((c) => c.isBuiltin).length;
    final total = combined.length;
    if (index < b) {
      final target = (index + delta).clamp(0, b - 1);
      if (target == index) return;
      final builtins = combined.where((c) => c.isBuiltin).toList();
      final item = builtins.removeAt(index);
      builtins.insert(target, item);
      await saveBuiltinOrder(builtins);
    } else {
      final users = combined.where((c) => !c.isBuiltin).toList();
      final userIndex = index - b;
      final target = (userIndex + delta).clamp(0, users.length - 1);
      if (target == userIndex) return;
      final item = users.removeAt(userIndex);
      users.insert(target, item);
      await reorderConfigs(users);
    }
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
