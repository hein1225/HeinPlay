import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/windows/login_screen.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/app_logger.dart';
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
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // Windows 桌面端统一监听 ESC 作为返回键。
    HardwareKeyboard.instance.addHandler(_handleEscKey);
    if (Platform.isWindows) {
      windowManager.addListener(this);
      windowManager.setPreventClose(true);
    }
  }

  @override
  void dispose() {
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
      theme: buildAppTheme(),
      routes: {
        '/home': (context) => const WindowsShell(),
        '/login': (context) => const LoginScreen(),
      },
      home: FutureBuilder<bool>(
        future: UserDataService.isLoggedIn(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: AppColors.bgApp,
              body: Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            );
          }
          final loggedIn = snapshot.data ?? false;
          return loggedIn ? const WindowsShell() : const LoginScreen();
        },
      ),
    );
  }
}
