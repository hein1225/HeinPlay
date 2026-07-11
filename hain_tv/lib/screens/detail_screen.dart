import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../focus/focusable.dart';
import '../models/bangumi_calendar_item.dart';
import '../models/douban_movie.dart';
import '../models/favorite.dart';
import '../models/play_record.dart' as models;
import '../models/search_result.dart';
import '../models/source_option.dart';
import '../models/video_detail.dart';
import '../player/video_player_backend.dart';
import '../services/bangumi_service.dart';
import '../services/douban_service.dart';
import '../services/hain_tv_cache_manager.dart';
import '../services/local_storage_service.dart' as local;
import '../services/lunatv_service.dart';
import '../services/play_record_service.dart';
import '../services/profile_refresh_notifier.dart';
import '../services/search_service.dart';
import '../services/user_data_service.dart';
import '../theme.dart';
import 'player_screen.dart';

class DetailScreen extends StatefulWidget {
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

  const DetailScreen({
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

  factory DetailScreen.fromSearchResult(
    SearchResult result, {
    int initialEpisodeIndex = 0,
    int initialPlayTime = 0,
  }) {
    return DetailScreen(
      sources: [SourceOption.fromSearchResult(result)],
      title: result.title,
      poster: result.poster.isNotEmpty ? result.poster : null,
      year: result.year,
      doubanId: result.doubanId,
      initialEpisodeIndex: initialEpisodeIndex,
      initialPlayTime: initialPlayTime,
    );
  }

  factory DetailScreen.fromSearchResults(
    List<SearchResult> results, {
    int initialSourceIndex = 0,
    int initialEpisodeIndex = 0,
    int initialPlayTime = 0,
  }) {
    final sources = SearchService.groupBySource(results);
    return DetailScreen(
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

  factory DetailScreen.fromDoubanMovie(DoubanMovie movie) {
    return DetailScreen(
      sources: const [],
      title: movie.title,
      poster: movie.poster.isNotEmpty ? movie.poster : null,
      year: movie.year,
      doubanId: int.tryParse(movie.id),
    );
  }

  factory DetailScreen.fromBangumiCalendarItem(BangumiCalendarItem item) {
    return DetailScreen(
      sources: const [],
      title: item.title,
      poster: item.poster,
      year: item.year ?? '',
      bangumiId: item.id,
      bangumiRate: item.rate,
      searchOnLoad: true,
    );
  }

  factory DetailScreen.fromPlayRecord(models.PlayRecord record) {
    return DetailScreen(
      sources: [
        SourceOption(
          source: record.source,
          sourceName:
              record.sourceName.isNotEmpty ? record.sourceName : record.source,
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
      doubanId: record.doubanId != null
          ? int.tryParse(record.doubanId!)
          : null,
      initialEpisodeIndex: record.index > 0 ? record.index - 1 : 0,
      initialPlayTime: record.playTime,
      playRecord: record,
      searchOnLoad: true,
    );
  }

  /// 通过标题和年份搜索并进入详情页
  factory DetailScreen.fromTitle({
    required String title,
    String year = '',
    int initialEpisodeIndex = 0,
    int initialPlayTime = 0,
  }) {
    return DetailScreen(
      sources: const [],
      title: title,
      year: year,
      initialEpisodeIndex: initialEpisodeIndex,
      initialPlayTime: initialPlayTime,
      searchOnLoad: true,
    );
  }

  @override
  State<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends State<DetailScreen> {
  bool _detailLoading = true;
  bool _doubanLoading = true;
  bool _speedTesting = false;
  bool _searchingSources = false;
  String? _error;
  VideoDetail? _videoDetail;
  DoubanMovieDetails? _doubanDetails;
  int _selectedEpisodeIndex = 0;
  bool _episodeSortAscending = true;
  int _selectedSourceIndex = 0;
  bool _isFavorite = false;
  bool _fuzzySearchEnabled = false;
  PlayerBackendType _playerBackend = PlayerBackendType.mediaKit;
  late List<SourceOption> _sources;
  models.PlayRecord? _playRecord;

  VideoPlayerBackend? _previewBackend;
  final List<StreamSubscription> _previewSubscriptions = [];
  final ScrollController _scrollController = ScrollController();

  SourceOption get _currentSource {
    if (_sources.isEmpty) {
      return const SourceOption(
        source: '',
        sourceName: '',
        id: '',
        title: '',
      );
    }
    return _sources[_selectedSourceIndex];
  }

  @override
  void initState() {
    super.initState();
    // 海报墙进入时只保留与影片标题精确匹配的源，避免传入的模糊结果污染列表
    _sources = widget.sources
        .where(
          (s) => SearchService.isExactTitleMatch(
            s.title,
            widget.title,
            variants: SearchService.generateSearchVariants(widget.title),
          ),
        )
        .toList();
    _selectedEpisodeIndex = widget.initialEpisodeIndex;
    _selectedSourceIndex = widget.initialSourceIndex.clamp(
      0,
      _sources.isEmpty ? 0 : _sources.length - 1,
    );
    _playRecord = widget.playRecord;
    _loadFavoriteStatus();
    _loadPlayerBackend();
    _loadPlayRecord();
    _loadData();
  }

  /// 按标题查询是否有播放记录。
  /// [force] 为 true 时，即使已有记录也会重新查询，用于从播放页返回后刷新。
  Future<void> _loadPlayRecord({bool force = false}) async {
    if (_playRecord != null && !force) return;
    try {
      final record = await PlayRecordService.getByTitle(
        widget.title,
        year: widget.year,
      );
      if (mounted) {
        setState(() => _playRecord = record);
      }
    } catch (e) {
      debugPrint('查询播放记录失败: $e');
    }
  }

  @override
  void dispose() {
    _disposePreviewPlayer();
    _scrollController.dispose();
    super.dispose();
  }

  /// 当焦点回到顶部操作区时，滚动回页面顶部以显示完整影片详情。
  void _ensureInfoVisible() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOut,
      );
    }
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

  Future<void> _loadFavoriteStatus() async {
    final source = _currentSource.source;
    final id = _currentSource.id;
    if (source.isEmpty || id.isEmpty) return;
    final key = '$source+$id';
    final isFavorite = await LunaTVService.isFavorite(key);
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

    // 如果没有源或明确要求搜索（如从播放记录进入），在后台异步搜索更多源，不阻塞页面内容展示
    if (widget.title.isNotEmpty &&
        (_sources.isEmpty || widget.searchOnLoad)) {
      unawaited(_searchSourcesInBackground());
    }

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
    debugPrint(
      '[SourceSearch] 开始搜索: title=${widget.title}, year=${widget.year}, '
      'bangumiId=${widget.bangumiId}, exactMatch=$initialExactMatch, fuzzy=$fuzzy',
    );
    final onProgress = (List<SourceOption> sources) {
      _mergeAndUpdateSources(sources, fuzzy: fuzzy, isFinal: false);
    };
    var response = await SearchService.searchSourcesFastWithVariants(
      keyword: widget.title,
      exactMatch: initialExactMatch,
      fuzzy: fuzzy,
      onProgress: onProgress,
    );
    debugPrint(
      '[SourceSearch] 首轮结果: success=${response.success}, '
      'count=${response.data?.length ?? 0}, message=${response.message}',
    );

    // 若原始标题无结果，尝试用简化标题重试
    if ((!response.success || response.data == null || response.data!.isEmpty) &&
        !fuzzy &&
        (widget.title.contains(':') ||
            widget.title.contains('：') ||
            widget.title.contains('-'))) {
      final simplified = widget.title.split(RegExp(r'[:：\-]')).first.trim();
      if (simplified.isNotEmpty && simplified != widget.title) {
        debugPrint('[SourceSearch] 尝试简化标题: $simplified');
        response = await SearchService.searchSourcesFastWithVariants(
          keyword: simplified,
          exactMatch: true,
          fuzzy: false,
          onProgress: onProgress,
        );
        debugPrint(
          '[SourceSearch] 简化标题结果: count=${response.data?.length ?? 0}',
        );
      }
    }

    // Bangumi 每日放送条目：精确匹配无结果时自动降级到严格模糊匹配
    //（仅保留包含/高相似结果），避免 LunaTV 式宽泛匹配引入大量不相关源。
    // 若仍无结果，用户可手动点击“尝试模糊搜索”使用更宽松的阈值。
    if ((!response.success || response.data == null || response.data!.isEmpty) &&
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
      if (isFinal) setState(() => _searchingSources = false);
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

    setState(() {
      _sources = mergedSources;
      _selectedSourceIndex = 0;
      if (isFinal) _searchingSources = false;
    });

    // 若存在原始源，默认选中它，保证“继续播放”使用原来的源
    if (originalSource != null) {
      final originalIndex = _sources.indexWhere(
        (s) => '${s.source}+${s.id}' == originalSource,
      );
      if (originalIndex >= 0) {
        setState(() => _selectedSourceIndex = originalIndex);
      }
    }

    // 视频详情尚未加载时，自动加载当前选中源
    if (isFinal &&
        _videoDetail == null &&
        _currentSource.source.isNotEmpty) {
      unawaited(_loadVideoDetail());
    }
  }

  /// 手动触发模糊搜索，用于精确匹配无结果时。
  Future<void> _runFuzzySearch() async {
    await _searchSourcesInBackground(fuzzy: true);
  }

  Future<void> _loadVideoDetail() async {
    final response = await LunaTVService.getDetail(
      source: _currentSource.source,
      id: _currentSource.id,
      title: _currentSource.title,
    );

    if (!mounted) return;

    if (response.success && response.data != null) {
        setState(() {
          _videoDetail = response.data;
          _detailLoading = false;
        });
        if (_sources.isNotEmpty && !_speedTesting) {
          _runSpeedTest();
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
      _videoDetail = null;
      _error = null;
      _selectedEpisodeIndex = 0;
      _detailLoading = true;
    });
    await _loadFavoriteStatus();
    await _loadPlayerBackend();
    await _loadVideoDetail();
  }

  Future<void> _runSpeedTest() async {
    if (_sources.length < 2 || _speedTesting) return;
    setState(() => _speedTesting = true);

    final tested = await SearchService.speedTestSources(
      _sources,
      onProgress: (index, updated) {
        if (mounted) {
          setState(() {
            _sources[index] = updated;
          });
        }
      },
    );

    if (!mounted) return;

    setState(() {
      for (var i = 0; i < tested.length; i++) {
        _sources[i] = tested[i];
      }
      _speedTesting = false;
    });

    final bestIndex = _findBestSourceIndex();
    if (bestIndex != _selectedSourceIndex && bestIndex >= 0) {
      await _onSourceChanged(bestIndex);
    }
  }

  int _findBestSourceIndex() {
    for (var i = 0; i < _sources.length; i++) {
      if ((_sources[i].speed ?? 0) > 0) return i;
    }
    return _selectedSourceIndex;
  }

  void _toggleFavorite() async {
    final source = _currentSource.source;
    final id = _currentSource.id;
    if (source.isEmpty || id.isEmpty) return;
    final key = '$source+$id';
    final favorite = Favorite(
      source: source,
      id: id,
      title: widget.title,
      cover: widget.poster ?? _doubanDetails?.poster ?? '',
      sourceName: _currentSource.sourceName,
    );

    try {
      final added = await LunaTVService.toggleFavorite(key: key, favorite: favorite);
      final record = local.FavoriteRecord(
        source: source,
        id: id,
        title: widget.title,
        posterUrl: widget.poster ?? _doubanDetails?.poster,
        year: widget.year,
        createdAt: DateTime.now(),
      );
      if (added) {
        await local.LocalStorageService.addFavorite(record);
      } else {
        await local.LocalStorageService.removeFavorite(source, id);
      }
      ProfileRefreshNotifier.instance.notify();
    } catch (e) {
      debugPrint('切换收藏失败: $e');
    }

    await _loadFavoriteStatus();
  }

  /// 查找播放记录原始源在当前源列表中的索引。
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

    // 优先使用指定的源（如播放记录的原始源），否则按速度择优
    var bestIndex = preferredSourceIndex ?? _selectedSourceIndex;
    if (preferredSourceIndex == null && _sources.isNotEmpty) {
      var bestSpeed = _sources[bestIndex].speed ?? 0;
      for (var i = 0; i < _sources.length; i++) {
        final speed = _sources[i].speed ?? 0;
        if (speed > bestSpeed) {
          bestSpeed = speed;
          bestIndex = i;
        }
      }
      if (bestIndex != _selectedSourceIndex) {
        setState(() => _selectedSourceIndex = bestIndex);
      }
    }

    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          videoDetail: detail,
          episodeIndex: index,
          sources: _sources,
          initialSourceIndex: bestIndex,
          playerBackend: _playerBackend,
          initialPositionMs: initialPlayTime * 1000,
        ),
      ),
    );

    // 从播放页返回后立即刷新播放记录，无需回到首页
    if (mounted) {
      await _loadPlayRecord(force: true);
    }
    // 若播放记录更新导致当前集数/进度变化，刷新视频详情以同步状态
    if (mounted &&
        _playRecord != null &&
        _playRecord!.index > 0 &&
        _playRecord!.index <= detail.episodes.length) {
      setState(() => _selectedEpisodeIndex = _playRecord!.index - 1);
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
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
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
              FocusableWidget(
                onTap: _runSpeedTest,
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
                      : FocusableWidget(
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

    return FocusableWidget(
      autofocus: index == 0,
      onTap: () => _onSourceChanged(index),
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
                  placeholder: (_, __) => Container(
                    color: AppColors.bgSurface,
                  ),
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
            fontSize: 28,
            fontWeight: FontWeight.w700,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Row(
          children: [
            if (widget.year.isNotEmpty) _buildMetaChip(widget.year),
            if (rating != null && rating.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              _buildMetaChip('豆瓣 $rating', isPrimary: true),
            ],
            if (widget.bangumiRate != null && widget.bangumiRate!.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              _buildMetaChip('Bangumi ${widget.bangumiRate}', isBangumi: true),
            ],
            if (genres.isNotEmpty) ...[
              const SizedBox(width: AppSpacing.sm),
              _buildMetaChip(genres.take(3).join(' / ')),
            ],
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
          Text(
            summary,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              height: 1.5,
              color: AppColors.textSecondary,
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
            if (languages.isNotEmpty)
              _buildMetaChip(languages.first),
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
      child: RichText(
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 14,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoText(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.xs),
      child: RichText(
        text: TextSpan(
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 14,
            height: 1.5,
            color: AppColors.textSecondary,
          ),
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            TextSpan(text: value),
          ],
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    final record = _playRecord;
    final sourceName = record != null && record.sourceName.isNotEmpty
        ? record.sourceName
        : (record != null ? record.source : '');
    final hasRecord = record != null;

    return Wrap(
      spacing: AppSpacing.md,
      runSpacing: AppSpacing.md,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (hasRecord)
          FocusableWidget(
            autofocus: true,
            onTap: () => _playEpisode(
              record.index > 0 ? record.index - 1 : 0,
              initialPlayTime: record.playTime,
              preferredSourceIndex: _findSourceIndex(record.source, record.id),
            ),
            onFocusChange: (focused) {
              if (focused) _ensureInfoVisible();
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
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.play_arrow, color: Colors.white),
                  const SizedBox(width: AppSpacing.xs),
                  Column(
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
                ],
              ),
            ),
          ),
        if (hasRecord)
          FocusableWidget(
            onTap: () => _playEpisode(0),
            onFocusChange: (focused) {
              if (focused) _ensureInfoVisible();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.bgElevated,
                borderRadius: BorderRadius.circular(AppRadius.md),
                border: Border.all(color: AppColors.border),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.replay, color: AppColors.textPrimary),
                  SizedBox(width: AppSpacing.xs),
                  Text(
                    '从头播放',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        if (!hasRecord)
          FocusableWidget(
            autofocus: true,
            onTap: () => _playEpisode(_selectedEpisodeIndex),
            onFocusChange: (focused) {
              if (focused) _ensureInfoVisible();
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
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.play_arrow, color: Colors.white),
                  SizedBox(width: AppSpacing.xs),
                  Text(
                    '播放',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ),
        FocusableWidget(
          onTap: _toggleFavorite,
          onFocusChange: (focused) {
            if (focused) _ensureInfoVisible();
          },
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.sm,
            ),
            decoration: BoxDecoration(
              color: _isFavorite ? AppColors.primaryTint : AppColors.bgElevated,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: _isFavorite ? AppColors.primary : AppColors.textPrimary,
                ),
                const SizedBox(width: AppSpacing.xs),
                Text(
                  _isFavorite ? '已收藏' : '收藏',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: _isFavorite ? AppColors.primary : AppColors.textPrimary,
                  ),
                ),
              ],
            ),
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
          fontWeight: isPrimary || isBangumi ? FontWeight.w600 : FontWeight.w400,
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
        : List<int>.generate(detail.episodes.length, (i) => i)
            .reversed
            .toList();

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
              FocusableWidget(
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
              FocusableWidget(
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
                  padding: EdgeInsets.only(
                    right:
                        displayIndex < displayIndices.length - 1 ? AppSpacing.sm : 0,
                  ),
                  child: SizedBox(
                    width: 100,
                    child: FocusableWidget(
                      autofocus: displayIndex == 0,
                      onTap: () => _playEpisode(originalIndex),
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
    final hasFatalError = _error != null &&
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
              FocusableWidget(
                autofocus: true,
                onTap: _loadData,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.lg,
                    vertical: AppSpacing.md,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(AppRadius.md),
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
              ),
            ],
          ),
        ),
      );
    } else {
      child = Scaffold(
        body: SingleChildScrollView(
          controller: _scrollController,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: 320,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(width: AppSpacing.lg),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      child: SizedBox(
                        width: 210,
                        height: 320,
                        child: _buildPoster(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.md,
                        ),
                        child: _buildInfoSection(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.lg),
              _buildEpisodes(),
              const SizedBox(height: AppSpacing.lg),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: _buildSourceSelector(),
              ),
              const SizedBox(height: AppSpacing.xl),
            ],
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
