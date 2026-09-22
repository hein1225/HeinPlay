import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/tv/login_screen.dart';
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

class _HainTvAppState extends State<HainTvApp> {
  /// 全局导航 key：供 MaterialApp 管理路由栈（搜索跳转已迁移到 TvShell 的常驻 Tab）。
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
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
    ThemeModeService.instance.removeListener(_onThemeChanged);
    super.dispose();
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
