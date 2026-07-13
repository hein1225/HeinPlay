import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 权限管理服务：处理首次启动权限提示
class PermissionService {
  static const String _firstLaunchKey = 'first_launch_completed';

  /// 检查是否已完成首次启动
  static Future<bool> isFirstLaunch() async {
    final prefs = await SharedPreferences.getInstance();
    return !prefs.containsKey(_firstLaunchKey);
  }

  /// 标记首次启动已完成
  static Future<void> markFirstLaunchCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_firstLaunchKey, true);
  }

  /// 检查存储权限状态
  static Future<bool> hasStoragePermission() async {
    // Android 10+ 使用 Scoped Storage，应用私有目录不需要权限
    // 但缓存图片到外部存储需要 READ_EXTERNAL_STORAGE
    final status = await Permission.storage.status;
    return status.isGranted;
  }

  /// 显示存储权限请求对话框（TV 风格）
  static Future<void> showStoragePermissionDialog(BuildContext context) async {
    return showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: Color(0xFF2A2A3A)),
        ),
        title: const Text(
          '需要存储权限',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: Colors.white,
          ),
        ),
        content: const Text(
          '海因影视需要存储权限来缓存海报图片和影视数据，以提供更流畅的浏览体验。',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 14,
            color: Color(0xFF9CA3AF),
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text(
              '稍后',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: Color(0xFF9CA3AF),
              ),
            ),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await _requestStoragePermissionInternal();
            },
            child: const Text(
              '允许',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: Color(0xFFE50914),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 内部请求存储权限方法
  static Future<bool> _requestStoragePermissionInternal() async {
    if (!Platform.isAndroid) return true;

    // Android 13+ 使用新的媒体权限替代 READ_EXTERNAL_STORAGE
    final photos = await Permission.photos.request();
    final videos = await Permission.videos.request();
    final audio = await Permission.audio.request();

    if (photos.isGranted || videos.isGranted || audio.isGranted) {
      return true;
    }

    // Android 12 及以下回退到传统存储权限
    final storageStatus = await Permission.storage.request();
    if (storageStatus.isGranted) return true;

    // 如果被拒绝，尝试请求管理外部存储权限（Android 11+）
    final manageStatus = await Permission.manageExternalStorage.request();
    return manageStatus.isGranted;
  }

  /// 请求存储权限并返回结果（供设置页面使用）
  static Future<bool> requestStoragePermission() async {
    return await _requestStoragePermissionInternal();
  }

  /// 检查是否拥有安装未知应用权限（Android）
  static Future<bool> canInstallPackages() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.requestInstallPackages.status;
    return status.isGranted;
  }

  /// 请求安装未知应用权限（Android），会引导用户到设置页开启。
  /// 返回是否已授权。
  static Future<bool> requestInstallPackagesPermission() async {
    if (!Platform.isAndroid) return true;
    final status = await Permission.requestInstallPackages.request();
    return status.isGranted;
  }
}
