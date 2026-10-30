import 'dart:async';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'buffer_profile_config.dart';

abstract class VideoPlayerBackend {
  Widget buildVideoWidget();

  /// 后端是否要求「提前且常驻」挂载视频层。
  ///
  /// 🔴 2026-10-14：mpv 后端恒为 true，这是**避免死锁的硬要求**。
  ///
  /// 【死锁成因】mpv 的原生实例（PlatformView）是在 Flutter 真正 build
  ///   [buildVideoWidget] 时才被创建的，而 `MpvBackend.open()` 必须等这个
  ///   view 的 id（`onPlatformViewCreated`）才能下发命令。若播放页沿用
  ///   「`_initialized` 之前不挂载视频层」的既有逻辑，就形成闭环：
  ///     open() 等 view → view 要 buildVideoWidget 被调用
  ///       → 被 `_initialized` 拦住 → `_initialized` 又要等 open() 成功。
  ///   真机实测：点播必然卡满 5 秒后抛「等待 AndroidView view 创建超时」，
  ///   view 在抛错后 23ms 才被创建；直播则虽走到原生但 mpv 全程零输出。
  ///
  /// 【处理】为 true 时，播放页在 `_openEpisodeImpl` 一开始就挂载视频层，
  ///   并全程缓存同一个 widget 实例，用不透明遮罩隐藏定位前的画面。
  ///   本字段与 `hain_tv_legacy` 的同名机制一致（legacy 已用此方案跑通）。
  bool get requiresEagerMount;

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

  /// fvp 续播卡死且 App 层 seek 重试/回退片头均 no-op 时触发，
  /// 上抛到播放页以自动切换后端（如 ExoPlayer）。仅 fvp 后端会赋值并触发，
  /// 其余后端以空实现满足接口契约。
  void set onUnrecoverableStall(VoidCallback? cb);

  Future<void> dispose();
}
