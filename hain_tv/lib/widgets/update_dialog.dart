import 'package:flutter/material.dart';
import '../focus/focusable.dart';
import '../models/update_info.dart';
import '../services/user_data_service.dart';
import '../theme.dart';

Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  required Future<void> Function() onDownload,
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

class UpdateDialog extends StatelessWidget {
  final UpdateInfo info;
  final Future<void> Function() onDownload;

  const UpdateDialog({
    super.key,
    required this.info,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: FocusScope(
        autofocus: true,
        child: AlertDialog(
          backgroundColor: AppColors.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: Text(
            '发现新版本 ${info.version}',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Text(
                info.body.isEmpty ? '暂无更新说明' : info.body,
                style: const TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  color: AppColors.textSecondary,
                  height: 1.5,
                ),
              ),
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: FocusableWidget(
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
                    onTap: () async {
                      await UserDataService.saveSkippedVersion(info.version);
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
                    onTap: () async {
                      await onDownload();
                    },
                    child: _buildButton(
                      label: '立即更新',
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
