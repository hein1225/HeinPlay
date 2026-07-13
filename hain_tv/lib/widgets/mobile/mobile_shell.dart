import 'package:flutter/material.dart';
import 'package:hain_tv/screens/mobile/category_screen.dart';
import 'package:hain_tv/screens/mobile/home_screen.dart';
import 'package:hain_tv/screens/mobile/profile_screen.dart';
import 'package:hain_tv/screens/mobile/search_screen.dart';
import 'package:hain_tv/services/permission_service.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/theme.dart';

class MobileShell extends StatefulWidget {
  const MobileShell({super.key});

  @override
  State<MobileShell> createState() => _MobileShellState();
}

class _MobileShellState extends State<MobileShell> {
  int _selectedIndex = 0;

  @override
  void initState() {
    super.initState();
    _checkFirstLaunchPermission();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _checkUpdate();
    });
  }

  Future<void> _checkUpdate() async {
    await UpdateService.checkAndPrompt(
      context,
      silent: true,
      channel: UpdateChannel.domestic,
      platform: 'mobile',
    );
  }

  Future<void> _checkFirstLaunchPermission() async {
    final isFirst = await PermissionService.isFirstLaunch();
    if (isFirst && mounted) {
      await PermissionService.showStoragePermissionDialog(context);
      await PermissionService.markFirstLaunchCompleted();
    }
  }

  final List<NavigationDestination> _destinations = const [
    NavigationDestination(
      icon: Icon(Icons.home_outlined),
      selectedIcon: Icon(Icons.home),
      label: '首页',
    ),
    NavigationDestination(
      icon: Icon(Icons.category_outlined),
      selectedIcon: Icon(Icons.category),
      label: '分类',
    ),
    NavigationDestination(
      icon: Icon(Icons.search_outlined),
      selectedIcon: Icon(Icons.search),
      label: '搜索',
    ),
    NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: '我的',
    ),
  ];

  void _onDestinationSelected(int index) {
    setState(() => _selectedIndex = index);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: IndexedStack(
        index: _selectedIndex,
        children: const [
          MobileHomeScreen(key: ValueKey('mobile_home')),
          MobileCategoryScreen(key: ValueKey('mobile_category')),
          MobileSearchScreen(key: ValueKey('mobile_search')),
          MobileProfileScreen(key: ValueKey('mobile_profile')),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        backgroundColor: AppColors.bgSurface,
        indicatorColor: AppColors.primary.withValues(alpha: 0.2),
        destinations: _destinations,
      ),
    );
  }
}
