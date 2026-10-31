import 'package:flutter/material.dart';
import 'package:hain_tv/models/live_source_config.dart';
import 'package:hain_tv/services/live_source_refresh_notifier.dart';
import 'package:hain_tv/services/live_source_storage.dart';
import 'package:hain_tv/services/local_video_service.dart';
import 'package:hain_tv/theme.dart';

import 'add_server_dialog.dart';
import 'live_source_dialog.dart';

/// 应用内「加号」菜单（底部弹窗）。
///
/// 选项：
/// - 添加服务器地址：打开 [showAddServerDialog]；
/// - 添加直播源：本地直播源（名称 + M3U/M3U8/JSON 地址），无需服务器；
/// - 添加本地视频：从系统文件管理器选择本机视频文件，复制进应用私有目录后播放，
///   同样无需服务器（应用为用户自身单机使用）。
///
/// 两个入口在游客态（未连接服务器）下同样可用 —— 这是本次上架整改的核心：
/// 服务器登录非必需，但本地能力（直播源等）必须随时可用。
Future<void> showAddMenuSheet(BuildContext context) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.bgSurface,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.dns_outlined, color: AppColors.primary),
            title: const Text(
              '添加服务器地址',
              style: TextStyle(fontFamily: 'NotoSansSC'),
            ),
            subtitle: Text(
              '连接服务器后可加载影视内容',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            onTap: () {
              Navigator.of(ctx).pop();
              showAddServerDialog(context);
            },
          ),
          ListTile(
            leading: const Icon(Icons.live_tv_outlined, color: AppColors.primary),
            title: const Text(
              '添加直播源',
              style: TextStyle(fontFamily: 'NotoSansSC'),
            ),
            subtitle: Text(
              '支持 M3U / M3U8 / JSON 地址，无需服务器',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            onTap: () async {
              Navigator.of(ctx).pop();
              final result = await showLiveSourceDialog(context, title: '添加直播源');
              if (result == null) return;
              final config = LiveSourceConfig(
                id: LiveSourceConfig.generateId(),
                name: result.name,
                url: result.url,
                isLocal: true,
                createTime: DateTime.now(),
              );
              await LiveSourceStorage.saveConfig(config);
              LiveSourceRefreshNotifier.instance.notify();
            },
          ),
          ListTile(
            leading: const Icon(Icons.video_library_outlined, color: AppColors.primary),
            title: const Text(
              '添加本地视频',
              style: TextStyle(fontFamily: 'NotoSansSC'),
            ),
            subtitle: Text(
              '从文件管理器选择本机视频，无需服务器',
              style: TextStyle(color: AppColors.textMuted, fontSize: 12),
            ),
            onTap: () async {
              Navigator.of(ctx).pop();
              try {
                final item = await LocalVideoService.pickVideo();
                if (item == null) return;
                await LocalVideoService.save(item);
                LocalVideoListNotifier.instance.notify();
              } catch (e) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('添加本地视频失败：$e')),
                  );
                }
              }
            },
          ),
          const SizedBox(height: AppSpacing.sm),
        ],
      ),
    ),
  );
}
