import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../models/douban_movie.dart';
import '../models/play_record.dart';
import '../services/douban_service.dart';
import '../services/play_record_service.dart';
import '../theme.dart';
import '../widgets/tv_grid.dart';
import 'detail_screen.dart';
import 'source_loading_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _continueFirstFocusNode = FocusNode(debugLabel: 'homeContinueFirst');
    _hotMoviesFirstFocusNode = FocusNode(debugLabel: 'homeHotMoviesFirst');
    _hotTvFirstFocusNode = FocusNode(debugLabel: 'homeHotTvFirst');
    _hotShowsFirstFocusNode = FocusNode(debugLabel: 'homeHotShowsFirst');
    _hotAnimesFirstFocusNode = FocusNode(debugLabel: 'homeHotAnimesFirst');
    _loadData();
  }

  @override
  void dispose() {
    _continueFirstFocusNode.dispose();
    _hotMoviesFirstFocusNode.dispose();
    _hotTvFirstFocusNode.dispose();
    _hotShowsFirstFocusNode.dispose();
    _hotAnimesFirstFocusNode.dispose();
    super.dispose();
  }

  void focusFirstContent() {
    if (_continueWatching.isNotEmpty) {
      _continueFirstFocusNode.requestFocus();
    } else {
      _hotMoviesFirstFocusNode.requestFocus();
    }
  }

  Future<void> _loadData() async {
    const pageLimit = 18;
    try {
      final results = await Future.wait([
        DoubanService.getHotMovies(pageLimit: pageLimit),
        DoubanService.getHotTvShows(pageLimit: pageLimit),
        DoubanService.getHotShows(pageLimit: pageLimit),
        DoubanService.getHotAnimes(pageLimit: pageLimit),
      ]);
      await _loadContinueWatching();

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

  Future<void> _loadContinueWatching() async {
    try {
      final records = await PlayRecordService.getAll();
      if (mounted && records.isNotEmpty) {
        setState(() {
          _continueWatching = records.take(12).toList();
        });
      }
    } catch (e) {
      // 获取失败忽略
    }
  }

  Future<void> _openHistory(PlayRecord record) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SourceLoadingScreen(record: record),
      ),
    );
  }

  Future<void> _openDetail(BuildContext context, DoubanMovie movie) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen.fromDoubanMovie(movie),
      ),
    );
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

    return VisibilityDetector(
      key: const Key('home_screen'),
      onVisibilityChanged: (info) {
        // IndexedStack 中切回首页时刷新继续播放记录
        if (info.visibleFraction > 0.5) {
          _loadContinueWatching();
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
            if (_continueWatching.isNotEmpty) const SizedBox(height: AppSpacing.xl),
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
