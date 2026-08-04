import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_info.dart';

enum DoubanDataSource { direct, cdnTencent, cdnAliyun, corsProxy }

enum PlayerBackendType { exo, fvp, vlc }

enum BufferProfile { standard, enhanced, power, lowLatency }

enum BangumiApiProxyType { direct, cmliussss, custom }

enum BangumiImageProxyType { direct, cmliussss, custom }

class UserDataService {
  static const String _serverUrlKey = 'server_url';
  static const String _backupServerUrlKey = 'backup_server_url';
  static const String _lastSelectedServerUrlKey = 'last_selected_server_url';
  static const String _usernameKey = 'username';
  static const String _passwordKey = 'password';
  static const String _cookiesKey = 'cookies';
  static const String _mainAccountKey = 'main_account';
  static const String _subAccountKey = 'sub_account';
  static const String _activeAccountKey = 'active_account';
  static const String _windowsFullscreenAlwaysOnTopKey =
      'windows_fullscreen_always_on_top';
  static const String _windowsMiniPlayerEnabledKey = 'windows_mini_player_enabled';
  static const String _autoSelectLowLatencyServerKey =
      'auto_select_low_latency_server';
  static const String _doubanDataSourceKey = 'app_douban_source';
  static const String _playerBackendKey = 'player_backend';
  static const String _autoSkipOpeningEndingKey = 'auto_skip_opening_ending';
  static const String _autoPlayNextEpisodeKey = 'auto_play_next_episode';
  static const String _defaultQualityKey = 'default_quality';
  static const String _autoSwitchPlayerKey = 'auto_switch_player';
  static const String _autoSwitchSourceKey = 'auto_switch_source';
  static const String _autoSwitchSourceTimeoutKey =
      'auto_switch_source_timeout_seconds';
  static const String _autoSpeedTestKey = 'auto_speed_test';
  static const String _logEnabledKey = 'log_enabled';
  static const String _skippedVersionKey = 'skipped_update_version';
  static const String _lastUpdateCheckTimeKey = 'last_update_check_time';
  static const String _defaultUpdateChannelKey = 'default_update_channel';
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

    // 同时写入新账号模型，保持新旧数据一致，便于后续逐步迁移。
    final activeType = await getActiveAccount();
    final account = AccountInfo(
      username: username,
      password: password,
      cookies: cookies,
    );
    if (activeType == 'sub') {
      await saveSubAccount(account);
    } else {
      await saveMainAccount(account);
    }
  }

  static Future<String?> getServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_serverUrlKey);
  }

  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url.trim());
  }

  static Future<void> saveBackupServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backupServerUrlKey, url.trim());
  }

  static Future<String> getBackupServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_backupServerUrlKey) ?? '';
  }

  static Future<void> saveLastSelectedServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSelectedServerUrlKey, url.trim());
  }

  static Future<String?> getLastSelectedServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_lastSelectedServerUrlKey);
  }

  static Future<void> clearLastSelectedServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_lastSelectedServerUrlKey);
  }

  /// 判断当前连接的服务器类型，返回 'internet' 或 'lan'。
  static Future<String> getCurrentServerType() async {
    final primary = await getServerUrl();
    final backup = await getBackupServerUrl();
    final selected = await getLastSelectedServerUrl();
    final effective = selected ?? primary ?? '';
    if (effective.isEmpty) return 'internet';

    String normalize(String url) {
      return url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
    }

    final normalized = normalize(effective);
    final normalizedBackup = normalize(backup);
    if (normalizedBackup.isNotEmpty && normalized == normalizedBackup) {
      return 'lan';
    }
    return 'internet';
  }

  static Future<String?> getUsername() async {
    final account = await getCurrentAccount();
    if (account != null) return account.username;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_usernameKey);
  }

  static Future<String?> getPassword() async {
    final account = await getCurrentAccount();
    if (account != null) return account.password;
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_passwordKey);
  }

  static Future<String?> getCookies() async {
    final account = await getCurrentAccount();
    if (account != null && account.cookies.isNotEmpty) {
      return account.cookies;
    }
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_cookiesKey);
  }

  static Future<bool> isLoggedIn() async {
    final cookies = await getCookies();
    return cookies != null && cookies.isNotEmpty;
  }

  /// 退出登录时仅清除当前账号的 Cookie，保留账号名/密码便于再次登录。
  static Future<void> clearUserData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cookiesKey);
    await clearCurrentAccountCookies();
  }

  /// 清除所有账号与服务器数据（谨慎使用）。
  static Future<void> clearAllUserData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_serverUrlKey);
    await prefs.remove(_backupServerUrlKey);
    await prefs.remove(_lastSelectedServerUrlKey);
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);
    await prefs.remove(_cookiesKey);
    await prefs.remove(_mainAccountKey);
    await prefs.remove(_subAccountKey);
    await prefs.remove(_activeAccountKey);
  }

  static Future<Map<String, String?>> getAllUserData() async {
    final prefs = await SharedPreferences.getInstance();
    final account = await getCurrentAccount();
    return {
      'serverUrl': prefs.getString(_serverUrlKey),
      'username': account?.username ?? prefs.getString(_usernameKey),
      'password': account?.password ?? prefs.getString(_passwordKey),
      'cookies': account?.cookies ?? prefs.getString(_cookiesKey),
    };
  }

  static Future<bool> hasAutoLoginData() async {
    final data = await getAllUserData();
    return data.values.every((v) => v != null && v.isNotEmpty);
  }

  // ===================== 账号槽位管理 =====================

  static Future<void> saveMainAccount(AccountInfo account) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_mainAccountKey, json.encode(account.toJson()));
  }

  static Future<AccountInfo?> getMainAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_mainAccountKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return AccountInfo.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> saveSubAccount(AccountInfo account) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_subAccountKey, json.encode(account.toJson()));
  }

  static Future<AccountInfo?> getSubAccount() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_subAccountKey);
    if (raw == null || raw.isEmpty) return null;
    try {
      return AccountInfo.fromJson(json.decode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  static Future<void> setActiveAccount(String type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_activeAccountKey, type == 'sub' ? 'sub' : 'main');
  }

  static Future<String> getActiveAccount() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_activeAccountKey) ?? 'main';
  }

  static Future<AccountInfo?> getCurrentAccount() async {
    final type = await getActiveAccount();
    return type == 'sub' ? await getSubAccount() : await getMainAccount();
  }

  static Future<void> clearCurrentAccountCookies() async {
    final type = await getActiveAccount();
    if (type == 'sub') {
      final account = await getSubAccount();
      if (account != null) {
        await saveSubAccount(account.copyWith(cookies: ''));
      }
    } else {
      final account = await getMainAccount();
      if (account != null) {
        await saveMainAccount(account.copyWith(cookies: ''));
      }
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_cookiesKey);
  }

  /// 首次启动 v1.2.0 时将旧键 username/password/cookies 迁移到 main_account，
  /// 并将旧版单一服务器地址按域名/IP 区分导入到互联网/局域网服务器。
  static Future<void> migrateLegacyAccount() async {
    final mainAccount = await getMainAccount();
    final prefs = await SharedPreferences.getInstance();
    final username = prefs.getString(_usernameKey);
    final password = prefs.getString(_passwordKey);
    final cookies = prefs.getString(_cookiesKey);

    if ((mainAccount == null || mainAccount.password.isEmpty) &&
        password != null &&
        password.isNotEmpty) {
      await saveMainAccount(AccountInfo(
        username: username ?? '',
        password: password,
        cookies: cookies ?? '',
      ));
      await setActiveAccount('main');
      await clearLegacyAccountData();
    }

    // 迁移旧版单一服务器地址：域名保留在互联网服务器，IP 地址迁移到局域网服务器。
    final legacyServerUrl = prefs.getString(_serverUrlKey);
    if (legacyServerUrl != null && legacyServerUrl.trim().isNotEmpty) {
      final url = legacyServerUrl.trim();
      if (isIpAddress(url)) {
        final backup = await getBackupServerUrl();
        if (backup.isEmpty) {
          await saveBackupServerUrl(url);
          await prefs.remove(_serverUrlKey);
          await clearLastSelectedServerUrl();
        }
      } else {
        // 域名地址已保存在 _serverUrlKey（互联网服务器），无需移动。
        // 清除可能指向旧地址的选中记录，让启动测速/连接逻辑重新选择。
        await clearLastSelectedServerUrl();
      }
    }
  }

  /// 将用户输入的主/备服务器地址按 IP/域名分类。
  /// IP 地址归入局域网服务器，域名归入互联网服务器，确保登录后地址显示在正确位置。
  static ({String internet, String lan}) classifyServerUrls(
    String primaryUrl,
    String backupUrl,
  ) {
    final primaryIsIp = primaryUrl.isNotEmpty && isIpAddress(primaryUrl);
    final backupIsIp = backupUrl.isNotEmpty && isIpAddress(backupUrl);

    // 主输入框是 IP、备用输入框是域名：互换，让域名去互联网服务器。
    if (primaryIsIp && backupUrl.isNotEmpty && !backupIsIp) {
      return (internet: backupUrl, lan: primaryUrl);
    }

    // 主输入框是 IP：归入局域网服务器。
    if (primaryIsIp) {
      return (internet: '', lan: primaryUrl);
    }

    return (internet: primaryUrl, lan: backupUrl);
  }

  /// 判断服务器地址的主机部分是否为 IPv4/IPv6 地址。
  static bool isIpAddress(String url) {
    try {
      final uri = Uri.parse(url);
      final host = uri.host;
      if (host.isEmpty) return false;
      // 简单 IPv4 正则校验。
      final ipv4RegExp = RegExp(
        r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$',
      );
      if (ipv4RegExp.hasMatch(host)) {
        return host.split('.').every((part) {
          final n = int.tryParse(part);
          return n != null && n >= 0 && n <= 255;
        });
      }
      // IPv6 包含冒号即可识别。
      if (host.contains(':')) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 仅删除旧账号键，保留服务器地址等全局键。
  static Future<void> clearLegacyAccountData() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_usernameKey);
    await prefs.remove(_passwordKey);
    await prefs.remove(_cookiesKey);
  }

  // ===================== Windows 窗口设置 =====================

  static Future<bool> getWindowsFullscreenAlwaysOnTop() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_windowsFullscreenAlwaysOnTopKey) ?? false;
  }

  static Future<void> setWindowsFullscreenAlwaysOnTop(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_windowsFullscreenAlwaysOnTopKey, value);
  }

  static Future<bool> getWindowsMiniPlayerEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_windowsMiniPlayerEnabledKey) ?? false;
  }

  static Future<void> setWindowsMiniPlayerEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_windowsMiniPlayerEnabledKey, value);
  }

  // ===================== 服务器自动测速开关 =====================

  static Future<bool> getAutoSelectLowLatencyServer() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_autoSelectLowLatencyServerKey) ?? true;
  }

  static Future<void> setAutoSelectLowLatencyServer(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSelectLowLatencyServerKey, value);
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

  static Future<void> saveAutoSpeedTest(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_autoSpeedTestKey, enabled);
  }

  static Future<bool> getAutoSpeedTest() async {
    final prefs = await SharedPreferences.getInstance();
    // 默认开启自动测速，与历史行为保持一致。
    return prefs.getBool(_autoSpeedTestKey) ?? true;
  }

  static Future<void> saveLogEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_logEnabledKey, enabled);
  }

  static Future<bool> getLogEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    // 默认关闭文件日志，避免长期占用存储。
    return prefs.getBool(_logEnabledKey) ?? false;
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

  /// 获取默认更新渠道：'domestic' 或 'github'，未设置时默认返回 'domestic'。
  static Future<String> getDefaultUpdateChannel() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_defaultUpdateChannelKey) ?? 'domestic';
  }

  /// 保存默认更新渠道：'domestic' 或 'github'。
  static Future<void> saveDefaultUpdateChannel(String channel) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_defaultUpdateChannelKey, channel);
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
