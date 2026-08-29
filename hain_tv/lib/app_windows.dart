import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/windows/login_screen.dart';
import 'package:hain_tv/services/app_bootstrap.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/app_logger.dart';
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

    // 在后台刷新日志，不阻塞窗口关闭；无论刷新成功/失败，最后都强制退出进程。
    AppLogger.flush().whenComplete(() => exit(0));
  }

  /// 拦截 ESC 键：若当前有可以弹出的路由则执行返回，否则忽略。
  /// 使用 [maybePop] 让当前路由的 PopScope 有机会拦截（如播放页全屏时先退出全屏）。
  bool _handleEscKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;

    // 使用全局 navigatorKey 获取 Navigator，避免在 MaterialApp 之上
    // 调用 Navigator.of(context) 触发空断言崩溃（Windows 退出直播时闪退的根因）。
    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) {
      debugPrint('全局 ESC: 无路由可返回');
      return false;
    }
    debugPrint('全局 ESC: 执行 maybePop');
    AppLogger.log('AppWindows', '全局 ESC maybePop');
    navigator.maybePop();
    return true;
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
