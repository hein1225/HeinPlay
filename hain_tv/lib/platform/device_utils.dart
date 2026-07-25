import 'dart:io';
import 'package:flutter/foundation.dart';

class DeviceUtils {
  static bool? _tvOverride;

  static set isTvOverride(bool value) => _tvOverride = value;

  static bool get isWeb => kIsWeb;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isIOS => !kIsWeb && Platform.isIOS;

  static bool get isMobile => isAndroid || isIOS;

  static bool get isWindows => !kIsWeb && Platform.isWindows;

  static bool get isMacOS => !kIsWeb && Platform.isMacOS;

  static bool get isLinux => !kIsWeb && Platform.isLinux;

  static bool get isDesktop => isWindows || isMacOS || isLinux;

  static bool get isTv {
    if (_tvOverride != null) return _tvOverride!;
    // 默认不视为 TV，避免 Android 手机被误判为 TV。
    // TV/Windows 入口需在 main 中显式设置 isTvOverride = true。
    return false;
  }
}
