import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/account_info.dart';
import 'glass_style_service.dart';
import '../utils/log_redactor.dart';

enum DoubanDataSource { direct, cdnTencent, cdnAliyun, corsProxy }

/// 播放后端类型。
///
/// - exo    : Android 官方 ExoPlayer（安卓/TV 原生运行时，作 mpv 的兜底）
/// - fvp    : libmdk/ffmpeg（历史上安卓/Win/Linux/ohos 通用，已被 mpv 全面取代，
///            仅作为迁移期兼容旧存储值的枚举项，新代码不再作为可选项）
/// - vlc    : Windows 端 VLC（Win 兜底）
/// - mpv    : 官方 mpv 内核 + 各平台自写壳（Android/TV/Win/Linux 默认后端，
///            鸿蒙在 hain_tv_ohos 工程另用 mpv-arkts 实现）
///
/// 枚举值以 `.name` 字符串持久化，删除旧值不会破坏旧存储（未知值走默认值回退）。
enum PlayerBackendType { exo, fvp, vlc, mpv }

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
  static const String _windowsMiniPlayerEnabledKey = 'windows_mini_player_enabled';
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
  static const String _hardwareDecodingKey = 'hardware_decoding';
  // 渲染后端：强制 OpenGL ES（默认 false，即 Vulkan 优先）。
  // 内核同时带 Vulkan 与 GLES 两个后端，由原生 RendererProbe 探测决定用哪个；
  // 打开此项则无视探测结果，一律 GLES（用于 Vulkan 驱动异常时的兜底排查）。
  static const String _forceOpenGlKey = 'force_opengl_es';
  static const String _hlsPrefetchEnabledKey = 'hls_prefetch_enabled';
  static const String _bufferProfileKey = 'buffer_profile';

  // 直播设置
  static const String _lunaTvLiveEnabledKey = 'lunatv_live_enabled';
  static const String _liveSourceCacheHoursKey = 'live_source_cache_hours';
  static const String _epgLoadEnabledKey = 'epg_load_enabled';
  // 本地 M3U8 代理总开关：开启时点播 M3U8 经由本地代理（统一请求头/去广告），
  // 关闭时直接播放原始地址。直播默认直连，不受此开关影响。
  static const String _localProxyEnabledKey = 'local_proxy_enabled';
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
    // 🔒 隐私：登录使用的服务器地址需遮蔽。
    LogRedactor.registerServerAddress(serverUrl);
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
    final url = prefs.getString(_serverUrlKey);
    // 🔒 隐私：登记为需遮蔽的 LunaTV 服务器地址（读一次即生效）。
    LogRedactor.registerServerAddress(url);
    return url;
  }

  static Future<void> saveServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlKey, url.trim());
    // 🔒 隐私：新地址立即登记，旧地址仍保留遮蔽。
    LogRedactor.registerServerAddress(url);
  }

  static Future<void> saveBackupServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_backupServerUrlKey, url.trim());
    // 🔒 隐私：备用服务器地址同样需要遮蔽。
    LogRedactor.registerServerAddress(url);
  }

  static Future<String> getBackupServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_backupServerUrlKey) ?? '';
    // 🔒 隐私：登记为需遮蔽的 LunaTV 服务器地址。
    LogRedactor.registerServerAddress(url);
    return url;
  }

  static Future<void> saveLastSelectedServerUrl(String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_lastSelectedServerUrlKey, url.trim());
    // 🔒 隐私：上次选用的服务器地址同样需要遮蔽。
    LogRedactor.registerServerAddress(url);
  }

  static Future<String?> getLastSelectedServerUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final url = prefs.getString(_lastSelectedServerUrlKey);
    // 🔒 隐私：登记为需遮蔽的 LunaTV 服务器地址。
    LogRedactor.registerServerAddress(url);
    return url;
  }

  static Future<InternetServerDnsPreference> getInternetServerDnsPreference() async {
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

    // 播放后端升级迁移（fvp -> mpv）：必须早于任何读取播放后端的逻辑，
    // 因此放在此处（迁移总入口）而非各页面 initState。
    await migratePlayerBackendToMpv();

    // 直播默认后端迁移（历史上 ExoPlayer -> fvp），独立于账号迁移。
    await migrateLivePlayerBackendDefault();
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

  /// fvp 替换目标：fvp 已从本工程彻底删除（安卓/TV/鸿蒙/桌面均不用它），
  /// 历史 `"fvp"` 存储值一律落到它。
  ///
  /// 🔴 这**不是**各平台默认后端：
  ///   · 安卓 / TV 默认是 **exo**（首选）、mpv 为备用；
  ///   · 桌面（Windows/Linux）默认是 **mpv**。
  /// 该常量仅用于「把已存的 fvp 改成什么」。
  static const PlayerBackendType _fvpReplacementBackend = PlayerBackendType.mpv;

  /// 各平台默认后端：安卓 / TV / 鸿蒙 为 **exo**，桌面（Windows / Linux）为 **mpv**。
  ///
  /// 保持与历史一致的语义 —— 本次改动**不触碰**默认值，只处理「已存的 fvp」。
  static PlayerBackendType get _platformDefaultBackend {
    if (Platform.isWindows || Platform.isLinux) return PlayerBackendType.mpv;
    return PlayerBackendType.exo;
  }

  /// 直播默认后端：Android / TV 默认 ExoPlayer（与点播同款，兼容性最佳）；
  /// 桌面（Windows / Linux）无 ExoPlayer 运行时，用 mpv。
  /// 注：历史上曾因 Shield TV 等设备的 ExoPlayer OkHttp 网络栈连外部 IPTV 域名
  /// 超时而默认 fvp，现改回 ExoPlayer；个别设备若连源超时可在直播设置里切回 mpv。
  static PlayerBackendType get _platformDefaultLiveBackend {
    // 🔴 桌面（Windows/Linux）用 mpv：与 PlayerBackendFactory.platformLiveDefault 保持一致。
    if (Platform.isWindows || Platform.isLinux) return PlayerBackendType.mpv;
    return PlayerBackendType.exo;
  }

  /// 解析已保存的后端字符串；**历史值 `"fvp"` 一律纠正为 [_fvpReplacementBackend]**，
  /// 其余合法值（exo / vlc / mpv）按原样保留以尊重用户选择。
  ///
  /// 🔴 绝不覆盖用户的 exo 选择：安卓默认即 exo，已选 exo 的用户必须原样保留。
  ///
  /// 这是「升级强制切 mpv」的读取侧兜底：即使迁移函数 [migratePlayerBackendToMpv]
  /// 因故未执行（例如 prefs 被外部工具写回旧值），读取路径也不会把用户留在
  /// 「选了 fvp 但工程里没有 fvp」的坏状态。
  ///
  /// [fallback] 是「无存储值 / 值非法」时使用的平台默认：点播用
  /// [_platformDefaultBackend]，直播用 [_platformDefaultLiveBackend]，
  /// 两者在桌面与移动端的取值可能不同，不可混用。
  static PlayerBackendType _resolveStoredBackend(
    String? name, {
    required PlayerBackendType fallback,
  }) {
    if (name == null || name.isEmpty) return fallback;
    final resolved = PlayerBackendType.values.firstWhere(
      (e) => e.name == name,
      orElse: () => fallback,
    );
    // fvp 已从本工程摘除：历史存储值 "fvp" 统一替换为 mpv。
    // 其余值（exo / vlc / mpv）原样保留，尊重用户选择。
    if (resolved == PlayerBackendType.fvp) return _fvpReplacementBackend;
    return resolved;
  }

  static Future<PlayerBackendType> getPlayerBackend() async {
    final prefs = await SharedPreferences.getInstance();
    return _resolveStoredBackend(
      prefs.getString(_playerBackendKey),
      fallback: _platformDefaultBackend,
    );
  }

  static Future<void> saveLivePlayerBackend(PlayerBackendType type) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_livePlayerBackendKey, type.name);
  }

  static Future<PlayerBackendType> getLivePlayerBackend() async {
    final prefs = await SharedPreferences.getInstance();
    return _resolveStoredBackend(
      prefs.getString(_livePlayerBackendKey),
      fallback: _platformDefaultLiveBackend,
    );
  }

  /// 直播默认后端历史迁移：曾把 Android 默认从 ExoPlayer 迁到 fvp，
  /// 现又改回 ExoPlayer（见 [_platformDefaultLiveBackend]）。本迁移仅保证只执行一次，
  /// 不再强制改动用户的已保存选择——无保存项的用户会自然落到新的 ExoPlayer 默认，
  /// 曾手动选 fvp 的用户保持不变（尊重其选择）。
  static const String _livePlayerBackendMigratedKey =
      'live_player_backend_migrated_to_fvp';

  /// 【fvp -> mpv 升级迁移】把用户已保存的 **fvp** 后端改写为 mpv。
  ///
  /// 背景：本工程 1.4.0 起播放后端从 **fvp** 替换为 **mpv**（官方 mpv 内核 +
  /// 自写 Kotlin/JNI 壳），fvp 插件已整体摘除；`player_backend_factory.dart`
  /// 里 `availableBackends` 不再列出 fvp，且 `create(fvp)` 已被改写成回退 mpv。
  /// 老用户 prefs 里若存着 `"fvp"`，设置页会显示一个本版本已不存在、且运行时
  /// 会被静默改写的后端，用户无从判断真实后端。
  ///
  /// 🔴 **只替换 fvp，绝不覆盖用户的其他选择**：安卓/TV 默认仍是 exo，
  /// 已选 exo / vlc / mpv 的用户在升级后必须原样保留。因此这里逐键比对，
  /// 只有值确实是 `"fvp"` 时才改写（而不是无条件写入 mpv）。
  /// 覆盖范围：
  /// 1. 全局点播后端 `player_backend`；
  /// 2. 全局直播后端 `live_player_backend`；
  /// 3. 所有单视频级后端 `per_video_player_backend_*`（旧版可能逐个记过 fvp）。
  ///
  /// 读取侧 [_resolveStoredBackend] 是同一语义的兜底，两者共同保证
  /// 「无论 prefs 里是什么，运行时永远不是 fvp」。
  static const String _mpvMigrationKey = 'player_backend_migrated_to_mpv_v1';

  static Future<void> migratePlayerBackendToMpv() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_mpvMigrationKey) ?? false) return;

    /// 仅当存储值确为 fvp 时改写；null / 空 / 其他后端一律不动，
    /// 以免把安卓用户已选的 exo 冲成 mpv。
    Future<void> fixIfFvp(String key) async {
      final stored = prefs.getString(key);
      if (stored == PlayerBackendType.fvp.name) {
        await prefs.setString(key, _fvpReplacementBackend.name);
      }
    }

    await fixIfFvp(_playerBackendKey);
    await fixIfFvp(_livePlayerBackendKey);

    // 单视频级记录：逐个检查，只把值为 "fvp" 的改成 mpv，其余保留。
    final perVideoKeys = prefs
        .getKeys()
        .where((k) => k.startsWith(_perVideoPlayerBackendPrefix))
        .toList();
    for (final k in perVideoKeys) {
      await fixIfFvp(k);
    }

    await prefs.setBool(_mpvMigrationKey, true);
  }

  static Future<void> migrateLivePlayerBackendDefault() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(_livePlayerBackendMigratedKey) ?? false) return;
    // 不强制清除任何已保存值：新默认由 [_platformDefaultLiveBackend] 提供，
    // 仅记录迁移已完成避免重复执行。
    await prefs.setBool(_livePlayerBackendMigratedKey, true);
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

  /// 保存「强制 OpenGL ES」开关。
  ///
  /// 默认 false：mpv 渲染走 Vulkan 优先（设备支持时），否则自动回落 GLES。
  /// 打开 true 则跳过 Vulkan、一律 GLES，用于 Vulkan 驱动异常的兜底。
  static Future<void> saveForceOpenGl(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_forceOpenGlKey, enabled);
  }

  /// 读取「强制 OpenGL ES」开关，默认 false（即 Vulkan 优先）。
  static Future<bool> getForceOpenGl() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_forceOpenGlKey) ?? false;
  }

  /// HLS 并发分片预取开关（移植自 hain_tv_ohos，借鉴 LunaTV OptimizedHlsLoader）。
  ///
  /// 默认关闭：预取会额外消耗带宽（并发下载后续分片），故保守默认关闭，
  /// 由用户在「点播设置」中按需开启。开启后由 LocalM3u8Proxy 并发预取
  /// 后续分片，弱网/换段缓冲更快。
  static Future<bool> getHlsPrefetchEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_hlsPrefetchEnabledKey) ?? false;
  }

  static Future<void> saveHlsPrefetchEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_hlsPrefetchEnabledKey, enabled);
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
    // 走同一解析路径：单视频级存的 "fvp" 也必须被纠正为 mpv，
    // 否则会绕过迁移在运行时留在「没有 fvp 的版本里选了 fvp」的坏状态。
    return _resolveStoredBackend(
      prefs.getString(key),
      fallback: effectiveFallback,
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

  // ---------------------------------------------------------------------------
  // 磨砂玻璃档位（2026-10-23 由鸿蒙版移植，仅 Android 手机版使用）
  // ---------------------------------------------------------------------------

  /// 磨砂玻璃档位存储键。string 存 `GlassLevel.name`。
  static const String _glassLevelKey = 'glass_level';

  /// 磨砂玻璃透明度档位（强/中/弱/关）。**默认「关」**。
  ///
  /// 【为什么默认关】磨砂玻璃走高斯模糊实时渲染，对 GPU 与电量有持续开销。
  /// 鸿蒙版 2026-10-07 起改为默认关闭、由用户主动开启，此处保持一致。
  ///
  /// 与鸿蒙版共用同一个 SharedPreferences 键名（`glass_level`），
  /// 便于将来跨版本迁移用户偏好时不丢失。
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
}
