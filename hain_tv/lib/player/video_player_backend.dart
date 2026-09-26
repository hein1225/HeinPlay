import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'buffer_profile_config.dart';

abstract class VideoPlayerBackend {
  Widget buildVideoWidget();

  BoxFit get fit;
  set fit(BoxFit value);

  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
    BufferProfileConfig? bufferConfig,
    bool isLive = false,
    VideoFormat? formatHint,
    /// 强制使用 textureView 渲染（即使平台默认是 platformView）。
    /// 仅供 fvp 后端使用：Android 上 fvp/libmdk 的 platformView 路径点播会卡死。
    bool preferTextureView = false,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);

  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<Duration> get bufferedStream;
  Stream<bool> get playingStream;

  /// 播放完成事件流。每个 [open] 周期内应仅触发一次，
  /// 用于在 position 流未精确到达片尾时仍能可靠切下一集。
  Stream<void> get completedStream;

  /// fvp 续播卡死且 App 层 seek 重试/回退片头均 no-op 时触发，
  /// 上抛到播放页以自动切换后端（如 ExoPlayer）。仅 fvp 后端会赋值并触发，
  /// 其余后端以空实现满足接口契约。
  void set onUnrecoverableStall(VoidCallback? cb);

  Future<void> dispose();
}
