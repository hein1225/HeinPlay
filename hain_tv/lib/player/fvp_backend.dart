import 'package:flutter/material.dart';
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
  }) async {
    debugPrint('FvpBackend open: $url');
    try {
      await _impl.open(
        url,
        startAt: startAt,
        headers: headers,
        proxyMode: proxyMode,
      );
    } catch (e, stack) {
      debugPrint('FvpBackend open error: $e');
      debugPrint('$stack');
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
  Stream<bool> get playingStream => _impl.playingStream;

  @override
  Future<void> dispose() => _impl.dispose();
}
