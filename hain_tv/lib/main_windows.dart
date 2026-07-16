import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_mpv/flutter_mpv.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hain_tv/app_windows.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/portable_storage_windows.dart';
import 'package:hain_tv/services/storage_service.dart';
import 'package:hain_tv/utils/windows_logger.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

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
  FlutterMpv.ensureInitialized();
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
  // 异步请求存储权限（不阻塞启动）
  StorageService.requestStoragePermission().catchError((_) => false);
  // 异步加载 Bangumi 代理设置到内存缓存，便于后续图片代理同步使用
  BangumiService.loadProxySettings().catchError((_) {});
  runApp(const HainWindowsApp());
}
