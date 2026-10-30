// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:mockito/mockito.dart';
import 'package:video_player_ohos/src/messages.g.dart';

class MockOhosVideoPlayerApi extends Mock implements OhosVideoPlayerApi {
  @override
  Future<void> initialize() =>
      super.noSuchMethod(
            Invocation.method(#initialize, <Object?>[]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<int> create(CreateMessage? msg) =>
      super.noSuchMethod(
            Invocation.method(#create, <Object?>[msg]),
            returnValue: Future<int>.value(0),
            returnValueForMissingStub: Future<int>.value(0),
          )
          as Future<int>;

  @override
  Future<void> dispose(int? playerId) =>
      super.noSuchMethod(
            Invocation.method(#dispose, <Object?>[playerId]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> setLooping(int? playerId, bool? looping) =>
      super.noSuchMethod(
            Invocation.method(#setLooping, <Object?>[playerId, looping]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> setVolume(int? playerId, double? volume) =>
      super.noSuchMethod(
            Invocation.method(#setVolume, <Object?>[playerId, volume]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> setPlaybackSpeed(int? playerId, double? speed) =>
      super.noSuchMethod(
            Invocation.method(#setPlaybackSpeed, <Object?>[playerId, speed]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> play(int? playerId) =>
      super.noSuchMethod(
            Invocation.method(#play, <Object?>[playerId]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<int> position(int? playerId) =>
      super.noSuchMethod(
            Invocation.method(#position, <Object?>[playerId]),
            returnValue: Future<int>.value(0),
            returnValueForMissingStub: Future<int>.value(0),
          )
          as Future<int>;

  @override
  Future<void> seekTo(int? playerId, int? position) =>
      super.noSuchMethod(
            Invocation.method(#seekTo, <Object?>[playerId, position]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> pause(int? playerId) =>
      super.noSuchMethod(
            Invocation.method(#pause, <Object?>[playerId]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;

  @override
  Future<void> setMixWithOthers(bool? mixWithOthers) =>
      super.noSuchMethod(
            Invocation.method(#setMixWithOthers, <Object?>[mixWithOthers]),
            returnValue: Future<void>.value(),
            returnValueForMissingStub: Future<void>.value(),
          )
          as Future<void>;
}
