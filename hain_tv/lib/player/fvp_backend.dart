import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../services/user_data_service.dart';
import '../utils/windows_logger.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart';

/// FVP (Flutter Video Player) backend.
///
/// On Windows, [video_player] is backed by FVP/libmdk after calling
/// `fvp.registerWith()`, so this backend delegates to [VideoPlayerBackendImpl]
/// while exposing a dedicated option label.
class FvpBackend implements VideoPlayerBackend {
  final VideoPlayerBackendImpl _impl = VideoPlayerBackendImpl();

  @override
  BoxFit get fit => _impl.fit;
  @override
  set fit(BoxFit value) => _impl.fit = value;

  @override
  Widget buildVideoWidget() => _impl.buildVideoWidget();

  @override
  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
    BufferProfileConfig? bufferConfig,
    bool isLive = false,
    VideoFormat? formatHint,
  }) async {
    debugPrint('FvpBackend open: $url isLive=$isLive');
    WindowsLogger.log('FvpBackend', 'open url=$url proxyMode=$proxyMode isLive=$isLive');
    // 在 initialize() 之前就确定低延迟缓冲配置，传入 _impl.open 于 prepare 前应用，
    // 避免首开沿用 libmdk 默认缓冲窗口而加载慢（与 exo 差距明显的主因）。
    final preInitBufferConfig = isLive
        ? BufferProfileConfig.forProfile(BufferProfile.lowLatency)
        : (bufferConfig ?? await BufferProfileConfig.current());
    try {
      await _impl.open(
        url,
        startAt: startAt,
        // fvp/libmdk 不解析 x-heinplay- 内部键，强制过滤避免泄漏到上游。
        headers: stripInternalRequestHeaders(headers, force: true),
        proxyMode: proxyMode,
        bufferConfig: bufferConfig,
        isLive: isLive,
        formatHint: formatHint,
        preInitBufferConfig: preInitBufferConfig,
      );
      debugPrint(
        'FvpBackend 已预置缓冲配置(pre-init): min=${preInitBufferConfig.fvpMinMs}ms max=${preInitBufferConfig.fvpMaxMs}ms drop=${preInitBufferConfig.fvpDrop}',
      );
      WindowsLogger.log(
        'FvpBackend',
        '缓冲配置已预置(pre-init): min=${preInitBufferConfig.fvpMinMs}ms max=${preInitBufferConfig.fvpMaxMs}ms',
      );
      WindowsLogger.log('FvpBackend', 'open 成功: $url');
    } catch (e, stack) {
      debugPrint('FvpBackend open error: $e');
      debugPrint('$stack');
      WindowsLogger.log('FvpBackend', 'open 失败: $e');
      WindowsLogger.log('FvpBackend', 'stack: $stack');
      rethrow;
    }
  }

  @override
  Future<void> play() => _impl.play();

  @override
  Future<void> pause() => _impl.pause();

  @override
  Future<void> seek(Duration position) => _impl.seek(position);

  @override
  Future<void> setSpeed(double speed) => _impl.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _impl.setVolume(volume);

  @override
  Stream<Duration> get positionStream => _impl.positionStream;

  @override
  Stream<Duration> get durationStream => _impl.durationStream;

  @override
  Stream<Duration> get bufferedStream => _impl.bufferedStream;

  @override
  Stream<bool> get playingStream => _impl.playingStream;

  @override
  Stream<void> get completedStream => _impl.completedStream;

  @override
  Future<void> dispose() => _impl.dispose();
}
