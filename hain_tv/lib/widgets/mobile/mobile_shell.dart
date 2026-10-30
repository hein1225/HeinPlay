import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:hain_tv/screens/mobile/category_screen.dart';
import 'package:hain_tv/screens/mobile/home_screen.dart';
import 'package:hain_tv/screens/mobile/live_screen.dart';
import 'package:hain_tv/screens/mobile/profile_screen.dart';
import 'package:hain_tv/screens/mobile/search_screen.dart';
import 'package:hain_tv/services/glass_style_service.dart';
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
    GlassStyleService.instance.addListener(_onGlassChanged);
    // 从磁盘读取用户保存的磨砂档位（默认「关」）。不 await —— 首帧可先用默认值
    // 渲染，读取完成后 GlassStyleService 会 notifyListeners，由 _onGlassChanged
    // 重建导航栏，用户感知不到这一次补齐。
    GlassStyleService.instance.load();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) await _checkUpdate();
    });
  }

  void _onThemeChanged() {
    // 切主题时重建自身，重读 AppColors 实现整页刷新。播放页是独立路由，不受影响。
    if (mounted) setState(() {});
  }

  /// 磨砂档位变化（设置页切换）时重建导航栏。
  void _onGlassChanged() {
    if (mounted) setState(() {});
  }

  /// 磨砂是否开启。档位参数统一取自 [GlassStyleService]（与鸿蒙版同源）。
  bool get _glassNavBar => GlassStyleService.instance.enabled;

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
    GlassStyleService.instance.removeListener(_onGlassChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      // 🔴 2026-10-23：底部导航栏由「Scaffold 独立的 bottomNavigationBar 槽」
      // 改为「与内容同层 Stack 上的浮动磨砂层」（对齐鸿蒙版毛玻璃设计）。
      //
      // 【为什么改】原 NavigationBar 放 bottomNavigationBar 槽时，其背景（无论是否
      // 透明）都会遮住下方内容，BackdropFilter 无法「看到」背后内容做模糊。
      // 要让它浮在内容之上、背景半透明，才能实时模糊下方滚动的列表/画面。
      //
      // 【结构（关键）】内容层**铺满全屏、不在底部收缩** —— 否则导航栏背后只会是
      // 纯色 bgApp，BackdropFilter 模糊纯色等于没模糊，「强/中/弱」档位看不出差别。
      // 各分页滚动内容各自在底部留出导航栏高度（GlassStyleService.navBarTotalHeight），
      // 保证最后一行可滚到导航栏之上而不被永久遮挡。
      body: Container(
        color: AppColors.bgApp,
        child: Stack(
          children: [
            // 内容层：整页的多分页（首页/分类/直播/搜索/我的），铺满到底。
            Positioned.fill(
              child: Stack(
                children: [
                  for (int i = 0; i < _destinations.length; i++)
                    if (_builtTabs[i] != null || i == _selectedIndex) _fadeTab(i),
                ],
              ),
            ),
            // 磨砂玻璃导航栏：浮动于内容层之上；「关」档回退为实色普通栏。
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _glassNavBar ? _buildGlassNavBar() : _buildPlainNavBar(),
            ),
          ],
        ),
      ),
      // 底部导航栏已改为上方 body 内的浮动磨砂层。
    );
  }

  /// 磨砂玻璃底部导航栏：真实高斯模糊（BackdropFilter）＋半透明叠加＋顶部细分割线。
  ///
  /// 【实现要点】
  /// · `BackdropFilter(ImageFilter.blur(...))` 模糊其背后已绘制的内容（即下方滚动
  ///   的列表/画面），是「光线透出」的核心。
  /// · 内容必须真正画到导航栏区域之下（见 build 的 Stack），否则 Blur 只会模糊空白。
  /// · 叠加一层半透明 `bgSurface`（磨砂主色），保证图标/文字可读而不遮死背景。
  /// · 顶部细分割线用于区分内容与导航栏，磨砂下仍保持清晰的层级边界。
  /// · 底部手势条区由 NavigationBar 内置的 SafeArea 保留，该区域同样透出毛玻璃
  ///   → 沉浸光感一直延伸到底，不留实底死区。
  ///
  /// 与鸿蒙版 `mobile_shell.dart` 的同名方法保持同源同参数。
  Widget _buildGlassNavBar() {
    // 磨砂参数统一由 [GlassStyleService] 的当前档位（强/中/弱）提供：
    // 档位越低越透明、模糊越轻，兼顾观感与性能。随主题自动选择明/暗透明度。
    final glass = GlassStyleService.instance;
    final sigma = glass.sigma;
    final tint = AppColors.bgSurface.withValues(
      alpha: glass.alphaFor(
        isLight: ThemeModeService.instance.effectiveIsLight,
      ),
    );
    final navigationBar = NavigationBar(
      selectedIndex: _selectedIndex,
      onDestinationSelected: _onDestinationSelected,
      backgroundColor: Colors.transparent,
      indicatorColor: AppColors.primary.withValues(alpha: 0.2),
      height: _kNavigationBarHeight,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      destinations: _destinations,
    );

    return ClipRect(
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: sigma, sigmaY: sigma),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: tint,
            // 顶部细分割线：磨砂层上缘，区分内容层。
            border: Border(
              top: BorderSide(color: AppColors.border, width: 0.6),
            ),
          ),
          // 【为什么必须 removePadding(removeTop: true)】导航栏原本放在 Scaffold 的
          // bottomNavigationBar 槽，该槽会以 `removeTopPadding: true` 包裹子树
          // （scaffold.dart:3169-3171），因此栏体不会吃到状态栏高度。现在栏体被拆到
          // body 内（body 槽的 removeTopPadding 仅为 `appBar != null`，我们无 appBar
          // → false），若不再手动剥离，NavigationBar 内置的 SafeArea（默认 top/bottom
          // 均为 true，safe_area.dart:65-68）会把**状态栏高度**当作空白垫在图标上方，
          // 真机上就是「背景框上下太高、图标上方一大片空白」。
          // 剥掉顶部 padding 后，栏体 = 内容区 56dp + 底部手势条安全区，上下都紧凑。
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: navigationBar,
          ),
        ),
      ),
    );
  }

  /// 「关」档回退的普通底部导航栏（实色、无模糊）。
  Widget _buildPlainNavBar() {
    return MediaQuery.removePadding(
      context: context,
      removeTop: true,
      child: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: _onDestinationSelected,
        backgroundColor: AppColors.bgSurface,
        indicatorColor: AppColors.primary.withValues(alpha: 0.2),
        height: _kNavigationBarHeight,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: _destinations,
      ),
    );
  }

  /// 底部导航栏内容区高度（dp）。不含系统手势条安全区 —— 后者由 NavigationBar
  /// 内置的 SafeArea 自动保留（总高度 = 本值 + 安全区）。
  ///
  /// 【高度调校历史（2026-09-28，用户三轮反馈）】保留结论避免再错：
  ///   · 第一轮：只把 height 从 M3 默认 80 改成 64 → 用户说"没变化"。
  ///   · 第二轮：以为大头在安全区，把 padding.bottom 压到 40% →
  ///     用户明确纠正「我说的是导航栏**背景**，不是图标；而且安全区现在太小了」。
  ///   · 第三轮：两件事分开做 —— **背景块压矮** + **安全区恢复原样**。
  ///
  /// 【结构回顾】Flutter 的 NavigationBar 内部是
  ///     Material( SafeArea( SizedBox(height: effectiveHeight) ) )
  /// SafeArea 在外层，故：总高度 = height + padding.bottom。
  /// 用户看到"背景块太高"指的是 **height 这一项**（图标上下留白多），
  /// 而"安全区太小"指的是 SafeArea 那一项 —— 第二轮把后者压小，方向反了。
  ///
  /// 【取值】height = 56：M3 默认 80 偏松；56 能放下 64×32 指示器与 label，
  /// 仍满足 48dp 最小可点区域，图标上下留白明显收窄。
  /// 安全区 = 原值 100%（不压缩）：由组件自带 SafeArea 自动处理。
  ///
  /// ⚠️ 注意：鸿蒙版同位置常量为 68（见 GlassStyleService.navBarContentHeight），
  /// 那是为 M3 选中指示器胶囊（32dp）+ label 的 52dp 内容块留 8dp 余量的实测值。
  /// 本工程按用户要求压到 56，属**有意与鸿蒙版不同**，不要"顺手对齐"改回 68。
  /// 若后续还要更矮/更松，只调本常量即可。
  static const double _kNavigationBarHeight = 56;
}
