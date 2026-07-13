import 'package:flutter/material.dart';
import 'package:hain_tv/models/api_response.dart';
import 'package:hain_tv/models/bangumi_calendar_item.dart';
import 'package:hain_tv/models/douban_movie.dart';
import 'package:hain_tv/models/douban_recommends_params.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/douban_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_poster_grid.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

class _OptionItem {
  final String label;
  final String value;

  const _OptionItem(this.label, this.value);
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

class MobileCategoryScreen extends StatefulWidget {
  final String? kind;
  final String? title;

  const MobileCategoryScreen({
    super.key,
    this.kind,
    this.title,
  });

  @override
  State<MobileCategoryScreen> createState() => _MobileCategoryScreenState();
}

class _MobileCategoryScreenState extends State<MobileCategoryScreen> {
  bool _loading = true;
  bool _loadingMore = false;
  String? _error;
  List<DoubanMovie> _movies = [];
  bool _hasMore = true;

  late DoubanRecommendsParams _params;
  late String _selectedPrimary;
  late String _selectedSecondary;

  final ScrollController _scrollController = ScrollController();

  List<BangumiCalendarItem> _bangumiCalendarItems = [];
  late String _selectedWeekday;

  int _loadToken = 0;

  late String _currentKind;

  static const _kindOptions = [
    _OptionItem('电影', 'movie'),
    _OptionItem('电视剧', 'tv'),
    _OptionItem('综艺', 'show'),
    _OptionItem('动漫', 'anime'),
  ];

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
      defaultPrimary: '番剧',
      defaultSecondary: '全部',
      defaultFormat: 'all',
      defaultSort: 'U',
    ),
  };

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
    return _categoryConfigs[_currentKind] ?? _categoryConfigs['movie']!;
  }

  List<_FilterDimension> get _dimensions {
    final isAnime = _currentKind == 'anime';
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
    if (_currentKind == 'movie') {
      return _sortLabelsMovie.toList();
    }
    return _sortLabelsAnime.toList();
  }

  @override
  void initState() {
    super.initState();
    _currentKind = widget.kind ?? 'movie';
    _resetToKind(_currentKind);
    _selectedWeekday = _currentWeekdayEn();
    _scrollController.addListener(_onScroll);
    _loadData(refresh: true);
  }

  void _resetToKind(String kind) {
    final config = _categoryConfigs[kind] ?? _categoryConfigs['movie']!;
    _selectedPrimary = config.defaultPrimary;
    _selectedSecondary = config.defaultSecondary;
    _params = DoubanRecommendsParams(
      kind: config.kind,
      category: 'all',
      format: config.defaultFormat,
      sort: config.defaultSort,
      pageLimit: 30,
    );
  }

  static String _currentWeekdayEn() {
    final weekday = DateTime.now().weekday;
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return names[weekday - 1];
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
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
    final token = ++_loadToken;

    if (refresh) {
      setState(() {
        _loading = true;
        _error = null;
      });
    }

    try {
      final params = refresh ? _params.copyWith(page: 0) : _params;

      late ApiResponse<List<DoubanMovie>> response;

      if (_currentKind == 'anime' && _selectedPrimary == '每日放送') {
        response = await _loadBangumiDailyBroadcast();
      } else if (_currentKind == 'anime') {
        response = await DoubanService.fetchRecommends(
          params: params.copyWith(
            kind: _selectedPrimary == '番剧' ? 'tv' : 'movie',
            category: '动画',
            format: _selectedPrimary == '番剧' ? '电视剧' : 'all',
          ),
        );
      } else if (_selectedPrimary == '全部') {
        response = await DoubanService.fetchRecommends(params: params);
      } else if (_currentKind == 'movie') {
        response = await DoubanService.getCategoryData(
          kind: 'movie',
          category: _selectedPrimary,
          type: _selectedSecondary,
          pageLimit: params.pageLimit,
          page: params.page,
        );
      } else if (_currentKind == 'tv' && _selectedPrimary == '最近热门') {
        response = await DoubanService.getCategoryData(
          kind: 'tv',
          category: 'tv',
          type: _selectedSecondary,
          pageLimit: params.pageLimit,
          page: params.page,
        );
      } else if (_currentKind == 'show' && _selectedPrimary == '最近热门') {
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

      if (token != _loadToken || !mounted) return;

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
          if (_currentKind == 'anime' && _selectedPrimary == '每日放送') {
            _hasMore = false;
          }
          _loadingMore = false;
        });

        if (refresh) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _scrollController.hasClients) {
              _scrollController.jumpTo(_scrollController.position.minScrollExtent);
            }
          });
        }
      }
    } catch (e, stackTrace) {
      debugPrint('MobileCategoryScreen[${_currentKind}] 加载失败: $e');
      debugPrint('$stackTrace');
      if (token != _loadToken || !mounted) return;
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
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    _params = _params.copyWith(page: _params.page + 1);
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
        if (_currentKind == 'movie') return _typeOptionsMovie;
        if (_currentKind == 'tv') return _typeOptionsTv;
        if (_currentKind == 'show') return _typeOptionsShow;
        return const ['全部'];
      case 'label':
        if (_selectedPrimary == '番剧') return _labelOptionsAnimeTv;
        if (_selectedPrimary == '剧场版') return _labelOptionsAnimeMovie;
        return const ['全部'];
      case 'region':
        if (_currentKind == 'movie') return _regionOptionsMovie;
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

  void _onKindChanged(String kind) {
    if (kind == _currentKind) return;
    _loadToken++;
    setState(() {
      _currentKind = kind;
      _resetToKind(kind);
    });
    _loadData(refresh: true);
  }

  void _onPrimaryChanged(String value) {
    if (value == _selectedPrimary) return;
    _loadToken++;
    setState(() {
      _selectedPrimary = value;
      _selectedSecondary = _defaultSecondaryForPrimary(value);
      _params = _resetParamsForPrimary(value);
    });
    _loadData(refresh: true);
  }

  String _defaultSecondaryForPrimary(String primary) {
    if (_currentKind == 'movie') return '全部';
    if (_currentKind == 'tv') {
      return primary == '最近热门' ? 'tv' : 'tv';
    }
    if (_currentKind == 'show') {
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

    if (_currentKind == 'anime') {
      if (primary == '番剧') {
        return base.copyWith(kind: 'tv', category: '动画', format: '电视剧');
      }
      if (primary == '剧场版') {
        return base.copyWith(kind: 'movie', category: '动画', format: 'all');
      }
      return base;
    }

    if (primary == '全部') {
      if (_currentKind == 'movie') {
        return base.copyWith(kind: 'movie', format: 'all');
      }
      if (_currentKind == 'tv') {
        return base.copyWith(kind: 'tv', format: '电视剧');
      }
      if (_currentKind == 'show') {
        return base.copyWith(kind: 'tv', format: '综艺');
      }
    }

    return base;
  }

  void _onSecondaryChanged(String value) {
    if (value == _selectedSecondary) return;
    setState(() {
      _selectedSecondary = value;
      _params = _params.copyWith(page: 0);
    });
    _loadData(refresh: true);
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
      screen = MobileDetailScreen.fromBangumiCalendarItem(item);
    } else {
      screen = MobileDetailScreen.fromDoubanMovie(movie);
    }
    await Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));
  }

  bool get _showSecondaryRow {
    if (_currentKind == 'movie') return _selectedPrimary != '全部';
    if (_currentKind == 'tv') return _selectedPrimary == '最近热门';
    if (_currentKind == 'show') return _selectedPrimary == '最近热门';
    return false;
  }

  bool get _showDimensionButtons {
    if (_currentKind == 'anime') {
      return _selectedPrimary == '番剧' || _selectedPrimary == '剧场版';
    }
    return _selectedPrimary == '全部';
  }

  String get _secondRowLabel {
    if (_selectedPrimary == '每日放送') return '星期';
    if (_showSecondaryRow) return '类型';
    if (_showDimensionButtons) return '筛选';
    return '';
  }

  Widget _buildTag({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
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
          label,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.white : AppColors.textSecondary,
          ),
        ),
      ),
    );
  }

  Widget _buildKindTags() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < _kindOptions.length; index++) ...[
            _buildTag(
              label: _kindOptions[index].label,
              selected: _currentKind == _kindOptions[index].value,
              onTap: () => _onKindChanged(_kindOptions[index].value),
            ),
            if (index < _kindOptions.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildCategoryTags() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < _config.primaryOptions.length; index++) ...[
            _buildTag(
              label: _config.primaryOptions[index].label,
              selected: _selectedPrimary == _config.primaryOptions[index].value,
              onTap: () => _onPrimaryChanged(_config.primaryOptions[index].value),
            ),
            if (index < _config.primaryOptions.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildSecondaryTags() {
    final options = _config.secondaryOptions;
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int index = 0; index < options.length; index++) ...[
            _buildTag(
              label: options[index].label,
              selected: _selectedSecondary == options[index].value,
              onTap: () => _onSecondaryChanged(options[index].value),
            ),
            if (index < options.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildWeekdayRow() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < BangumiService.weekdays.length; i++) ...[
            _buildTag(
              label: BangumiService.weekdays[i]['cn']!,
              selected: _selectedWeekday == BangumiService.weekdays[i]['en']!,
              onTap: () {
                setState(() => _selectedWeekday = BangumiService.weekdays[i]['en']!);
                _loadData(refresh: true);
              },
            ),
            if (i < BangumiService.weekdays.length - 1)
              const SizedBox(width: AppSpacing.sm),
          ],
        ],
      ),
    );
  }

  Widget _buildDimensionButtons() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (int i = 0; i < _dimensions.length; i++) ...[
            _buildDimensionButton(_dimensions[i]),
            if (i < _dimensions.length - 1) const SizedBox(width: AppSpacing.md),
          ],
        ],
      ),
    );
  }

  Widget _buildDimensionButton(_FilterDimension dimension) {
    final current = _currentValueForDimension(dimension.key);
    final label = '${dimension.label}：$current';
    return GestureDetector(
      onTap: () => _showDimensionSheet(dimension),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: AppColors.border),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Future<void> _showDimensionSheet(_FilterDimension dimension) async {
    final options = _optionsForDimension(dimension.key);
    final currentValue = _currentValueForDimension(dimension.key);

    await showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
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
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, color: AppColors.textSecondary),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1, color: AppColors.border),
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    final selected = currentValue == option;
                    return ListTile(
                      dense: true,
                      title: Text(
                        option,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 14,
                          color: selected ? AppColors.primary : AppColors.textPrimary,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                        ),
                      ),
                      trailing: selected
                          ? const Icon(Icons.check, color: AppColors.primary, size: 20)
                          : null,
                      onTap: () {
                        Navigator.of(context).pop();
                        _applyDimensionValue(dimension.key, option);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSecondRow() {
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

  Widget _buildTopFilterBar() {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
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
            label: '大类',
            child: _buildKindTags(),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildLabeledRow(
            label: '分类',
            child: _buildCategoryTags(),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildLabeledRow(
            label: _secondRowLabel,
            child: _buildSecondRow(),
          ),
        ],
      ),
    );
  }

  Widget _buildLabeledRow({
    required String label,
    required Widget child,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: () => _loadData(refresh: true),
              child: const Text('重试'),
            ),
          ],
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

    final isBangumiDaily = _currentKind == 'anime' && _selectedPrimary == '每日放送';
    final items = _movies.map((movie) {
      return PosterItem(
        id: movie.id,
        title: movie.title,
        posterUrl: movie.poster,
        year: movie.year,
        rating: movie.rate,
        ratingLabel: isBangumiDaily ? 'Bangumi' : '豆瓣',
        onTap: () => _openDetail(context, movie),
      );
    }).toList();

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            color: AppColors.primary,
            backgroundColor: AppColors.bgSurface,
            onRefresh: () => _loadData(refresh: true),
            child: MobilePosterGrid(
              controller: _scrollController,
              items: items,
            ),
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
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: SafeArea(
        child: Column(
          children: [
            _buildTopFilterBar(),
            Expanded(
              child: _buildBody(context),
            ),
          ],
        ),
      ),
    );
  }
}
