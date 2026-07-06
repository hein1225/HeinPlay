import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme.dart';
import 'tv_card.dart';

class PosterItem {
  final String id;
  final String title;
  final String? posterUrl;
  final String year;
  final String? rating;
  final VoidCallback? onTap;

  PosterItem({
    required this.id,
    required this.title,
    this.posterUrl,
    this.year = '',
    this.rating,
    this.onTap,
  });
}

class TvHorizontalPosterList extends StatefulWidget {
  final String? title;
  final List<PosterItem> items;
  final double cardWidth;

  const TvHorizontalPosterList({
    super.key,
    this.title,
    required this.items,
    this.cardWidth = 140,
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
      _focusNodes.add(FocusNode());
    }
    while (_focusNodes.length > widget.items.length) {
      _focusNodes.removeLast().dispose();
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(int index, FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
    return KeyEventResult.ignored;
  }

  void _focusIndex(int target) {
    if (target < 0 || target >= _focusNodes.length) return;
    if (_scrollController.hasClients) {
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
    _focusNodes[target].requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
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
                  title: item.title,
                  posterUrl: item.posterUrl,
                  year: item.year,
                  rating: item.rating,
                  onTap: item.onTap,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}

class TvPosterGrid extends StatelessWidget {
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
  });

  static int computeCrossAxisCount(double width) {
    if (width > 1600) return 8;
    if (width > 1400) return 7;
    if (width > 1100) return 6;
    if (width > 800) return 5;
    if (width > 500) return 4;
    return 3;
  }

  int _computeCrossAxisCount(double width) => computeCrossAxisCount(width);

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final count = crossAxisCount ?? _computeCrossAxisCount(constraints.maxWidth);
        return GridView.builder(
            controller: controller,
            padding: padding,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: count,
              crossAxisSpacing: AppSpacing.md,
              mainAxisSpacing: AppSpacing.lg,
              childAspectRatio: 0.55,
            ),
            itemCount: items.length,
            itemBuilder: (context, index) {
            final item = items[index];
            final isFirst = index == 0;
            final count = crossAxisCount ?? _computeCrossAxisCount(constraints.maxWidth);
            return TvPosterCard(
              autofocus: autofocusFirstItem && isFirst,
              focusNode: itemFocusNodes != null
                  ? itemFocusNodes![index]
                  : (isFirst ? firstItemFocusNode : null),
              onKeyEvent: (node, event) {
                if (onItemKeyEvent != null) {
                  final result = onItemKeyEvent!(index, count, node, event);
                  if (result == KeyEventResult.handled) return result;
                }
                return onKeyEvent?.call(node, event) ?? KeyEventResult.ignored;
              },
              title: item.title,
              posterUrl: item.posterUrl,
              year: item.year,
              rating: item.rating,
              onTap: item.onTap,
            );
          },
        );
      },
    );
  }
}
