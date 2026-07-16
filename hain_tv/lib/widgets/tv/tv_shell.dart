import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/screens/tv/category_screen.dart';
import 'package:hain_tv/screens/tv/home_screen.dart';
import 'package:hain_tv/screens/tv/profile_screen.dart';
import 'package:hain_tv/screens/tv/search_screen.dart';
import 'package:hain_tv/services/connectivity_service.dart';
import 'package:hain_tv/services/permission_service.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/back_interceptor.dart';
import 'package:hain_tv/platform/device_utils.dart';

class _NavItem {
  final String label;
  final IconData icon;

  const _NavItem({required this.label, required this.icon});
}

class TvShell extends StatefulWidget {
  const TvShell({super.key});

  @override
  State<TvShell> createState() => _TvShellState();
}

class _TvShellState extends State<TvShell> {
  int _selectedIndex = 2;
  final List<FocusNode> _navFocusNodes = [];
  bool _exitDialogShowing = false;
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
    for (int i = 0; i < _items.length; i++) {
      _navFocusNodes.add(FocusNode());
    }
    ConnectivityService.instance.startMonitoring();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkFirstLaunch();
      if (mounted) {
        await _checkUpdate();
      }
    });
  }

  Future<void> _checkFirstLaunch() async {
    if (DeviceUtils.isDesktop) {
      await PermissionService.markFirstLaunchCompleted();
      return;
    }
    final isFirst = await PermissionService.isFirstLaunch();
    if (isFirst && mounted) {
      await PermissionService.showStoragePermissionDialog(context);
      await PermissionService.markFirstLaunchCompleted();
    }
  }

  Future<void> _checkUpdate() async {
    final platform = DeviceUtils.isWindows ? 'windows' : 'tv';
    await UpdateService.checkAndPrompt(
      context,
      silent: true,
      channel: UpdateChannel.domestic,
      platform: platform,
    );
  }

  void _onNavTap(int index) {
    setState(() => _selectedIndex = index);
    // 切换到“我的”分页时刷新播放记录与收藏夹，避免 IndexedStack 保留旧数据。
    if (index == 0) {
      _profileScreenKey.currentState?.refresh();
    }
  }

  void _moveNavFocus(int direction) {
    final newIndex = (_selectedIndex + direction).clamp(0, _items.length - 1);
    if (newIndex != _selectedIndex) {
      setState(() => _selectedIndex = newIndex);
      _navFocusNodes[newIndex].requestFocus();
    }
  }

  void _handleBack() {
    if (_exitDialogShowing) return;
    // 先让已注册的页面拦截器处理（如分类页关闭筛选面板）
    if (BackInterceptor.intercept()) return;
    _showExitDialog();
  }

  Widget _buildNavItem(_NavItem item, int index) {
    final isActive = index == _selectedIndex;

    return Focus(
      focusNode: _navFocusNodes[index],
      autofocus: index == _selectedIndex,
      onFocusChange: (hasFocus) {
        if (hasFocus) {
          setState(() => _selectedIndex = index);
          // 焦点切到“我的”时也刷新一次，确保遥控/键盘切页后数据最新。
          if (index == 0) {
            _profileScreenKey.currentState?.refresh();
          }
        }
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowLeft:
            _moveNavFocus(-1);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowRight:
            _moveNavFocus(1);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowUp:
            // 顶部导航栏已经是最顶层，按上键时阻止焦点继续向上或跳到其他导航项
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowDown:
            // 从顶部导航栏按下键时，将焦点直接移动到当前页面的首个输入区域，
            // 避免 ReadingOrderTraversalPolicy 在 IndexedStack 的隐藏页面中找不到焦点。
            if (index == 1) {
              _searchScreenKey.currentState?.requestSearchBoxFocus();
              return KeyEventResult.handled;
            }
            if (index == 2) {
              _homeScreenKey.currentState?.focusFirstContent();
              return KeyEventResult.handled;
            }
            if (index == 3) {
              _movieScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            if (index == 4) {
              _tvScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            if (index == 5) {
              _showScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            if (index == 6) {
              _animeScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          case LogicalKeyboardKey.select:
          case LogicalKeyboardKey.enter:
            _onNavTap(index);
            return KeyEventResult.handled;
          default:
            return KeyEventResult.ignored;
        }
      },
      child: GestureDetector(
        onTap: () => _onNavTap(index),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
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
      ),
    );
  }

  void _showExitDialog() {
    if (_exitDialogShowing) return;
    _exitDialogShowing = true;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: const Text(
            '退出应用',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: const Text(
            '确定要退出海因影视吗？',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              color: AppColors.textSecondary,
            ),
          ),
          actions: [
            FocusableWidget(
              autofocus: true,
              onTap: () {
                _exitDialogShowing = false;
                Navigator.of(ctx).pop();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: Colors.transparent,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(color: AppColors.border),
                ),
                child: const Text(
                  '取消',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            FocusableWidget(
              onTap: () {
                _exitDialogShowing = false;
                Navigator.of(ctx).pop();
                SystemNavigator.pop();
              },
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '确认退出',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    ).then((_) {
      _exitDialogShowing = false;
    });
  }

  @override
  void dispose() {
    ConnectivityService.instance.stopMonitoring();
    for (var node in _navFocusNodes) {
      node.dispose();
    }
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
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }

          // 上键兜底：当页面内找不到上方焦点时，回到顶部导航栏
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            final currentFocus = FocusManager.instance.primaryFocus;
            if (currentFocus != null &&
                !_navFocusNodes.contains(currentFocus)) {
              // 首页、搜索/我的页面、电影/电视剧/综艺/动漫分类页：按上直接回到当前顶部导航项，
              // 避免 ReadingOrderTraversalPolicy 按几何位置找到错误的导航项。
              if (_selectedIndex >= 0 && _selectedIndex <= 6) {
                _navFocusNodes[_selectedIndex].requestFocus();
                return KeyEventResult.handled;
              }
              final policy = ReadingOrderTraversalPolicy();
              final candidate = policy.findFirstFocusInDirection(
                currentFocus,
                TraversalDirection.up,
              );
              if (candidate == null || candidate == currentFocus) {
                _navFocusNodes[_selectedIndex].requestFocus();
                return KeyEventResult.handled;
              }
            }
          }

          return KeyEventResult.ignored;
        },
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
