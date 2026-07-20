import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../screens/windows/category_screen.dart';
import '../../screens/windows/home_screen.dart';
import '../../screens/windows/profile_screen.dart';
import '../../screens/windows/search_screen.dart';
import '../../services/connectivity_service.dart';
import '../../services/update_service.dart';
import '../../theme.dart';
import '../../utils/back_interceptor.dart';

class _NavItem {
  final String label;
  final IconData icon;

  const _NavItem({required this.label, required this.icon});
}

class WindowsShell extends StatefulWidget {
  const WindowsShell({super.key});

  @override
  State<WindowsShell> createState() => _WindowsShellState();
}

class _WindowsShellState extends State<WindowsShell> {
  int _selectedIndex = 2;
  final _profileScreenKey = GlobalKey<ProfileScreenState>();
  final _searchScreenKey = GlobalKey<SearchScreenState>();
  final _homeScreenKey = GlobalKey<HomeScreenState>();
  final _movieScreenKey = GlobalKey<CategoryScreenState>();
  final _tvScreenKey = GlobalKey<CategoryScreenState>();
  final _showScreenKey = GlobalKey<CategoryScreenState>();
  final _animeScreenKey = GlobalKey<CategoryScreenState>();

  final List<_NavItem> _items = const [
    _NavItem(label: '我的', icon: Icons.person_outline),
    _NavItem(label: '搜索', icon: Icons.search),
    _NavItem(label: '首页', icon: Icons.home_outlined),
    _NavItem(label: '电影', icon: Icons.movie_outlined),
    _NavItem(label: '电视剧', icon: Icons.tv_outlined),
    _NavItem(label: '综艺', icon: Icons.emoji_emotions_outlined),
    _NavItem(label: '动漫', icon: Icons.animation_outlined),
  ];

  @override
  void initState() {
    super.initState();
    ConnectivityService.instance.startMonitoring();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        await _checkUpdate();
      }
    });
  }

  Future<void> _checkUpdate() async {
    await UpdateService.checkAndPrompt(
      context,
      silent: true,
      channel: UpdateChannel.domestic,
      platform: 'windows',
    );
  }

  void _onNavTap(int index) {
    setState(() => _selectedIndex = index);
    // 切换到“我的”分页时刷新播放记录与收藏夹，避免 IndexedStack 保留旧数据。
    if (index == 0) {
      _profileScreenKey.currentState?.refresh();
    }
  }

  void _handleBack() {
    // 先让已注册的页面拦截器处理（如分类页关闭筛选面板）
    if (BackInterceptor.intercept()) return;
    // Windows 端退出不显示确认对话框，直接关闭窗口。
    if (Platform.isWindows) {
      windowManager.close();
    } else {
      SystemNavigator.pop();
    }
  }

  /// 键盘方向键切换顶部导航。
  KeyEventResult _handleNavKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        final newIndex = (_selectedIndex - 1).clamp(0, _items.length - 1);
        _onNavTap(newIndex);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        final newIndex = (_selectedIndex + 1).clamp(0, _items.length - 1);
        _onNavTap(newIndex);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.select:
        _onNavTap(_selectedIndex);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildNavItem(_NavItem item, int index) {
    final isActive = index == _selectedIndex;

    return InkWell(
      onTap: () => _onNavTap(index),
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isActive
              ? AppColors.primary.withValues(alpha: 0.12)
              : Colors.transparent,
          border: Border.all(
            color: isActive ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(AppRadius.sm),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  item.icon,
                  size: 18,
                  color: isActive
                      ? AppColors.primary
                      : AppColors.textSecondary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  item.label,
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 15,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                    color: isActive
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 2,
              width: isActive ? 24 : 0,
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  void dispose() {
    ConnectivityService.instance.stopMonitoring();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Focus(
        onKeyEvent: (node, event) => _handleNavKey(event),
        child: Scaffold(
          backgroundColor: AppColors.bgApp,
          body: Column(
            children: [
              Container(
                height: 56,
                color: AppColors.bgSurface,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
                child: Row(
                  children: [
                    Text(
                      '海因影视',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 26,
                        fontWeight: FontWeight.w900,
                        color: AppColors.primary,
                        letterSpacing: 1.2,
                        shadows: [
                          Shadow(
                            color: AppColors.primary.withValues(alpha: 0.45),
                            blurRadius: 10,
                            offset: const Offset(0, 0),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    ValueListenableBuilder<bool>(
                      valueListenable:
                          ConnectivityService.instance.isServerConnected,
                      builder: (context, connected, child) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: connected
                                ? AppColors.success
                                : AppColors.error,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                          ),
                          child: Text(
                            connected ? '已连接服务器' : '服务器未连接',
                            style: const TextStyle(
                              fontFamily: 'NotoSansSC',
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                            ),
                          ),
                        );
                      },
                    ),
                    const Spacer(),
                    ..._items.asMap().entries.map((entry) {
                      return _buildNavItem(entry.value, entry.key);
                    }).toList(),
                  ],
                ),
              ),
              Container(height: 1, color: AppColors.border),
              Expanded(
                child: IndexedStack(
                  index: _selectedIndex,
                  children: [
                    ProfileScreen(key: _profileScreenKey),
                    SearchScreen(key: _searchScreenKey),
                    HomeScreen(key: _homeScreenKey),
                    CategoryScreen(
                      key: _movieScreenKey,
                      kind: 'movie',
                      title: '电影',
                    ),
                    CategoryScreen(key: _tvScreenKey, kind: 'tv', title: '电视剧'),
                    CategoryScreen(
                      key: _showScreenKey,
                      kind: 'show',
                      title: '综艺',
                    ),
                    CategoryScreen(
                      key: _animeScreenKey,
                      kind: 'anime',
                      title: '动漫',
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
