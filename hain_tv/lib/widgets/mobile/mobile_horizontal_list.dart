import 'package:flutter/material.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_poster_card.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

class MobileHorizontalList extends StatelessWidget {
  final String? title;
  final List<PosterItem> items;
  final double cardWidth;
  final double listHeight;
  final VoidCallback? onViewMore;

  const MobileHorizontalList({
    super.key,
    this.title,
    required this.items,
    this.cardWidth = 120,
    this.listHeight = 220,
    this.onViewMore,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (title != null && title!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    title!,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
                GestureDetector(
                  onTap: onViewMore,
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '查看更多',
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      SizedBox(width: AppSpacing.xs),
                      Icon(
                        Icons.chevron_right,
                        color: AppColors.textSecondary,
                        size: 18,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (title != null && title!.isNotEmpty)
          const SizedBox(height: AppSpacing.md),
        SizedBox(
          height: listHeight,
          child: ListView.separated(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            itemCount: items.length,
            separatorBuilder: (_, __) => const SizedBox(width: AppSpacing.md),
            itemBuilder: (context, index) {
              final item = items[index];
              return SizedBox(
                width: cardWidth,
                child: MobilePosterCard(
                  title: item.title,
                  posterUrl: item.posterUrl,
                  year: item.year,
                  subtitle: item.subtitle,
                  rating: item.rating,
                  ratingLabel: item.ratingLabel,
                  bangumiRating: item.bangumiRating,
                  aspectRatio: cardWidth / listHeight,
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
