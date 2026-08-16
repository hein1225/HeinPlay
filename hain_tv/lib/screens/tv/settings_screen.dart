import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/services/ad_filter_service.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/cache_service.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/player/buffer_profile_config.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/services/live_source_refresh_notifier.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:qr_flutter/qr_flutter.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PlayerBackendType _playerBackend = PlayerBackendType.exo;
  PlayerBackendType _livePlayerBackend = PlayerBackendType.fvp;
  DoubanDataSource _doubanSource = DoubanDataSource.direct;
  bool _autoSkipOpeningEnding = true;
  bool _autoPlayNextEpisode = true;
  bool _autoSwitchSource = true;
  int _autoSwitchSourceTimeout = 15;
  bool _autoSpeedTest = true;
  String _m3u8ProxyUrl = '';
  bool _adFilterEnabled = false;
  bool _hardwareDecoding = true;
  BufferProfile _bufferProfile = BufferProfile.standard;
  bool _lunaTvLiveEnabled = true;
  int _liveSourceCacheHours = 24;
  BangumiApiProxyType _bangumiApiProxyType = BangumiApiProxyType.cmliussss;
  String _bangumiApiProxyUrl = '';
  BangumiImageProxyType _bangumiImageProxyType =
      BangumiImageProxyType.cmliussss;
  String _bangumiImageProxyUrl = '';

  // Windows 全屏置顶
  bool _windowsFullscreenAlwaysOnTop = false;
  bool _logEnabled = false;
  String _logPath = '';

  // TV 端日志下载二维码相关
  HttpServer? _logServer;
  String? _logDownloadUrl;

  // 应用版本号
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  @override
  void dispose() {
    _stopLogServer();
    super.dispose();
  }

  Future<void> _stopLogServer() async {
    final server = _logServer;
    _logServer = null;
    _logDownloadUrl = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _loadSettings() async {
    final backend = await UserDataService.getPlayerBackend();
    final liveBackend = await UserDataService.getLivePlayerBackend();
    final douban = await UserDataService.getDoubanDataSource();
    final skip = await UserDataService.getAutoSkipOpeningEnding();
    final next = await UserDataService.getAutoPlayNextEpisode();
    final autoSwitchSource = await UserDataService.getAutoSwitchSource();
    final autoSwitchSourceTimeout =
        await UserDataService.getAutoSwitchSourceTimeout();
    final autoSpeedTest = await UserDataService.getAutoSpeedTest();
    final m3u8ProxyUrl = await UserDataService.getM3u8ProxyUrl();
    final adFilterEnabled = await AdFilterService.isEnabled();
    final hardwareDecoding = await UserDataService.getHardwareDecoding();
    final bufferProfile = await UserDataService.getBufferProfile();
    final lunaTvLiveEnabled = await UserDataService.getLunaTvLiveEnabled();
    final liveSourceCacheHours = await UserDataService.getLiveSourceCacheHours();
    final bangumiApiProxyType = await UserDataService.getBangumiApiProxyType();
    final bangumiApiProxyUrl = await UserDataService.getBangumiApiProxyUrl();
    final bangumiImageProxyType =
        await UserDataService.getBangumiImageProxyType();
    final bangumiImageProxyUrl =
        await UserDataService.getBangumiImageProxyUrl();
    final windowsFullscreenAlwaysOnTop =
        await UserDataService.getWindowsFullscreenAlwaysOnTop();
    final logEnabled = await UserDataService.getLogEnabled();
    // 若日志已开启，确保日志目录已初始化并读取保存路径。
    String logPath = '';
    if (logEnabled) {
      await AppLogger.initialize();
      logPath = AppLogger.logFilePath;
    }
    await BangumiService.loadProxySettings();
    final appVersion = AppInfoService.version;
    setState(() {
      _playerBackend = backend;
      _livePlayerBackend = liveBackend;
      _doubanSource = douban;
      _autoSkipOpeningEnding = skip;
      _autoPlayNextEpisode = next;
      _autoSwitchSource = autoSwitchSource;
      _autoSwitchSourceTimeout = autoSwitchSourceTimeout;
      _autoSpeedTest = autoSpeedTest;
      _m3u8ProxyUrl = m3u8ProxyUrl;
      _adFilterEnabled = adFilterEnabled;
      _hardwareDecoding = hardwareDecoding;
      _bufferProfile = bufferProfile;
      _lunaTvLiveEnabled = lunaTvLiveEnabled;
      _liveSourceCacheHours = liveSourceCacheHours;
      _bangumiApiProxyType = bangumiApiProxyType;
      _bangumiApiProxyUrl = bangumiApiProxyUrl;
      _bangumiImageProxyType = bangumiImageProxyType;
      _bangumiImageProxyUrl = bangumiImageProxyUrl;
      _windowsFullscreenAlwaysOnTop = windowsFullscreenAlwaysOnTop;
      _logEnabled = logEnabled;
      _logPath = logPath;
      _appVersion = appVersion;
    });
    if (logEnabled && DeviceUtils.isTv) {
      _startLogServer();
    }
  }

  void _showSnackBar(
    String message, {
    Color backgroundColor = AppColors.bgElevated,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: backgroundColor,
        duration: duration,
      ),
    );
  }

  Future<void> _setDoubanSource(DoubanDataSource value) async {
    try {
      await UserDataService.saveDoubanDataSource(value);
      // 验证保存是否成功
      final verified = await UserDataService.getDoubanDataSource();
      if (verified != value) {
        _showSnackBar('数据源保存验证失败，请重试', backgroundColor: Colors.red);
        return;
      }
      setState(() => _doubanSource = value);
      try {
        final cache = CacheService();
        await cache.init();
        await cache.clearPrefix('douban_');
      } catch (e) {
        // 缓存清除失败不影响设置保存
      }
      _showSnackBar(
        '已切换为 ${_doubanSourceLabel(value)}，豆瓣缓存已清除',
      );
    } catch (e) {
      _showSnackBar('切换失败: $e', backgroundColor: Colors.red);
    }
  }

  String _doubanSourceLabel(DoubanDataSource source) {
    switch (source) {
      case DoubanDataSource.cdnTencent:
        return '腾讯云 CDN';
      case DoubanDataSource.cdnAliyun:
        return '阿里云 CDN';
      case DoubanDataSource.corsProxy:
        return 'CORS 代理';
      case DoubanDataSource.direct:
        return '直连';
    }
  }

  Future<void> _setPlayerBackend(PlayerBackendType value) async {
    await UserDataService.savePlayerBackend(value);
    setState(() => _playerBackend = value);
  }

  Future<void> _setLivePlayerBackend(PlayerBackendType value) async {
    await UserDataService.saveLivePlayerBackend(value);
    setState(() => _livePlayerBackend = value);
  }

  Future<void> _setLunaTvLiveEnabled(bool value) async {
    await UserDataService.saveLunaTvLiveEnabled(value);
    setState(() => _lunaTvLiveEnabled = value);
    // 通知直播相关页面立即刷新，开启后第一时间获取服务器直播源。
    LiveSourceRefreshNotifier.instance.notify();
  }

  Future<void> _setLiveSourceCacheHours(int hours) async {
    await UserDataService.saveLiveSourceCacheHours(hours);
    setState(() => _liveSourceCacheHours = hours);
    _showSnackBar('直播源缓存时间已设为 ${hours ~/ 24} 天');
  }

  Future<void> _setAutoSkip(bool value) async {
    await UserDataService.saveAutoSkipOpeningEnding(value);
    setState(() => _autoSkipOpeningEnding = value);
  }

  Future<void> _setAutoNext(bool value) async {
    await UserDataService.saveAutoPlayNextEpisode(value);
    setState(() => _autoPlayNextEpisode = value);
  }

  Future<void> _setAutoSwitchSource(bool value) async {
    await UserDataService.saveAutoSwitchSource(value);
    setState(() => _autoSwitchSource = value);
  }

  Future<void> _setAutoSpeedTest(bool value) async {
    await UserDataService.saveAutoSpeedTest(value);
    setState(() => _autoSpeedTest = value);
  }

  Future<void> _setM3u8ProxyUrl(String url) async {
    await UserDataService.saveM3u8ProxyUrl(url);
    setState(() => _m3u8ProxyUrl = url.trim());
  }

  Future<void> _setAdFilterEnabled(bool value) async {
    await AdFilterService.setEnabled(value);
    setState(() => _adFilterEnabled = value);
  }

  Future<void> _setHardwareDecoding(bool value) async {
    await UserDataService.saveHardwareDecoding(value);
    setState(() => _hardwareDecoding = value);
  }

  Future<void> _setBufferProfile(BufferProfile value) async {
    await UserDataService.saveBufferProfile(value);
    setState(() => _bufferProfile = value);
    _showSnackBar('已切换为 ${bufferProfileLabel(value)}');
  }

  Future<void> _setBangumiApiProxyType(BangumiApiProxyType value) async {
    await UserDataService.saveBangumiApiProxyType(value);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiApiProxyType = value);
  }

  Future<void> _setBangumiApiProxyUrl(String url) async {
    await UserDataService.saveBangumiApiProxyUrl(url);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiApiProxyUrl = url.trim());
  }

  Future<void> _setBangumiImageProxyType(BangumiImageProxyType value) async {
    await UserDataService.saveBangumiImageProxyType(value);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiImageProxyType = value);
  }

  Future<void> _setBangumiImageProxyUrl(String url) async {
    await UserDataService.saveBangumiImageProxyUrl(url);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiImageProxyUrl = url.trim());
  }

  Future<void> _setAutoSwitchSourceTimeout(int seconds) async {
    await UserDataService.saveAutoSwitchSourceTimeout(seconds);
    setState(() => _autoSwitchSourceTimeout = seconds);
    _showSnackBar('切换源超时时间已设为 $seconds 秒');
  }

  Future<void> _setWindowsFullscreenAlwaysOnTop(bool value) async {
    await UserDataService.setWindowsFullscreenAlwaysOnTop(value);
    setState(() => _windowsFullscreenAlwaysOnTop = value);
  }

  Future<void> _setLogEnabled(bool value) async {
    await AppLogger.setEnabled(value);
    final logPath = value ? AppLogger.logFilePath : '';
    setState(() {
      _logEnabled = value;
      _logPath = logPath;
    });
    if (value && DeviceUtils.isTv && !DeviceUtils.isWindows) {
      await _startLogServer();
      _showSnackBar('日志已开启，请扫描二维码下载日志文件');
    } else {
      await _stopLogServer();
      if (!value) {
        _showSnackBar('日志已关闭');
      }
    }
  }

  Future<void> _startLogServer() async {
    try {
      await _stopLogServer();
      final server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
      _logServer = server;
      final ip = await _getLocalIp();
      final url = 'http://$ip:${server.port}/logs';
      if (mounted) {
        setState(() {
          _logDownloadUrl = url;
        });
      }
      server.listen((request) async {
        try {
          _setCorsHeaders(request.response);
          if (request.method == 'OPTIONS') {
            request.response
              ..statusCode = 204
              ..close();
            return;
          }
          if (request.method == 'GET' && request.uri.path == '/logs') {
            await AppLogger.flush();
            final logPath = AppLogger.logFilePath;
            if (logPath.isEmpty || !File(logPath).existsSync()) {
              request.response
                ..statusCode = 404
                ..headers.contentType = ContentType.text
                ..write('日志文件不存在，请确认已开启获取日志并产生日志内容')
                ..close();
              return;
            }
            final file = File(logPath);
            final bytes = await file.readAsBytes();
            final fileName =
                'hain_tv_log_${DateTime.now().millisecondsSinceEpoch}.txt';
            request.response
              ..statusCode = 200
              ..headers.contentType = ContentType('text', 'plain', charset: 'utf-8')
              ..headers.add(
                'Content-Disposition',
                'attachment; filename="$fileName"',
              )
              ..add(bytes)
              ..close();
          } else {
            request.response
              ..statusCode = 404
              ..write('Not Found')
              ..close();
          }
        } catch (e) {
          request.response
            ..statusCode = 500
            ..write('Internal Server Error')
            ..close();
        }
      });
    } catch (e) {
      debugPrint('日志下载服务启动失败: $e');
      if (mounted) {
        _showSnackBar('日志下载服务启动失败', backgroundColor: Colors.red);
      }
    }
  }

  void _setCorsHeaders(HttpResponse response) {
    response.headers.add('Access-Control-Allow-Origin', '*');
    response.headers.add('Access-Control-Allow-Methods', 'GET, OPTIONS');
    response.headers.add('Access-Control-Allow-Headers', 'Content-Type');
  }

  Future<String> _getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );
      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && addr.type == InternetAddressType.IPv4) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      debugPrint('获取本地IP失败: $e');
    }
    return '127.0.0.1';
  }

  Future<void> _clearCache() async {
    final cacheService = CacheService();
    await cacheService.init();
    await cacheService.clearPrefix('douban_');
    await HainTvCacheManager().emptyCache();
    _showSnackBar('图片与豆瓣数据缓存已清除');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        elevation: 0,
        title: const Text('软件设置'),
        leading: DeviceUtils.isWindows
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _buildSectionTitle('播放器'),
          _buildPlayerBackendTile(),
          _buildSwitchTile(
            title: '自动跳过片头片尾',
            subtitle: '到达片头/片尾区域时自动跳转',
            value: _autoSkipOpeningEnding,
            onChanged: _setAutoSkip,
          ),
          _buildSwitchTile(
            title: '自动播放下一集',
            subtitle: '片尾结束后自动播放下一集',
            value: _autoPlayNextEpisode,
            onChanged: _setAutoNext,
          ),
          _buildSwitchTile(
            title: '进入详情页自动测速',
            subtitle: '多源时自动测试各源速度并排序，关闭后仍支持手动测速',
            value: _autoSpeedTest,
            onChanged: _setAutoSpeedTest,
          ),
          _buildAutoSwitchSourceTile(),
          _buildM3u8ProxyTile(),
          _buildSwitchTile(
            title: 'M3U8 去广告（本地过滤）',
            subtitle: '播放 M3U8 时使用本地规则过滤片头贴片广告',
            value: _adFilterEnabled,
            onChanged: _setAdFilterEnabled,
          ),
          _buildSwitchTile(
            title: '硬件解码',
            subtitle: '关闭后可能解决部分花屏问题',
            value: _hardwareDecoding,
            onChanged: _setHardwareDecoding,
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('直播设置'),
          _buildLivePlayerBackendTile(),
          _buildSwitchTile(
            title: '启用 LunaTV 服务器直播源',
            subtitle: '关闭后将不再获取 LunaTV 服务端提供的直播频道',
            value: _lunaTvLiveEnabled,
            onChanged: _setLunaTvLiveEnabled,
          ),
          const SizedBox(height: AppSpacing.md),
          _buildLiveSourceCacheTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('缓冲模式'),
          _buildBufferProfileTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('Bangumi 数据源'),
          _buildBangumiApiProxyTile(),
          const SizedBox(height: AppSpacing.md),
          _buildBangumiImageProxyTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('豆瓣数据源'),
          _buildDoubanSourceTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('缓存'),
          _buildActionTile(
            title: '清除缓存',
            subtitle: '清除海报、图片与豆瓣数据缓存，保留播放记录、搜索记录、跳过设置等数据',
            icon: Icons.cleaning_services_outlined,
            onTap: _clearCache,
          ),
          const SizedBox(height: AppSpacing.lg),
          if (DeviceUtils.isWindows) ...[
            _buildSectionTitle('Windows'),
            _buildSwitchTile(
              title: '全屏时窗口置顶',
              subtitle: '全屏播放时自动将窗口置顶',
              value: _windowsFullscreenAlwaysOnTop,
              onChanged: _setWindowsFullscreenAlwaysOnTop,
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
          _buildSectionTitle('日志与调试'),
          _buildLogTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('关于'),
          _buildInfoTile(title: '版本', value: _appVersion.isEmpty ? '-' : _appVersion),
          _buildInfoTile(title: '作者', value: '海因茨'),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  String _playerBackendTitle(PlayerBackendType type) {
    final isDefault = PlayerBackendFactory.platformDefault == type;
    switch (type) {
      case PlayerBackendType.exo:
        return isDefault ? 'ExoPlayer（默认）' : 'ExoPlayer';
      case PlayerBackendType.fvp:
        return isDefault ? 'FVP（默认）' : 'FVP';
      case PlayerBackendType.vlc:
        return isDefault ? 'VLC（默认）' : 'VLC';
    }
  }

  /// 直播播放器标题，默认标记按直播默认后端（fvp）判断。
  String _livePlayerBackendTitle(PlayerBackendType type) {
    final isDefault = PlayerBackendFactory.platformLiveDefault == type;
    switch (type) {
      case PlayerBackendType.exo:
        return isDefault ? 'ExoPlayer（默认）' : 'ExoPlayer';
      case PlayerBackendType.fvp:
        return isDefault ? 'FVP（默认）' : 'FVP';
      case PlayerBackendType.vlc:
        return isDefault ? 'VLC（默认）' : 'VLC';
    }
  }

  String _playerBackendSubtitle(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        return 'Android 原生播放器，硬解能力强';
      case PlayerBackendType.fvp:
        return '基于 libmdk，兼容性较好';
      case PlayerBackendType.vlc:
        return '基于 libvlc，格式兼容性最强';
    }
  }

  Widget _buildPlayerBackendTile() {
    final tiles = <Widget>[];
    for (final type in PlayerBackendFactory.availableBackends) {
      if (tiles.isNotEmpty) {
        tiles.add(const Divider(height: 1, color: AppColors.border));
      }
      tiles.add(
        _buildRadioTile<PlayerBackendType>(
          title: _playerBackendTitle(type),
          subtitle: _playerBackendSubtitle(type),
          value: type,
          groupValue: _playerBackend,
          onChanged: _setPlayerBackend,
        ),
      );
    }

    return _buildCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: const Text(
              '点播源默认播放器',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          ...tiles,
        ],
      ),
    );
  }

  Widget _buildLivePlayerBackendTile() {
    final tiles = <Widget>[];
    for (final type in PlayerBackendFactory.availableBackends) {
      if (tiles.isNotEmpty) {
        tiles.add(const Divider(height: 1, color: AppColors.border));
      }
      tiles.add(
        _buildRadioTile<PlayerBackendType>(
          title: _livePlayerBackendTitle(type),
          subtitle: _playerBackendSubtitle(type),
          value: type,
          groupValue: _livePlayerBackend,
          onChanged: _setLivePlayerBackend,
        ),
      );
    }

    return _buildCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: const Text(
              '直播默认播放器',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          ...tiles,
        ],
      ),
    );
  }

  Widget _buildLiveSourceCacheTile() {
    return _buildCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '直播源缓存时间：${_liveSourceCacheHours ~/ 24} 天',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<int>(
            title: '1 天',
            subtitle: '默认缓存时间',
            value: 24,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<int>(
            title: '2 天',
            subtitle: '48小时缓存',
            value: 48,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<int>(
            title: '3 天',
            subtitle: '72小时缓存',
            value: 72,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<int>(
            title: '7 天',
            subtitle: '最长缓存时间',
            value: 168,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
        ],
      ),
    );
  }

  Widget _buildBufferProfileTile() {
    final tiles = <Widget>[
      Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Text(
          '当前：${bufferProfileLabel(_bufferProfile)}',
          style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
        ),
      ),
      const Divider(height: 1, color: AppColors.border),
    ];

    for (final profile in BufferProfile.values) {
      tiles.add(
        _buildRadioTile<BufferProfile>(
          title: bufferProfileLabel(profile),
          subtitle: bufferProfileSubtitle(profile),
          value: profile,
          groupValue: _bufferProfile,
          onChanged: _setBufferProfile,
        ),
      );
      if (profile != BufferProfile.values.last) {
        tiles.add(const Divider(height: 1, color: AppColors.border));
      }
    }

    return _buildCard(child: Column(children: tiles));
  }

  Widget _buildDoubanSourceTile() {
    return _buildCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '当前：${_doubanSourceLabel(_doubanSource)}',
              style: const TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: '直连（默认）',
            subtitle: '直接访问豆瓣官方接口',
            value: DoubanDataSource.direct,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: '腾讯云 CDN',
            subtitle: '通过腾讯云 CDN 加速访问',
            value: DoubanDataSource.cdnTencent,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: '阿里云 CDN',
            subtitle: '通过阿里云 CDN 加速访问',
            value: DoubanDataSource.cdnAliyun,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: 'CORS 代理',
            subtitle: '通过 CORS 代理服务器访问',
            value: DoubanDataSource.corsProxy,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
        ],
      ),
    );
  }

  Widget _buildAutoSwitchSourceTile() {
    return _buildCard(
      child: Column(
        children: [
          Builder(
            builder: (context) => FocusableWidget(
              onTap: () => _setAutoSwitchSource(!_autoSwitchSource),
              onFocusChange: (focused) =>
                  _ensureVisibleOnFocus(context, focused),
              child: SwitchListTile(
                title: const Text(
                  '播放失败自动切换播放源',
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: const Text(
                  '当前源无法播放时按测速顺序自动尝试其他源',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                value: _autoSwitchSource,
                onChanged: _setAutoSwitchSource,
                activeThumbColor: AppColors.primary,
                inactiveThumbColor: AppColors.textMuted,
              ),
            ),
          ),
          if (_autoSwitchSource) ...[
            const Divider(height: 1, color: AppColors.border),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                '当前：$_autoSwitchSourceTimeout 秒',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            _buildRadioTile<int>(
              title: '10 秒',
              subtitle: '默认较短等待时间',
              value: 10,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
            const Divider(height: 1, color: AppColors.border),
            _buildRadioTile<int>(
              title: '15 秒',
              subtitle: '适中等待时间',
              value: 15,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
            const Divider(height: 1, color: AppColors.border),
            _buildRadioTile<int>(
              title: '30 秒',
              subtitle: '较长等待时间，适合弱网或源响应慢的环境',
              value: 30,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildM3u8ProxyTile() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () async {
            final controller = TextEditingController(text: _m3u8ProxyUrl);
            final fieldNode = FocusNode();
            final cancelNode = FocusNode();
            final saveNode = FocusNode();

            final confirmed = await showDialog<bool>(
              context: context,
              builder: (dialogContext) {
                void closeDialog(bool value) {
                  if (Navigator.of(dialogContext).canPop()) {
                    Navigator.of(dialogContext).pop(value);
                  }
                }

                return FocusScope(
                  child: AlertDialog(
                    backgroundColor: AppColors.bgSurface,
                    title: const Text('M3U8 代理地址'),
                    content: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Focus(
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                              return KeyEventResult.ignored;
                            }
                            final key = event.logicalKey;
                            if (key == LogicalKeyboardKey.arrowDown ||
                                key == LogicalKeyboardKey.select ||
                                key == LogicalKeyboardKey.enter ||
                                key == LogicalKeyboardKey.numpadEnter) {
                              cancelNode.requestFocus();
                              return KeyEventResult.handled;
                            }
                            if (key == LogicalKeyboardKey.goBack ||
                                key == LogicalKeyboardKey.escape) {
                              closeDialog(false);
                              return KeyEventResult.handled;
                            }
                            return KeyEventResult.ignored;
                          },
                          child: TextField(
                            controller: controller,
                            focusNode: fieldNode,
                            autofocus: true,
                            style: const TextStyle(color: AppColors.textPrimary),
                            decoration: const InputDecoration(
                              hintText: '例如 http://127.0.0.1:8080/proxy?url=',
                              hintStyle: TextStyle(color: AppColors.textMuted),
                              border: OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            FocusableWidget(
                              focusNode: cancelNode,
                              onTap: () => closeDialog(false),
                              onKeyEvent: (node, event) {
                                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                                  return KeyEventResult.ignored;
                                }
                                final key = event.logicalKey;
                                if (key == LogicalKeyboardKey.arrowUp) {
                                  fieldNode.requestFocus();
                                  return KeyEventResult.handled;
                                }
                                if (key == LogicalKeyboardKey.goBack ||
                                    key == LogicalKeyboardKey.escape) {
                                  closeDialog(false);
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                                child: Text(
                                  '取消',
                                  style: TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    fontSize: 14,
                                    color: AppColors.textPrimary,
                                  ),
                                ),
                              ),
                            ),
                            FocusableWidget(
                              focusNode: saveNode,
                              onTap: () => closeDialog(true),
                              onKeyEvent: (node, event) {
                                if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                                  return KeyEventResult.ignored;
                                }
                                final key = event.logicalKey;
                                if (key == LogicalKeyboardKey.arrowUp) {
                                  fieldNode.requestFocus();
                                  return KeyEventResult.handled;
                                }
                                if (key == LogicalKeyboardKey.goBack ||
                                    key == LogicalKeyboardKey.escape) {
                                  closeDialog(false);
                                  return KeyEventResult.handled;
                                }
                                return KeyEventResult.ignored;
                              },
                              child: const Padding(
                                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                                child: Text(
                                  '保存',
                                  style: TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: AppColors.primary,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            );
            fieldNode.dispose();
            cancelNode.dispose();
            saveNode.dispose();
            if (confirmed == true) {
              await _setM3u8ProxyUrl(controller.text);
            }
            controller.dispose();
          },
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'M3U8 代理地址',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _m3u8ProxyUrl.isEmpty ? '未配置' : _m3u8ProxyUrl,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '配置后 M3U8/HLS 播放地址将通过代理请求，用于解决跨域或 Referer 限制',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBangumiApiProxyTile() {
    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bangumi 数据代理',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '选择获取 Bangumi 番剧数据的方式，服务器无法访问 api.bgm.tv 时可切换反代',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _buildRadioTile<BangumiApiProxyType>(
            title: '直连（直接访问 api.bgm.tv）',
            value: BangumiApiProxyType.direct,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          _buildRadioTile<BangumiApiProxyType>(
            title: 'Bangumi 反代 By CMLiussss（解决服务器被墙）',
            value: BangumiApiProxyType.cmliussss,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          _buildRadioTile<BangumiApiProxyType>(
            title: '自定义反代地址',
            value: BangumiApiProxyType.custom,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          if (_bangumiApiProxyType == BangumiApiProxyType.custom)
            Builder(
              builder: (context) => FocusableWidget(
                onTap: () => _showBangumiProxyUrlInput(
                  title: 'Bangumi 反代地址',
                  hint: '例如 https://api.example.com',
                  current: _bangumiApiProxyUrl,
                  onSave: _setBangumiApiProxyUrl,
                ),
                onFocusChange: (focused) =>
                    _ensureVisibleOnFocus(context, focused),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bangumiApiProxyUrl.isEmpty
                            ? '点击输入反代地址'
                            : _bangumiApiProxyUrl,
                        style: TextStyle(
                          fontSize: 13,
                          color: _bangumiApiProxyUrl.isEmpty
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      const Text(
                        '与官方 api.bgm.tv 路径兼容的反代地址，不含末尾斜杠',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_bangumiApiProxyType == BangumiApiProxyType.cmliussss)
            const Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Thanks to @CMLiussss',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBangumiImageProxyTile() {
    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bangumi 图片代理',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '选择获取 Bangumi 封面图片的方式，服务器无法访问 lain.bgm.tv 时可切换',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _buildRadioTile<BangumiImageProxyType>(
            title: '直连（直接请求 lain.bgm.tv）',
            value: BangumiImageProxyType.direct,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          _buildRadioTile<BangumiImageProxyType>(
            title: 'Bangumi 图片 CDN By CMLiussss',
            value: BangumiImageProxyType.cmliussss,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          _buildRadioTile<BangumiImageProxyType>(
            title: '自定义代理',
            value: BangumiImageProxyType.custom,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          if (_bangumiImageProxyType == BangumiImageProxyType.custom)
            Builder(
              builder: (context) => FocusableWidget(
                onTap: () => _showBangumiProxyUrlInput(
                  title: 'Bangumi 图片代理地址',
                  hint: '例如 https://img.example.com/proxy?url=',
                  current: _bangumiImageProxyUrl,
                  onSave: _setBangumiImageProxyUrl,
                ),
                onFocusChange: (focused) =>
                    _ensureVisibleOnFocus(context, focused),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bangumiImageProxyUrl.isEmpty
                            ? '点击输入图片代理地址'
                            : _bangumiImageProxyUrl,
                        style: TextStyle(
                          fontSize: 13,
                          color: _bangumiImageProxyUrl.isEmpty
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      const Text(
                        '接收原始图片 URL 并返回图片的代理地址',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_bangumiImageProxyType == BangumiImageProxyType.cmliussss)
            const Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Thanks to @CMLiussss',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showBangumiProxyUrlInput({
    required String title,
    required String hint,
    required String current,
    required ValueChanged<String> onSave,
  }) async {
    final controller = TextEditingController(text: current);
    final fieldNode = FocusNode();
    final cancelNode = FocusNode();
    final saveNode = FocusNode();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        void closeDialog(bool value) {
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop(value);
          }
        }

        return FocusScope(
          child: AlertDialog(
            backgroundColor: AppColors.bgSurface,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      cancelNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.escape) {
                      closeDialog(false);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: controller,
                    focusNode: fieldNode,
                    autofocus: true,
                    style: const TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: const TextStyle(color: AppColors.textMuted),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FocusableWidget(
                      focusNode: cancelNode,
                      onTap: () => closeDialog(false),
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowUp) {
                          fieldNode.requestFocus();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    FocusableWidget(
                      focusNode: saveNode,
                      onTap: () => closeDialog(true),
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowUp) {
                          fieldNode.requestFocus();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        child: Text(
                          '保存',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    fieldNode.dispose();
    cancelNode.dispose();
    saveNode.dispose();
    if (confirmed == true) {
      onSave(controller.text);
    }
    controller.dispose();
  }

  void _ensureVisibleOnFocus(BuildContext context, bool focused) {
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0.5,
          );
        }
      });
    }
  }

  Widget _buildLogTile() {
    return _buildCard(
      child: Column(
        children: [
          _buildSwitchTile(
            title: '获取日志',
            subtitle: '作为调试核查问题使用，正常情况下请关闭选项，避免影响性能',
            value: _logEnabled,
            onChanged: _setLogEnabled,
          ),
          if (_logEnabled && _logPath.isNotEmpty) ...[
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '日志保存路径',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _logPath,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (_logEnabled &&
              DeviceUtils.isTv &&
              !DeviceUtils.isWindows &&
              _logDownloadUrl != null) ...[
            const Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Container(
                    width: 100,
                    height: 100,
                    padding: const EdgeInsets.all(AppSpacing.xs),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: QrImageView(
                      data: _logDownloadUrl!,
                      version: QrVersions.auto,
                      size: 84,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          '手机扫描下载日志',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        const Text(
                          '提示：获取日志二维码会发生变化，请在调试完再返回扫描',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.warning,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _logDownloadUrl!,
                          style: const TextStyle(
                            fontSize: 11,
                            color: AppColors.textMuted,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () => onChanged(!value),
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: SwitchListTile(
            title: Text(
              title,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
            inactiveThumbColor: AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildActionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: onTap,
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              icon,
              color: danger ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(
              title,
              style: TextStyle(
                color: danger ? AppColors.primary : AppColors.textPrimary,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile({required String title, required String value}) {
    return _buildCard(
      child: ListTile(
        title: Text(
          title,
          style: const TextStyle(color: AppColors.textPrimary),
        ),
        trailing: Text(
          value,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _buildRadioTile<T>({
    required String title,
    String? subtitle,
    required T value,
    required T groupValue,
    required ValueChanged<T> onChanged,
  }) {
    final selected = value == groupValue;
    return Builder(
      builder: (context) => FocusableWidget(
        onTap: () => onChanged(value),
        onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? AppColors.primary : AppColors.textMuted,
                    width: 2,
                  ),
                ),
                child: selected
                    ? Center(
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.primary,
                          ),
                        ),
                      )
                    : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: selected
                            ? AppColors.primary
                            : AppColors.textPrimary,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                    ),
                    if (subtitle != null)
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}
