import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hain_tv/screens/tv/login_screen.dart';
import 'package:hain_tv/player/mpv_desktop_backend.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:hain_tv/services/gamepad_input_service.dart';
import 'package:hain_tv/services/remote_input_service.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/splash_screen.dart';
import 'package:hain_tv/widgets/tv/tv_shell.dart';

class HainTvApp extends StatefulWidget {
  const HainTvApp({super.key});

  @override
  State<HainTvApp> createState() => _HainTvAppState();
}

class _HainTvAppState extends State<HainTvApp> with WindowListener {
  /// 全局导航 key：供 MaterialApp 管理路由栈（搜索跳转已迁移到 TvShell 的常驻 Tab）。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    // 🔴🔴 2026-10-21 修复「关闭软件卡死」：
    //    本类此前完全没有窗口关闭处理：既没 addListener(this)，也没 setPreventClose。
    //    于是用户点关闭 → 窗口被直接销毁 → Flutter 引擎进入拆除流程，但
    //    mpv 的渲染线程/事件线程仍在跑、EGL 上下文仍被持有、libmpv 从没收到
    //    dispose → 进程退不掉，表现就是「点关闭后软件卡死」。
    //    78 日志实证：最后一条是 'FlutterEngineRemoveView ... cannot be removed'，
    //    之后没有任何 'mpv 已完全关闭' / '事件线程已 join'，即 shutdown 从未执行。
    //    修法：接管关闭流程，先停 mpv 再销毁窗口，并加超时与 exit 兜底。
    //
    // 🔴 2026-10-23 更正过期描述：本类**不是** Linux 桌面的入口。
    //    Linux 发行版入口是 main_linux.dart → HainLinuxApp（桌面界面 + 桌面播放页）；
    //    main.dart 现已补上 Linux 分支，同样走 HainLinuxApp。
    //    本类只服务 Android TV 与「未特指 target」的 TV 形态。
    if (Platform.isLinux || Platform.isWindows) {
      windowManager.addListener(this);
      // 让本回调成为唯一退出路径，保证 mpv 一定被关闭。
      windowManager.setPreventClose(true);
    }
    ThemeModeService.instance.addListener(_onThemeChanged);
    ThemeModeService.instance.init();
    // 手柄适配（A=确认/B=返回/方向键）：在按键进入 Flutter 的第一站做映射，
    // 复用全部既有按键逻辑，无需改动任何页面。
    GamepadInputService.instance.start();
    _startRemoteControl();
  }

  void _startRemoteControl() {
    // 手机控制服务常驻后台，固定端口 5025，APP 启动即开始监听，
    // 这样任意入口的二维码都能指向统一的手机设置页。
    RemoteInputService().deviceName = '海因影视 TV';
    RemoteInputService()
        .startServer()
        .then((url) => debugPrint('远程控制服务已启动: $url'))
        .catchError((e) => debugPrint('远程控制服务启动失败: $e'));
    // 账号处理器在 App 层常驻注册（与 tv_shell 生命周期解耦），保证切账号后
    // 手机端账号操作仍可由单例响应，无需重启 TV 才能再次切账号。
    RemoteInputService().setSubAccountHandler(
      (d) => handleRemoteSubAccount(d, _navigatorKey),
    );
    RemoteInputService().setAccountActionHandler(
      (d) => handleRemoteAccountAction(d, _navigatorKey),
    );
  }

  // 手机搜索跳转逻辑已迁移到 TvShell：搜索是 TvShell 的常驻 Tab（顶栏"搜索"，index 1），
  // 由 TvShell 监听 RemoteInputService 的命令/关键词流后切到该 Tab，而不是 push 一个独立
  // SearchScreen 路由——这样既不会"另开一个新页"，也避免了搜索 Tab 已被缓存导致永不跳转。

  @override
  void dispose() {
    if (Platform.isLinux || Platform.isWindows) {
      windowManager.removeListener(this);
    }
    ThemeModeService.instance.removeListener(_onThemeChanged);
    super.dispose();
  }

  /// 窗口关闭：**先把 mpv 内核彻底关掉**，再销毁窗口，最后无条件退出。
  ///
  /// 顺序不能反。mpv 的 render context 释放时要求 EGL 上下文 current，
  /// 一旦窗口先没了、EGL surface 失效，mpv_render_context_free 就会挂住，
  /// 进程永远退不出去——这正是之前「关闭卡死」的成因。
  @override
  Future<void> onWindowClose() async {
    debugPrint('HainTvApp 收到窗口关闭请求，开始关闭 mpv');
    // ① 关 mpv：让壳侧走完整 shutdown（释放 render context、销毁 EGL、
    //    terminate_destroy、join 事件线程）。最多等 3 秒，绝不无限等。
    try {
      await MpvDesktopBackend.shutdownEngine()
          .timeout(const Duration(seconds: 3));
      debugPrint('HainTvApp mpv 已关闭');
    } catch (e) {
      debugPrint('HainTvApp 关闭 mpv 异常/超时（忽略，继续退出）：$e');
    }
    // ② 刷日志（带超时）
    try {
      await AppLogger.flush().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('HainTvApp 刷日志异常/超时（忽略）：$e');
    }
    // ③ 销毁窗口
    try {
      await windowManager.destroy().timeout(const Duration(seconds: 2));
    } catch (e) {
      debugPrint('HainTvApp 销毁窗口异常/超时（忽略）：$e');
    }
    // ④ 无条件退出，保证进程不残留。
    exit(0);
  }

  void _onThemeChanged() {
    // 切换主题时重建 MaterialApp（setState 触发 build），所有页面与覆盖层随之
    // 按新主题重新读取 AppColors，实现全量刷新；不换 key，避免正在播放的视频页被
    // 整体销毁而卡死。
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    // 设置全屏模式，隐藏系统状态栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: '海因影视',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeModeService.instance.themeMode,
      // 注意：'/home' 不要写成 const TvShell()，否则主题切换时 identical 的 const 页面
      // 不重跑 build，AppColors 不重读、界面不刷新。每次返回新实例以触发整页重绘。
      routes: {
        '/home': (context) => TvShell(),
        '/login': (context) => const LoginScreen(),
      },
      home: const SplashScreen(target: SplashTarget.tv),
    );
  }
}
