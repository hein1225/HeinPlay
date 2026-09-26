import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/windows_logger.dart';
import 'cache_service.dart';
import 'hain_tv_cache_manager.dart';
import 'local_storage_service.dart';
import 'update_service.dart';

/// 应用版本迁移服务。
///
/// 每次启动时对比当前版本与上次启动保存的版本：
/// - 首次安装：只记录版本号，不清理缓存。
/// - 版本升级：自动清理旧缓存（图片缓存、SharedPreferences 业务缓存、临时文件等），
///   但保留用户数据（播放记录、收藏、搜索历史、设置等）。
class VersionMigrationService {
  static const String _lastVersionKey = 'app_last_version';

  /// 执行版本迁移检查与缓存清理。
  static Future<void> migrate() async {
    final prefs = await SharedPreferences.getInstance();
    final lastVersion = prefs.getString(_lastVersionKey);
    final currentVersion = UpdateService.currentVersion;

    debugPrint('[VersionMigration] 当前版本=$currentVersion, 上次版本=$lastVersion');
    if (Platform.isWindows) {
      WindowsLogger.log('VersionMigration', '当前版本=$currentVersion, 上次版本=$lastVersion');
    }

    if (lastVersion == null) {
      // 首次安装，记录版本号即可。
      await prefs.setString(_lastVersionKey, currentVersion);
      debugPrint('[VersionMigration] 首次安装，无需清理旧缓存');
      if (Platform.isWindows) {
        WindowsLogger.log('VersionMigration', '首次安装，无需清理旧缓存');
      }
      return;
    }

    if (lastVersion == currentVersion) {
      debugPrint('[VersionMigration] 版本未变化，跳过缓存清理');
      return;
    }

    debugPrint('[VersionMigration] 检测到版本升级 $lastVersion -> $currentVersion，开始清理旧缓存');
    if (Platform.isWindows) {
      WindowsLogger.log('VersionMigration', '版本升级 $lastVersion -> $currentVersion，开始清理旧缓存');
    }

    // 1. 清理 SharedPreferences 中的业务缓存（不会误删用户设置/数据）。
    try {
      await CacheService().clear();
      debugPrint('[VersionMigration] CacheService 清理完成');
    } catch (e) {
      debugPrint('[VersionMigration] CacheService 清理失败: $e');
    }

    // 2. 清理分辨率分析缓存。
    try {
      await LocalStorageService.clearSourceResolutionCache();
      debugPrint('[VersionMigration] 分辨率缓存清理完成');
    } catch (e) {
      debugPrint('[VersionMigration] 分辨率缓存清理失败: $e');
    }

    // 3. 清理图片缓存。
    try {
      await DefaultCacheManager().emptyCache();
      await HainTvCacheManager().emptyCache();
      debugPrint('[VersionMigration] 图片缓存清理完成');
    } catch (e) {
      debugPrint('[VersionMigration] 图片缓存清理失败: $e');
    }

    // 4. 清理临时目录中**属于本 App 的**内容。
    //
    // ⚠️ `getTemporaryDirectory()` 的平台语义差别极大，不能一律整目录清空：
    //   - Android / ohos / Windows 便携版：返回的**就是** App 专属缓存目录
    //     （Android 为 `getCacheDir()`；Windows 便携版由 `PortablePathProviderWindows`
    //     映射到 `data/cache`），与 `getApplicationCacheDirectory()` 为**同一路径**，
    //     整清安全 —— 且已由第 5 步完成，此处直接跳过以免重复清理。
    //   - Linux：返回 `$TMPDIR`，通常就是 **`/tmp` 这个系统级共享目录**，其中混有
    //     Steam、mangohud、gamescope-limiter、AppImage 挂载点、`.X11-unix` 等
    //     **其他程序**的文件。此处原先做整目录删除，实测本次迁移日志刷出 105 条
    //     「删除失败」（多数因权限侥幸逃过，属当前用户的会被真删）。
    //   - macOS：`NSTemporaryDirectory()`（`/var/folders/.../T/`，同一用户下共享）。
    //
    // 因此：仅当临时目录与应用缓存目录是同一路径时才整清（交给第 5 步）；
    // 不同路径时（Linux/macOS）只按**白名单**删除本 App 自己创建的子目录与一次性文件。
    try {
      final tempDir = await getTemporaryDirectory();
      final appCacheDir = await getApplicationCacheDirectory();
      if (p.equals(tempDir.path, appCacheDir.path)) {
        debugPrint('[VersionMigration] 临时目录即应用缓存目录，跳过（由第 5 步统一清理）');
      } else {
        final removed = await _deleteOwnTempEntries(tempDir);
        debugPrint('[VersionMigration] 共享临时目录白名单清理完成: ${tempDir.path}，移除 $removed 项');
      }
    } catch (e) {
      debugPrint('[VersionMigration] 临时目录清理失败: $e');
    }

    // 5. 清理应用缓存目录内容（App 专属目录，整清安全）。
    try {
      final cacheDir = await getApplicationCacheDirectory();
      await _deleteDirectoryContents(cacheDir);
      debugPrint('[VersionMigration] 应用缓存目录清理完成: ${cacheDir.path}');
    } catch (e) {
      debugPrint('[VersionMigration] 应用缓存目录清理失败: $e');
    }

    // 6. 清理 Flutter 运行时图片缓存。
    try {
      final imageCache = PaintingBinding.instance.imageCache;
      imageCache.clear();
      imageCache.clearLiveImages();
      debugPrint('[VersionMigration] 运行时图片缓存清理完成');
    } catch (e) {
      debugPrint('[VersionMigration] 运行时图片缓存清理失败: $e');
    }

    // 记录当前版本号，避免重复清理。
    await prefs.setString(_lastVersionKey, currentVersion);
    debugPrint('[VersionMigration] 版本号已更新为 $currentVersion');
    if (Platform.isWindows) {
      WindowsLogger.log('VersionMigration', '旧缓存清理完成，版本号已更新为 $currentVersion');
    }
  }

  /// 删除目录下的所有子文件/子目录，但不删除目录本身。
  ///
  /// 仅用于 **App 专属目录**（应用缓存目录、Windows 便携版 `data/cache`）。调用前会做
  /// [_isProtectedPath] 守卫：若 path_provider 因环境异常返回了过泛的路径（例如应用 ID
  /// 解析失败时 `~/.cache/<id>` 会退化成 `~/.cache` 本身），则拒绝清理并留下日志。
  static Future<void> _deleteDirectoryContents(Directory dir) async {
    if (!await dir.exists()) return;
    if (_isProtectedPath(dir.path)) {
      debugPrint('[VersionMigration] ⚠️ 拒绝清空过泛的目录（保护其他程序数据）: ${dir.path}');
      return;
    }
    await for (final entity in dir.list(followLinks: false)) {
      try {
        if (entity is Directory) {
          await entity.delete(recursive: true);
        } else if (entity is File) {
          await entity.delete();
        }
      } catch (e) {
        debugPrint('[VersionMigration] 删除失败 ${entity.path}: $e');
      }
    }
  }

  /// 本 App 在**系统共享临时目录**（Linux 的 `/tmp` 等）中创建的子目录名（白名单）。
  ///
  /// 白名单之外的一切条目一律不碰 —— 共享临时目录里绝大多数文件属于其他程序。
  static const List<String> _ownTempDirs = <String>[
    'libCachedImageData', // flutter_cache_manager 的 DefaultCacheManager（key 即目录名）
    'hainTvCache', // HainTvCacheManager.key
  ];

  /// 本 App 在系统共享临时目录中创建的一次性文件名前缀（白名单）。
  static const List<String> _ownTempFilePrefixes = <String>[
    'hain_tv_update_', // UpdateService 下载的更新包 hain_tv_update_<version>.apk
  ];

  /// 只删除本 App 在共享临时目录中创建的子目录/文件，返回实际移除的条数。
  ///
  /// 与 [_deleteDirectoryContents] 的区别：**只删白名单命中的条目**，不遍历删除其余内容。
  static Future<int> _deleteOwnTempEntries(Directory dir) async {
    if (!await dir.exists()) return 0;
    var removed = 0;
    await for (final entity in dir.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final isOwn = (entity is Directory && _ownTempDirs.contains(name)) ||
          (entity is File && _ownTempFilePrefixes.any(name.startsWith));
      if (!isOwn) continue;
      try {
        await entity.delete(recursive: true);
        removed++;
      } catch (e) {
        debugPrint('[VersionMigration] 删除失败 ${entity.path}: $e');
      }
    }
    return removed;
  }

  /// 该路径是否属于「不允许整体清空」的过泛目录。
  ///
  /// 纵深防御：即使上游路径解析出人意料的浅（`/`、`/tmp`、家目录、`~/.cache` …），
  /// 也绝不整目录删除，避免误删同机其他程序的数据。
  static bool _isProtectedPath(String path) {
    final unified = _normalizeForCompare(path);
    if (unified.isEmpty) return true;
    if (_protectedRoots.contains(unified)) return true;
    // 家目录本身，以及家目录下的通用共享目录（不含 App 专属子目录）。
    final home = _homeDir;
    if (home != null && home.isNotEmpty) {
      if (unified == home) return true;
      for (final sub in _protectedHomeSubdirs) {
        if (unified == '$home$sub') return true;
      }
    }
    return false;
  }

  /// 规范化路径用于比较：绝对化 → 归一化 → 统一分隔符 → 去尾斜杠 → 小写。
  static String _normalizeForCompare(String path) {
    final normalized = p.normalize(p.absolute(path));
    final unified = normalized
        .replaceAll('\\', '/')
        .replaceAll(RegExp(r'/+$'), '');
    return unified.toLowerCase();
  }

  /// 规范化后的家目录（小写、统一分隔符）；无法确定时为 null。
  static final String? _homeDir = () {
    final raw = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
    if (raw == null || raw.isEmpty) return null;
    final unified = _normalizeForCompare(raw);
    return unified.isEmpty ? null : unified;
  }();

  /// 系统根与共享目录：整目录清空会破坏系统或其他程序。
  static const Set<String> _protectedRoots = <String>{
    '/',
    '/tmp',
    '/var',
    '/var/tmp',
    '/usr',
    '/etc',
    '/opt',
    '/home',
    '/root',
    '/mnt',
    '/media',
    '/dev',
    '/proc',
    '/sys',
    '/run',
    'c:/',
    'c:/windows',
    'c:/users',
    'c:/program files',
    'c:/program files (x86)',
  };

  /// 家目录下属于「其他程序也会用」的共享目录（不含本 App 的专属子目录，
  /// 如 `~/.cache/<appId>`、`~/.local/share/<appId>` 均可正常整清）。
  static const List<String> _protectedHomeSubdirs = <String>[
    '/.cache',
    '/.config',
    '/.local',
    '/.local/share',
    '/.ssh',
    '/.gnupg',
    '/documents',
    '/downloads',
    '/desktop',
  ];
}
