import 'dart:async';

import 'package:flutter/material.dart';

import '../../player/player_backend_factory.dart';
import '../../player/video_player_backend.dart';
import '../../theme.dart';
import '../../services/local_video_service.dart';
import '../../services/user_data_service.dart' show PlayerBackendType;

/// 本地视频播放页（单机使用，无服务器也能看本机视频）。
///
/// 【为什么单独做一页，而不是复用影视播放页】
/// 影视播放页（MobilePlayerScreen）围绕「服务器剧集 / 多线路 / 续播」设计，
/// 依赖服务器返回的剧集列表与源信息；本地视频没有这些概念，
/// 强行复用会把一堆服务器逻辑带进单机路径，风险高。
/// 故本页只保留播放器必需的最小能力：画面、播放/暂停、进度拖动、标题。
///
/// 【播放链路】
/// 沙箱内绝对路径 → `file://` URL → [PlayerBackendFactory] 的 avplayer 后端
/// → video_player_ohos 转成 `fd://` 文件描述符交给系统 AVPlayer。
class LocalVideoPlayerScreen extends StatefulWidget {
  const LocalVideoPlayerScreen({
    super.key,
    required this.item,
  });

  final LocalVideoItem item;

  @override
  State<LocalVideoPlayerScreen> createState() => _LocalVideoPlayerScreenState();
}

class _LocalVideoPlayerScreenState extends State<LocalVideoPlayerScreen> {
  VideoPlayerBackend? _backend;
  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;

  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _playing = false;
  bool _ready = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    try {
      // 本地文件统一用 avplayer（系统原生 AVPlayer）：
      // 对本地文件的兼容性与起播速度都优于 mpv，且 fd:// 路径为其原生用法。
      final backend = await PlayerBackendFactory.createForVod(
        PlayerBackendType.avplayer,
      );
      if (!mounted) {
        await backend.dispose();
        return;
      }
      _backend = backend;
      backend.fit = BoxFit.contain;

      _posSub = backend.positionStream.listen((p) {
        if (mounted) setState(() => _position = p);
      });
      _durSub = backend.durationStream.listen((d) {
        if (mounted) setState(() => _duration = d);
      });
      _playingSub = backend.playingStream.listen((v) {
        if (mounted) setState(() => _playing = v);
      });

      await backend.open(widget.item.playUrl);
      if (mounted) {
        setState(() => _ready = true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = '本地视频播放失败：$e');
      }
    }
  }

  @override
  void dispose() {
    _posSub?.cancel();
    _durSub?.cancel();
    _playingSub?.cancel();
    _backend?.dispose();
    super.dispose();
  }

  String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    final mm = m.toString().padLeft(2, '0');
    final ss = s.toString().padLeft(2, '0');
    return h > 0 ? '$h:$mm:$ss' : '$mm:$ss';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          Positioned.fill(
            child: _backend == null
                ? const Center(child: CircularProgressIndicator())
                : Center(child: _backend!.buildVideoWidget()),
          ),
          // 顶部标题栏
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: AppSpacing.xs,
                ),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.arrow_back, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    Expanded(
                      child: Text(
                        widget.item.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // 底部控制条
          if (_error == null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  color: Colors.black54,
                  child: Row(
                    children: [
                      IconButton(
                        icon: Icon(
                          _playing ? Icons.pause : Icons.play_arrow,
                          color: Colors.white,
                        ),
                        onPressed: () async {
                          final backend = _backend;
                          if (backend == null) return;
                          if (_playing) {
                            await backend.pause();
                          } else {
                            await backend.play();
                          }
                        },
                      ),
                      Expanded(
                        child: Slider(
                          value: _position.inMilliseconds
                              .clamp(
                                0,
                                _duration.inMilliseconds > 0
                                    ? _duration.inMilliseconds
                                    : 1,
                              )
                              .toDouble(),
                          max: _duration.inMilliseconds > 0
                              ? _duration.inMilliseconds.toDouble()
                              : 1,
                          onChanged: (v) {
                            setState(() {
                              _position = Duration(milliseconds: v.round());
                            });
                          },
                          onChangeEnd: (v) {
                            _backend?.seek(Duration(milliseconds: v.round()));
                          },
                          activeColor: AppColors.primary,
                          inactiveColor: Colors.white24,
                        ),
                      ),
                      Text(
                        '${_fmt(_position)} / ${_fmt(_duration)}',
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white70,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          if (_error == null && !_ready)
            const Center(child: CircularProgressIndicator()),
        ],
      ),
    );
  }
}
