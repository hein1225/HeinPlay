import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hain_tv/app_windows.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/portable_storage_windows.dart';
import 'package:hain_tv/services/server_latency_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/services/version_migration_service.dart';
import 'package:hain_tv/utils/windows_logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 缓存应用版本与平台信息，供更新检测与设置页读取。
  await AppInfoService.init();

  // Windows 便携版：将用户数据重定向到软件 exe 同级目录的 data 文件夹。
  if (Platform.isWindows) {
    await PortableStorageWindows.initialize();
    PathProviderPlatform.instance = PortablePathProviderWindows();
    SharedPreferencesStorePlatform.instance =
        PortableSharedPreferencesStore();
    // 预先初始化 Windows 日志目录，确保首次写入时目录已就绪。
    final logOk = await WindowsLogger.initialize();
    if (!logOk) {
      debugPrint('main_windows: Windows 日志初始化失败');
    }
  }

  // 初始化桌面窗口管理，用于 Windows 全屏/取消全屏等控制。
  await windowManager.ensureInitialized();
  // 显式设置窗口标题，避免中文在原生标题栏出现乱码。
  await windowManager.setTitle('海因影视');
  // Windows 默认使用 FVP 作为 video_player 后端（基于 libmdk）。
  // 不传 video.decoders，让 fvp 使用内置默认解码器列表（包含 D3D11/DXVA/CUDA/FFmpeg 等），
  // 兼容性最好。关闭 FFmpeg TLS 严格验证，避免非标准端口/自签证书源被服务器拒绝。
  fvp.registerWith(options: {
    'platforms': ['windows'],
    'global': {
      'avformat': 'tls_verify=0',
      'ffmpeg.loglevel': 'info',
    },
  });
  // Windows 版复用 TV 版页面布局，标记为 TV 模式以确保焦点、遥控逻辑生效。
  DeviceUtils.isTvOverride = true;
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
  // 异步加载 Bangumi 代理设置到内存缓存，便于后续图片代理同步使用
  BangumiService.loadProxySettings().catchError((_) {});
  runApp(const HainWindowsApp());
}
