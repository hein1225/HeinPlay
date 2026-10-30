import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:hain_tv/services/ad_filter_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/player/buffer_profile_config.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/player/video_render_mode.dart';
import 'package:hain_tv/screens/settings/settings_helpers.dart';
import 'package:hain_tv/widgets/common/focusable.dart';

class VodSettingsPage extends StatefulWidget {
  const VodSettingsPage({super.key});

  @override
  State<VodSettingsPage> createState() => _VodSettingsPageState();
}

class _VodSettingsPageState extends State<VodSettingsPage> {
  // ⚠️ 初值不能写死 exo：鸿蒙没有 ExoPlayer 运行时。用平台默认（鸿蒙=fvp），
  // 保证首帧渲染到 _load() 完成之间不会闪现错误的「ExoPlayer（默认）」。
  PlayerBackendType _playerBackend = PlayerBackendFactory.platformDefault;
  bool _autoSkipOpeningEnding = true;
  bool _autoPlayNextEpisode = true;
  bool _autoSwitchSource = true;
  int _autoSwitchSourceTimeout = 15;
  bool _autoSpeedTest = true;
  String _m3u8ProxyUrl = '';
  bool _adFilterEnabled = false;
  bool _hlsPrefetchEnabled = false;
  BufferProfile _bufferProfile = BufferProfile.standard;
  VideoRenderMode _renderMode = VideoRenderMode.texture;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final backend = await UserDataService.getPlayerBackend();
    // ⚠️ 可用性校验：鸿蒙只有 fvp，历史设置里的 `exo` 必须纠正，
    // 否则本页单选组会错误显示「ExoPlayer（默认）」（点选后也不生效）。
    final effectiveBackend =
        PlayerBackendFactory.availableBackends.contains(backend)
        ? backend
        : PlayerBackendFactory.platformDefault;
    final skip = await UserDataService.getAutoSkipOpeningEnding();
    final next = await UserDataService.getAutoPlayNextEpisode();
    final autoSwitchSource = await UserDataService.getAutoSwitchSource();
    final autoSwitchSourceTimeout =
        await UserDataService.getAutoSwitchSourceTimeout();
    final autoSpeedTest = await UserDataService.getAutoSpeedTest();
    final m3u8ProxyUrl = await UserDataService.getM3u8ProxyUrl();
    final adFilterEnabled = await AdFilterService.isEnabled();
    final hlsPrefetchEnabled = await UserDataService.getHlsPrefetchEnabled();
    final bufferProfile = await UserDataService.getBufferProfile();
    final renderMode = await UserDataService.getVodRenderMode();
    if (!mounted) return;
    setState(() {
      _playerBackend = effectiveBackend;
      _autoSkipOpeningEnding = skip;
      _autoPlayNextEpisode = next;
      _autoSwitchSource = autoSwitchSource;
      _autoSwitchSourceTimeout = autoSwitchSourceTimeout;
      _autoSpeedTest = autoSpeedTest;
      _m3u8ProxyUrl = m3u8ProxyUrl;
      _adFilterEnabled = adFilterEnabled;
      _hlsPrefetchEnabled = hlsPrefetchEnabled;
      _bufferProfile = bufferProfile;
      _renderMode = renderMode;
    });
  }

  Future<void> _setPlayerBackend(PlayerBackendType value) async {
    await UserDataService.savePlayerBackend(value);
    setState(() => _playerBackend = value);
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

  Future<void> _setHlsPrefetchEnabled(bool value) async {
    await UserDataService.saveHlsPrefetchEnabled(value);
    setState(() => _hlsPrefetchEnabled = value);
  }

  Future<void> _setBufferProfile(BufferProfile value) async {
    await UserDataService.saveBufferProfile(value);
    setState(() => _bufferProfile = value);
    showSettingsSnackBar(context, '已切换为 ${bufferProfileLabel(value)}');
  }

  Future<void> _setRenderMode(VideoRenderMode value) async {
    await UserDataService.saveVodRenderMode(value);
    setState(() => _renderMode = value);
    showSettingsSnackBar(context, '点播渲染方式已切换为 ${_renderModeLabel(value)}');
  }

  String _renderModeLabel(VideoRenderMode mode) {
    return switch (mode) {
      VideoRenderMode.texture => 'TextureView（纹理）',
      VideoRenderMode.surface => 'SurfaceView（原生）',
    };
  }

  String _renderModeSubtitle(VideoRenderMode mode) {
    return switch (mode) {
      VideoRenderMode.texture => 'Flutter 外部纹理渲染，兼容性最稳（当前鸿蒙两后端默认）。',
      VideoRenderMode.surface =>
        '原生合成 surface 渲染。鸿蒙当前版本此档为预留能力，'
            '选择后实际回落到纹理并记录日志；后续接入原生通道后生效。',
    };
  }

  Widget _buildRenderModeCard() {
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
              '渲染方式',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          ...VideoRenderMode.values
              .map((mode) {
                final tiles = <Widget>[
                  buildRadioTile<VideoRenderMode>(
                    title: _renderModeLabel(mode),
                    subtitle: _renderModeSubtitle(mode),
                    value: mode,
                    groupValue: _renderMode,
                    onChanged: _setRenderMode,
                  ),
                ];
                if (mode != VideoRenderMode.values.last) {
                  tiles.add(Divider(height: 1, color: AppColors.border));
                }
                return tiles;
              })
              .expand((e) => e),
        ],
      ),
    );
  }

  Future<void> _setAutoSwitchSourceTimeout(int seconds) async {
    await UserDataService.saveAutoSwitchSourceTimeout(seconds);
    setState(() => _autoSwitchSourceTimeout = seconds);
    showSettingsSnackBar(context, '切换源超时时间已设为 $seconds 秒');
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
      case PlayerBackendType.avplayer:
        return isDefault ? 'AVPlayer（默认）' : 'AVPlayer';
      case PlayerBackendType.mpv:
        return isDefault ? 'mpv（默认）' : 'mpv';
    }
  }

  String _playerBackendSubtitle(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        // 鸿蒙工程无 Android 运行时，此值仅为兼容历史设置而保留，不会出现在选项里。
        return 'Android 原生播放器，硬解能力强';
      case PlayerBackendType.fvp:
        return '基于 libmdk，兼容性较好';
      case PlayerBackendType.vlc:
        return '基于 libvlc，格式兼容性最强';
      case PlayerBackendType.avplayer:
        // 鸿蒙原生系统播放器，与安卓的 ExoPlayer 定位对等。
        return '鸿蒙原生播放器，硬解省电、起播快';
      case PlayerBackendType.mpv:
        return '基于 libmpv，鸿蒙 XComponent 渲染、续播稳定';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '点播设置',
        isWindows: DeviceUtils.isComputer,
      ),
      body: buildSettingsScrollView(
        children: [
          buildSectionTitle('点播设置'),
          _buildPlayerBackendCard(),
          buildSwitchTile(
            context: context,
            title: '自动跳过片头片尾',
            subtitle: '到达片头/片尾区域时自动跳转',
            value: _autoSkipOpeningEnding,
            onChanged: _setAutoSkip,
          ),
          buildSwitchTile(
            context: context,
            title: '自动播放下一集',
            subtitle: '片尾结束后自动播放下一集',
            value: _autoPlayNextEpisode,
            onChanged: _setAutoNext,
          ),
          buildSwitchTile(
            context: context,
            title: '进入详情页自动测速',
            subtitle: '多源时自动测试各源速度并排序，关闭后仍支持手动测速',
            value: _autoSpeedTest,
            onChanged: _setAutoSpeedTest,
          ),
          _buildAutoSwitchSourceCard(),
          _buildM3u8ProxyTile(),
          buildSwitchTile(
            context: context,
            title: 'M3U8 去广告（本地过滤）',
            subtitle: '播放 M3U8 时使用本地规则过滤片头贴片广告',
            value: _adFilterEnabled,
            onChanged: _setAdFilterEnabled,
          ),
          buildSwitchTile(
            context: context,
            title: 'HLS 并发分片预取',
            subtitle: '开启后强制走本地代理并并发预取后续分片，弱网/换段缓冲更快；会额外消耗带宽（建议 Wi-Fi 下开启）',
            value: _hlsPrefetchEnabled,
            onChanged: _setHlsPrefetchEnabled,
          ),
          // 🔴 2026-10-07：删除「硬件解码」开关。
          //   用户决定不再暴露硬解/软解选择 —— mpv 始终优先硬解，
          //   硬解黑屏时由播放页看门狗自动回退软解，无需人工干预。
          _buildBufferProfileCard(),
          _buildRenderModeCard(),
        ],
      ),
    );
  }

  Widget _buildPlayerBackendCard() {
    final tiles = <Widget>[];
    for (final type in PlayerBackendFactory.availableBackends) {
      if (tiles.isNotEmpty) {
        tiles.add(Divider(height: 1, color: AppColors.border));
      }
      tiles.add(
        buildRadioTile<PlayerBackendType>(
          title: _playerBackendTitle(type),
          subtitle: _playerBackendSubtitle(type),
          value: type,
          groupValue: _playerBackend,
          onChanged: _setPlayerBackend,
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
              '点播源默认播放器',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          ...tiles,
        ],
      ),
    );
  }

  Widget _buildAutoSwitchSourceCard() {
    return buildSettingsCard(
      child: Column(
        children: [
          buildSwitchTile(
            context: context,
            title: '播放失败自动切换播放源',
            subtitle: '当前源无法播放时按测速顺序自动尝试其他源',
            value: _autoSwitchSource,
            onChanged: _setAutoSwitchSource,
          ),
          if (_autoSwitchSource) ...[
            Divider(height: 1, color: AppColors.border),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                '当前：$_autoSwitchSourceTimeout 秒',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
            buildRadioTile<int>(
              title: '10 秒',
              subtitle: '默认较短等待时间',
              value: 10,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
            Divider(height: 1, color: AppColors.border),
            buildRadioTile<int>(
              title: '15 秒',
              subtitle: '适中等待时间',
              value: 15,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
            Divider(height: 1, color: AppColors.border),
            buildRadioTile<int>(
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

  Widget _buildBufferProfileCard() {
    final tiles = <Widget>[
      Container(
        width: double.infinity,
        padding: const EdgeInsets.only(
          left: AppSpacing.md,
          right: AppSpacing.md,
          top: AppSpacing.md,
          bottom: AppSpacing.sm,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '缓冲模式',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '当前：${bufferProfileLabel(_bufferProfile)}',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ],
        ),
      ),
      Divider(height: 1, color: AppColors.border),
    ];

    for (final profile in BufferProfile.values) {
      tiles.add(
        buildRadioTile<BufferProfile>(
          title: bufferProfileLabel(profile),
          subtitle: bufferProfileSubtitle(profile),
          value: profile,
          groupValue: _bufferProfile,
          onChanged: _setBufferProfile,
        ),
      );
      if (profile != BufferProfile.values.last) {
        tiles.add(Divider(height: 1, color: AppColors.border));
      }
    }

    return buildSettingsCard(child: Column(children: tiles));
  }

  Widget _buildM3u8ProxyTile() {
    return buildSettingsCard(
      child: Builder(
        builder: (ctx) => FocusableWidget(
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
                            if (event is! KeyDownEvent &&
                                event is! KeyRepeatEvent) {
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
                              hintText: '例如 http://127.0.0.1:8080/proxy?url=',
                              hintStyle: TextStyle(color: AppColors.textMuted),
                              border: const OutlineInputBorder(),
                            ),
                          ),
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            _buildDialogButton(
                              node: cancelNode,
                              fieldNode: fieldNode,
                              label: '取消',
                              color: AppColors.textPrimary,
                              onClose: () => closeDialog(false),
                            ),
                            _buildDialogButton(
                              node: saveNode,
                              fieldNode: fieldNode,
                              label: '保存',
                              color: AppColors.primary,
                              onClose: () => closeDialog(true),
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
          onFocusChange: (focused) => ensureVisibleOnFocus(ctx, focused),
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
                  style: TextStyle(fontSize: 13, color: AppColors.textMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
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

  Widget _buildDialogButton({
    required FocusNode node,
    required FocusNode fieldNode,
    required String label,
    required Color color,
    required VoidCallback onClose,
  }) {
    return FocusableWidget(
      focusNode: node,
      onTap: onClose,
      onKeyEvent: (n, event) {
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
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}
