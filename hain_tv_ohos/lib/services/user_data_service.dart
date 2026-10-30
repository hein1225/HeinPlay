import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_info.dart';
import '../player/video_render_mode.dart';
import 'glass_style_service.dart';

enum DoubanDataSource { direct, cdnTencent, cdnAliyun, corsProxy }

/// 播放后端类型。
///
/// 🔴 2026-10-06：鸿蒙工程实际可用的是 [mpv]、[avplayer] 两个（见
/// `player/player_backend_factory.dart` 的 `availableBackends`）：
/// - [mpv]：基于 @mpv-ohos/mpv-arkts 的 libmpv 封装，硬解 ohcodec + ohaudio、
///   续播语义正确（首帧就绪后 seek），已真机验证点播/直播均正常（平台默认）。
/// - [avplayer]：鸿蒙原生 AVPlayer 系统播放器，硬解省电、起播快，
///   与安卓的 ExoPlayer 后端定位对等（保留作系统原生兜底）。
///
/// [fvp]、[exo]、[vlc] 为历史/未来值保留（后续跨平台阶段复用）：在鸿蒙上 fvp 已移除、
/// exo/vlc 无运行时，工厂会自动归一化回落到 [mpv] 并写回设置。
enum PlayerBackendType { exo, fvp, vlc, avplayer, mpv }

enum BufferProfile { standard, enhanced, power, lowLatency }

enum BangumiApiProxyType { direct, cmliussss, custom }

enum BangumiImageProxyType { direct, cmliussss, custom }

enum InternetServerDnsPreference { ipv4, ipv6, any }

class UserDataService {
  static const String _serverUrlKey = 'server_url';
  static const String _backupServerUrlKey = 'backup_server_url';
  static const String _lastSelectedServerUrlKey = 'last_selected_server_url';
  static const String _internetServerDnsPreferenceKey =
      'internet_server_dns_preference';
  static const String _usernameKey = 'username';
  static const String _passwordKey = 'password';
  static const String _cookiesKey = 'cookies';
  static const String _mainAccountKey = 'main_account';
  static const String _subAccountKey = 'sub_account';
  static const String _activeAccountKey = 'active_account';
  static const String _windowsFullscreenAlwaysOnTopKey =
      'windows_fullscreen_always_on_top';
  static const String _windowsMiniPlayerEnabledKey =
      'windows_mini_player_enabled';
  static const String _autoSelectLowLatencyServerKey =
      'auto_select_low_latency_server';
  static const String _doubanDataSourceKey = 'app_douban_source';
  static const String _playerBackendKey = 'player_backend';
  static const String _livePlayerBackendKey = 'live_player_backend';
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
  // 🔴 2026-10-07：'hardware_decoding' 键随「硬件解码」开关一并废弃（不再读写）。
  static const String _bufferProfileKey = 'buffer_profile';
  // 渲染方式（SurfaceView / TextureView）—— 点播、直播区分存储。
  // 🔴 2026-10-07 新增：鸿蒙当前两后端仅纹理可用，surface 为预留档（选它回落纹理并标注）。
  static const String _vodRenderModeKey = 'vod_render_mode';
  static const String _liveRenderModeKey = 'live_render_mode';

  // 沉浸式磨砂玻璃导航栏（默认开启）。
  // 🔴 2026-10-07 新增：底部导航栏背景由纯色改为 BackdropFilter 高斯模糊＋半透明，
  // 让内容光线透出形成沉浸光感。仅做视觉层，不影响播放。
  static const String _glassNavBarEnabledKey = 'glass_nav_bar_enabled';
  // 🔴 2026-10-07 新增：磨砂玻璃透明度档位（强/中/弱/关），同时作用于底部导航栏
  // 与分类页顶部分类导航。string 存储 GlassLevel.name；缺省/非法值回落「中」。
  static const String _glassLevelKey = 'glass_level';

  // 直播设置
  static const String _lunaTvLiveEnabledKey = 'lunatv_live_enabled';
  static const String _liveSourceCacheHoursKey = 'live_source_cache_hours';
  static const String _epgLoadEnabledKey = 'epg_load_enabled';
  // 本地 M3U8 代理总开关：开启时点播 M3U8 经由本地代理（统一请求头/去广告），
  // 关闭时直接播放原始地址。直播默认直连，不受此开关影响。
  static const String _localProxyEnabledKey = 'local_proxy_enabled';
  // HLS 并发分片预取开关（借鉴 LunaTV OptimizedHlsLoader）。开启后鸿蒙端强制走
  // 本地 M3U8 代理透传，并由 LocalM3u8Proxy 在播放当前分片时并发预取后续分片，
  // 加速弱网/换段缓冲。独立于去广告，默认关闭。
  static const String _hlsPrefetchEnabledKey = 'hls_prefetch_enabled';
  // 无缝换台：换台时先在后台预载目标频道，就绪（或超时）后再切换画面。
  static const String _seamlessChannelSwitchKey = 'seamless_channel_switch';
  // FCC 快速换台：读取直播源中的 FCC 地址进行快速换台。
  static const String _fccFastSwitchKey = 'fcc_fast_switch';

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

  static Future<InternetServerDnsPreference>
  getInternetServerDnsPreference() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_internetServerDnsPreferenceKey);
    // 默认优先解析 IPv4，避免在 IPv6 不完整网络下因系统 Happy Eyeballs 等待过久而加载慢。
    if (index == null) return InternetServerDnsPreference.ipv4;
    return InternetServerDnsPreference.values[index];
  }

  static Future<void> saveInternetServerDnsPreference(
    InternetServerDnsPreference value,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_internetServerDnsPreferenceKey, value.index);
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
      await saveMainAccount(
        AccountInfo(
          username: username ?? '',
          password: password,
          cookies: cookies ?? '',
        ),
      );
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

    // 2026-10-08 移除：原此处调用 migrateLivePlayerBackendDefault()
    // （ExoPlayer -> fvp 的直播默认后端迁移）。该迁移早已退化为**空操作** ——
    // 函数体只剩「读标记 → 写标记 true」，真正的默认值由
    // [_platformDefaultLiveBackend] 直接提供。它唯一的可见副作用是：每次启动都
    // 往 SharedPreferences 写一个名为 `live_player_backend_migrated_to_fvp` 的键，
    // 而 SharedPreferencesOhosPlugin 会回显全部键值 —— 于是日志里每次启动都出现
    // 一行含 `fvp` 的记录，排查时极易被误认为「已移除的 fvp 后端还在跑」。
    // 迁移标记本身也已无意义（无任何读取方决定行为），故一并清理。
    await prefs.remove(_livePlayerBackendMigratedKey);
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

  /// 点播默认后端。
  ///
  /// 🔴 2026-10-23：鸿蒙（ohos）默认改为 **avplayer**（系统原生 AVPlayer，
  ///   起播快、兼容性最稳），mpv 退为备选（仅用户显式切换时）。
  /// 🔴 2026-10-06：鸿蒙此前默认改为 mpv（libmpv）；fvp 已从鸿蒙移除。
  ///
  /// ⚠️ 下方 Windows / Linux 分支是 `hain_tv_ohos` 工程里的**死代码**
  ///   （本工程只构建 ohos 产物），保留仅为兼容源码共享时的编译。
  ///   其中的 `fvp` 已全平台退役，若本工程将来真的要出桌面包，须先改成 mpv。
  static PlayerBackendType get _platformDefaultBackend {
    if (Platform.operatingSystem == 'ohos') return PlayerBackendType.avplayer;
    if (Platform.isWindows || Platform.isLinux) return PlayerBackendType.fvp;
    return PlayerBackendType.exo;
  }

  /// 直播默认后端：Android / TV 默认 ExoPlayer；HarmonyOS 默认 avplayer。
  ///
  /// 🔴 2026-10-23：鸿蒙直播默认由 mpv 改为 **avplayer**（与点播一致）。
  /// ⚠️ 下方 Linux 分支同为死代码，其 `fvp` 已全平台退役。
  static PlayerBackendType get _platformDefaultLiveBackend {
    if (Platform.operatingSystem == 'ohos') return PlayerBackendType.avplayer;
    if (Platform.isLinux) return PlayerBackendType.fvp;
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

  static Future<void> saveLivePlayerBackend(PlayerBackendType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_livePlayerBackendKey, type.name);
  }

  static Future<PlayerBackendType> getLivePlayerBackend() async {
    final prefs = await SharedPreferences.getInstance();
    final key = prefs.getString(_livePlayerBackendKey);
    if (key == null || key.isEmpty) return _platformDefaultLiveBackend;
    return PlayerBackendType.values.firstWhere(
      (e) => e.name == key,
      orElse: () => _platformDefaultLiveBackend,
    );
  }

  /// 【已废弃·仅用于清理】直播默认后端历史迁移（ExoPlayer -> fvp）遗留的
  /// SharedPreferences 键名。迁移逻辑已于 2026-10-08 删除（它早已是空操作），
  /// 但旧装机上该键仍存在，会在每次启动被插件回显到日志里。保留常量只为在
  /// [_migrateAccountIfNeeded] 中把它移除。
  static const String _livePlayerBackendMigratedKey =
      'live_player_backend_migrated_to_fvp';

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

  // 🔴 2026-10-07：删除「硬件解码」读写接口。
  //   用户决定不再提供硬解/软解开关 —— mpv 始终优先硬解，黑屏时由播放页
  //   看门狗自动回退软解（见 player_screen.dart 的 _handleHwdecNoFrame）。
  //   原先存于 prefs 的 'hardware_decoding' 键不再被读取（遗留值无害）。

  static Future<void> saveBufferProfile(BufferProfile profile) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_bufferProfileKey, profile.index);
  }

  static Future<BufferProfile> getBufferProfile() async {
    final prefs = await SharedPreferences.getInstance();
    final index = prefs.getInt(_bufferProfileKey);
    if (index != null && index >= 0 && index < BufferProfile.values.length) {
      return BufferProfile.values[index];
    }
    return BufferProfile.standard;
  }

  /// 点播渲染方式（默认 TextureView）。
  static Future<void> saveVodRenderMode(VideoRenderMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_vodRenderModeKey, mode.name);
  }

  static Future<VideoRenderMode> getVodRenderMode() async {
    final prefs = await SharedPreferences.getInstance();
    return _parseRenderMode(prefs.getString(_vodRenderModeKey));
  }

  /// 直播渲染方式（默认 TextureView）。
  static Future<void> saveLiveRenderMode(VideoRenderMode mode) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_liveRenderModeKey, mode.name);
  }

  static Future<VideoRenderMode> getLiveRenderMode() async {
    final prefs = await SharedPreferences.getInstance();
    return _parseRenderMode(prefs.getString(_liveRenderModeKey));
  }

  static VideoRenderMode _parseRenderMode(String? raw) {
    if (raw != null) {
      for (final m in VideoRenderMode.values) {
        if (m.name == raw) return m;
      }
    }
    // 默认 TextureView。
    return VideoRenderMode.texture;
  }

  /// 沉浸式磨砂玻璃导航栏是否开启（默认关闭）。
  ///
  /// 【2026-10-07 变更】默认值由 true 改为 false，与 [getGlassLevel] 的默认
  /// 「关」保持一致。当前 UI 已统一改用档位 [getGlassLevel]，本布尔开关保留
  /// 仅为兼容旧版本读写的 `glass_nav_bar_enabled` 键。
  static Future<bool> getGlassNavBarEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_glassNavBarEnabledKey) ?? false;
  }

  static Future<void> saveGlassNavBarEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_glassNavBarEnabledKey, enabled);
  }

  /// 磨砂玻璃透明度档位（强/中/弱/关）。**默认「关」**。
  ///
  /// 【2026-10-07 变更】默认档位由「中」改为「关」：磨砂玻璃使用高斯模糊实时
  /// 渲染，对 GPU 与电量有持续开销，改为默认关闭、由用户在设置里主动开启。
  ///
  /// 兼容旧版「沉浸式磨砂导航栏」布尔开关：若旧开关被用户显式关闭且尚未设置过
  /// 档位，同样回落「关」，保持旧用户关闭磨砂的意向不被新档位意外覆盖。
  static Future<GlassLevel> getGlassLevel() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_glassLevelKey);
    if (raw != null) {
      return GlassLevel.values.firstWhere(
        (l) => l.name == raw,
        orElse: () => GlassLevel.off,
      );
    }
    return GlassLevel.off;
  }

  static Future<void> saveGlassLevel(GlassLevel level) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_glassLevelKey, level.name);
  }

  static Future<void> saveLunaTvLiveEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_lunaTvLiveEnabledKey, enabled);
  }

  static Future<bool> getLunaTvLiveEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_lunaTvLiveEnabledKey) ?? true;
  }

  /// 直播源缓存时间（小时），默认 24 小时（1 天）。
  static Future<int> getLiveSourceCacheHours() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_liveSourceCacheHoursKey) ?? 24;
  }

  /// 保存直播源缓存时间（小时）。
  static Future<void> saveLiveSourceCacheHours(int hours) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_liveSourceCacheHoursKey, hours);
  }

  /// 是否加载 EPG 节目单（含时移 catchup 信息），默认开启。
  ///
  /// 关闭后进入直播页只拉取频道列表并立即播放，不在后台拉取节目单/时移元数据，
  /// 以降低直播连接耗时；开启时（默认）频道列表就绪后立即开播，
  /// 节目单与时移信息在后台异步加载并刷新。
  static Future<bool> getEpgLoadEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_epgLoadEnabledKey) ?? true;
  }

  static Future<void> saveEpgLoadEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_epgLoadEnabledKey, enabled);
  }

  /// 本地 M3U8 代理总开关，默认开启。
  ///
  /// 关闭后点播 M3U8 直接播放原始地址，不经过本地代理；用于排查代理导致的
  /// 播放卡顿/兼容问题（例如部分设备对本地代理不兼容时）。
  static Future<bool> getLocalProxyEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_localProxyEnabledKey) ?? false;
  }

  static Future<void> saveLocalProxyEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_localProxyEnabledKey, enabled);
  }

  /// HLS 并发分片预取开关（借鉴 LunaTV OptimizedHlsLoader）。
  ///
  /// 默认关闭：预取会额外消耗带宽（并发下载后续分片），且需走本地代理透传，
  /// 故保守默认关闭，由用户在「播放设置」中按需开启。开启后鸿蒙端强制走本地
  /// 代理透传，并由 LocalM3u8Proxy 并发预取后续分片。
  static Future<bool> getHlsPrefetchEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hlsPrefetchEnabledKey) ?? false;
  }

  static Future<void> saveHlsPrefetchEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hlsPrefetchEnabledKey, enabled);
  }

  /// 无缝换台总开关，默认关闭。
  ///
  /// 开启后换台不会立即黑屏：当前频道画面保持播放，目标频道在后台预载，
  /// 首帧就绪（或达到 [seamlessSwitchTimeoutMs] 超时）后再切换画面。
  /// 注意：预载期间会同时解码两路直播流，消耗更多流量与设备性能。
  /// 关闭时恢复传统换台（立即切换、期间黑屏加载）。
  static Future<bool> getSeamlessChannelSwitch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_seamlessChannelSwitchKey) ?? false;
  }

  static Future<void> saveSeamlessChannelSwitch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_seamlessChannelSwitchKey, enabled);
  }

  /// 无缝换台预载超时（毫秒）。超时后无论是否就绪都立即切换，避免久等。
  static const int seamlessSwitchTimeoutMs = 3000;

  /// FCC 快速换台开关，默认关闭。
  ///
  /// 开启后如果直播源（M3U 属性）提供了 FCC 地址，换台时优先使用 FCC 地址
  /// 拉流以缩短首帧时间；未提供 FCC 地址的频道自动回退到普通地址。
  static Future<bool> getFccFastSwitch() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_fccFastSwitchKey) ?? false;
  }

  static Future<void> saveFccFastSwitch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_fccFastSwitchKey, enabled);
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
