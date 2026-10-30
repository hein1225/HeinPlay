// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(PigeonOptions(
    dartOut: 'lib/src/messages.g.dart',
    dartTestOut: 'test/test_api.g.dart',
    arkTSOut: 'ohos/src/main/ets/components/videoplayer/Messages.ets',
    arkTSOptions: ArkTSOptions()))

/// Pigeon equivalent of VideoViewType.
enum PlatformVideoViewType { textureView, platformView }

/// Information passed to the platform view creation.
class PlatformVideoViewCreationParams {
  const PlatformVideoViewCreationParams({required this.playerId});

  final int playerId;
}

class CreateMessage {
  CreateMessage({required this.httpHeaders});
  String? asset;
  String? uri;
  String? packageName;
  String? formatHint;
  Map<String?, String?> httpHeaders;
  PlatformVideoViewType? viewType;

  /// 起播起始位置（毫秒）。null / 0 表示从 0 起播。
  ///
  /// 🔴 2026-09-28 新增（HeinPlay 本地 fork）：让「续播定位」在 AVPlayer 的
  /// prepare 阶段就下发，而不是等 initialize() 返回后再 seek。
  ///
  /// 背景：鸿蒙 AVPlayer 的公开 API 不支持「打开即定位」——
  ///   · media.PlaybackStrategy 只有 preferredBufferDuration / showFirstFrameOnPrepare
  ///     等 9 个字段，**没有起始位置**；
  ///   · createMediaSourceWithUrl(url, headers) 也无第三个参数。
  /// 而 VideoPlayer.ets 里已存在 pendingSeekPosition 机制：
  ///     seekTo(position) { if (!isPrepared) { pendingSeekPosition = position; return; } ... }
  ///     // PREPARED 状态处理器：if (pendingSeekPosition !== null) avPlayer.seek(...)
  /// 但 Dart 侧 initialize() 恰好 resolve 在 PREPARED 时刻（sendInitialized），
  /// 此时 isPrepared 已为 true，永远走不到 pendingSeekPosition 分支。
  /// 故从 create 阶段把位置带进去，让它在 prepare 期间生效。
  int? startPositionMs;

  /// 点播缓冲档位（毫秒），null/0 表示不下发、沿用系统默认。
  ///
  /// 🔴 2026-09-28 新增：此前 AvPlayerBackend 算出了档位却只打日志不下发
  /// （注释「仅记录，AVPlayer 不支持运行时下发」），导致用户设置的四个点播缓冲
  /// 级别对 AVPlayer 完全无效。
  ///
  /// 【为什么必须从 create 阶段带】鸿蒙 media.PlaybackStrategy 的缓冲字段：
  ///   · preferredBufferDuration          —— 起播前缓冲时长
  ///   · preferredBufferDurationForPlaying —— 播放中维持的缓冲水位
  /// 二者只能在 setMediaSource 时随 PlaybackStrategy 给出，**没有运行期 setter**，
  /// 因此 Dart 侧无法在 initialize() 之后补设，只能在 create 时下发。
  ///
  /// [bufferDurationMs]             → preferredBufferDuration（起播缓冲，取档位 max）
  /// [bufferDurationForPlayingMs]   → preferredBufferDurationForPlaying（稳态水位，取档位 min）
  int? bufferDurationMs;

  /// 见 [bufferDurationMs]。
  int? bufferDurationForPlayingMs;
}

@HostApi(dartHostTestHandler: 'TestHostVideoPlayerApi')
abstract class OhosVideoPlayerApi {
  void initialize();
  int create(CreateMessage msg);
  void dispose(int playerId);
  void setLooping(int playerId, bool looping);
  void setVolume(int playerId, double volume);
  void setPlaybackSpeed(int playerId, double speed);
  void play(int playerId);
  int position(int playerId);
  void seekTo(int playerId, int position);
  void pause(int playerId);
  void setMixWithOthers(bool mixWithOthers);
}
