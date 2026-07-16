import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hain_tv/models/bangumi_calendar_item.dart';
import 'package:hain_tv/models/douban_movie.dart';
import 'package:hain_tv/models/favorite.dart';
import 'package:hain_tv/models/play_record.dart' as models;
import 'package:hain_tv/models/search_result.dart';
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/models/video_detail.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/player/video_player_backend.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/douban_service.dart';
import 'package:hain_tv/services/favorite_refresh_notifier.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/services/local_storage_service.dart' as local;
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/search_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/screens/mobile/player_screen.dart';

class MobileDetailScreen extends StatefulWidget {
  final List<SourceOption> sources;
  final int initialSourceIndex;
  final String title;
  final String? poster;
  final String year;
  final int? doubanId;
  final int? bangumiId;
  final String? bangumiRate;
  final int initialEpisodeIndex;
  final int initialPlayTime;
  final bool searchOnLoad;
  final models.PlayRecord? playRecord;

  const MobileDetailScreen({
    super.key,
    required this.sources,
    this.initialSourceIndex = 0,
    required this.title,
    this.poster,
    this.year = '',
    this.doubanId,
    this.bangumiId,
    this.bangumiRate,
    this.initialEpisodeIndex = 0,
    this.initialPlayTime = 0,
    this.searchOnLoad = false,
    this.playRecord,
  });

  factory MobileDetailScreen.fromSearchResult(
    SearchResult result, {
    int initialEpisodeIndex = 0,
    int initialPlayTime = 0,
  }) {
    return MobileDetailScreen(
      sources: [SourceOption.fromSearchResult(result)],
      title: result.title,
      poster: result.poster.isNotEmpty ? result.poster : null,
      year: result.year,
      doubanId: result.doubanId,
      initialEpisodeIndex: initialEpisodeIndex,
      initialPlayTime: initialPlayTime,
    );
  }

  factory MobileDetailScreen.fromSearchResults(
    List<SearchResult> results, {
    int initialSourceIndex = 0,
    int initialEpisodeIndex = 0,
    int initialPlayTime = 0,
  }) {
    final sources = SearchService.groupBySource(results);
    return MobileDetailScreen(
      sources: sources,
      initialSourceIndex: initialSourceIndex,
      title: sources.isNotEmpty ? sources.first.title : '',
      poster: sources.isNotEmpty && sources.first.poster != null
          ? sources.first.poster
          : null,
      year: sources.isNotEmpty ? sources.first.year : '',
      doubanId: sources.isNotEmpty ? sources.first.doubanId : null,
      initialEpisodeIndex: initialEpisodeIndex,
      initialPlayTime: initialPlayTime,
    );
  }

  factory MobileDetailScreen.fromDoubanMovie(DoubanMovie movie) {
    return MobileDetailScreen(
      sources: const [],
      title: movie.title,
      poster: movie.poster.isNotEmpty ? movie.poster : null,
      year: movie.year,
      doubanId: int.tryParse(movie.id),
    );
  }

  factory MobileDetailScreen.fromBangumiCalendarItem(BangumiCalendarItem item) {
    return MobileDetailScreen(
      sources: const [],
      title: item.title,
      poster: item.poster,
      year: item.year ?? '',
      bangumiId: item.id,
      bangumiRate: item.rate,
      searchOnLoad: true,
    );
  }

  factory MobileDetailScreen.fromFavorite(Favorite favorite) {
    return MobileDetailScreen(
      sources: [
        SourceOption(
          source: favorite.source,
          sourceName: favorite.sourceName.isNotEmpty
              ? favorite.sourceName
              : favorite.source,
          id: favorite.id,
          title: favorite.title,
          poster: favorite.cover.isNotEmpty ? favorite.cover : null,
          year: '',
        ),
      ],
      title: favorite.title,
      poster: favorite.cover.isNotEmpty ? favorite.cover : null,
      year: '',
      searchOnLoad: true,
    );
  }

  factory MobileDetailScreen.fromPlayRecord(models.PlayRecord record) {
    return MobileDetailScreen(
      sources: [
        SourceOption(
          source: record.source,
          sourceName: record.sourceName.isNotEmpty
              ? record.sourceName
              : record.source,
          id: record.id,
          title: record.title,
          poster: record.cover.isNotEmpty ? record.cover : null,
          year: record.year,
          doubanId: record.doubanId != null
              ? int.tryParse(record.doubanId!)
              : null,
        ),
      ],
      title: record.title,
      poster: record.cover.isNotEmpty ? record.cover : null,
      year: record.year,
      doubanId: record.doubanId != null ? int.tryParse(record.doubanId!) : null,
      initialEpisodeIndex: record.index > 0 ? record.index - 1 : 0,
      initialPlayTime: record.playTime,
      playRecord: record,
      searchOnLoad: true,
    );
  }

  /// 通过标题和年份搜索并进入详情页
  factory MobileDetailScreen.fromTitle({
    required String title,
    String year = '',
    int initialEpisodeIndex = 0,
    int initialPlayTime = 0,
  }) {
    return MobileDetailScreen(
      sources: const [],
      title: title,
      year: year,
      initialEpisodeIndex: initialEpisodeIndex,
      initialPlayTime: initialPlayTime,
      searchOnLoad: true,
    );
  }

  @override
  State<MobileDetailScreen> createState() => _MobileDetailScreenState();
}

class _MobileDetailScreenState extends State<MobileDetailScreen> {
  bool _detailLoading = true;
  bool _doubanLoading = true;
  bool _speedTesting = false;
  bool _hasSpeedTested = false;
  bool _searchingSources = false;
  String? _error;
  VideoDetail? _videoDetail;
  DoubanMovieDetails? _doubanDetails;

  /// 视频详情请求序号，用于在用户手动切换源后丢弃旧源的异步响应，
  /// 避免界面仍显示已放弃源的数据。
  int _videoDetailRequestId = 0;

  int _selectedEpisodeIndex = 0;
  bool _episodeSortAscending = true;
  int _selectedSourceIndex = 0;

  // 仅当用户主动手动切换源时为 true，用于区分“自动选中记录源”和“用户手动切源”。
  bool _sourceSwitchedByUser = false;

  bool _isFavorite = false;
  bool _fuzzySearchEnabled = false;
  PlayerBackendType _playerBackend = PlayerBackendFactory.platformDefault;
  late List<SourceOption> _sources;
  models.PlayRecord? _playRecord;

  bool _summaryExpanded = false;

  VideoPlayerBackend? _previewBackend;
  final List<StreamSubscription> _previewSubscriptions = [];
  final ScrollController _scrollController = ScrollController();
  final Map<int, GlobalKey> _episodeKeys = {};

  /// 与播放页共享源列表，进入全屏播放后搜索/测速仍会继续，
  /// 新源可实时同步到播放页的换源列表。
  final ValueNotifier<List<SourceOption>> _sourcesNotifier = ValueNotifier([]);

  SourceOption get _currentSource {
    if (_sources.isEmpty) {
      return const SourceOption(source: '', sourceName: '', id: '', title: '');
    }
    return _sources[_selectedSourceIndex];
  }

  @override
  void initState() {
    super.initState();
    // 先直接展示传入的源，避免在路由转场期间做繁重的同步过滤导致灰屏/卡顿。
    _sources = widget.sources;
    _sourcesNotifier.value = List.unmodifiable(_sources);
    _selectedEpisodeIndex = widget.initialEpisodeIndex;
    _selectedSourceIndex = widget.initialSourceIndex.clamp(
      0,
      _sources.isEmpty ? 0 : _sources.length - 1,
    );
    _playRecord = widget.playRecord;
    // 首帧渲染后再过滤源并加载数据，让详情页先显示出来。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _filterSources();
      if (!mounted) return;
      if (_playRecord != null) {
        setState(() => _applyPlayRecordSelection());
        _scrollToSelectedEpisode();
      }
      _loadData();
    });
  }

  /// 过滤掉与影片标题不精确匹配的源，避免传入的模糊结果污染列表。
  void _filterSources() {
    if (widget.sources.isEmpty || widget.title.isEmpty) return;
    final variants = SearchService.generateSearchVariants(widget.title);
    final filtered = widget.sources
        .where(
          (s) => SearchService.isExactTitleMatch(
            s.title,
            widget.title,
            variants: variants,
          ),
        )
        .toList();
    if (!mounted) return;
    setState(() {
      _sources = filtered;
      _sourcesNotifier.value = List.unmodifiable(_sources);
      _selectedSourceIndex = _selectedSourceIndex.clamp(
        0,
        _sources.isEmpty ? 0 : _sources.length - 1,
      );
    });
  }

  /// 按标题查询是否有播放记录。
  /// [force] 为 true 时，即使已有记录也会重新查询，用于从播放页返回后刷新。
  /// [applySelection] 为 true 时，查询到记录后自动选中记录中的源。
  /// [localOnly] 为 true 时只读本地，避免远程请求阻塞 UI。
  Future<void> _loadPlayRecord({
    bool force = false,
    bool applySelection = false,
    bool localOnly = false,
  }) async {
    if (_playRecord != null && !force) return;
    // 收集可能的标题：Bangumi 标题、源标题、视频详情标题可能不一致，
    // 播放记录保存的是视频源标题，所以要用多个候选标题去匹配。
    final candidateTitles = <String>{widget.title};
    if (_videoDetail != null && _videoDetail!.title.isNotEmpty) {
      candidateTitles.add(_videoDetail!.title);
    }
    if (_currentSource.title.isNotEmpty) {
      candidateTitles.add(_currentSource.title);
    }
    if (_doubanDetails != null && _doubanDetails!.title.isNotEmpty) {
      candidateTitles.add(_doubanDetails!.title);
    }
    try {
      final record = await PlayRecordService.findByTitles(
        candidateTitles.toList(),
        year: widget.year,
        localOnly: localOnly,
      );
      if (mounted) {
        setState(() {
          _playRecord = record;
          if (applySelection && record != null) {
            _applyPlayRecordSelection();
          }
        });
        if (applySelection && record != null) {
          _scrollToSelectedEpisode();
        }
      }
    } catch (e) {
      debugPrint('查询播放记录失败: $e');
    }
  }

  /// 根据当前 [_playRecord] 选中对应源与集数。
  /// 若用户已手动切换源，则不再覆盖当前源，仅同步集数。
  void _applyPlayRecordSelection() {
    final record = _playRecord;
    if (record == null || _sources.isEmpty) return;
    if (!_sourceSwitchedByUser) {
      final index = _sources.indexWhere(
        (s) => s.source == record.source && s.id == record.id,
      );
      if (index >= 0) {
        _selectedSourceIndex = index;
      }
    }
    // 同步播放记录中的集数（转换为 0-based 索引）
    final episodeIndex = record.index > 0 ? record.index - 1 : 0;
    final detail = _videoDetail;
    if (detail != null && episodeIndex < detail.episodes.length) {
      _selectedEpisodeIndex = episodeIndex;
    } else if (detail == null) {
      // 详情尚未加载完成时先暂存，后续加载后再应用
      _selectedEpisodeIndex = episodeIndex;
    }
  }

  /// 将当前选中的集数滚动到可视区域。
  void _scrollToSelectedEpisode() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final key = _episodeKeys[_selectedEpisodeIndex];
      final ctx = key?.currentContext;
      if (ctx != null && ctx.mounted) {
        Scrollable.ensureVisible(
          ctx,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.5,
        );
      }
    });
  }

  @override
  void dispose() {
    _disposePreviewPlayer();
    _scrollController.dispose();
    _sourcesNotifier.dispose();
    super.dispose();
  }

  /// 从年份字符串中提取 4 位数字年份，与 LunaTV 的 normalizeYearForMatch 对齐。
  String? _extractYear(String year) {
    final match = RegExp(r'\d{4}').firstMatch(year);
    return match?.group(0);
  }

  /// 判断结果年份是否与请求年份匹配；请求年份为空或无法解析时视为匹配。
  bool _yearMatches(String resultYear, String requestedYear) {
    if (requestedYear.isEmpty) return true;
    final requested = _extractYear(requestedYear);
    if (requested == null || requested.isEmpty) return true;
    final result = _extractYear(resultYear);
    return result == requested;
  }

  Future<void> _loadFavoriteStatus({bool localOnly = false}) async {
    final source = _currentSource.source;
    final id = _currentSource.id;
    if (source.isEmpty || id.isEmpty) return;

    bool isFavorite;
    if (localOnly) {
      isFavorite = await local.LocalStorageService.isFavorite(source, id);
    } else {
      final key = '$source+$id';
      isFavorite = await LunaTVService.isFavorite(key);
      // 同步远程状态到本地
      if (isFavorite) {
        final record = local.FavoriteRecord(
          source: source,
          id: id,
          title: widget.title,
          posterUrl: widget.poster ?? _doubanDetails?.poster,
          year: widget.year,
          createdAt: DateTime.now(),
        );
        await local.LocalStorageService.addFavorite(record);
      } else {
        await local.LocalStorageService.removeFavorite(source, id);
      }
    }

    if (mounted) {
      setState(() => _isFavorite = isFavorite);
    }
  }

  Future<void> _loadPlayerBackend() async {
    final source = _currentSource.source;
    final id = _currentSource.id;
    if (source.isEmpty || id.isEmpty) {
      final defaultBackend = await UserDataService.getPlayerBackend();
      if (mounted) {
        setState(() => _playerBackend = defaultBackend);
      }
      return;
    }
    final type = await UserDataService.getPlayerBackendForVideo(source, id);
    if (mounted) {
      setState(() => _playerBackend = type);
    }
  }

  Future<void> _loadData() async {
    if (mounted) {
      setState(() {
        _doubanLoading = true;
        _error = null;
      });
    }

    // 如果没有源或明确要求搜索，提前进入搜索状态，避免先显示"精确匹配无结果"
    final needsSourceSearch =
        widget.title.isNotEmpty && (_sources.isEmpty || widget.searchOnLoad);
    if (needsSourceSearch && mounted) {
      setState(() => _searchingSources = true);
    }

    // 进入详情页立即在后台搜索更多源并触发测速，搜索与下面的播放记录/收藏/详情加载并发执行。
    if (needsSourceSearch) {
      unawaited(_searchSourcesInBackground());
    }

    // 先查询本地播放记录；若存在记录则优先使用记录中的源。
    await _loadPlayRecord(applySelection: true, localOnly: true);
    // 后台同步远程记录与豆瓣海报
    unawaited(_loadPlayRecord(applySelection: true, localOnly: false));

    // 源确定后再加载收藏状态与播放器后端。
    await _loadFavoriteStatus(localOnly: true);
    unawaited(_loadFavoriteStatus(localOnly: false));
    await _loadPlayerBackend();

    // 源数量>=2 时立即后台测速，不等详情加载完成。
    _maybeStartSpeedTest();

    final futures = <Future<void>>[];

    if (_currentSource.source.isNotEmpty && _currentSource.id.isNotEmpty) {
      futures.add(_loadVideoDetail());
    } else {
      if (mounted) setState(() => _detailLoading = false);
    }

    // 如果有豆瓣ID、Bangumi ID或需要搜索，加载详情
    if (widget.doubanId != null ||
        widget.bangumiId != null ||
        widget.searchOnLoad ||
        widget.title.isNotEmpty) {
      futures.add(_loadDoubanDetails());
    } else {
      if (mounted) setState(() => _doubanLoading = false);
    }

    if (futures.isEmpty) {
      if (mounted) {
        setState(() {
          _detailLoading = false;
          _doubanLoading = false;
          _error = '缺少视频源信息';
        });
      }
      return;
    }

    await Future.wait(futures);

    // 详情加载完成后再次尝试测速（若源在详情加载期间才达到 2 个且尚未测速）。
    _maybeStartSpeedTest();
  }

  /// 满足条件时在后台启动测速，避免重复启动。
  void _maybeStartSpeedTest() {
    if (_sources.length >= 2 && !_speedTesting && !_hasSpeedTested) {
      unawaited(_runSpeedTest());
    }
  }

  /// 提取用于模糊/简化搜索的基准名称：取第一个空格或标点（:：-–—）之前的部分。
  String _extractSearchBaseName(String title) {
    final splitIndex = title.indexOf(RegExp(r'[\s:：\-–—]'));
    if (splitIndex <= 0) return title.trim();
    return title.substring(0, splitIndex).trim();
  }

  /// 后台搜索播放源，搜索到一个即刷新界面，全部完成后加载当前选中源详情。
  /// 海报墙进入默认使用精确匹配；若 [fuzzy] 为 true 则启用模糊匹配。
  Future<void> _searchSourcesInBackground({bool fuzzy = false}) async {
    if (!mounted) return;
    setState(() {
      _searchingSources = true;
      _fuzzySearchEnabled = fuzzy;
    });

    // 使用快速搜索（含变体），不走豆瓣 enrich，避免详情页等待过久。
    // Bangumi 每日放送条目直接使用严格模糊匹配，避免精确模式把带后缀
    // 的源标题（如"名侦探柯南（1996）"）过滤掉，与 LunaTV 行为对齐。
    final initialExactMatch = widget.bangumiId != null ? false : !fuzzy;
    // 手动模糊搜索时使用影视名基准名（首个空格/标点前），提升命中率
    final searchKeyword = fuzzy
        ? _extractSearchBaseName(widget.title)
        : widget.title;
    debugPrint(
      '[SourceSearch] 开始搜索: title=${widget.title}, keyword=$searchKeyword, year=${widget.year}, '
      'bangumiId=${widget.bangumiId}, exactMatch=$initialExactMatch, fuzzy=$fuzzy',
    );
    final onProgress = (List<SourceOption> sources) {
      _mergeAndUpdateSources(sources, fuzzy: fuzzy, isFinal: false);
    };
    var response = await SearchService.searchSourcesFastWithVariants(
      keyword: searchKeyword,
      exactMatch: initialExactMatch,
      fuzzy: fuzzy,
      onProgress: onProgress,
    );
    debugPrint(
      '[SourceSearch] 首轮结果: success=${response.success}, '
      'count=${response.data?.length ?? 0}, message=${response.message}',
    );

    // 若原始标题无结果，尝试用基准名（首个空格/标点前）重试
    if ((!response.success ||
            response.data == null ||
            response.data!.isEmpty) &&
        !fuzzy) {
      final simplified = _extractSearchBaseName(widget.title);
      if (simplified.isNotEmpty && simplified != widget.title) {
        debugPrint('[SourceSearch] 尝试基准名重试: $simplified');
        response = await SearchService.searchSourcesFastWithVariants(
          keyword: simplified,
          exactMatch: true,
          fuzzy: false,
          onProgress: onProgress,
        );
        debugPrint(
          '[SourceSearch] 基准名重试结果: count=${response.data?.length ?? 0}',
        );
      }
    }

    // Bangumi 每日放送条目：精确匹配无结果时自动降级到严格模糊匹配
    //（仅保留包含/高相似结果），避免 LunaTV 式宽泛匹配引入大量不相关源。
    // 若仍无结果，用户可手动点击“尝试模糊搜索”使用更宽松的阈值。
    if ((!response.success ||
            response.data == null ||
            response.data!.isEmpty) &&
        !fuzzy &&
        widget.bangumiId != null) {
      debugPrint('[SourceSearch] Bangumi 首轮无结果，降级严格模糊匹配');
      response = await SearchService.searchSourcesFastWithVariants(
        keyword: widget.title,
        exactMatch: false,
        fuzzy: false,
        onProgress: onProgress,
      );
      debugPrint(
        '[SourceSearch] Bangumi 降级结果: count=${response.data?.length ?? 0}',
      );
    }

    if (response.success &&
        response.data != null &&
        response.data!.isNotEmpty) {
      _mergeAndUpdateSources(response.data!, fuzzy: fuzzy, isFinal: true);
    } else if (mounted) {
      setState(() => _searchingSources = false);
    }
  }

  /// 将搜索到的源与当前 [_sources] 合并并刷新界面。
  /// [isFinal] 为 true 时，会重置搜索状态并尝试加载当前选中源的视频详情。
  void _mergeAndUpdateSources(
    List<SourceOption> searchedSources, {
    required bool fuzzy,
    required bool isFinal,
  }) {
    if (!mounted || searchedSources.isEmpty) {
      if (isFinal && mounted) setState(() => _searchingSources = false);
      return;
    }

    final exactYear = widget.year.isNotEmpty
        ? searchedSources
              .where((s) => _yearMatches(s.year, widget.year))
              .toList()
        : <SourceOption>[];
    final sourcesToUse = exactYear.isNotEmpty ? exactYear : searchedSources;

    // 合并已有源与搜索结果，去重；播放记录对应的原始源优先排在最前
    final originalSource = widget.playRecord != null
        ? '${widget.playRecord!.source}+${widget.playRecord!.id}'
        : null;
    final seen = <String>{};
    final mergedSources = <SourceOption>[];

    // 1. 优先保留原始源
    for (final s in _sources) {
      final key = '${s.source}+${s.id}';
      if (key == originalSource) {
        seen.add(key);
        mergedSources.add(s);
        break;
      }
    }

    // 2. 加入搜索结果
    for (final s in sourcesToUse) {
      final key = '${s.source}+${s.id}';
      if (!seen.contains(key)) {
        seen.add(key);
        mergedSources.add(s);
      }
    }

    // 3. 模糊模式下保留其余已有源；精确模式下丢弃不匹配的已有源
    if (fuzzy) {
      for (final s in _sources) {
        final key = '${s.source}+${s.id}';
        if (!seen.contains(key)) {
          seen.add(key);
          mergedSources.add(s);
        }
      }
    }

    // 若用户已手动选源，尽量保留当前选中的源；否则优先使用播放记录源。
    final currentSourceKey =
        _sources.isNotEmpty && _selectedSourceIndex < _sources.length
        ? '${_sources[_selectedSourceIndex].source}+${_sources[_selectedSourceIndex].id}'
        : null;
    var preservedIndex = currentSourceKey != null
        ? mergedSources.indexWhere(
            (s) => '${s.source}+${s.id}' == currentSourceKey,
          )
        : -1;

    // 用户手动选择的源若不在搜索结果中，仍予以保留，避免自动切回记录源。
    if (_sourceSwitchedByUser &&
        currentSourceKey != null &&
        preservedIndex < 0) {
      mergedSources.add(_sources[_selectedSourceIndex]);
      preservedIndex = mergedSources.length - 1;
    }

    setState(() {
      _sources = mergedSources;
      _sourcesNotifier.value = List.unmodifiable(_sources);
      if (_sourceSwitchedByUser && preservedIndex >= 0) {
        _selectedSourceIndex = preservedIndex;
      } else if (originalSource != null) {
        final originalIndex = mergedSources.indexWhere(
          (s) => '${s.source}+${s.id}' == originalSource,
        );
        if (originalIndex >= 0) {
          _selectedSourceIndex = originalIndex;
    
        } else {
          _selectedSourceIndex = 0;
        }
      } else {
        _selectedSourceIndex = 0;
      }
      if (isFinal) _searchingSources = false;
      if (isFinal && _playRecord != null) {
        _applyPlayRecordSelection();
      }
    });
    if (isFinal && _playRecord != null) {
      _scrollToSelectedEpisode();
    }

    // 视频详情尚未加载时，自动加载当前选中源
    if (isFinal && _videoDetail == null && _currentSource.source.isNotEmpty) {
      unawaited(_loadVideoDetail());
    }

    // 搜索到源后，用源标题再次尝试匹配播放记录（Bangumi 标题与源标题可能不同）。
    if (isFinal && _playRecord == null) {
      unawaited(_loadPlayRecord(force: true, applySelection: true));
    }

    // 源列表发生变化时，后台触发测速；若正在测速中则自动跳过，
    // 避免与当前测速任务冲突。
    if (_sources.length >= 2 && !_speedTesting) {
      unawaited(_runSpeedTest(force: true));
    }
  }

  /// 手动触发模糊搜索，用于精确匹配无结果时。
  Future<void> _runFuzzySearch() async {
    await _searchSourcesInBackground(fuzzy: true);
  }

  Future<void> _loadVideoDetail() async {
    final requestId = ++_videoDetailRequestId;
    final reqSource = _currentSource.source;
    final reqId = _currentSource.id;
    final reqTitle = _currentSource.title;

    final response = await LunaTVService.getDetail(
      source: reqSource,
      id: reqId,
      title: reqTitle,
    );

    if (!mounted) return;
    // 若切换源后已有新请求发出，或当前源已变更，则丢弃本次旧响应。
    if (requestId != _videoDetailRequestId) return;
    if (reqSource != _currentSource.source || reqId != _currentSource.id) {
      return;
    }

    if (response.success && response.data != null) {
      setState(() {
        _videoDetail = response.data;
        _detailLoading = false;
        if (_playRecord != null) {
          _applyPlayRecordSelection();
        }
      });
      if (_playRecord != null) {
        _scrollToSelectedEpisode();
      }
      // 视频标题已确定后，用源标题/视频标题再次尝试匹配播放记录。
      if (_playRecord == null) {
        unawaited(_loadPlayRecord(force: true, applySelection: true));
      }
    } else {
      setState(() {
        _error = response.message ?? '获取视频详情失败';
        _detailLoading = false;
      });
    }
  }

  Future<void> _loadDoubanDetails() async {
    // Bangumi 每日放送条目：优先用豆瓣详情，豆瓣找不到再回退到 Bangumi
    if (widget.bangumiId != null) {
      DoubanMovieDetails? doubanDetails;
      if (widget.title.isNotEmpty) {
        final searchResponse = await DoubanService.search(
          keyword: widget.title,
          limit: 5,
        );
        if (searchResponse.success && searchResponse.data != null) {
          DoubanMovie? bestMatch;
          var bestScore = 0.0;
          for (final candidate in searchResponse.data!) {
            var score = _titleSimilarity(widget.title, candidate.title);
            if (widget.year.isNotEmpty && candidate.year.isNotEmpty) {
              if (widget.year == candidate.year) score += 0.2;
            }
            if (score > bestScore) {
              bestScore = score;
              bestMatch = candidate;
            }
          }
          if (bestMatch != null && bestScore >= 0.6) {
            final detailResponse = await DoubanService.getDetails(
              doubanId: bestMatch.id,
            );
            if (detailResponse.success && detailResponse.data != null) {
              doubanDetails = detailResponse.data;
            }
          }
        }
      }

      if (doubanDetails == null) {
        final response = await BangumiService.fetchSubject(widget.bangumiId!);
        if (response.success && response.data != null) {
          doubanDetails = response.data;
        }
      }

      if (mounted) {
        setState(() {
          _doubanLoading = false;
          _doubanDetails = doubanDetails;
        });
      }
      return;
    }

    // 普通豆瓣条目
    if (widget.doubanId != null) {
      final response = await DoubanService.getDetails(
        doubanId: widget.doubanId.toString(),
      );
      if (!mounted) return;
      setState(() {
        _doubanLoading = false;
        if (response.success && response.data != null) {
          _doubanDetails = response.data;
        }
      });
      return;
    }

    // 既无 Bangumi ID 也无豆瓣 ID：直接结束加载
    if (mounted) setState(() => _doubanLoading = false);
  }

  static double _titleSimilarity(String a, String b) {
    final na = a.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    final nb = b.toLowerCase().replaceAll(RegExp(r'\s+'), '');
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;

    var keywordIndex = 0;
    for (var i = 0; i < nb.length && keywordIndex < na.length; i++) {
      if (nb[i] == na[keywordIndex]) keywordIndex++;
    }
    if (keywordIndex == na.length) return 0.9;

    final matchedChars = na.split('').where(nb.contains).length;
    return matchedChars / na.length;
  }

  void _disposePreviewPlayer() {
    for (final sub in _previewSubscriptions) {
      sub.cancel();
    }
    _previewSubscriptions.clear();
    _previewBackend?.dispose();
    _previewBackend = null;
  }

  Future<void> _onSourceChanged(int index) async {
    if (index < 0 || index >= _sources.length) return;
    if (index == _selectedSourceIndex) return;

    setState(() {
      _selectedSourceIndex = index;

      _sourceSwitchedByUser = true;
      _videoDetail = null;
      _error = null;
      _selectedEpisodeIndex = 0;
      _detailLoading = true;
    });
    await _loadFavoriteStatus(localOnly: true);
    unawaited(_loadFavoriteStatus(localOnly: false));
    await _loadPlayerBackend();
    await _loadVideoDetail();
  }

  /// 按测速结果对播放源进行排序。
  /// - 无播放记录：全部按速度降序排列，最快的源放在第一位。
  /// - 有播放记录：记录原始源置顶；测速最快的源（若与记录源不同）放在第二位，
  ///   其余源按速度降序排在后面。
  List<SourceOption> _sortSourcesBySpeed(List<SourceOption> sources) {
    if (sources.length <= 1) return List<SourceOption>.from(sources);

    final record = _playRecord;
    SourceOption? recordSource;
    if (record != null) {
      recordSource = sources.firstWhere(
        (s) => s.source == record.source && s.id == record.id,
        orElse: () =>
            const SourceOption(source: '', sourceName: '', id: '', title: ''),
      );
      if (recordSource.source.isEmpty) recordSource = null;
    }

    final others = sources.where((s) => s != recordSource).toList();
    others.sort((a, b) {
      final aOk = (a.speed ?? 0) > 0;
      final bOk = (b.speed ?? 0) > 0;
      if (aOk && !bOk) return -1;
      if (!aOk && bOk) return 1;
      return (b.speed ?? 0).compareTo(a.speed ?? 0);
    });

    if (recordSource != null) {
      return [recordSource, ...others];
    }
    return others;
  }

  Future<void> _runSpeedTest({bool force = false}) async {
    if (_sources.length < 2 || _speedTesting) return;
    if (!force && _hasSpeedTested) return;

    setState(() => _speedTesting = true);

    // 记录当前选中的源标识，测速排序后优先保持不变。
    final previousSourceIndex = _selectedSourceIndex;
    final previousSource = previousSourceIndex >= 0 &&
            previousSourceIndex < _sources.length
        ? _sources[previousSourceIndex]
        : null;
    final previousSourceKey = previousSource != null
        ? '${previousSource.source}+${previousSource.id}'
        : null;

    final tested = await SearchService.speedTestSources(
      _sources,
      onProgress: (index, updated) {
        if (mounted) {
          setState(() {
            if (index >= 0 && index < _sources.length) {
              _sources[index] = updated;
            }
          });
        }
      },
    );

    if (!mounted) return;

    // 将测速结果合并到当前源列表（避免测速期间源列表被后台搜索更新后，
    // 这里用旧的 sorted 列表覆盖导致新增源丢失或用户手动选择被重置）。
    final speedMap = {
      for (final s in tested) '${s.source}+${s.id}': s.speed,
    };

    setState(() {
      // 排序前先记录当前选中的源标识，避免排序后索引错位。
      final currentSourceKey = _selectedSourceIndex >= 0 &&
              _selectedSourceIndex < _sources.length
          ? '${_sources[_selectedSourceIndex].source}+${_sources[_selectedSourceIndex].id}'
          : previousSourceKey;

      for (var i = 0; i < _sources.length; i++) {
        final key = '${_sources[i].source}+${_sources[i].id}';
        if (speedMap.containsKey(key)) {
          _sources[i] = _sources[i].copyWith(speed: speedMap[key]);
        }
      }
      _sources = _sortSourcesBySpeed(_sources);
      _sourcesNotifier.value = List.unmodifiable(_sources);
      _speedTesting = false;
      _hasSpeedTested = true;

      final record = _playRecord;
      final recordIndex = record != null
          ? _sources.indexWhere(
              (s) => s.source == record.source && s.id == record.id,
            )
          : -1;

      // 用户手动切换过源时，测速排序后仍保持用户当前选择的源。
      if (_sourceSwitchedByUser &&
          currentSourceKey != null &&
          currentSourceKey.isNotEmpty &&
          currentSourceKey != '+') {
        final manualIndex = _sources.indexWhere(
          (s) => '${s.source}+${s.id}' == currentSourceKey,
        );
        if (manualIndex >= 0) {
          _selectedSourceIndex = manualIndex;
        } else {
          // 用户手动选择的源若不在当前列表中，仍保留原选择避免被强制切走。
          // 保持当前索引并在安全范围内 clamp。
          _selectedSourceIndex = _selectedSourceIndex.clamp(
            0,
            _sources.isEmpty ? 0 : _sources.length - 1,
          );
        }
      } else if (recordIndex >= 0) {
        _selectedSourceIndex = recordIndex;
      } else {
        _selectedSourceIndex = 0;
      }

      debugPrint(
        '[SourceSelect] speedTest done: userSwitched=$_sourceSwitchedByUser, '
        'currentKey=$currentSourceKey, selectedIndex=$_selectedSourceIndex, '
        'source=${_sources.isNotEmpty ? _sources[_selectedSourceIndex].source : ""}',
      );
    });

    // 选中源发生变化时，重新加载对应源的详情与播放器后端。
    final currentSource = _sources[_selectedSourceIndex];
    if (previousSource == null ||
        currentSource.source != previousSource.source ||
        currentSource.id != previousSource.id) {
      setState(() {
        _videoDetail = null;
        _error = null;
        _selectedEpisodeIndex = 0;
        _detailLoading = true;
      });
      await _loadFavoriteStatus(localOnly: true);
      unawaited(_loadFavoriteStatus(localOnly: false));
      await _loadPlayerBackend();
      await _loadVideoDetail();
    }
  }

  void _toggleFavorite() async {
    final source = _currentSource.source;
    final id = _currentSource.id;
    if (source.isEmpty || id.isEmpty) return;
    final key = '$source+$id';

    // 1. 先按本地状态切换，立即刷新 UI
    final currentlyFavorite = await local.LocalStorageService.isFavorite(
      source,
      id,
    );
    final targetFavorite = !currentlyFavorite;
    final record = local.FavoriteRecord(
      source: source,
      id: id,
      title: widget.title,
      posterUrl: widget.poster ?? _doubanDetails?.poster,
      year: widget.year,
      createdAt: DateTime.now(),
    );
    if (targetFavorite) {
      await local.LocalStorageService.addFavorite(record);
    } else {
      await local.LocalStorageService.removeFavorite(source, id);
    }
    if (mounted) {
      setState(() => _isFavorite = targetFavorite);
    }
    FavoriteRefreshNotifier.instance.notify();

    // 2. 后台同步到 LunaTV 服务器
    unawaited(_syncFavoriteToRemote(key: key, add: targetFavorite));
  }

  Future<void> _syncFavoriteToRemote({
    required String key,
    required bool add,
  }) async {
    try {
      final favorite = Favorite(
        source: _currentSource.source,
        id: _currentSource.id,
        title: widget.title,
        cover: widget.poster ?? _doubanDetails?.poster ?? '',
        sourceName: _currentSource.sourceName,
      );
      if (add) {
        await LunaTVService.addFavorite(key: key, favorite: favorite);
      } else {
        await LunaTVService.deleteFavorite(key);
      }
    } catch (e) {
      debugPrint('同步远程收藏失败: $e');
    }
  }

  /// 查找指定源 ID 在当前源列表中的索引。
  int? _findSourceIndex(String source, String id) {
    final key = '$source+$id';
    final index = _sources.indexWhere((s) => '${s.source}+${s.id}' == key);
    return index >= 0 ? index : null;
  }

  Future<void> _playEpisode(
    int index, {
    int initialPlayTime = 0,
    int? preferredSourceIndex,
  }) async {
    // 若视频详情尚未加载完成，短暂等待（用户点击时详情通常已在后台加载）
    if (_videoDetail == null && _detailLoading) {
      await Future.any([
        Future.doWhile(() async {
          await Future.delayed(const Duration(milliseconds: 100));
          return mounted && _videoDetail == null && _detailLoading;
        }),
        Future.delayed(const Duration(seconds: 8)),
      ]);
    }

    final detail = _videoDetail;
    if (detail == null || detail.episodes.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('播放资源加载中，请稍后再试'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (index < 0 || index >= detail.episodes.length) return;

    // 播放时优先使用指定的源（如播放记录），否则使用用户当前选中的源。
    // 自动测速择优只在详情页初始化时执行一次，播放时不再调回优选源。
    final sourceIndex = preferredSourceIndex ?? _selectedSourceIndex;

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobilePlayerScreen(
          videoDetail: detail,
          episodeIndex: index,
          sources: _sources,
          sourcesNotifier: _sourcesNotifier,
          initialSourceIndex: sourceIndex,
          playerBackend: _playerBackend,
          initialPositionMs: initialPlayTime * 1000,
        ),
      ),
    );

    // 从播放页返回后异步刷新播放记录：先读本地立即更新 UI，再在后台同步远程/海报
    if (mounted) {
      unawaited(
        _loadPlayRecord(
          force: true,
          applySelection: true,
          localOnly: true,
        ).then((_) async {
          if (mounted) {
            // 后台再拉取远程记录和豆瓣海报，不阻塞当前页面
            unawaited(
              _loadPlayRecord(
                force: true,
                applySelection: true,
                localOnly: false,
              ),
            );
          }
        }),
      );
    }
  }

  Widget _buildPoster() {
    var url = _doubanDetails?.poster ?? widget.poster ?? '';
    if (url.isEmpty) {
      return Container(
        color: AppColors.bgSurface,
        child: Center(
          child: Text(
            widget.title.isNotEmpty ? widget.title.substring(0, 1) : '',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 48,
              color: AppColors.textMuted,
            ),
          ),
        ),
      );
    }

    if (url.startsWith('//')) {
      url = 'https:$url';
    }
    url = BangumiService.proxyImageUrl(url);

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      cacheManager: HainTvCacheManager(),
      memCacheWidth: 300,
      memCacheHeight: 450,
      httpHeaders: const {
        'Referer': 'https://m.douban.com',
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      },
      placeholder: (_, __) => Container(color: AppColors.bgSurface),
      errorWidget: (_, __, ___) => Container(color: AppColors.bgSurface),
    );
  }

  Widget _buildSourceSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Text(
              '播放源',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            if (_searchingSources)
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              ),
            if (_searchingSources) const SizedBox(width: AppSpacing.sm),
            if (_sources.length >= 2)
              GestureDetector(
                onTap: () => _runSpeedTest(force: true),
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
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (_speedTesting)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.primary,
                          ),
                        )
                      else
                        const Icon(
                          Icons.network_check,
                          color: AppColors.primary,
                          size: 16,
                        ),
                      const SizedBox(width: AppSpacing.xs),
                      Text(
                        _speedTesting ? '测速中' : '优选测速',
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 13,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: 180,
          child: _sources.isEmpty
              ? _searchingSources
                    ? const SizedBox.shrink()
                    : _fuzzySearchEnabled
                    ? const Text(
                        '未找到相关播放源',
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 14,
                          color: AppColors.textSecondary,
                        ),
                      )
                    : GestureDetector(
                        onTap: _runFuzzySearch,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.sm,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.bgElevated,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.search,
                                color: AppColors.primary,
                                size: 16,
                              ),
                              SizedBox(width: AppSpacing.xs),
                              Text(
                                '精确匹配无结果，尝试模糊搜索',
                                style: TextStyle(
                                  fontFamily: 'NotoSansSC',
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  child: Row(
                    children: List.generate(_sources.length, (index) {
                      return Padding(
                        padding: EdgeInsets.only(
                          right: index < _sources.length - 1
                              ? AppSpacing.md
                              : AppSpacing.sm,
                        ),
                        child: _buildSourceCard(index),
                      );
                    }),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildSourceCard(int index) {
    final source = _sources[index];
    final selected = index == _selectedSourceIndex;
    final speedText = _formatSpeed(source.speed);
    final badgeColor = _speedColor(source.speed);
    final resolutionText = source.resolution?.trim() ?? '';

    return GestureDetector(
      onTap: () => _onSourceChanged(index),
      child: SizedBox(
        width: 140,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: CachedNetworkImage(
                  imageUrl: source.poster?.isNotEmpty == true
                      ? source.poster!
                      : '',
                  fit: BoxFit.cover,
                  cacheManager: HainTvCacheManager(),
                  memCacheWidth: 300,
                  memCacheHeight: 450,
                  placeholder: (_, __) => Container(color: AppColors.bgSurface),
                  errorWidget: (_, __, ___) => Container(
                    color: AppColors.bgSurface,
                    child: Center(
                      child: Text(
                        source.title.isNotEmpty
                            ? source.title.substring(0, 1)
                            : '',
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 24,
                          color: AppColors.textMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 底部彩色背景 + 标题/源名
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(AppRadius.sm),
                  ),
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.bgElevated.withValues(alpha: 0.95),
                      border: Border(
                        top: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.6),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          source.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          source.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (speedText.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: badgeColor,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      speedText,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              if (resolutionText.isNotEmpty)
                Positioned(
                  top: speedText.isNotEmpty ? 28 : 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      resolutionText,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textInverse,
                      ),
                    ),
                  ),
                ),
              if (selected)
                const Positioned(
                  top: 6,
                  left: 6,
                  child: Icon(
                    Icons.check_circle,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  String _formatSpeed(double? speedBps) {
    if (speedBps == null) return '';
    if (speedBps <= 0) return '不可用';
    if (speedBps >= 1000 * 1000) {
      return '${(speedBps / 1000 / 1000).toStringAsFixed(1)} Mbps';
    }
    return '${(speedBps / 1000).toStringAsFixed(1)} Kbps';
  }

  Color _speedColor(double? speedBps) {
    if (speedBps == null || speedBps <= 0) return AppColors.error;
    if (speedBps >= 8 * 1000 * 1000) return AppColors.success;
    if (speedBps >= 2 * 1000 * 1000) return AppColors.primary;
    return AppColors.warning;
  }

  Widget _buildInfoSection() {
    final rating = _doubanDetails?.rate;
    final genres = _doubanDetails?.genres ?? [];
    final summary = _doubanDetails?.summary ?? _videoDetail?.desc ?? '';
    final directors = _doubanDetails?.directors ?? [];
    final screenwriters = _doubanDetails?.screenwriters ?? [];
    final actors = _doubanDetails?.actors ?? [];
    final countries = _doubanDetails?.countries ?? [];
    final languages = _doubanDetails?.languages ?? [];
    final duration = _doubanDetails?.duration;
    final releaseDate = _doubanDetails?.releaseDate;
    final totalEpisodes = _doubanDetails?.totalEpisodes;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          widget.title,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 24,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            if (widget.year.isNotEmpty) _buildMetaChip(widget.year),
            if (rating != null && rating.isNotEmpty)
              _buildMetaChip('豆瓣 $rating', isPrimary: true),
            if (widget.bangumiRate != null && widget.bangumiRate!.isNotEmpty)
              _buildMetaChip('Bangumi ${widget.bangumiRate}', isBangumi: true),
            if (genres.isNotEmpty) _buildMetaChip(genres.take(3).join(' / ')),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        if (_doubanLoading)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.primary,
            ),
          )
        else if (summary.isNotEmpty)
          GestureDetector(
            onTap: () => setState(() => _summaryExpanded = !_summaryExpanded),
            child: Text(
              summary,
              maxLines: _summaryExpanded ? null : 3,
              overflow: _summaryExpanded
                  ? TextOverflow.visible
                  : TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        const SizedBox(height: AppSpacing.md),
        _buildInfoRow('导演', directors),
        _buildInfoRow('编剧', screenwriters),
        _buildInfoRow('主演', actors, maxItems: 8),
        if (releaseDate != null && releaseDate.isNotEmpty)
          _buildInfoText('首播', releaseDate),
        const SizedBox(height: AppSpacing.md),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: [
            if (countries.isNotEmpty)
              _buildMetaChip(countries.take(2).join(' / ')),
            if (languages.isNotEmpty) _buildMetaChip(languages.first),
            if (totalEpisodes != null && totalEpisodes > 0)
              _buildMetaChip('共${totalEpisodes}集'),
            if (duration != null && duration.isNotEmpty)
              _buildMetaChip(duration),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        _buildActionButtons(),
      ],
    );
  }

  Widget _buildInfoRow(String label, List<String> items, {int maxItems = 5}) {
    if (items.isEmpty) return const SizedBox.shrink();
    final value = items.take(maxItems).join(' / ');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoText(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '$label: ',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              height: 1.5,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                height: 1.5,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButtons() {
    final record = _playRecord;
    // 未手动切源时优先使用播放记录原始源；手动切源后跟随当前选中的源。
    final effectiveSourceIndex = _sources.isNotEmpty
        ? _selectedSourceIndex.clamp(0, _sources.length - 1)
        : -1;
    final continueSourceIndex = record != null && effectiveSourceIndex >= 0
        ? (_sourceSwitchedByUser
              ? effectiveSourceIndex
              : _findSourceIndex(record.source, record.id) ??
                    effectiveSourceIndex)
        : effectiveSourceIndex;
    final continueSource = continueSourceIndex >= 0
        ? _sources[continueSourceIndex]
        : const SourceOption(source: '', sourceName: '', id: '', title: '');
    final sourceName = record != null && continueSourceIndex >= 0
        ? (continueSource.sourceName.isNotEmpty
              ? continueSource.sourceName
              : continueSource.source)
        : '';
    final hasRecord = record != null;

    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hasRecord)
          GestureDetector(
            onTap: () => _playEpisode(
              record.index > 0 ? record.index - 1 : 0,
              initialPlayTime: record.playTime,
              preferredSourceIndex: continueSourceIndex,
            ),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '继续播放',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                  if (sourceName.isNotEmpty)
                    Text(
                      '来源：$sourceName',
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 11,
                        color: Colors.white70,
                      ),
                    ),
                ],
              ),
            ),
          ),
        if (hasRecord)
          OutlinedButton.icon(
            onPressed: () => _playEpisode(0),
            icon: const Icon(Icons.replay, color: AppColors.textPrimary),
            label: const Text(
              '从头播放',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: AppColors.textPrimary,
              side: const BorderSide(color: AppColors.border),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),
        if (!hasRecord)
          ElevatedButton.icon(
            onPressed: () => _playEpisode(_selectedEpisodeIndex),
            icon: const Icon(Icons.play_arrow, color: Colors.white),
            label: const Text(
              '播放',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.primary,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
            ),
          ),
        ElevatedButton.icon(
          onPressed: _toggleFavorite,
          icon: Icon(
            _isFavorite ? Icons.favorite : Icons.favorite_border,
            color: _isFavorite ? AppColors.primary : AppColors.textPrimary,
          ),
          label: Text(
            _isFavorite ? '已收藏' : '收藏',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _isFavorite ? AppColors.primary : AppColors.textPrimary,
            ),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: _isFavorite
                ? AppColors.primaryTint
                : AppColors.bgElevated,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            elevation: 0,
          ),
        ),
      ],
    );
  }

  Widget _buildMetaChip(
    String text, {
    bool isPrimary = false,
    bool isBangumi = false,
  }) {
    final Color bgColor;
    final Color fgColor;
    if (isBangumi) {
      bgColor = const Color(0xFFFBCFE8); // 浅粉
      fgColor = const Color(0xFFDB2777); // 深粉
    } else if (isPrimary) {
      bgColor = AppColors.primaryTint;
      fgColor = AppColors.primary;
    } else {
      bgColor = AppColors.bgElevated;
      fgColor = AppColors.textSecondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 12,
          fontWeight: isPrimary || isBangumi
              ? FontWeight.w600
              : FontWeight.w400,
          color: fgColor,
        ),
      ),
    );
  }

  Widget _buildEpisodes() {
    final detail = _videoDetail;
    if (_detailLoading) {
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Center(
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.primary,
          ),
        ),
      );
    }

    if (detail == null || detail.episodes.isEmpty) {
      return const SizedBox.shrink();
    }

    final titles = detail.episodesTitles.isNotEmpty
        ? detail.episodesTitles
        : List.generate(detail.episodes.length, (i) => '第${i + 1}集');

    final displayIndices = _episodeSortAscending
        ? List<int>.generate(detail.episodes.length, (i) => i)
        : List<int>.generate(
            detail.episodes.length,
            (i) => i,
          ).reversed.toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(
            left: AppSpacing.lg,
            right: AppSpacing.lg,
            bottom: AppSpacing.md,
          ),
          child: Row(
            children: [
              const Text(
                '选集',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: () {
                  if (!_episodeSortAscending) {
                    setState(() => _episodeSortAscending = true);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: _episodeSortAscending
                        ? AppColors.primaryTint
                        : AppColors.bgSurface,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(
                      color: _episodeSortAscending
                          ? AppColors.primary
                          : AppColors.border,
                    ),
                  ),
                  child: Text(
                    '正序',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: _episodeSortAscending
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              GestureDetector(
                onTap: () {
                  if (_episodeSortAscending) {
                    setState(() => _episodeSortAscending = false);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: !_episodeSortAscending
                        ? AppColors.primaryTint
                        : AppColors.bgSurface,
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                    border: Border.all(
                      color: !_episodeSortAscending
                          ? AppColors.primary
                          : AppColors.border,
                    ),
                  ),
                  child: Text(
                    '倒序',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      color: !_episodeSortAscending
                          ? AppColors.primary
                          : AppColors.textSecondary,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 72,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: List.generate(displayIndices.length, (displayIndex) {
                final originalIndex = displayIndices[displayIndex];
                final title = titles[originalIndex];
                final selected = _selectedEpisodeIndex == originalIndex;
                return Padding(
                  key: _episodeKeys.putIfAbsent(
                    originalIndex,
                    () => GlobalKey(),
                  ),
                  padding: EdgeInsets.only(
                    right: displayIndex < displayIndices.length - 1
                        ? AppSpacing.sm
                        : 0,
                  ),
                  child: SizedBox(
                    width: 100,
                    child: GestureDetector(
                      onTap: () => _playEpisode(originalIndex),
                      child: Container(
                        alignment: Alignment.center,
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.sm,
                          vertical: AppSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: selected
                              ? AppColors.primaryTint
                              : AppColors.bgSurface,
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: selected
                                ? AppColors.primary
                                : AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasFatalError =
        _error != null &&
        _videoDetail == null &&
        _doubanDetails == null &&
        !_detailLoading &&
        !_doubanLoading;

    Widget child;
    if (hasFatalError) {
      child = Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                style: const TextStyle(color: AppColors.textSecondary),
              ),
              const SizedBox(height: AppSpacing.lg),
              ElevatedButton(
                onPressed: _loadData,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                ),
                child: const Text(
                  '重试',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: Colors.white,
                    fontSize: 16,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      final screenWidth = MediaQuery.of(context).size.width;
      final posterWidth = screenWidth * 0.42;

      child = Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                    child: SizedBox(
                      width: posterWidth,
                      child: AspectRatio(
                        aspectRatio: 2 / 3,
                        child: _buildPoster(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: _buildInfoSection(),
                ),
                const SizedBox(height: AppSpacing.lg),
                _buildEpisodes(),
                const SizedBox(height: AppSpacing.lg),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                  ),
                  child: _buildSourceSelector(),
                ),
                const SizedBox(height: AppSpacing.xl),
              ],
            ),
          ),
        ),
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) Navigator.of(context).pop();
      },
      child: child,
    );
  }
}
