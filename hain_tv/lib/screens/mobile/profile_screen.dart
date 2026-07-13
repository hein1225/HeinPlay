import 'dart:async';

import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:hain_tv/models/favorite.dart';
import 'package:hain_tv/models/play_record.dart' as models;
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/screens/mobile/player_screen.dart';
import 'package:hain_tv/screens/tv/settings_screen.dart';
import 'package:hain_tv/services/favorite_refresh_notifier.dart';
import 'package:hain_tv/services/favorite_service.dart';
import 'package:hain_tv/services/local_storage_service.dart' as local;
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/play_record_refresh_notifier.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/profile_refresh_notifier.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/record_manage_view.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';
import 'package:hain_tv/widgets/tv/update_channel_dialog.dart';

class MobileProfileScreen extends StatefulWidget {
  const MobileProfileScreen({super.key});

  @override
  State<MobileProfileScreen> createState() => _MobileProfileScreenState();
}

class _MobileProfileScreenState extends State<MobileProfileScreen> {
  List<Favorite> _favorites = [];
  List<models.PlayRecord> _history = [];

  @override
  void initState() {
    super.initState();
    _loadData();
    ProfileRefreshNotifier.instance.addListener(_onProfileRefresh);
    PlayRecordRefreshNotifier.instance.addListener(_onPlayRecordRefresh);
    FavoriteRefreshNotifier.instance.addListener(_onFavoriteRefresh);
  }

  @override
  void dispose() {
    ProfileRefreshNotifier.instance.removeListener(_onProfileRefresh);
    PlayRecordRefreshNotifier.instance.removeListener(_onPlayRecordRefresh);
    FavoriteRefreshNotifier.instance.removeListener(_onFavoriteRefresh);
    super.dispose();
  }

  void _onProfileRefresh() {
    if (mounted) _loadData();
  }

  void _onPlayRecordRefresh() {
    if (mounted) _loadHistory(localOnly: true);
  }

  void _onFavoriteRefresh() {
    if (mounted) _loadFavorites(localOnly: true);
  }

  Future<void> _loadData() async {
    // 收藏先读本地立即显示，再后台同步远程
    await _loadFavorites(localOnly: true);
    unawaited(_loadFavorites(localOnly: false));
    // 播放记录先读本地立即显示，再后台同步远程记录与豆瓣海报
    await _loadHistory(localOnly: true);
    unawaited(_loadHistory(localOnly: false));
  }

  Future<void> _loadFavorites({bool localOnly = false}) async {
    List<Favorite> favorites = [];
    try {
      if (localOnly) {
        final localFavorites = await local.LocalStorageService.getFavorites();
        favorites = localFavorites
            .map(
              (f) => Favorite(
                source: f.source,
                id: f.id,
                title: f.title,
                cover: f.posterUrl ?? '',
                sourceName: '',
                saveTime: f.createdAt.millisecondsSinceEpoch,
              ),
            )
            .toList();
      } else {
        final response = await LunaTVService.getFavorites();
        if (response.success && response.data != null) {
          favorites = response.data!;
          // 将远程收藏同步回本地
          for (final f in favorites) {
            await local.LocalStorageService.addFavorite(
              local.FavoriteRecord(
                source: f.source,
                id: f.id,
                title: f.title,
                posterUrl: f.cover.isNotEmpty ? f.cover : null,
                createdAt: DateTime.fromMillisecondsSinceEpoch(f.saveTime ?? DateTime.now().millisecondsSinceEpoch),
              ),
            );
          }
        }
      }
    } catch (e) {}

    if (!mounted) return;
    setState(() => _favorites = favorites);
  }

  Future<void> _loadHistory({bool localOnly = false}) async {
    List<models.PlayRecord> history = [];
    try {
      history = localOnly
          ? await PlayRecordService.getAllLocal()
          : await PlayRecordService.getAll();
    } catch (e) {}

    if (!mounted) return;
    setState(() => _history = history);
  }

  Future<void> _openFavorite(Favorite favorite) async {
    final messenger = ScaffoldMessenger.of(context);
    final response = await LunaTVService.getDetail(
      source: favorite.source,
      id: favorite.id,
      title: favorite.title,
    );
    if (!response.success || response.data == null) {
      messenger.showSnackBar(const SnackBar(content: Text('未找到播放资源')));
      return;
    }
    final detail = response.data!;
    final sourceOption = SourceOption(
      source: detail.source,
      sourceName: detail.sourceName,
      id: detail.id,
      title: detail.title,
      poster: detail.poster.isNotEmpty ? detail.poster : null,
      year: detail.year,
      doubanId: detail.doubanId,
    );
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobilePlayerScreen(
          videoDetail: detail,
          episodeIndex: 0,
          sources: [sourceOption],
        ),
      ),
    );
  }

  Future<void> _openHistory(models.PlayRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromPlayRecord(record),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  Future<void> _checkUpdate() async {
    final channel = await showUpdateChannelDialog(context);
    if (channel != null && context.mounted) {
      await UpdateService.checkAndPrompt(
        context,
        force: true,
        channel: channel,
        platform: 'mobile',
      );
    }
  }

  void _showFavorites() {
    _showRecordSheet<Favorite>(
      title: '收藏夹',
      items: _favorites,
      emptyMessage: '暂无收藏内容',
      toKey: (f) => '${f.source}+${f.id}',
      toPosterItem: (f) => PosterItem(
        id: f.id,
        title: f.title,
        posterUrl: f.cover.isNotEmpty ? f.cover : null,
        year: '',
        onTap: () => _openFavorite(f),
      ),
      onDeleteKeys: (keys) => FavoriteService.deleteByKeys(keys),
      onClear: () => FavoriteService.clear(),
      onItemsChanged: (remaining) => setState(() => _favorites = remaining),
    );
  }

  void _showRecords() {
    _showRecordSheet<models.PlayRecord>(
      title: '播放记录',
      items: _history,
      emptyMessage: '暂无播放记录',
      toKey: (r) => r.title,
      toPosterItem: (r) => PosterItem(
        id: r.id,
        title: r.title,
        posterUrl: r.cover.isNotEmpty ? r.cover : null,
        subtitle: r.sourceName.isNotEmpty ? r.sourceName : r.source,
        onTap: () => _openHistory(r),
      ),
      onDeleteKeys: (keys) => PlayRecordService.deleteByKeys(keys),
      onClear: () => PlayRecordService.clear(),
      onItemsChanged: (remaining) => setState(() => _history = remaining),
    );
  }

  void _showRecordSheet<T>({
    required String title,
    required List<T> items,
    required String emptyMessage,
    required String Function(T) toKey,
    required PosterItem Function(T) toPosterItem,
    required Future<void> Function(List<String>) onDeleteKeys,
    required Future<void> Function() onClear,
    required void Function(List<T>) onItemsChanged,
  }) {
    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: AppColors.bgApp,
        insetPadding: const EdgeInsets.all(AppSpacing.md),
        child: Container(
          width: MediaQuery.of(context).size.width * 0.92,
          height: MediaQuery.of(context).size.height * 0.88,
          padding: const EdgeInsets.all(AppSpacing.md),
          child: RecordManageView<T>(
            title: title,
            items: items,
            emptyMessage: emptyMessage,
            toKey: toKey,
            toPosterItem: toPosterItem,
            onDeleteKeys: onDeleteKeys,
            onClear: onClear,
            onItemsChanged: onItemsChanged,
          ),
        ),
      ),
    );
  }

  Widget _buildMenuTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return Card(
      color: AppColors.bgElevated,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        side: const BorderSide(color: AppColors.border),
      ),
      margin: EdgeInsets.zero,
      child: ListTile(
        leading: Icon(icon, color: AppColors.primary, size: 28),
        title: Text(
          title,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 13,
            color: AppColors.textSecondary,
          ),
        ),
        trailing: const Icon(
          Icons.chevron_right,
          color: AppColors.textSecondary,
        ),
        onTap: onTap,
      ),
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '软件介绍',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            '海因影视是一款基于 Flutter 开发的跨平台影视应用，TV 版支持多源播放、豆瓣数据展示等功能。手机版与 Windows 版本可前往下方开源仓库下载。',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          _buildRepoLink(
            label: '国内仓库',
            url: 'https://gitcode.com/gcw_QbmhmbO8/HeinPlay',
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildRepoLink(
            label: 'GitHub 仓库',
            url: 'https://github.com/hein1225/HeinPlay',
          ),
        ],
      ),
    );
  }

  Widget _buildRepoLink({required String label, required String url}) {
    return InkWell(
      onTap: () async {
        final uri = Uri.parse(url);
        if (await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      },
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.code,
              color: AppColors.primary,
              size: 16,
            ),
            const SizedBox(width: AppSpacing.xs),
            Text(
              '$label：',
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            Expanded(
              child: Text(
                url,
                style: const TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 13,
                  color: AppColors.primary,
                  decoration: TextDecoration.underline,
                  decorationColor: AppColors.primary,
                ),
                softWrap: true,
                overflow: TextOverflow.visible,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(AppSpacing.md),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text(
                  '我的',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              _buildMenuTile(
                icon: Icons.history,
                title: '播放记录',
                subtitle: _history.isEmpty ? '暂无播放记录' : '${_history.length} 部',
                onTap: _showRecords,
              ),
              const SizedBox(height: AppSpacing.md),
              _buildMenuTile(
                icon: Icons.favorite_outline,
                title: '收藏夹',
                subtitle: _favorites.isEmpty ? '暂无收藏' : '${_favorites.length} 部',
                onTap: _showFavorites,
              ),
              const SizedBox(height: AppSpacing.md),
              _buildMenuTile(
                icon: Icons.settings_outlined,
                title: '软件设置',
                subtitle: '播放器、数据源、缓存',
                onTap: _openSettings,
              ),
              const SizedBox(height: AppSpacing.md),
              _buildMenuTile(
                icon: Icons.system_update,
                title: '检测更新',
                subtitle: '当前版本 ${UpdateService.currentVersion}',
                onTap: _checkUpdate,
              ),
              const SizedBox(height: AppSpacing.xl),
              _buildFooter(),
            ],
          ),
        ),
      ),
    );
  }
}
