import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'device_utils.dart';

/// Windows 桌面端播放页全屏/ESC/双击操作隔离。
///
/// 该 mixin 仅服务于 Windows 桌面端，TV/Android 的全屏/返回逻辑仍由各自平台代码处理，
/// 避免互相影响。核心策略：
///
/// 1. 切换全屏时先通过 [windowManager.isFullScreen] 读取真实窗口状态，再取反设置；
///    不依赖可能失步的本地状态变量，防止进入全屏后 ESC/双击无法退出。
/// 2. 全屏状态仍以 [WindowListener] 事件为主要驱动，并在切换后补充同步一次状态。
/// 3. ESC 统一先尝试退出真实全屏，非全屏时再触发页面返回。
/// 4. 添加 [_togglingFullScreen] 防抖，避免连续点击导致窗口管理器卡死。
mixin WindowsFullscreenMixin<T extends StatefulWidget> on State<T>
    implements WindowListener {
  bool _isFullScreen = false;
  bool _togglingFullScreen = false;

  /// 当前是否处于窗口全屏状态，供 UI 图标/PopScope 判断使用。
  bool get isWindowsFullScreen => _isFullScreen;

  /// 初始化 Windows 全屏监听与状态。
  Future<void> initWindowsFullscreen() async {
    if (!DeviceUtils.isWindows) return;
    windowManager.addListener(this);
    try {
      final actual = await windowManager.isFullScreen();
      if (mounted) {
        setState(() => _isFullScreen = actual);
      }
    } catch (e) {
      debugPrint('WindowsFullscreenMixin: 初始化全屏状态失败: $e');
    }
  }

  /// 释放 Windows 全屏监听。
  void disposeWindowsFullscreen() {
    if (!DeviceUtils.isWindows) return;
    windowManager.removeListener(this);
  }

  /// Windows 桌面端切换窗口全屏/取消全屏。
  ///
  /// 关键：不依赖本地 [_isFullScreen] 计算目标值，而是读取真实窗口状态再取反，
  /// 避免某些情况下 window_manager 事件未触发导致状态失步、无法退出全屏。
  Future<void> toggleWindowsFullscreen() async {
    if (!DeviceUtils.isWindows || _togglingFullScreen) return;
    _togglingFullScreen = true;
    try {
      final actual = await windowManager.isFullScreen();
      final next = !actual;
      debugPrint('Windows 切换全屏: actual=$actual next=$next');
      await windowManager.setFullScreen(next);
      // 以窗口事件为主要驱动；若事件未触发，补充同步一次状态。
      if (mounted) {
        setState(() => _isFullScreen = next);
      }
      debugPrint('Windows 切换全屏完成: _isFullScreen=$next');
    } catch (e) {
      debugPrint('Windows 切换全屏失败: $e');
    } finally {
      _togglingFullScreen = false;
    }
  }

  /// ESC 键处理：真实全屏时退出全屏，否则返回上一页。
  void handleWindowsEsc() {
    if (!DeviceUtils.isWindows) return;
    // fire-and-forget，HardwareKeyboard handler 需要同步返回是否已处理。
    _exitFullScreenOrPopAsync();
  }

  Future<void> _exitFullScreenOrPopAsync() async {
    try {
      final actual = await windowManager.isFullScreen();
      debugPrint('Windows ESC: actualFullScreen=$actual');
      if (actual) {
        await windowManager.setFullScreen(false);
        if (mounted) {
          setState(() => _isFullScreen = false);
        }
      } else if (mounted) {
        Navigator.of(context).maybePop();
      }
    } catch (e) {
      debugPrint('Windows ESC 处理失败: $e');
    }
  }

  /// 双击屏幕/全屏按钮触发切换。
  void onWindowsDoubleTap() {
    toggleWindowsFullscreen();
  }

  @override
  void onWindowEnterFullScreen() {
    if (mounted) {
      setState(() => _isFullScreen = true);
    }
  }

  @override
  void onWindowLeaveFullScreen() {
    if (mounted) {
      setState(() => _isFullScreen = false);
    }
  }

  // WindowListener 其它回调在此无实际行为，留空实现即可。
  @override
  void onWindowClose() {}

  @override
  void onWindowFocus() {}

  @override
  void onWindowBlur() {}

  @override
  void onWindowMaximize() {}

  @override
  void onWindowUnmaximize() {}

  @override
  void onWindowMinimize() {}

  @override
  void onWindowRestore() {}

  @override
  void onWindowResize() {}

  @override
  void onWindowResized() {}

  @override
  void onWindowMove() {}

  @override
  void onWindowMoved() {}

  @override
  void onWindowDocked() {}

  @override
  void onWindowUndocked() {}

  @override
  void onWindowEvent(String eventName) {}
}
