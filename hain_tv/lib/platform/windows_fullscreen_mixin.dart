import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../services/user_data_service.dart';
import 'device_utils.dart';
import 'windows_window_utils.dart';

/// Windows 桌面端播放页全屏/ESC/双击操作隔离。
///
/// 该 mixin 仅服务于 Windows 桌面端，TV/Android 的全屏/返回逻辑仍由各自平台代码处理，
/// 避免互相影响。核心策略：
///
/// 1. 切换全屏时以 [windowManager.isFullScreen] 为主要依据，该状态由插件内部维护，
///    只在我们显式调用 [setFullScreen] 时改变，因此不会把“窗口较大”误判为全屏。
/// 2. 窗口边界仅作为辅助校验：当插件报告全屏但窗口实际未铺满屏幕时，修正本地状态。
/// 3. ESC 统一先尝试退出真实全屏，非全屏时再触发页面返回。
/// 4. 添加 [_togglingFullScreen] 防抖，避免连续点击导致窗口管理器卡死。
mixin WindowsFullscreenMixin<T extends StatefulWidget> on State<T>
    implements WindowListener {
  bool _isFullScreen = false;
  bool _togglingFullScreen = false;

  /// window_manager 的 SetMaximumSize 不支持 Size.infinite，用超大尺寸代替无限制。
  static const Size _kUnboundedSize = Size(100000, 100000);

  /// 进入全屏前保存的普通窗口边界，退出全屏后用于覆盖插件可能恢复的错误尺寸。
  Rect? _normalWindowBounds;

  /// 当前是否处于窗口全屏状态，供 UI 图标/PopScope 判断使用。
  bool get isWindowsFullScreen => _isFullScreen;

  /// 供外部在显式调用 [windowManager.setFullScreen] 后同步本地状态。
  void setWindowsFullScreenState(bool value) {
    if (mounted) {
      setState(() => _isFullScreen = value);
    }
  }

  /// 初始化 Windows 全屏监听与状态。
  Future<void> initWindowsFullscreen() async {
    if (!DeviceUtils.isWindows) return;
    windowManager.addListener(this);
    await syncWindowsFullscreenState();
  }

  /// 同步本地全屏状态。
  ///
  /// 优先使用 [windowManager.isFullScreen]（插件内部状态），仅当插件报告全屏但
  /// 窗口边界明显未铺满屏幕时才修正为 false，防止异常情况下状态失步。
  Future<void> syncWindowsFullscreenState() async {
    if (!DeviceUtils.isWindows || !mounted) return;
    try {
      final pluginState = await windowManager.isFullScreen();
      var actualState = pluginState;
      if (pluginState) {
        final bounds = await windowManager.getBounds();
        // 插件报告全屏但窗口明显小于屏幕（<70%）时视为异常，修正为 false。
        if (_isBoundsObviouslyNotFullscreen(bounds)) {
          debugPrint(
            'WindowsFullscreenMixin: 插件报告全屏但窗口未铺满，修正为 false: $bounds',
          );
          actualState = false;
        }
      }
      debugPrint(
        'WindowsFullscreenMixin: 同步全屏状态: plugin=$pluginState, '
        'actual=$actualState, local=$_isFullScreen',
      );
      if (_isFullScreen != actualState) {
        setState(() => _isFullScreen = actualState);
      }
    } catch (e) {
      debugPrint('WindowsFullscreenMixin: 同步全屏状态失败: $e');
    }
  }

  /// 判断窗口边界是否明显不是全屏状态。
  ///
  /// 窗口宽/高任一小于屏幕尺寸 70% 视为明显未铺满；使用较低阈值避免把
  /// 接近全屏的普通大窗口误判为全屏。
  bool _isBoundsObviouslyNotFullscreen(Rect bounds) {
    final screenSize = _tryGetScreenSize();
    if (screenSize == null) return false;
    return bounds.width < screenSize.width * 0.7 ||
        bounds.height < screenSize.height * 0.7;
  }

  /// 获取当前屏幕逻辑尺寸，优先 [View.of]，失败时回退到首屏。
  Size? _tryGetScreenSize() {
    try {
      final view = View.of(context);
      final pixelRatio = view.devicePixelRatio;
      final displaySize = view.display.size;
      return Size(
        displaySize.width / pixelRatio,
        displaySize.height / pixelRatio,
      );
    } catch (e) {
      try {
        final view = WidgetsBinding.instance.platformDispatcher.views.first;
        final pixelRatio = view.devicePixelRatio;
        final displaySize = view.display.size;
        return Size(
          displaySize.width / pixelRatio,
          displaySize.height / pixelRatio,
        );
      } catch (e2) {
        debugPrint('WindowsFullscreenMixin: 计算屏幕尺寸失败: $e; $e2');
        return null;
      }
    }
  }

  /// 释放 Windows 全屏监听。
  void disposeWindowsFullscreen() {
    if (!DeviceUtils.isWindows) return;
    windowManager.removeListener(this);
  }

  /// Windows 桌面端切换窗口全屏/取消全屏。
  ///
  /// 关键：以 [windowManager.isFullScreen] 为准决定下一步动作，避免依赖窗口
  /// 边界导致误判。进入全屏前先保存当前普通窗口边界，退出后用它覆盖插件
  /// 可能恢复的错误尺寸。
  Future<void> toggleWindowsFullscreen() async {
    if (!DeviceUtils.isWindows || _togglingFullScreen) return;
    _togglingFullScreen = true;
    try {
      final pluginFullScreen = await windowManager.isFullScreen();
      final next = !pluginFullScreen;
      debugPrint(
        'Windows 切换全屏: plugin=$pluginFullScreen local=$_isFullScreen next=$next',
      );

      if (next) {
        // 1. 先保存当前普通窗口边界（在修改标题栏/尺寸限制之前）。
        try {
          final bounds = await windowManager.getBounds();
          if (bounds.width >= 900 && bounds.height >= 600) {
            _normalWindowBounds = bounds;
            debugPrint('Windows 进入全屏前保存边界: $_normalWindowBounds');
          } else {
            _normalWindowBounds = null;
            debugPrint('Windows 进入全屏前忽略过小边界: $bounds');
          }
        } catch (e) {
          _normalWindowBounds = null;
          debugPrint('Windows 保存全屏前边界失败: $e');
        }

        // 2. 进入全屏前：必须先恢复普通窗口样式。window_manager 的 SetFullScreen
        // 在 is_frameless_ 为 true 时不会执行实际的全屏 resize；即便修复了该
        // 插件行为，若当前 GWL_STYLE 缺少 WS_CAPTION/WS_THICKFRAME，退出全屏后
        // 仍会变成不可调整的小窗口。因此先通过 Win32 API 恢复标准窗口框架。
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await WindowsWindowUtils.ensureNormalWindowFrame();
        // 放开最大/最小尺寸限制、确保可拉伸。
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setResizable(true);
        await WindowsWindowUtils.ensureResizableFrame();
        // 给 Windows 消息队列留出时间应用标题栏/框架变更。
        await Future.delayed(const Duration(milliseconds: 50));
      }

      await windowManager.setFullScreen(next);

      // 根据用户设置同步置顶状态
      final alwaysOnTop = await UserDataService.getWindowsFullscreenAlwaysOnTop();
      if (alwaysOnTop) {
        await windowManager.setAlwaysOnTop(next);
      } else {
        // 设置已关闭但当前仍是置顶状态时，取消置顶
        final currentTopmost = await windowManager.isAlwaysOnTop();
        if (!next && currentTopmost) {
          await windowManager.setAlwaysOnTop(false);
        }
      }

      // 退出全屏后恢复正常窗口的尺寸限制与标题栏，并强制刷新框架，
      // 确保 WS_THICKFRAME 等样式真正生效。
      if (!next) {
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setResizable(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await WindowsWindowUtils.ensureResizableFrame();
        // 使用自行保存的边界覆盖插件恢复结果，避免回到错误的小尺寸。
        final savedBounds = _normalWindowBounds;
        if (savedBounds != null &&
            savedBounds.width >= 900 &&
            savedBounds.height >= 600) {
          try {
            await windowManager.setBounds(savedBounds);
            debugPrint('Windows 退出全屏后恢复边界: $savedBounds');
          } catch (e) {
            debugPrint('Windows 退出全屏恢复边界失败: $e');
          }
        }
        // 兜底：如果恢复后的窗口仍然过小，强制设置为默认正常尺寸并居中。
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          final restoredBounds = await windowManager.getBounds();
          if (restoredBounds.width < 900 || restoredBounds.height < 600) {
            debugPrint(
              'Windows 退出全屏后尺寸异常，强制恢复默认尺寸: $restoredBounds',
            );
            await windowManager.setSize(const Size(900, 600));
            await windowManager.center();
          }
        } catch (e) {
          debugPrint('Windows 退出全屏后校验尺寸失败: $e');
        }
        // 先恢复边界，再限制最小尺寸，避免保存的边界小于 900x600 时被强制放大。
        await windowManager.setMinimumSize(const Size(900, 600));
        await WindowsWindowUtils.ensureResizableFrame();
        _normalWindowBounds = null;
      }

      // 同步本地状态，优先以插件状态为准。
      await syncWindowsFullscreenState();
      debugPrint('Windows 切换全屏完成: _isFullScreen=$_isFullScreen');
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
      final pluginFullScreen = await windowManager.isFullScreen();
      debugPrint('Windows ESC: plugin=$pluginFullScreen local=$_isFullScreen');
      if (pluginFullScreen) {
        await windowManager.setFullScreen(false);
        // 退出全屏后恢复窗口尺寸限制，避免仍处于小窗的限制状态。
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setResizable(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.normal);
        await WindowsWindowUtils.ensureResizableFrame();
        // 使用自行保存的边界覆盖插件恢复结果，避免回到错误的小尺寸。
        final savedBounds = _normalWindowBounds;
        if (savedBounds != null &&
            savedBounds.width >= 900 &&
            savedBounds.height >= 600) {
          try {
            await windowManager.setBounds(savedBounds);
            debugPrint('Windows ESC 退出全屏后恢复边界: $savedBounds');
          } catch (e) {
            debugPrint('Windows ESC 退出全屏恢复边界失败: $e');
          }
        }
        // 兜底：如果恢复后的窗口仍然过小，强制设置为默认正常尺寸并居中。
        await Future.delayed(const Duration(milliseconds: 100));
        try {
          final restoredBounds = await windowManager.getBounds();
          if (restoredBounds.width < 900 || restoredBounds.height < 600) {
            debugPrint(
              'Windows ESC 退出全屏后尺寸异常，强制恢复默认尺寸: $restoredBounds',
            );
            await windowManager.setSize(const Size(900, 600));
            await windowManager.center();
          }
        } catch (e) {
          debugPrint('Windows ESC 退出全屏后校验尺寸失败: $e');
        }
        await windowManager.setMinimumSize(const Size(900, 600));
        await WindowsWindowUtils.ensureResizableFrame();
        _normalWindowBounds = null;
        final alwaysOnTop = await UserDataService.getWindowsFullscreenAlwaysOnTop();
        if (alwaysOnTop || await windowManager.isAlwaysOnTop()) {
          await windowManager.setAlwaysOnTop(false);
        }
        await syncWindowsFullscreenState();
      } else if (mounted) {
        Navigator.of(context).maybePop();
        return;
      }
      if (mounted) {
        await WindowsWindowUtils.ensureResizableFrame();
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
