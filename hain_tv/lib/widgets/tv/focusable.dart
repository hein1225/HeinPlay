import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:hain_tv/theme.dart';

class FocusableWidget extends StatefulWidget {
  final Widget child;
  final VoidCallback? onTap;
  final ValueChanged<bool>? onFocusChange;
  final bool autofocus;
  final FocusNode? focusNode;
  final EdgeInsets padding;
  final double focusedScale;
  final FocusOnKeyEventCallback? onKeyEvent;
  final bool enabled;

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
    this.enabled = true,
  });

  @override
  State<FocusableWidget> createState() => _FocusableWidgetState();
}

class _FocusableWidgetState extends State<FocusableWidget> {
  late FocusNode _focusNode;
  bool _focused = false;
  bool _hovered = false;

  // 当内部节点被外部节点替换时，延迟到下一帧再释放，避免 Focus 组件还在 detach 阶段。
  final List<FocusNode> _pendingDisposeNodes = [];

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
  }

  @override
  void didUpdateWidget(covariant FocusableWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 当外部传入的 focusNode 发生变化时，切换底层 Focus 使用的节点。
    // 旧的内部自动创建的节点需要释放；外部传入的节点由调用方管理生命周期。
    if (widget.focusNode != oldWidget.focusNode) {
      if (oldWidget.focusNode == null) {
        _pendingDisposeNodes.add(_focusNode);
      }
      _focusNode = widget.focusNode ?? FocusNode();
      if (_pendingDisposeNodes.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          for (final node in _pendingDisposeNodes) {
            node.dispose();
          }
          _pendingDisposeNodes.clear();
        });
      }
    }
  }

  @override
  void dispose() {
    for (final node in _pendingDisposeNodes) {
      node.dispose();
    }
    _pendingDisposeNodes.clear();
    if (widget.focusNode == null) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  void _onFocusChange(bool focused) {
    if (_focused == focused) return;

    void apply() {
      if (!mounted) return;
      setState(() {
        _focused = focused;
      });
      widget.onFocusChange?.call(focused);
    }

    // FocusableActionDetector 可能会在 build 阶段回调 focus 变化，
    // 直接 setState 会触发 "setState during build" 异常， defer 到帧尾处理。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      SchedulerBinding.instance.addPostFrameCallback((_) => apply());
    } else {
      apply();
    }
  }

  void _onHover(bool hovered) {
    if (_hovered == hovered) return;
    if (!mounted) return;
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
    final isActive = widget.enabled && (_focused || _hovered);

    Widget result = AnimatedContainer(
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
    );

    if (!widget.enabled) {
      result = IgnorePointer(child: Opacity(opacity: 0.5, child: result));
    }

    return Focus(
      onKeyEvent: widget.enabled ? widget.onKeyEvent : null,
      canRequestFocus: false,
      skipTraversal: true,
      child: MouseRegion(
        onEnter: widget.enabled ? (_) => _onHover(true) : null,
        onExit: widget.enabled ? (_) => _onHover(false) : null,
        child: GestureDetector(
          onTap: widget.enabled && widget.onTap != null ? _handleTap : null,
          child: FocusableActionDetector(
            autofocus: widget.enabled && widget.autofocus,
            focusNode: _focusNode,
            onFocusChange: widget.enabled ? _onFocusChange : null,
            actions: widget.enabled && widget.onTap != null
                ? <Type, Action<Intent>>{
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
                  }
                : const {},
            child: result,
          ),
        ),
      ),
    );
  }
}
