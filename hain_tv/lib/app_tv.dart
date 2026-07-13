import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/screens/tv/login_screen.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/tv/tv_shell.dart';

class HainTvApp extends StatelessWidget {
  const HainTvApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 设置全屏模式，隐藏系统状态栏
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    
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
