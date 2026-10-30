import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:window_manager/window_manager.dart';

import 'app_linux.dart';
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
import 'mpv_selftest_app.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 根据设置初始化文件日志，全平台统一由「获取日志」开关控制。
  //
  // 🔴 2026-10-21：**必须放在自检分支之前**。
  //    自检模式会提前 runApp 并 return，若日志初始化留在后面，
  //    自检运行时不会产生任何日志文件（实测 ~/文档/app_logs/ 为空），
  //    排障时无从核实。放到最前面可保证两条路径都写日志。
  await AppLogger.initialize();

  // 🔴 排障自检入口（默认关闭）：HEIN_MPV_SELFTEST=<媒体路径> 时，
  //    直接渲染一个最小的 Texture(textureId) 播放界面，绕过首页/详情页。
  //
  //    为什么需要它：桌面 mpv 壳的出画链路是
  //      mpv 渲染 → FBO → FlTextureGL.populate → Flutter 采样
  //    而 populate **只在 Dart 侧真的构建了 `Texture(textureId)` 时**
  //    才会被 Flutter 调用。真机排障常无法人工点进播放页（无输入设备/
  //    自动化环境），没有这个入口就无法验证「捕获 Flutter EGL 上下文 →
  //    建共享上下文 → 出画」这一段，只能看到「渲染在跑但 popupate 0 次」。
  //
  //    仅在显式设置该环境变量时走此分支，正常启动完全不受影响。
  if (Platform.isLinux) {
    final selftestMedia = Platform.environment['HEIN_MPV_SELFTEST'] ?? '';
    if (selftestMedia.isNotEmpty) {
      runApp(MpvSelfTestApp(media: selftestMedia));
      return;
    }
  }

  // 缓存应用版本信息，供 User-Agent 与设置页读取。
  await AppInfoService.init();

  // Windows 便携版：将用户数据重定向到软件 exe 同级目录的 data 文件夹。
  if (Platform.isWindows) {
    await PortableStorageWindows.initialize();
    PathProviderPlatform.instance = PortablePathProviderWindows();
    final prefsStore = PortableSharedPreferencesStore();
    SharedPreferencesStorePlatform.instance = prefsStore;
    PortableStorageWindows.registerStore(prefsStore);
  }

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
    // Windows 端与 Linux 端保持一致：isTv=true 只影响直播页/设置页里
    // 「TV 布局 vs 电脑版布局」的分支（内部以 isTv && isDesktop 组合判断），
    // **不**决定播放页走哪套页面 —— 播放页是桌面专用的 WindowsPlayerScreen。
    DeviceUtils.isTvOverride = true;
    runApp(const HainWindowsApp());
    return;
  }

  if (Platform.isLinux) {
    // 🔴🔴 2026-10-23 修复「Linux 版界面像 TV、不能像 Windows 那样用鼠标/手柄」：
    //   本文件是 Flutter 的**默认 target**（`flutter build linux` / `flutter run -d linux`
    //   不带 `--target` 时用的就是它），此前**完全没有 Linux 分支** → 直接落到
    //   `HainTvApp`，也就是 **TV 界面 + TV 播放页**（遥控器焦点驱动，没有桌面版的
    //   鼠标点击 / 比例切换 / 小窗 / 手柄交互）。
    //   发行版脚本 build_linux_appimage.sh 走的是 `--target lib/main_linux.dart`，
    //   所以只有「自己直接 build linux」的用户会撞上这个坑 —— 现象正是
    //   「Linux 版跟 TV 一样，而不是跟 Windows 一样」。
    //   此处补齐分支：**任何** Linux 入口都得到与 Windows 一致的桌面版。
    //   走 LinuxShell → screens/windows/*（首页/分类/搜索/直播/我的）
    //   → screens/windows/detail_screen.dart → WindowsPlayerScreen（桌面播放页）。
    //
    //   Linux 桌面端同样必须初始化窗口管理器：[HainLinuxApp] 用到了
    //   setPreventClose / addListener / close，未先 ensureInitialized 会直接抛错。
    await windowManager.ensureInitialized();
    await windowManager.setTitle('海因影视');
    DeviceUtils.isTvOverride = true;
    runApp(const HainLinuxApp());
    return;
  }

  runApp(const HainTvApp());
}
