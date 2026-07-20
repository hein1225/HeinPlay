import 'package:flutter/material.dart';
import 'buffer_profile_config.dart';
import 'exo_player_buffer_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart';

/// ExoPlayer backend.
///
/// On Android, [video_player] uses ExoPlayer under the hood, so this
/// backend delegates to [VideoPlayerBackendImpl] while exposing a
/// dedicated option label for users who prefer the Android native player.
class ExoPlayerBackend implements VideoPlayerBackend {
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
  }) async {
    final effectiveConfig = bufferConfig ?? await BufferProfileConfig.current();
    try {
      await ExoPlayerBufferConfig.apply(effectiveConfig);
    } catch (e) {
      debugPrint('ExoPlayerBackend 缓冲配置下发失败（可能尚未实现原生端）: $e');
    }
    return _impl.open(
      url,
      startAt: startAt,
      headers: headers,
      proxyMode: proxyMode,
      bufferConfig: effectiveConfig,
    );
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
  Stream<bool> get playingStream => _impl.playingStream;

  @override
  Future<void> dispose() => _impl.dispose();
}
