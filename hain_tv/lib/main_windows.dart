import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hain_tv/app_windows.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/portable_storage_windows.dart';
import 'package:hain_tv/utils/desktop_heartbeat.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;

  // Windows 便携版：将用户数据重定向到软件 exe 同级目录的 data 文件夹。
  if (Platform.isWindows) {
    await PortableStorageWindows.initialize();
    PathProviderPlatform.instance = PortablePathProviderWindows();
    final prefsStore = PortableSharedPreferencesStore();
    SharedPreferencesStorePlatform.instance = prefsStore;
    PortableStorageWindows.registerStore(prefsStore);
  }

  // 初始化桌面窗口管理，用于 Windows 全屏/取消全屏等控制。
  await windowManager.ensureInitialized();
  // 显式设置窗口标题，避免中文在原生标题栏出现乱码。
  await windowManager.setTitle('海因影视');
  // 🔴🔴 2026-10-16：**已移除 fvp**（原 fvp.registerWith 调用）。
  //
  //   Windows 版此前用 FVP/libmdk 作为 video_player 后端，现全平台统一走
  //   **mpv**（官方内核 + 自写壳，见 PlayerBackendFactory.platformDefault）。
  //   fvp 插件已从 pubspec 摘除，故此处不再注册。
  //
  //   随之失效的 fvp 专有配置已由自写 mpv 后端等价接管：
  //     · tls_verify=0              → MpvPlayerView.initMpv 下发 tls-verify=no
  //     · analyzeduration/probesize → mpv 侧 demuxer-readahead-secs + 档位缓存
  //     · reconnect*/http_persistent → mpv 侧 network-timeout + HLS 自愈
  //     · demuxer.io=0（子分片继承 header）→ mpv 原生按 http-header-fields 处理，
  //       不存在 mdkio 那样的「子请求丢 header」缺陷，无需该绕行开关
  // Windows 端与 Linux 端保持一致：isTv=true 只影响直播页/设置页里
  // 「TV 布局 vs 电脑版布局」的分支（这些分支内部以 `isTv && isDesktop` 组合
  // 判断，桌面端行为与手机版不同），**不**决定播放页走哪套页面。
  // 播放页是桌面专用的 screens/windows/player_screen.dart（WindowsPlayerScreen）。
  DeviceUtils.isTvOverride = true;
  // 🔴 2026-10-23：启动卡死诊断心跳（HB-UI 主 isolate + HB-ISO 独立 isolate）。
  //   用于区分「Dart 主 isolate 被同步阻塞」与「只是某个 await 不返回」，
  //   详见 [DesktopHeartbeat] 的判读表。
  DesktopHeartbeat.start();
  // 不在此处阻塞解码封面：避免首帧前黑底等待。启动封面由原生 runner
  // （win32_window）的 IDB_SPLASH 覆盖层绘制，Flutter 首帧就绪后移除。
  runApp(const HainWindowsApp());
}
