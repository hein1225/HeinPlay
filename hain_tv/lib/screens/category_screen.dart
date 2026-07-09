import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../focus/focusable.dart';
import '../models/douban_movie.dart';
import '../models/douban_recommends_params.dart';
import '../services/douban_service.dart';
import '../models/api_response.dart';
import '../theme.dart';
import '../utils/back_interceptor.dart';
import '../widgets/tv_grid.dart';
import 'detail_screen.dart';

class _FilterDimension {
  final String key;
  final String label;

  const _FilterDimension({required this.key, required this.label});
}

class _FilterConfig {
  final String kind;
  final String defaultCategory;
  final String defaultFormat;
  final String defaultSort = 'R';
  final List<String> categories;
  final List<String> regions;
  final List<String> years;
  final List<String> sorts;
  final List<String> labels;

  const _FilterConfig({
    required this.kind,
    required this.defaultCategory,
    required this.defaultFormat,
    required this.categories,
    required this.regions,
    required this.years,
    required this.sorts,
    required this.labels,
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
  bool _filterPanelOpen = false;
  bool _hasEverBeenVisible = false;

  late DoubanRecommendsParams _params;
  String _selectedDimension = 'category';
  final ScrollController _scrollController = ScrollController();
  final List<FocusNode> _categoryTagFocusNodes = [];
  final FocusScopeNode _filterPanelFocusNode = FocusScopeNode();
  final FocusNode _filterButtonFocusNode = FocusNode();
  final Map<String, FocusNode> _dimensionFocusNodes = {};
  final Map<String, FocusNode> _optionFocusNodes = {};
  final List<FocusNode> _posterFocusNodes = [];
  BoxConstraints? _gridConstraints;

  List<_FilterDimension> get _dimensions {
    final base = [
      _FilterDimension(key: 'category', label: '类型'),
      _FilterDimension(key: 'region', label: '地区'),
      _FilterDimension(key: 'year', label: '年份'),
      _FilterDimension(key: 'label', label: '特色'),
    ];
    // 近期热门模式下排序无效，不显示排序维度
    if (_params.category != 'recent_hot') {
      base.add(_FilterDimension(key: 'sort', label: '排序'));
    }
    return base;
  }

  static const _sortValues = {
    '近期热度': 'U',
    '首映时间': 'R',
    '高分优先': 'S',
  };

  static List<String> _buildYearOptions({int earliestSingleYear = 2020}) {
    final currentYear = DateTime.now().year;
    final years = <String>['全部'];
    for (var year = currentYear; year >= earliestSingleYear; year--) {
      years.add(year.toString());
    }
    return years;
  }

  // 豆瓣API支持的标签映射（UI显示 -> API标签）
  static final _doubanTagMapping = {
    // 电影分类标签
    '剧情': '剧情',
    '喜剧': '喜剧',
    '动作': '动作',
    '爱情': '爱情',
    '科幻': '科幻',
    '动画': '动画',
    '悬疑': '悬疑',
    '惊悚': '惊悚',
    '恐怖': '恐怖',
    '纪录片': '纪录片',
    '短片': '短片',
    '家庭': '家庭',
    '古装': '古装',
    '武侠': '武侠',
    '历史': '历史',
    '战争': '战争',
    '犯罪': '犯罪',
    '西部': '西部',
    '奇幻': '奇幻',
    '冒险': '冒险',
    '音乐': '音乐',
    '歌舞': '歌舞',
    '传记': '传记',
    // 电视剧分类标签
    '真人秀': '真人秀',
    '脱口秀': '脱口秀',
    // 动漫分类特殊处理（使用地区作为筛选）
    '日本动画': '日本',
    '国产动画': '中国大陆',
    '欧美动画': '美国',
    '韩国动画': '韩国',
  };

  static final _filterConfigs = {
    'movie': _FilterConfig(
      kind: 'movie',
      defaultCategory: '全部',
      defaultFormat: '电影',
      categories: const [
        '全部', '近期热门', '剧情', '喜剧', '动作', '爱情', '科幻', '动画', '悬疑', '惊悚', '恐怖', '纪录片', '短片', '家庭', '古装', '武侠', '历史', '战争', '犯罪', '西部', '奇幻', '冒险', '音乐', '歌舞', '传记',
      ],
      regions: const [
        '全部', '中国大陆', '美国', '中国香港', '中国台湾', '日本', '韩国',
        '英国', '法国', '德国', '泰国', '印度', '意大利', '西班牙', '加拿大',
        '澳大利亚', '俄罗斯', '其他',
      ],
      years: _buildYearOptions()
        ..addAll(const ['2010-2019', '2000-2009', '1990-1999', '1980-1989', '更早']),
      sorts: const ['近期热度', '首映时间', '高分优先'],
      labels: const [
        '全部', '经典', '冷门佳片', '豆瓣高分', '院线', 'Netflix', 'Disney+',
        '华语', '欧美', '韩国', '日本',
      ],
    ),
    'tv': _FilterConfig(
      kind: 'tv',
      defaultCategory: '全部',
      defaultFormat: '电视剧',
      categories: const [
        '全部', '近期热门', '剧情', '喜剧', '爱情', '科幻', '动画', '悬疑', '惊悚',
        '恐怖', '纪录片', '家庭', '古装', '武侠', '历史', '战争', '犯罪',
        '真人秀', '脱口秀', '音乐', '歌舞',
      ],
      regions: const [
        '全部', '中国大陆', '美国', '中国香港', '中国台湾', '日本', '韩国',
        '英国', '法国', '德国', '泰国', '印度', '加拿大', '澳大利亚', '其他',
      ],
      years: _buildYearOptions()
        ..addAll(const ['2010-2019', '2000-2009', '1990-1999', '更早']),
      sorts: const ['近期热度', '首映时间', '高分优先'],
      labels: const [
        '全部', '经典', '冷门佳片', '豆瓣高分', 'Netflix', 'Disney+',
        '华语', '欧美', '韩国', '日本',
      ],
    ),
    'show': _FilterConfig(
      kind: 'tv',
      defaultCategory: '全部',
      defaultFormat: '综艺',
      categories: const [
        '全部', '近期热门', '真人秀', '脱口秀', '音乐', '歌舞', '访谈', '选秀',
        '剧情', '喜剧', '纪录片',
      ],
      regions: const [
        '全部', '中国大陆', '美国', '中国香港', '中国台湾', '日本', '韩国',
        '英国', '法国', '其他',
      ],
      years: _buildYearOptions()
        ..addAll(const ['2010-2019', '更早']),
      sorts: const ['近期热度', '首映时间', '高分优先'],
      labels: const [
        '全部', '经典', '冷门佳片', '豆瓣高分', '华语', '韩国', '日本',
      ],
    ),
    'anime': _FilterConfig(
      kind: 'tv',
      defaultCategory: '全部',
      defaultFormat: '动画',
      categories: const [
        '全部', '近期热门', '日本动画', '国产动画', '欧美动画', '韩国动画',
      ],
      regions: const [
        '全部', '日本', '中国大陆', '美国', '中国台湾', '韩国', '其他',
      ],
      years: _buildYearOptions()
        ..addAll(const ['2010-2019', '更早']),
      sorts: const ['近期热度', '首映时间', '高分优先'],
      labels: const [
        '全部', '经典', '冷门佳片', '豆瓣高分', 'Netflix', 'Disney+',
        '华语', '日本', '欧美',
      ],
    ),
  };

  _FilterConfig get _config {
    return _filterConfigs[widget.kind] ?? _filterConfigs['movie']!;
  }

  @override
  void initState() {
    super.initState();
    _params = DoubanRecommendsParams(
      kind: _config.kind,
      category: _encodeValue(_config.defaultCategory),
      format: _encodeValue(_config.defaultFormat),
      sort: _config.defaultSort,
      pageLimit: 50,
    );
    _scrollController.addListener(_onScroll);
    _categoryTagFocusNodes.addAll(
      List.generate(_config.categories.length, (_) => FocusNode()),
    );
    _createFilterFocusNodes();
    FocusManager.instance.addListener(_ensureFilterPanelFocus);
    BackInterceptor.register(_onBackIntercepted);
    // 延迟加载数据，等待页面可见
  }

  void focusFilterButton() {
    _filterButtonFocusNode.requestFocus();
  }

  void _focusFirstPoster() {
    if (_posterFocusNodes.isNotEmpty) {
      _posterFocusNodes.first.requestFocus();
    }
  }

  void _createFilterFocusNodes() {
    for (final dimension in _dimensions) {
      _dimensionFocusNodes.putIfAbsent(dimension.key, () => FocusNode());
      for (final option in _optionsForDimension(dimension.key)) {
        _optionFocusNodes.putIfAbsent(
          '${dimension.key}:$option',
          () => FocusNode(),
        );
      }
    }
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (info.visibleFraction > 0.5) {
      // 首次可见或数据为空时加载
      if (!_hasEverBeenVisible || (_movies.isEmpty && !_loading && _error == null)) {
        _hasEverBeenVisible = true;
        _loadData(refresh: true);
      }
    }
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_ensureFilterPanelFocus);
    _scrollController.dispose();
    for (final node in _categoryTagFocusNodes) {
      node.dispose();
    }
    _categoryTagFocusNodes.clear();
    _filterPanelFocusNode.dispose();
    _filterButtonFocusNode.dispose();
    for (final node in _dimensionFocusNodes.values) {
      node.dispose();
    }
    _dimensionFocusNodes.clear();
    for (final node in _optionFocusNodes.values) {
      node.dispose();
    }
    _optionFocusNodes.clear();
    for (final node in _posterFocusNodes) {
      node.dispose();
    }
    _posterFocusNodes.clear();
    BackInterceptor.unregister(_onBackIntercepted);
    super.dispose();
  }

  bool _onBackIntercepted() {
    if (_filterPanelOpen) {
      _closeFilterPanel();
      return true;
    }
    return false;
  }

  void _ensureFilterPanelFocus() {
    if (!_filterPanelOpen) return;
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return;
    final inPanel = _filterPanelFocusNode.traversalDescendants.contains(primary) ||
        primary == _filterPanelFocusNode;
    if (!inPanel) {
      _filterPanelFocusNode.requestFocus();
    }
  }

  KeyEventResult _handleDimensionKeyEvent(
    String dimensionKey,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final dimensions = _dimensions;
    final index = dimensions.indexWhere((d) => d.key == dimensionKey);
    if (index == -1) return KeyEventResult.ignored;

    // 手动处理上下键焦点移动，避免 ListView 默认遍历在 TV 遥控器短按上键时失效
    if (event.logicalKey == LogicalKeyboardKey.arrowUp && index > 0) {
      final prevKey = dimensions[index - 1].key;
      _dimensionFocusNodes[prevKey]?.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown &&
        index < dimensions.length - 1) {
      final nextKey = dimensions[index + 1].key;
      _dimensionFocusNodes[nextKey]?.requestFocus();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      // 先切换右侧为当前维度对应的选项，确保选项 Widget 已加入树后再请求焦点
      setState(() => _selectedDimension = dimensionKey);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focusOptionForDimension(dimensionKey);
      });
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleOptionKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _dimensionFocusNodes[_selectedDimension]?.requestFocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _focusPosterIndex(int target, int crossAxisCount) {
    if (target < 0 || target >= _posterFocusNodes.length) return;

    // 先滚动到目标行，再请求焦点，确保焦点能移动到不在当前视口的海报
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

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index % crossAxisCount == 0) {
          if (index == 0) {
            // 海报墙第一个海报按左键返回到顶部筛选按钮
            _filterButtonFocusNode.requestFocus();
          } else {
            // 其他行第一列按左键跳到上一行最后一列
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
        // 在最后一个海报消费右键，防止默认遍历跳到海报墙外部
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        // 第一行按上键返回到顶部筛选按钮
        if (index < crossAxisCount) {
          _filterButtonFocusNode.requestFocus();
        } else {
          _focusPosterIndex(index - crossAxisCount, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (index + crossAxisCount < _posterFocusNodes.length) {
          _focusPosterIndex(index + crossAxisCount, crossAxisCount);
        }
        // 在最后一行消费下键，防止默认遍历跳到海报墙外部
        return KeyEventResult.handled;
      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
        // 返回键从海报墙返回到顶部筛选按钮
        _filterButtonFocusNode.requestFocus();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _focusOptionForDimension(String dimensionKey) {
    final currentValue = _currentValueForDimension(dimensionKey);
    final options = _optionsForDimension(dimensionKey);
    final target = options.contains(currentValue) ? currentValue : (options.isNotEmpty ? options.first : null);
    if (target == null) return;
    final node = _optionFocusNodes['$dimensionKey:$target'];
    node?.requestFocus();
  }

  void _onScroll() {
    if (_loading || _loadingMore || !_hasMore) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final currentScroll = _scrollController.position.pixels;
    if (currentScroll >= maxScroll * 0.9) {
      _loadMore();
    }
  }

  Future<void> _loadData({bool refresh = false}) async {
    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final params = refresh
          ? _params.copyWith(page: 0)
          : _params;
      
      debugPrint('CategoryScreen[${widget.kind}] 加载数据: page=${params.page}, category=${params.category}');
      
      late ApiResponse<List<DoubanMovie>> response;
      
      if (params.category == 'recent_hot') {
        // 近期热门改为走 LunaTV 后端 /api/douban 代理，数据与豆瓣网站“热门”标签一致
        final (:type, :tag) = _recentHotTypeTag();
        response = await DoubanService.getHotDataFromServer(
          type: type,
          tag: tag,
          pageSize: params.pageLimit,
          pageStart: params.page * params.pageLimit,
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

  String _encodeValue(String value) {
    if (value == '全部') return 'all';
    if (value == '近期热门') return 'recent_hot';
    // 使用豆瓣标签映射，如果没有映射则使用原值
    return _doubanTagMapping[value] ?? value;
  }

  String _decodeValue(String value) {
    if (value == 'all') return '全部';
    if (value == 'recent_hot') return '近期热门';
    return value;
  }

  /// 近期热门对应 LunaTV /api/douban 的 type/tag 参数
  ({String type, String tag}) _recentHotTypeTag() {
    switch (widget.kind) {
      case 'movie':
        return (type: 'movie', tag: '热门');
      case 'show':
        return (type: 'tv', tag: '综艺');
      case 'anime':
        return (type: 'tv', tag: '日本动画');
      case 'tv':
      default:
        return (type: 'tv', tag: '热门');
    }
  }

  String _currentValueForDimension(String dimension) {
    switch (dimension) {
      case 'category':
        return _decodeValue(_params.category);
      case 'region':
        return _decodeValue(_params.region);
      case 'year':
        return _decodeValue(_params.year);
      case 'sort':
        for (final entry in _sortValues.entries) {
          if (entry.value == _params.sort) return entry.key;
        }
        return '近期热度';
      case 'label':
        return _decodeValue(_params.label);
      default:
        return '全部';
    }
  }

  List<String> _optionsForDimension(String dimension) {
    switch (dimension) {
      case 'category':
        return _config.categories;
      case 'region':
        return _config.regions;
      case 'year':
        return _config.years;
      case 'sort':
        return _config.sorts;
      case 'label':
        return _config.labels;
      default:
        return [];
    }
  }

  void _applyDimensionValue(String dimension, String value) {
    final encoded = dimension == 'sort' ? _sortValues[value]! : _encodeValue(value);
    setState(() {
      var newSort = dimension == 'sort' ? encoded : _params.sort;
      // 切换小分类时，非近期热门默认使用首映时间排序
      if (dimension == 'category' && encoded != 'recent_hot') {
        newSort = _config.defaultSort;
      }
      _params = _params.copyWith(
        category: dimension == 'category' ? encoded : _params.category,
        region: dimension == 'region' ? encoded : _params.region,
        year: dimension == 'year' ? encoded : _params.year,
        sort: newSort,
        label: dimension == 'label' ? encoded : _params.label,
        page: 0,
      );
      // 切换到近期热门时排序维度会被隐藏，避免停留在已消失的排序项
      if (dimension == 'category' && encoded == 'recent_hot' && _selectedDimension == 'sort') {
        _selectedDimension = 'category';
      }
    });
  }

  void _resetFilters() {
    setState(() {
      _params = DoubanRecommendsParams(
        kind: _config.kind,
        category: _encodeValue(_config.defaultCategory),
        format: _encodeValue(_config.defaultFormat),
        sort: _config.defaultSort,
      );
      _selectedDimension = 'category';
    });
  }

  void _openFilterPanel() {
    setState(() {
      _filterPanelOpen = true;
      _selectedDimension = 'category';
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _filterPanelFocusNode.requestFocus();
    });
  }

  void _closeFilterPanel() {
    setState(() => _filterPanelOpen = false);
  }

  Future<void> _confirmFilters() async {
    _closeFilterPanel();
    await _loadData(refresh: true);
  }

  Future<void> _openDetail(BuildContext context, DoubanMovie movie) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen.fromDoubanMovie(movie),
      ),
    );
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;

    // TV 遥控器返回键统一交给 PopScope/BackInterceptor 处理，
    // 这里仅保留键盘 Escape 的兜底关闭，避免与系统返回事件重复响应。
    if (event.logicalKey == LogicalKeyboardKey.escape && _filterPanelOpen) {
      _closeFilterPanel();
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
          if (_filterPanelOpen) _buildFilterPanelOverlay(),
        ],
      ),
    ),
  );
}

KeyEventResult _handleFilterButtonKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (_categoryTagFocusNodes.isNotEmpty) {
        _categoryTagFocusNodes.first.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusFirstPoster();
      return KeyEventResult.handled;
    }
    // 左键在筛选按钮上无内部移动，消费掉避免默认遍历跳到其他区域；
    // 上键继续冒泡，由 TvShell 回到顶部导航栏。
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildTopFilterBar() {
    return Container(
      height: 64,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      decoration: const BoxDecoration(
        color: AppColors.bgSurface,
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        children: [
          FocusableWidget(
            autofocus: true,
            focusNode: _filterButtonFocusNode,
            onTap: _openFilterPanel,
            onKeyEvent: _handleFilterButtonKeyEvent,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.bgElevated,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.border),
              ),
              child: const Row(
                children: [
                  Icon(Icons.filter_list, color: AppColors.textSecondary, size: 18),
                  SizedBox(width: AppSpacing.xs),
                  Text(
                    '筛选与排序',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: _buildCategoryTags(),
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
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _categoryTagFocusNodes[index - 1].requestFocus();
      } else {
        _filterButtonFocusNode.requestFocus();
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
      _focusFirstPoster();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildCategoryTags() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < _config.categories.length; index++) ...[
            Builder(
              builder: (context) {
                final category = _config.categories[index];
                final selected =
                    _currentValueForDimension('category') == category;
                return Center(
                  child: FocusableWidget(
                    focusNode: _categoryTagFocusNodes[index],
                    onTap: () {
                      _applyDimensionValue('category', category);
                      _loadData(refresh: true);
                    },
                    onKeyEvent: (node, event) =>
                        _handleCategoryTagKeyEvent(index, node, event),
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
                        category,
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
            if (index < _config.categories.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
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

    // 同步海报焦点节点，确保每个海报都有稳定的 FocusNode 用于自定义导航
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

  KeyEventResult _handleFilterPanelKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    // TV 遥控器返回键统一交给 TvShell 的 PopScope + BackInterceptor 处理，
    // 防止 Focus 先关闭面板后 PopScope 再次触发，导致 BackInterceptor 看到 _filterPanelOpen=false 而弹出退出框。
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      _closeFilterPanel();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Widget _buildFilterPanelOverlay() {
    return FocusScope(
      node: _filterPanelFocusNode,
      onKeyEvent: _handleFilterPanelKeyEvent,
      child: Container(
        color: AppColors.bgOverlay,
        child: Center(
        child: Container(
          width: 640,
          height: 480,
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
            children: [
              _buildFilterPanelHeader(),
              Expanded(
                child: Row(
                  children: [
                    _buildFilterPanelDimensions(),
                    Expanded(child: _buildFilterPanelOptions()),
                  ],
                ),
              ),
              _buildFilterPanelFooter(),
            ],
          ),
        ),
      ),
    ),
  );
  }

  Widget _buildFilterPanelHeader() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.border),
        ),
      ),
      child: const Row(
        children: [
          Text(
            '筛选',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterPanelDimensions() {
    return Container(
      width: 160,
      decoration: const BoxDecoration(
        border: Border(
          right: BorderSide(color: AppColors.border),
        ),
      ),
      child: ListView.builder(
        itemCount: _dimensions.length,
        itemBuilder: (context, index) {
          final dimension = _dimensions[index];
          final selected = _selectedDimension == dimension.key;
          return FocusableWidget(
            autofocus: index == 0,
            focusNode: _dimensionFocusNodes[dimension.key],
            onTap: () => setState(() => _selectedDimension = dimension.key),
            onKeyEvent: (node, event) => _handleDimensionKeyEvent(dimension.key, event),
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
                vertical: AppSpacing.md,
              ),
              decoration: BoxDecoration(
                color: selected ? AppColors.primaryTint : Colors.transparent,
                border: Border(
                  left: BorderSide(
                    color: selected ? AppColors.primary : Colors.transparent,
                    width: 3,
                  ),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    dimension.label,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected ? AppColors.primary : AppColors.textPrimary,
                    ),
                  ),
                  Text(
                    _currentValueForDimension(dimension.key),
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildFilterPanelOptions() {
    final options = _optionsForDimension(_selectedDimension);
    final currentValue = _currentValueForDimension(_selectedDimension);
    final targetValue =
        options.contains(currentValue) ? currentValue : (options.isNotEmpty ? options.first : null);

    return Container(
      key: ValueKey('filter_options_$_selectedDimension'),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: SingleChildScrollView(
        child: Wrap(
          spacing: AppSpacing.md,
          runSpacing: AppSpacing.md,
          children: options.map((option) {
            final selected = currentValue == option;
            return FocusableWidget(
              autofocus: option == targetValue,
              focusNode: _optionFocusNodes['${_selectedDimension}:$option'],
              onTap: () => _applyDimensionValue(_selectedDimension, option),
              onKeyEvent: _handleOptionKeyEvent,
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
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? Colors.white : AppColors.textPrimary,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ),
    );
  }

  Widget _buildFilterPanelFooter() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: const BoxDecoration(
        border: Border(
          top: BorderSide(color: AppColors.border),
        ),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FocusableWidget(
            onTap: _resetFilters,
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
                '清除',
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
            onTap: _confirmFilters,
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
                '完成',
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
      ),
    );
  }
}
