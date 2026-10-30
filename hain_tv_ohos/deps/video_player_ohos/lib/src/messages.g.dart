// Copyright (c) 2025 Huawei Device Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_HW file.
// Based on Camera.java originally written by
// Copyright 2013 The Flutter Authors.

import 'dart:async';
import 'dart:typed_data' show Float64List, Int32List, Int64List, Uint8List;

import 'package:flutter/foundation.dart' show ReadBuffer, WriteBuffer;
import 'package:flutter/services.dart';

/// Pigeon equivalent of VideoViewType.
enum PlatformVideoViewType {
  textureView,
  platformView,
}

class CreateMessage {
  CreateMessage({
    this.asset,
    this.uri,
    this.packageName,
    this.formatHint,
    required this.httpHeaders,
    this.viewType,
    this.startPositionMs,
    this.bufferDurationMs,
    this.bufferDurationForPlayingMs,
  });

  String? asset;

  String? uri;

  String? packageName;

  String? formatHint;

  Map<String?, String?> httpHeaders;

  PlatformVideoViewType? viewType;

  /// 起播起始位置（毫秒）。null / 0 表示从 0 起播。
  ///
  /// 🔴 2026-09-28 新增（HeinPlay 本地 fork，手工同步自 pigeons/messages.dart）：
  /// 让续播定位在 AVPlayer 的 prepare 阶段下发，避免「从片头顺序缓冲」。
  int? startPositionMs;

  /// 点播缓冲档位（毫秒）。null / 0 表示不下发、沿用系统默认。
  ///
  /// 🔴 2026-09-28 新增（HeinPlay 本地 fork，手工同步自 pigeons/messages.dart）：
  /// 鸿蒙 PlaybackStrategy 的缓冲字段没有运行期 setter，只能在 setMediaSource
  /// 时下发，因此必须从 create 阶段带下去。
  int? bufferDurationMs;

  /// 见 [bufferDurationMs]。
  int? bufferDurationForPlayingMs;

  Object encode() {
    return <Object?>[
      asset,
      uri,
      packageName,
      formatHint,
      httpHeaders,
      viewType?.index,
      startPositionMs,
      bufferDurationMs,
      bufferDurationForPlayingMs,
    ];
  }

  static CreateMessage decode(Object result) {
    result as List<Object?>;
    return CreateMessage(
      asset: result[0] as String?,
      uri: result[1] as String?,
      packageName: result[2] as String?,
      formatHint: result[3] as String?,
      httpHeaders:
          (result[4] as Map<Object?, Object?>?)!.cast<String?, String?>(),
      viewType: result[5] != null
          ? PlatformVideoViewType.values[result[5]! as int]
          : null,
      startPositionMs: result[6] as int?,
      bufferDurationMs: result[7] as int?,
      bufferDurationForPlayingMs: result[8] as int?,
    );
  }
}

class _OhosVideoPlayerApiCodec extends StandardMessageCodec {
  const _OhosVideoPlayerApiCodec();
  @override
  void writeValue(WriteBuffer buffer, Object? value) {
    if (value is CreateMessage) {
      buffer.putUint8(128);
      writeValue(buffer, value.encode());
    } else {
      super.writeValue(buffer, value);
    }
  }

  @override
  Object? readValueOfType(int type, ReadBuffer buffer) {
    switch (type) {
      case 128:
        return CreateMessage.decode(readValue(buffer)!);
      default:
        return super.readValueOfType(type, buffer);
    }
  }
}

class OhosVideoPlayerApi {
  /// Constructor for [OhosVideoPlayerApi].  The [binaryMessenger] named argument is
  /// available for dependency injection.  If it is left null, the default
  /// BinaryMessenger will be used which routes to the host platform.
  OhosVideoPlayerApi({BinaryMessenger? binaryMessenger})
      : _binaryMessenger = binaryMessenger;
  final BinaryMessenger? _binaryMessenger;

  static const MessageCodec<Object?> codec = _OhosVideoPlayerApiCodec();

  Future<void> initialize() async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.initialize',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList = await channel.send(null) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<int> create(CreateMessage arg_msg) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.create', codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList =
        await channel.send(<Object?>[arg_msg]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else if (replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (replyList[0] as int?)!;
    }
  }

  Future<void> dispose(int arg_playerId) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.dispose',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList =
        await channel.send(<Object?>[arg_playerId]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> setLooping(int arg_playerId, bool arg_looping) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setLooping',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList = await channel
        .send(<Object?>[arg_playerId, arg_looping]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> setVolume(int arg_playerId, double arg_volume) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setVolume',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList = await channel
        .send(<Object?>[arg_playerId, arg_volume]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> setPlaybackSpeed(int arg_playerId, double arg_speed) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setPlaybackSpeed',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList = await channel
        .send(<Object?>[arg_playerId, arg_speed]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> play(int arg_playerId) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.play', codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList =
        await channel.send(<Object?>[arg_playerId]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<int> position(int arg_playerId) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.position',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList =
        await channel.send(<Object?>[arg_playerId]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else if (replyList[0] == null) {
      throw PlatformException(
        code: 'null-error',
        message: 'Host platform returned null value for non-null return value.',
      );
    } else {
      return (replyList[0] as int?)!;
    }
  }

  Future<void> seekTo(int arg_playerId, int arg_position) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.seekTo', codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList = await channel
        .send(<Object?>[arg_playerId, arg_position]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> pause(int arg_playerId) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.pause', codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList =
        await channel.send(<Object?>[arg_playerId]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }

  Future<void> setMixWithOthers(bool arg_mixWithOthers) async {
    final BasicMessageChannel<Object?> channel = BasicMessageChannel<Object?>(
        'dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setMixWithOthers',
        codec,
        binaryMessenger: _binaryMessenger);
    final List<Object?>? replyList =
        await channel.send(<Object?>[arg_mixWithOthers]) as List<Object?>?;
    if (replyList == null) {
      throw PlatformException(
        code: 'channel-error',
        message: 'Unable to establish connection on channel.',
      );
    } else if (replyList.length > 1) {
      throw PlatformException(
        code: replyList[0]! as String,
        message: replyList[1] as String?,
        details: replyList[2],
      );
    } else {
      return;
    }
  }
}
