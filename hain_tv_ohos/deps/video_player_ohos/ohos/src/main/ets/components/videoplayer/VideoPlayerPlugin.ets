// Copyright (c) 2025 Hunan OpenValley Digital Industry Development Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_ODID file.
// Based on VideoPlayerPlugin.java originally written by
// Copyright 2013 The Flutter Authors.

import { MethodCall, MethodCallHandler, MethodChannel, MethodResult } from '@ohos/flutter_ohos';
import AbilityAware from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityAware';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import { FlutterPlugin, FlutterPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { TextureRegistry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';
import { VideoPlayerApi } from './VideoPlayerApi';
import { VideoPlayerApiImpl } from './VideoPlayerApiImpl';
import fs from '@ohos.file.fs';

const TAG: string = "VideoPlayerPlugin";

// 将 FlutterState 类移到顶部定义
export class FlutterState {
  private binaryMessenger: BinaryMessenger;
  private textureRegistry: TextureRegistry;

  constructor(binaryMessenger: BinaryMessenger, textureRegistry: TextureRegistry) {
    this.binaryMessenger = binaryMessenger;
    this.textureRegistry = textureRegistry;
  }

  getBinaryMessenger(): BinaryMessenger {
    return this.binaryMessenger;
  }

  getTextureRegistry(): TextureRegistry {
    return this.textureRegistry;
  }
}

export class VideoPlayerPlugin implements FlutterPlugin, AbilityAware, MethodCallHandler {
  private pluginBinding: FlutterPluginBinding | null = null;
  private videoPlayerApiImpl: VideoPlayerApiImpl | null = null;
  private flutterState: FlutterState | null = null;
  private channel: MethodChannel | null = null;

  getUniqueClassName(): string {
    return TAG;
  }

  async onMethodCall(call: MethodCall, result: MethodResult): Promise<void> {
    if (call.method == "getFileFdByPath") {
      try {
        let filePath = call.argument("filePath") as string;
        Log.i(TAG, 'filePath: ' + filePath);
        let openFile: fs.File = fs.openSync(filePath);
        result.success(openFile.fd);
      } catch (e) {
        Log.e(TAG, 'getFileFdByPath failed with err: ' + e);
        result.success(-1);
      }
    }
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    this.pluginBinding = binding;
    Log.i(TAG, "VideoPlayer onAttachedToEngine");
    this.flutterState = new FlutterState(this.pluginBinding.getBinaryMessenger(), this.pluginBinding.getTextureRegistry());
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    Log.i(TAG, "VideoPlayer onDetachedFromEngine");
    this.disposeAll();
    this.pluginBinding = null;
  }

  onAttachedToAbility(binding: AbilityPluginBinding): void {
    Log.i(TAG, "VideoPlayer onAttachedToAbility");
    if (this.flutterState != null && this.pluginBinding != null && this.videoPlayerApiImpl == null) {
      this.videoPlayerApiImpl = new VideoPlayerApiImpl(this.flutterState, binding);
      this.videoPlayerApiImpl.setup(this.pluginBinding.getBinaryMessenger());
    }
    this.channel = new MethodChannel(this.pluginBinding!.getBinaryMessenger(), "plugins.flutter.io/video_player_ohos");
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromAbility(): void {
    Log.i(TAG, "VideoPlayer onDetachedFromAbility");
    this.disposeAll();
  }

  // 添加资源释放的通用方法
  private disposeAll(): void {
    if (this.videoPlayerApiImpl != null) {
      this.videoPlayerApiImpl.disposeAllPlayers();
      this.videoPlayerApiImpl = null;
    }
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
  }
}
