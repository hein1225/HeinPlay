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

  Future<void> dispose();
}
