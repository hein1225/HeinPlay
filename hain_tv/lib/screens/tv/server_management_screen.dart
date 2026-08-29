import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/remote_input_service.dart';
import 'package:hain_tv/services/server_latency_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class ServerManagementScreen extends StatefulWidget {
  const ServerManagementScreen({super.key});

  @override
  State<ServerManagementScreen> createState() => _ServerManagementScreenState();
}

class _ServerManagementScreenState extends State<ServerManagementScreen> {
  String _primaryServerUrl = '';
  String _backupServerUrl = '';
  bool _autoSelectLowLatency = true;
  bool _preferIpv6 = false;
  bool _speedTesting = false;

  final _remoteInputService = RemoteInputService();
  StreamSubscription<Map<String, String>>? _serverConfigSub;
  bool _qrServerConfigDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _setupServerConfigQr();
  }

  @override
  void dispose() {
    _serverConfigSub?.cancel();
    _remoteInputService.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    final primaryServerUrl = await UserDataService.getServerUrl() ?? '';
    final backupServerUrl = await UserDataService.getBackupServerUrl();
    final autoSelectLowLatency =
        await UserDataService.getAutoSelectLowLatencyServer();
    final dnsPreference = await UserDataService.getInternetServerDnsPreference();
    if (mounted) {
      setState(() {
        _primaryServerUrl = primaryServerUrl;
        _backupServerUrl = backupServerUrl;
        _autoSelectLowLatency = autoSelectLowLatency;
        _preferIpv6 = dnsPreference == InternetServerDnsPreference.ipv6;
      });
    }
  }

  void _showSnackBar(
    String message, {
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: backgroundColor ?? AppColors.bgElevated,
        duration: duration,
      ),
    );
  }

  Future<void> _setPrimaryServerUrl(String url) async {
    final trimmed = url.trim();
    await UserDataService.saveServerUrl(trimmed);
    await UserDataService.clearLastSelectedServerUrl();
    LunaTVService.resetSharedClient();
    setState(() => _primaryServerUrl = trimmed);
  }

  Future<void> _setBackupServerUrl(String url) async {
    final trimmed = url.trim();
    await UserDataService.saveBackupServerUrl(trimmed);
    await UserDataService.clearLastSelectedServerUrl();
    LunaTVService.resetSharedClient();
    setState(() => _backupServerUrl = trimmed);
  }

  Future<void> _setAutoSelectLowLatency(bool value) async {
    await UserDataService.setAutoSelectLowLatencyServer(value);
    setState(() => _autoSelectLowLatency = value);
  }

  Future<void> _setPreferIpv6(bool value) async {
    await UserDataService.saveInternetServerDnsPreference(
      value ? InternetServerDnsPreference.ipv6 : InternetServerDnsPreference.ipv4,
    );
    LunaTVService.resetSharedClient();
    setState(() => _preferIpv6 = value);
  }

  Future<void> _runSpeedTest() async {
    if (_speedTesting) return;
    if (_primaryServerUrl.isEmpty) {
      _showSnackBar('请先配置互联网服务器地址', backgroundColor: Colors.red);
      return;
    }
    setState(() => _speedTesting = true);
    try {
      final best = await ServerLatencyService.selectBestServer(
        _primaryServerUrl,
        _backupServerUrl,
      );
      _showSnackBar('已切换到延迟最低的服务器：$best');
    } catch (e) {
      _showSnackBar('测速失败: $e', backgroundColor: Colors.red);
    } finally {
      if (mounted) setState(() => _speedTesting = false);
    }
  }

  void _setupServerConfigQr() {
    _serverConfigSub = _remoteInputService.onServerConfig.listen((data) async {
      if (!mounted) return;
      final serverUrl = data['serverUrl'] ?? '';
      final backupServerUrl = data['backupServerUrl'] ?? '';
      if (serverUrl.isEmpty && backupServerUrl.isEmpty) return;

      final normalized =
          UserDataService.classifyServerUrls(serverUrl, backupServerUrl);
      // 手机端未填写的字段保留电视端原有地址，避免空值覆盖已有配置。
      if (normalized.internet.isNotEmpty) {
        await _setPrimaryServerUrl(normalized.internet);
      }
      if (normalized.lan.isNotEmpty) {
        await _setBackupServerUrl(normalized.lan);
      }

      if (_qrServerConfigDialogShowing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        setState(() => _qrServerConfigDialogShowing = false);
      }
      _showSnackBar('服务器地址已更新');
    });
  }

  Future<void> _showServerConfigQrDialog() async {
    if (_qrServerConfigDialogShowing) return;
    setState(() => _qrServerConfigDialogShowing = true);

    String? url;
    String? error;
    try {
      final baseUrl = await _remoteInputService.startServer(
        currentServerUrl: _primaryServerUrl,
        currentBackupServerUrl: _backupServerUrl,
      );
      url = '$baseUrl?mode=server_config';
    } catch (e) {
      error = '启动失败，请检查网络权限';
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return FocusScope(
          child: AlertDialog(
            backgroundColor: AppColors.bgSurface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AppRadius.lg),
            ),
          title: Text(
            '扫码修改服务器地址',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Text(
                    error,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: Colors.redAccent,
                    ),
                  )
                else if (url != null) ...[
                  Container(
                    width: 200,
                    height: 200,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: QrImageView(
                      data: url,
                      version: QrVersions.auto,
                      size: 180,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '使用手机扫描上方二维码',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '或访问 $url',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '在手机页面输入互联网/局域网服务器地址后，电视将自动保存',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ] else
                  const SizedBox(
                    width: 40,
                    height: 40,
                    child: TechLoadingIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          actions: [
            FocusableWidget(
              autofocus: true,
              onTap: () => Navigator.of(ctx).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '关闭',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        ),
        );
      },
    );

    if (mounted) {
      setState(() => _qrServerConfigDialogShowing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        elevation: 0,
        title: const Text('服务器管理'),
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
          _buildSectionTitle('服务器'),
          _buildServerAddressTile(),
          _buildBackupServerAddressTile(),
          _buildServerHintTile(),
          _buildAutoSpeedTestSwitch(),
          _buildDnsPreferenceTile(),
          _buildManualSpeedTestButton(),
          if (DeviceUtils.isTv && !DeviceUtils.isWindows)
            _buildQrModifyServerButton(),
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
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  Widget _buildServerAddressTile() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () => _showTextInputDialog(
            title: '互联网服务器地址',
            hint: '例如 https://your-lunatv-server.com（建议填写公网可访问域名）',
            current: _primaryServerUrl,
            onSave: _setPrimaryServerUrl,
          ),
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
                Text(
                  '互联网服务器地址',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _primaryServerUrl.isEmpty
                      ? '未配置，点击填写（公网域名）'
                      : _primaryServerUrl,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '建议填写公网可访问域名',
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

  Widget _buildBackupServerAddressTile() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () => _showTextInputDialog(
            title: '局域网服务器地址',
            hint: '例如 http://192.168.1.100:3000（局域网地址）',
            current: _backupServerUrl,
            onSave: _setBackupServerUrl,
          ),
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
                Text(
                  '局域网服务器地址',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _backupServerUrl.isEmpty
                      ? '未配置，点击填写（局域网地址）'
                      : _backupServerUrl,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '建议填写内网地址',
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

  Widget _buildServerHintTile() {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      child: Text(
        '提示：首次登录时至少填写一个服务器地址即可；后续可在此补充或修改两个地址。',
        style: TextStyle(
          fontSize: 12,
          color: AppColors.textSecondary,
        ),
      ),
    );
  }

  Widget _buildDnsPreferenceTile() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () => _setPreferIpv6(!_preferIpv6),
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: SwitchListTile(
            title: Text(
              '互联网服务器地址优先解析 IPv6',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              _preferIpv6 ? '优先解析 IPv6 地址' : '优先解析 IPv4 地址',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            value: _preferIpv6,
            onChanged: _setPreferIpv6,
            activeThumbColor: AppColors.primary,
            inactiveThumbColor: AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildAutoSpeedTestSwitch() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () => _setAutoSelectLowLatency(!_autoSelectLowLatency),
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: SwitchListTile(
            title: Text(
              '启动时自动测速并切换',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              '每次启动时自动选择互联网/局域网服务器中延迟最低的地址',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            value: _autoSelectLowLatency,
            onChanged: _setAutoSelectLowLatency,
            activeThumbColor: AppColors.primary,
            inactiveThumbColor: AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildManualSpeedTestButton() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: _speedTesting ? null : _runSpeedTest,
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              _speedTesting ? Icons.network_check : Icons.speed,
              color: AppColors.textSecondary,
            ),
            title: Text(
              _speedTesting ? '测速中...' : '立即测速并切换',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              _speedTesting
                  ? '正在测试互联网/局域网服务器延迟'
                  : '手动触发一次服务器延迟测速并切换到最优地址',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: _speedTesting
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: TechLoadingIndicator(strokeWidth: 2),
                  )
                : Icon(
                    Icons.chevron_right,
                    color: AppColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildQrModifyServerButton() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: _showServerConfigQrDialog,
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              Icons.qr_code_scanner,
              color: AppColors.textSecondary,
            ),
            title: Text(
              '扫码修改服务器地址',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              '使用手机扫码填写互联网/局域网服务器地址',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showTextInputDialog({
    required String title,
    required String hint,
    required String current,
    required Future<void> Function(String) onSave,
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
                    style: TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(color: AppColors.textMuted),
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
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Padding(
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
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Padding(
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
      await onSave(controller.text);
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
