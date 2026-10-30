import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'buffer_profile_config.dart';

abstract class VideoPlayerBackend {
  Widget buildVideoWidget();

  BoxFit get fit;
  set fit(BoxFit value);

  /// 是否需要**提前挂载**视频 widget（在播放真正开始之前就进入 widget 树）。
  ///
  /// mpv 后端为 true：原生 mpv 实例随 PlatformView 创建，而「等待 view 创建」
  /// 会与续播定位闸门互相死锁，因此播放页需提前挂载。
  /// 旧 fvp 后端为 false（其 open() 不依赖 Flutter 侧挂载）。
  bool get requiresEagerMount;

  /// 纹理路线下已注册的 Flutter 外部纹理 id；未就绪或平台视图路线时为 null。
  ///
  /// 供播放页用 `Texture(textureId)` 显示画面。
  int? get textureId;

  /// 纹理 id 就绪（或更换）时推送，用于触发播放页重建。
  Stream<int> get textureReadyStream;

  /// 首帧已出画事件流。用于隐藏「加载中」遮罩并启动计时等逻辑。
  ///
  /// 默认实现为永不触发的空流；仅 mpv 后端会实际推送。
  Stream<void> get firstFrameStream => const Stream<void>.empty();

  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
    BufferProfileConfig? bufferConfig,
    bool isLive = false,
    VideoFormat? formatHint,

    /// 强制使用 textureView 渲染（即使平台默认是 platformView）。
    /// 仅供历史 fvp 后端使用；tvLegacy 已移除 fvp，mpv 恒为纹理路线。
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
  ///
  /// tvLegacy 已移除 fvp，该回调恒为 null；保留以兼容共享代码路径。
  void set onUnrecoverableStall(VoidCallback? cb);

  Future<void> dispose();
}
