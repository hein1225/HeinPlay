import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/screens/windows/login_screen.dart';
import 'package:hain_tv/services/app_bootstrap.dart';
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
  @override
  Future<void> onWindowClose() async {
    windowManager.destroy();
    AppLogger.flush().whenComplete(() => exit(0));
  }

  /// 拦截 ESC 键：若当前有可以弹出的路由则执行返回，否则忽略。
  /// 使用 [maybePop] 让当前路由的 PopScope 有机会拦截（如播放页全屏时先退出全屏）。
  bool _handleEscKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;

    final navigator = _navigatorKey.currentState;
    if (navigator == null || !navigator.canPop()) {
      debugPrint('全局 ESC: 无路由可返回');
      return false;
    }
    debugPrint('全局 ESC: 执行 maybePop');
    AppLogger.log('AppLinux', '全局 ESC maybePop');
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
