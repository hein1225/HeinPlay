import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

/// 屏幕常亮封装：抹平鸿蒙与非鸿蒙的差异。
///
/// 【为什么需要】
/// `wakelock_plus` 仅覆盖 android / ios / web / windows / linux / macos，
/// **没有鸿蒙（ohos）原生实现**——在 ohos 上调用 `WakelockPlus.enable()` 会抛
/// `PlatformException(channel-error, Unable to establish connection on channel)`，
/// 屏幕不会常亮。
///
/// 鸿蒙侧改由原生 `EntryAbility.ets` 注册的 `hain_tv/screen_wake` MethodChannel
/// 实现：ArkTS 调 `window.getLastWindow(ctx).setWindowKeepScreenOn(bool)`。
///
/// Dart 侧统一走本封装，播放页无需按平台分支。
class ScreenWakeOhos {
  static const MethodChannel _channel = MethodChannel('hain_tv/screen_wake');

  /// 开启屏幕常亮。
  static Future<void> enable() async {
    if (Platform.isOhos) {
      try {
        await _channel.invokeMethod<void>('setKeepScreenOn', {'keep': true});
      } catch (e) {
        // 原生通道失败不应阻断播放页初始化，仅记录。
        debugPrint('ScreenWakeOhos: 鸿蒙开启常亮失败: $e');
      }
    } else {
      await WakelockPlus.enable();
    }
  }

  /// 关闭屏幕常亮。
  static Future<void> disable() async {
    if (Platform.isOhos) {
      try {
        await _channel.invokeMethod<void>('setKeepScreenOn', {'keep': false});
      } catch (e) {
        debugPrint('ScreenWakeOhos: 鸿蒙关闭常亮失败: $e');
      }
    } else {
      await WakelockPlus.disable();
    }
  }
}
