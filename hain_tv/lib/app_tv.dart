import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/tv/login_screen.dart';
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
    // 设置全屏模式，隐藏系统状态栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    return MaterialApp(
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
