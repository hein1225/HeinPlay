import 'dart:async';

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

  final _homeScreenKey = GlobalKey();
  final _categoryScreenKey = GlobalKey();
  final _liveScreenKey = GlobalKey();
  final _searchScreenKey = GlobalKey();
  final _profileScreenKey = GlobalKey();

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

  // 切页淡入淡出期间保留的旧分页索引（仅用于过渡期绘制，结束后置空）。
  int? _animatingFrom;
  // 已构建的导航页缓存：每个分页只构建一次并复用同一实例，切走后仍保留
  // Element/State（见 [_fadeTab] 的 Offstage 处理），实现“首次加载、后续缓存”。
  final List<Widget?> _builtTabs = List<Widget?>.filled(5, null);

  void _onDestinationSelected(int index) {
    _selectIndex(index);
  }

  /// 切换导航分页，并在切页期间保留旧页以实现淡入淡出；
  /// 所有访问过的分页都带全局 Key 并被缓存（见 [_getTab]），切走后 Element/State
  /// 仍在树中（仅离屏隐藏），实现“首次加载、后续缓存”，切换不再重新加载数据。
  void _selectIndex(int index) {
    if (_selectedIndex == index) return;
    _animatingFrom = _selectedIndex;
    _selectedIndex = index;
    // 淡入淡出结束后停止保留旧页的绘制（旧页仍常驻缓存，仅不再绘制）。
    Timer(const Duration(milliseconds: 260), () {
      if (mounted && _animatingFrom != null) setState(() => _animatingFrom = null);
    });
    setState(() {});
  }

  /// 懒构建并缓存对应索引的导航页；每个页面只构建一次，之后复用同一实例以保留状态。
  Widget _getTab(int index) => _builtTabs[index] ??= _buildTab(index);

  /// 单个导航页的包装：选中页不透明可交互；切页过程中旧页短暂绘制以完成淡出；
  /// 其余已缓存页离屏隐藏（保留状态、不绘制、不接收焦点），节省绘制开销。
  Widget _fadeTab(int i) {
    final selected = i == _selectedIndex;
    final animating = i == _animatingFrom;
    return Offstage(
      offstage: !selected && !animating,
      child: IgnorePointer(
        ignoring: !selected,
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 220),
          opacity: selected ? 1.0 : 0.0,
          child: _getTab(i),
        ),
      ),
    );
  }

  /// 构建对应索引的导航页；每个页面都带全局 Key，配合 AnimatedSwitcher 在
  /// 切走后保留 Element/State，实现“首次加载、后续缓存”的效果。
  Widget _buildTab(int index) {
    switch (index) {
      case 0:
        return MobileHomeScreen(key: _homeScreenKey);
      case 1:
        return MobileCategoryScreen(key: _categoryScreenKey);
      case 2:
        return MobileLiveScreen(key: _liveScreenKey);
      case 3:
        return MobileSearchScreen(key: _searchScreenKey);
      case 4:
        return MobileProfileScreen(key: _profileScreenKey);
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
      body: Container(
        color: AppColors.bgApp,
        child: Stack(
          children: [
            for (int i = 0; i < _destinations.length; i++)
              if (_builtTabs[i] != null || i == _selectedIndex) _fadeTab(i),
          ],
        ),
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
