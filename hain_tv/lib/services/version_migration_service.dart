import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
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

    // 4. 清理临时目录内容。
    try {
      final tempDir = await getTemporaryDirectory();
      await _deleteDirectoryContents(tempDir);
      debugPrint('[VersionMigration] 临时目录清理完成: ${tempDir.path}');
    } catch (e) {
      debugPrint('[VersionMigration] 临时目录清理失败: $e');
    }

    // 5. 清理应用缓存目录内容。
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
  static Future<void> _deleteDirectoryContents(Directory dir) async {
    if (!await dir.exists()) return;
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
}
