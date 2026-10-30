import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:hain_tv/app_linux.dart';
// 🔴 排障自检界面（HEIN_MPV_SELFTEST 专用入口）。
import 'package:hain_tv/mpv_selftest_app.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:hain_tv/utils/desktop_heartbeat.dart';
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

  // 🔴🔴 2026-10-26 16:45 排障自检入口（默认关闭）：
  //    HEIN_MPV_SELFTEST=<媒体路径或URL> 时，直接渲染一个最小的
  //    `Texture(textureId)` 播放界面，绕过首页/详情页。
  //
  //    为什么 Linux 也要有：Linux 构建固定 `--target lib/main_linux.dart`
  //    （见 scripts/build_linux_appimage.sh），而自检分支此前只写在
  //    `lib/main.dart`（Windows/通用入口）里 ⇒ Linux 侧设了
  //    HEIN_MPV_SELFTEST 也只会「mpv 自己播、没人采样」，
  //    populate 恒为 0 次，无法验证
  //    「捕获 Flutter EGL 上下文 → 建共享上下文 → 纹理名在 Flutter 侧有效」。
  //
  //    这在游戏模式排障里尤其关键：掌机无输入设备、无法人工点进播放页。
  //    仅在显式设置该环境变量时走此分支，正常启动完全不受影响。
  if (Platform.isLinux) {
    final selftestMedia = Platform.environment['HEIN_MPV_SELFTEST'] ?? '';
    if (selftestMedia.isNotEmpty) {
      // 日志初始化放前面，保证自检期间也有日志可查。
      try {
        await AppLogger.initialize();
      } catch (_) {
        // 日志初始化失败不阻断自检。
      }
      runApp(MpvSelfTestApp(media: selftestMedia));
      return;
    }
  }

  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;

  // 初始化桌面窗口管理，用于 Linux 全屏/取消全屏等控制。
  // 完整支持原生 Wayland：不强制 GDK_BACKEND，GTK 在 Wayland 会话下原生嵌入。
  await windowManager.ensureInitialized();
  // 显式设置窗口标题，避免中文在原生标题栏出现乱码。
  await windowManager.setTitle('海因影视');

  // 🔴🔴 2026-10-16：**已移除 fvp**（原 fvp.registerWith 调用）。
  //
  //   Linux 版此前用 FVP/libmdk 作为 video_player 后端，现全平台统一走
  //   **mpv**（官方内核 + 自写壳，见 PlayerBackendFactory.platformDefault）。
  //   fvp 插件已从 pubspec 摘除，故此处不再注册。
  //
  //   随之失效的 fvp 专有配置（avformat 的 tls_verify/analyzeduration/reconnect、
  //   demuxer.io=0 等）已由自写 mpv 后端等价接管：
  //     · tls-verify=no      → MpvPlayerView.initMpv 下发
  //     · 重连/超时          → mpv 侧 network-timeout + HLS 自愈
  //     · 子分片 header 继承  → mpv 原生按 -http-header-fields 处理
  //   `lowLatency` / `fastSeek` 是 fvp 专有开关，mpv 对应能力由
  //   profile=fast + hwdec 策略承担，无需在此保留。

  // 🔴 2026-10-23 更正（此前注释与实现不符，容易误导后续维护）：
  //   Linux **不是**「复用 TV 版页面布局」。实际链路是：
  //     main_linux.dart → app_linux.dart → widgets/linux/linux_shell.dart
  //     → screens/windows/*（首页/分类/搜索/直播/我的）
  //     → screens/windows/detail_screen.dart → **WindowsPlayerScreen**
  //   即 Linux 与 Windows **共用同一套桌面界面与桌面播放页**（电脑版一体化）：
  //   顶部导航 + 内容区、鼠标可点、键盘可导航、桌面播放页的比例/小窗等能力。
  //   证据（13:12 的 AppImage 二进制）：`LinuxShell` / `WindowsPlayerScreen`
  //   存在，而 TV 播放页的 `_TvPlayerScreenState` 被 tree-shaking 整个摇掉（=0）。
  //
  //   `isTvOverride = true` 保留，与 Windows 端（main_windows.dart）保持一致：
  //   它只影响直播页/设置页里「TV 布局 vs 电脑版布局」的分支，这些分支内部
  //   都以 `isTv && isDesktop` 组合判断，桌面端行为因此与 Windows 完全相同。
  //   它**不**决定播放页走哪套页面。
  //
  //   手柄：app_linux.dart 里启动 GamepadInputService（读 /dev/input/js*，
  //   A=确认 / B=返回 / 方向键），配合 Steam Input 即可在 Steam Deck 等掌机用手柄操作。
  DeviceUtils.isTvOverride = true;

  // 🔴 2026-10-23：启动卡死诊断心跳（HB-UI 主 isolate + HB-ISO 独立 isolate）。
  //   Linux 桌面版与 Windows 走同一套 TV 播放页，卡死成因需能区分对待，
  //   详见 [DesktopHeartbeat] 的判读表。
  DesktopHeartbeat.start();

  runApp(const HainLinuxApp());

  // SteamOS / Bazzite 掌机的「游戏模式」(gamescope 会话) 没有常规桌面窗口管理器，
  // 应用窗口不会自动铺满屏幕，画面会被缩在屏幕中间。检测到游戏模式即强制全屏。
  if (DeviceUtils.isSteamGameMode) {
    unawaited(enforceGameModeFullScreen());
  }

  // 探测「环境强制全屏」并打印显示诊断信息（详见函数注释）。
  unawaited(_probeDisplayEnvironment());
}

/// 当前会话是不是 **Wayland**。
///
/// 决定 `windowManager.isFullScreen()` 能不能作为全屏判据：
///   · Wayland 会话 ⇒ `isFullScreen()` 恒为 false（compositor 没有 WM 可问），
///     此时不能用 WM 状态推断全屏，也不能强行 setBounds；
///   · X11 会话 ⇒ `isFullScreen()` **探测有效**，setBounds 兜底可按 display.size 铺满。
///
/// 🔴 2026-10-27 实测事实（69 掌机，游戏模式 gamescope 会话）：
///   `XDG_SESSION_TYPE` = **x11**，`WAYLAND_DISPLAY` = **不存在**，
///   但 `XDG_CURRENT_DESKTOP=gamescope`、`GAMESCOPE_WAYLAND_DISPLAY=gamescope-0`，
///   且 `/run/user/1000/` 下**没有 `wayland-0`**（只有 `gamescope-0`）。
///   ⇒ 这两个变量在本会话里**都不能用来判断「是不是 Wayland」**：
///     · `XDG_SESSION_TYPE` 描述的是会话内的 Xwayland 侧，报 x11；
///     · `WAYLAND_DISPLAY` 由启动器决定是否注入，此处未被注入。
///   ⇒ 判据必须包含 **gamescope 会话标识**（`XDG_CURRENT_DESKTOP` 含 gamescope
///     或 `SteamGamepadUI=1`），这正是 [DeviceUtils.isSteamGameMode] 的内容。
///     游戏模式由 gamescope 合成，属 Wayland 体系，不能按 X11 处理
///     （无 WM 的 gamescope 里 setBounds 行为不可预期）。
bool _isWaylandSession() {
  try {
    final env = Platform.environment;
    if (env['XDG_SESSION_TYPE'] == 'wayland') return true;
    // gamescope 会话：合成器是 Wayland，但上面两个变量都不可靠。
    if (DeviceUtils.isSteamGameMode) return true;
    final wd = env['WAYLAND_DISPLAY'];
    if (wd != null && wd.isNotEmpty) return true;
    return false;
  } catch (_) {
    return false;
  }
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
    // 🔴🔴🔴 2026-10-26（游戏模式 Wayland 化后必须改）：
    //   切换到 gamescope 的 Wayland 后，window_manager 的 `isFullScreen()`
    //   **读不到** gamescope 的全屏状态（实测 Wayland 下返回 false），
    //   于是 `envForcedFullScreen` 会是 false ⇒ 播放页的 PopScope 会把
    //   「按返回」当成「先退全屏」⇒ **返回键被永久吞掉**
    //   （2026-09-20 掌机踩过的坑：实测 94 次返回请求 0 次成功）。
    //
    //   游戏模式下窗口**本来就**是环境强制全屏（gamescope 没有窗口管理器），
    //   所以判据应当是「游戏模式 ⇒ 一定强制全屏」，而不是去问 WM。
    DeviceUtils.envForcedFullScreen = fullScreen || DeviceUtils.isSteamGameMode;
    _diag('[Display] 启动全屏探测: isFullScreen=$fullScreen '
        '游戏模式=${DeviceUtils.isSteamGameMode} '
        '→ 环境强制全屏=${DeviceUtils.envForcedFullScreen}');
  } catch (e) {
    _diag('[Display] 启动全屏探测失败: $e');
    // 探测失败时，游戏模式仍应按「环境强制全屏」处理（理由同上）。
    if (DeviceUtils.isSteamGameMode) {
      DeviceUtils.envForcedFullScreen = true;
      _diag('[Display] 探测失败，按游戏模式置环境强制全屏=true');
    }
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
      // 🔴 2026-10-26：游戏模式改走 Wayland 后，这两项决定了 GTK 用哪套
      //   GL 后端（Wayland ⇒ EGL ⇒ mpv 纹理共享可用；X11/GLX ⇒ 必然失败），
      //   出问题时必须一眼能看出来。
      'XDG_RUNTIME_DIR', 'GDK_BACKEND',
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
    // 🔴🔴🔴 2026-10-26 14:45 修正（上一版误伤游戏模式）：
    //   上一版按「游戏模式」跳过 setBounds 兜底 ⇒ 游戏模式里窗口停在
    //   Flutter 默认的 1280x720（位置 (26,23)），**没有铺满 1920x1080**
    //   ⇒ 这就是用户报的「游戏模式分辨率识别不对」。
    //
    //   正确的判据是「**当前会话是不是 Wayland 合成器**」：
    //     · Wayland 合成器会话 ⇒ window_manager 的 isFullScreen() 恒为 false
    //       （gamescope 自己的 compositor 没有 WM 可问）⇒ 此时强行 setBounds
    //       反而可能把「环境全屏」压成「固定尺寸」，应当收手；
    //     · 有 WM 的会话 ⇒ isFullScreen() **探测有效**，setBounds 兜底能把窗口
    //       按 display.size 铺满 ⇒ 必须保留兜底。
    //   ⚠️ 注意区分「合成器类型」与「GTK 选的后端」：游戏模式的合成器是
    //      gamescope（Wayland），但 GTK 可能因未注入 WAYLAND_DISPLAY 而选了
    //      X11 后端（boot.log 实测 GdkX11Display）。这里判断的是**会话类型**，
    //      用 [DeviceUtils.isSteamGameMode] 兜住 gamescope 会话。
    if (_isWaylandSession()) {
      _diag('[GameMode] Wayland 会话下无法探测全屏状态，按「环境即全屏」处理，'
          '跳过 setBounds 兜底');
      return;
    }
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
