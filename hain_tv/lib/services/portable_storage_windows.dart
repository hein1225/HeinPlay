import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import '../utils/windows_logger.dart';

/// Windows 便携版存储配置。
///
/// 将 shared_preferences 与 path_provider 的默认路径从
/// `%APPDATA%\com.heinplay\海因影视` 重定向到软件 exe 同级目录下的 `data` 文件夹，
/// 实现删除软件目录即可清除所有用户数据。
class PortableStorageWindows {
  static late final String appDir;
  static late final String dataDir;
  static bool _initialized = false;

  static Future<void> initialize() async {
    if (_initialized) return;
    appDir = File(Platform.resolvedExecutable).parent.path;
    dataDir = p.join(appDir, 'data');

    // 优先使用软件 exe 同级目录作为便携数据目录；
    // 若该目录没有写入权限（如 Program Files），则回退到 %APPDATA%。
    if (!await _isDirectoryWritable(dataDir)) {
      final appData = Platform.environment['APPDATA'];
      if (appData != null && appData.isNotEmpty) {
        dataDir = p.join(appData, 'com.heinplay', 'hain_tv', 'data');
        debugPrint('PortableStorageWindows: exe 目录不可写，回退到 $dataDir');
      }
    }
    await Directory(dataDir).create(recursive: true);
    _initialized = true;
    WindowsLogger.log(
      'PortableStorageWindows',
      '初始化完成 dataDir=$dataDir',
    );
  }

  /// 检测目录是否存在且具有写入权限。
  static Future<bool> _isDirectoryWritable(String dir) async {
    try {
      final d = Directory(dir);
      if (!await d.exists()) {
        await d.create(recursive: true);
      }
      final testFile = File(p.join(dir, '.write_test'));
      await testFile.writeAsString('test', flush: true);
      await testFile.delete();
      return true;
    } catch (e) {
      return false;
    }
  }
}

/// 重定向 path_provider 到软件目录。
class PortablePathProviderWindows extends PathProviderPlatform {
  @override
  Future<String?> getTemporaryPath() async {
    final dir = p.join(PortableStorageWindows.dataDir, 'temp');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  @override
  Future<String?> getApplicationSupportPath() async {
    final dir = p.join(PortableStorageWindows.dataDir, 'support');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  @override
  Future<String?> getApplicationDocumentsPath() async {
    final dir = p.join(PortableStorageWindows.dataDir, 'documents');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  @override
  Future<String?> getApplicationCachePath() async {
    final dir = p.join(PortableStorageWindows.dataDir, 'cache');
    await Directory(dir).create(recursive: true);
    return dir;
  }

  @override
  Future<String?> getDownloadsPath() async {
    final dir = p.join(PortableStorageWindows.dataDir, 'downloads');
    await Directory(dir).create(recursive: true);
    return dir;
  }
}

/// 重定向 shared_preferences 到软件目录。
class PortableSharedPreferencesStore extends SharedPreferencesStorePlatform {
  final String _filePath;

  PortableSharedPreferencesStore()
    : _filePath = p.join(
        PortableStorageWindows.dataDir,
        'shared_preferences.json',
      );

  Map<String, Object>? _cache;

  Future<Map<String, Object>> _readAll() async {
    if (_cache != null) return _cache!;
    final file = File(_filePath);
    if (!await file.exists()) {
      _cache = {};
      WindowsLogger.log(
        'PortableSharedPreferencesStore',
        '文件不存在，使用空缓存 path=$_filePath',
      );
      return _cache!;
    }
    try {
      final content = await file.readAsString();
      final map = jsonDecode(content) as Map<String, dynamic>;
      _cache = map.cast<String, Object>();
      WindowsLogger.log(
        'PortableSharedPreferencesStore',
        '读取成功 keyCount=${_cache!.length}',
      );
    } catch (e) {
      WindowsLogger.log('PortableSharedPreferencesStore', '读取失败: $e');
      _cache = {};
    }
    return _cache!;
  }

  Future<bool> _writeAll(Map<String, Object> data) async {
    try {
      final file = File(_filePath);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
      WindowsLogger.log(
        'PortableSharedPreferencesStore',
        '写入成功 keyCount=${data.length}',
      );
      return true;
    } catch (e) {
      WindowsLogger.log('PortableSharedPreferencesStore', '写入失败: $e');
      return false;
    }
  }

  @override
  Future<Map<String, Object>> getAll() async => _readAll();

  @override
  Future<Map<String, Object>> getAllWithPrefix(String prefix) async {
    final all = await _readAll();
    return Map<String, Object>.fromEntries(
      all.entries.where((e) => e.key.startsWith(prefix)),
    );
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
    GetAllParameters parameters,
  ) async {
    final filter = parameters.filter;
    final all = await _readAll();
    return Map<String, Object>.fromEntries(
      all.entries.where(
        (e) =>
            e.key.startsWith(filter.prefix) &&
            (filter.allowList == null ||
                filter.allowList!.contains(e.key)),
      ),
    );
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    WindowsLogger.log(
      'PortableSharedPreferencesStore',
      'setValue key=$key valueType=$valueType',
    );
    final all = await _readAll();
    all[key] = value;
    _cache = all;
    return _writeAll(all);
  }

  @override
  Future<bool> remove(String key) async {
    final all = await _readAll();
    all.remove(key);
    _cache = all;
    return _writeAll(all);
  }

  @override
  Future<bool> clear() async {
    _cache = {};
    return _writeAll({});
  }

  @override
  Future<bool> clearWithPrefix(String prefix) async {
    final all = await _readAll();
    all.removeWhere((key, _) => key.startsWith(prefix));
    _cache = all;
    return _writeAll(all);
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    final all = await _readAll();
    all.removeWhere(
      (key, _) =>
          key.startsWith(filter.prefix) &&
          (filter.allowList == null || filter.allowList!.contains(key)),
    );
    _cache = all;
    return _writeAll(all);
  }
}
