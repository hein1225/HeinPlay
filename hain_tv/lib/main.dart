import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

import 'app_tv.dart';
import 'app_windows.dart';
import 'platform/device_utils.dart';
import 'services/app_info_service.dart';
import 'services/bangumi_service.dart';
import 'services/portable_storage_windows.dart';
import 'services/server_latency_service.dart';
import 'utils/app_logger.dart';
import 'services/user_data_service.dart';
import 'services/version_migration_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 缓存应用版本信息，供 User-Agent 与设置页读取。
  await AppInfoService.init();

  // Windows 便携版：将用户数据重定向到软件 exe 同级目录的 data 文件夹。
  if (Platform.isWindows) {
    await PortableStorageWindows.initialize();
    PathProviderPlatform.instance = PortablePathProviderWindows();
    SharedPreferencesStorePlatform.instance =
        PortableSharedPreferencesStore();
  }

  // 根据设置初始化文件日志，全平台统一由「获取日志」开关控制。
  await AppLogger.initialize();

  // Windows 桌面端需要初始化窗口管理器，并显式设置窗口标题避免中文乱码。
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('海因影视');
  }

  // 版本升级时自动清理旧缓存（保留用户数据），首次安装仅记录版本号。
  await VersionMigrationService.migrate();

  // v1.2.0：将旧版 username/password/cookies 迁移到主/子账号模型。
  await UserDataService.migrateLegacyAccount();

  // v1.2.0：若开启自动测速，对主/备服务器进行延迟探测并保存最优地址。
  final autoSelectLowLatency =
      await UserDataService.getAutoSelectLowLatencyServer();
  if (autoSelectLowLatency) {
    final primary = await UserDataService.getServerUrl() ?? '';
    final backup = await UserDataService.getBackupServerUrl();
    final serverUrl = primary.isNotEmpty ? primary : backup;
    if (serverUrl.isNotEmpty) {
      try {
        await ServerLatencyService.selectBestServer(
          serverUrl,
          primary.isNotEmpty ? backup : null,
        );
      } catch (e) {
        debugPrint('启动时服务器测速失败: $e');
      }
    }
  }

  // 每次 App 启动后重置首页首次进入标记，确保用云端数据覆盖本地旧缓存。
  await UserDataService.resetHomeFirstEntryCompleted();

  // 异步加载 Bangumi 代理设置到内存缓存，便于后续图片代理同步使用。
  BangumiService.loadProxySettings().catchError((_) {});

  if (Platform.isWindows) {
    // Windows 版复用 TV 版页面布局，标记为 TV 模式以确保焦点、遥控逻辑生效。
    DeviceUtils.isTvOverride = true;
    runApp(const HainWindowsApp());
    return;
  }

  runApp(const HainTvApp());
}
