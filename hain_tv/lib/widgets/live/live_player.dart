import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../player/player_backend_factory.dart';
import '../../player/video_player_backend.dart';
import '../../theme.dart';
import '../../utils/windows_logger.dart';
import '../common/tech_loading_indicator.dart';

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

  /// 直播播放器是否因进入后台而被关闭（需用户手动继续）。
  bool get isStopped => _state?._stopped ?? false;
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

  /// 是否静音。无缝换台时后台预载的频道以静音方式解码，
  /// 切换为主画面后再取消静音，避免两路声音同时输出。
  final bool muted;

  /// 首帧就绪回调（底层开始播放/拿到时长）。同一个 URL 只回调一次。
  final VoidCallback? onReady;

  /// 打开失败回调，供无缝换台在预载失败时立即放弃等待。
  final void Function(String message)? onFailed;

  /// 是否显示内置的加载圈/错误提示遮罩。
  /// 后台预载时置 false，避免预载中的提示层影响后续画面。
  final bool showOverlay;

  LivePlayer({
    super.key,
    required this.url,
    this.formatHint,
    this.paused = false,
    this.controller,
    this.headers,
    this.muted = false,
    this.onReady,
    this.onFailed,
    this.showOverlay = true,
  });

  @override
  State<LivePlayer> createState() => _LivePlayerState();
}

class _LivePlayerState extends State<LivePlayer> {
  VideoPlayerBackend? _backend;
  bool _initializing = true;
  String? _error;
  final List<StreamSubscription> _subscriptions = [];

  /// 是否因进入后台（最小化/待机）而关闭了播放。直播流无法暂停，后台时直接
  /// 释放播放器与视频纹理；回到前台后停留在“已停止”态，由用户手动继续播放，
  /// 避免自动重载在部分设备出现黑屏有声音的僵尸播放器。
  bool _stopped = false;

  /// 当前 URL 的就绪回调是否已触发，避免 playing/duration 流重复回调。
  bool _readyNotified = false;

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
    if (oldWidget.muted != widget.muted) {
      _applyVolume();
    }
  }

  /// 按 [LivePlayer.muted] 应用音量（静音 0，正常 1）。
  Future<void> _applyVolume() async {
    try {
      await _backend?.setVolume(widget.muted ? 0.0 : 1.0);
    } catch (_) {
      // 部分后端在未就绪时设置音量会抛错，忽略即可。
    }
  }

  /// 触发一次就绪回调（同一 URL 只触发一次）。
  void _notifyReady() {
    if (_readyNotified) return;
    _readyNotified = true;
    final callback = widget.onReady;
    if (callback == null) return;
    // 避免在 build/stream 回调栈内直接触发父级 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
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
          // 同时清除可能因 transient 异常（如 VLC controller 尚未 attach）
          // 而残留的播放失败提示，避免画面已正常播放却仍显示错误。
          if (mounted && (_initializing || _error != null)) {
            setState(() {
              _initializing = false;
              _error = null;
            });
          }
          _notifyReady();
        }),
      )
      ..add(
        backend.durationStream.listen((_) {
          if (mounted && (_initializing || _error != null)) {
            setState(() {
              _initializing = false;
              _error = null;
            });
          }
          _notifyReady();
        }),
      );
    await _openUrl(widget.url);
  }

  Future<void> _openUrl(String url) async {
    if (_backend == null || url.isEmpty) return;

    _readyNotified = false;
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
      await _applyVolume();
      if (widget.paused) {
        await _backend!.pause();
      } else {
        await _backend!.play();
      }
    } catch (e, stackTrace) {
      debugPrint('LivePlayer 播放失败: $e');
      debugPrint('$stackTrace');
      WindowsLogger.log('LivePlayer', 'open/play 失败: $e');
      if (mounted) {
        setState(() {
          _error = '播放失败: $e';
          _initializing = false;
        });
      }
      final failed = widget.onFailed;
      if (failed != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) failed('$e');
        });
      }
    }
  }

  /// 后台关闭后由用户手动继续播放：恢复入口在 live_player_screen 通过卸载并
  /// 重挂 LivePlayer（全新实例）实现。卸载走 Flutter 正常的平台视图拆除流程，
  /// 由系统先释放 fvp 视频纹理与 SurfaceView，再延迟释放后端，规避“组件仍挂载时
  /// 手动 dispose 后端 → 原生 surface 回调打在已释放后端上 → SIGSEGV 闪退”的问题。

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
        Future<void>.delayed(Duration(milliseconds: 500), () async {
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
          if (_initializing && widget.showOverlay)
            Container(
              color: Colors.black54,
              child: Center(
                child: TechLoadingIndicator(),
              ),
            ),
          if (_error != null && widget.showOverlay)
            Container(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: AppColors.error,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          if (_stopped)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      color: AppColors.primary,
                      size: 48,
                    ),
                    SizedBox(height: AppSpacing.md),
                    Text(
                      '已停止播放，点击屏幕继续',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Color(0xFFF0F0F5),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
