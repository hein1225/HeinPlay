import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:hain_tv/models/douban_movie.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/services/connectivity_service.dart';
import 'package:hain_tv/services/douban_service.dart';
import 'package:hain_tv/services/favorite_service.dart';
import 'package:hain_tv/services/home_data_preload.dart';
import 'package:hain_tv/services/play_record_refresh_notifier.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';
import 'detail_screen.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => HomeScreenState();
}

class HomeScreenState extends State<HomeScreen> {
  bool _loading = true;
  String? _error;

  List<DoubanMovie> _hotMovies = [];
  List<DoubanMovie> _hotTvShows = [];
  List<DoubanMovie> _hotShows = [];
  List<DoubanMovie> _hotAnimes = [];
  List<PlayRecord> _continueWatching = [];

  late final FocusNode _continueFirstFocusNode;
  late final FocusNode _hotMoviesFirstFocusNode;
  late final FocusNode _hotTvFirstFocusNode;
  late final FocusNode _hotShowsFirstFocusNode;
  late final FocusNode _hotAnimesFirstFocusNode;

  /// 导航栏按下进入首页内容时若首页仍在加载（内容节点尚未挂载），先挂起，
  /// 待首页加载完成后再把焦点移入首个内容项。
  bool _pendingFocusFirstContent = false;

  @override
  void initState() {
    super.initState();
    _continueFirstFocusNode = FocusNode(debugLabel: 'homeContinueFirst');
    _hotMoviesFirstFocusNode = FocusNode(debugLabel: 'homeHotMoviesFirst');
    _hotTvFirstFocusNode = FocusNode(debugLabel: 'homeHotTvFirst');
    _hotShowsFirstFocusNode = FocusNode(debugLabel: 'homeHotShowsFirst');
    _hotAnimesFirstFocusNode = FocusNode(debugLabel: 'homeHotAnimesFirst');
    _consumePreloadedData();
    // SplashScreen 已成功预加载首页数据时（_consumePreloadedData 已消费并把
    // _loading 置 false），首页直接用该快照渲染，不再重复请求服务器 —— 既避免
    // 冷启动拉两遍热门，也避免弱网下再次同步/拉取造成卡顿。本地“继续播放/收藏”
    // 的实时增量由 PlayRecordRefreshNotifier 等通知机制刷新，不依赖重启。
    // 仅当预加载失败（首页无缓存数据）时才自行加载兜底。
    if (_loading) {
      _loadData();
    }
    PlayRecordRefreshNotifier.instance.addListener(_onPlayRecordRefresh);
  }

  /// 如果 SplashScreen 已预加载首页数据，直接填充状态并跳过初始加载圈。
  void _consumePreloadedData() {
    if (!HomeDataPreload.hasData) return;
    _hotMovies = HomeDataPreload.hotMovies!;
    _hotTvShows = HomeDataPreload.hotTvShows!;
    _hotShows = HomeDataPreload.hotShows!;
    _hotAnimes = HomeDataPreload.hotAnimes!;
    _continueWatching = HomeDataPreload.continueWatching!;
    _loading = false;
    HomeDataPreload.clear();
  }

  @override
  void dispose() {
    _continueFirstFocusNode.dispose();
    _hotMoviesFirstFocusNode.dispose();
    _hotTvFirstFocusNode.dispose();
    _hotShowsFirstFocusNode.dispose();
    _hotAnimesFirstFocusNode.dispose();
    PlayRecordRefreshNotifier.instance.removeListener(_onPlayRecordRefresh);
    super.dispose();
  }

  void _onPlayRecordRefresh() {
    if (mounted) _loadContinueWatching(localOnly: true);
  }

  void focusFirstContent() {
    if (_loading) {
      // 首页仍在加载、内容节点尚未挂载，挂起待加载完成后聚焦。
      _pendingFocusFirstContent = true;
      return;
    }
    _applyFirstContentFocus();
  }

  void _applyFirstContentFocus() {
    if (_continueWatching.isNotEmpty) {
      _continueFirstFocusNode.requestFocus();
    } else {
      _hotMoviesFirstFocusNode.requestFocus();
    }
  }

  /// 首页加载完成后，若此前有“进入内容”的待处理请求，则把焦点移入首个内容项。
  void _flushPendingFirstContentFocus() {
    if (!_pendingFocusFirstContent) return;
    _pendingFocusFirstContent = false;
    // 等本帧构建完成、内容节点挂载后再聚焦。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _applyFirstContentFocus();
    });
  }

  Future<void> _loadData() async {
    const pageLimit = 18;
    try {
      // 首次进入首页时强制从服务器全量刷新播放记录与收藏夹，并缓存到本地；
      // 后续进入直接读取本地缓存，播放后的增量更新通过通知机制刷新。
      final isFirstEntry = !(await UserDataService.isHomeFirstEntryCompleted());
      final syncFuture = isFirstEntry ? _syncAllUserData() : Future.value();

      final resultsFuture = Future.wait([
        DoubanService.getHotMovies(pageLimit: pageLimit),
        DoubanService.getHotTvShows(pageLimit: pageLimit),
        DoubanService.getHotShows(pageLimit: pageLimit),
        DoubanService.getHotAnimes(pageLimit: pageLimit),
      ]);

      final syncSucceeded = await syncFuture;
      if (isFirstEntry && syncSucceeded) {
        await UserDataService.markHomeFirstEntryCompleted();
      }

      await _loadContinueWatching(localOnly: true);
      final results = await resultsFuture;

      if (mounted) {
        setState(() {
          _hotMovies = results[0].success ? results[0].data ?? [] : [];
          _hotTvShows = results[1].success ? results[1].data ?? [] : [];
          _hotShows = results[2].success ? results[2].data ?? [] : [];
          _hotAnimes = results[3].success ? results[3].data ?? [] : [];
          _loading = false;
        });
        _flushPendingFirstContentFocus();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败: $e';
          _loading = false;
        });
        _flushPendingFirstContentFocus();
      }
    }
  }

  /// 首次进入首页时强制同步服务器播放记录与收藏夹到本地缓存。
  /// 返回是否两项均同步成功。
  Future<bool> _syncAllUserData() async {
    try {
      final results = await Future.wait([
        PlayRecordService.syncFromRemote(),
        FavoriteService.syncFromRemote(),
      ]);
      return results.every((r) => r);
    } catch (e) {
      debugPrint('HomeScreen: 首次全量同步失败: $e');
      return false;
    }
  }

  Future<void> _loadContinueWatching({bool localOnly = false, bool forceRefresh = false}) async {
    try {
      final records = localOnly
          ? await PlayRecordService.getAllLocal()
          : await PlayRecordService.getAll(forceRefresh: forceRefresh);
      if (mounted) {
        setState(() {
          _continueWatching = records.take(12).toList();
        });
      }
      // 远程同步成功后立即刷新服务器连接状态，避免首页显示未连接但实际已可用
      if (!localOnly) {
        unawaited(ConnectivityService.instance.checkNow());
      }
    } catch (e) {
      // 获取失败忽略
    }
  }

  Future<void> _openHistory(PlayRecord record) async {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen.fromPlayRecord(record)),
    );
  }

  Future<void> _openDetail(BuildContext context, DoubanMovie movie) async {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => DetailScreen.fromDoubanMovie(movie)),
    );
  }

  List<PosterItem> _toPosterItems(
    List<DoubanMovie> movies,
    BuildContext context,
  ) {
    return movies.map((movie) {
      return PosterItem(
        id: movie.id,
        title: movie.title,
        posterUrl: movie.poster,
        year: movie.year,
        rating: movie.rate,
        onTap: () => _openDetail(context, movie),
      );
    }).toList();
  }

  List<PosterItem> _toContinueItems(List<PlayRecord> records) {
    return records.map((record) {
      return PosterItem(
        id: record.title,
        title: record.title,
        posterUrl: record.cover.isNotEmpty ? record.cover : null,
        subtitle: record.sourceName.isNotEmpty
            ? record.sourceName
            : record.source,
        onTap: () => _openHistory(record),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: TechLoadingIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    return VisibilityDetector(
      key: const Key('home_screen'),
      onVisibilityChanged: (info) {
        // IndexedStack 中切回首页时读取本地缓存即可；
        // 播放后的增量更新已通过 PlayRecordRefreshNotifier 刷新。
        if (info.visibleFraction > 0.5) {
          _loadContinueWatching(localOnly: true);
        }
      },
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: AppSpacing.xl),
            if (_continueWatching.isNotEmpty)
              TvHorizontalPosterList(
                title: '继续播放',
                items: _toContinueItems(_continueWatching),
                firstItemFocusNode: _continueFirstFocusNode,
                onMoveDown: () => _hotMoviesFirstFocusNode.requestFocus(),
              ),
            if (_continueWatching.isNotEmpty)
              const SizedBox(height: AppSpacing.xl),
            TvHorizontalPosterList(
              title: '热门电影',
              items: _toPosterItems(_hotMovies, context),
              firstItemFocusNode: _hotMoviesFirstFocusNode,
              onMoveUp: _continueWatching.isNotEmpty
                  ? () => _continueFirstFocusNode.requestFocus()
                  : null,
              onMoveDown: () => _hotTvFirstFocusNode.requestFocus(),
            ),
            const SizedBox(height: AppSpacing.xl),
            TvHorizontalPosterList(
              title: '热门电视剧',
              items: _toPosterItems(_hotTvShows, context),
              firstItemFocusNode: _hotTvFirstFocusNode,
              onMoveUp: () => _hotMoviesFirstFocusNode.requestFocus(),
              onMoveDown: () => _hotShowsFirstFocusNode.requestFocus(),
            ),
            const SizedBox(height: AppSpacing.xl),
            TvHorizontalPosterList(
              title: '热门综艺',
              items: _toPosterItems(_hotShows, context),
              firstItemFocusNode: _hotShowsFirstFocusNode,
              onMoveUp: () => _hotTvFirstFocusNode.requestFocus(),
              onMoveDown: () => _hotAnimesFirstFocusNode.requestFocus(),
            ),
            const SizedBox(height: AppSpacing.xl),
            TvHorizontalPosterList(
              title: '热门动漫',
              items: _toPosterItems(_hotAnimes, context),
              firstItemFocusNode: _hotAnimesFirstFocusNode,
              onMoveUp: () => _hotShowsFirstFocusNode.requestFocus(),
            ),
            const SizedBox(height: AppSpacing.xxl),
          ],
        ),
      ),
    );
  }
}
