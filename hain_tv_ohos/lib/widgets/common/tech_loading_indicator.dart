import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme.dart';

/// 科技感加载指示器。
///
/// 替换默认的 [CircularProgressIndicator]，提供旋转的霓虹渐变圆环，
/// 支持自定义颜色、大小与线宽，适配全平台（TV / Windows / Mobile）。
class TechLoadingIndicator extends StatefulWidget {
  final double size;
  final double strokeWidth;
  final Color? color;
  final double glowRadius;

  const TechLoadingIndicator({
    super.key,
    this.size = 36,
    this.strokeWidth = 3.5,
    this.color,
    this.glowRadius = 4,
  });

  @override
  State<TechLoadingIndicator> createState() => _TechLoadingIndicatorState();
}

class _TechLoadingIndicatorState extends State<TechLoadingIndicator>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? AppColors.loading;

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return CustomPaint(
          size: Size(widget.size, widget.size),
          painter: _TechRingPainter(
            rotation: _controller.value * 2 * pi,
            color: color,
            strokeWidth: widget.strokeWidth,
            glowRadius: widget.glowRadius,
          ),
        );
      },
    );
  }
}

class _TechRingPainter extends CustomPainter {
  final double rotation;
  final Color color;
  final double strokeWidth;
  final double glowRadius;

  _TechRingPainter({
    required this.rotation,
    required this.color,
    required this.strokeWidth,
    required this.glowRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - strokeWidth) / 2;
    final rect = Rect.fromCircle(center: center, radius: radius);

    // 背景细环
    final backgroundPaint = Paint()
      ..color = color.withValues(alpha: 0.12)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(center, radius, backgroundPaint);

    // 科技感刻度小点
    final tickPaint = Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.fill;
    const tickCount = 12;
    for (var i = 0; i < tickCount; i++) {
      final angle = rotation + (i * 2 * pi / tickCount);
      final tickCenter = Offset(
        center.dx + cos(angle) * (radius - strokeWidth * 1.8),
        center.dy + sin(angle) * (radius - strokeWidth * 1.8),
      );
      final alpha = ((i / tickCount) * 180).toInt();
      tickPaint.color = color.withValues(alpha: alpha / 255);
      canvas.drawCircle(tickCenter, strokeWidth * 0.25, tickPaint);
    }

    // 发光层
    final glowPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          color.withValues(alpha: 0.9),
          color,
        ],
        stops: const [0.0, 0.7, 1.0],
        transform: GradientRotation(rotation),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round
      ..maskFilter = MaskFilter.blur(BlurStyle.outer, glowRadius);

    canvas.drawArc(rect, rotation, 1.5 * pi, false, glowPaint);

    // 主体渐变弧
    final arcPaint = Paint()
      ..shader = SweepGradient(
        colors: [
          Colors.transparent,
          color,
        ],
        stops: const [0.0, 1.0],
        transform: GradientRotation(rotation),
      ).createShader(rect)
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(rect, rotation, 1.5 * pi, false, arcPaint);
  }

  @override
  bool shouldRepaint(covariant _TechRingPainter oldDelegate) {
    return oldDelegate.rotation != rotation ||
        oldDelegate.color != color ||
        oldDelegate.strokeWidth != strokeWidth ||
        oldDelegate.glowRadius != glowRadius;
  }
}
