import 'package:flutter/material.dart';
import 'package:hain_tv/screens/mobile/login_screen.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/splash_screen.dart';
import 'package:hain_tv/widgets/mobile/mobile_shell.dart';

class MobileApp extends StatefulWidget {
  const MobileApp({super.key});

  @override
  State<MobileApp> createState() => _MobileAppState();
}

class _MobileAppState extends State<MobileApp> {
  @override
  void initState() {
    super.initState();
    ThemeModeService.instance.addListener(_onThemeChanged);
    ThemeModeService.instance.init();
  }

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
    return MaterialApp(
      title: '海因影视',
      debugShowCheckedModeBanner: false,
      theme: buildLightTheme(),
      darkTheme: buildDarkTheme(),
      themeMode: ThemeModeService.instance.themeMode,
      // 注意：'/home' 路由不要写成 const MobileShell()，否则主题切换时 setState 重建
      // MaterialApp 会遇到 identical 的 const 页面而不重跑 build，导致 AppColors 不重读、
      // 界面不刷新。这里每次都返回新实例以触发整页重绘。
      routes: {
        '/home': (context) => MobileShell(),
        '/login': (context) => const MobileLoginScreen(),
      },
      home: const SplashScreen(target: SplashTarget.mobile),
    );
  }
}
