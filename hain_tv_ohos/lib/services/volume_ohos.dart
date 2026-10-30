import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:volume_controller/volume_controller.dart';

/// 系统媒体音量封装：抹平鸿蒙与非鸿蒙的差异。
///
/// 【为什么需要】
/// `volume_controller` 插件（pubspec 锁 3.5.0）的 `plugin.platforms` 只有
/// android / ios / macos / linux / windows，**没有 ohos**。因此在鸿蒙上
/// `VolumeController.instance.setVolume()` 走的是**默认空实现** —— 只改了 Dart
/// 侧本地变量、不调用任何系统 API，表现为「音量提示条在动、实际音量不变」。
/// 安卓有原生实现，故行为正常。
///
/// 鸿蒙侧改由原生 `EntryAbility.ets` 注册的 `hain_tv/volume` MethodChannel
/// 实现：ArkTS 用 `@ohos.multimedia.audio` 的
/// `AudioVolumeGroupManager` 读写 `AudioVolumeType.MEDIA` 音量，
/// 与安卓「改系统媒体音量」的行为对齐。
///
/// Dart 侧统一走本封装，播放页无需按平台分支。
///
/// 【取值范围】对外一律使用 0.0..1.0 归一化音量；原生侧负责与设备档位
/// （[min,max]）换算，故上层无需感知具体档位数。
class VolumeOhos {
  static const MethodChannel _channel = MethodChannel('hain_tv/volume');

  /// 读取当前系统媒体音量（0.0..1.0）。
  ///
  /// 读取失败时返回 [fallback]（默认 0.5），保证手势起点始终有可用值。
  static Future<double> get({double fallback = 0.5}) async {
    if (Platform.isOhos) {
      try {
        final v = await _channel.invokeMethod<num>('getVolume');
        if (v == null) return fallback;
        return v.toDouble().clamp(0.0, 1.0);
      } catch (e) {
        debugPrint('VolumeOhos: 鸿蒙读取音量失败: $e');
        return fallback;
      }
    }
    try {
      return (await VolumeController.instance.getVolume()).clamp(0.0, 1.0);
    } catch (e) {
      debugPrint('VolumeOhos: 读取音量失败: $e');
      return fallback;
    }
  }

  /// 设置系统媒体音量（[volume] 取 0.0..1.0）。
  ///
  /// 设置失败不应阻断手势交互，仅记录日志。
  static Future<void> set(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    if (Platform.isOhos) {
      try {
        await _channel.invokeMethod<void>('setVolume', {'volume': v});
      } catch (e) {
        debugPrint('VolumeOhos: 鸿蒙设置音量失败: $e');
      }
      return;
    }
    try {
      await VolumeController.instance.setVolume(v);
    } catch (e) {
      debugPrint('VolumeOhos: 设置音量失败: $e');
    }
  }
}
