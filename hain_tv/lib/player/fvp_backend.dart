import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart';
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
  }) async {
    debugPrint('FvpBackend open: $url');
    WindowsLogger.log('FvpBackend', 'open url=$url proxyMode=$proxyMode');
    try {
      await _impl.open(
        url,
        startAt: startAt,
        headers: headers,
        proxyMode: proxyMode,
        bufferConfig: bufferConfig,
      );
      final effectiveConfig = bufferConfig ?? await BufferProfileConfig.current();
      final controller = _impl.controller;
      if (controller != null) {
        try {
          controller.setBufferRange(
            min: effectiveConfig.fvpMinMs,
            max: effectiveConfig.fvpMaxMs,
            drop: effectiveConfig.fvpDrop,
          );
          debugPrint(
            'FvpBackend 已应用缓冲配置: min=${effectiveConfig.fvpMinMs}ms max=${effectiveConfig.fvpMaxMs}ms drop=${effectiveConfig.fvpDrop}',
          );
          WindowsLogger.log(
            'FvpBackend',
            '缓冲配置已应用: min=${effectiveConfig.fvpMinMs}ms max=${effectiveConfig.fvpMaxMs}ms',
          );
        } catch (e) {
          debugPrint('FvpBackend setBufferRange 失败: $e');
          WindowsLogger.log('FvpBackend', 'setBufferRange 失败: $e');
        }
      }
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
  Stream<bool> get playingStream => _impl.playingStream;

  @override
  Future<void> dispose() => _impl.dispose();
}
