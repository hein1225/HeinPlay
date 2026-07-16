import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/services/update_service.dart';
import 'package:hain_tv/theme.dart';

Future<UpdateChannel?> showUpdateChannelDialog(BuildContext context) async {
  return showDialog<UpdateChannel>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => const UpdateChannelDialog(),
  );
}

class UpdateChannelDialog extends StatefulWidget {
  const UpdateChannelDialog({super.key});

  @override
  State<UpdateChannelDialog> createState() => _UpdateChannelDialogState();
}

class _UpdateChannelDialogState extends State<UpdateChannelDialog> {
  final List<FocusNode> _focusNodes = [FocusNode(), FocusNode(), FocusNode()];

  @override
  void dispose() {
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final currentIndex = _focusNodes.indexWhere((n) => n.hasFocus);
    if (currentIndex == -1) return KeyEventResult.ignored;

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (currentIndex > 0) {
          _focusNodes[currentIndex - 1].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        if (currentIndex < _focusNodes.length - 1) {
          _focusNodes[currentIndex + 1].requestFocus();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
      case LogicalKeyboardKey.arrowDown:
        // 限制焦点在对话框按钮行内，不允许上下离开
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: Focus(
        onKeyEvent: _handleKeyEvent,
        child: AlertDialog(
          backgroundColor: AppColors.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: const Text(
            '选择更新渠道',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: const SizedBox(
            width: 420,
            child: Text(
              '请选择检查更新的来源渠道：',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                color: AppColors.textSecondary,
                height: 1.5,
              ),
            ),
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: FocusableWidget(
                    autofocus: true,
                    focusNode: _focusNodes[0],
                    onTap: () =>
                        Navigator.of(context).pop(UpdateChannel.domestic),
                    child: _buildButton(
                      label: '国内渠道',
                      backgroundColor: AppColors.primary,
                      foregroundColor: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FocusableWidget(
                    focusNode: _focusNodes[1],
                    onTap: () =>
                        Navigator.of(context).pop(UpdateChannel.github),
                    child: _buildButton(
                      label: 'GitHub 渠道',
                      backgroundColor: AppColors.bgElevated,
                      foregroundColor: AppColors.textPrimary,
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: FocusableWidget(
                    focusNode: _focusNodes[2],
                    onTap: () => Navigator.of(context).pop(),
                    child: _buildButton(
                      label: '取消',
                      backgroundColor: AppColors.bgElevated,
                      foregroundColor: AppColors.textPrimary,
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
