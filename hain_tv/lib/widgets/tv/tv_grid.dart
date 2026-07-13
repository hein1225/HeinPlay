import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/theme.dart';
import 'tv_card.dart';

class PosterItem {
  final String id;
  final String title;
  final String? posterUrl;
  final String year;
  final String? subtitle;
  final String? rating;
  final String? ratingLabel;
  final String? bangumiRating;
  final VoidCallback? onTap;

  PosterItem({
    required this.id,
    required this.title,
    this.posterUrl,
    this.year = '',
    this.subtitle,
    this.rating,
    this.ratingLabel,
    this.bangumiRating,
    this.onTap,
  });
}

class TvHorizontalPosterList extends StatefulWidget {
  final String? title;
  final List<PosterItem> items;
  final double cardWidth;
  final FocusNode? firstItemFocusNode;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  const TvHorizontalPosterList({
    super.key,
    this.title,
    required this.items,
    this.cardWidth = 140,
    this.firstItemFocusNode,
    this.onMoveUp,
    this.onMoveDown,
  });

  @override
  State<TvHorizontalPosterList> createState() => _TvHorizontalPosterListState();
}

class _TvHorizontalPosterListState extends State<TvHorizontalPosterList> {
  final _scrollController = ScrollController();
  final List<FocusNode> _focusNodes = [];

  @override
  void initState() {
    super.initState();
    _syncFocusNodes();
  }

  @override
  void didUpdateWidget(covariant TvHorizontalPosterList oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncFocusNodes();
  }

  void _syncFocusNodes() {
    while (_focusNodes.length < widget.items.length) {
      // 第一项优先使用外部传入的 FocusNode，便于首页焦点链串联
      if (_focusNodes.isEmpty && widget.firstItemFocusNode != null) {
        _focusNodes.add(widget.firstItemFocusNode!);
      } else {
        _focusNodes.add(FocusNode());
      }
    }
    while (_focusNodes.length > widget.items.length) {
      final removed = _focusNodes.removeLast();
      if (removed != widget.firstItemFocusNode) {
        removed.dispose();
      }
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _focusNodes) {
      if (node != widget.firstItemFocusNode) {
        node.dispose();
      }
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(int index, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (index > 0) {
        _focusIndex(index - 1);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (index < widget.items.length - 1) {
        _focusIndex(index + 1);
      }
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      if (widget.onMoveUp != null) {
        widget.onMoveUp!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      if (widget.onMoveDown != null) {
        widget.onMoveDown!();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  void _scrollToIndex(int target) {
    if (!_scrollController.hasClients) return;
    final viewportWidth = _scrollController.position.viewportDimension;
    const padding = AppSpacing.lg;
    const separator = AppSpacing.md;
    final itemWidth = widget.cardWidth;
    final targetLeft = padding + target * (itemWidth + separator);
    final targetRight = targetLeft + itemWidth;
    final currentOffset = _scrollController.offset;
    final viewportRight = currentOffset + viewportWidth;
    double targetOffset = currentOffset;
    if (targetLeft < currentOffset) {
      targetOffset = targetLeft - padding;
    } else if (targetRight > viewportRight) {
      targetOffset = targetRight - viewportWidth + padding;
    }
    targetOffset = targetOffset.clamp(
      _scrollController.position.minScrollExtent,
      _scrollController.position.maxScrollExtent,
    );
    if ((targetOffset - currentOffset).abs() > 0.5) {
      _scrollController.animateTo(
        targetOffset,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _focusIndex(int target) {
    if (target < 0 || target >= _focusNodes.length) return;
    _scrollToIndex(target);
    _focusNodes[target].requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (focused) {
        if (focused) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              Scrollable.ensureVisible(
                context,
                alignment: 0.5,
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
              );
            }
          });
        }
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.title != null && widget.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(
                left: AppSpacing.lg,
                bottom: AppSpacing.md,
              ),
              child: Text(
                widget.title!,
                style: const TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          SizedBox(
            height: 230,
            child: ListView.separated(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              scrollCacheExtent: ScrollCacheExtent.pixels(double.maxFinite),
              itemCount: widget.items.length,
              separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
              itemBuilder: (context, index) {
                final item = widget.items[index];
                return SizedBox(
                    width: widget.cardWidth,
                    child: TvPosterCard(
                      autofocus: index == 0,
                      focusNode: _focusNodes[index],
                      onKeyEvent: (node, event) =>
                          _handleKeyEvent(index, node, event),
                      onFocusChange: (focused) {
                        if (focused) _scrollToIndex(index);
                      },
                      title: item.title,
                      posterUrl: item.posterUrl,
                      year: item.year,
                      subtitle: item.subtitle,
                      rating: item.rating,
                      ratingLabel: item.ratingLabel,
                      bangumiRating: item.bangumiRating,
                      onTap: item.onTap,
                    ),
                  );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class TvPosterGrid extends StatefulWidget {
  final List<PosterItem> items;
  final int? crossAxisCount;
  final EdgeInsets padding;
  final ScrollController? controller;
  final FocusNode? firstItemFocusNode;
  final List<FocusNode>? itemFocusNodes;
  final bool autofocusFirstItem;
  final FocusOnKeyEventCallback? onKeyEvent;
  final KeyEventResult Function(
    int index,
    int crossAxisCount,
    FocusNode node,
    KeyEvent event,
  )? onItemKeyEvent;
  final bool Function(int index)? selectedPredicate;

  const TvPosterGrid({
    super.key,
    required this.items,
    this.crossAxisCount,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.controller,
    this.firstItemFocusNode,
    this.itemFocusNodes,
    this.autofocusFirstItem = true,
    this.onKeyEvent,
    this.onItemKeyEvent,
    this.selectedPredicate,
  });

  static int computeCrossAxisCount(double width) {
    if (width > 1500) return 8;
    if (width > 1300) return 7;
    if (width > 1050) return 6;
    if (width > 750) return 5;
    if (width > 500) return 4;
    return 3;
  }

  @override
  State<TvPosterGrid> createState() => _TvPosterGridState();
}

class _TvPosterGridState extends State<TvPosterGrid> {
  final List<GlobalKey> _itemKeys = [];
  final ScrollController _internalScrollController = ScrollController();
  int _crossAxisCount = 1;
  int _lastFocusedRow = -1;
  double _rowHeight = 0;

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  @override
  void didUpdateWidget(covariant TvPosterGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeys();
    // 数据整体刷新（首项变化）时重置上次聚焦行，避免滚动定位沿用上一条数据的状态
    if (widget.items.isNotEmpty &&
        (oldWidget.items.isEmpty || oldWidget.items.first.id != widget.items.first.id)) {
      _lastFocusedRow = -1;
    }
  }

  @override
  void dispose() {
    _internalScrollController.dispose();
    super.dispose();
  }

  void _syncKeys() {
    while (_itemKeys.length < widget.items.length) {
      _itemKeys.add(GlobalKey());
    }
    while (_itemKeys.length > widget.items.length) {
      _itemKeys.removeLast();
    }
  }

  ScrollController get _scrollController =>
      widget.controller ?? _internalScrollController;

  void _ensureVisible(int index) {
    if (index < 0 || index >= _itemKeys.length) return;
    final row = index ~/ _crossAxisCount;
    // 同一行内左右移动不触发竖直滚动，避免海报墙上下跳动
    if (row == _lastFocusedRow) {
      debugPrint('[TvPosterGrid._ensureVisible] index=$index row=$row 同一行，不滚动');
      return;
    }

    final controller = _scrollController;
    if (!controller.hasClients || _rowHeight <= 0) {
      debugPrint('[TvPosterGrid._ensureVisible] index=$index row=$row 无客户端或行高未计算');
      return;
    }

    final topPadding = widget.padding.top;
    // 焦点选中行始终作为可见的第一行海报行显示
    double targetOffset = topPadding + row * _rowHeight;
    // 最顶行回到最小偏移，留出顶部内边距，避免放大后被裁切
    if (row == 0) {
      targetOffset = controller.position.minScrollExtent;
    }

    targetOffset = targetOffset.clamp(
      controller.position.minScrollExtent,
      controller.position.maxScrollExtent,
    );

    debugPrint('[TvPosterGrid._ensureVisible] index=$index row=$row 滚动 -> target=$targetOffset');
    _lastFocusedRow = row;
    controller.animateTo(
      targetOffset,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  int _computeCrossAxisCount(double width) =>
      widget.crossAxisCount ?? TvPosterGrid.computeCrossAxisCount(width);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = _computeCrossAxisCount(constraints.maxWidth);
        // 列数变化时重置上次记录的行，避免行号计算失效
        if (count != _crossAxisCount) {
          _lastFocusedRow = -1;
        }
        _crossAxisCount = count;

        // 计算单行高度：item 宽度 / 宽高比 + 行间距
        final itemWidth = (constraints.maxWidth -
                widget.padding.horizontal -
                AppSpacing.md * (count - 1)) /
            count;
        _rowHeight = itemWidth / 0.78 + 6;
        return GridView.builder(
            controller: _scrollController,
            padding: widget.padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              crossAxisSpacing: AppSpacing.md,
              mainAxisSpacing: 6,
              childAspectRatio: 0.78,
            ),
            scrollCacheExtent: ScrollCacheExtent.pixels(2000),
            itemCount: widget.items.length,
            itemBuilder: (context, index) {
            final item = widget.items[index];
            final isFirst = index == 0;
            final itemCount = count;
            return TvPosterCard(
              key: _itemKeys[index],
              autofocus: widget.autofocusFirstItem && isFirst,
              focusNode: widget.itemFocusNodes != null
                  ? widget.itemFocusNodes![index]
                  : (isFirst ? widget.firstItemFocusNode : null),
              selected: widget.selectedPredicate?.call(index) ?? false,
              aspectRatio: 0.78,
              onKeyEvent: (node, event) {
                if (widget.onItemKeyEvent != null) {
                  final result = widget.onItemKeyEvent!(
                    index,
                    itemCount,
                    node,
                    event,
                  );
                  if (result == KeyEventResult.handled) return result;
                }
                return widget.onKeyEvent?.call(node, event) ??
                    KeyEventResult.ignored;
              },
              onFocusChange: (focused) {
                if (focused) _ensureVisible(index);
              },
              title: item.title,
              posterUrl: item.posterUrl,
              year: item.year,
              subtitle: item.subtitle,
              rating: item.rating,
              ratingLabel: item.ratingLabel,
              bangumiRating: item.bangumiRating,
              onTap: item.onTap,
            );
          },
        );
      },
    );
  }
}
