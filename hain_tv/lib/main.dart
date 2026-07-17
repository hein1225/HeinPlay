import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_mpv/flutter_mpv.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

import 'app_tv.dart';
import 'app_windows.dart';
import 'platform/device_utils.dart';
import 'services/bangumi_service.dart';
import 'services/portable_storage_windows.dart';
import 'services/storage_service.dart';
import 'services/user_data_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Windows 便携版：将用户数据重定向到软件 exe 同级目录的 data 文件夹。
  if (Platform.isWindows) {
    await PortableStorageWindows.initialize();
    PathProviderPlatform.instance = PortablePathProviderWindows();
    SharedPreferencesStorePlatform.instance =
        PortableSharedPreferencesStore();
  }

  // Windows 桌面端需要初始化窗口管理器，并显式设置窗口标题避免中文乱码。
  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setTitle('海因影视');
  }

  // 初始化 flutter_mpv。
  FlutterMpv.ensureInitialized();

  // 每次 App 启动后重置首页首次进入标记，确保用云端数据覆盖本地旧缓存。
  await UserDataService.resetHomeFirstEntryCompleted();

  // 异步请求存储权限（不阻塞启动）。
  StorageService.requestStoragePermission().catchError((_) => false);
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
