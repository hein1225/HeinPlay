import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/screens/tv/category_screen.dart';
import 'package:hain_tv/screens/tv/home_screen.dart';
import 'package:hain_tv/screens/tv/live_screen.dart';
import 'package:hain_tv/screens/tv/profile_screen.dart';
import 'package:hain_tv/screens/tv/search_screen.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/connectivity_service.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/utils/back_interceptor.dart';
import 'package:hain_tv/widgets/connection_status_badge.dart';

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
  int _selectedIndex = 3;
  // 焦点高亮随焦点立即移动；_selectedIndex 控制内容分页，延迟切换（见导航停留逻辑）。
  int _focusedIndex = 3;
  // 导航栏焦点停留计时器：焦点移动到某分类后停留 0.5 秒才切换内容分页，
  // 避免遥控器快速横移时反复重建分类页造成的卡顿。
  Timer? _navSwitchTimer;
  final List<FocusNode> _navFocusNodes = [];
  bool _exitDialogShowing = false;
  final _profileScreenKey = GlobalKey<ProfileScreenState>();
  final _searchScreenKey = GlobalKey<SearchScreenState>();
  final _liveScreenKey = GlobalKey<TvLiveScreenState>();
  final _homeScreenKey = GlobalKey<HomeScreenState>();
  final _movieScreenKey = GlobalKey<CategoryScreenState>();
  final _tvScreenKey = GlobalKey<CategoryScreenState>();
  final _showScreenKey = GlobalKey<CategoryScreenState>();
  final _animeScreenKey = GlobalKey<CategoryScreenState>();

  final List<_NavItem> _items = const [
    _NavItem(label: '我的', icon: Icons.person_outline),
    _NavItem(label: '搜索', icon: Icons.search),
    _NavItem(label: '直播', icon: Icons.live_tv_outlined),
    _NavItem(label: '首页', icon: Icons.home_outlined),
    _NavItem(label: '电影', icon: Icons.movie_outlined),
    _NavItem(label: '电视剧', icon: Icons.tv_outlined),
    _NavItem(label: '综艺', icon: Icons.emoji_emotions_outlined),
    _NavItem(label: '动漫', icon: Icons.animation_outlined),
  ];

  // 切页淡入淡出期间保留的旧分页索引（仅用于过渡期绘制，结束后置空）。
  int? _animatingFrom;
  // 已构建的导航页缓存：每个分页只构建一次并复用同一实例，切走后仍保留
  // Element/State（见 [_fadeTab] 的 Offstage 处理），实现“首次加载、后续缓存”，
  // 切换分页不再重新加载海报/数据，除非重启软件。
  final List<Widget?> _builtTabs = List<Widget?>.filled(8, null);

  @override
  void initState() {
    super.initState();
    ThemeModeService.instance.addListener(_onThemeChanged);
    for (int i = 0; i < _items.length; i++) {
      _navFocusNodes.add(FocusNode());
    }
    ConnectivityService.instance.startMonitoring();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        await _checkUpdate();
      }
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
      platform: AppInfoService.platform,
    );
  }

  void _onNavTap(int index) {
    // 显式点击/确认：立即切换（不等待停留计时），并取消可能存在的延迟切换。
    _navSwitchTimer?.cancel();
    if (mounted) {
      _focusedIndex = index;
      _selectIndex(index);
    }
    // 切换到“我的”分页时刷新播放记录与收藏夹，避免切回时仍显示旧数据。
    if (index == 0) {
      _profileScreenKey.currentState?.refresh();
    }
  }

  /// 构建对应索引的导航页；每个页面都带全局 Key，配合 AnimatedSwitcher 在
  /// 切走后保留 Element/State，实现“首次加载、后续缓存”的效果。
  Widget _buildTab(int index) {
    switch (index) {
      case 0:
        return ProfileScreen(key: _profileScreenKey);
      case 1:
        return SearchScreen(key: _searchScreenKey);
      case 2:
        return TvLiveScreen(
          key: _liveScreenKey,
          onRequestNavFocus: () {
            _navFocusNodes[2].requestFocus();
          },
        );
      case 3:
        return HomeScreen(key: _homeScreenKey);
      case 4:
        return CategoryScreen(
          key: _movieScreenKey,
          kind: 'movie',
          title: '电影',
        );
      case 5:
        return CategoryScreen(key: _tvScreenKey, kind: 'tv', title: '电视剧');
      case 6:
        return CategoryScreen(
          key: _showScreenKey,
          kind: 'show',
          title: '综艺',
        );
      case 7:
        return CategoryScreen(
          key: _animeScreenKey,
          kind: 'anime',
          title: '动漫',
        );
      default:
        return const SizedBox.shrink();
    }
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

  void _moveNavFocus(int direction) {
    final newIndex = (_focusedIndex + direction).clamp(0, _items.length - 1);
    if (newIndex != _focusedIndex) {
      // 仅移动焦点；内容分页切换交由 onFocusChange 的 0.5 秒停留计时器触发。
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
    final isActive = index == _focusedIndex;

    return Focus(
      focusNode: _navFocusNodes[index],
      autofocus: index == _selectedIndex,
      onFocusChange: (hasFocus) {
        if (hasFocus) {
          // 高亮立即跟随焦点移动。
          if (mounted) setState(() => _focusedIndex = index);
          // 内容分页延迟 0.5 秒切换：焦点停留满 0.5 秒才真正切到该分类页。
          _navSwitchTimer?.cancel();
          _navSwitchTimer = Timer(const Duration(milliseconds: 500), () {
            if (mounted && _navFocusNodes[index].hasFocus) {
              _selectIndex(index);
              // 焦点切到“我的”时刷新一次，确保数据最新。
              if (index == 0) _profileScreenKey.currentState?.refresh();
            }
          });
        } else {
          _navSwitchTimer?.cancel();
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
              _liveScreenKey.currentState?.requestListFocus();
              return KeyEventResult.handled;
            }
            if (index == 3) {
              _homeScreenKey.currentState?.focusFirstContent();
              return KeyEventResult.handled;
            }
            if (index == 4) {
              _movieScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            if (index == 5) {
              _tvScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            if (index == 6) {
              _showScreenKey.currentState?.focusFilterButton();
              return KeyEventResult.handled;
            }
            if (index == 7) {
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
            horizontal: 12,
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
          title: Text(
            '退出应用',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: Text(
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
                child: Text(
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
    ThemeModeService.instance.removeListener(_onThemeChanged);
    ConnectivityService.instance.stopMonitoring();
    _navSwitchTimer?.cancel();
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

          // 上键兜底：当页面内找不到上方焦点时，回到顶部导航栏。
          // 直播页（index 2）有自己的内部焦点导航（功能行 ↔ 列表 ↔ 预览），
          // 在此不做拦截，交给直播页自己的键盘处理器处理。
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            if (_selectedIndex == 2) {
              // 直播页：只要内部（功能行/源列表/预览区）持有焦点，
              // 上键就交给直播页自己处理，不做兜底跳回导航栏，避免焦点错误跳到"我的"或"电影"。
              final liveState = _liveScreenKey.currentState;
              if (liveState != null && liveState.hasInternalFocus) {
                return KeyEventResult.ignored;
              }
              // 直播页没有内部焦点时，回到顶部导航栏"直播"
              _navFocusNodes[2].requestFocus();
              return KeyEventResult.handled;
            }
            final currentFocus = FocusManager.instance.primaryFocus;
            if (currentFocus != null &&
                !_navFocusNodes.contains(currentFocus)) {
              // 首页、搜索/直播/我的页面、电影/电视剧/综艺/动漫分类页：按上直接回到当前顶部导航项，
              // 避免 ReadingOrderTraversalPolicy 按几何位置找到错误的导航项。
              if (_selectedIndex >= 0 && _selectedIndex <= 7) {
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
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: Row(
                  children: [
                    Text(
                      '海因影视',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 28,
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
                    const SizedBox(width: AppSpacing.sm),
                    const ConnectionStatusBadge(),
                    const Spacer(),
                    ..._items.asMap().entries.map((entry) {
                      return _buildNavItem(entry.value, entry.key);
                    }).toList(),
                  ],
                ),
              ),
              Container(height: 1, color: AppColors.border),
              Expanded(
                // 导航分页切换使用淡入淡出（新分页渐变覆盖旧分页）；
                // 每个访问过的分页都通过 [_getTab] 懒构建并缓存，切走后仅离屏隐藏
                // （Element/State 仍保留，见 [_fadeTab]），实现“首次加载、后续缓存”，
                // 切换分页不再重新加载海报/数据，除非重启软件。
                child: Container(
                  color: AppColors.bgApp,
                  child: Stack(
                    children: [
                      for (int i = 0; i < _items.length; i++)
                        if (_builtTabs[i] != null || i == _selectedIndex)
                          _fadeTab(i),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
