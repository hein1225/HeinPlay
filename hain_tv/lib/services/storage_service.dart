import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// 存储管理服务：处理权限请求和缓存目录管理
class StorageService {
  /// 请求存储权限（Android）
  static Future<bool> requestStoragePermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.storage.request();
      return status.isGranted || status.isLimited;
    }
    return true;
  }

  /// 检查存储权限状态
  static Future<bool> checkStoragePermission() async {
    if (Platform.isAndroid) {
      final status = await Permission.storage.status;
      return status.isGranted || status.isLimited;
    }
    return true;
  }

  /// 获取应用缓存目录（用于缓存大小统计和清理）
  static Future<Directory?> getCacheDirectory() async {
    try {
      return await getTemporaryDirectory();
    } catch (e) {
      return null;
    }
  }

  /// 获取缓存大小（字节）
  static Future<int> getCacheSize() async {
    try {
      final cacheDir = await getCacheDirectory();
      if (cacheDir == null || !await cacheDir.exists()) return 0;
      int totalSize = 0;
      await for (final entity in cacheDir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is File) {
          totalSize += await entity.length();
        }
      }
      return totalSize;
    } catch (e) {
      return 0;
    }
  }

  /// 格式化缓存大小为可读字符串
  static String formatCacheSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 清理应用缓存
  static Future<void> clearCache() async {
    try {
      final cacheDir = await getCacheDirectory();
      if (cacheDir != null && await cacheDir.exists()) {
        final entities = await cacheDir.list().toList();
        for (final entity in entities) {
          try {
            await entity.delete(recursive: true);
          } catch (_) {}
        }
      }
    } catch (e) {
      // 清理失败忽略
    }
  }
}
