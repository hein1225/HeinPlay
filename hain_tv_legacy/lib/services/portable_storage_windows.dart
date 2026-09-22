import 'dart:async';
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

  /// 便携数据目录是否已就绪。
  ///
  /// [dataDir] 是 `late final`，未初始化时读取会抛异常；需要按平台判断能否
  /// 使用便携路径的调用方（如 `CacheService`）必须先查这个标志再取路径。
  static bool get isInitialized => _initialized;

  /// 便携目录下的统一缓存区（`data/cache`）。
  ///
  /// 这里只装**可再生成**的数据，删除整个目录不影响用户数据：
  /// - `cache/entries/` 派生缓存条目（频道列表/EPG/搜索/详情/豆瓣）
  /// - `cache/posters/` 海报图片
  ///
  /// 用户数据（登录态、服务器地址、设置、播放记录、收藏）仍留在
  /// `data/shared_preferences.json`；日志在 `data/app_logs/`（另有 7 天滚动）。
  static String get cacheDir => p.join(dataDir, 'cache');

  /// 当前生效的偏好存储实例，用于退出前强制刷盘。
  static PortableSharedPreferencesStore? _store;

  /// 注册偏好存储实例（在设置 [SharedPreferencesStorePlatform.instance] 后调用）。
  static void registerStore(PortableSharedPreferencesStore store) {
    _store = store;
  }

  /// 把去抖窗口内待落盘的偏好写入立即刷到磁盘。
  ///
  /// 偏好的整表写入带去抖（见 [PortableSharedPreferencesStore]），退出前必须刷一次，
  /// 否则用户在 300ms 内改完设置就关窗口时，改动可能丢失。
  static Future<void> flushPendingWrites() async {
    await _store?.flushNow();
  }

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
    // 临时文件与派生缓存同属「可再生成的数据」，统一收进 `data/cache/`：
    // 海报图片走 flutter_cache_manager（用本目录 + cacheKey 作子目录名），
    // 更新包等一次性临时文件也落在这里，删掉整个 cache 目录即可全清。
    final dir = PortableStorageWindows.cacheDir;
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
///
/// 性能要点（Windows 直播加载明显比安卓慢的根因）：
/// shared_preferences 的 `setValue` 语义是「整表重写」——本实现把整张表序列化成一个
/// JSON 文件。而便携版把「直播频道列表 + 节目单」这类大对象也交给 shared_preferences
/// 保管（单键 6MB+），于是**哪怕只写 82 字节的「上次观看频道」，也要把 7~8MB 的表重新
/// jsonEncode 并 flush 落盘**，同步编码直接阻塞主 isolate 1~2 秒；进入直播页时
/// `_loadChannels`（解码 6MB 缓存）+ `_saveCurrentChannel`（编码整表）正好连在一起，
/// 表现为「起播前明显卡一下」。安卓用原生 SharedPreferences 逐键增量写，写 82 字节
/// 是瞬时的，所以同一个 fvp 后端在安卓上起播很快。
///
/// 因此这里做两件事：
/// 1. **大值外置**：超过 [_bigValueThreshold] 的字符串值不再内联进主表，而是单独写
///    `data/prefs_big/<key>.txt`，主表只留一个引用。主表因此只剩几十~几百 KB，
///    「整表重写」的代价从秒级降到毫秒级；读表时也无需再 jsonDecode 那 6MB。
/// 2. **写入合并**：短时间内的多次写入（切台、EPG 刷新、缓存清理连续 remove）合并为
///    一次落盘，避免连续多次整表写入。
///
/// **不变式：`_cache`（内存）里永远是真实值，`__hain_bigref__` 只出现在落盘快照上。**
/// `getAll()` 的返回值会被 SharedPreferences 直接当作 `_preferenceCache` 使用，
/// 若把引用结构留在内存里，`getString(key)` 会因类型不符而读不到值。
class PortableSharedPreferencesStore extends SharedPreferencesStorePlatform {
  /// 超过该长度的字符串值改为外置存文件（256KB）。
  static const int _bigValueThreshold = 256 * 1024;

  /// 主表中代替外置值的引用标记键。
  static const String _bigRefKey = '__hain_bigref__';

  /// 外置值存放目录名（位于 exe 同级 data 目录下）。
  static const String _bigDirName = 'prefs_big';

  /// 写入去抖间隔：合并短时间内的多次写入，只落盘一次。
  static const Duration _writeDebounce = Duration(milliseconds: 300);

  final String _filePath;

  PortableSharedPreferencesStore()
    : _filePath = p.join(
        PortableStorageWindows.dataDir,
        'shared_preferences.json',
      );

  Map<String, Object>? _cache;

  /// 已落盘的外置大值指纹（key → 值指纹），用于避免重复写那几 MB 的文件。
  final Map<String, int> _bigWritten = {};

  /// 大值指纹：长度 + 内容散列。同一字符串在同一进程内稳定，
  /// 值未变即可安全跳过外置写盘。
  static int _fingerprint(String value) => Object.hash(value.length, value);

  /// 待落盘标记与去抖计时器。
  Timer? _writeTimer;
  bool _dirty = false;
  bool _writing = false;

  String get _bigDirPath =>
      p.join(PortableStorageWindows.dataDir, _bigDirName);

  /// 由 prefs key 推导外置文件名（base64url 编码，避免中文/特殊字符进文件名）。
  String _bigFileName(String key) {
    final encoded = base64Url.encode(utf8.encode(key)).replaceAll('=', '');
    return 'v_$encoded.txt';
  }

  Future<String?> _readBigValue(String name) async {
    try {
      final file = File(p.join(_bigDirPath, name));
      if (!await file.exists()) return null;
      return await file.readAsString();
    } catch (e) {
      WindowsLogger.log('PortableSharedPreferencesStore', '读取外置值失败 $name: $e');
      return null;
    }
  }

  Future<bool> _writeBigValue(String name, String value) async {
    try {
      final dir = Directory(_bigDirPath);
      await dir.create(recursive: true);
      await File(p.join(dir.path, name)).writeAsString(value, flush: true);
      return true;
    } catch (e) {
      WindowsLogger.log('PortableSharedPreferencesStore', '写入外置值失败 $name: $e');
      return false;
    }
  }

  Future<void> _deleteBigValue(String name) async {
    try {
      final file = File(p.join(_bigDirPath, name));
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 外置值删除失败不影响主流程（下次写入会覆盖同名文件）。
    }
  }

  /// 删除某键的外置文件（用于覆盖/删除/清理场景）。
  ///
  /// 文件名由 key 确定性推导，所以这里不去看内存里的值长什么样：读取时外置值
  /// 已被还原成真实字符串，若仍按「值是不是 `{__hain_bigref__: …}`」来判断就
  /// 删不到文件，会在 `prefs_big/` 里留下几 MB 的孤儿。
  Future<void> _detachBigIfAny(String key) async {
    // 指纹必须一起清掉：否则「值 A → 值 B → 值 A」时，第三轮会误以为 A 已落盘
    // 而跳过写文件，但文件早被删了，结果读到空值。
    _bigWritten.remove(key);
    await _deleteBigValue(_bigFileName(key));
  }

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
    final sw = Stopwatch()..start();
    try {
      final content = await file.readAsString();
      final map = (jsonDecode(content) as Map<String, dynamic>)
          .cast<String, Object>();
      // 还原外置大值；同时把旧版本内联的大字符串就地迁出，
      // 使升级后第一次启动即完成瘦身，后续写入不再背着重表。
      var restored = 0;
      var migrated = 0;
      for (final entry in map.entries.toList()) {
        final value = entry.value;
        if (value is Map && value[_bigRefKey] is String) {
          final big = await _readBigValue(value[_bigRefKey] as String);
          if (big != null) {
            map[entry.key] = big;
            // 登记指纹：内容没变的话，后续整表写入不必重写这个文件。
            _bigWritten[entry.key] = _fingerprint(big);
            restored++;
          } else {
            map.remove(entry.key);
          }
        } else if (value is String && value.length > _bigValueThreshold) {
          // 内联大值：**内存里必须保留真字符串**，不能就地换成 `__hain_bigref__`。
          // `getAll()` 的返回值会被 SharedPreferences 直接当成 `_preferenceCache`，
          // 一旦这里塞进去的是 Map，`prefs.getString(key)` 就会类型不符拿不到值
          // （表现为频道缓存读不出、缓存迁移漏掉该键）。
          // 外置只发生在落盘快照上，由 _externalizeBigValues 统一处理，
          // 这里只需标记「需要回写一次」让主表完成瘦身。
          migrated++;
        }
      }
      _cache = map;
      if (migrated > 0) {
        unawaited(_writeAll(map));
      }
      WindowsLogger.log(
        'PortableSharedPreferencesStore',
        '读取成功 keyCount=${map.length} 外置还原=$restored 迁移=$migrated '
            '耗时=${sw.elapsedMilliseconds}ms',
      );
    } catch (e) {
      WindowsLogger.log('PortableSharedPreferencesStore', '读取失败: $e');
      _cache = {};
    }
    return _cache!;
  }

  /// 调度一次整表写入（去抖合并，短时间内多次调用只落盘一次）。
  Future<bool> _writeAll(Map<String, Object> data) {
    _dirty = true;
    _writeTimer?.cancel();
    _writeTimer = Timer(_writeDebounce, () => unawaited(_flushWrite()));
    return Future.value(true);
  }

  /// 跳过去抖立即落盘（退出前调用，避免去抖窗口内的改动丢失）。
  Future<void> flushNow() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    var guard = 0;
    while ((_writing || _dirty) && guard < 50) {
      guard++;
      if (!_writing && _dirty) {
        await _flushWrite();
      } else {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    }
  }

  /// 写盘前把超过阈值的大字符串重新外置，保证主表始终是「瘦」的。
  ///
  /// 读取时外置值会被还原成真实字符串放进内存缓存（`getAll()` 必须返回真值），
  /// 若这里不重新外置，下一次整表写入又会把它内联回主表，让「写 82 字节的偏好
  /// 也要序列化好几 MB」的老问题复发。只改用于落盘的快照，不动内存缓存。
  ///
  /// 用 [_bigWritten] 记录「已落盘值的指纹」，值没变就直接改快照、跳过写盘——
  /// 否则每次整表写入（切台、存播放进度都会触发）都要重写那几 MB 的外置文件，
  /// 等于把刚消掉的卡顿又原样搬回来。
  Future<void> _externalizeBigValues(Map<String, Object> snapshot) async {
    for (final entry in snapshot.entries.toList()) {
      final value = entry.value;
      if (value is String && value.length > _bigValueThreshold) {
        final ref = _bigFileName(entry.key);
        final fp = _fingerprint(value);
        if (_bigWritten[entry.key] != fp) {
          if (await _writeBigValue(ref, value)) {
            _bigWritten[entry.key] = fp;
          } else {
            continue; // 写失败则保持内联，宁可信件变大也不能丢值。
          }
        }
        snapshot[entry.key] = {_bigRefKey: ref};
      }
    }
  }

  Future<void> _flushWrite() async {
    if (_writing) return;
    _writing = true;
    try {
      // 写盘期间若又有新写入，最多再补一轮，保证最终落盘的是最新内容。
      var rounds = 0;
      while (_dirty && rounds < 8) {
        rounds++;
        _dirty = false;
        final snapshot = Map<String, Object>.from(
          _cache ?? const <String, Object>{},
        );
        await _externalizeBigValues(snapshot);
        final text = jsonEncode(snapshot);
        final file = File(_filePath);
        await file.parent.create(recursive: true);
        await file.writeAsString(text, flush: true);
        WindowsLogger.log(
          'PortableSharedPreferencesStore',
          '写入成功 keyCount=${snapshot.length} size=${text.length}',
        );
      }
    } catch (e) {
      WindowsLogger.log('PortableSharedPreferencesStore', '写入失败: $e');
    } finally {
      _writing = false;
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
    // 旧外置文件先作废：新值若仍是「大字符串」，落盘快照会按同一文件名重建；
    // 若新值变小或换了类型，则不再重建，正好把过期文件清掉。
    await _detachBigIfAny(key);
    // 内存缓存一律存真值（见类文档「大值外置」）。大值推迟到落盘快照再外置，
    // 由 _externalizeBigValues 统一处理，保证 getString(key) 任何时候都拿得到内容。
    all[key] = value;
    _cache = all;
    return _writeAll(all);
  }

  @override
  Future<bool> remove(String key) async {
    final all = await _readAll();
    await _detachBigIfAny(key);
    all.remove(key);
    _cache = all;
    return _writeAll(all);
  }

  @override
  Future<bool> clear() async {
    _cache = {};
    _bigWritten.clear();
    try {
      final dir = Directory(_bigDirPath);
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {
      // 忽略目录删除异常（不可写时下次写入会重建）。
    }
    return _writeAll(_cache!);
  }

  @override
  Future<bool> clearWithPrefix(String prefix) async {
    final all = await _readAll();
    for (final key in all.keys.where((k) => k.startsWith(prefix)).toList()) {
      await _detachBigIfAny(key);
    }
    all.removeWhere((key, _) => key.startsWith(prefix));
    _cache = all;
    return _writeAll(all);
  }

  @override
  Future<bool> clearWithParameters(ClearParameters parameters) async {
    final filter = parameters.filter;
    final all = await _readAll();
    bool matches(String key) =>
        key.startsWith(filter.prefix) &&
        (filter.allowList == null || filter.allowList!.contains(key));
    for (final key in all.keys.where(matches).toList()) {
      await _detachBigIfAny(key);
    }
    all.removeWhere((key, _) => matches(key));
    _cache = all;
    return _writeAll(all);
  }
}
