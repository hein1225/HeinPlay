import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
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

  @override
  void initState() {
    super.initState();
    _syncKeys();
  }

  @override
  void didUpdateWidget(covariant TvPosterGrid oldWidget) {
    super.didUpdateWidget(oldWidget);
    _syncKeys();
  }

  void _syncKeys() {
    while (_itemKeys.length < widget.items.length) {
      _itemKeys.add(GlobalKey());
    }
    while (_itemKeys.length > widget.items.length) {
      _itemKeys.removeLast();
    }
  }

  void _ensureVisible(int index) {
    if (index < 0 || index >= _itemKeys.length) return;
    final context = _itemKeys[index].currentContext;
    if (context == null) return;
    Scrollable.ensureVisible(
      context,
      alignment: 0.5,
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
        return GridView.builder(
            controller: widget.controller,
            padding: widget.padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              crossAxisSpacing: AppSpacing.md,
              mainAxisSpacing: AppSpacing.md,
              childAspectRatio: 0.7,
            ),
            scrollCacheExtent: ScrollCacheExtent.pixels(2000),
            itemCount: widget.items.length,
            itemBuilder: (context, index) {
            final item = widget.items[index];
            final isFirst = index == 0;
            final itemCount = _computeCrossAxisCount(constraints.maxWidth);
            return TvPosterCard(
              key: _itemKeys[index],
              autofocus: widget.autofocusFirstItem && isFirst,
              focusNode: widget.itemFocusNodes != null
                  ? widget.itemFocusNodes![index]
                  : (isFirst ? widget.firstItemFocusNode : null),
              selected: widget.selectedPredicate?.call(index) ?? false,
              aspectRatio: 0.7,
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
