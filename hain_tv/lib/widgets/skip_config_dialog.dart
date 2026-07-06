import 'package:flutter/material.dart';
import '../focus/focusable.dart';
import '../models/skip_segment.dart';
import '../theme.dart';

class SkipConfigDialog extends StatefulWidget {
  final List<SkipSegment> segments;
  final ValueChanged<List<SkipSegment>>? onSave;

  const SkipConfigDialog({
    super.key,
    required this.segments,
    this.onSave,
  });

  @override
  State<SkipConfigDialog> createState() => _SkipConfigDialogState();
}

class _SkipConfigDialogState extends State<SkipConfigDialog> {
  late List<SkipSegment> _segments;

  @override
  void initState() {
    super.initState();
    _segments = List.from(widget.segments);
  }

  void _addSegment(String type) {
    setState(() {
      _segments.add(SkipSegment(
        start: 0,
        end: 0,
        type: type,
        title: type == 'opening' ? '片头' : '片尾',
        autoSkip: true,
        autoNextEpisode: type == 'ending',
      ));
    });
  }

  void _removeSegment(int index) {
    setState(() => _segments.removeAt(index));
  }

  void _updateSegment(int index, SkipSegment segment) {
    setState(() => _segments[index] = segment);
  }

  String _formatSeconds(double seconds) {
    final m = seconds ~/ 60;
    final s = (seconds % 60).toInt();
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  double _parseSeconds(String text) {
    final parts = text.split(':');
    if (parts.length == 2) {
      final m = int.tryParse(parts[0]) ?? 0;
      final s = int.tryParse(parts[1]) ?? 0;
      return (m * 60 + s).toDouble();
    }
    return double.tryParse(text) ?? 0;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgApp,
      title: const Text(
        '跳过片头片尾',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 18,
          fontWeight: FontWeight.w600,
          color: AppColors.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 520,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                FocusableWidget(
                  autofocus: true,
                  onTap: () => _addSegment('opening'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryTint,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, color: AppColors.primary, size: 18),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          '片头',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                FocusableWidget(
                  onTap: () => _addSegment('ending'),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primaryTint,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.add, color: AppColors.primary, size: 18),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          '片尾',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),
            if (_segments.isEmpty)
              const Text(
                '暂无跳过配置，点击上方按钮添加片头或片尾。',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: AppColors.textSecondary,
                ),
              )
            else
              ..._segments.asMap().entries.map((entry) {
                final index = entry.key;
                final segment = entry.value;
                return _buildSegmentEditor(index, segment);
              }),
            const SizedBox(height: AppSpacing.lg),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                FocusableWidget(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.bgElevated,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Text(
                      '取消',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                FocusableWidget(
                  onTap: () {
                    widget.onSave?.call(_segments);
                    Navigator.of(context).pop();
                  },
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.primary,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: const Text(
                      '保存',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Colors.white,
                      ),
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

  Widget _buildSegmentEditor(int index, SkipSegment segment) {
    final startController = TextEditingController(
      text: _formatSeconds(segment.start),
    );
    final endController = TextEditingController(
      text: _formatSeconds(segment.end),
    );

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.md),
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  segment.type == 'opening' ? '片头' : '片尾',
                  style: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const Spacer(),
                FocusableWidget(
                  onTap: () => _removeSegment(index),
                  child: const Icon(
                    Icons.delete_outline,
                    color: AppColors.error,
                    size: 20,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Expanded(
                  child: _buildTimeField(
                    label: '开始',
                    controller: startController,
                    onChanged: (value) {
                      _updateSegment(
                        index,
                        segment.copyWith(start: _parseSeconds(value)),
                      );
                    },
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: _buildTimeField(
                    label: '结束',
                    controller: endController,
                    onChanged: (value) {
                      _updateSegment(
                        index,
                        segment.copyWith(end: _parseSeconds(value)),
                      );
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                _buildToggle(
                  label: '自动跳过',
                  value: segment.autoSkip,
                  onChanged: (value) => _updateSegment(
                    index,
                    segment.copyWith(autoSkip: value),
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                _buildToggle(
                  label: '自动下一集',
                  value: segment.autoNextEpisode,
                  onChanged: (value) => _updateSegment(
                    index,
                    segment.copyWith(autoNextEpisode: value),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTimeField({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 12,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        TextField(
          controller: controller,
          onChanged: onChanged,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textPrimary,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: AppColors.bgSurface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.sm),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.sm,
              vertical: AppSpacing.xs,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildToggle({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return FocusableWidget(
      onTap: () => onChanged(!value),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            value ? Icons.check_box : Icons.check_box_outline_blank,
            color: value ? AppColors.primary : AppColors.textSecondary,
            size: 20,
          ),
          const SizedBox(width: AppSpacing.xs),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 13,
              color: value ? AppColors.textPrimary : AppColors.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}
