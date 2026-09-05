import 'package:flutter/material.dart';
import 'package:hain_tv/screens/mobile/category_screen.dart';
import 'package:hain_tv/screens/mobile/home_screen.dart';
import 'package:hain_tv/screens/mobile/live_screen.dart';
import 'package:hain_tv/screens/mobile/profile_screen.dart';
import 'package:hain_tv/screens/mobile/search_screen.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/services/theme_mode_service.dart';

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
    ThemeModeService.instance.addListener(_onThemeChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _checkUpdate();
    });
  }

  void _onThemeChanged() {
    // 切主题时重建自身，重读 AppColors 实现整页刷新。播放页是独立路由，不受影响。
    if (mounted) setState(() {});
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

  // 仅挂载当前选中的非首页标签；切走即卸载，降低常驻内存占用。
  Widget _buildTab(int index) {
    switch (index) {
      case 1:
        return MobileCategoryScreen(key: ValueKey('mobile_category'));
      case 2:
        return MobileLiveScreen(key: ValueKey('mobile_live'));
      case 3:
        return MobileSearchScreen(key: ValueKey('mobile_search'));
      case 4:
        return MobileProfileScreen(key: ValueKey('mobile_profile'));
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  void dispose() {
    ThemeModeService.instance.removeListener(_onThemeChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          // 首页常驻底层：切回首页时无需重新挂载/重建，避免旧手机低内存下卡死。
          // 其余标签仅当选中时挂载，切走即卸载释放内存（原 IndexedStack 会常驻全部 5 个标签，
          // 约 84 张海报 + 分类/直播/搜索/我的列表常驻，低内存设备切换时易卡死）。
          MobileHomeScreen(key: ValueKey('mobile_home')),
          if (_selectedIndex != 0)
            Container(
              color: AppColors.bgApp,
              child: _buildTab(_selectedIndex),
            ),
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
