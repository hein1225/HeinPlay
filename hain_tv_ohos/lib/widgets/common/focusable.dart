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

  /// 回车 / 遥控器确认键是否触发 [onTap]。
  ///
  /// 默认 true（键盘/遥控器确认 = 点击，TV 端依赖该行为）。
  /// Windows 桌面端对「返回 / 关闭 / 退出」这类控件必须设为 false：
  /// 鼠标滑过就会把焦点停到该控件上（见 build 中 MouseRegion.onEnter），
  /// 若回车也能激活它，用户随后在任何位置按回车都会直接返回上一页，
  /// 即「回车马上返回」。置 false 后只保留鼠标点击与 ESC / 右键返回。
  final bool confirmOnEnter;

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
    this.confirmOnEnter = true,
  });

  /// 鼠标悬停（而非键盘/遥控器）期间抑制各界面 onFocusChange 中的
  /// Scrollable.ensureVisible，避免“鼠标移动就触发列表滚动/翻页”。
  ///
  /// 用全局布尔而非「节点集合 + Focus.of(context)」判断：后者在帧回调里
  /// context 已 detach 会抛空指针（detail_screen 崩溃），且 MouseRegion 上下文
  /// 拿到的 Focus 节点常与 hover 集合中的 _focusNode 不一致，导致守卫失效、悬停仍滚动。
  /// 任意按键事件会在 [_handleKeyEvent] 开头清除该标志，使键盘/遥控器导航仍能正常滚动。
  static bool _hoverScrollSuppressed = false;

  /// 当前是否处于鼠标悬停态（应抑制自动滚动）。
  static bool get hoverScrollSuppressed => _hoverScrollSuppressed;

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
    // 本控件销毁时（如所在页面被 pop 而鼠标仍停在上方略过 onExit）复位悬停抑制，
    // 避免全局标志卡在 true 导致下一页焦点滚动被错误抑制。
    if (_hovered) FocusableWidget._hoverScrollSuppressed = false;
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
        // 焦点离开时清掉悬停高亮：避免「鼠标还停在某项 + 键盘已移到别的项」时
        // 出现两个高亮（鼠标所指项靠 _hovered、键盘项靠 _focused），保证全局
        // 鼠标与键盘共用同一个真实焦点，任何时刻只有一处高亮。
        if (!focused) {
          _hovered = false;
        }
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
    // 主键盘回车 / 遥控器确认键 / 小键盘回车 三者等价，缺一都会表现为
    // “回车（某个键盘）无法确认”。Windows 端用户常用主键盘与小键盘两种回车。
    return key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter;
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
    // 任意按键清除悬停滚动抑制，使键盘/遥控器导航的焦点变更能正常触发
    // Scrollable.ensureVisible（悬停抑制只在鼠标悬停期间生效）。
    if (FocusableWidget._hoverScrollSuppressed) {
      FocusableWidget._hoverScrollSuppressed = false;
    }

    // 1. 优先交给调用方处理方向键等自定义逻辑。
    final userResult = widget.onKeyEvent?.call(node, event);
    if (userResult == KeyEventResult.handled) {
      _cancelLongPressTimer();
      return KeyEventResult.handled;
    }

    // 2. 未提供长按回调时，直接把确认键（回车 / 遥控器确认 / 小键盘回车）映射为
    //    onTap，确保无论焦点落在哪个 FocusableWidget 上，回车都能作为“确认键”。
    //    不依赖 FocusableActionDetector 的 ActivateIntent：外层 Focus 设了
    //    canRequestFocus:false，其 Actions 作用域在某些情况下不可达，导致
    //    ActivateIntent 不触发——表现为“方向键能移动焦点，但回车无法确认”。
    //    仅 KeyDown 触发一次，避免长按重复激活；空格保留页面滚动语义不动。
    if (!_wantsLongPress) {
      if (event is KeyDownEvent && _isConfirmKey(event.logicalKey)) {
        if (widget.confirmOnEnter) {
          widget.onTap?.call();
        }
        // 无论是否真正激活，都必须消费确认键：否则它会在返回 ignored 后
        // 继续冒泡到 Shortcuts，由默认 ActivateIntent 再激活一次。
        return KeyEventResult.handled;
      }
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
      // 必须为 false：skipTraversal=true 会让该节点及其所有后代（包括内部真正
      // 可聚焦的 FocusableActionDetector）都不被键盘/遥控器方向键遍历访问，导致
      // 整个 FocusableWidget 在方向键导航下“锁死”（鼠标点击能直接 requestFocus
      // 绕过遍历，所以表现为“点击后方向键移动不了”）。改为 false 后内部焦点节点
      // 参与遍历，方向与 TV 版卡片一致。canRequestFocus:false 仍阻止焦点停在外层空节点。
      skipTraversal: false,
        child: MouseRegion(
          // 鼠标移到功能选项即把「真实焦点」移到该项：鼠标与键盘从此共用同一个
          // Focus，不再各自维护一套高亮。回车/确认键激活的永远是鼠标或键盘最后
          // 停留的那一项（_handleKeyEvent 的确认键映射 onTap），消除“鼠标指着 A、
          // 回车却激活了键盘之前选的 B”。TV 端无鼠标悬停，此分支不触发，行为不变。
          // 同时置 _hoverScrollSuppressed=true，使各界面 onFocusChange 中的
          // Scrollable.ensureVisible 对其跳过——鼠标移动只高亮、不触发列表滚动/翻页。
          onEnter: widget.enabled
              ? (_) {
                  FocusableWidget._hoverScrollSuppressed = true;
                  _focusNode.requestFocus();
                  _onHover(true);
                }
              : null,
          onExit: widget.enabled
              ? (_) {
                  FocusableWidget._hoverScrollSuppressed = false;
                  _onHover(false);
                }
              : null,
        child: GestureDetector(
          onTap: widget.enabled && widget.onTap != null ? _handleTap : null,
          child: FocusableActionDetector(
            autofocus: widget.enabled && widget.autofocus,
            focusNode: _focusNode,
            onFocusChange: widget.enabled ? _onFocusChange : null,
            actions: widget.enabled
                ? <Type, Action<Intent>>{
                    if (widget.onTap != null && widget.confirmOnEnter)
                      ActivateIntent: CallbackAction<ActivateIntent>(
                        onInvoke: (_) {
                          widget.onTap?.call();
                          return null;
                        },
                      ),
                    if (widget.onTap != null && widget.confirmOnEnter)
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
