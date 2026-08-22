import 'dart:ffi';

import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';
import 'package:win32/win32.dart';

import 'device_utils.dart';

/// Windows 窗口样式修复辅助工具。
///
/// window_manager 0.5.2 在 [SetResizable] 后不会调用 SetWindowPos(...SWP_FRAMECHANGED)，
/// 导致 WS_THICKFRAME 样式变更无法立即生效，进而表现为：
/// - 全屏退出后窗口无法调整尺寸；
/// - 小窗模式自定义拉伸热区失效；
/// - 窗口尺寸限制异常。
///
/// 本工具通过 win32 API 直接校验并补充 WS_THICKFRAME，同时刷新窗口框架，
/// 作为插件问题的临时规避方案。
class WindowsWindowUtils {
  WindowsWindowUtils._();

  /// 确保当前窗口具有可调整尺寸边框（WS_THICKFRAME）并刷新框架。
  ///
  /// window_manager 的 [SetResizable] 仅修改 GWL_STYLE，不会调用
  /// SetWindowPos(...SWP_FRAMECHANGED)，导致 WS_THICKFRAME 变更不会立即生效。
  /// 本方法主动补充 WS_THICKFRAME 并始终刷新框架，确保样式立即生效。
  static Future<void> ensureResizableFrame() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) {
        debugPrint('WindowsWindowUtils: 无法获取窗口句柄');
        return;
      }
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());
      final styleResult = GetWindowLongPtr(hwnd, GWL_STYLE);
      if (styleResult.error.isError) {
        debugPrint('WindowsWindowUtils: 获取窗口样式失败');
        return;
      }
      final style = styleResult.value;
      final newStyle = style | WS_THICKFRAME;
      if (newStyle != style) {
        SetWindowLongPtr(hwnd, GWL_STYLE, newStyle);
        debugPrint('WindowsWindowUtils: 已补充 WS_THICKFRAME');
      }
      SetWindowPos(
        hwnd,
        HWND_TOP,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
      debugPrint('WindowsWindowUtils: 已刷新窗口框架');
    } catch (e) {
      debugPrint('WindowsWindowUtils: 确保可调整尺寸失败: $e');
    }
  }

  /// 将窗口样式恢复为普通可调整尺寸窗口（补充标题栏、系统菜单、最大/最小化框）。
  ///
  /// 当窗口曾因全屏/小窗切换丢失 WS_CAPTION/WS_THICKFRAME 等样式时，
  /// 调用本方法可确保后续 setFullScreen/setBounds 等操作基于正常窗口状态，
  /// 避免退出全屏或恢复小窗后变成不可调整的小窗口。
  static Future<void> ensureNormalWindowFrame() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) {
        debugPrint('WindowsWindowUtils: 无法获取窗口句柄');
        return;
      }
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());
      final styleResult = GetWindowLongPtr(hwnd, GWL_STYLE);
      if (styleResult.error.isError) {
        debugPrint('WindowsWindowUtils: 获取窗口样式失败');
        return;
      }
      final style = styleResult.value;
      final normalStyle = WS_CAPTION | WS_SYSMENU | WS_THICKFRAME |
          WS_MINIMIZEBOX | WS_MAXIMIZEBOX;
      final newStyle = style | normalStyle;
      if (newStyle != style) {
        SetWindowLongPtr(hwnd, GWL_STYLE, newStyle);
        debugPrint('WindowsWindowUtils: 已恢复普通窗口样式');
      }
      SetWindowPos(
        hwnd,
        HWND_TOP,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
      debugPrint('WindowsWindowUtils: 已刷新普通窗口框架');
    } catch (e) {
      debugPrint('WindowsWindowUtils: 恢复普通窗口样式失败: $e');
    }
  }

  /// 控制鼠标光标可见性（仅 Windows）。
  ///
  /// [visible] 为 true 显示光标，false 隐藏光标。底层基于 win32 的 ShowCursor
  /// 计数器 API：隐藏时持续递减计数直到光标真正隐藏，显示时持续递增直到真正显示，
  /// 避免多次调用造成计数不平衡导致光标无法恢复。
  static void setCursorVisible(bool visible) {
    if (!DeviceUtils.isWindows) return;
    try {
      if (visible) {
        // 递增计数直到光标可见（ShowCursor 返回计数 >= 0 表示可见）。
        while (ShowCursor(true) < 0) {}
      } else {
        // 递减计数直到光标隐藏（ShowCursor 返回计数 < 0 表示隐藏）。
        while (ShowCursor(false) >= 0) {}
      }
    } catch (e) {
      debugPrint('WindowsWindowUtils: 设置光标可见性失败: $e');
    }
  }

  /// 刷新窗口框架，使之前的样式变更（如 setResizable）立即生效。
  static Future<void> refreshWindowFrame() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final hwndValue = await windowManager.getId();
      if (hwndValue == 0) return;
      final hwnd = HWND(Pointer.fromAddress(hwndValue).cast<NativeType>());
      SetWindowPos(
        hwnd,
        HWND_TOP,
        0,
        0,
        0,
        0,
        SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOOWNERZORDER | SWP_FRAMECHANGED,
      );
    } catch (e) {
      debugPrint('WindowsWindowUtils: 刷新窗口框架失败: $e');
    }
  }
}
