import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hain_tv/models/douban_movie.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/screens/mobile/category_screen.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/screens/mobile/history_screen.dart';
import 'package:hain_tv/services/connectivity_service.dart';
import 'package:hain_tv/services/douban_service.dart';
import 'package:hain_tv/services/play_record_refresh_notifier.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_horizontal_list.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

class MobileHomeScreen extends StatefulWidget {
  const MobileHomeScreen({super.key});

  @override
  State<MobileHomeScreen> createState() => _MobileHomeScreenState();
}

class _MobileHomeScreenState extends State<MobileHomeScreen>
    with AutomaticKeepAliveClientMixin<MobileHomeScreen> {
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  List<DoubanMovie> _hotMovies = [];
  List<DoubanMovie> _hotTvShows = [];
  List<DoubanMovie> _hotShows = [];
  List<DoubanMovie> _hotAnimes = [];
  List<PlayRecord> _continueWatching = [];
  List<PlayRecord> _allContinueWatching = [];

  @override
  void initState() {
    super.initState();
    _loadData();
    PlayRecordRefreshNotifier.instance.addListener(_onPlayRecordRefresh);
    ConnectivityService.instance.startMonitoring();
  }

  @override
  void dispose() {
    PlayRecordRefreshNotifier.instance.removeListener(_onPlayRecordRefresh);
    ConnectivityService.instance.stopMonitoring();
    super.dispose();
  }

  void _onPlayRecordRefresh() {
    if (mounted) _loadContinueWatching(localOnly: true);
  }

  void _viewMoreCategory(String kind, String title) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileCategoryScreen(kind: kind, title: title),
      ),
    );
  }

  void _viewHistory() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileHistoryScreen(
          initialRecords: _allContinueWatching,
        ),
      ),
    );
  }

  Future<void> _loadData() async {
    const pageLimit = 18;
    try {
      // 播放记录先读本地立即显示，避免远程请求阻塞首页渲染
      await _loadContinueWatching(localOnly: true);
      // 后台同步远程记录与豆瓣海报
      unawaited(_loadContinueWatching(localOnly: false));

      final results = await Future.wait([
        DoubanService.getHotMovies(pageLimit: pageLimit),
        DoubanService.getHotTvShows(pageLimit: pageLimit),
        DoubanService.getHotShows(pageLimit: pageLimit),
        DoubanService.getHotAnimes(pageLimit: pageLimit),
      ]);

      if (mounted) {
        setState(() {
          _hotMovies = results[0].success ? results[0].data ?? [] : [];
          _hotTvShows = results[1].success ? results[1].data ?? [] : [];
          _hotShows = results[2].success ? results[2].data ?? [] : [];
          _hotAnimes = results[3].success ? results[3].data ?? [] : [];
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败: $e';
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadContinueWatching({bool localOnly = false}) async {
    try {
      final records = localOnly
          ? await PlayRecordService.getAllLocal()
          : await PlayRecordService.getAll();
      if (mounted) {
        setState(() {
          _allContinueWatching = records;
          _continueWatching = records.take(12).toList();
        });
      }
    } catch (e) {
      // 获取失败忽略
    }
  }

  Future<void> _openHistory(PlayRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromPlayRecord(record),
      ),
    );
    if (mounted) await _loadContinueWatching();
  }

  Future<void> _openDetail(BuildContext context, DoubanMovie movie) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromDoubanMovie(movie),
      ),
    );
    if (mounted) await _loadContinueWatching();
  }

  List<PosterItem> _toPosterItems(List<DoubanMovie> movies, BuildContext context) {
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
        subtitle: record.sourceName.isNotEmpty ? record.sourceName : record.source,
        onTap: () => _openHistory(record),
      );
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: SafeArea(
        child: _buildBody(context),
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
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _error!,
              style: const TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _loadData,
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                const Icon(
                  Icons.movie,
                  color: AppColors.primary,
                  size: 28,
                ),
                const SizedBox(width: AppSpacing.sm),
                const Text(
                  '海因影视',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                ValueListenableBuilder<bool>(
                  valueListenable: ConnectivityService.instance.isServerConnected,
                  builder: (context, connected, child) {
                    return Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: connected ? AppColors.success : AppColors.error,
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: Text(
                        connected ? '已连接服务器' : '服务器未连接',
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        if (_continueWatching.isNotEmpty)
          SliverToBoxAdapter(
            child: MobileHorizontalList(
              title: '继续播放',
              items: _toContinueItems(_continueWatching),
              onViewMore: _viewHistory,
            ),
          ),
        if (_continueWatching.isNotEmpty)
          const SliverToBoxAdapter(
            child: SizedBox(height: AppSpacing.xl),
          ),
        SliverToBoxAdapter(
          child: MobileHorizontalList(
            title: '热门电影',
            items: _toPosterItems(_hotMovies, context),
            onViewMore: () => _viewMoreCategory('movie', '电影'),
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppSpacing.xl),
        ),
        SliverToBoxAdapter(
          child: MobileHorizontalList(
            title: '热门电视剧',
            items: _toPosterItems(_hotTvShows, context),
            onViewMore: () => _viewMoreCategory('tv', '电视剧'),
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppSpacing.xl),
        ),
        SliverToBoxAdapter(
          child: MobileHorizontalList(
            title: '热门综艺',
            items: _toPosterItems(_hotShows, context),
            onViewMore: () => _viewMoreCategory('show', '综艺'),
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppSpacing.xl),
        ),
        SliverToBoxAdapter(
          child: MobileHorizontalList(
            title: '热门动漫',
            items: _toPosterItems(_hotAnimes, context),
            onViewMore: () => _viewMoreCategory('anime', '动漫'),
          ),
        ),
        const SliverToBoxAdapter(
          child: SizedBox(height: AppSpacing.xxl),
        ),
      ],
    );
  }
}
