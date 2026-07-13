import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../focus/focusable.dart';
import '../services/bangumi_service.dart';
import '../services/hain_tv_cache_manager.dart';
import '../theme.dart';

class TvBanner extends StatelessWidget {
  final String title;
  final String? overview;
  final String? backdropUrl;
  final VoidCallback? onPlay;
  final VoidCallback? onFavorite;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final FocusNode? playFocusNode;
  final FocusOnKeyEventCallback? onPlayKeyEvent;

  const TvBanner({
    super.key,
    required this.title,
    this.overview,
    this.backdropUrl,
    this.onPlay,
    this.onFavorite,
    this.onPrevious,
    this.onNext,
    this.playFocusNode,
    this.onPlayKeyEvent,
  });

  Widget _buildBackground() {
    if (backdropUrl == null || backdropUrl!.isEmpty) {
      return Container(color: AppColors.bgSurface);
    }
    var url = backdropUrl!;
    if (url.startsWith('//')) {
      url = 'https:$url';
    }
    url = BangumiService.proxyImageUrl(url);
    return CachedNetworkImage(
      imageUrl: url,
      fit: BoxFit.cover,
      cacheManager: HainTvCacheManager(),
      memCacheWidth: 800,
      memCacheHeight: 450,
      httpHeaders: const {
        'Referer': 'https://m.douban.com',
        'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
            'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      },
      placeholder: (_, __) => Container(color: AppColors.bgSurface),
      errorWidget: (_, __, ___) => Container(color: AppColors.bgSurface),
    );
  }

  Widget _buildActionButton({
    required String label,
    required IconData icon,
    required VoidCallback? onTap,
    bool primary = true,
    bool autofocus = false,
    FocusNode? focusNode,
    FocusOnKeyEventCallback? onKeyEvent,
  }) {
    return FocusableWidget(
      autofocus: autofocus,
      focusNode: focusNode,
      onTap: onTap,
      onKeyEvent: onKeyEvent,
      child: Container(
        height: 48,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        decoration: BoxDecoration(
          color: primary ? AppColors.primary : AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: primary ? Colors.white : AppColors.textPrimary,
              size: 20,
            ),
            const SizedBox(width: AppSpacing.sm),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: primary ? Colors.white : AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 420,
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildBackground(),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppColors.bgApp.withValues(alpha: 0.95),
                  AppColors.bgApp.withValues(alpha: 0.6),
                  Colors.transparent,
                ],
                stops: const [0.0, 0.45, 0.85],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 40,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                if (overview != null && overview!.isNotEmpty)
                  SizedBox(
                    width: 560,
                    child: Text(
                      overview!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 15,
                        height: 1.5,
                        color: AppColors.textSecondary,
                      ),
                    ),
                  ),
                const SizedBox(height: AppSpacing.xl),
                Row(
                  children: [
                    _buildActionButton(
                      label: '播放',
                      icon: Icons.play_arrow,
                      onTap: onPlay,
                      primary: true,
                      autofocus: true,
                      focusNode: playFocusNode,
                      onKeyEvent: onPlayKeyEvent,
                    ),
                    const SizedBox(width: AppSpacing.md),
                    _buildActionButton(
                      label: '收藏',
                      icon: Icons.add,
                      onTap: onFavorite,
                      primary: false,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
