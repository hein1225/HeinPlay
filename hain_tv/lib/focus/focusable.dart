import 'package:flutter/material.dart';
import '../theme.dart';

class FocusableWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsets padding;
  final double focusedScale;
  final FocusOnKeyEventCallback? onKeyEvent;

  const FocusableWidget({
    super.key,
    required this.child,
    this.onTap,
    this.onFocusChange,
    this.autofocus = false,
    this.focusNode,
    this.padding = const EdgeInsets.all(AppSpacing.xs),
    this.focusedScale = 1.0,
    this.onKeyEvent,
  });

  @override
  State<FocusableWidget> createState() => _FocusableWidgetState();
}

class _FocusableWidgetState extends State<FocusableWidget> {
  late final FocusNode _focusNode;
  bool _focused = false;
  bool _hovered = false;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
  }

  @override
  void dispose() {
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChange(bool focused) {
    if (_focused == focused) return;
    setState(() {
      _focused = focused;
    });
    widget.onFocusChange?.call(focused);
  }

  void _onHover(bool hovered) {
    if (_hovered == hovered) return;
    setState(() {
      _hovered = hovered;
    });
  }

  void _handleTap() {
    _focusNode.requestFocus();
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final isActive = _focused || _hovered;

    return Focus(
      onKeyEvent: widget.onKeyEvent,
      canRequestFocus: false,
      skipTraversal: true,
      child: MouseRegion(
        onEnter: (_) => _onHover(true),
        onExit: (_) => _onHover(false),
        child: GestureDetector(
          onTap: widget.onTap != null ? _handleTap : null,
          child: FocusableActionDetector(
            autofocus: widget.autofocus,
            focusNode: _focusNode,
            onFocusChange: _onFocusChange,
            actions: <Type, Action<Intent>>{
            ActivateIntent: CallbackAction<ActivateIntent>(
              onInvoke: (_) {
                widget.onTap?.call();
                return null;
              },
            ),
            ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
              onInvoke: (_) {
                widget.onTap?.call();
                return null;
              },
            ),
          },
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOut,
            padding: widget.padding,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: isActive
                  ? Border.all(color: AppColors.primary, width: 2)
                  : Border.all(color: Colors.transparent, width: 2),
              boxShadow: isActive
                  ? [
                      BoxShadow(
                        color: AppColors.primary.withValues(alpha: 0.3),
                        blurRadius: 12,
                        spreadRadius: 2,
                      ),
                    ]
                  : null,
            ),
            child: AnimatedScale(
              scale: isActive ? widget.focusedScale : 1.0,
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOut,
              child: widget.child,
            ),
          ),
        ),
      ),
    ),
  );
  }
}
