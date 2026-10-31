import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本地视频条目。
///
/// 描述一个已导入到应用沙箱内的本地视频文件。
class LocalVideoItem {
  /// 沙箱内绝对路径（原生复制后的路径）。
  final String path;

  /// 原始文件名（用于展示）。
  final String name;

  /// 文件字节数。
  final int size;

  /// 导入时间（毫秒时间戳）。
  final int addedAt;

  const LocalVideoItem({
    required this.path,
    required this.name,
    required this.size,
    required this.addedAt,
  });

  Map<String, dynamic> toJson() => {
    'path': path,
    'name': name,
    'size': size,
    'addedAt': addedAt,
  };

  factory LocalVideoItem.fromJson(Map<String, dynamic> json) {
    return LocalVideoItem(
      path: json['path']?.toString() ?? '',
      name: json['name']?.toString() ?? '本地视频',
      size: (json['size'] as num?)?.toInt() ?? 0,
      addedAt: (json['addedAt'] as num?)?.toInt() ?? 0,
    );
  }

  /// 播放 URL：本地文件走 `file://` 协议。
  String get playUrl => path.startsWith('file://') ? path : 'file://$path';
}

/// 本地视频列表变更通知器。
///
/// 添加/删除本地视频后通知首页刷新「我的本地视频」列表。
class LocalVideoListNotifier extends ChangeNotifier {
  LocalVideoListNotifier._();

  static final LocalVideoListNotifier instance = LocalVideoListNotifier._();

  void notify() => notifyListeners();
}

/// 本地视频库服务。
///
/// 【为什么需要它】
/// 应用为**用户自身单机使用**的工具，服务器是可选的。为保证「无服务器也能用」，
/// 这里提供本机视频的导入（系统文件选择器）、列表持久化与删除能力。
///
/// 【实现分工】
/// · 选文件 + 复制进沙箱：原生侧 `hain_tv/local_media` 通道（EntryAbility.ets）。
///   用户通过系统 DocumentViewPicker 选定文件，原生复制到应用私有目录，
///   因此**无需申请任何媒体读取权限**（选中的单文件由系统一次性授权）。
/// · 列表持久化：Dart 侧 SharedPreferences（只存路径与元信息，不存文件内容）。
class LocalVideoService {
  static const MethodChannel _channel = MethodChannel('hain_tv/local_media');
  static const String _prefsKey = 'local_video_library_v1';

  /// 调起系统文件选择器选择本地视频。
  ///
  /// 成功返回 [LocalVideoItem]；用户取消或选择失败返回 null。
  static Future<LocalVideoItem?> pickVideo() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'pickVideo',
      );
      if (raw == null) return null;
      final path = raw['path']?.toString() ?? '';
      if (path.isEmpty) return null;
      return LocalVideoItem(
        path: path,
        name: raw['name']?.toString() ?? '本地视频',
        size: (raw['size'] as num?)?.toInt() ?? 0,
        addedAt: DateTime.now().millisecondsSinceEpoch,
      );
    } on PlatformException catch (e) {
      throw Exception(e.message ?? '选择本地视频失败');
    } on MissingPluginException {
      // 非鸿蒙平台（无原生实现）直接返回 null，调用方按「不可用」处理。
      return null;
    }
  }

  /// 读取本地视频列表（按导入时间倒序）。
  static Future<List<LocalVideoItem>> list() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = json.decode(raw) as List<dynamic>;
      final items = decoded
          .map((e) => LocalVideoItem.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.addedAt.compareTo(a.addedAt));
      return items;
    } catch (_) {
      return [];
    }
  }

  /// 保存（新增或更新）本地视频条目。
  static Future<void> save(LocalVideoItem item) async {
    final items = await list();
    items.removeWhere((e) => e.path == item.path);
    items.insert(0, item);
    await _persist(items);
  }

  /// 移除条目，并删除沙箱内对应文件（尽力而为，失败不阻塞 UI）。
  static Future<void> remove(LocalVideoItem item) async {
    final items = await list();
    items.removeWhere((e) => e.path == item.path);
    await _persist(items);
    try {
      await _channel.invokeMethod<void>('deleteFile', {'path': item.path});
    } catch (_) {
      // 忽略：文件删除失败仅会残留磁盘占用。
    }
  }

  static Future<void> _persist(List<LocalVideoItem> items) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      json.encode(items.map((e) => e.toJson()).toList()),
    );
  }
}
