// Copyright (c) 2025 Hunan OpenValley Digital Industry Development Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_ODID file.


import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import { CreateMessage } from './Messages';
import { FlutterState } from './VideoPlayerPlugin';

export interface VideoPlayerApi {
  initialize(): void;

  create(arg: CreateMessage): Promise<number>;

  dispose(playerId: number): void;

  setLooping(playerId: number, looping: boolean): void;

  setVolume(playerId: number, volume: number): void;

  setPlaybackSpeed(playerId: number, speed: number): void;

  play(playerId: number): void;

  position(playerId: number): number;

  seekTo(playerId: number, position: number): void;

  pause(playerId: number): void;

  setMixWithOthers(mixWithOthers: boolean): void;

  setup(binaryMessenger: BinaryMessenger): void;
}
