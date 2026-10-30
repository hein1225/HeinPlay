import 'package:shared_preferences/shared_preferences.dart';

class AdFilterService {
  static const String _adFilterEnabledKey = 'ad_filter_enabled';

  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    // 默认关闭，避免默认规则误伤正常播放；用户可在设置中手动开启
    return prefs.getBool(_adFilterEnabledKey) ?? false;
  }

  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_adFilterEnabledKey, enabled);
  }
}
