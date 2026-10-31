import 'dart:async';

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';
import 'package:hain_tv/models/douban_movie.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/screens/mobile/category_screen.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/screens/mobile/history_screen.dart';
import 'package:hain_tv/screens/mobile/local_video_player_screen.dart';
import 'package:hain_tv/services/app_mode_service.dart';
import 'package:hain_tv/services/connectivity_service.dart';
import 'package:hain_tv/services/douban_service.dart';
import 'package:hain_tv/services/favorite_service.dart';
import 'package:hain_tv/services/local_video_service.dart';
import 'package:hain_tv/services/glass_style_service.dart';
import 'package:hain_tv/services/home_data_preload.dart';
import 'package:hain_tv/services/play_record_refresh_notifier.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/connection_status_badge.dart';
import 'package:hain_tv/widgets/common/add_menu_sheet.dart';
import 'package:hain_tv/widgets/mobile/mobile_horizontal_list.dart';
import 'package:hain_tv/widgets/common/video_grid.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

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

  /// 本地视频列表（用户自行导入的本机视频）。
  /// 🔴 2026-10-31 上架整改：应用为用户自身单机使用，无服务器也能播放本地视频。
  List<LocalVideoItem> _localVideos = [];

  /// 游客态（未连接服务器）：不展示任何影视海报，仅保留本地播放记录与添加入口。
  /// 🔴 2026-10-31 上架整改。
  bool get _guest => AppModeService.instance.isGuest;

  @override
  void initState() {
    super.initState();
    _consumePreloadedData();
    // SplashScreen 已成功预加载首页数据时（_consumePreloadedData 已消费并把
    // _loading 置 false），首页直接用该快照渲染，不再重复请求服务器 —— 既避免
    // 冷启动拉两遍热门，也避免弱网下再次同步/拉取造成卡顿。本地“继续播放/收藏”
    // 的实时增量由 PlayRecordRefreshNotifier 等通知机制刷新，不依赖重启。
    // 仅当预加载失败（首页无缓存数据）时才自行加载兜底。
    if (_loading) {
      _loadData();
    }
    _loadLocalVideos();
    PlayRecordRefreshNotifier.instance.addListener(_onPlayRecordRefresh);
    LocalVideoListNotifier.instance.addListener(_onLocalVideosChanged);
    AppModeService.instance.addListener(_onModeChanged);
    ConnectivityService.instance.startMonitoring();
  }

  /// 如果 SplashScreen 已预加载首页数据，直接填充状态并跳过初始加载圈。
  void _consumePreloadedData() {
    if (!HomeDataPreload.hasData) return;
    _hotMovies = HomeDataPreload.hotMovies!;
    _hotTvShows = HomeDataPreload.hotTvShows!;
    _hotShows = HomeDataPreload.hotShows!;
    _hotAnimes = HomeDataPreload.hotAnimes!;
    _allContinueWatching = HomeDataPreload.allContinueWatching!;
    _continueWatching = HomeDataPreload.continueWatching!;
    _loading = false;
    HomeDataPreload.clear();
  }

  @override
  void dispose() {
    PlayRecordRefreshNotifier.instance.removeListener(_onPlayRecordRefresh);
    LocalVideoListNotifier.instance.removeListener(_onLocalVideosChanged);
    AppModeService.instance.removeListener(_onModeChanged);
    ConnectivityService.instance.stopMonitoring();
    super.dispose();
  }

  /// 运行态切换（游客态 ↔ 服务器态）时刷新首页内容。
  ///
  /// 切到服务器态：拉取海报与服务器记录；切回游客态：清空海报，仅保留本地记录。
  void _onModeChanged() {
    if (!mounted) return;
    if (_guest) {
      setState(() {
        _hotMovies = [];
        _hotTvShows = [];
        _hotShows = [];
        _hotAnimes = [];
      });
      _loadContinueWatching(localOnly: true);
    } else {
      _loadData();
    }
  }

  void _onPlayRecordRefresh() {
    if (mounted) _loadContinueWatching(localOnly: true);
  }

  /// 本地视频库变化（新增/删除）后刷新首页「本地视频」区块。
  void _onLocalVideosChanged() {
    if (mounted) _loadLocalVideos();
  }

  Future<void> _loadLocalVideos() async {
    final items = await LocalVideoService.list();
    if (!mounted) return;
    setState(() => _localVideos = items);
  }

  /// 打开本地视频播放页。
  Future<void> _openLocalVideo(LocalVideoItem item) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LocalVideoPlayerScreen(item: item),
      ),
    );
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
        builder: (_) =>
            MobileHistoryScreen(initialRecords: _allContinueWatching),
      ),
    );
  }

  Future<void> _loadData() async {
    const pageLimit = 18;
    try {
      // 游客态（未连接服务器）：不拉取影视海报、不与服务器同步，
      // 只读取本地播放记录，保证无服务器也能秒开应用。
      if (_guest) {
        await _loadContinueWatching(localOnly: true);
        if (mounted) {
          setState(() {
            _hotMovies = [];
            _hotTvShows = [];
            _hotShows = [];
            _hotAnimes = [];
            _loading = false;
            _error = null;
          });
        }
        return;
      }

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
      debugPrint('MobileHomeScreen: 首次全量同步失败: $e');
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
          _allContinueWatching = records;
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromPlayRecord(record),
      ),
    );
    // 从详情页返回后仅读取本地增量更新，避免再次请求远程。
    if (mounted) await _loadContinueWatching(localOnly: true);
  }

  Future<void> _openDetail(BuildContext context, DoubanMovie movie) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromDoubanMovie(movie),
      ),
    );
    // 从详情页返回后仅读取本地增量更新，避免再次请求远程。
    if (mounted) await _loadContinueWatching(localOnly: true);
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
        // 游客态不展示任何海报：继续播放仅以文字卡片呈现（2026-10-31 上架整改）。
        posterUrl: (!_guest && record.cover.isNotEmpty) ? record.cover : null,
        subtitle: record.sourceName.isNotEmpty
            ? record.sourceName
            : record.source,
        onTap: () => _openHistory(record),
      );
    }).toList();
  }

  /// 本地视频区块：纵向列表（无海报），点击播放，长按删除。
  ///
  /// 刻意不用横向海报列表 —— 本地视频没有封面图，
  /// 横向卡片会出现大量空白占位；纵向列表信息密度更高，也便于删除操作。
  Widget _buildLocalVideosSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '本地视频',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              TextButton.icon(
                onPressed: () => showAddMenuSheet(context),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加'),
                style: TextButton.styleFrom(foregroundColor: AppColors.primary),
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
        ..._localVideos.map(
          (item) => ListTile(
            leading: const Icon(Icons.play_circle_outline, color: AppColors.primary),
            title: Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: AppColors.textPrimary,
              ),
            ),
            subtitle: Text(
              '本地文件 · ${(item.size / 1024 / 1024).toStringAsFixed(1)} MB',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
            trailing: IconButton(
              icon: Icon(Icons.delete_outline, color: AppColors.textMuted),
              tooltip: '删除',
              onPressed: () => _confirmDeleteLocalVideo(item),
            ),
            onTap: () => _openLocalVideo(item),
          ),
        ),
      ],
    );
  }

  /// 删除本地视频（同时删除沙箱内文件）。
  Future<void> _confirmDeleteLocalVideo(LocalVideoItem item) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除本地视频'),
        content: Text('确定要删除「${item.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await LocalVideoService.remove(item);
    await _loadLocalVideos();
  }

  /// 游客态引导卡片：说明当前可用能力，并提供「添加服务器」入口。
  Widget _buildGuestGuide() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.info_outline, color: AppColors.primary, size: 18),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '未连接服务器（可离线使用）',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '当前可使用本地播放记录、直播源与本地视频。'
            '连接服务器后可浏览影视分类与推荐内容。',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 13,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: [
              ElevatedButton.icon(
                onPressed: () => showAddMenuSheet(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加服务器 / 直播源 / 本地视频'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return VisibilityDetector(
      key: const Key('mobile_home_screen'),
      onVisibilityChanged: (info) {
        // 手机版 IndexedStack 切回首页时读取本地缓存即可；
        // 播放后的增量更新已通过 PlayRecordRefreshNotifier 刷新。
        if (info.visibleFraction > 0.5) {
          _loadContinueWatching(localOnly: true);
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.bgApp,
        // bottom:false —— 让内容视口一直延伸到屏幕最底，滚动时海报能穿到底部
        // 磨砂导航栏之下被真实模糊；底部避让由滚动内容自身的 padding 承担。
        body: SafeArea(bottom: false, child: _buildBody(context)),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: TechLoadingIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              _error!,
              style: TextStyle(color: AppColors.textSecondary),
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(onPressed: _loadData, child: const Text('重试')),
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
                Icon(Icons.movie, color: AppColors.primary, size: 28),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  '海因影视',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                const ConnectionStatusBadge(),
                const Spacer(),
                // 右上角「加号」：添加服务器地址 / 添加直播源。
                // 🔴 2026-10-31 上架整改：服务器登录非必需，入口前置到首页右上角。
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: '添加服务器 / 直播源',
                  color: AppColors.primary,
                  onPressed: () => showAddMenuSheet(context),
                ),
              ],
            ),
          ),
        ),
        // 游客态引导条：未连接服务器时提示可用能力与添加入口。
        if (_guest)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: _buildGuestGuide(),
            ),
          ),
        // 本地视频区块（无服务器也能播放本机视频）。
        if (_localVideos.isNotEmpty) ...[
          SliverToBoxAdapter(child: _buildLocalVideosSection()),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
        ],
        if (_guest && _continueWatching.isNotEmpty)
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.lg)),
        if (_continueWatching.isNotEmpty)
          SliverToBoxAdapter(
            child: MobileHorizontalList(
              title: '继续播放',
              items: _toContinueItems(_continueWatching),
              onViewMore: _viewHistory,
            ),
          ),
        if (_continueWatching.isNotEmpty)
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
        // 游客态不展示任何影视海报（2026-10-31 上架整改）。
        if (!_guest) ...[
          SliverToBoxAdapter(
            child: MobileHorizontalList(
              title: '热门电影',
              items: _toPosterItems(_hotMovies, context),
              onViewMore: () => _viewMoreCategory('movie', '电影'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
          SliverToBoxAdapter(
            child: MobileHorizontalList(
              title: '热门电视剧',
              items: _toPosterItems(_hotTvShows, context),
              onViewMore: () => _viewMoreCategory('tv', '电视剧'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
          SliverToBoxAdapter(
            child: MobileHorizontalList(
              title: '热门综艺',
              items: _toPosterItems(_hotShows, context),
              onViewMore: () => _viewMoreCategory('show', '综艺'),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: AppSpacing.xl)),
          SliverToBoxAdapter(
            child: MobileHorizontalList(
              title: '热门动漫',
              items: _toPosterItems(_hotAnimes, context),
              onViewMore: () => _viewMoreCategory('anime', '动漫'),
            ),
          ),
        ],
        // 底部留出浮动磨砂导航栏总高（含手势条），保证最后一个列表可完整滚出。
        SliverToBoxAdapter(
          child: SizedBox(
            height:
                AppSpacing.xxl + GlassStyleService.navBarTotalHeight(context),
          ),
        ),
      ],
    );
  }
}
