import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hain_tv/app_linux.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:window_manager/window_manager.dart';

/// 诊断输出：同时走 debugPrint（stdout，进 journal/Steam 日志）与 [AppLogger]
/// （进应用日志文件），保证用户无论用哪种方式导出日志都能拿到这些实测值。
void _diag(String message) {
  debugPrint(message);
  try {
    AppLogger.log('LinuxDisplay', message);
  } catch (_) {
    // AppLogger 尚未初始化时忽略，不影响启动。
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;

  // 初始化桌面窗口管理，用于 Linux 全屏/取消全屏等控制。
  // 完整支持原生 Wayland：不强制 GDK_BACKEND，GTK 在 Wayland 会话下原生嵌入，
  // fvp/libmdk 通过 EGL/VA-API 在 Wayland 下正常渲染视频。
  await windowManager.ensureInitialized();
  // 显式设置窗口标题，避免中文在原生标题栏出现乱码。
  await windowManager.setTitle('海因影视');

  // Linux 版使用 FVP 作为 video_player 后端（基于 libmdk，支持 X11 与 Wayland）。
  // 关闭 FFmpeg TLS 严格验证，避免非标准端口/自签证书源被服务器拒绝。
  fvp.registerWith(options: {
    'platforms': ['linux'],
    'lowLatency': 1,
    // 补 KeyFrame(=Fast) 标志：fvp 包默认 seek 标志缺该位会退化为精确 seek
    // （逐帧解码到目标位置），点播续播/拖进度条会长时间卡顿（详见
    // player_backend_factory.dart 中 Android 段的同一说明）。
    'fastSeek': true,
    'global': {
      // 关闭 FFmpeg TLS 严格验证，兼容非标准端口/自签证书源。
      // analyzeduration/probesize 调小：缩短组播直播流首次 initialize 的探测窗口，
      // 修复换台慢（默认 5s → <1s）。
      // reconnect*/http_persistent：HLS 子分片请求偶发连接失败/复用异常时自动重连，
      // 避免“出声无画面→卡死”（与 Windows 端配置一致）。
      'avformat': 'tls_verify=0:analyzeduration=500000:probesize=2097152'
          ':reconnect=1:reconnect_streamed=1:reconnect_delay_max=2:http_persistent=1',
      // 与 Windows 端保持一致：强制 fvp 使用 FFmpeg 内置 IO(demuxer.io=0)，
      // 而非 MDK 自带的 mdkio 模块(demuxer.io=1)。mdkio 对 HLS 子分片请求不继承
      // player 级 avio.headers（UA/Referer/Origin），分片会被 CDN 拒绝→出声无画面；
      // 改用 FFmpeg avio 后子请求继承完整 header，直连即可正常播放，无需退回代理。
      'demuxer.io': '0',
      'ffmpeg.loglevel': 'info',
    },
  });

  // Linux 版复用 TV 版页面布局，标记为 TV 模式以确保焦点、遥控逻辑生效；
  // 配合 Steam Input（手柄 → 方向键/Enter/Esc 映射）即可在 Steam Deck 等掌机上用手柄操作。
  DeviceUtils.isTvOverride = true;

  runApp(const HainLinuxApp());

  // SteamOS / Bazzite 掌机的「游戏模式」(gamescope 会话) 没有常规桌面窗口管理器，
  // 应用窗口不会自动铺满屏幕，画面会被缩在屏幕中间。检测到游戏模式即强制全屏。
  if (DeviceUtils.isSteamGameMode) {
    unawaited(enforceGameModeFullScreen());
  }

  // 探测「环境强制全屏」并打印显示诊断信息（详见函数注释）。
  unawaited(_probeDisplayEnvironment());
}

/// 探测环境强制全屏 + 打印显示/会话诊断信息。
///
/// 背景（2026-09-20 掌机实测）：Steam 游戏模式下应用**启动时窗口就已经是全屏**，
/// 且 `setFullScreen(false)` 撤不掉（调用后 `isFullScreen()` 仍为 true）。
/// 播放页的返回逻辑原本以「是否全屏」决定「先退全屏还是退页面」，于是返回键被
/// 永久吞掉——实测 94 次返回请求 0 次成功，直播页与点播页都退不出去。
/// 这里在启动后探测一次并记录到 [DeviceUtils.envForcedFullScreen]；
/// 即使这里的时机没探到，[DesktopFullscreenMixin] 在用户首次按返回时还有兜底。
///
/// 同时打印显示尺寸/缩放/会话变量：掌机是 1080x1920 的竖屏面板 + gamescope，
/// 「游戏模式下界面缩放不对」这类问题必须靠这些实测值定位，不能靠猜。
Future<void> _probeDisplayEnvironment() async {
  // 等窗口系统把启动阶段的尺寸/全屏请求应用完再探测，避免读到中间态。
  await Future<void>.delayed(const Duration(milliseconds: 1500));

  try {
    final fullScreen = await windowManager.isFullScreen();
    DeviceUtils.envForcedFullScreen = fullScreen;
    _diag('[Display] 启动全屏探测: isFullScreen=$fullScreen '
        '游戏模式=${DeviceUtils.isSteamGameMode} '
        '→ 环境强制全屏=${DeviceUtils.envForcedFullScreen}');
  } catch (e) {
    _diag('[Display] 启动全屏探测失败: $e');
  }

  // 会话把窗口置成全屏本身就是游戏模式的特征（gamescope 会这样，桌面 GNOME 不会）。
  // 若判据没命中而这里命中了，补一次铺满兜底——用户报过游戏模式下画面缩在中间。
  if (DeviceUtils.envForcedFullScreen && !DeviceUtils.isSteamGameMode) {
    _diag('[Display] 检出环境强制全屏（判据未命中），补一次铺满兜底');
    unawaited(enforceGameModeFullScreen());
  }

  // 注意：release 构建里 Size/Rect 的 toString() 只输出 `Instance of 'Size'`，
  // 必须显式取 width/height 格式化，否则日志拿不到数值（已实测）。
  try {
    final size = await windowManager.getSize();
    final bounds = await windowManager.getBounds();
    _diag('[Display] 窗口: ${size.width}x${size.height} '
        'bounds=(${bounds.left},${bounds.top},${bounds.width},${bounds.height})');
  } catch (e) {
    _diag('[Display] 窗口尺寸读取失败: $e');
  }

  try {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isNotEmpty) {
      final view = views.first;
      final dpr = view.devicePixelRatio;
      final physical = view.physicalSize;
      final display = view.display.size;
      _diag('[Display] View: display=${display.width}x${display.height} '
          'dpr=$dpr physical=${physical.width}x${physical.height} '
          'logical=${physical.width / dpr}x${physical.height / dpr}');
    }
  } catch (e) {
    _diag('[Display] View 信息读取失败: $e');
  }

  try {
    final env = Platform.environment;
    const keys = [
      'XDG_CURRENT_DESKTOP', 'XDG_SESSION_TYPE', 'GAMESCOPE_WAYLAND_DISPLAY',
      'SteamDeck', 'SteamGamepadUI', 'SteamTenfoot', 'GDK_SCALE',
      'GDK_DPI_SCALE', 'WAYLAND_DISPLAY', 'DISPLAY', 'QT_SCALE_FACTOR',
    ];
    final parts = keys.map((k) => '$k=${env[k] ?? "-"}').join(' ');
    _diag('[Display] env: $parts');
  } catch (e) {
    _diag('[Display] 环境变量读取失败: $e');
  }
}

/// 游戏模式（gamescope 会话）下强制窗口铺满屏幕。
///
/// gamescope 里 GTK 的 gtk_window_fullscreen 有时不生效（表现为画面仍被缩在
/// 屏幕中间），因此先放开尺寸限制、确保窗口可拉伸，再请求全屏；随后复查一次，
/// 仍未全屏则按屏幕尺寸直接把窗口铺满作为兜底。
Future<void> enforceGameModeFullScreen() async {
  const unbounded = Size(100000, 100000);
  try {
    await windowManager.setMaximumSize(unbounded);
    await windowManager.setMinimumSize(const Size(320, 180));
    await windowManager.setResizable(true);
    await windowManager.setFullScreen(true);
    _diag('[GameMode] 已请求全屏（检测到 gamescope 游戏模式）');
  } catch (e) {
    _diag('[GameMode] 请求全屏失败: $e');
  }

  // 复查兜底：等窗口系统应用完上面的请求再判断。
  await Future<void>.delayed(const Duration(milliseconds: 800));
  try {
    if (await windowManager.isFullScreen()) return;
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    // 注意：Flutter 的 [Display.size] 已经是**逻辑尺寸**（掌机实测 display=1440x810、
    // dpr=2、physical=2880x1526）。早期版本在此又除了一次 dpr，把窗口设成屏幕的一半，
    // 会直接造成「铺满后画面比例不对」。此处必须直接用 display.size。
    final display = view.display.size;
    await windowManager.setBounds(
      Rect.fromLTWH(0, 0, display.width, display.height),
    );
    _diag('[GameMode] setFullScreen 未生效，已按屏幕尺寸铺满: '
        '${display.width}x${display.height}');
  } catch (e) {
    _diag('[GameMode] 全屏兜底失败: $e');
  }
}
