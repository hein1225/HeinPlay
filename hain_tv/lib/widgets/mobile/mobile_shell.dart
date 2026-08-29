import 'package:flutter/material.dart';
import 'package:hain_tv/screens/mobile/category_screen.dart';
import 'package:hain_tv/screens/mobile/home_screen.dart';
import 'package:hain_tv/screens/mobile/live_screen.dart';
import 'package:hain_tv/screens/mobile/profile_screen.dart';
import 'package:hain_tv/screens/mobile/search_screen.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _checkUpdate();
    });
  }

  Future<void> _checkUpdate() async {
    final channel = await UserDataService.getDefaultUpdateChannel();
    final updateChannel = channel == 'github'
        ? UpdateChannel.github
        : UpdateChannel.domestic;
    await UpdateService.checkAndPrompt(
      context,
      silent: true,
      channel: updateChannel,
      platform: 'mobile',
    );
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
      icon: Icon(Icons.live_tv_outlined),
      selectedIcon: Icon(Icons.live_tv),
      label: '直播',
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
        // 子项不要写成 const：主题切换时 MobileShell.build 重跑，需要这些页面返回新
        // 实例才能触发各自 build 重读 AppColors，实现整页刷新。
        children: [
          MobileHomeScreen(key: ValueKey('mobile_home')),
          MobileCategoryScreen(key: ValueKey('mobile_category')),
          MobileLiveScreen(key: ValueKey('mobile_live')),
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
