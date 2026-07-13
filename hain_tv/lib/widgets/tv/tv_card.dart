import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/theme.dart';

class TvPosterCard extends StatelessWidget {
  final String title;
  final String? posterUrl;
  final String year;
  final String? subtitle;
  final String? rating;
  final String? ratingLabel;
  final String? bangumiRating;
  final VoidCallback? onTap;
  final bool autofocus;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final bool selected;
  final double aspectRatio;

  const TvPosterCard({
    super.key,
    required this.title,
    this.posterUrl,
    required this.year,
    this.subtitle,
    this.rating,
    this.ratingLabel,
    this.bangumiRating,
    this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChange,
    this.selected = false,
    this.aspectRatio = 2 / 3,
  });

  Widget _buildImage(BuildContext context) {
    final placeholder = Container(
      color: AppColors.bgSurface,
      child: Center(
        child: Text(
          title.isNotEmpty ? title.substring(0, 1) : '',
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 32,
            color: AppColors.textMuted,
          ),
        ),
      ),
    );

    if (posterUrl == null || posterUrl!.isEmpty) {
      return placeholder;
    }

    var url = posterUrl!;
    if (url.startsWith('//')) {
      url = 'https:$url';
    }
    url = BangumiService.proxyImageUrl(url);

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      cacheManager: HainTvCacheManager(),
      memCacheWidth: 300,
      memCacheHeight: 450,
      httpHeaders: const {
        'Referer': 'https://m.douban.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      },
      placeholder: (context, url) => placeholder,
      errorWidget: (context, url, error) => placeholder,
    );
  }

  Widget _buildRatingBadge(
    String rate, {
    String? label,
    bool isBangumi = false,
  }) {
    final score = double.tryParse(rate);
    final Color bgColor;
    if (isBangumi) {
      bgColor = const Color(0xFFF472B6); // Bangumi 粉
    } else if (score == null) {
      bgColor = AppColors.textMuted;
    } else if (score >= 9.0) {
      bgColor = const Color(0xFF3B82F6); // 蓝色
    } else if (score >= 8.0) {
      bgColor = const Color(0xFF22C55E); // 绿色
    } else if (score >= 6.0) {
      bgColor = const Color(0xFFEAB308); // 黄色
    } else {
      bgColor = const Color(0xFFEF4444); // 红色
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AppRadius.full),
      ),
      child: Text(
        label != null ? '$label $rate' : rate,
        style: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: Colors.white,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget card = FocusableWidget(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      onKeyEvent: onKeyEvent,
      onFocusChange: onFocusChange,
      focusedScale: 1.04,
      child: AspectRatio(
        aspectRatio: aspectRatio,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(AppRadius.md),
          child: Stack(
            fit: StackFit.expand,
            children: [
              _buildImage(context),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.all(AppSpacing.sm),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.9),
                        Colors.black.withValues(alpha: 0.5),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        subtitle ?? (year.isNotEmpty ? year : '未知年份'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 11,
                          color: Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (rating != null && rating!.isNotEmpty)
                Positioned(
                  top: AppSpacing.xs,
                  right: AppSpacing.xs,
                  child: _buildRatingBadge(
                    rating!,
                    label: ratingLabel ?? '豆瓣',
                    isBangumi: ratingLabel == 'Bangumi',
                  ),
                ),
              if (bangumiRating != null && bangumiRating!.isNotEmpty)
                Positioned(
                  top: AppSpacing.xs,
                  left: AppSpacing.xs,
                  child: _buildRatingBadge(
                    bangumiRating!,
                    label: 'Bangumi',
                    isBangumi: true,
                  ),
                ),
            ],
          ),
        ),
      ),
    );

    if (selected) {
      card = Stack(
        children: [
          card,
          Positioned(
            top: AppSpacing.sm,
            right: AppSpacing.sm,
            child: Container(
              padding: const EdgeInsets.all(2),
              decoration: const BoxDecoration(
                color: AppColors.primary,
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.check,
                color: Colors.white,
                size: 14,
              ),
            ),
          ),
        ],
      );
    }

    return card;
  }
}
