import 'package:flutter/material.dart';
import 'package:hain_tv/screens/mobile/login_screen.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_shell.dart';

class MobileApp extends StatelessWidget {
  const MobileApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '海因影视',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      routes: {
        '/home': (context) => const MobileShell(),
        '/login': (context) => const MobileLoginScreen(),
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
          return loggedIn ? const MobileShell() : const MobileLoginScreen();
        },
      ),
    );
  }
}
