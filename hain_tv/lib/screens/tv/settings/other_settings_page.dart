import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/cache_service.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/utils/app_logger.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/screens/tv/settings/settings_helpers.dart';

class OtherSettingsPage extends StatefulWidget {
  const OtherSettingsPage({super.key});

  @override
  State<OtherSettingsPage> createState() => _OtherSettingsPageState();
}

class _OtherSettingsPageState extends State<OtherSettingsPage> {
  bool _windowsFullscreenAlwaysOnTop = false;
  bool _logEnabled = false;
  String _logPath = '';
  HttpServer? _logServer;
  String? _logDownloadUrl;
  String _appVersion = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _stopLogServer();
    super.dispose();
  }

  Future<void> _load() async {
    final windowsFullscreenAlwaysOnTop =
        await UserDataService.getWindowsFullscreenAlwaysOnTop();
    final logEnabled = await UserDataService.getLogEnabled();
    String logPath = '';
    if (logEnabled) {
      await AppLogger.initialize();
      logPath = AppLogger.logFilePath;
    }
    final appVersion = AppInfoService.version;
    if (!mounted) return;
    setState(() {
      _windowsFullscreenAlwaysOnTop = windowsFullscreenAlwaysOnTop;
      _logEnabled = logEnabled;
      _logPath = logPath;
      _appVersion = appVersion;
    });
    if (logEnabled && DeviceUtils.isTv) {
      _startLogServer();
    }
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
      showSettingsSnackBar(context, '日志已开启，请扫描二维码下载日志文件');
    } else {
      await _stopLogServer();
      if (!value) {
        showSettingsSnackBar(context, '日志已关闭');
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
        setState(() => _logDownloadUrl = url);
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
              ..headers.contentType =
                  ContentType('text', 'plain', charset: 'utf-8')
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
        showSettingsSnackBar(context, '日志下载服务启动失败',
            backgroundColor: AppColors.error);
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

  Future<void> _stopLogServer() async {
    final server = _logServer;
    _logServer = null;
    _logDownloadUrl = null;
    if (server != null) {
      await server.close(force: true);
    }
  }

  Future<void> _clearCache() async {
    final cacheService = CacheService();
    await cacheService.init();
    await cacheService.clearPrefix('douban_');
    await HainTvCacheManager().emptyCache();
    showSettingsSnackBar(context, '图片与豆瓣数据缓存已清除');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '其他',
        isWindows: DeviceUtils.isWindows,
      ),
      body: buildSettingsScrollView(
        children: [
          buildSectionTitle('其他'),
          buildActionTile(
            title: '清除缓存源',
            subtitle: '清除海报、图片与豆瓣数据缓存，保留播放记录、搜索记录、跳过设置等数据',
            icon: Icons.cleaning_services_outlined,
            onTap: _clearCache,
          ),
          const SizedBox(height: AppSpacing.lg),
          buildSectionTitle('日志与调试'),
          _buildLogCard(),
          if (DeviceUtils.isWindows) ...[
            const SizedBox(height: AppSpacing.lg),
            buildSectionTitle('Windows'),
            buildSwitchTile(
              context: context,
              title: '全屏时窗口置顶',
              subtitle: '全屏播放时自动将窗口置顶',
              value: _windowsFullscreenAlwaysOnTop,
              onChanged: _setWindowsFullscreenAlwaysOnTop,
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          buildSectionTitle('关于'),
          buildInfoTile(
            title: '版本',
            value: _appVersion.isEmpty ? '-' : _appVersion,
          ),
          buildInfoTile(title: '作者', value: '海因茨'),
        ],
      ),
    );
  }

  Widget _buildLogCard() {
    return buildSettingsCard(
      child: Column(
        children: [
          buildSwitchTile(
            context: context,
            title: '获取日志',
            subtitle: '作为调试核查问题使用，正常情况下请关闭选项，避免影响性能',
            value: _logEnabled,
            onChanged: _setLogEnabled,
          ),
          if (_logEnabled && _logPath.isNotEmpty) ...[
            Divider(height: 1, color: AppColors.border),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '日志保存路径',
                    style: TextStyle(
                      fontSize: 13,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    _logPath,
                    style: TextStyle(
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
            Divider(height: 1, color: AppColors.border),
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
                        Text(
                          '手机扫描下载日志',
                          style: TextStyle(
                            fontSize: 13,
                            color: AppColors.textSecondary,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          '提示：获取日志二维码会发生变化，请在调试完再返回扫描',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppColors.warning,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          _logDownloadUrl!,
                          style: TextStyle(
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
}
