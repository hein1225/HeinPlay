import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
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
  final VoidCallback? onLongPress;
  final bool enabled;

  /// 为 true 时，禁用 [FocusableActionDetector] 内部默认的方向键焦点遍历。
  /// 调用方需要在 [onKeyEvent] 中自行处理方向键，避免焦点被默认策略带到错误位置。
  final bool consumeDirectionalKeys;

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
    this.onLongPress,
    this.enabled = true,
    this.consumeDirectionalKeys = false,
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

  // 遥控器/键盘长按确认键计时器（仅当提供 onLongPress 时启用）。
  Timer? _longPressTimer;
  bool _longPressTriggered = false;

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
    _longPressTimer?.cancel();
    _longPressTimer = null;
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
    _longPressTimer?.cancel();
    _longPressTimer = null;
    if (_longPressTriggered) {
      _longPressTriggered = false;
      return;
    }
    widget.onTap?.call();
  }

  bool get _wantsLongPress =>
      widget.enabled && widget.onLongPress != null && widget.onTap != null;

  bool _isConfirmKey(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter;
  }

  void _startLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTriggered = false;
    _longPressTimer = Timer(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      _longPressTriggered = true;
      widget.onLongPress?.call();
    });
  }

  void _cancelLongPressTimer() {
    _longPressTimer?.cancel();
    _longPressTimer = null;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    // 1. 优先交给调用方处理方向键等自定义逻辑。
    final userResult = widget.onKeyEvent?.call(node, event);
    if (userResult == KeyEventResult.handled) {
      _cancelLongPressTimer();
      return KeyEventResult.handled;
    }

    // 2. 未提供长按回调时，不再拦截确认键。
    if (!_wantsLongPress) {
      return userResult ?? KeyEventResult.ignored;
    }

    final key = event.logicalKey;
    if (!_isConfirmKey(key)) {
      return userResult ?? KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      _startLongPressTimer();
      return KeyEventResult.handled;
    }
    if (event is KeyRepeatEvent) {
      // 持续按住时保持计时器，计时器触发后会执行 onLongPress。
      return KeyEventResult.handled;
    }
    if (event is KeyUpEvent) {
      if (_longPressTriggered) {
        _longPressTriggered = false;
        _cancelLongPressTimer();
        return KeyEventResult.handled;
      }
      _cancelLongPressTimer();
      widget.onTap?.call();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
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
      onKeyEvent: widget.enabled ? _handleKeyEvent : null,
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
            actions: widget.enabled
                ? <Type, Action<Intent>>{
                    if (widget.onTap != null)
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) {
                          widget.onTap?.call();
                          return null;
                        },
                      ),
                    if (widget.onTap != null)
                      ButtonActivateIntent: CallbackAction<ButtonActivateIntent>(
                        onInvoke: (_) {
                          widget.onTap?.call();
                          return null;
                        },
                      ),
                    if (widget.consumeDirectionalKeys)
                      DirectionalFocusIntent:
                          CallbackAction<DirectionalFocusIntent>(
                        onInvoke: (_) => null,
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
