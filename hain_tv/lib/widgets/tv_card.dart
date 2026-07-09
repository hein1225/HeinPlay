import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../focus/focusable.dart';
import '../services/hain_tv_cache_manager.dart';
import '../theme.dart';

class TvPosterCard extends StatelessWidget {
  final String title;
  final String? posterUrl;
  final String year;
  final String? subtitle;
  final String? rating;
  final VoidCallback? onTap;
  final bool autofocus;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;
  final ValueChanged<bool>? onFocusChange;
  final bool selected;

  const TvPosterCard({
    super.key,
    required this.title,
    this.posterUrl,
    required this.year,
    this.subtitle,
    this.rating,
    this.onTap,
    this.autofocus = false,
    this.focusNode,
    this.onKeyEvent,
    this.onFocusChange,
    this.selected = false,
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

    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      cacheManager: HainTvCacheManager(),
      httpHeaders: const {
        'Referer': 'https://m.douban.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      },
      placeholder: (context, url) => placeholder,
      errorWidget: (context, url, error) => placeholder,
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
        aspectRatio: 2 / 3,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.md),
                child: _buildImage(context),
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: selected ? AppColors.primary : AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Row(
              children: [
                Expanded(
                  child: Text(
                    subtitle ?? (year.isNotEmpty ? year : '未知年份'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textSecondary,
                    ),
                  ),
                ),
                if (rating != null && rating!.isNotEmpty) ...[
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    rating!,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.primary,
                    ),
                  ),
                ],
              ],
            ),
          ],
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
