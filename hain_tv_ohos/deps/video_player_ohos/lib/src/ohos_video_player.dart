// Copyright (c) 2025 Huawei Device Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_HW file.
// Based on Camera.java originally written by
// Copyright 2013 The Flutter Authors.

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'video_player_ohos_channel.dart';
import 'messages.g.dart';

/// An OHOS implementation of [VideoPlayerPlatform] that uses the
/// Pigeon-generated [OhosVideoPlayerApi].
class OhosVideoPlayer extends VideoPlayerPlatform {
  OhosVideoPlayer({OhosVideoPlayerApi? pluginApi})
    : _api = pluginApi ?? OhosVideoPlayerApi();
  final OhosVideoPlayerApi _api;

  /// 下一次 [create] 要使用的起播位置（毫秒）。
  ///
  /// 🔴 2026-09-28 新增（HeinPlay 本地 fork）：
  /// 上游 [VideoPlayerPlatform.create] 的签名里没有起始位置，而主包
  /// `video_player` 传给它的 `VideoCreationOptions` 也没有该字段，
  /// 故无法通过参数链路传入。这里用「一次性预置」的方式旁路：
  /// 调用方在 create 之前调用 [setNextStartPosition]，create 时消费并清空。
  ///
  /// 之所以必须在 create 阶段传入（而非 create 之后 seekTo）：鸿蒙 AVPlayer 的
  /// prepare 阶段已开始拉流，而 VideoPlayer.ets 的 pendingSeekPosition 只在
  /// isPrepared==false 时生效；Dart 侧 initialize() 恰好 resolve 在 PREPARED 时刻，
  /// 之后调用永远走不到 pendingSeekPosition 分支，定位会晚于首次拉流。
  int? _nextStartPositionMs;

  /// 设置「下一次 create 的起播位置」（毫秒）。传 null 或 0 表示从 0 起播。
  ///
  /// 只影响紧随其后的第一次 [create]，消费后自动清空，避免污染后续播放器实例。
  void setNextStartPosition(Duration? position) {
    final int? ms = position == null ? null : position.inMilliseconds;
    _nextStartPositionMs = (ms == null || ms <= 0) ? null : ms;
  }

  /// 下一次 create 时要下发的点播缓冲档位（毫秒）。
  ///
  /// 与 [_nextStartPositionMs] 同样是「一次性预置」：
  /// 鸿蒙 PlaybackStrategy 的 preferredBufferDuration /
  /// preferredBufferDurationForPlaying 没有运行期 setter，只能在 setMediaSource
  /// 时随策略一起给出，因此必须从 create 阶段带下去。
  int? _nextBufferDurationMs;
  int? _nextBufferDurationForPlayingMs;

  /// 设置「下一次 create 的点播缓冲档位」（毫秒）。
  ///
  /// [bufferDurationMs] 起播前缓冲时长；[bufferDurationForPlayingMs] 播放中缓冲水位。
  /// 任一路传 null / ≤0 即表示该项不下发、沿用系统默认。
  /// 只影响紧随其后的第一次 [create]，消费后自动清空。
  void setNextBufferProfile({int? bufferDurationMs, int? bufferDurationForPlayingMs}) {
    _nextBufferDurationMs =
        (bufferDurationMs == null || bufferDurationMs <= 0) ? null : bufferDurationMs;
    _nextBufferDurationForPlayingMs =
        (bufferDurationForPlayingMs == null || bufferDurationForPlayingMs <= 0)
            ? null
            : bufferDurationForPlayingMs;
  }

  static void registerWith() {
    VideoPlayerPlatform.instance = OhosVideoPlayer();
  }

  @override
  Future<void> init() => _api.initialize();

  @override
  Future<void> dispose(int textureId) => _api.dispose(textureId);

  @override
  Future<int?> create(DataSource dataSource) async {
    String? asset;
    String? uri;
    final httpHeaders = dataSource.httpHeaders.isEmpty
        ? null
        : Map<String?, String?>.fromEntries(dataSource.httpHeaders.entries
            .map((e) => MapEntry(e.key, e.value)));

    switch (dataSource.sourceType) {
      case DataSourceType.asset:
        asset = dataSource.asset;
        break;
      case DataSourceType.network:
        uri = dataSource.uri;
        break;
      case DataSourceType.file:
        uri = dataSource.uri?.startsWith('fd://') == true
            ? dataSource.uri
            : 'fd://${await VideoPlayerOhosChannel.getFileFdByPath(dataSource.uri!)}';
        break;
      default:
        uri = dataSource.uri;
    }

    // 消费「一次性起播位置」：取出后立即清空，确保只作用于本次 create。
    final int? startPositionMs = _nextStartPositionMs;
    _nextStartPositionMs = null;

    // 同样消费「一次性缓冲档位」。
    final int? bufferDurationMs = _nextBufferDurationMs;
    final int? bufferDurationForPlayingMs = _nextBufferDurationForPlayingMs;
    _nextBufferDurationMs = null;
    _nextBufferDurationForPlayingMs = null;

    final message = CreateMessage(
      httpHeaders: httpHeaders ?? <String?, String?>{},
      asset: asset,
      uri: uri,
      viewType: PlatformVideoViewType.textureView,
      startPositionMs: startPositionMs,
      bufferDurationMs: bufferDurationMs,
      bufferDurationForPlayingMs: bufferDurationForPlayingMs,
    );

    return _api.create(message);
  }

  @override
  Future<void> setLooping(int textureId, bool looping) {
    return _api.setLooping(textureId, looping);
  }

  @override
  Future<void> play(int textureId) {
    return _api.play(textureId);
  }

  @override
  Future<void> pause(int textureId) {
    return _api.pause(textureId);
  }

  @override
  Future<void> setVolume(int textureId, double volume) {
    return _api.setVolume(textureId, volume);
  }

  @override
  Future<void> setPlaybackSpeed(int textureId, double speed) {
    assert(speed > 0);
    return _api.setPlaybackSpeed(textureId, speed);
  }

  @override
  Future<void> seekTo(int textureId, Duration position) {
    return _api.seekTo(textureId, position.inMilliseconds);
  }

  @override
  Future<Duration> getPosition(int textureId) async {
    final int positionMs = await _api.position(textureId);
    return Duration(milliseconds: positionMs);
  }

  @override
  Stream<VideoEvent> videoEventsFor(int textureId) {
    return _eventChannelFor(textureId)
        .receiveBroadcastStream()
        .map((dynamic event) {
      final Map<dynamic, dynamic> map = event as Map<dynamic, dynamic>;
      switch (map['event']) {
        case 'initialized':
          return VideoEvent(
            eventType: VideoEventType.initialized,
            duration: Duration(milliseconds: map['duration'] as int),
            size: Size((map['width'] as num?)?.toDouble() ?? 0.0,
                (map['height'] as num?)?.toDouble() ?? 0.0),
            rotationCorrection: map['rotationCorrection'] as int? ?? 0,
          );
        case 'completed':
          return VideoEvent(
            eventType: VideoEventType.completed,
          );
        case 'bufferingUpdate':
          final List<dynamic> values = map['values'] as List<dynamic>;
          return VideoEvent(
            buffered: values.map<DurationRange>(_toDurationRange).toList(),
            eventType: VideoEventType.bufferingUpdate,
          );
        case 'bufferingStart':
          return VideoEvent(eventType: VideoEventType.bufferingStart);
        case 'bufferingEnd':
          return VideoEvent(eventType: VideoEventType.bufferingEnd);
        case 'isPlayingStateUpdate':
          return VideoEvent(
            eventType: VideoEventType.isPlayingStateUpdate,
            isPlaying: map['isPlaying'] as bool,
          );
        default:
          return VideoEvent(eventType: VideoEventType.unknown);
      }
    });
  }

  @override
  Widget buildView(int textureId) {
    return Texture(textureId: textureId);
  }

  @override
  Future<void> setMixWithOthers(bool mixWithOthers) {
    return _api.setMixWithOthers(mixWithOthers);
  }

  EventChannel _eventChannelFor(int textureId) {
    return EventChannel('flutter.io/videoPlayer/videoEvents$textureId');
  }

  static const Map<VideoFormat, String> _videoFormatStringMap =
      <VideoFormat, String>{
    VideoFormat.ss: 'ss',
    VideoFormat.hls: 'hls',
    VideoFormat.dash: 'dash',
    VideoFormat.other: 'other',
  };

  DurationRange _toDurationRange(dynamic value) {
    final List<dynamic> pair = value as List<dynamic>;
    return DurationRange(
      Duration(milliseconds: pair[0] as int),
      Duration(milliseconds: pair[1] as int),
    );
  }
}
