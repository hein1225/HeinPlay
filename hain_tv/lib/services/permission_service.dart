import 'dart:io';
import 'package:permission_handler/permission_handler.dart';

/// 权限管理服务：处理安装未知应用权限（用于应用内更新）
class PermissionService {
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
