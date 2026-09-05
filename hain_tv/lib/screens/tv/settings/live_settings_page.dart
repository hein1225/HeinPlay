import 'package:flutter/material.dart';

import 'package:hain_tv/services/live_source_refresh_notifier.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/screens/tv/settings/settings_helpers.dart';

class LiveSettingsPage extends StatefulWidget {
  const LiveSettingsPage({super.key});

  @override
  State<LiveSettingsPage> createState() => _LiveSettingsPageState();
}

class _LiveSettingsPageState extends State<LiveSettingsPage> {
  PlayerBackendType _livePlayerBackend = PlayerBackendType.exo;
  bool _lunaTvLiveEnabled = true;
  bool _epgLoadEnabled = true;
  bool _localProxyEnabled = false;
  bool _seamlessSwitchEnabled = false;
  bool _fccFastSwitchEnabled = false;
  int _liveSourceCacheHours = 24;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final liveBackend = await UserDataService.getLivePlayerBackend();
    final lunaTvLiveEnabled = await UserDataService.getLunaTvLiveEnabled();
    final epgLoadEnabled = await UserDataService.getEpgLoadEnabled();
    final liveSourceCacheHours =
        await UserDataService.getLiveSourceCacheHours();
    final localProxyEnabled = await UserDataService.getLocalProxyEnabled();
    final seamlessSwitch = await UserDataService.getSeamlessChannelSwitch();
    final fccFastSwitch = await UserDataService.getFccFastSwitch();
    if (!mounted) return;
    setState(() {
      _livePlayerBackend = liveBackend;
      _lunaTvLiveEnabled = lunaTvLiveEnabled;
      _epgLoadEnabled = epgLoadEnabled;
      _localProxyEnabled = localProxyEnabled;
      _seamlessSwitchEnabled = seamlessSwitch;
      _fccFastSwitchEnabled = fccFastSwitch;
      _liveSourceCacheHours = liveSourceCacheHours;
    });
  }

  Future<void> _setLivePlayerBackend(PlayerBackendType value) async {
    await UserDataService.saveLivePlayerBackend(value);
    setState(() => _livePlayerBackend = value);
  }

  Future<void> _setLunaTvLiveEnabled(bool value) async {
    await UserDataService.saveLunaTvLiveEnabled(value);
    setState(() => _lunaTvLiveEnabled = value);
    LiveSourceRefreshNotifier.instance.notify();
  }

  Future<void> _setEpgLoadEnabled(bool value) async {
    await UserDataService.saveEpgLoadEnabled(value);
    setState(() => _epgLoadEnabled = value);
  }

  Future<void> _setLiveSourceCacheHours(int hours) async {
    await UserDataService.saveLiveSourceCacheHours(hours);
    setState(() => _liveSourceCacheHours = hours);
    showSettingsSnackBar(context, '直播源缓存时间已设为 ${hours ~/ 24} 天');
  }

  Future<void> _setLocalProxyEnabled(bool value) async {
    await UserDataService.saveLocalProxyEnabled(value);
    setState(() => _localProxyEnabled = value);
    showSettingsSnackBar(
      context,
      value ? '已开启本地 M3U8 代理' : '已关闭本地 M3U8 代理',
    );
  }

  Future<void> _setSeamlessSwitchEnabled(bool value) async {
    await UserDataService.saveSeamlessChannelSwitch(value);
    setState(() => _seamlessSwitchEnabled = value);
    showSettingsSnackBar(
      context,
      value ? '已开启无缝换台' : '已关闭无缝换台',
    );
  }

  Future<void> _setFccFastSwitchEnabled(bool value) async {
    await UserDataService.saveFccFastSwitch(value);
    setState(() => _fccFastSwitchEnabled = value);
    showSettingsSnackBar(
      context,
      value ? '已开启 FCC 快速换台' : '已关闭 FCC 快速换台',
    );
  }

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

  String _livePlayerBackendSubtitle(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        return 'Android 原生播放器，硬解能力强';
      case PlayerBackendType.fvp:
        return '基于 libmdk，兼容性较好';
      case PlayerBackendType.vlc:
        return '基于 libvlc，格式兼容性最强';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '直播设置',
        isWindows: DeviceUtils.isWindows,
      ),
      body: buildSettingsScrollView(
        children: [
          buildSectionTitle('换台优化'),
          buildSwitchTile(
            context: context,
            title: '无缝换台',
            subtitle: '开启后换台时当前画面继续播放，目标频道在后台预载，'
                '就绪后再切换（最多等待 ${UserDataService.seamlessSwitchTimeoutMs ~/ 1000} 秒，'
                '超时直接切换）。预载期间同时解码两路直播流，'
                '会消耗更多流量与设备性能。默认关闭',
            value: _seamlessSwitchEnabled,
            onChanged: _setSeamlessSwitchEnabled,
          ),
          const SizedBox(height: AppSpacing.md),
          buildSwitchTile(
            context: context,
            title: 'FCC 快速换台',
            subtitle: '开启后优先使用直播源提供的 FCC 地址拉流，缩短换台等待；'
                '源未提供 FCC 地址的频道自动使用普通地址。默认关闭',
            value: _fccFastSwitchEnabled,
            onChanged: _setFccFastSwitchEnabled,
          ),
          const SizedBox(height: AppSpacing.md),
          buildSectionTitle('直播设置'),
          buildSwitchTile(
            context: context,
            title: '本地 M3U8 代理',
            subtitle: '开启后直播 M3U8 经本地代理转发，用于排查/兼容个别直播源'
                '（如神盾TV）；关闭则直播直连原始地址。默认关闭',
            value: _localProxyEnabled,
            onChanged: _setLocalProxyEnabled,
          ),
          const SizedBox(height: AppSpacing.md),
          _buildLivePlayerBackendCard(),
          buildSwitchTile(
            context: context,
            title: '启用 LunaTV 服务器直播源',
            subtitle: '关闭后将不再获取 LunaTV 服务端提供的直播频道',
            value: _lunaTvLiveEnabled,
            onChanged: _setLunaTvLiveEnabled,
          ),
          const SizedBox(height: AppSpacing.md),
          buildSwitchTile(
            context: context,
            title: '加载 EPG 节目单',
            subtitle:
                '关闭后不拉取节目单与时移信息，直播连接更快；开启时（默认）频道就绪后立即开播，节目单后台异步加载',
            value: _epgLoadEnabled,
            onChanged: _setEpgLoadEnabled,
          ),
          const SizedBox(height: AppSpacing.md),
          _buildLiveSourceCacheCard(),
        ],
      ),
    );
  }

  Widget _buildLivePlayerBackendCard() {
    final tiles = <Widget>[];
    for (final type in PlayerBackendFactory.availableBackends) {
      if (tiles.isNotEmpty) {
        tiles.add(Divider(height: 1, color: AppColors.border));
      }
      tiles.add(
        buildRadioTile<PlayerBackendType>(
          title: _livePlayerBackendTitle(type),
          subtitle: _livePlayerBackendSubtitle(type),
          value: type,
          groupValue: _livePlayerBackend,
          onChanged: _setLivePlayerBackend,
        ),
      );
    }
    return buildSettingsCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '直播默认播放器',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          ...tiles,
        ],
      ),
    );
  }

  Widget _buildLiveSourceCacheCard() {
    return buildSettingsCard(
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
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<int>(
            title: '1 天',
            subtitle: '默认缓存时间',
            value: 24,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<int>(
            title: '2 天',
            subtitle: '48小时缓存',
            value: 48,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<int>(
            title: '3 天',
            subtitle: '72小时缓存',
            value: 72,
            groupValue: _liveSourceCacheHours,
            onChanged: _setLiveSourceCacheHours,
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<int>(
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
}
