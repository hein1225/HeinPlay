import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../../platform/device_utils.dart';
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

/// Linux 桌面版外壳：复用 Windows 桌面布局，并在 [DeviceUtils.isTvOverride] 为真时
/// 继承 TV 版焦点导航（方向键/Enter/Esc）。配合 Steam Input 手柄映射即可在
/// Steam Deck 等掌机上用手柄操作；GTK 嵌入同时兼容 X11 与 Wayland。
class LinuxShell extends StatefulWidget {
  const LinuxShell({super.key});

  @override
  State<LinuxShell> createState() => _LinuxShellState();
}

class _LinuxShellState extends State<LinuxShell> {
  int _selectedIndex = 3;
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
    final channel = await UserDataService.getDefaultUpdateChannel();
    final updateChannel = channel == 'github'
        ? UpdateChannel.github
        : UpdateChannel.domestic;
    await UpdateService.checkAndPrompt(
      context,
      silent: true,
      channel: updateChannel,
      platform: 'linux',
    );
  }

  void _onNavTap(int index) {
    setState(() => _selectedIndex = index);
    // 切换到“我的”分页时刷新播放记录与收藏夹，避免 IndexedStack 保留旧数据。
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
  }

  /// 非首页标签按需挂载：仅当选中时才构建并挂载，切走即卸载释放内存。
  /// 首页（index 3）由 _LinuxShellState 常驻，不在本方法内。
  Widget _buildTab(int index) {
    switch (index) {
      case 0:
        return ProfileScreen(key: _profileScreenKey);
      case 1:
        return SearchScreen(key: _searchScreenKey);
      case 2:
        return WindowsLiveScreen(key: _liveScreenKey);
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

  void _handleBack() {
    // 先让已注册的页面拦截器处理（如分类页关闭筛选面板）
    if (BackInterceptor.intercept()) return;
    // 桌面端（Windows/Linux）直接关闭窗口。
    if (DeviceUtils.isDesktop) {
      windowManager.close();
    } else {
      SystemNavigator.pop();
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

  /// 键盘方向键切换顶部导航（TV 版焦点控制的桌面变体）。
  KeyEventResult _handleNavKey(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // 焦点在输入框内时交给输入框自行处理（如回车搜索、方向键移动光标）。
    if (_isEditing()) {
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
                child: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    // 首页常驻底层：切回首页零重建、瞬时响应；其余标签仅选中时挂载
                    // （最多同时 2 个常驻），切走即卸载释放内存，规避 IndexedStack
                    // 8 标签全常驻的内存压力。
                    HomeScreen(key: _homeScreenKey),
                    if (_selectedIndex != 3)
                      Container(
                        color: AppColors.bgApp,
                        child: _buildTab(_selectedIndex),
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
