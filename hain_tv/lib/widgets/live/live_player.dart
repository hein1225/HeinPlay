import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../player/player_backend_factory.dart';
import '../../player/video_player_backend.dart';
import '../../theme.dart';
import '../../utils/windows_logger.dart';

/// 直播播放器控制器：用于在播放器外部对已挂载的播放器进行定位（回放流内 seek）。
class LivePlayerController {
  _LivePlayerState? _state;

  void _attach(_LivePlayerState state) => _state = state;
  void _detach(_LivePlayerState state) {
    if (_state == state) _state = null;
  }

  /// 是否已挂载到实际播放器。
  bool get isAttached => _state != null;

  /// 定位到指定位置（相对当前打开的流起点）。
  Future<void> seek(Duration position) => _state?._seek(position) ?? Future.value();

  /// 暂停播放（停止渲染），供退出播放前停止直播流推帧使用。
  Future<void> pause() => _state?._pause() ?? Future.value();

  /// 恢复播放。
  Future<void> play() => _state?._play() ?? Future.value();
}

/// 通用直播播放器组件。
///
/// 直播播放器独立于点播播放器，不继承点播源的去广告等设置。
/// 按当前平台直播默认后端初始化播放器，组件 dispose 时自动释放播放器资源。
class LivePlayer extends StatefulWidget {
  final String url;
  final VideoFormat? formatHint;
  final bool paused;
  final LivePlayerController? controller;

  /// 附加到播放请求的 HTTP 请求头（可包含内部特殊键如代理地址）。
  final Map<String, String>? headers;

  const LivePlayer({
    super.key,
    required this.url,
    this.formatHint,
    this.paused = false,
    this.controller,
    this.headers,
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
    widget.controller?._attach(this);
    _initBackend();
  }

  @override
  void didUpdateWidget(covariant LivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.url != widget.url || oldWidget.headers != widget.headers) {
      _openUrl(widget.url);
    } else if (oldWidget.paused != widget.paused && _backend != null) {
      if (widget.paused) {
        _backend!.pause();
      } else {
        _backend!.play();
      }
    }
  }

  /// 定位到指定位置（相对当前打开的流起点）。
  Future<void> _seek(Duration position) async {
    try {
      await _backend?.seek(position);
    } catch (_) {
      // 部分后端/流不支持定位时静默忽略。
    }
  }

  /// 暂停播放（停止渲染）。
  Future<void> _pause() async {
    try {
      await _backend?.pause();
    } catch (_) {
      // 初始化失败/已销毁时忽略。
    }
  }

  /// 恢复播放。
  Future<void> _play() async {
    try {
      await _backend?.play();
    } catch (_) {
      // 初始化失败/已销毁时忽略。
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
      await _backend!.open(
        url,
        isLive: true,
        formatHint: widget.formatHint,
        headers: widget.headers,
      );
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
    WindowsLogger.log('LivePlayer', 'dispose 开始');
    widget.controller?._detach(this);
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    // 销毁播放器后端。
    //
    // 立即销毁时 VideoPlayer 纹理仍挂载于正在卸载的子树，Windows FVP 释放
    // 纹理时易与渲染线程竞态导致退出卡死/闪退。因此先立即暂停（停止渲染
    // 与声音），再延迟到 widget 树卸载完成后销毁，且不阻塞页面退出。
    final backend = _backend;
    _backend = null;
    if (backend != null) {
      unawaited(
        backend.pause().catchError((Object e) {
          debugPrint('LivePlayer 退出暂停播放器失败: $e');
          WindowsLogger.log('LivePlayer', 'pause 失败: $e');
        }).then((_) {
          WindowsLogger.log('LivePlayer', 'pause 完成');
        }),
      );
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 500), () async {
          WindowsLogger.log('LivePlayer', '开始延迟销毁');
          try {
            await backend.dispose();
            WindowsLogger.log('LivePlayer', '延迟销毁完成');
          } catch (e) {
            debugPrint('LivePlayer 延迟销毁播放器失败: $e');
            WindowsLogger.log('LivePlayer', '延迟销毁失败: $e');
          }
        }),
      );
    }
    super.dispose();
    WindowsLogger.log('LivePlayer', 'dispose 结束');
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
