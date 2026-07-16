import 'dart:math';

import 'package:flutter/material.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/models/skip_segment.dart';
import 'package:hain_tv/theme.dart';

class SkipConfigDialog extends StatefulWidget {
  final List<SkipSegment> segments;
  final Duration Function() getCurrentPosition;
  final Duration duration;
  final ValueChanged<List<SkipSegment>>? onSave;

  const SkipConfigDialog({
    super.key,
    required this.segments,
    required this.getCurrentPosition,
    required this.duration,
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
    final position = widget.getCurrentPosition();
    final seconds = position.inMilliseconds / 1000.0;
    final totalSeconds = widget.duration.inMilliseconds / 1000.0;

    setState(() {
      final existingIndex = _segments.indexWhere((s) => s.type == type);
      if (type == 'opening') {
        // 片头结束时间不能超过片尾开始时间，避免一跳就进片尾导致直接下一集
        final ending = _segments.cast<SkipSegment?>().firstWhere(
          (s) => s?.type == 'ending',
          orElse: () => null,
        );
        // 未拖动到片头结束位置时（当前进度接近 0），使用默认片头长度，
        // 避免生成 start=0/end=0 的无效片段导致跳过不生效。
        var endSeconds = seconds < 1.0 ? 90.0 : seconds;
        endSeconds = min(endSeconds, totalSeconds);
        if (ending != null) {
          endSeconds = min(endSeconds, max(0.0, ending.start - 1.0));
        }
        final segment = SkipSegment(
          start: 0,
          end: endSeconds,
          type: 'opening',
          title: '片头',
          autoSkip: true,
          autoNextEpisode: false,
        );
        if (existingIndex >= 0) {
          _segments[existingIndex] = segment;
        } else {
          _segments.add(segment);
        }
      } else {
        // 片尾开始时间不能早于片头结束时间
        final opening = _segments.cast<SkipSegment?>().firstWhere(
          (s) => s?.type == 'opening',
          orElse: () => null,
        );
        var startSeconds = max(0.0, seconds);
        if (opening != null) {
          startSeconds = max(startSeconds, opening.end + 1.0);
        }
        startSeconds = min(startSeconds, totalSeconds);
        final segment = SkipSegment(
          start: startSeconds,
          end: totalSeconds,
          type: 'ending',
          title: '片尾',
          autoSkip: true,
          autoNextEpisode: true,
          remainingTime: totalSeconds > startSeconds
              ? totalSeconds - startSeconds
              : 0,
        );
        if (existingIndex >= 0) {
          _segments[existingIndex] = segment;
        } else {
          _segments.add(segment);
        }
      }
    });
  }

  void _removeSegment(int index) {
    setState(() => _segments.removeAt(index));
  }

  void _updateSegment(int index, SkipSegment segment) {
    setState(() => _segments[index] = segment);
  }

  String _formatSeconds(double seconds) {
    final h = seconds ~/ 3600;
    final m = (seconds % 3600) ~/ 60;
    final s = (seconds % 60).toInt();
    if (h > 0) {
      return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
    }
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      scrollable: true,
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
      content: FocusScope(
        autofocus: true,
        child: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  FocusableWidget(
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
      ),
    );
  }

  Widget _buildSegmentEditor(int index, SkipSegment segment) {
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
            Text(
              '${_formatSeconds(segment.start)} - ${_formatSeconds(segment.end)}',
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                _buildToggle(
                  label: '自动跳过',
                  value: segment.autoSkip,
                  onChanged: (value) =>
                      _updateSegment(index, segment.copyWith(autoSkip: value)),
                ),
                if (segment.type == 'ending') ...[
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
              ],
            ),
          ],
        ),
      ),
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
