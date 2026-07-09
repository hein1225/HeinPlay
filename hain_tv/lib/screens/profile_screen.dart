import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/focusable.dart';
import '../models/favorite.dart';
import '../models/play_record.dart' as models;
import '../models/source_option.dart';
import '../services/favorite_service.dart';
import '../services/lunatv_service.dart';
import '../services/play_record_service.dart';
import '../services/profile_refresh_notifier.dart';
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
    ProfileRefreshNotifier.instance.removeListener(_onRefresh);
    for (final node in _menuFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadData();
    ProfileRefreshNotifier.instance.addListener(_onRefresh);
  }

  void _onRefresh() {
    if (mounted) _loadData();
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

    if (!mounted) return;
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
                'https://gitcode.com/gcw_QbmhmbO8/HeinPlay',
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
    _showRecordSheet<Favorite>(
      title: '收藏夹',
      items: favorites,
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

  void _showRecords(List<models.PlayRecord> records) {
    _showRecordSheet<models.PlayRecord>(
      title: '播放记录',
      items: records,
      emptyMessage: '暂无播放记录',
      toKey: (r) => '${r.source}+${r.id}',
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
      builder: (context) => _RecordSheet<T>(
        title: title,
        items: items,
        emptyMessage: emptyMessage,
        toKey: toKey,
        toPosterItem: toPosterItem,
        onDeleteKeys: onDeleteKeys,
        onClear: onClear,
        onItemsChanged: onItemsChanged,
      ),
    );
  }
}

class _RecordSheet<T> extends StatefulWidget {
  final String title;
  final List<T> items;
  final String emptyMessage;
  final String Function(T) toKey;
  final PosterItem Function(T) toPosterItem;
  final Future<void> Function(List<String>) onDeleteKeys;
  final Future<void> Function() onClear;
  final void Function(List<T>) onItemsChanged;

  const _RecordSheet({
    required this.title,
    required this.items,
    required this.emptyMessage,
    required this.toKey,
    required this.toPosterItem,
    required this.onDeleteKeys,
    required this.onClear,
    required this.onItemsChanged,
  });

  @override
  State<_RecordSheet<T>> createState() => _RecordSheetState<T>();
}

class _RecordSheetState<T> extends State<_RecordSheet<T>> {
  late List<T> _items;
  final Set<String> _selectedKeys = <String>{};
  bool _selectionMode = false;

  final ScrollController _scrollController = ScrollController();
  final List<FocusNode> _itemFocusNodes = [];
  final List<FocusNode> _toolbarFocusNodes =
      List.generate(3, (_) => FocusNode());
  BoxConstraints? _gridConstraints;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
    _syncItemFocusNodes();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _items.isNotEmpty && _itemFocusNodes.isNotEmpty) {
        _itemFocusNodes[0].requestFocus();
      }
    });
  }

  @override
  void didUpdateWidget(covariant _RecordSheet<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.items.length != _items.length) {
      _items = List.from(widget.items);
      _syncItemFocusNodes();
    }
  }

  void _syncItemFocusNodes() {
    while (_itemFocusNodes.length < _items.length) {
      _itemFocusNodes.add(FocusNode());
    }
    while (_itemFocusNodes.length > _items.length) {
      _itemFocusNodes.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _itemFocusNodes) {
      node.dispose();
    }
    for (final node in _toolbarFocusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  void _toggleSelectionMode() {
    setState(() {
      _selectionMode = !_selectionMode;
      if (!_selectionMode) {
        _selectedKeys.clear();
      }
    });
  }

  void _toggleItem(String key) {
    setState(() {
      if (_selectedKeys.contains(key)) {
        _selectedKeys.remove(key);
      } else {
        _selectedKeys.add(key);
      }
    });
  }

  Future<void> _deleteSelected() async {
    if (_selectedKeys.isEmpty) return;
    final confirmed = await _showConfirm(
      title: '删除确认',
      message: '确定要删除选中的 ${_selectedKeys.length} 项吗？',
    );
    if (!confirmed) return;

    final keysToDelete = _selectedKeys.toList();
    await widget.onDeleteKeys(keysToDelete);

    if (!mounted) return;
    setState(() {
      _items.removeWhere((item) => keysToDelete.contains(widget.toKey(item)));
      _syncItemFocusNodes();
      _selectedKeys.clear();
      _selectionMode = false;
    });
    widget.onItemsChanged(_items);
  }

  Future<void> _clearAll() async {
    final confirmed = await _showConfirm(
      title: '清空确认',
      message: '确定要清空全部内容吗？此操作不可恢复。',
    );
    if (!confirmed) return;

    await widget.onClear();

    if (!mounted) return;
    setState(() {
      _items.clear();
      _syncItemFocusNodes();
      _selectedKeys.clear();
      _selectionMode = false;
    });
    widget.onItemsChanged(_items);
  }

  Future<bool> _showConfirm({
    required String title,
    required String message,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.bgElevated,
          title: Text(
            title,
            style: const TextStyle(
              color: AppColors.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          content: Text(
            message,
            style: const TextStyle(color: AppColors.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.textSecondary),
              ),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text(
                '确定',
                style: TextStyle(color: AppColors.primary),
              ),
            ),
          ],
        );
      },
    );
    return result == true;
  }

  KeyEventResult _handleToolbarKeyEvent(
    int index,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (_items.isNotEmpty && _itemFocusNodes.isNotEmpty) {
        _itemFocusNodes[0].requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _toolbarFocusNodes[index - 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (index < _toolbarFocusNodes.length - 1) {
        _toolbarFocusNodes[index + 1].requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  KeyEventResult _handleRecordGridKeyEvent(
    int index,
    int crossAxisCount,
    FocusNode node,
    KeyEvent event,
  ) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (index % crossAxisCount != 0) {
          _focusGridIndex(index - 1, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (index % crossAxisCount != crossAxisCount - 1 &&
            index + 1 < _itemFocusNodes.length) {
          _focusGridIndex(index + 1, crossAxisCount);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        if (index >= crossAxisCount) {
          _focusGridIndex(index - crossAxisCount, crossAxisCount);
        } else {
          // 第一行按上回到工具栏第一个按钮（批量选择/完成）
          _toolbarFocusNodes[0].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        if (index + crossAxisCount < _itemFocusNodes.length) {
          _focusGridIndex(index + crossAxisCount, crossAxisCount);
        }
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  void _focusGridIndex(int target, int crossAxisCount) {
    if (target < 0 || target >= _itemFocusNodes.length) return;

    final c = _gridConstraints;
    if (c != null && _scrollController.hasClients) {
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
      final currentOffset = _scrollController.offset;
      final viewportBottom = currentOffset + viewportHeight;

      double? targetOffset;
      if (targetTop < currentOffset) {
        targetOffset = targetTop;
      } else if (targetBottom > viewportBottom) {
        targetOffset = targetBottom - viewportHeight;
      }

      if (targetOffset != null) {
        _scrollController.animateTo(
          targetOffset.clamp(
            _scrollController.position.minScrollExtent,
            _scrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }

    _itemFocusNodes[target].requestFocus();
  }

  Widget _buildToolbarButton({
    required String label,
    required VoidCallback? onTap,
    required FocusNode focusNode,
    bool primary = false,
  }) {
    return FocusableWidget(
      focusNode: focusNode,
      onTap: onTap,
      onKeyEvent: (node, event) => _handleToolbarKeyEvent(
        _toolbarFocusNodes.indexOf(focusNode),
        node,
        event,
      ),
      child: Container(
        height: 40,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        decoration: BoxDecoration(
          color: primary ? AppColors.primary : AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: primary ? AppColors.primary : AppColors.border,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: primary ? Colors.white : AppColors.textPrimary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildToolbar() {
    if (_selectionMode) {
      return Row(
        children: [
          _buildToolbarButton(
            label: '完成',
            onTap: _toggleSelectionMode,
            focusNode: _toolbarFocusNodes[0],
          ),
          const SizedBox(width: AppSpacing.md),
          _buildToolbarButton(
            label: '删除(${_selectedKeys.length})',
            onTap: _selectedKeys.isNotEmpty ? _deleteSelected : null,
            focusNode: _toolbarFocusNodes[1],
            primary: true,
          ),
          const SizedBox(width: AppSpacing.md),
          _buildToolbarButton(
            label: '清空',
            onTap: _clearAll,
            focusNode: _toolbarFocusNodes[2],
          ),
        ],
      );
    }

    return Row(
      children: [
        _buildToolbarButton(
          label: '批量选择',
          onTap: _toggleSelectionMode,
          focusNode: _toolbarFocusNodes[0],
        ),
        const SizedBox(width: AppSpacing.md),
        _buildToolbarButton(
          label: '清空',
          onTap: _clearAll,
          focusNode: _toolbarFocusNodes[1],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final posterItems = _items.map((item) {
      final base = widget.toPosterItem(item);
      final key = widget.toKey(item);
      return PosterItem(
        id: base.id,
        title: base.title,
        posterUrl: base.posterUrl,
        year: base.year,
        subtitle: base.subtitle,
        rating: base.rating,
        onTap: _selectionMode ? () => _toggleItem(key) : base.onTap,
      );
    }).toList();

    return Dialog(
      backgroundColor: AppColors.bgApp,
      insetPadding: const EdgeInsets.all(AppSpacing.lg),
      child: Container(
        width: size.width * 0.92,
        height: size.height * 0.88,
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  widget.title,
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                _buildToolbar(),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            Expanded(
              child: _items.isEmpty
                  ? Center(
                      child: Text(
                        widget.emptyMessage,
                        style:
                            const TextStyle(color: AppColors.textSecondary),
                      ),
                    )
                  : Focus(
                      onKeyEvent: (node, event) {
                        if ((event is KeyDownEvent ||
                                event is KeyRepeatEvent) &&
                            event.logicalKey == LogicalKeyboardKey.arrowUp) {
                          _toolbarFocusNodes[0].requestFocus();
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          _gridConstraints = constraints;
                          return TvPosterGrid(
                            controller: _scrollController,
                            items: posterItems,
                            itemFocusNodes: _itemFocusNodes,
                            autofocusFirstItem: false,
                            selectedPredicate: (index) =>
                                _selectionMode &&
                                _selectedKeys
                                    .contains(widget.toKey(_items[index])),
                            onItemKeyEvent: (index, crossAxisCount, node,
                                    event) =>
                                _handleRecordGridKeyEvent(
                                    index, crossAxisCount, node, event),
                          );
                        },
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
