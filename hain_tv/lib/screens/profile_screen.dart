import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/focusable.dart';
import '../models/favorite.dart';
import '../models/play_record.dart' as models;
import '../models/source_option.dart';
import '../services/lunatv_service.dart';
import '../services/play_record_service.dart';
import '../services/update_service.dart';
import '../theme.dart';
import '../widgets/tv_grid.dart';
import '../widgets/update_channel_dialog.dart';
import 'player_screen.dart';
import 'settings_screen.dart';
import 'source_loading_screen.dart';

class ProfileScreen extends StatefulWidget {
  const ProfileScreen({super.key});

  @override
  State<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends State<ProfileScreen> {
  List<Favorite> _favorites = [];
  List<models.PlayRecord> _history = [];
  final List<FocusNode> _menuFocusNodes = List.generate(4, (_) => FocusNode());

  @override
  void dispose() {
    for (final node in _menuFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    List<Favorite> favorites = [];
    try {
      final response = await LunaTVService.getFavorites();
      if (response.success && response.data != null) {
        favorites = response.data!;
      }
    } catch (e) {}

    List<models.PlayRecord> history = [];
    try {
      history = await PlayRecordService.getAll();
    } catch (e) {}

    setState(() {
      _favorites = favorites;
      _history = history;
    });
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
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          videoDetail: detail,
          episodeIndex: 0,
          sources: [sourceOption],
        ),
      ),
    );
  }

  Future<void> _openHistory(models.PlayRecord record) async {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SourceLoadingScreen(record: record),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const SettingsScreen()),
    );
  }

  int? get _currentMenuIndex {
    for (int i = 0; i < _menuFocusNodes.length; i++) {
      if (_menuFocusNodes[i].hasFocus) return i;
    }
    return null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final menuIndex = _currentMenuIndex;
    if (menuIndex != null) {
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        if (menuIndex < _menuFocusNodes.length - 1) {
          _menuFocusNodes[menuIndex + 1].requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        if (menuIndex > 0) {
          _menuFocusNodes[menuIndex - 1].requestFocus();
        }
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        // 我的页面菜单下方没有可聚焦内容，禁止按下丢失焦点
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // 第一行：播放记录和收藏夹
            Row(
              children: [
                Expanded(
                  child: _buildMenuCard(
                    icon: Icons.history,
                    title: '播放记录',
                    subtitle: _history.isEmpty ? '暂无播放记录' : '${_history.length} 部',
                    onTap: () => _showRecords(_history),
                    focusNode: _menuFocusNodes[0],
                    autofocus: true,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _buildMenuCard(
                    icon: Icons.favorite_outline,
                    title: '收藏夹',
                    subtitle: _favorites.isEmpty ? '暂无收藏' : '${_favorites.length} 部',
                    onTap: () => _showFavorites(_favorites),
                    focusNode: _menuFocusNodes[1],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _buildMenuCard(
                    icon: Icons.settings_outlined,
                    title: '软件设置',
                    subtitle: '播放器、数据源、缓存',
                    onTap: _openSettings,
                    focusNode: _menuFocusNodes[2],
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _buildMenuCard(
                    icon: Icons.system_update,
                    title: '检测更新',
                    subtitle: '当前版本 ${UpdateService.currentVersion}',
                    onTap: () async {
                      final channel = await showUpdateChannelDialog(context);
                      if (channel != null && context.mounted) {
                        await UpdateService.checkAndPrompt(
                          context,
                          channel: channel,
                        );
                      }
                    },
                    focusNode: _menuFocusNodes[3],
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.xl),
            // 软件介绍
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildMenuCard({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    FocusNode? focusNode,
    bool autofocus = false,
  }) {
    return FocusableWidget(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      child: Container(
        height: 100,
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Row(
          children: [
            Icon(icon, color: AppColors.primary, size: 32),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
          ],
        ),
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
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          const Text(
            '海因影视是一款基于 Flutter 开发的 TV 端影视应用，支持多源播放、豆瓣数据展示等功能。',
            style: TextStyle(
              fontSize: 13,
              color: AppColors.textSecondary,
              height: 1.5,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              const Icon(
                Icons.code,
                color: AppColors.primary,
                size: 16,
              ),
              const SizedBox(width: AppSpacing.xs),
              const Text(
                '开源仓库：',
                style: TextStyle(
                  fontSize: 13,
                  color: AppColors.textSecondary,
                ),
              ),
              Text(
                'https://github.com/hein1225/HeinPlay',
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.primary,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showFavorites(List<Favorite> favorites) {
    final items = favorites.map((f) {
      return PosterItem(
        id: f.id,
        title: f.title,
        posterUrl: f.cover.isNotEmpty ? f.cover : null,
        year: '',
        onTap: () => _openFavorite(f),
      );
    }).toList();

    _showRecordSheet(
      title: '收藏夹',
      items: items,
      emptyMessage: '暂无收藏内容',
    );
  }

  void _showRecords(List<models.PlayRecord> records) {
    final items = records.map((r) {
      return PosterItem(
        id: r.title,
        title: r.title,
        posterUrl: r.cover.isNotEmpty ? r.cover : null,
        onTap: () => _openHistory(r),
      );
    }).toList();

    _showRecordSheet(
      title: '播放记录',
      items: items,
      emptyMessage: '暂无播放记录',
    );
  }

  KeyEventResult _handleRecordGridKeyEvent(
    int index,
    int crossAxisCount,
    KeyEvent event,
    ScrollController controller,
    BoxConstraints? constraints,
    List<FocusNode> nodes,
  ) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index % crossAxisCount != 0) {
          _focusGridIndex(
            index - 1,
            crossAxisCount,
            controller,
            constraints,
            nodes,
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowRight:
        if (index % crossAxisCount != crossAxisCount - 1 &&
            index + 1 < nodes.length) {
          _focusGridIndex(
            index + 1,
            crossAxisCount,
            controller,
            constraints,
            nodes,
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowUp:
        if (index >= crossAxisCount) {
          _focusGridIndex(
            index - crossAxisCount,
            crossAxisCount,
            controller,
            constraints,
            nodes,
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.arrowDown:
        if (index + crossAxisCount < nodes.length) {
          _focusGridIndex(
            index + crossAxisCount,
            crossAxisCount,
            controller,
            constraints,
            nodes,
          );
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _focusGridIndex(
    int target,
    int crossAxisCount,
    ScrollController controller,
    BoxConstraints? constraints,
    List<FocusNode> nodes,
  ) {
    if (target < 0 || target >= nodes.length) return;

    final c = constraints;
    if (c != null && controller.hasClients) {
      const horizontalPadding = AppSpacing.lg * 2;
      const crossSpacing = AppSpacing.md;
      const mainSpacing = AppSpacing.lg;
      const aspectRatio = 0.55;

      final availableWidth = c.maxWidth - horizontalPadding;
      final itemWidth =
          (availableWidth - (crossAxisCount - 1) * crossSpacing) /
          crossAxisCount;
      final itemHeight = itemWidth / aspectRatio;
      final rowHeight = itemHeight + mainSpacing;

      final targetRow = target ~/ crossAxisCount;
      final targetTop = AppSpacing.lg + targetRow * rowHeight;
      final targetBottom = targetTop + itemHeight;

      final viewportHeight = c.maxHeight;
      final currentOffset = controller.offset;
      final viewportBottom = currentOffset + viewportHeight;

      double? targetOffset;
      if (targetTop < currentOffset) {
        targetOffset = targetTop;
      } else if (targetBottom > viewportBottom) {
        targetOffset = targetBottom - viewportHeight;
      }

      if (targetOffset != null) {
        controller.animateTo(
          targetOffset.clamp(
            controller.position.minScrollExtent,
            controller.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }

    nodes[target].requestFocus();
  }

  void _showRecordSheet({
    required String title,
    required List<PosterItem> items,
    required String emptyMessage,
  }) {
    final scrollController = ScrollController();
    final focusNodes = List.generate(items.length, (_) => FocusNode());
    BoxConstraints? gridConstraints;

    showModalBottomSheet(
      context: context,
      backgroundColor: AppColors.bgApp,
      isScrollControlled: true,
      builder: (context) {
        return Container(
          height: MediaQuery.of(context).size.height * 0.75,
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Expanded(
                child: items.isEmpty
                    ? Center(
                        child: Text(
                          emptyMessage,
                          style: const TextStyle(color: AppColors.textSecondary),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          gridConstraints = constraints;
                          return TvPosterGrid(
                            controller: scrollController,
                            items: items,
                            itemFocusNodes: focusNodes,
                            autofocusFirstItem: false,
                            onItemKeyEvent: (index, crossAxisCount, node,
                                    event) =>
                                _handleRecordGridKeyEvent(
                                  index,
                                  crossAxisCount,
                                  event,
                                  scrollController,
                                  gridConstraints,
                                  focusNodes,
                                ),
                          );
                        },
                      ),
              ),
            ],
          ),
        );
      },
    ).then((_) {
      scrollController.dispose();
      for (final node in focusNodes) {
        node.dispose();
      }
    });
  }
}
