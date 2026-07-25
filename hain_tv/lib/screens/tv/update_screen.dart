import 'package:flutter/material.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/widgets/tv/update_channel_dialog.dart';

/// 全平台统一的“检查更新”页面，提供两个功能选项：
/// 1. 选择默认更新仓库（国内/GitHub）；
/// 2. 立即检测更新。
class UpdateScreen extends StatefulWidget {
  const UpdateScreen({super.key});

  @override
  State<UpdateScreen> createState() => _UpdateScreenState();
}

class _UpdateScreenState extends State<UpdateScreen> {
  String _defaultUpdateChannel = 'domestic';

  @override
  void initState() {
    super.initState();
    _loadDefaultChannel();
  }

  Future<void> _loadDefaultChannel() async {
    final channel = await UserDataService.getDefaultUpdateChannel();
    if (!mounted) return;
    setState(() => _defaultUpdateChannel = channel);
  }

  String _channelLabel(String channel) {
    return channel == 'github' ? 'GitHub 仓库' : '国内仓库';
  }

  String get _platform => AppInfoService.platform;

  Future<void> _selectDefaultChannel() async {
    final channel = await showUpdateChannelDialog(context);
    if (channel != null && mounted) {
      final channelKey = channel == UpdateChannel.github ? 'github' : 'domestic';
      await UserDataService.saveDefaultUpdateChannel(channelKey);
      setState(() => _defaultUpdateChannel = channelKey);
    }
  }

  Future<void> _checkUpdate() async {
    final channel = _defaultUpdateChannel == 'github'
        ? UpdateChannel.github
        : UpdateChannel.domestic;

    if (context.mounted) {
      await UpdateService.checkAndPrompt(
        context,
        force: true,
        channel: channel,
        platform: _platform,
      );
    }
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        elevation: 0,
        title: const Text('检查更新'),
        leading: DeviceUtils.isWindows
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _buildSectionTitle('更新仓库'),
          _buildCard(
            child: FocusableWidget(
              onTap: _selectDefaultChannel,
              child: ListTile(
                leading: const Icon(Icons.swap_horiz, color: AppColors.primary),
                title: const Text('默认更新仓库'),
                subtitle: Text(_channelLabel(_defaultUpdateChannel)),
                trailing: const Text(
                  '已设置',
                  style: TextStyle(color: AppColors.primary),
                ),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('操作'),
          _buildCard(
            child: FocusableWidget(
              onTap: _checkUpdate,
              child: ListTile(
                leading:
                    const Icon(Icons.system_update, color: AppColors.primary),
                title: const Text('检测更新'),
                subtitle: const Text('立即检查是否有新版本'),
                trailing: const Icon(
                  Icons.chevron_right,
                  color: AppColors.textSecondary,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
