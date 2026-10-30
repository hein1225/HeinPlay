// Copyright (c) 2025 Hunan OpenValley Digital Industry Development Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_ODID file.

import { FlutterPlugin, FlutterPluginBinding} from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/FlutterPlugin';
import { AbilityPluginBinding } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/plugins/ability/AbilityPluginBinding';
import { BinaryMessenger } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BinaryMessenger';
import BasicMessageChannel, { Reply } from '@ohos/flutter_ohos/src/main/ets/plugin/common/BasicMessageChannel';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { FlutterRenderer } from '@ohos/flutter_ohos/src/main/ets/embedding/engine/renderer/FlutterRenderer';
import { SurfaceTextureEntry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';
import { VideoPlayer } from './VideoPlayer';
import { VideoPlayerApi } from './VideoPlayerApi';
import { CommonConstants } from './constants/CommonConstants';
import { CreateMessage,wrapError,OhosVideoPlayerApi,PlatformVideoViewType } from './Messages';
import { PlayerModel } from './PlayerModel';
import HashMap from '@ohos.util.HashMap';
import { VideoPlayerApiCodec } from './VideoPlayerApiCodec';
import { FlutterState } from './VideoPlayerPlugin';
import resourceManager from '@ohos.resourceManager';
import common from '@ohos.app.ability.common';
import { media } from '@kit.MediaKit';
import { EventChannel } from '@ohos/flutter_ohos';
import { GlobalContext } from './util/GlobalContext';
import { window } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';

const TAG: string = "VideoPlayerApiImpl";
const BLACK_COLOR = 0xFF000000;

function mapPlaybackSpeed(speed: number): media.PlaybackSpeed {
  if (speed > 0 && speed <= 0.125) {
    //x0.125
    return media.PlaybackSpeed.SPEED_FORWARD_0_125_X;
  } else if (speed > 0.125 && speed <= 0.4) {
    //x0.25
    return media.PlaybackSpeed.SPEED_FORWARD_0_25_X;
  } else if (speed > 0.4 && speed <= 0.6) {
    //x0.5
    return media.PlaybackSpeed.SPEED_FORWARD_0_50_X;
  } else if (speed > 0.6 && speed <= 0.8) {
    //x0.75
    return media.PlaybackSpeed.SPEED_FORWARD_0_75_X;
  } else if (speed > 0.8 && speed <= 1.1) {
    //x1
    return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
  } else if (speed > 1.1 && speed <= 1.4) {
    //x1.25
    return media.PlaybackSpeed.SPEED_FORWARD_1_25_X;
  } else if (speed > 1.4 && speed <= 1.6) {
    //x1.5
    return media.PlaybackSpeed.SPEED_FORWARD_1_50_X;
  } else if (speed > 1.6 && speed <= 1.8) {
    //x1.75
    return media.PlaybackSpeed.SPEED_FORWARD_1_75_X;
  } else if (speed > 1.8 && speed <= 2.0) {
    //x2.0
    return media.PlaybackSpeed.SPEED_FORWARD_2_00_X;
  } else if (speed > 2.0) {
    return media.PlaybackSpeed.SPEED_FORWARD_3_00_X;
  }
  return media.PlaybackSpeed.SPEED_FORWARD_1_00_X;
}

export class VideoPlayerApiImpl extends OhosVideoPlayerApi{
  private videoPlayers: HashMap<number, VideoPlayer> = new HashMap<number, VideoPlayer>();
  private flutterState: FlutterState | null = null;
  private binding: AbilityPluginBinding | null = null;
  private audioFocus: Boolean = false;
  private pixelMaps: HashMap<string, image.PixelMap> = new HashMap();

  constructor(flutterState: FlutterState | null, binding: AbilityPluginBinding | null) {
    super();
    this.flutterState = flutterState;
    this.binding = binding;
  }

  disposeAllPlayers(): void {
    this.videoPlayers.forEach(videoPlayer => videoPlayer?.release());
    this.videoPlayers.clear();
  }

  initialize(): void {
    Log.i(TAG, "enter initialize")
    this.disposeAllPlayers();
  }

  detach(): void {
    Log.i(TAG, "enter detach")
    this.disposeAllPlayers();
  }

  getContext(): common.UIAbilityContext {
    if (this.binding == null) {
      throw Error("Illegal binding or context state.");
    }
    return this.binding.getAbility().context;
  }

  async createBlackPixelMap(width: number, height: number): Promise<image.PixelMap> {
    const pixels32 = new Uint32Array(width * height);
    pixels32.fill(BLACK_COLOR);
    const opts: image.InitializationOptions = {
      editable: true,
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      size: { width, height }
    };
    return image.createPixelMap(pixels32.buffer, opts);
  }

  async create(arg: CreateMessage): Promise<number> {
    let windowClass = await window.getLastWindow(this.getContext())
    GlobalContext.getContext().setObject("windowClass", windowClass)
    Log.i(TAG, "enter create");
    if (this.flutterState == null) {
      throw new Error("Illegal flutterState null.");
    }
    let playerModel = new PlayerModel();
    let flutterRenderer = this.flutterState.getTextureRegistry();
    let uri: string = arg.getUri();
    let asset: string = arg.getAsset();
    let header: Record<string, string> | null = null;
    arg.getHttpHeaders().forEach((value, key) => {
      if (!header) {
        header = {}
      }
      header[key.toString()] = value.toString();
    })
    let textureId: number = flutterRenderer.getTextureId();
    let playerId: number = textureId;
    Log.i(TAG, "enter getRawFd, textureId=" + textureId);
    let surfaceTextureEntry: SurfaceTextureEntry = flutterRenderer.registerTexture(textureId);
    let windowProperties = windowClass.getWindowProperties();
    const width = windowProperties.windowRect.width;
    const height = windowProperties.windowRect.height;
    flutterRenderer.setTextureBackGroundPixelMap(textureId, await this.createBlackPixelMap(width, height));
    if (asset != null) {
      Log.i(TAG, "asset create called, asset is" + asset);
      let avMetaExtractor = await media.createAVMetadataExtractor();
      avMetaExtractor.fdSrc = await this.getContext().resourceManager.getRawFd("flutter_assets/" + asset);
      let mateData = await avMetaExtractor.fetchMetadata();
      if (mateData.hasVideo == CommonConstants.YES) {
        let avImageGenerator = await media.createAVImageGenerator();
        Log.i(TAG, "asset video create");
        avImageGenerator.fdSrc = await this.getContext().resourceManager.getRawFd("flutter_assets/" + asset);
        let pixelMap = await avImageGenerator.fetchFrameByTime(0, media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, {
          width: -1,
          height: -1
        });
        this.pixelMaps.set(JSON.stringify(arg), pixelMap);
        avImageGenerator.release();
        flutterRenderer.setTextureBackGroundPixelMap(textureId, this.pixelMaps.get(JSON.stringify(arg)));
      }
      avMetaExtractor.release();
    } else if (uri != null && uri.startsWith("fd://")) {
      Log.i(TAG, "local create called, file is" + uri);
      let avMetaExtractor = await media.createAVMetadataExtractor();
      avMetaExtractor.fdSrc = {
        fd: Number.parseInt(uri.replace("fd://", ""))
      };
      let mateData = await avMetaExtractor.fetchMetadata();
      if (mateData.hasVideo == CommonConstants.YES) {
        let avImageGenerator = await media.createAVImageGenerator();
        Log.i(TAG, "local video create");
        avImageGenerator.fdSrc = {
          fd: Number.parseInt(uri.replace("fd://", ""))
        };
        let pixelMap = await avImageGenerator.fetchFrameByTime(0, media.AVImageQueryOptions.AV_IMAGE_QUERY_NEXT_SYNC, {
          width: -1,
          height: -1
        });
        this.pixelMaps.set(JSON.stringify(arg), pixelMap);
        avImageGenerator.release();
        flutterRenderer.setTextureBackGroundPixelMap(textureId, this.pixelMaps.get(JSON.stringify(arg)));
      }
      avMetaExtractor.release();
    }
    let eventChannel: EventChannel = new EventChannel(this.flutterState.getBinaryMessenger(), "flutter.io/videoPlayer/videoEvents" + textureId.toString());
    // 🔴 2026-09-28 新增（HeinPlay 本地 fork）：取出 create 阶段带下来的起播位置，
    // 交给 VideoPlayer 预置到 pendingSeekPosition，使续播定位在 prepare 阶段生效。
    let startPositionMs: number = arg.getStartPositionMs();
    if (startPositionMs > 0) {
      Log.i(TAG, "create: 起播定位 " + startPositionMs + "ms");
    }
    // 🔴 2026-09-28 新增（HeinPlay 本地 fork）：点播缓冲档位。
    // AVPlayer 的 PlaybackStrategy 没有运行期 setter，只能在 setMediaSource 时下发，
    // 故必须在 create 阶段就把档位带进 VideoPlayer。
    let bufferDurationMs: number = arg.getBufferDurationMs();
    let bufferDurationForPlayingMs: number = arg.getBufferDurationForPlayingMs();
    if (bufferDurationMs > 0 || bufferDurationForPlayingMs > 0) {
      Log.i(TAG, "create: 缓冲档位 buffer=" + bufferDurationMs + "ms playing=" + bufferDurationForPlayingMs + "ms");
    }
    let videoPlayer: VideoPlayer;
      if (asset != null) {
        let rawFileDescriptor: resourceManager.RawFileDescriptor = await this.getContext().resourceManager.getRawFd("flutter_assets/" + asset);
        videoPlayer = new VideoPlayer(playerModel, surfaceTextureEntry, rawFileDescriptor, null, eventChannel, this.audioFocus, null, startPositionMs, bufferDurationMs, bufferDurationForPlayingMs);
      } else if (uri != null) {
        videoPlayer = new VideoPlayer(playerModel, surfaceTextureEntry, null, uri, eventChannel, this.audioFocus, header, startPositionMs, bufferDurationMs, bufferDurationForPlayingMs);
      } else {
        throw new Error("Invalid video source");
      }
      await videoPlayer.createAVPlayer();
      this.videoPlayers.set(playerId, videoPlayer);
      
      Log.i(TAG, `The player was created successfully,ID: ${playerId}`);
      return playerId;
  }

  dispose(playerId:number): void {
    const videoPlayer = this.videoPlayers.get(playerId);
    if (videoPlayer) {
      videoPlayer.release();
      if (this.flutterState) {
        this.flutterState.getTextureRegistry().unregisterTexture(playerId);
      }
      this.videoPlayers.remove(playerId);
      Log.i(TAG, `Release player resources: ${playerId}`);
    } else {
      Log.w(TAG, `Try to release an non-existent player: ${playerId}`);
    }
  }

  setLooping(playerId: number, looping: boolean) {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "setLooping, id=" + playerId + ", videoPlayer=" + videoPlayer);
    if (videoPlayer) {
      videoPlayer.setLooping(looping);
      Log.d(TAG, `Set up the player: ${playerId} loop: ${looping}`);
    } else {
      Log.w(TAG, `The player does not exist: ${playerId}`);
    }
  }

  setVolume(playerId: number, volume: number) {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "setVolume, id=" + playerId + ", videoPlayer=" + videoPlayer);
   if (videoPlayer) {
      videoPlayer.setVolume(volume);
      Log.d(TAG, `Set up the player: ${playerId} volume: ${volume}`);
    } else {
      Log.w(TAG, `The player does not exist: ${playerId}`);
    }
  }

  setPlaybackSpeed(playerId: number, speed: number) {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "setPlaybackSpeed, id=" + playerId + ", videoPlayer=" + videoPlayer);
    if (videoPlayer) {
      const enumSpeed = mapPlaybackSpeed(speed);
      videoPlayer.setSpeed(enumSpeed);
      Log.d(TAG, `Set up the player: ${playerId} speed: ${speed}`);
    } else {
      Log.w(TAG, `The player does not exist: ${playerId}`);
  }
}

  play(playerId: number) {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "play, id=" + playerId + ", videoPlayer=" + videoPlayer);
    if (videoPlayer != null) {
      videoPlayer.play();
    } else {
      Log.e(TAG, "play  videoPlayer is null");
    }

  }

  position(playerId: number): number {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "position, id=" + playerId + ", videoPlayer=" + videoPlayer);
    if (videoPlayer) {
      const position = videoPlayer.getPosition();
      Log.d(TAG, `get the player,id=${playerId} position: ${position}`);
      return position;
    }
    throw new Error(`VideoError: No player found with playerId <${playerId}>`);
  }

  seekTo(playerId: number, position: number) {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "seekTo, id=" + playerId + ", videoPlayer=" + videoPlayer);
    if (videoPlayer) {
      videoPlayer.seekTo(position);
      Log.d(TAG, `videoPlayer,id=${playerId} seekTo: ${position}`);
    } else {
      Log.w(TAG, `The player does not exist: ${playerId}`);
    }
  }

  pause(playerId:number) {
    const videoPlayer = this.videoPlayers.get(playerId);
    Log.d(TAG, "pause, id=" + playerId + ", videoPlayer=" + videoPlayer);
    if (videoPlayer) {
      videoPlayer.pause();
      Log.d(TAG, `Pause: ${playerId}`);
    } else {
      Log.w(TAG, `The player does not exist: ${playerId}`);
    }
  }

  setMixWithOthers(mixWithOthers: boolean) {
    Log.d(TAG, "set MixWithOthers:" + mixWithOthers);
    this.audioFocus = mixWithOthers;
     this.videoPlayers.forEach((videoPlayer:VideoPlayer) => {
      videoPlayer.setAudioFocus(mixWithOthers);
    });
  }

  setup(binaryMessenger: BinaryMessenger): void {
    Log.i(TAG, "设置消息通道处理程序");
    
    // 为每个方法设置消息通道
    this.setupInitializeChannel(binaryMessenger);
    this.setupCreateChannel(binaryMessenger);
    this.setupDisposeChannel(binaryMessenger);
    this.setupSetLoopingChannel(binaryMessenger);
    this.setupSetVolumeChannel(binaryMessenger);
    this.setupSetPlaybackSpeedChannel(binaryMessenger);
    this.setupPlayChannel(binaryMessenger);
    this.setupPositionChannel(binaryMessenger);
    this.setupSeekToChannel(binaryMessenger);
    this.setupPauseChannel(binaryMessenger);
    this.setupSetMixWithOthersChannel(binaryMessenger);
  }

  // 初始化通道设置
  private setupInitializeChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.initialize", 
      OhosVideoPlayerApi.getCodec() // 使用抽象类的编解码器
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        try {
          this.initialize();
          // 返回空数组表示成功，无返回值
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }

  // 创建通道设置
  private setupCreateChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.create", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let createMsg = args[0] as CreateMessage;
        
        try {
          this.create(createMsg).then((playerId: number) => {
            // 返回包含playerId的数组
            reply.reply([playerId]);
          }).catch((err:Error) => {
            reply.reply(wrapError(err));
          });
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }

  // 释放通道设置
  private setupDisposeChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.dispose", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        
        try {
          this.dispose(playerId);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }

  // 设置循环播放通道
  private setupSetLoopingChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setLooping", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        let looping = args[1] as boolean;
        
        try {
          this.setLooping(playerId, looping);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 设置音量通道
  private setupSetVolumeChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setVolume", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        let volume = args[1] as number;
        
        try {
          this.setVolume(playerId, volume);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 设置播放速度通道
  private setupSetPlaybackSpeedChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setPlaybackSpeed", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        let speed = args[1] as number;
        
        try {
          this.setPlaybackSpeed(playerId, speed);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 播放通道
  private setupPlayChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.play", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        
        try {
          this.play(playerId);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 获取位置通道
  private setupPositionChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.position", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        
        try {
          let position = this.position(playerId);
          // 返回包含位置的数组
          reply.reply([position]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 跳转通道
  private setupSeekToChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.seekTo", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        let position = args[1] as number;
        
        try {
          this.seekTo(playerId, position);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 暂停通道
  private setupPauseChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.pause", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let playerId = args[0] as number;
        
        try {
          this.pause(playerId);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }
  
  // 设置音频混合通道
  private setupSetMixWithOthersChannel(binaryMessenger: BinaryMessenger): void {
    const channel: BasicMessageChannel<Object> = new BasicMessageChannel<Object>(
      binaryMessenger, 
      "dev.flutter.pigeon.video_player_ohos.OhosVideoPlayerApi.setMixWithOthers", 
      OhosVideoPlayerApi.getCodec()
    );
    
    channel.setMessageHandler({
      onMessage: (msg: Object, reply: Reply<Object>): void => {
        let args = msg as Array<Object>;
        let mixWithOthers = args[0] as boolean;
        
        try {
          this.setMixWithOthers(mixWithOthers);
          // 返回空数组表示成功
          reply.reply([]);
        } catch (err) {
          reply.reply(wrapError(err));
        }
      }
    });
  }

}