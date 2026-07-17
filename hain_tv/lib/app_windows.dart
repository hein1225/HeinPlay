import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/tv/login_screen.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/windows_logger.dart';
import 'package:hain_tv/widgets/tv/tv_shell.dart';
import 'package:window_manager/window_manager.dart';

class HainWindowsApp extends StatefulWidget {
  const HainWindowsApp({super.key});

  @override
  State<HainWindowsApp> createState() => _HainWindowsAppState();
}

class _HainWindowsAppState extends State<HainWindowsApp>
    with WindowListener {
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

    if (Platform.isWindows) {
      // 在后台刷新日志，不阻塞窗口关闭；无论刷新成功/失败，最后都强制退出进程。
      WindowsLogger.flush().whenComplete(() => exit(0));
    } else {
      exit(0);
    }
  }

  /// 拦截 ESC 键：若当前有可以弹出的路由则执行返回，否则忽略。
  /// 使用 [maybePop] 让当前路由的 PopScope 有机会拦截（如播放页全屏时先退出全屏）。
  bool _handleEscKey(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    if (event.logicalKey != LogicalKeyboardKey.escape) return false;

    final navigator = Navigator.of(context, rootNavigator: true);
    if (navigator.canPop()) {
      navigator.maybePop();
      return true;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '海因影视',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routes: {
        '/home': (context) => const TvShell(),
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
          return loggedIn ? const TvShell() : const LoginScreen();
        },
      ),
    );
  }
}
