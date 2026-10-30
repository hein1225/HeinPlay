import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'buffer_profile_config.dart';
import 'video_render_mode.dart';

abstract class VideoPlayerBackend {
  Widget buildVideoWidget();

  BoxFit get fit;
  set fit(BoxFit value);

  /// 渲染方式（SurfaceView / TextureView）。
  ///
  /// 由工厂按场景（点播→vod 设置、直播→live 设置）在创建后端后设置，
  /// open() 内部据此选择渲染路径。默认 [VideoRenderMode.texture]。
  ///
  /// 🔴 2026-10-07：鸿蒙当前两后端仅纹理可用；置 [VideoRenderMode.surface] 时
  ///   后端回落到纹理并打日志标注（详见 avplayer_backend / mpv_backend）。
  VideoRenderMode get renderMode;
  set renderMode(VideoRenderMode value);

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

  /// 首帧「画面已可见」事件流。每个 [open] 周期内至多触发一次。
  ///
  /// 🔴 2026-09-28 新增：用于无缝换台时判断新频道画面是否**真的**可以看了。
  ///   走 texture 渲染的平台（鸿蒙 / 桌面端）上，「底层报告 playing」远早于
  ///   「纹理产出首帧」——若一收到 playing 就撤掉冻结的旧画面，会黑屏/花屏一下
  ///   才恢复，即用户反馈的「换台卡一下，过一下才正常播放」。
  ///
  /// 各后端以空实现满足契约时，订阅方须自行设置超时兜底，避免永不切换。
  Stream<void> get firstFrameStream;

  /// fvp 续播卡死且 App 层 seek 重试/回退片头均 no-op 时触发，
  /// 上抛到播放页以自动切换后端（如 ExoPlayer）。仅 fvp 后端会赋值并触发，
  /// 其余后端以空实现满足接口契约。
  void set onUnrecoverableStall(VoidCallback? cb);

  /// 🔴🔴🔴 2026-10-24（第十六轮）：**seek 目标落在裁剪落点之前**时触发，
  /// 参数为用户轴的目标毫秒。
  ///
  /// 【语义】裁剪模式下播放列表的第 0 片 = 落点片 ⇒ 落点之前不可 seek。
  ///   后端检测到后不做 seek，而是上抛本回调，由播放页**重建播放器**
  ///   并以该目标为新落点起播（代理按新落点重新裁剪列表）。
  ///
  /// 仅 avp 后端会触发；其余后端以空实现满足接口契约。
  void set onSeekRebuildRequested(void Function(int targetMs)? cb);

  /// 是否必须在 `open()` 之前就把 [buildVideoWidget] 挂载进 widget 树。
  ///
  /// 🔴 2026-09-30 新增：mpv（mpv-arkts）走 **XComponent SURFACE** 而非 texture，
  ///   其原生 Player 实例是在 PlatformView 被 Flutter 创建时才 new 出来的。
  ///   而播放页的「续播定位闸门」会在位置抵达续播点前一直不挂载视频层 ——
  ///   于是就死锁了：
  ///     open() 等 view 创建 → view 要 buildVideoWidget 被调用
  ///       → 被闸门拦住 → 闸门要等位置事件 → 位置事件要 view 创建。
  ///
  ///   走 texture 的后端（fvp/avplayer/video_player）不受影响：它们的
  ///   `open()` 不依赖 Flutter 侧挂载，引擎自行出帧并上报位置，
  ///   闸门因此能正常开闸，之后再挂载也不迟。
  ///
  /// 置 true 的后端，播放页须**无条件提前挂载**视频层（用黑色底遮挡代替
  /// 「不挂载」来隐藏片头画面），闸门语义改由其它手段保证。
  bool get requiresEagerMount => false;

  Future<void> dispose();
}
