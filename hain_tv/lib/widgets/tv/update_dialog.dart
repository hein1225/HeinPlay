import 'package:flutter/material.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/models/update_info.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  required Future<void> Function(void Function(double progress) onProgress)
      onDownload,
}) async {
  await showDialog(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => UpdateDialog(
      info: info,
      onDownload: onDownload,
    ),
  );
}

class UpdateDialog extends StatefulWidget {
  final UpdateInfo info;
  final Future<void> Function(void Function(double progress) onProgress)
      onDownload;

  const UpdateDialog({
    super.key,
    required this.info,
    required this.onDownload,
  });

  @override
  State<UpdateDialog> createState() => _UpdateDialogState();
}

class _UpdateDialogState extends State<UpdateDialog> {
  bool _isDownloading = false;
  double _progress = 0.0;

  Future<void> _startDownload() async {
    setState(() {
      _isDownloading = true;
      _progress = 0.0;
    });

    try {
      await widget.onDownload((progress) {
        if (mounted) {
          setState(() {
            _progress = progress;
          });
        }
      });
    } finally {
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final progressText = '${(_progress * 100).toStringAsFixed(1)}%';

    return PopScope(
      canPop: !_isDownloading,
      child: FocusScope(
        autofocus: true,
        child: AlertDialog(
          backgroundColor: AppColors.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: Text(
            '发现新版本 ${widget.info.version}',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 640,
            height: MediaQuery.of(context).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 更新日志滚动区域
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      color: AppColors.bgApp,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (widget.info.title.isNotEmpty) ...[
                            Text(
                              widget.info.title,
                              style: const TextStyle(
                                fontFamily: 'NotoSansSC',
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: AppColors.textPrimary,
                              ),
                            ),
                            const SizedBox(height: AppSpacing.sm),
                          ],
                          Text(
                            widget.info.body.isEmpty
                                ? '暂无更新说明'
                                : widget.info.body,
                            style: const TextStyle(
                              fontFamily: 'NotoSansSC',
                              fontSize: 14,
                              color: AppColors.textSecondary,
                              height: 1.6,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // 下载进度区域（固定显示在底部）
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: _isDownloading ? 64 : 0,
                  padding: _isDownloading
                      ? const EdgeInsets.only(top: AppSpacing.md)
                      : EdgeInsets.zero,
                  child: _isDownloading
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: ClipRRect(
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.sm),
                                    child: LinearProgressIndicator(
                                      value: _progress,
                                      backgroundColor: AppColors.bgElevated,
                                      valueColor:
                                          const AlwaysStoppedAnimation<Color>(
                                        AppColors.primary,
                                      ),
                                      minHeight: 8,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: AppSpacing.sm),
                                SizedBox(
                                  width: 56,
                                  child: Text(
                                    progressText,
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(
                                      fontFamily: 'NotoSansSC',
                                      fontSize: 12,
                                      color: AppColors.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: AppSpacing.xs),
                            const Text(
                              '正在下载安装包，请稍候...',
                              style: TextStyle(
                                fontFamily: 'NotoSansSC',
                                fontSize: 12,
                                color: AppColors.textSecondary,
                              ),
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
              ],
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: FocusableWidget(
                    enabled: !_isDownloading,
                    onTap: () => Navigator.of(context).pop(),
                    child: _buildButton(
                      label: '稍后更新',
                      backgroundColor: AppColors.bgElevated,
                      foregroundColor: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FocusableWidget(
                    enabled: !_isDownloading,
                    onTap: () async {
                      await UserDataService.saveSkippedVersion(
                          widget.info.version);
                      if (context.mounted) {
                        Navigator.of(context).pop();
                      }
                    },
                    child: _buildButton(
                      label: '跳过该版本',
                      backgroundColor: AppColors.bgElevated,
                      foregroundColor: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FocusableWidget(
                    autofocus: true,
                    enabled: !_isDownloading,
                    onTap: _startDownload,
                    child: _buildButton(
                      label: _isDownloading ? '下载中...' : '立即更新',
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildButton({
    required String label,
    required Color backgroundColor,
    required Color foregroundColor,
  }) {
    return Container(
      height: 44,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: backgroundColor,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: foregroundColor,
        ),
      ),
    );
  }
}
