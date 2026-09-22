import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/windows_logger.dart';

/// 缓存条目的存储后端。
///
/// `CacheService` 只依赖这个抽象，不关心条目最终落在偏好表还是便携目录文件里。
/// 键值一律是「已序列化好的字符串」（形如 `{"expiresAt":…,"data":…}`），
/// 后端不做任何解析，只负责存取与滚动淘汰。
abstract class LocalCacheStore {
  /// 读取条目的原始字符串；不存在返回 null。
  Future<String?> read(String key);

  /// 写入（覆盖）条目。
  Future<void> write(String key, String value);

  /// 删除条目。
  Future<void> remove(String key);

  /// 列出当前全部键。
  Future<List<String>> keys();

  /// 清空本后端的所有条目。
  Future<void> clear();

  /// 淘汰「超过 [maxAge] 未被使用」的条目，返回删除数量。
  ///
  /// 这是 TTL 之外的兜底滚动：条目自带的 `expiresAt` 由 `CacheService`
  /// 在读取时判定，但长期不被读取的条目永远不会触发那次判定，会一直占着空间。
  Future<int> prune(Duration maxAge);
}

/// 偏好表后端（非便携平台默认，也是 Windows 上「用户数据镜像」的落点）。
///
/// 走平台原生 SharedPreferences：安卓/TV 是逐键增量写，本就很轻；
/// 滚动淘汰由条目自身的 TTL 负责，故 [prune] 恒返回 0。
class PrefsCacheStore implements LocalCacheStore {
  const PrefsCacheStore();

  @override
  Future<String?> read(String key) async {
    // 用 get() 而非 getString()：后者内部是 `cache[key] as String?`，
    // 一旦该键存的是 bool/int 就直接抛类型异常。缓存后端只关心字符串值，
    // 非字符串一律按「无此条目」处理。
    final value = (await SharedPreferences.getInstance()).get(key);
    return value is String ? value : null;
  }

  @override
  Future<void> write(String key, String value) async {
    await (await SharedPreferences.getInstance()).setString(key, value);
  }

  @override
  Future<void> remove(String key) async {
    await (await SharedPreferences.getInstance()).remove(key);
  }

  @override
  Future<List<String>> keys() async =>
      (await SharedPreferences.getInstance()).getKeys().toList();

  @override
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys().toList()) {
      await prefs.remove(key);
    }
  }

  @override
  Future<int> prune(Duration maxAge) async => 0;
}

/// 便携目录文件后端（Windows 便携版）。
///
/// 一条缓存 = 一个文件：`data/cache/entries/v_<base64url(key)>.json`。
///
/// 为什么不用偏好表：`shared_preferences` 的写入语义是「整表重写」，而便携版
/// 曾把频道列表+EPG（单键 5.6MB）也塞进这张表，导致**只写 82 字节的「上次频道」
/// 也要重新序列化 7.5MB**，同步编码阻塞主 isolate 1~2 秒（Windows 直播起播
/// 明显慢于安卓的根因）。落到独立文件后，每条缓存各写各的，互不牵连。
///
/// 文件名用 base64url 编码：键里含中文（如 `lunatv_search_all_交锋`）与
/// 点号（`lunatv_detail_bfzy.tv_161456`），不能直接做文件名；编码可逆，
/// 于是列键/按前缀匹配无需读取文件内容。
class FileCacheStore implements LocalCacheStore {
  FileCacheStore(this.rootDir);

  /// 缓存根目录（便携版为 `data/cache`）。
  final String rootDir;

  /// 条目子目录名。
  static const String entryDirName = 'entries';

  static const String _filePrefix = 'v_';
  static const String _fileSuffix = '.json';

  /// 距上次写入超过该时长，才在读取时刷新文件的修改时间。
  ///
  /// [prune] 以「修改时间」近似「最后使用时间」，读取时刷新它才能让
  /// 「7 天没被用过」的判定成立。设成间隔刷新是为了避免每次读缓存都去写
  /// 文件元数据（频道列表几乎每次进直播页都读）。
  static const Duration _touchInterval = Duration(hours: 12);

  String get entryDir => p.join(rootDir, entryDirName);

  /// 键 → 文件名。
  static String encodeName(String key) =>
      '$_filePrefix${base64Url.encode(utf8.encode(key)).replaceAll('=', '')}'
      '$_fileSuffix';

  /// 文件名 → 键；不是本后端生成的文件返回 null。
  static String? decodeName(String fileName) {
    if (!fileName.startsWith(_filePrefix) ||
        !fileName.endsWith(_fileSuffix)) {
      return null;
    }
    final body = fileName.substring(
      _filePrefix.length,
      fileName.length - _fileSuffix.length,
    );
    try {
      final padding = (4 - body.length % 4) % 4;
      return utf8.decode(base64Url.decode(body + '=' * padding));
    } catch (_) {
      return null;
    }
  }

  File _fileOf(String key) => File(p.join(entryDir, encodeName(key)));

  @override
  Future<String?> read(String key) async {
    final file = _fileOf(key);
    try {
      final stat = await file.stat();
      if (stat.type == FileSystemEntityType.notFound) return null;
      final text = await file.readAsString();
      if (DateTime.now().difference(stat.modified) > _touchInterval) {
        unawaited(_touch(file));
      }
      return text;
    } catch (e) {
      WindowsLogger.log('FileCacheStore', '读取失败 key=$key: $e');
      return null;
    }
  }

  Future<void> _touch(File file) async {
    try {
      await file.setLastModified(DateTime.now());
    } catch (_) {
      // 刷新访问时间失败不影响读取结果。
    }
  }

  @override
  Future<void> write(String key, String value) async {
    try {
      final dir = Directory(entryDir);
      if (!await dir.exists()) await dir.create(recursive: true);
      await _fileOf(key).writeAsString(value, flush: true);
    } catch (e) {
      WindowsLogger.log('FileCacheStore', '写入失败 key=$key: $e');
    }
  }

  @override
  Future<void> remove(String key) async {
    try {
      final file = _fileOf(key);
      if (await file.exists()) await file.delete();
    } catch (_) {
      // 删除失败可容忍：同名文件会在下次写入时被覆盖。
    }
  }

  @override
  Future<List<String>> keys() async {
    final dir = Directory(entryDir);
    if (!await dir.exists()) return const [];
    final result = <String>[];
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        final key = decodeName(p.basename(entity.path));
        if (key != null) result.add(key);
      }
    } catch (e) {
      WindowsLogger.log('FileCacheStore', '列键失败: $e');
    }
    return result;
  }

  @override
  Future<void> clear() async {
    try {
      final dir = Directory(entryDir);
      if (await dir.exists()) await dir.delete(recursive: true);
      WindowsLogger.log('FileCacheStore', '已清空缓存目录 $entryDir');
    } catch (e) {
      WindowsLogger.log('FileCacheStore', '清空失败: $e');
    }
  }

  @override
  Future<int> prune(Duration maxAge) async {
    final dir = Directory(entryDir);
    if (!await dir.exists()) return 0;
    final deadline = DateTime.now().subtract(maxAge);
    var removed = 0;
    try {
      await for (final entity in dir.list()) {
        if (entity is! File) continue;
        try {
          final stat = await entity.stat();
          if (stat.modified.isBefore(deadline)) {
            await entity.delete();
            removed++;
          }
        } catch (_) {
          // 单个文件删除失败不影响其余条目。
        }
      }
    } catch (e) {
      WindowsLogger.log('FileCacheStore', '滚动淘汰失败: $e');
    }
    return removed;
  }
}
