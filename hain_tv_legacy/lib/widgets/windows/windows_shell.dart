import 'dart:io';

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../screens/windows/category_screen.dart';
import '../../screens/windows/home_screen.dart';
import '../../screens/windows/live_screen.dart';
import '../../screens/windows/profile_screen.dart';
import '../../screens/windows/search_screen.dart';
import '../../services/connectivity_service.dart';
import '../../services/update_service.dart';
import '../../services/user_data_service.dart';
import '../../theme.dart';
import '../../utils/back_interceptor.dart';
import '../../widgets/connection_status_badge.dart';

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
  int _selectedIndex = 3;
  // 顶部导航栏各分类项的焦点节点：供方向键在导航栏与内容区之间做“逻辑”路由
  // （而非 Flutter 默认几何遍历），与 TV 版 TvShell 一致。
  final List<FocusNode> _navFocusNodes = [];
  final _profileScreenKey = GlobalKey<ProfileScreenState>();
  final _searchScreenKey = GlobalKey<SearchScreenState>();
  final _liveScreenKey = GlobalKey<WindowsLiveScreenState>();
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

  // 退出确认对话框是否已显示：避免 ESC / 鼠标右键连按弹出多个确认框。
  bool _exitConfirmVisible = false;
  // 已构建的导航页缓存：每个分页只构建一次并复用同一实例，切走后仍保留
  // Element/State（见 [_fadeTab] 的 Offstage 处理），实现“首次加载、后续缓存”。
  final List<Widget?> _builtTabs = List<Widget?>.filled(8, null);

  @override
  void initState() {
    super.initState();
    for (int i = 0; i < _items.length; i++) {
      _navFocusNodes.add(FocusNode(debugLabel: 'winNav_${_items[i].label}'));
    }
    ConnectivityService.instance.startMonitoring();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        await _checkUpdate();
      }
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
      platform: 'windows',
    );
  }

  void _onNavTap(int index) {
    _selectIndex(index);
    // 切换到“我的”分页时刷新播放记录与收藏夹，避免切回时仍显示旧数据。
    if (index == 0) {
      _profileScreenKey.currentState?.refresh();
    }
    // 切换到搜索页时让搜索框获得焦点，便于键盘/遥控器直接输入。
    if (index == 1) {
      _searchScreenKey.currentState?.requestSearchBoxFocus();
    }
    // 切换到直播页时让频道列表获得焦点，便于键盘直接选择。
    if (index == 2) {
      _liveScreenKey.currentState?.requestListFocus();
    }
    // 鼠标点击/确认后把焦点拉回顶部导航项，避免焦点仍残留在内容区，
    // 导致后续方向键无法在分类页之间正常移动（与 TV 版一致）。
    _navFocusNodes[index].requestFocus();
  }

  /// 导航栏某分类项按“下”时，把焦点送进当前分类页内容的首个可聚焦区域。
  /// 这里是“逻辑移动”：无论焦点在分类行的哪个位置，都进入对应页首个元素，
  /// 而非 Flutter 默认几何遍历（与 TV 版 TvShell 一致）。
  void _enterContent(int index) {
    switch (index) {
      case 0:
        _profileScreenKey.currentState?.focusFirstContent();
      case 1:
        _searchScreenKey.currentState?.requestSearchBoxFocus();
      case 2:
        _liveScreenKey.currentState?.requestListFocus();
      case 3:
        _homeScreenKey.currentState?.focusFirstContent();
      case 4:
        _movieScreenKey.currentState?.focusFilterButton();
      case 5:
        _tvScreenKey.currentState?.focusFilterButton();
      case 6:
        _showScreenKey.currentState?.focusFilterButton();
      case 7:
        _animeScreenKey.currentState?.focusFilterButton();
    }
  }

  /// 导航栏单个分类项的键盘处理：左/右在分类间移动（并即时切页）、上为顶部拦截、
  /// 下进入内容、确认键切页并聚焦。与 TV 版 TvShell._buildNavItem 的 onKeyEvent 对齐。
  KeyEventResult _handleNavItemKey(int index, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 焦点在输入框（搜索框）内时交给输入框自行处理。
    if (_isEditing()) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        final newIndex = (index - 1).clamp(0, _items.length - 1);
        if (newIndex != index) {
          _navFocusNodes[newIndex].requestFocus();
          _onNavTap(newIndex);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        final newIndex = (index + 1).clamp(0, _items.length - 1);
        if (newIndex != index) {
          _navFocusNodes[newIndex].requestFocus();
          _onNavTap(newIndex);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        // 顶部导航栏已是最顶层，拦截上键避免焦点乱跳。
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        // 当前分类页已即时切换显示，把焦点直接送进内容首个可聚焦区域。
        _enterContent(index);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        _onNavTap(index);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// 构建对应索引的导航页；每个页面都带全局 Key，配合 AnimatedSwitcher 在
  /// 切走后保留 Element/State，实现“首次加载、后续缓存”的效果。
  Widget _buildTab(int index) {
    switch (index) {
      case 0:
        return ProfileScreen(key: _profileScreenKey);
      case 1:
        return SearchScreen(
          key: _searchScreenKey,
          // 搜索框内按“上”将焦点交回顶部导航栏。
          onRequestNavFocus: () => _navFocusNodes[1].requestFocus(),
        );
      case 2:
        return WindowsLiveScreen(key: _liveScreenKey);
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

  /// 首页 / 各分类页按返回（ESC、鼠标右键、播放器外的返回键）时的统一处理。
  ///
  /// 顺序：先让已注册的页面拦截器处理（如分类页关闭筛选面板）；没有任何可返回的
  /// 层级时，**弹出退出确认对话框**而不是直接关掉应用 —— 首页与「我的 / 搜索 /
  /// 直播 / 电影」等分类页都属于“最外层”，在这里直接退应用会让用户误触即退出。
  Future<void> _handleBack() async {
    // 先让已注册的页面拦截器处理（如分类页关闭筛选面板）
    if (BackInterceptor.intercept()) return;
    if (!Platform.isWindows) {
      SystemNavigator.pop();
      return;
    }
    // 防止连按 ESC / 连续右键弹出多个确认框
    if (_exitConfirmVisible) return;
    if (!mounted) return;
    _exitConfirmVisible = true;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(
          '退出海因影视',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          '确定要退出应用吗？',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(
              '取消',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: AppColors.textSecondary,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              '退出',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: AppColors.primary,
              ),
            ),
          ),
        ],
      ),
    );
    _exitConfirmVisible = false;
    if (confirmed == true) {
      await windowManager.close();
    }
  }

  /// 当前焦点是否在文本输入框内。
  ///
  /// 搜索框等编辑区域获得焦点时，顶部导航不应再消费方向键/回车键，
  /// 否则会导致搜索框内按回车无法触发搜索、按左右方向键切换页面。
  bool _isEditing() {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) return false;
    return focus.context!.findAncestorWidgetOfExactType<EditableText>() != null;
  }

  /// 键盘方向键切换顶部导航。
  /// 左/右/确认键：导航栏持焦点时由 [_handleNavItemKey] 处理；此处作为内容区的兜底，
  /// 在内容区按左/右仍可切页（保留 Windows 原有便捷行为）。
  /// 上键兜底：内容区内按上回到当前顶部导航栏（逻辑移动，非几何遍历），与 TV 版一致。
  KeyEventResult _handleNavKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 焦点在输入框内时交给输入框自行处理（如回车搜索、方向键移动光标）。
    if (_isEditing()) {
      return KeyEventResult.ignored;
    }
    // 上键兜底：当焦点在内容区（非导航栏）时，回到当前顶部导航项。
    // 直播页（index 2）有自己的内部焦点导航（功能行 ↔ 列表 ↔ 预览），
    // 在其内部持焦点时上键交给直播页自己处理，不做兜底跳回导航栏。
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final currentFocus = FocusManager.instance.primaryFocus;
      if (currentFocus != null && !_navFocusNodes.contains(currentFocus)) {
        if (_selectedIndex == 2) {
          final liveState = _liveScreenKey.currentState;
          if (liveState != null && liveState.hasInternalFocus) {
            return KeyEventResult.ignored;
          }
          _navFocusNodes[2].requestFocus();
          return KeyEventResult.handled;
        }
        if (_selectedIndex >= 0 && _selectedIndex <= 7) {
          _navFocusNodes[_selectedIndex].requestFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        final newIndex = (_selectedIndex - 1).clamp(0, _items.length - 1);
        if (newIndex != _selectedIndex) _onNavTap(newIndex);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        final newIndex = (_selectedIndex + 1).clamp(0, _items.length - 1);
        if (newIndex != _selectedIndex) _onNavTap(newIndex);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.select:
        _onNavTap(_selectedIndex);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildNavItem(_NavItem item, int index) {
    final isActive = index == _selectedIndex;

    return Focus(
      focusNode: _navFocusNodes[index],
      autofocus: index == _selectedIndex,
      debugLabel: 'winNavItem_${item.label}',
      onKeyEvent: (node, event) => _handleNavItemKey(index, node, event),
      child: InkWell(
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
      ),
    );
  }

  @override
  void dispose() {
    ConnectivityService.instance.stopMonitoring();
    for (final node in _navFocusNodes) {
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
                // （Element/State 仍保留，见 [_fadeTab]），实现“首次加载、后续缓存”。
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
