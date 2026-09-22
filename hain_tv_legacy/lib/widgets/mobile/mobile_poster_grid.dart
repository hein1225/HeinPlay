import 'package:flutter/material.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_poster_card.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

class MobilePosterGrid extends StatelessWidget {
  final List<PosterItem> items;
  final ScrollController? controller;
  final EdgeInsets padding;
  final double childAspectRatio;
  final void Function(int index, PosterItem item)? onTapItem;
  final bool Function(int index)? selectedPredicate;
  final bool shrinkWrap;
  final ScrollPhysics? physics;

  const MobilePosterGrid({
    super.key,
    required this.items,
    this.controller,
    this.padding = const EdgeInsets.all(AppSpacing.md),
    this.childAspectRatio = 0.62,
    this.onTapItem,
    this.selectedPredicate,
    this.shrinkWrap = false,
    this.physics,
  });

  int _computeCrossAxisCount(double width) {
    if (width <= 360) return 2;
    if (width <= 600) return 3;
    if (width <= 900) return 4;
    return 5;
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = _computeCrossAxisCount(constraints.maxWidth);
        return GridView.builder(
          controller: controller,
          padding: padding,
          shrinkWrap: shrinkWrap,
          physics: physics,
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: crossAxisCount,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
            childAspectRatio: childAspectRatio,
          ),
          itemCount: items.length,
          itemBuilder: (context, index) {
            final item = items[index];
            return MobilePosterCard(
              title: item.title,
              posterUrl: item.posterUrl,
              year: item.year,
              subtitle: item.subtitle,
              rating: item.rating,
              ratingLabel: item.ratingLabel,
              bangumiRating: item.bangumiRating,
              aspectRatio: childAspectRatio,
              selected: selectedPredicate?.call(index) ?? false,
              onTap: () {
                onTapItem?.call(index, item);
                item.onTap?.call();
              },
            );
          },
        );
      },
    );
  }
}
