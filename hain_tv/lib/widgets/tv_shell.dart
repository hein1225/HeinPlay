import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/focusable.dart';
import '../screens/category_screen.dart';
import '../screens/home_screen.dart';
import '../screens/profile_screen.dart';
import '../screens/search_screen.dart';
import '../services/permission_service.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../utils/back_interceptor.dart';

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
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _checkFirstLaunch();
      if (mounted) {
        await _checkUpdate();
      }
    });
  }

  Future<void> _checkFirstLaunch() async {
    final isFirst = await PermissionService.isFirstLaunch();
    if (isFirst && mounted) {
      await PermissionService.showStoragePermissionDialog(context);
      await PermissionService.markFirstLaunchCompleted();
    }
  }

  Future<void> _checkUpdate() async {
    await UpdateService.checkAndPrompt(context, silent: true);
  }

  void _onNavTap(int index) {
    setState(() => _selectedIndex = index);
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
        }
      },
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;
        switch (event.logicalKey) {
          case LogicalKeyboardKey.arrowLeft:
            _moveNavFocus(-1);
            return KeyEventResult.handled;
          case LogicalKeyboardKey.arrowRight:
            _moveNavFocus(1);
            return KeyEventResult.handled;
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
                    color: isActive ? AppColors.primary : AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    item.label,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 15,
                      fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                      color: isActive ? AppColors.textPrimary : AppColors.textSecondary,
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
          if (event is! KeyDownEvent) return KeyEventResult.ignored;

          // 上键兜底：当页面内找不到上方焦点时，回到顶部导航栏
          if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
            final currentFocus = FocusManager.instance.primaryFocus;
            if (currentFocus != null && !_navFocusNodes.contains(currentFocus)) {
              // 搜索/我的页面、电影/电视剧/综艺/动漫分类页：按上直接回到当前顶部导航项，
              // 避免 ReadingOrderTraversalPolicy 按几何位置找到错误的导航项。
              if (_selectedIndex == 0 ||
                  _selectedIndex == 1 ||
                  (_selectedIndex >= 3 && _selectedIndex <= 6)) {
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
                    const Text(
                      '海因影视',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: AppColors.primary,
                      ),
                    ),
                    const Spacer(),
                    ..._items.asMap().entries.map((entry) {
                      return _buildNavItem(entry.value, entry.key);
                    }).toList(),
                  ],
                ),
              ),
              Container(
                height: 1,
                color: AppColors.border,
              ),
              Expanded(
                child: IndexedStack(
                  index: _selectedIndex,
                  children: const [
                    ProfileScreen(),
                    SearchScreen(),
                    HomeScreen(),
                    CategoryScreen(
                      kind: 'movie',
                      title: '电影',
                    ),
                    CategoryScreen(
                      kind: 'tv',
                      title: '电视剧',
                    ),
                    CategoryScreen(
                      kind: 'show',
                      title: '综艺',
                    ),
                    CategoryScreen(
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
