import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../models/live_channel.dart';
import '../../theme.dart';

/// 通用直播频道列表视图。
///
/// 按分组展示频道，支持当前选中高亮与点击回调。
class LiveChannelListView extends StatelessWidget {
  final Map<String, List<LiveChannel>> groupedChannels;
  final LiveChannel? selectedChannel;
  final ValueChanged<LiveChannel> onChannelSelected;
  final ScrollController? scrollController;

  const LiveChannelListView({
    super.key,
    required this.groupedChannels,
    this.selectedChannel,
    required this.onChannelSelected,
    this.scrollController,
  });

  List<_ListItem> get _items {
    final result = <_ListItem>[];
    // 保持分组在源文件中的原始顺序
    final groupKeys = groupedChannels.keys.toList();
    for (final group in groupKeys) {
      result.add(_ListItem.header(group));
      for (final channel in groupedChannels[group]!) {
        result.add(_ListItem.channel(channel));
      }
    }
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final items = _items;
    return ListView.builder(
      controller: scrollController,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: items.length,
      itemBuilder: (context, index) {
        final item = items[index];
        if (item.isHeader) {
          return _buildHeader(item.header!);
        }
        return _buildChannel(item.channel!);
      },
    );
  }

  Widget _buildHeader(String title) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      color: AppColors.bgSurface,
      child: Text(
        title,
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildChannel(LiveChannel channel) {
    final isSelected = selectedChannel?.url == channel.url &&
        selectedChannel?.name == channel.name;

    return InkWell(
      onTap: () => onChannelSelected(channel),
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.15)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: isSelected ? AppColors.primary : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            if (channel.logo != null && channel.logo!.isNotEmpty)
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: CachedNetworkImage(
                  imageUrl: channel.logo!,
                  width: 40,
                  height: 28,
                  fit: BoxFit.cover,
                  placeholder: (_, __) => Container(
                    width: 40,
                    height: 28,
                    color: AppColors.bgElevated,
                  ),
                  errorWidget: (_, __, ___) => Container(
                    width: 40,
                    height: 28,
                    color: AppColors.bgElevated,
                    child: Icon(
                      Icons.live_tv,
                      size: 16,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              )
            else
              Container(
                width: 40,
                height: 28,
                decoration: BoxDecoration(
                  color: AppColors.bgElevated,
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Icon(
                  Icons.live_tv,
                  size: 16,
                  color: AppColors.textMuted,
                ),
              ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  color: isSelected ? AppColors.textPrimary : AppColors.textSecondary,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
            ),
            if (isSelected)
              Icon(
                Icons.play_arrow,
                size: 16,
                color: AppColors.primary,
              ),
          ],
        ),
      ),
    );
  }
}

class _ListItem {
  final bool isHeader;
  final String? header;
  final LiveChannel? channel;

  _ListItem.header(this.header)
      : isHeader = true,
        channel = null;

  _ListItem.channel(this.channel)
      : isHeader = false,
        header = null;
}
