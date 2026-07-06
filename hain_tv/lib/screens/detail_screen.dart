import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../focus/focusable.dart';
import '../models/douban_movie.dart';
import '../models/favorite.dart';
import '../models/search_result.dart';
import '../models/source_option.dart';
import '../models/video_detail.dart';
import '../player/video_player_backend.dart';
import '../services/douban_service.dart';
import '../services/hain_tv_cache_manager.dart';
import '../services/lunatv_service.dart';
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
  final int initialEpisodeIndex;
  final int initialPlayTime;
  final bool searchOnLoad;

  const DetailScreen({
    super.key,
    required this.sources,
    this.initialSourceIndex = 0,
    required this.title,
    this.poster,
    this.year = '',
    this.doubanId,
    this.initialEpisodeIndex = 0,
    this.initialPlayTime = 0,
    this.searchOnLoad = false,
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

  VideoPlayerBackend? _previewBackend;
  final List<StreamSubscription> _previewSubscriptions = [];

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
    _loadFavoriteStatus();
    _loadPlayerBackend();
    _loadData();
  }

  @override
  void dispose() {
    _disposePreviewPlayer();
    super.dispose();
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
        _detailLoading = true;
        _doubanLoading = true;
        _error = null;
      });
    }

    // 如果没有源且需要搜索（searchOnLoad为true或sources为空但title不为空）
    if (_sources.isEmpty && widget.title.isNotEmpty) {
      setState(() => _searchingSources = true);
      // 使用快速搜索，不走豆瓣 enrich，避免详情页等待过久
      var response = await SearchService.searchSourcesFast(keyword: widget.title);

      // 若原始标题无结果，尝试用简化标题（去掉冒号、破折号后的前半部分）重试
      if ((!response.success || response.data == null || response.data!.isEmpty) &&
          (widget.title.contains(':') || widget.title.contains('：') || widget.title.contains('-'))) {
        final simplified = widget.title
            .split(RegExp(r'[:：\-]'))
            .first
            .trim();
        if (simplified.isNotEmpty && simplified != widget.title) {
          response = await SearchService.searchSourcesFast(keyword: simplified);
        }
      }

      if (!mounted) return;
      setState(() => _searchingSources = false);

      if (response.success && response.data != null && response.data!.isNotEmpty) {
        final exactYear = widget.year.isNotEmpty
            ? response.data!.where((s) => s.year == widget.year).toList()
            : <SourceOption>[];
        final sources = exactYear.isNotEmpty ? exactYear : response.data!;

        setState(() {
          _sources.addAll(sources);
          _selectedSourceIndex = 0;
        });
      } else if (!widget.searchOnLoad) {
        // 如果不是searchOnLoad模式，搜索失败显示错误
        setState(() {
          _detailLoading = false;
          _doubanLoading = false;
          _error = '未找到 "${widget.title}" 的播放源';
        });
        return;
      }
      // searchOnLoad模式下，搜索失败继续加载豆瓣详情
    }

    final futures = <Future<void>>[];

    if (_currentSource.source.isNotEmpty && _currentSource.id.isNotEmpty) {
      futures.add(_loadVideoDetail());
    } else {
      if (mounted) setState(() => _detailLoading = false);
    }

    // 如果有豆瓣ID或需要搜索，加载豆瓣详情
    if (widget.doubanId != null || widget.searchOnLoad) {
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
    await LunaTVService.toggleFavorite(key: key, favorite: favorite);
    await _loadFavoriteStatus();
  }

  void _playEpisode(int index, {int initialPlayTime = 0}) {
    final detail = _videoDetail;
    if (detail == null || detail.episodes.isEmpty) return;
    if (index < 0 || index >= detail.episodes.length) return;

    // 自动优选速度最快的源
    var bestIndex = _selectedSourceIndex;
    if (_sources.isNotEmpty) {
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
        Row(
          children: [
            FocusableWidget(
              autofocus: true,
              onTap: () => _playEpisode(_selectedEpisodeIndex),
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
            const SizedBox(width: AppSpacing.md),
            FocusableWidget(
              onTap: _toggleFavorite,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: _isFavorite
                      ? AppColors.primaryTint
                      : AppColors.bgElevated,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: _isFavorite
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      _isFavorite ? '已收藏' : '收藏',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                        color: _isFavorite
                            ? AppColors.primary
                            : AppColors.textPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
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

  Widget _buildSearchingOverlay() {
    if (!_searchingSources) return const SizedBox.shrink();
    return Container(
      color: AppColors.bgSurface,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(
              strokeWidth: 3,
              color: AppColors.primary,
            ),
            SizedBox(height: AppSpacing.lg),
            Text(
              '正在搜索播放源...',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 18,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final hasFatalError = _error != null &&
        _videoDetail == null &&
        _doubanDetails == null &&
        !_detailLoading &&
        !_doubanLoading &&
        !_searchingSources;

    Widget child;
    if (hasFatalError) {
      child = Scaffold(
        body: Center(
          child: Text(
            _error!,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
        ),
      );
    } else {
      child = Scaffold(
        body: Stack(
          fit: StackFit.expand,
          children: [
            SingleChildScrollView(
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
            _buildSearchingOverlay(),
          ],
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
