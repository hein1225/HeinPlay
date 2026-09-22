import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 主题模式偏好。
/// - [dark]：强制黑暗主题（默认）。
/// - [light]：强制明亮主题。
/// - [system]：跟随系统亮度。
enum ThemeModePref { dark, light, system }

/// 全局主题模式服务。
/// 持久化用户选择的主题模式，并在模式变化时通知监听者，
/// 使整个应用的 [AppColors] 与 [MaterialApp.themeMode] 同步切换。
class ThemeModeService extends ChangeNotifier {
  static const String _key = 'app_theme_mode';

  static final ThemeModeService instance = ThemeModeService._();

  ThemeModeService._();

  ThemeModePref _pref = ThemeModePref.dark;
  bool _initialized = false;

  /// 当前偏好。
  ThemeModePref get pref => _pref;

  /// 是否处于“跟随系统”模式。
  bool get followSystem => _pref == ThemeModePref.system;

  /// 实际是否使用明亮主题（用于 [AppColors] 解析）。
  /// 在 system 模式下读取平台亮度。
  bool get effectiveIsLight {
    if (_pref == ThemeModePref.light) return true;
    if (_pref == ThemeModePref.dark) return false;
    return PlatformDispatcher.instance.platformBrightness == Brightness.light;
  }

  Brightness get effectiveBrightness =>
      effectiveIsLight ? Brightness.light : Brightness.dark;

  /// 对应 [MaterialApp.themeMode] 的值。
  ThemeMode get themeMode {
    switch (_pref) {
      case ThemeModePref.light:
        return ThemeMode.light;
      case ThemeModePref.dark:
        return ThemeMode.dark;
      case ThemeModePref.system:
        return ThemeMode.system;
    }
  }

  /// 读取已保存的模式。应在应用启动、[MaterialApp] 构建前调用一次。
  Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_key);
    if (saved == 'light') {
      _pref = ThemeModePref.light;
    } else if (saved == 'system') {
      _pref = ThemeModePref.system;
    } else {
      _pref = ThemeModePref.dark;
    }
    _initialized = true;
    // 跟随系统模式下，平台亮度变化时需刷新。
    PlatformDispatcher.instance.onPlatformBrightnessChanged = () {
      if (_pref == ThemeModePref.system) {
        notifyListeners();
      }
    };
    notifyListeners();
  }

  /// 切换主题模式并持久化。
  Future<void> setPref(ThemeModePref pref) async {
    if (_pref == pref) return;
    _pref = pref;
    final prefs = await SharedPreferences.getInstance();
    final value = switch (pref) {
      ThemeModePref.light => 'light',
      ThemeModePref.system => 'system',
      ThemeModePref.dark => 'dark',
    };
    await prefs.setString(_key, value);
    notifyListeners();
  }

  /// 主题切换后请求重启应用（仅 Android 走原生 Activity 重建，使新主题彻底生效、
  /// 无残留浅色；Windows / TV / 手机端不重启，由各 Shell 监听 ThemeModeService
  /// 原地刷新自身）。与 [ThemeSettingsPage] 内联实现保持一致，供远程（手机）切换复用。
  static void requestRestart() {
    if (Platform.isAndroid) {
      try {
        const MethodChannel('hain_tv/app').invokeMethod<void>('restart');
      } catch (e) {
        debugPrint('请求重启应用失败: $e');
      }
    }
  }
}
