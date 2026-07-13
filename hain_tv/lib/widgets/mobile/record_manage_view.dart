import 'package:flutter/material.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_poster_grid.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

/// 通用记录管理视图：支持网格展示、批量选择、删除与清空。
class RecordManageView<T> extends StatefulWidget {
  final String title;
  final List<T> items;
  final String emptyMessage;
  final String Function(T) toKey;
  final PosterItem Function(T) toPosterItem;
  final Future<void> Function(List<String>) onDeleteKeys;
  final Future<void> Function() onClear;
  final void Function(List<T>)? onItemsChanged;

  const RecordManageView({
    super.key,
    required this.title,
    required this.items,
    required this.emptyMessage,
    required this.toKey,
    required this.toPosterItem,
    required this.onDeleteKeys,
    required this.onClear,
    this.onItemsChanged,
  });

  @override
  State<RecordManageView<T>> createState() => _RecordManageViewState<T>();
}

class _RecordManageViewState<T> extends State<RecordManageView<T>> {
  late List<T> _items;
  final Set<String> _selectedKeys = <String>{};
  bool _selectionMode = false;
  final ScrollController _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
  }

  @override
  void didUpdateWidget(covariant RecordManageView<T> oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length ||
        oldWidget.items != widget.items) {
      setState(() {
        _items = List.from(widget.items);
        // 移除已不存在的选择项，避免删除时误操作
        final validKeys = _items.map(widget.toKey).toSet();
        _selectedKeys.removeWhere((key) => !validKeys.contains(key));
      });
    }
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
      _selectedKeys.clear();
      _selectionMode = false;
    });
    widget.onItemsChanged?.call(_items);
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
      _selectedKeys.clear();
      _selectionMode = false;
    });
    widget.onItemsChanged?.call(_items);
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
              fontFamily: 'NotoSansSC',
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

  Widget _buildToolbarButton({
    required String label,
    required VoidCallback? onTap,
    bool primary = false,
  }) {
    return GestureDetector(
      onTap: onTap,
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
          ),
          const SizedBox(width: AppSpacing.md),
          _buildToolbarButton(
            label: '删除(${_selectedKeys.length})',
            onTap: _selectedKeys.isNotEmpty ? _deleteSelected : null,
            primary: true,
          ),
          const SizedBox(width: AppSpacing.md),
          _buildToolbarButton(
            label: '清空',
            onTap: _clearAll,
          ),
        ],
      );
    }

    return Row(
      children: [
        _buildToolbarButton(
          label: '批量选择',
          onTap: _toggleSelectionMode,
        ),
        const SizedBox(width: AppSpacing.md),
        _buildToolbarButton(
          label: '清空',
          onTap: _clearAll,
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              widget.title,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
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
                    style: const TextStyle(color: AppColors.textSecondary),
                  ),
                )
              : MobilePosterGrid(
                  controller: _scrollController,
                  items: _items.map((item) {
                    final base = widget.toPosterItem(item);
                    return PosterItem(
                      id: base.id,
                      title: base.title,
                      posterUrl: base.posterUrl,
                      year: base.year,
                      subtitle: base.subtitle,
                      rating: base.rating,
                      ratingLabel: base.ratingLabel,
                      bangumiRating: base.bangumiRating,
                      onTap: null,
                    );
                  }).toList(),
                  selectedPredicate: (index) =>
                      _selectionMode &&
                      _selectedKeys.contains(widget.toKey(_items[index])),
                  onTapItem: (index, item) {
                    final key = widget.toKey(_items[index]);
                    if (_selectionMode) {
                      _toggleItem(key);
                    } else {
                      widget.toPosterItem(_items[index]).onTap?.call();
                    }
                  },
                ),
        ),
      ],
    );
  }
}
