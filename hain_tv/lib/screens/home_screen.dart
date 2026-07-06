import 'package:flutter/material.dart';
import '../models/douban_movie.dart';
import '../models/play_record.dart';
import '../services/douban_service.dart';
import '../services/play_record_service.dart';
import '../theme.dart';
import '../widgets/tv_banner.dart';
import '../widgets/tv_grid.dart';
import 'detail_screen.dart';
import 'source_loading_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _loading = true;
  String? _error;

  List<DoubanMovie> _hotMovies = [];
  List<DoubanMovie> _hotTvShows = [];
  List<DoubanMovie> _hotShows = [];
  List<DoubanMovie> _hotAnimes = [];
  List<PlayRecord> _continueWatching = [];

  @override
  void initState() {
    super.initState();
    _loadData();
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
        onTap: () => _openHistory(record),
      );
    }).toList();
  }

  Widget _buildBanner() {
    final bannerMovie = _hotMovies.isNotEmpty ? _hotMovies.first : null;
    if (bannerMovie == null) return const SizedBox.shrink();

    return TvBanner(
      title: bannerMovie.title,
      overview: null,
      backdropUrl: bannerMovie.poster,
      onPlay: () => _openDetail(context, bannerMovie),
      onFavorite: () {
        // TODO: 加入收藏
      },
    );
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

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildBanner(),
          const SizedBox(height: AppSpacing.xl),
          if (_continueWatching.isNotEmpty)
            TvHorizontalPosterList(
              title: '继续播放',
              items: _toContinueItems(_continueWatching),
            ),
          if (_continueWatching.isNotEmpty) const SizedBox(height: AppSpacing.xl),
          TvHorizontalPosterList(
            title: '热门电影',
            items: _toPosterItems(_hotMovies, context),
          ),
          const SizedBox(height: AppSpacing.xl),
          TvHorizontalPosterList(
            title: '热门电视剧',
            items: _toPosterItems(_hotTvShows, context),
          ),
          const SizedBox(height: AppSpacing.xl),
          TvHorizontalPosterList(
            title: '热门综艺',
            items: _toPosterItems(_hotShows, context),
          ),
          const SizedBox(height: AppSpacing.xl),
          TvHorizontalPosterList(
            title: '热门动漫',
            items: _toPosterItems(_hotAnimes, context),
          ),
          const SizedBox(height: AppSpacing.xxl),
        ],
      ),
    );
  }
}
