import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../player/player_backend_factory.dart';
import '../../player/video_player_backend.dart';
import '../../theme.dart';

/// 通用直播播放器组件。
///
/// 直播播放器独立于点播播放器，不继承点播源的去广告等设置。
/// 按当前平台直播默认后端初始化播放器，组件 dispose 时自动释放播放器资源。
class LivePlayer extends StatefulWidget {
  final String url;
  final VideoFormat? formatHint;
  final bool paused;

  const LivePlayer({
    super.key,
    required this.url,
    this.formatHint,
    this.paused = false,
  });

  @override
  State<LivePlayer> createState() => _LivePlayerState();
}

class _LivePlayerState extends State<LivePlayer> {
  VideoPlayerBackend? _backend;
  bool _initializing = true;
  String? _error;
  final List<StreamSubscription> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    _initBackend();
  }

  @override
  void didUpdateWidget(covariant LivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _openUrl(widget.url);
    } else if (oldWidget.paused != widget.paused && _backend != null) {
      if (widget.paused) {
        _backend!.pause();
      } else {
        _backend!.play();
      }
    }
  }

  Future<void> _initBackend() async {
    final backend = await PlayerBackendFactory.createForLive();
    _backend = backend;
    backend.fit = BoxFit.contain;
    _subscriptions
      ..add(
        backend.playingStream.listen((_) {
          // 直播流通常没有固定时长，只要底层开始播放即视为就绪。
          if (mounted && _initializing) {
            setState(() => _initializing = false);
          }
        }),
      )
      ..add(
        backend.durationStream.listen((_) {
          if (mounted && _initializing) {
            setState(() => _initializing = false);
          }
        }),
      );
    await _openUrl(widget.url);
  }

  Future<void> _openUrl(String url) async {
    if (_backend == null || url.isEmpty) return;

    setState(() {
      _initializing = true;
      _error = null;
    });

    try {
      await _backend!.open(url, isLive: true, formatHint: widget.formatHint);
      if (widget.paused) {
        await _backend!.pause();
      } else {
        await _backend!.play();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '播放失败: $e';
          _initializing = false;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _backend?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_backend != null) _backend!.buildVideoWidget(),
          if (_initializing)
            Container(
              color: Colors.black54,
              child: const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
              ),
            ),
          if (_error != null)
            Container(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: AppColors.error,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
