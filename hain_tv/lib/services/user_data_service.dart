import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

enum DoubanDataSource { direct, cdnTencent, cdnAliyun, corsProxy }

enum PlayerBackendType { exo, fvp, vlc }

enum BufferProfile { standard, enhanced, power, lowLatency }

enum BangumiApiProxyType { direct, cmliussss, custom }

enum BangumiImageProxyType { direct, cmliussss, custom }

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
  static const String _autoSwitchSourceTimeoutKey =
      'auto_switch_source_timeout_seconds';
  static const String _skippedVersionKey = 'skipped_update_version';
  static const String _lastUpdateCheckTimeKey = 'last_update_check_time';
  static const String _perVideoPlayerBackendPrefix =
      'per_video_player_backend_';
  static const String _homeFirstEntryCompletedKey =
      'home_first_entry_completed';
  // M3U8 代理地址存储键
  static const String _m3u8ProxyUrlKey = 'm3u8_proxy_url';
  static const String _hardwareDecodingKey = 'hardware_decoding';
  static const String _bufferProfileKey = 'buffer_profile';

  // Bangumi 代理设置
  static const String _bangumiApiProxyTypeKey = 'bangumi_api_proxy_type';
  static const String _bangumiApiProxyUrlKey = 'bangumi_api_proxy_url';
  static const String _bangumiImageProxyTypeKey = 'bangumi_image_proxy_type';
  static const String _bangumiImageProxyUrlKey = 'bangumi_image_proxy_url';

  // 内存缓存，便于图片代理在 build 阶段同步读取
  static BangumiApiProxyType? _cachedBangumiApiProxyType;
  static String? _cachedBangumiApiProxyUrl;
  static BangumiImageProxyType? _cachedBangumiImageProxyType;
  static String? _cachedBangumiImageProxyUrl;

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

  static PlayerBackendType get _platformDefaultBackend {
    if (Platform.isWindows) return PlayerBackendType.fvp;
    return PlayerBackendType.exo;
  }

  static Future<PlayerBackendType> getPlayerBackend() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_playerBackendKey);
    if (key == null || key.isEmpty) return _platformDefaultBackend;
    return PlayerBackendType.values.firstWhere(
      (e) => e.name == key,
      orElse: () => _platformDefaultBackend,
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
    var value = prefs.getInt(_autoSwitchSourceTimeoutKey) ?? 15;
    // 旧版本允许选择 5 秒，现最短为 10 秒，自动迁移旧配置
    if (value < 10) {
      value = 10;
      await prefs.setInt(_autoSwitchSourceTimeoutKey, value);
    }
    return value;
  }

  static Future<void> saveM3u8ProxyUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_m3u8ProxyUrlKey, url.trim());
  }

  static Future<String> getM3u8ProxyUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_m3u8ProxyUrlKey) ?? '';
  }

  static Future<void> saveHardwareDecoding(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hardwareDecodingKey, enabled);
  }

  static Future<bool> getHardwareDecoding() async {
    final prefs = await SharedPreferences.getInstance();
    // 默认开启硬件解码，用户可在播放器设置中手动关闭。
    return prefs.getBool(_hardwareDecodingKey) ?? true;
  }

  static Future<void> saveBufferProfile(BufferProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_bufferProfileKey, profile.index);
  }

  static Future<BufferProfile> getBufferProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_bufferProfileKey);
    if (index != null &&
        index >= 0 &&
        index < BufferProfile.values.length) {
      return BufferProfile.values[index];
    }
    return BufferProfile.standard;
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
    PlayerBackendType? fallback,
  }) async {
    final effectiveFallback = fallback ?? _platformDefaultBackend;
    final prefs = await SharedPreferences.getInstance();
    final key = _perVideoBackendKey(source, id);
    final name = prefs.getString(key);
    if (name == null || name.isEmpty) return effectiveFallback;
    return PlayerBackendType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => effectiveFallback,
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

  static Future<void> saveLastUpdateCheckTime(DateTime time) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_lastUpdateCheckTimeKey, time.millisecondsSinceEpoch);
  }

  static Future<DateTime?> getLastUpdateCheckTime() async {
    final prefs = await SharedPreferences.getInstance();
    final ms = prefs.getInt(_lastUpdateCheckTimeKey);
    if (ms == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ms);
  }

  /// 是否已完成首次进入首页的全量刷新。
  static Future<bool> isHomeFirstEntryCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_homeFirstEntryCompletedKey) ?? false;
  }

  /// 标记首次进入首页的全量刷新已完成。
  static Future<void> markHomeFirstEntryCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_homeFirstEntryCompletedKey, true);
  }

  /// 重置首次进入首页刷新标记，用于每次 App 启动后强制重新从云端刷新。
  static Future<void> resetHomeFirstEntryCompleted() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_homeFirstEntryCompletedKey, false);
  }

  // ===================== Bangumi 代理设置 =====================

  static BangumiApiProxyType? get cachedBangumiApiProxyType =>
      _cachedBangumiApiProxyType;
  static String? get cachedBangumiApiProxyUrl => _cachedBangumiApiProxyUrl;
  static BangumiImageProxyType? get cachedBangumiImageProxyType =>
      _cachedBangumiImageProxyType;
  static String? get cachedBangumiImageProxyUrl => _cachedBangumiImageProxyUrl;

  static Future<void> reloadBangumiProxyCache() async {
    _cachedBangumiApiProxyType = await getBangumiApiProxyType();
    _cachedBangumiApiProxyUrl = await getBangumiApiProxyUrl();
    _cachedBangumiImageProxyType = await getBangumiImageProxyType();
    _cachedBangumiImageProxyUrl = await getBangumiImageProxyUrl();
  }

  static Future<BangumiApiProxyType> getBangumiApiProxyType() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_bangumiApiProxyTypeKey);
    if (index != null &&
        index >= 0 &&
        index < BangumiApiProxyType.values.length) {
      return BangumiApiProxyType.values[index];
    }
    return BangumiApiProxyType.cmliussss;
  }

  static Future<void> saveBangumiApiProxyType(BangumiApiProxyType value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_bangumiApiProxyTypeKey, value.index);
    _cachedBangumiApiProxyType = value;
  }

  static Future<String> getBangumiApiProxyUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_bangumiApiProxyUrlKey) ?? '';
  }

  static Future<void> saveBangumiApiProxyUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bangumiApiProxyUrlKey, url.trim());
    _cachedBangumiApiProxyUrl = url.trim();
  }

  static Future<BangumiImageProxyType> getBangumiImageProxyType() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_bangumiImageProxyTypeKey);
    if (index != null &&
        index >= 0 &&
        index < BangumiImageProxyType.values.length) {
      return BangumiImageProxyType.values[index];
    }
    return BangumiImageProxyType.cmliussss;
  }

  static Future<void> saveBangumiImageProxyType(
    BangumiImageProxyType value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_bangumiImageProxyTypeKey, value.index);
    _cachedBangumiImageProxyType = value;
  }

  static Future<String> getBangumiImageProxyUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_bangumiImageProxyUrlKey) ?? '';
  }

  static Future<void> saveBangumiImageProxyUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_bangumiImageProxyUrlKey, url.trim());
    _cachedBangumiImageProxyUrl = url.trim();
  }
}
