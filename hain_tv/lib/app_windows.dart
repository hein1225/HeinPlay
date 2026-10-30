import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/windows/login_screen.dart';
import 'package:hain_tv/services/app_bootstrap.dart';
import 'package:hain_tv/services/gamepad_input_service.dart';
import 'package:hain_tv/services/portable_storage_windows.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:hain_tv/utils/back_interceptor.dart';
import 'package:hain_tv/widgets/common/splash_screen.dart';
import 'package:hain_tv/widgets/windows/windows_shell.dart';
import 'package:window_manager/window_manager.dart';

class HainWindowsApp extends StatefulWidget {
  const HainWindowsApp({super.key});

  @override
  State<HainWindowsApp> createState() => _HainWindowsAppState();
}

class _HainWindowsAppState extends State<HainWindowsApp>
    with WindowListener {
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
    // 手柄适配（A=确认=回车 / B=返回=ESC / 方向键）：Windows 手柄（XInput）不产生
    // 窗口按键消息，由本服务轮询后合成为标准按键注入，从而复用既有按键逻辑。
    GamepadInputService.instance.start();
    // Windows 桌面端统一监听 ESC 作为返回键。
    HardwareKeyboard.instance.addHandler(_handleEscKey);
    if (Platform.isWindows) {
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
    if (Platform.isWindows) {
      windowManager.removeListener(this);
    }
    HardwareKeyboard.instance.removeHandler(_handleEscKey);
    super.dispose();
  }

  /// 窗口关闭前刷新日志，确保退出前所有 pending 日志写入文件。
  ///
  /// 注意：这里不再 await [windowManager.destroy]，否则 Flutter 引擎在后台等待
  /// PlatformView、网络连接、本地代理等资源释放时，会导致窗口卡住很久才消失。
  /// 日志刷新也改为异步执行，不阻塞窗口关闭动画；刷新完成后强制 [exit] 结束进程。
  @override
  Future<void> onWindowClose() async {
    // 立即触发窗口销毁，让窗口立刻响应关闭动作；后续操作均不等待。
    windowManager.destroy();

    // 在后台刷新日志与待落盘偏好，不阻塞窗口关闭；无论成功/失败，最后都强制退出进程。
    // 偏好的整表写入带去抖（见 portable_storage_windows.dart），必须等它刷完，
    // 否则用户改完设置立刻关闭窗口时改动会丢失。
    Future.wait([
      AppLogger.flush(),
      PortableStorageWindows.flushPendingWrites(),
    ]).whenComplete(() => exit(0));
  }

  /// 拦截 ESC 键：若当前有可以弹出的路由则执行返回，否则忽略。
  /// 使用 [maybePop] 让当前路由的 PopScope 有机会拦截（如播放页全屏时先退出全屏）。
  bool _handleEscKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // 诊断：确认键（回车/小键盘回车）与返回键（ESC）都会经过这里。记录下来即可
    // 判断“回车是否被当成返回键消费”——这是 Windows 端“确认后又退出”类问题的
    // 关键证据。用 AppLogger 落盘，不受 debugPrint 节流影响。
    final pressedKey = event.logicalKey;
    if (pressedKey == LogicalKeyboardKey.enter ||
        pressedKey == LogicalKeyboardKey.numpadEnter ||
        pressedKey == LogicalKeyboardKey.escape) {
      AppLogger.log(
        'AppWindows',
        '全局按键 KeyDown=${pressedKey.keyLabel}($pressedKey)',
      );
    }

    if (event.logicalKey != LogicalKeyboardKey.escape) return false;

    // 使用全局 navigatorKey 获取 Navigator，避免在 MaterialApp 之上
    // 调用 Navigator.of(context) 触发空断言崩溃（Windows 退出直播时闪退的根因）。
    final navigator = _navigatorKey.currentState;
    if (navigator == null) {
      debugPrint('全局 ESC: navigator 未就绪');
      return false;
    }
    // 不要用 canPop() 提前 return：首页 / 各分类页是根路由，canPop() 为 false，
    // 提前返回会让 ESC、鼠标右键在首页完全失效（既不返回也不提示退出）。
    // 统一交给 maybePop：有可返回的路由就返回，否则由根路由的 PopScope
    // 拦截并弹出「退出确认」对话框（见 WindowsShell._handleBack）。
    //
    // 🔴🔴 2026-10-22 修复「回放中按 ESC 直接退出播放」：
    //    `HardwareKeyboard` 派发按键时是遍历所有 handler、且不看别人的返回值
    //    （见 hardware_keyboard.dart 的 _dispatchKeyEvent，循环体只有
    //    `handled = handled || thisResult`，命中后不会 break）。本 handler 由
    //    App 的 initState 注册，播放页的 handler 在页面 initState 才注册，因此
    //    本 handler 先执行；同一次 ESC 随后还会进播放页 handler 并同步执行
    //    「退回直播」。而这里 maybePop() 是异步落地的，等它走到 PopScope 时
    //    播放页已经把 _isReplayMode 改成 false，优先级决策就从「回放 → 退回直播」
    //    落到最后一档「退出播放页」——用户看到「回放按一次 ESC 直接退出播放」。
    //    修法：记下当时的 handledSerial，把 maybePop 推迟到微任务里执行；落地时
    //    序号若已变，说明本次返回键已被页面消费，放弃这次 maybePop。
    final serialBefore = BackInterceptor.handledSerial;
    // 同时记下「路由被弹出」序号：多数页面（详情页/分类页/登录页等）在按键
    // 派发过程中就同步 `Navigator.pop()` 了，它们不会调用 markHandled，
    // 只能靠 NavigatorObserver 记录。两条序号任一变化都说明本次返回键已被消费。
    final popSerialBefore = BackInterceptor.popSerial;
    debugPrint('全局 ESC: 排队 maybePop');
    AppLogger.log('AppWindows', '全局 ESC 排队 maybePop serial=$serialBefore');
    scheduleMicrotask(() {
      if (BackInterceptor.handledSerial != serialBefore) {
        AppLogger.log('AppWindows',
            '全局 ESC 放弃 maybePop：本次按键已被页面消费 '
            'serial=${BackInterceptor.handledSerial}');
        return;
      }
      if (BackInterceptor.popSerial != popSerialBefore) {
        AppLogger.log('AppWindows',
            '全局 ESC 放弃 maybePop：本次按键已弹出一层路由 '
            'popSerial=${BackInterceptor.popSerial}');
        return;
      }
      final nav = _navigatorKey.currentState;
      if (nav == null) return;
      AppLogger.log('AppWindows', '全局 ESC 执行 maybePop');
      nav.maybePop();
    });
    return true;
  }

  /// 全局鼠标右键 = 返回（与 ESC 等价）。
  /// 捕获右键 PointerDown 并对当前路由执行 maybePop，与 [_handleEscKey] 行为一致。
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
      // 记录「路由被弹出」，供全局 ESC/右键处理器判断本次返回是否已被页面
      // 通过 Navigator.pop() 消费，避免重复弹一层（详情页 ESC 连退两层的根因）。
      navigatorObservers: [BackInterceptorObserver()],
      title: '海因影视',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeModeService.instance.themeMode,
      // 全局鼠标右键 = 返回（与 ESC 等价）：在 Navigator 外层包 Listener 捕获右键
      // PointerDown 并 maybePop，实现“右键 = ESC = 返回”的全局一致行为。
      builder: (context, child) => Listener(
        onPointerDown: _handleSecondaryPointer,
        child: child,
      ),
      // 注意：'/home' 不要写成 const WindowsShell()，否则主题切换时 identical 的 const
      // 页面不重跑 build，AppColors 不重读、界面不刷新。每次返回新实例以触发整页重绘。
      // 初始路由依据 AppBootstrap 选择：首次冷启动走 '/splash' 载入页；运行期切主题
      // 重建 Navigator 时已为 true，直接落到载入页实际跳转的目标（/home 或 /login），
      // 不重走载入页、不重复初始化、也不会把登录页用户错误踢回首页。
      initialRoute: AppBootstrap.completed ? AppBootstrap.initialRoute : '/splash',
      routes: {
        '/splash': (context) => const SplashScreen(target: SplashTarget.windows),
        '/home': (context) => WindowsShell(),
        '/login': (context) => const LoginScreen(),
      },
      // Windows 版入口：复用全平台统一载入页 SplashScreen（封面 + “正在进入精彩视界”
      // 启动进度条）。由它完成全部初始化（应用信息/日志/版本迁移/服务器测速/首页预加载/
      // Bangumi 代理/登录判定）后自动 pushReplacementNamed 进入 /home 或 /login。
      // 原生 win32 启动封面（splash.bmp）在 Flutter 首帧后由 DestroySplashOverlay 移除；
      // 移除后 splash_shown_=false，窗口缩放/DPI 变化均不再重绘原生封面，故播放中调整窗口
      // 大小不会再次露出静态封面。
    );
  }
}
