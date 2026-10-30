import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/player/mpv_desktop_backend.dart';
import 'package:hain_tv/screens/windows/login_screen.dart';
import 'package:hain_tv/services/app_bootstrap.dart';
import 'package:hain_tv/services/gamepad_input_service.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:hain_tv/widgets/common/splash_screen.dart';
import 'package:hain_tv/widgets/linux/linux_shell.dart';
import 'package:window_manager/window_manager.dart';

class HainLinuxApp extends StatefulWidget {
  const HainLinuxApp({super.key});

  @override
  State<HainLinuxApp> createState() => _HainLinuxAppState();
}

class _HainLinuxAppState extends State<HainLinuxApp> with WindowListener {
  /// 全局导航 key：供无 Navigator context 的全局 ESC 处理器安全访问当前路由栈。
  ///
  /// 切主题时更换为新的 [GlobalKey]，强制整棵 [Navigator] 路由树重建（= 全界面
  /// 重建刷新）：所有页面与覆盖层立即按新主题重读 [AppColors]，实现全量刷新；
  /// 已启动后初始路由由 [AppBootstrap.completed] 决定为 /home 或 /login，不会
  /// 重新走载入页、也不会重复初始化。正在播放的视频页随之被重置（非卡死）。
  GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    ThemeModeService.instance.addListener(_onThemeChanged);
    ThemeModeService.instance.init();
    // 手柄适配（A=确认=回车 / B=返回=ESC / 方向键）：Linux 手柄是独立的
    // /dev/input/js* 设备，由本服务读取后合成为标准按键注入，复用既有按键逻辑。
    GamepadInputService.instance.start();
    // Linux 桌面端统一监听 ESC 作为返回键（Steam 手柄的 Esc 映射亦走此路径）。
    HardwareKeyboard.instance.addHandler(_handleEscKey);
    if (DeviceUtils.isDesktop) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  void _onThemeChanged() {
    // 全界面重建刷新：更换 Navigator key 使整棵路由树重建并立即套用新主题。
    // 不依赖 MaterialApp 原地 setState（那样已推送路由被 ModalRoute 缓存、不重跑
    // build，主题不生效）。已启动后初始路由为 /home，不会重走载入页与重复初始化。
    _navigatorKey = GlobalKey<NavigatorState>();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    ThemeModeService.instance.removeListener(_onThemeChanged);
    if (DeviceUtils.isDesktop) {
      windowManager.removeListener(this);
    }
    HardwareKeyboard.instance.removeHandler(_handleEscKey);
    super.dispose();
  }

  /// 窗口关闭前刷新日志，确保退出前所有 pending 日志写入文件。
  ///
  /// 🔴 2026-10-20 修「点击关闭卡死」：
  ///   原实现是 `windowManager.destroy()` → 再 `AppLogger.flush()`。
  ///   但 destroy() 之后 Flutter 引擎已进入拆除流程，此时再做异步文件 I/O
  ///   （flush）很可能**永远不返回**，而窗口已经消失 —— 用户看到的就是
  ///   「点了关闭、软件卡住不退出」。
  ///
  ///   正确顺序：**先 flush（带超时）→ 再 destroy → 最后 exit**。
  ///   任何一步失败都不能让进程挂住，故全程 try/catch + 超时。
  ///
  ///   另：`setPreventClose(true)` 让本回调成为**唯一**退出路径，
  ///   所以这里必须保证一定退出（exit(0) 兜底）。
  @override
  Future<void> onWindowClose() async {
    AppLogger.log('AppLinux', '窗口关闭请求，开始关闭 mpv');
    // 🔴🔴 2026-10-23 补齐「关掉 mpv 内核」这一步（对齐 app_tv.dart）。
    //   mpv 的 render context 释放时要求 EGL 上下文 current；一旦窗口先没了、
    //   EGL surface 失效，`mpv_render_context_free` 就会挂住 → 进程退不出去
    //   → 表现就是「点关闭后软件卡死」。
    //   最多等 3 秒，绝不无限等。
    try {
      await MpvDesktopBackend.shutdownEngine().timeout(
        const Duration(seconds: 3),
      );
      AppLogger.log('AppLinux', 'mpv 已关闭');
    } catch (e) {
      debugPrint('AppLinux: 关闭 mpv 异常/超时（忽略，继续退出）: $e');
    }
    try {
      // 1. 先刷日志（最多等 2 秒，绝不无限等）
      await AppLogger.flush().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          debugPrint('AppLinux: AppLogger.flush 超时，强制继续退出');
        },
      );
    } catch (e) {
      debugPrint('AppLinux: flush 异常（忽略，继续退出）: $e');
    }
    try {
      // 2. 再销毁窗口
      await windowManager.destroy().timeout(
        const Duration(seconds: 2),
        onTimeout: () {
          debugPrint('AppLinux: windowManager.destroy 超时，强制退出');
        },
      );
    } catch (e) {
      debugPrint('AppLinux: destroy 异常（忽略，继续退出）: $e');
    }
    // 3. 无条件退出，保证进程不残留
    exit(0);
  }

  /// 拦截 ESC 键：若当前有可以弹出的路由则执行返回，否则交给根路由处理。
  /// 使用 [maybePop] 让当前路由的 PopScope 有机会拦截（如播放页全屏时先退出全屏）。
  bool _handleEscKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;

    // 使用全局 navigatorKey 获取 Navigator，避免在 MaterialApp 之上
    // 调用 Navigator.of(context) 触发空断言崩溃。
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('全局 ESC: navigator 未就绪');
      return false;
    }
    // 不要用 canPop() 提前 return：首页 / 各分类页是根路由，canPop() 为 false，
    // 提前返回会让 ESC、鼠标右键在首页完全失效（既不返回也不提示退出）。
    // 与 Windows 版一致，统一交给 maybePop：有可返回的路由就返回，否则由根路由的
    // PopScope 拦截并弹出「退出确认」对话框（见 LinuxShell._handleBack）。
    debugPrint('全局 ESC: 执行 maybePop');
    AppLogger.log('AppLinux', '全局 ESC maybePop');
    navigator.maybePop();
    return true;
  }

  /// 全局鼠标右键 = 返回（与 ESC 等价），与 Windows 版行为一致。
  /// 捕获右键 PointerDown 并对当前路由执行 maybePop。
  /// 不要用 [Navigator.canPop] 提前 return：播放页 PopScope 在控制栏可见/全屏时
  /// canPop 为 false，提前 return 会让右键在播放页完全失效；改由 maybePop 交给
  /// PopScope 按优先级处理（先隐藏控制栏 / 退出全屏，否则返回）。
  void _handleSecondaryPointer(PointerDownEvent event) {
    if (event.buttons != kSecondaryMouseButton) return;
    final navigator = _navigatorKey.currentState;
    if (navigator == null) return;
    navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '海因影视',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeModeService.instance.themeMode,
      // 全局鼠标右键 = 返回（与 ESC 等价）：在 Navigator 外层包 Listener 捕获右键
      // PointerDown 并 maybePop，实现“右键 = ESC = 返回”的全局一致行为（与 Windows 版一致）。
      //
      // 外层再套一层 [_GameModeUiScale]：修「游戏模式界面/字体/图标过小」。
      builder: (context, child) => Listener(
        onPointerDown: _handleSecondaryPointer,
        child: _GameModeUiScale(child: child),
      ),
      // 初始路由依据 AppBootstrap 选择：首次冷启动走 '/splash' 载入页；运行期切主题
      // 重建 Navigator 时已为 true，直接落到载入页实际跳转的目标（/home 或 /login），
      // 不重走载入页、不重复初始化、也不会把登录页用户错误踢回首页。
      initialRoute: AppBootstrap.completed ? AppBootstrap.initialRoute : '/splash',
      routes: {
        '/splash': (context) => const SplashScreen(target: SplashTarget.linux),
        '/home': (context) => LinuxShell(),
        '/login': (context) => const LoginScreen(),
      },
    );
  }
}

/// 游戏模式（gamescope）下的全局 UI 缩放修正。
///
/// 【问题】掌机 7 寸面板原生 1920x1080，但**游戏模式报 `devicePixelRatio=1.0`**，
///   而**桌面模式报 2.0**（真机实测：桌面 View display=1440x810 dpr=2.0；
///   游戏模式 View display=1920x1080 dpr=1.0）。Flutter 的逻辑像素 = 物理像素/dpr，
///   于是游戏模式下逻辑画布是 1920x1080，比桌面模式的 1440x810 大 1.33 倍
///   ⇒ **同一套 UI 在游戏模式下每个元素占比都更小**，用户看到的就是
///   「字体和图标都小了一圈，像显示了错误的分辨率」。
///
/// 【为什么不用 GDK_SCALE】它是 GTK/X11 的缩放开关，**Wayland 下被忽略**
///   （真机实测 `GDK_SCALE=2` 后 dpr 仍为 1.0）。而且后端已切到 Wayland
///   （见 my_application.cc 的 hein_force_gamescope_wayland），该变量本就无效。
///
/// 【做法】用 [FittedBox] 把逻辑画布缩到 1/scale，再由 GPU 放大回满屏，
///   同时把 [MediaQueryData.devicePixelRatio] 同步乘 scale：
///     · 逻辑画布 1920→1440 ⇒ 字号/图标/间距等逻辑尺寸**等比放大** 1.33 倍，
///       视觉上与桌面模式一致；
///     · dpr 同步放大 ⇒ Flutter 仍按**物理像素**栅格化文字与图形，
///       不会因为先缩小再放大而变模糊（文字依然是 1080p 原生清晰度）；
///     · [FittedBox] 自带命中测试坐标反变换 ⇒ 点击/手柄操作位置准确，
///       不像裸 [Transform.scale] 那样需要手工换算。
///
/// 【为什么只改游戏模式】桌面模式 dpr=2 本来就正常，不能动；Windows 走
///   另一套入口（lib/main.dart），完全不受影响。
class _GameModeUiScale extends StatelessWidget {
  const _GameModeUiScale({required this.child});

  final Widget? child;

  /// 目标缩放：游戏模式逻辑画布 1920x1080 ⇒ 想要 1440x810 的观感，
  /// 即把 dpr 从 1.0 提到 1.3333（= 1920/1440）。这也是掌机 7 寸 1080p
  /// 面板最接近舒适阅读的字号档位（桌面模式实测即此档）。
  static const double _kScale = 4.0 / 3.0;

  @override
  Widget build(BuildContext context) {
    final w = child;
    if (w == null) return const SizedBox.shrink();
    // 非游戏模式（桌面 GNOME/KDE、Windows）一律原样透传，绝不改 dpr。
    if (!DeviceUtils.isSteamGameMode) return w;

    final mq = MediaQuery.maybeOf(context);
    if (mq == null) return w;

    // 只在「dpr 明显偏小」时介入：若某版本 gamescope 已正确上报 dpr≥1.25，
    // 说明系统已做过缩放，再乘一次就会过大 ⇒ 保持原样。
    if (mq.devicePixelRatio >= 1.25) return w;

    // 逻辑画布按 scale 缩小；dpr 与 size **必须同步**改，
    // 否则 MediaQuery.of(context).size 仍报 1920x1080，布局会按错的画布计算。
    final logicalSize = Size(
      mq.size.width / _kScale,
      mq.size.height / _kScale,
    );
    return FittedBox(
      fit: BoxFit.contain,
      alignment: Alignment.center,
      child: SizedBox(
        width: logicalSize.width,
        height: logicalSize.height,
        child: MediaQuery(
          data: mq.copyWith(
            devicePixelRatio: mq.devicePixelRatio * _kScale,
            size: logicalSize,
          ),
          child: w,
        ),
      ),
    );
  }
}
