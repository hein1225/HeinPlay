import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../focus/focusable.dart';
import '../models/bangumi_calendar_item.dart';
import '../models/douban_movie.dart';
import '../models/douban_recommends_params.dart';
import '../services/bangumi_service.dart';
import '../services/douban_service.dart';
import '../models/api_response.dart';
import '../theme.dart';
import '../utils/back_interceptor.dart';
import '../widgets/tv_grid.dart';
import 'detail_screen.dart';

class _OptionItem {
  final String label;
  final String value;

  const _OptionItem(this.label, this.value);
}

/// 自定义筛选按钮，使用 Focus 直接管理焦点，避免 FocusableWidget 外层 Focus 可能导致的焦点节点无法挂载问题。
class _DimensionButton extends StatefulWidget {
  final FocusNode focusNode;
  final VoidCallback onTap;
  final FocusOnKeyEventCallback onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final Widget child;

  const _DimensionButton({
    required this.focusNode,
    required this.onTap,
    required this.onKeyEvent,
    this.onFocusChange,
    required this.child,
  });

  @override
  State<_DimensionButton> createState() => _DimensionButtonState();
}

class _DimensionButtonState extends State<_DimensionButton> {
  bool _focused = false;

  void _onFocusChange(bool focused) {
    if (_focused == focused) return;
    setState(() => _focused = focused);
    widget.onFocusChange?.call(focused);
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    return widget.onKeyEvent(node, event);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onKeyEvent: _handleKeyEvent,
      onFocusChange: _onFocusChange,
      child: GestureDetector(
        onTap: () {
          widget.focusNode.requestFocus();
          widget.onTap();
        },
        child: MouseRegion(
          onEnter: (_) {},
          onExit: (_) {},
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: const EdgeInsets.all(AppSpacing.xs),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: _focused
                  ? Border.all(color: AppColors.primary, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
              boxShadow: _focused
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.3),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

class _FilterDimension {
  final String key;
  final String label;

  const _FilterDimension({required this.key, required this.label});
}

class _CategoryConfig {
  final String kind;
  final List<_OptionItem> primaryOptions;
  final List<_OptionItem> secondaryOptions;
  final String defaultPrimary;
  final String defaultSecondary;
  final String defaultFormat;
  final String defaultSort;

  const _CategoryConfig({
    required this.kind,
    required this.primaryOptions,
    required this.secondaryOptions,
    required this.defaultPrimary,
    required this.defaultSecondary,
    required this.defaultFormat,
    required this.defaultSort,
  });
}

class CategoryScreen extends StatefulWidget {
  final String kind;
  final String title;

  const CategoryScreen({
    super.key,
    required this.kind,
    required this.title,
  });

  @override
  State<CategoryScreen> createState() => CategoryScreenState();
}

class CategoryScreenState extends State<CategoryScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<DoubanMovie> _movies = [];
  bool _hasMore = true;
  bool _hasEverBeenVisible = false;

  late DoubanRecommendsParams _params;
  late String _selectedPrimary;
  late String _selectedSecondary;
  String? _activeDimension;
  int _dropdownCrossAxisCount = 1;
  final ScrollController _scrollController = ScrollController();
  final List<FocusNode> _categoryTagFocusNodes = [];
  final List<FocusNode> _secondaryTagFocusNodes = [];
  final Map<String, FocusNode> _dimensionButtonFocusNodes = {};
  final List<FocusNode> _dropdownOptionFocusNodes = [];
  final List<FocusNode> _posterFocusNodes = [];
  final List<FocusNode> _weekdayFocusNodes = [];
  BoxConstraints? _gridConstraints;

  List<BangumiCalendarItem> _bangumiCalendarItems = [];
  late String _selectedWeekday;

  // ===================== 分类选项（与 LunaTV DoubanSelector 一致） =====================

  static const _moviePrimaryOptions = [
    _OptionItem('全部', '全部'),
    _OptionItem('热门电影', '热门'),
    _OptionItem('最新电影', '最新'),
    _OptionItem('豆瓣高分', '豆瓣高分'),
    _OptionItem('冷门佳片', '冷门佳片'),
  ];

  static const _movieSecondaryOptions = [
    _OptionItem('全部', '全部'),
    _OptionItem('华语', '华语'),
    _OptionItem('欧美', '欧美'),
    _OptionItem('韩国', '韩国'),
    _OptionItem('日本', '日本'),
  ];

  static const _tvPrimaryOptions = [
    _OptionItem('全部', '全部'),
    _OptionItem('最近热门', '最近热门'),
  ];

  static const _tvSecondaryOptions = [
    _OptionItem('全部', 'tv'),
    _OptionItem('国产', 'tv_domestic'),
    _OptionItem('欧美', 'tv_american'),
    _OptionItem('日本', 'tv_japanese'),
    _OptionItem('韩国', 'tv_korean'),
    _OptionItem('动漫', 'tv_animation'),
    _OptionItem('纪录片', 'tv_documentary'),
  ];

  static const _showPrimaryOptions = [
    _OptionItem('全部', '全部'),
    _OptionItem('最近热门', '最近热门'),
  ];

  static const _showSecondaryOptions = [
    _OptionItem('全部', 'show'),
    _OptionItem('国内', 'show_domestic'),
    _OptionItem('国外', 'show_foreign'),
  ];

  static const _animePrimaryOptions = [
    _OptionItem('每日放送', '每日放送'),
    _OptionItem('番剧', '番剧'),
    _OptionItem('剧场版', '剧场版'),
  ];

  static const _categoryConfigs = {
    'movie': _CategoryConfig(
      kind: 'movie',
      primaryOptions: _moviePrimaryOptions,
      secondaryOptions: _movieSecondaryOptions,
      defaultPrimary: '热门',
      defaultSecondary: '全部',
      defaultFormat: 'all',
      defaultSort: 'U',
    ),
    'tv': _CategoryConfig(
      kind: 'tv',
      primaryOptions: _tvPrimaryOptions,
      secondaryOptions: _tvSecondaryOptions,
      defaultPrimary: '最近热门',
      defaultSecondary: 'tv',
      defaultFormat: '电视剧',
      defaultSort: 'U',
    ),
    'show': _CategoryConfig(
      kind: 'tv',
      primaryOptions: _showPrimaryOptions,
      secondaryOptions: _showSecondaryOptions,
      defaultPrimary: '最近热门',
      defaultSecondary: 'show',
      defaultFormat: '综艺',
      defaultSort: 'U',
    ),
    'anime': _CategoryConfig(
      kind: 'tv',
      primaryOptions: _animePrimaryOptions,
      secondaryOptions: [],
      defaultPrimary: '每日放送',
      defaultSecondary: '全部',
      defaultFormat: 'all',
      defaultSort: 'U',
    ),
  };

  // ===================== 筛选维度选项（与 LunaTV MultiLevelSelector 一致） =====================

  static const _typeOptionsMovie = [
    '全部', '喜剧', '爱情', '动作', '科幻', '悬疑', '犯罪', '惊悚', '冒险', '音乐',
    '历史', '奇幻', '恐怖', '战争', '传记', '歌舞', '武侠', '情色', '灾难', '西部',
    '纪录片', '短片',
  ];

  static const _typeOptionsTv = [
    '全部', '喜剧', '爱情', '悬疑', '武侠', '古装', '家庭', '犯罪', '科幻', '恐怖',
    '历史', '战争', '动作', '冒险', '传记', '剧情', '奇幻', '惊悚', '灾难', '歌舞',
    '音乐',
  ];

  static const _typeOptionsShow = [
    '全部', '真人秀', '脱口秀', '音乐', '歌舞',
  ];

  static const _labelOptionsAnimeTv = [
    '全部', '黑色幽默', '历史', '歌舞', '励志', '恶搞', '治愈', '运动', '后宫', '情色',
    '国漫', '人性', '悬疑', '恋爱', '魔幻', '科幻',
  ];

  static const _labelOptionsAnimeMovie = [
    '全部', '定格动画', '传记', '美国动画', '爱情', '黑色幽默', '歌舞', '儿童', '二次元',
    '动物', '青春', '历史', '励志', '恶搞', '治愈', '运动', '后宫', '情色', '人性', '悬疑',
    '恋爱', '魔幻', '科幻',
  ];

  static const _regionOptionsMovie = [
    '全部', '华语', '欧美', '韩国', '日本', '中国大陆', '美国', '中国香港', '中国台湾',
    '英国', '法国', '德国', '意大利', '西班牙', '印度', '泰国', '俄罗斯', '加拿大',
    '澳大利亚', '爱尔兰', '瑞典', '巴西', '丹麦',
  ];

  static const _regionOptionsTvShowAnime = [
    '全部', '华语', '欧美', '国外', '韩国', '日本', '中国大陆', '中国香港', '美国', '英国',
    '泰国', '中国台湾', '意大利', '法国', '德国', '西班牙', '俄罗斯', '瑞典', '巴西', '丹麦',
    '印度', '加拿大', '爱尔兰', '澳大利亚',
  ];

  static const _platformOptions = [
    '全部', '腾讯视频', '爱奇艺', '优酷', '湖南卫视', 'Netflix', 'HBO', 'BBC', 'NHK', 'CBS',
    'NBC', 'tvN',
  ];

  static const _yearOptions = [
    '全部', '2020年代', '2026', '2025', '2024', '2023', '2022', '2021', '2020', '2019',
    '2010年代', '2000年代', '90年代', '80年代', '70年代', '60年代', '更早',
  ];

  static const _sortLabelsMovie = ['近期热度', '首映时间', '高分优先'];
  static const _sortLabelsAnime = ['综合排序', '近期热度', '首播时间', '高分优先'];
  static const _sortValues = {
    '综合排序': 'T',
    '近期热度': 'U',
    '首映时间': 'R',
    '首播时间': 'R',
    '高分优先': 'S',
  };

  _CategoryConfig get _config {
    return _categoryConfigs[widget.kind] ?? _categoryConfigs['movie']!;
  }

  List<_FilterDimension> get _dimensions {
    final isAnime = widget.kind == 'anime';
    final isAnimeMovie = isAnime && _selectedPrimary == '剧场版';
    final isAnimeTv = isAnime && _selectedPrimary == '番剧';

    final base = <_FilterDimension>[];
    if (isAnimeTv || isAnimeMovie) {
      base.add(const _FilterDimension(key: 'label', label: '标签'));
    } else {
      base.add(const _FilterDimension(key: 'type', label: '类型'));
    }
    base.add(const _FilterDimension(key: 'region', label: '地区'));
    base.add(const _FilterDimension(key: 'year', label: '年代'));
    if (!isAnimeMovie) {
      base.add(const _FilterDimension(key: 'platform', label: '平台'));
    }
    base.add(const _FilterDimension(key: 'sort', label: '排序'));
    return base;
  }

  List<String> get _currentSortLabels {
    if (widget.kind == 'movie') {
      return _sortLabelsMovie.toList();
    }
    return _sortLabelsAnime.toList();
  }

  @override
  void initState() {
    super.initState();
    _selectedPrimary = _config.defaultPrimary;
    _selectedSecondary = _config.defaultSecondary;
    _params = DoubanRecommendsParams(
      kind: _config.kind,
      category: 'all',
      format: _config.defaultFormat,
      sort: _config.defaultSort,
      pageLimit: 25,
    );
    _scrollController.addListener(_onScroll);
    _categoryTagFocusNodes.addAll(
      List.generate(_config.primaryOptions.length, (_) => FocusNode()),
    );
    _secondaryTagFocusNodes.addAll(
      List.generate(_config.secondaryOptions.length, (_) => FocusNode()),
    );
    _selectedWeekday = _currentWeekdayEn();
    _weekdayFocusNodes.addAll(List.generate(7, (_) => FocusNode()));
    for (final key in ['type', 'region', 'year', 'platform', 'sort', 'label']) {
      _dimensionButtonFocusNodes[key] = FocusNode();
    }
    BackInterceptor.register(_onBackIntercepted);
  }

  static String _currentWeekdayEn() {
    final weekday = DateTime.now().weekday;
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[weekday - 1];
  }

  void focusFilterButton() {
    if (_categoryTagFocusNodes.isNotEmpty) {
      _categoryTagFocusNodes.first.requestFocus();
    }
  }

  void _focusFirstPoster() {
    if (_posterFocusNodes.isNotEmpty) {
      _posterFocusNodes.first.requestFocus();
    }
  }

  int get _selectedPrimaryIndex {
    final options = _config.primaryOptions;
    for (int i = 0; i < options.length; i++) {
      if (options[i].value == _selectedPrimary) return i;
    }
    return 0;
  }

  void _focusSelectedCategoryTag() {
    final index = _selectedPrimaryIndex;
    if (index >= 0 && index < _categoryTagFocusNodes.length) {
      _categoryTagFocusNodes[index].requestFocus();
    }
  }

  void _focusSecondRowFirst() {
    if (_selectedPrimary == '每日放送') {
      if (_weekdayFocusNodes.isNotEmpty) {
        _weekdayFocusNodes.first.requestFocus();
      }
    } else if (_showSecondaryRow) {
      if (_secondaryTagFocusNodes.isNotEmpty) {
        _secondaryTagFocusNodes.first.requestFocus();
      }
    } else if (_showDimensionButtons) {
      final firstKey = _dimensions.first.key;
      _dimensionButtonFocusNodes[firstKey]?.requestFocus();
    } else {
      _focusFirstPoster();
    }
  }

  bool get _showSecondaryRow {
    if (widget.kind == 'movie') return _selectedPrimary != '全部';
    if (widget.kind == 'tv') return _selectedPrimary == '最近热门';
    if (widget.kind == 'show') return _selectedPrimary == '最近热门';
    return false;
  }

  bool get _showDimensionButtons {
    if (widget.kind == 'anime') {
      return _selectedPrimary == '番剧' || _selectedPrimary == '剧场版';
    }
    return _selectedPrimary == '全部';
  }

  bool _showSecondaryRowForPrimary(String primary) {
    if (widget.kind == 'movie') return primary != '全部';
    if (widget.kind == 'tv') return primary == '最近热门';
    if (widget.kind == 'show') return primary == '最近热门';
    return false;
  }

  bool _showDimensionButtonsForPrimary(String primary) {
    if (widget.kind == 'anime') {
      return primary == '番剧' || primary == '剧场版';
    }
    return primary == '全部';
  }

  List<_FilterDimension> _dimensionsForPrimary(String primary) {
    final isAnime = widget.kind == 'anime';
    final isAnimeMovie = isAnime && primary == '剧场版';
    final isAnimeTv = isAnime && primary == '番剧';

    final base = <_FilterDimension>[];
    if (isAnimeTv || isAnimeMovie) {
      base.add(const _FilterDimension(key: 'label', label: '标签'));
    } else {
      base.add(const _FilterDimension(key: 'type', label: '类型'));
    }
    base.add(const _FilterDimension(key: 'region', label: '地区'));
    base.add(const _FilterDimension(key: 'year', label: '年代'));
    if (!isAnimeMovie) {
      base.add(const _FilterDimension(key: 'platform', label: '平台'));
    }
    base.add(const _FilterDimension(key: 'sort', label: '排序'));
    return base;
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _categoryTagFocusNodes) {
      node.dispose();
    }
    _categoryTagFocusNodes.clear();
    for (final node in _secondaryTagFocusNodes) {
      node.dispose();
    }
    _secondaryTagFocusNodes.clear();
    for (final node in _dimensionButtonFocusNodes.values) {
      node.dispose();
    }
    _dimensionButtonFocusNodes.clear();
    for (final node in _dropdownOptionFocusNodes) {
      node.dispose();
    }
    _dropdownOptionFocusNodes.clear();
    for (final node in _posterFocusNodes) {
      node.dispose();
    }
    _posterFocusNodes.clear();
    for (final node in _weekdayFocusNodes) {
      node.dispose();
    }
    _weekdayFocusNodes.clear();
    BackInterceptor.unregister(_onBackIntercepted);
    super.dispose();
  }

  bool _onBackIntercepted() {
    if (_activeDimension != null) {
      _closeDimensionDropdown();
      return true;
    }
    return false;
  }

  void _focusPosterIndex(int target, int crossAxisCount) {
    if (target < 0 || target >= _posterFocusNodes.length) return;

    final constraints = _gridConstraints;
    if (constraints != null && _scrollController.hasClients) {
      const horizontalPadding = AppSpacing.lg * 2;
      const crossSpacing = AppSpacing.md;
      const mainSpacing = AppSpacing.lg;
      const aspectRatio = 0.55;

      final availableWidth = constraints.maxWidth - horizontalPadding;
      final itemWidth =
          (availableWidth - (crossAxisCount - 1) * crossSpacing) / crossAxisCount;
      final itemHeight = itemWidth / aspectRatio;
      final rowHeight = itemHeight + mainSpacing;

      final targetRow = target ~/ crossAxisCount;
      final targetTop = AppSpacing.lg + targetRow * rowHeight;
      final targetBottom = targetTop + itemHeight;

      final viewportHeight = constraints.maxHeight;
      final currentOffset = _scrollController.offset;
      final viewportBottom = currentOffset + viewportHeight;

      double? targetOffset;
      if (targetTop < currentOffset) {
        targetOffset = targetTop;
      } else if (targetBottom > viewportBottom) {
        targetOffset = targetBottom - viewportHeight;
      }

      if (targetOffset != null) {
        _scrollController.animateTo(
          targetOffset.clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }

    _posterFocusNodes[target].requestFocus();
  }

  KeyEventResult _handlePosterKeyEvent(
    int index,
    int crossAxisCount,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    void focusPreviousRow() {
      _focusSecondRowFirst();
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index % crossAxisCount == 0) {
          if (index == 0) {
            focusPreviousRow();
          } else {
            _focusPosterIndex(index - 1, crossAxisCount);
          }
        } else {
          _focusPosterIndex(index - 1, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (index < _posterFocusNodes.length - 1) {
          _focusPosterIndex(index + 1, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (index < crossAxisCount) {
          focusPreviousRow();
        } else {
          _focusPosterIndex(index - crossAxisCount, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (index + crossAxisCount < _posterFocusNodes.length) {
          _focusPosterIndex(index + crossAxisCount, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
        focusPreviousRow();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _onScroll() {
    if (_loading || _loadingMore || !_hasMore) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (currentScroll >= maxScroll * 0.9) {
      _loadMore();
    }
  }

  Future<ApiResponse<List<DoubanMovie>>> _loadBangumiDailyBroadcast() async {
    if (_bangumiCalendarItems.isEmpty) {
      final res = await BangumiService.getCalendar();
      if (!res.success) return ApiResponse.error(res.message ?? '获取 Bangumi 数据失败');
      _bangumiCalendarItems = res.data ?? [];
    }
    final items = BangumiService.filterByWeekday(_bangumiCalendarItems, _selectedWeekday);
    return ApiResponse.success(items.map(_bangumiToDoubanMovie).toList());
  }

  DoubanMovie _bangumiToDoubanMovie(BangumiCalendarItem item) {
    return DoubanMovie(
      id: 'bgm_${item.id}',
      title: item.title,
      poster: item.poster ?? '',
      year: item.year ?? '',
      rate: item.rate,
    );
  }

  Future<void> _loadData({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final params = refresh ? _params.copyWith(page: 0) : _params;

      debugPrint('CategoryScreen[${widget.kind}] 加载数据: page=${params.page}, primary=$_selectedPrimary, secondary=$_selectedSecondary');

      late ApiResponse<List<DoubanMovie>> response;

      if (widget.kind == 'anime' && _selectedPrimary == '每日放送') {
        response = await _loadBangumiDailyBroadcast();
      } else if (widget.kind == 'anime') {
        response = await DoubanService.fetchRecommends(
          params: params.copyWith(
            kind: _selectedPrimary == '番剧' ? 'tv' : 'movie',
            category: '动画',
            format: _selectedPrimary == '番剧' ? '电视剧' : 'all',
          ),
        );
      } else if (_selectedPrimary == '全部') {
        response = await DoubanService.fetchRecommends(params: params);
      } else if (widget.kind == 'movie') {
        response = await DoubanService.getCategoryData(
          kind: 'movie',
          category: _selectedPrimary,
          type: _selectedSecondary,
          pageLimit: params.pageLimit,
          page: params.page,
        );
      } else if (widget.kind == 'tv' && _selectedPrimary == '最近热门') {
        response = await DoubanService.getCategoryData(
          kind: 'tv',
          category: 'tv',
          type: _selectedSecondary,
          pageLimit: params.pageLimit,
          page: params.page,
        );
      } else if (widget.kind == 'show' && _selectedPrimary == '最近热门') {
        response = await DoubanService.getCategoryData(
          kind: 'tv',
          category: 'show',
          type: _selectedSecondary,
          pageLimit: params.pageLimit,
          page: params.page,
        );
      } else {
        response = await DoubanService.fetchRecommends(params: params);
      }

      debugPrint('CategoryScreen[${widget.kind}] 响应: success=${response.success}, dataCount=${response.data?.length ?? 0}');

      if (mounted) {
        setState(() {
          if (refresh) {
            _movies = response.success ? response.data ?? [] : [];
            _error = response.success ? null : response.message;
            _loading = false;
          } else {
            if (response.success && response.data != null) {
              _movies.addAll(response.data!);
            }
          }
          _hasMore = response.success &&
              response.data != null &&
              response.data!.length >= params.pageLimit;
          if (widget.kind == 'anime' && _selectedPrimary == '每日放送') {
            _hasMore = false;
          }
          _loadingMore = false;

          debugPrint('CategoryScreen[${widget.kind}] 状态更新: movies=${_movies.length}, hasMore=$_hasMore');
        });
      }
    } catch (e, stackTrace) {
      debugPrint('CategoryScreen[${widget.kind}] 加载失败: $e');
      debugPrint('$stackTrace');
      if (mounted) {
        setState(() {
          _loading = false;
          _loadingMore = false;
          _error = '分类加载失败: $e';
        });
      }
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) {
      debugPrint('CategoryScreen[${widget.kind}] 跳过加载: loadingMore=$_loadingMore, hasMore=$_hasMore');
      return;
    }
    setState(() => _loadingMore = true);
    _params = _params.copyWith(page: _params.page + 1);
    debugPrint('CategoryScreen[${widget.kind}] 加载更多: page=${_params.page}');
    await _loadData(refresh: false);
  }

  String _encodeDimensionValue(String value) {
    return value == '全部' ? 'all' : value;
  }

  String _currentValueForDimension(String dimension) {
    switch (dimension) {
      case 'type':
        return _params.category == 'all' ? '全部' : _params.category;
      case 'label':
        return _params.label == 'all' ? '全部' : _params.label;
      case 'region':
        return _params.region == 'all' ? '全部' : _params.region;
      case 'year':
        return _params.year == 'all' ? '全部' : _params.year;
      case 'platform':
        return _params.platform == 'all' ? '全部' : _params.platform;
      case 'sort':
        final value = _params.sort;
        for (final entry in _sortValues.entries) {
          if (entry.value == value) return entry.key;
        }
        return '综合排序';
      default:
        return '全部';
    }
  }

  List<String> _optionsForDimension(String dimension) {
    switch (dimension) {
      case 'type':
        if (widget.kind == 'movie') return _typeOptionsMovie;
        if (widget.kind == 'tv') return _typeOptionsTv;
        if (widget.kind == 'show') return _typeOptionsShow;
        return const ['全部'];
      case 'label':
        if (_selectedPrimary == '番剧') return _labelOptionsAnimeTv;
        if (_selectedPrimary == '剧场版') return _labelOptionsAnimeMovie;
        return const ['全部'];
      case 'region':
        if (widget.kind == 'movie') return _regionOptionsMovie;
        return _regionOptionsTvShowAnime;
      case 'year':
        return _yearOptions;
      case 'platform':
        return _platformOptions;
      case 'sort':
        return _currentSortLabels;
      default:
        return [];
    }
  }

  void _applyDimensionValue(String dimension, String value) {
    _closeDimensionDropdown();
    final encoded = dimension == 'sort'
        ? _sortValues[value]!
        : _encodeDimensionValue(value);
    setState(() {
      _params = _params.copyWith(
        category: dimension == 'type' ? encoded : _params.category,
        label: dimension == 'label' ? encoded : _params.label,
        region: dimension == 'region' ? encoded : _params.region,
        year: dimension == 'year' ? encoded : _params.year,
        platform: dimension == 'platform' ? encoded : _params.platform,
        sort: dimension == 'sort' ? encoded : _params.sort,
        page: 0,
      );
    });
    _loadData(refresh: true);
  }

  void _onPrimaryChanged(String value) {
    if (value == _selectedPrimary) return;
    setState(() {
      _activeDimension = null;
      _selectedPrimary = value;
      _selectedSecondary = _defaultSecondaryForPrimary(value);
      _params = _resetParamsForPrimary(value);
    });
    _loadData(refresh: true);
  }

  String _defaultSecondaryForPrimary(String primary) {
    if (widget.kind == 'movie') return '全部';
    if (widget.kind == 'tv') {
      return primary == '最近热门' ? 'tv' : 'tv';
    }
    if (widget.kind == 'show') {
      return primary == '最近热门' ? 'show' : 'show';
    }
    return '全部';
  }

  DoubanRecommendsParams _resetParamsForPrimary(String primary) {
    const defaultSort = 'U';
    final base = DoubanRecommendsParams(
      kind: _config.kind,
      category: 'all',
      format: _config.defaultFormat,
      sort: defaultSort,
      pageLimit: _params.pageLimit,
      page: 0,
    );

    if (widget.kind == 'anime') {
      if (primary == '番剧') {
        return base.copyWith(kind: 'tv', category: '动画', format: '电视剧');
      }
      if (primary == '剧场版') {
        return base.copyWith(kind: 'movie', category: '动画', format: 'all');
      }
      return base;
    }

    if (primary == '全部') {
      if (widget.kind == 'movie') {
        return base.copyWith(kind: 'movie', format: 'all');
      }
      if (widget.kind == 'tv') {
        return base.copyWith(kind: 'tv', format: '电视剧');
      }
      if (widget.kind == 'show') {
        return base.copyWith(kind: 'tv', format: '综艺');
      }
    }

    return base;
  }

  void _onSecondaryChanged(String value) {
    if (value == _selectedSecondary) return;
    setState(() {
      _activeDimension = null;
      _selectedSecondary = value;
      _params = _params.copyWith(page: 0);
    });
    _loadData(refresh: true);
  }

  void _openDimensionDropdown(String dimension) {
    _disposeDropdownOptionFocusNodes();
    final options = _optionsForDimension(dimension);
    _dropdownOptionFocusNodes.addAll(
      List.generate(options.length, (_) => FocusNode()),
    );
    setState(() => _activeDimension = dimension);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusDropdownOption(0);
    });
  }

  void _closeDimensionDropdown() {
    _disposeDropdownOptionFocusNodes();
    setState(() => _activeDimension = null);
  }

  void _disposeDropdownOptionFocusNodes() {
    for (final node in _dropdownOptionFocusNodes) {
      node.dispose();
    }
    _dropdownOptionFocusNodes.clear();
  }

  void _focusDropdownOption(int index) {
    if (index >= 0 && index < _dropdownOptionFocusNodes.length) {
      _dropdownOptionFocusNodes[index].requestFocus();
    }
  }

  Widget _buildDimensionDropdown() {
    if (_activeDimension == null) return const SizedBox.shrink();
    final dimension = _dimensions.firstWhere((d) => d.key == _activeDimension);
    final options = _optionsForDimension(_activeDimension!);
    final currentValue = _currentValueForDimension(_activeDimension!);

    return Positioned(
      top: 116,
      left: AppSpacing.lg,
      right: AppSpacing.lg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 减去 Container 水平内边距和 FocusableWidget 默认 padding 后计算真实列数
          final width = constraints.maxWidth - 2 * AppSpacing.md;
          const itemWidth = 110.0 + 2 * AppSpacing.xs;
          const spacing = AppSpacing.md;
          _dropdownCrossAxisCount = math.max(
            1,
            ((width + spacing) / (itemWidth + spacing)).floor(),
          );
          return Container(
            padding: const EdgeInsets.all(AppSpacing.md),
            decoration: BoxDecoration(
              color: AppColors.bgSurface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: AppColors.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  dimension.label,
                  style: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Wrap(
                  spacing: AppSpacing.md,
                  runSpacing: AppSpacing.md,
                  children: [
                    for (int i = 0; i < options.length; i++)
                      Builder(
                        builder: (context) {
                          final option = options[i];
                          final selected = currentValue == option;
                          return FocusableWidget(
                            focusNode: _dropdownOptionFocusNodes[i],
                            onTap: () => _applyDimensionValue(_activeDimension!, option),
                            onKeyEvent: (node, event) => _handleDropdownOptionKeyEvent(
                              i,
                              options.length,
                              option,
                              node,
                              event,
                            ),
                            onFocusChange: (focused) {
                              if (focused) {
                                WidgetsBinding.instance.addPostFrameCallback((_) {
                                  if (context.mounted) {
                                    Scrollable.ensureVisible(
                                      context,
                                      duration: const Duration(milliseconds: 200),
                                      curve: Curves.easeOut,
                                      alignment: 0.5,
                                    );
                                  }
                                });
                              }
                            },
                            child: Container(
                              width: 110,
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.md,
                                vertical: AppSpacing.sm,
                              ),
                              decoration: BoxDecoration(
                                color: selected ? AppColors.primary : AppColors.bgElevated,
                                borderRadius: BorderRadius.circular(AppRadius.sm),
                                border: Border.all(
                                  color: selected ? AppColors.primary : AppColors.border,
                                ),
                              ),
                              child: Text(
                                option,
                                textAlign: TextAlign.center,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontFamily: 'NotoSansSC',
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: selected ? Colors.white : AppColors.textPrimary,
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                  ],
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  KeyEventResult _handleDropdownOptionKeyEvent(
    int index,
    int itemCount,
    String option,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    final crossAxisCount = _dropdownCrossAxisCount;
    final row = index ~/ crossAxisCount;
    final col = index % crossAxisCount;
    final rowCount = (itemCount + crossAxisCount - 1) ~/ crossAxisCount;

    int columnsInRow(int r) {
      if (r < rowCount - 1) return crossAxisCount;
      return itemCount - (rowCount - 1) * crossAxisCount;
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (col > 0) {
          _focusDropdownOption(index - 1);
        } else if (row > 0) {
          final prevRowColumns = columnsInRow(row - 1);
          _focusDropdownOption((row - 1) * crossAxisCount + (prevRowColumns - 1));
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        final currentRowColumns = columnsInRow(row);
        if (col < currentRowColumns - 1) {
          _focusDropdownOption(index + 1);
        } else if (row < rowCount - 1) {
          _focusDropdownOption((row + 1) * crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (row > 0) {
          final prevRowColumns = columnsInRow(row - 1);
          final targetCol = col < prevRowColumns ? col : prevRowColumns - 1;
          _focusDropdownOption((row - 1) * crossAxisCount + targetCol);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (row < rowCount - 1) {
          final nextRowColumns = columnsInRow(row + 1);
          final targetCol = col < nextRowColumns ? col : nextRowColumns - 1;
          _focusDropdownOption((row + 1) * crossAxisCount + targetCol);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.select:
        _applyDimensionValue(_activeDimension!, option);
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  KeyEventResult _handleDimensionButtonKeyEvent(
    int index,
    int itemCount,
    String dimensionKey,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index > 0) {
          final prevKey = _dimensions[index - 1].key;
          _dimensionButtonFocusNodes[prevKey]?.requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (index < itemCount - 1) {
          final nextKey = _dimensions[index + 1].key;
          _dimensionButtonFocusNodes[nextKey]?.requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _focusFirstPoster();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.select:
        _openDimensionDropdown(dimensionKey);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _focusSelectedCategoryTag();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Future<void> _openDetail(BuildContext context, DoubanMovie movie) async {
    final id = movie.id;
    final Widget screen;
    if (id.startsWith('bgm_')) {
      final bgmId = int.tryParse(id.substring(4));
      final item = _bangumiCalendarItems.firstWhere(
        (item) => item.id == bgmId,
        orElse: () => BangumiCalendarItem(
          id: bgmId ?? 0,
          title: movie.title,
          poster: movie.poster.isNotEmpty ? movie.poster : null,
          year: movie.year.isNotEmpty ? movie.year : null,
          rate: movie.rate,
        ),
      );
      screen = DetailScreen.fromBangumiCalendarItem(item);
    } else {
      screen = DetailScreen.fromDoubanMovie(movie);
    }
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    if (event.logicalKey == LogicalKeyboardKey.escape && _activeDimension != null) {
      _closeDimensionDropdown();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return VisibilityDetector(
      key: Key('category_${widget.kind}'),
      onVisibilityChanged: _onVisibilityChanged,
      child: Focus(
        skipTraversal: true,
        canRequestFocus: false,
        onKeyEvent: (_, event) => _handleKeyEvent(event),
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildTopFilterBar(),
                Expanded(
                  child: _buildBody(context),
                ),
              ],
            ),
            if (_activeDimension != null) _buildDimensionDropdown(),
          ],
        ),
      ),
    );
  }

  String get _secondRowLabel {
    if (_selectedPrimary == '每日放送') return '星期';
    if (_showSecondaryRow) return '类型';
    if (_showDimensionButtons) return '筛选';
    return '';
  }

  Widget _buildLabeledRow({
    required String label,
    required Widget child,
    required double height,
  }) {
    return SizedBox(
      height: height,
      child: Row(
        children: [
          SizedBox(
            width: 40,
            child: Text(
              label,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textSecondary,
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(child: child),
        ],
      ),
    );
  }

  Widget _buildTopFilterBar() {
    return Container(
      height: 116,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: const BoxDecoration(
        color: AppColors.bgSurface,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildLabeledRow(
            label: '分类',
            height: 56,
            child: _buildCategoryTags(),
          ),
          _buildLabeledRow(
            label: _secondRowLabel,
            height: 52,
            child: _buildSecondRow(),
          ),
        ],
      ),
    );
  }

  KeyEventResult _handleCategoryTagKeyEvent(
    int index,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    debugPrint('[CategoryTag] key=${event.logicalKey} index=$index');
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _categoryTagFocusNodes[index - 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (index < _categoryTagFocusNodes.length - 1) {
        _categoryTagFocusNodes[index + 1].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _onCategoryTagDown(index, node);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _onCategoryTagDown(int index, FocusNode node) {
    final option = _config.primaryOptions[index];
    final primary = option.value;

    if (widget.kind != 'anime') {
      _focusSecondRowFirst();
      return;
    }

    debugPrint('[CategoryTag] down index=$index primary=$primary selected=$_selectedPrimary');
    if (_selectedPrimary != primary) {
      setState(() {
        _activeDimension = null;
        _selectedPrimary = primary;
        _selectedSecondary = _defaultSecondaryForPrimary(primary);
        _params = _resetParamsForPrimary(primary);
      });
      _loadData(refresh: true);
    }

    _focusSecondRowForPrimary(primary);
  }

  void _focusSecondRowForPrimary(String primary) {
    FocusNode? target;
    if (primary == '每日放送') {
      if (_weekdayFocusNodes.isNotEmpty) target = _weekdayFocusNodes.first;
    } else if (_showSecondaryRowForPrimary(primary)) {
      if (_secondaryTagFocusNodes.isNotEmpty) target = _secondaryTagFocusNodes.first;
    } else if (_showDimensionButtonsForPrimary(primary)) {
      final firstKey = _dimensionsForPrimary(primary).first.key;
      debugPrint('[Focus] firstKey=$firstKey availableNodes=${_dimensionButtonFocusNodes.keys}');
      target = _dimensionButtonFocusNodes[firstKey];
    }

    if (target == null) {
      _focusFirstPoster();
      return;
    }

    final effectiveTarget = target;
    debugPrint('[Focus] target=$effectiveTarget hasPrimaryFocus=${effectiveTarget.hasPrimaryFocus} hasFocus=${effectiveTarget.hasFocus} context=${effectiveTarget.context}');
    effectiveTarget.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      debugPrint('[Focus] post-frame target=$effectiveTarget hasPrimaryFocus=${effectiveTarget.hasPrimaryFocus} hasFocus=${effectiveTarget.hasFocus} context=${effectiveTarget.context}');
      effectiveTarget.requestFocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        debugPrint('[Focus] post-frame2 target=$effectiveTarget hasPrimaryFocus=${effectiveTarget.hasPrimaryFocus} hasFocus=${effectiveTarget.hasFocus}');
      });
    });
  }

  Widget _buildCategoryTags() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < _config.primaryOptions.length; index++) ...[
            Builder(
              builder: (context) {
                final option = _config.primaryOptions[index];
                final selected = _selectedPrimary == option.value;
                return Center(
                  child: FocusableWidget(
                    focusNode: _categoryTagFocusNodes[index],
                    onTap: () => _onPrimaryChanged(option.value),
                    onFocusChange: (focused) {
                      if (focused) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (context.mounted) {
                            Scrollable.ensureVisible(
                              context,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                              alignment: 0.5,
                            );
                          }
                        });
                      }
                    },
                    onKeyEvent: (node, event) =>
                        _handleCategoryTagKeyEvent(index, node, event),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primary
                            : AppColors.bgElevated,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                        border: Border.all(
                          color: selected ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Text(
                        option.label,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (index < _config.primaryOptions.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildSecondRow() {
    debugPrint('[SecondRow] selectedPrimary=$_selectedPrimary showSecondary=$_showSecondaryRow showDim=$_showDimensionButtons');
    if (_selectedPrimary == '每日放送') {
      return _buildWeekdayRow();
    }
    if (_showSecondaryRow) {
      return _buildSecondaryTags();
    }
    if (_showDimensionButtons) {
      return _buildDimensionButtons();
    }
    return const SizedBox.shrink();
  }

  Widget _buildSecondaryTags() {
    final options = _config.secondaryOptions;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < options.length; index++) ...[
            Builder(
              builder: (context) {
                final option = options[index];
                final selected = _selectedSecondary == option.value;
                return Center(
                  child: FocusableWidget(
                    focusNode: _secondaryTagFocusNodes[index],
                    onTap: () => _onSecondaryChanged(option.value),
                    onKeyEvent: (node, event) =>
                        _handleSecondaryTagKeyEvent(index, node, event),
                    onFocusChange: (focused) {
                      if (focused) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (context.mounted) {
                            Scrollable.ensureVisible(
                              context,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                              alignment: 0.5,
                            );
                          }
                        });
                      }
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primary
                            : AppColors.bgElevated,
                        borderRadius: BorderRadius.circular(AppRadius.full),
                        border: Border.all(
                          color: selected ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Text(
                        option.label,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? Colors.white
                              : AppColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (index < options.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  KeyEventResult _handleSecondaryTagKeyEvent(
    int index,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index > 0) _secondaryTagFocusNodes[index - 1].requestFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (index < _secondaryTagFocusNodes.length - 1) {
          _secondaryTagFocusNodes[index + 1].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _focusFirstPoster();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (_categoryTagFocusNodes.isNotEmpty) {
          _categoryTagFocusNodes.first.requestFocus();
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildWeekdayRow() {
    return SizedBox(
      height: 52,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (int i = 0; i < BangumiService.weekdays.length; i++) ...[
              Builder(
                builder: (context) {
                  final day = BangumiService.weekdays[i];
                  final selected = _selectedWeekday == day['en'];
                  return FocusableWidget(
                    focusNode: _weekdayFocusNodes[i],
                    onTap: () {
                      setState(() => _selectedWeekday = day['en']!);
                      _loadData(refresh: true);
                    },
                    onFocusChange: (focused) {
                      if (focused) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (context.mounted) {
                            Scrollable.ensureVisible(
                              context,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                              alignment: 0.5,
                            );
                          }
                        });
                      }
                    },
                    onKeyEvent: (node, event) => _handleWeekdayKeyEvent(i, node, event),
                    child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: selected ? AppColors.primary : AppColors.bgElevated,
                      borderRadius: BorderRadius.circular(AppRadius.full),
                      border: Border.all(
                        color: selected ? AppColors.primary : AppColors.border,
                      ),
                    ),
                    child: Text(
                      day['cn']!,
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: selected ? Colors.white : AppColors.textSecondary,
                      ),
                    ),
                  ),
                );
              },
            ),
            if (i < BangumiService.weekdays.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    ),
  );
  }

  KeyEventResult _handleWeekdayKeyEvent(int index, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    debugPrint('[Weekday] key=${event.logicalKey} index=$index node=$node');

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index > 0) _weekdayFocusNodes[index - 1].requestFocus();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (index < BangumiService.weekdays.length - 1) {
          _weekdayFocusNodes[index + 1].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _focusFirstPoster();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _focusSelectedCategoryTag();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildDimensionButtons() {
    return SizedBox(
      height: 52,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (int i = 0; i < _dimensions.length; i++) ...[
              Builder(
                builder: (context) {
                  final dimension = _dimensions[i];
                  final node = _dimensionButtonFocusNodes[dimension.key]!;
                  if (i == 0) {
                    debugPrint('[DimButton] build i=$i key=${dimension.key} node=$node context=${node.context}');
                  }
                  final label = '${dimension.label}：${_currentValueForDimension(dimension.key)}';
                  final active = _activeDimension == dimension.key;
                  return _DimensionButton(
                    focusNode: node,
                    onTap: () => _openDimensionDropdown(dimension.key),
                    onFocusChange: (focused) {
                      if (focused) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (context.mounted) {
                            Scrollable.ensureVisible(
                              context,
                              duration: const Duration(milliseconds: 200),
                              curve: Curves.easeOut,
                              alignment: 0.5,
                            );
                          }
                        });
                      }
                    },
                    onKeyEvent: (n, event) => _handleDimensionButtonKeyEvent(
                      i,
                      _dimensions.length,
                      dimension.key,
                      n,
                      event,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: active ? AppColors.primary : AppColors.bgElevated,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                        border: Border.all(
                          color: active ? AppColors.primary : AppColors.border,
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: active ? Colors.white : AppColors.textPrimary,
                        ),
                      ),
                    ),
                  );
              },
            ),
            if (i < _dimensions.length - 1) const SizedBox(width: AppSpacing.md),
          ],
        ],
      ),
    ),
  );
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (info.visibleFraction > 0.5) {
      if (!_hasEverBeenVisible || (_movies.isEmpty && !_loading && _error == null)) {
        _hasEverBeenVisible = true;
        _loadData(refresh: true);
      }
    }
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    if (_movies.isEmpty) {
      return const Center(
        child: Text(
          '暂无数据',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final items = _movies.map((movie) {
      return PosterItem(
        id: movie.id,
        title: movie.title,
        posterUrl: movie.poster,
        year: movie.year,
        rating: movie.rate,
        onTap: () => _openDetail(context, movie),
      );
    }).toList();

    while (_posterFocusNodes.length < items.length) {
      _posterFocusNodes.add(FocusNode());
    }
    while (_posterFocusNodes.length > items.length) {
      _posterFocusNodes.removeLast().dispose();
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _gridConstraints = constraints;
        return Column(
          children: [
            Expanded(
              child: TvPosterGrid(
                controller: _scrollController,
                items: items,
                itemFocusNodes: _posterFocusNodes,
                autofocusFirstItem: false,
                onItemKeyEvent: (index, crossAxisCount, node, event) =>
                    _handlePosterKeyEvent(index, crossAxisCount, node, event),
              ),
            ),
            if (_loadingMore)
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: const Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
