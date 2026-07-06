import 'package:shared_preferences/shared_preferences.dart';

enum DoubanDataSource {
  direct,
  cdnTencent,
  cdnAliyun,
  corsProxy,
}

enum PlayerBackendType { mediaKit, videoPlayer, exo }

class UserDataService {
  static const String _serverUrlKey = 'server_url';
  static const String _usernameKey = 'username';
  static const String _passwordKey = 'password';
  static const String _cookiesKey = 'cookies';
  static const String _doubanDataSourceKey = 'app_douban_source';
  static const String _playerBackendKey = 'player_backend';
  static const String _autoSkipOpeningEndingKey = 'auto_skip_opening_ending';
  static const String _autoPlayNextEpisodeKey = 'auto_play_next_episode';
  static const String _defaultQualityKey = 'default_quality';
  static const String _autoSwitchPlayerKey = 'auto_switch_player';
  static const String _autoSwitchSourceKey = 'auto_switch_source';
  static const String _autoSwitchSourceTimeoutKey = 'auto_switch_source_timeout_seconds';
  static const String _skippedVersionKey = 'skipped_update_version';
  static const String _perVideoPlayerBackendPrefix = 'per_video_player_backend_';
  // 与 Selene 保持一致，方便共用已配置的代理
  static const String _m3u8ProxyUrlKey = 'm3u8_proxy_url';

  static Future<void> saveUserData({
    required String serverUrl,
    required String username,
    required String password,
    required String cookies,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, serverUrl);
    await prefs.setString(_usernameKey, username);
    await prefs.setString(_passwordKey, password);
    await prefs.setString(_cookiesKey, cookies);
  }

  static Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrlKey);
  }

  static Future<String?> getUsername() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  static Future<String?> getPassword() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_passwordKey);
  }

  static Future<String?> getCookies() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cookiesKey);
  }

  static Future<bool> isLoggedIn() async {
    final cookies = await getCookies();
    return cookies != null && cookies.isNotEmpty;
  }

  static Future<void> clearUserData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrlKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);
    await prefs.remove(_cookiesKey);
  }

  static Future<Map<String, String?>> getAllUserData() async {
    final prefs = await SharedPreferences.getInstance();
    return {
      'serverUrl': prefs.getString(_serverUrlKey),
      'username': prefs.getString(_usernameKey),
      'password': prefs.getString(_passwordKey),
      'cookies': prefs.getString(_cookiesKey),
    };
  }

  static Future<bool> hasAutoLoginData() async {
    final data = await getAllUserData();
    return data.values.every((v) => v != null && v.isNotEmpty);
  }

  static Future<void> saveDoubanDataSource(DoubanDataSource source) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_doubanDataSourceKey, source.index);
  }

  static Future<DoubanDataSource> getDoubanDataSource() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_doubanDataSourceKey);
    if (index != null && index >= 0 && index < DoubanDataSource.values.length) {
      return DoubanDataSource.values[index];
    }
    return DoubanDataSource.direct;
  }

  static Future<void> savePlayerBackend(PlayerBackendType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_playerBackendKey, type.name);
  }

  static Future<PlayerBackendType> getPlayerBackend() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_playerBackendKey) ?? 'exo';
    return PlayerBackendType.values.firstWhere(
      (e) => e.name == key,
      orElse: () => PlayerBackendType.exo,
    );
  }

  static Future<void> saveAutoSkipOpeningEnding(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSkipOpeningEndingKey, enabled);
  }

  static Future<bool> getAutoSkipOpeningEnding() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSkipOpeningEndingKey) ?? true;
  }

  static Future<void> saveAutoPlayNextEpisode(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoPlayNextEpisodeKey, enabled);
  }

  static Future<bool> getAutoPlayNextEpisode() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoPlayNextEpisodeKey) ?? true;
  }

  static Future<void> saveDefaultQuality(String quality) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_defaultQualityKey, quality);
  }

  static Future<String> getDefaultQuality() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_defaultQualityKey) ?? '自动';
  }

  static Future<void> saveAutoSwitchPlayer(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSwitchPlayerKey, enabled);
  }

  static Future<bool> getAutoSwitchPlayer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSwitchPlayerKey) ?? true;
  }

  static Future<void> saveAutoSwitchSource(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSwitchSourceKey, enabled);
  }

  static Future<bool> getAutoSwitchSource() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSwitchSourceKey) ?? true;
  }

  static Future<void> saveAutoSwitchSourceTimeout(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_autoSwitchSourceTimeoutKey, seconds);
  }

  static Future<int> getAutoSwitchSourceTimeout() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_autoSwitchSourceTimeoutKey) ?? 15;
  }

  static Future<void> saveM3u8ProxyUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_m3u8ProxyUrlKey, url.trim());
  }

  static Future<String> getM3u8ProxyUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_m3u8ProxyUrlKey) ?? '';
  }

  static String _perVideoBackendKey(String source, String id) {
    return '$_perVideoPlayerBackendPrefix${source}_$id';
  }

  static Future<void> savePlayerBackendForVideo(
    String source,
    String id,
    PlayerBackendType type,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_perVideoBackendKey(source, id), type.name);
  }

  static Future<PlayerBackendType> getPlayerBackendForVideo(
    String source,
    String id, {
    PlayerBackendType fallback = PlayerBackendType.exo,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final key = _perVideoBackendKey(source, id);
    final name = prefs.getString(key);
    if (name == null || name.isEmpty) return fallback;
    return PlayerBackendType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => fallback,
    );
  }

  static Future<void> saveSkippedVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_skippedVersionKey, version);
  }

  static Future<String?> getSkippedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_skippedVersionKey);
  }
}
