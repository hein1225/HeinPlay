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
import '../widgets/tv_grid.dart';
import 'player_screen.dart';

class DetailScreen extends StatefulWidget {
  final List<SourceOption> sources;
  final int initialSourceIndex;
  final String title;
  final String? poster;
  final String year;
  final int? doubanId;
  final int? bangumiId;
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
  int _selectedSourceIndex = 0;
  bool _isFavorite = false;
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
    _sources = List.from(widget.sources);
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

  /// 若未从入口传入播放记录，则按标题查询是否有记录。
  Future<void> _loadPlayRecord() async {
    if (_playRecord != null) return;
    try {
      final record = await PlayRecordService.getByTitle(
        widget.title,
        year: widget.year,
      );
      if (record != null && mounted) {
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

  /// 后台搜索播放源，搜索完成后自动加载第一个源的视频详情。
  Future<void> _searchSourcesInBackground() async {
    if (!mounted) return;
    setState(() => _searchingSources = true);

    // 使用快速搜索（含变体），不走豆瓣 enrich，避免详情页等待过久
    var response = await SearchService.searchSourcesFastWithVariants(
      keyword: widget.title,
    );

    // 若原始标题无结果，尝试用简化标题重试
    if ((!response.success || response.data == null || response.data!.isEmpty) &&
        (widget.title.contains(':') ||
            widget.title.contains('：') ||
            widget.title.contains('-'))) {
      final simplified = widget.title.split(RegExp(r'[:：\-]')).first.trim();
      if (simplified.isNotEmpty && simplified != widget.title) {
        response = await SearchService.searchSourcesFastWithVariants(
          keyword: simplified,
        );
      }
    }

    if (!mounted) return;

    if (response.success && response.data != null && response.data!.isNotEmpty) {
      final exactYear = widget.year.isNotEmpty
          ? response.data!.where((s) => s.year == widget.year).toList()
          : <SourceOption>[];
      final searchedSources = exactYear.isNotEmpty ? exactYear : response.data!;

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
      for (final s in searchedSources) {
        final key = '${s.source}+${s.id}';
        if (!seen.contains(key)) {
          seen.add(key);
          mergedSources.add(s);
        }
      }

      // 3. 加入其余已有源
      for (final s in _sources) {
        final key = '${s.source}+${s.id}';
        if (!seen.contains(key)) {
          seen.add(key);
          mergedSources.add(s);
        }
      }

      setState(() {
        _sources = mergedSources;
        _selectedSourceIndex = 0;
        _searchingSources = false;
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
      if (_videoDetail == null && _currentSource.source.isNotEmpty) {
        await _loadVideoDetail();
      }
    } else {
      setState(() => _searchingSources = false);
    }
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
    // Bangumi 每日放送条目：使用 Bangumi API 获取详情
    if (widget.bangumiId != null) {
      final response = await BangumiService.fetchSubject(widget.bangumiId!);
      if (!mounted) return;
      setState(() {
        _doubanLoading = false;
        if (response.success && response.data != null) {
          _doubanDetails = response.data;
        }
      });
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

    Navigator.of(context).push(
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

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      cacheManager: HainTvCacheManager(),
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
          height: 44,
          child: _sources.isEmpty
              ? const Text(
                  '暂无可用播放源',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    color: AppColors.textSecondary,
                  ),
                )
              : SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: List.generate(_sources.length, (index) {
                      final source = _sources[index];
                      final selected = index == _selectedSourceIndex;
                      final speedText = _formatSpeed(source.speed);
                      return Padding(
                        padding: EdgeInsets.only(
                          right: index < _sources.length - 1
                              ? AppSpacing.md
                              : 0,
                        ),
                        child: FocusableWidget(
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
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.md,
                            ),
                            decoration: BoxDecoration(
                              color: selected
                                  ? AppColors.primaryTint
                                  : AppColors.bgSurface,
                              borderRadius: BorderRadius.circular(AppRadius.md),
                              border: Border.all(
                                color: selected
                                    ? AppColors.primary
                                    : AppColors.border,
                              ),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  source.sourceName.isNotEmpty
                                      ? source.sourceName
                                      : source.source,
                                  style: TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: selected
                                        ? AppColors.primary
                                        : AppColors.textPrimary,
                                  ),
                                ),
                                if (speedText.isNotEmpty) ...[
                                  const SizedBox(width: AppSpacing.xs),
                                  Text(
                                    speedText,
                                    style: TextStyle(
                                      fontFamily: 'NotoSansSC',
                                      fontSize: 12,
                                      color: _speedColor(source.speed),
                                    ),
                                  ),
                                ],
                              ],
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
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              height: 1.5,
              color: AppColors.textSecondary,
            ),
          ),
        const SizedBox(height: AppSpacing.lg),
        _buildActionButtons(),
      ],
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

  Widget _buildMetaChip(String text, {bool isPrimary = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: isPrimary ? AppColors.primaryTint : AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 12,
          fontWeight: isPrimary ? FontWeight.w600 : FontWeight.w400,
          color: isPrimary ? AppColors.primary : AppColors.textSecondary,
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

    final items = List.generate(detail.episodes.length, (index) {
      return PosterItem(
        id: '$index',
        title: titles[index],
        onTap: () => _playEpisode(index),
      );
    });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(
            left: AppSpacing.lg,
            bottom: AppSpacing.md,
          ),
          child: Text(
            '选集',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
        ),
        SizedBox(
          height: 120,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            child: Row(
              children: List.generate(items.length, (index) {
                final item = items[index];
                return Padding(
                  padding: EdgeInsets.only(
                    right: index < items.length - 1 ? AppSpacing.md : 0,
                  ),
                  child: SizedBox(
                    width: 160,
                    child: FocusableWidget(
                      autofocus: index == 0,
                      onTap: item.onTap,
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
                        decoration: BoxDecoration(
                          color: _selectedEpisodeIndex == index
                              ? AppColors.primaryTint
                              : AppColors.bgSurface,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: Text(
                          item.title,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: _selectedEpisodeIndex == index
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
                height: 420,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(width: AppSpacing.lg),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(AppRadius.lg),
                      child: SizedBox(
                        width: 280,
                        height: 420,
                        child: _buildPoster(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          vertical: AppSpacing.lg,
                        ),
                        child: _buildInfoSection(),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              _buildEpisodes(),
              const SizedBox(height: AppSpacing.xl),
              const SizedBox(height: AppSpacing.xl),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
                child: _buildSourceSelector(),
              ),
              const SizedBox(height: AppSpacing.xxl),
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
