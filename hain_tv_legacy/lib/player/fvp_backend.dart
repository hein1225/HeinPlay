import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../utils/windows_logger.dart';
import '../services/user_data_service.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart';

/// FVP (Flutter Video Player) backend.
///
/// On Windows, [video_player] is backed by FVP/libmdk after calling
/// `fvp.registerWith()`, so this backend delegates to [VideoPlayerBackendImpl]
/// while exposing a dedicated option label.
class FvpBackend implements VideoPlayerBackend {
  final VideoPlayerBackendImpl _impl = VideoPlayerBackendImpl();

  @override
  BoxFit get fit => _impl.fit;
  @override
  set fit(BoxFit value) => _impl.fit = value;

  @override
  void set onUnrecoverableStall(VoidCallback? cb) =>
      _impl.onUnrecoverableStall = cb;

  @override
  Widget buildVideoWidget() => _impl.buildVideoWidget();

  @override
  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
    BufferProfileConfig? bufferConfig,
    bool isLive = false,
    VideoFormat? formatHint,
    bool preferTextureView = false,
  }) async {
    debugPrint('FvpBackend open: $url isLive=$isLive');
    WindowsLogger.log('FvpBackend', 'open url=$url proxyMode=$proxyMode isLive=$isLive');

    // 解码器：恢复 1.3.5 行为——默认「不显式调用 setVideoDecoders」，
    // 交由 fvp 自身 registerWith 的模拟器感知逻辑决定（video_player_mdk.dart:181
    // `if (_decoders == null && !PlatformEx.isAndroidEmulator())` 会在真机偏好
    // 硬解、在 x86_64 模拟器跳过硬解改用 FFmpeg）。
    // 旧逻辑曾强制 setVideoDecoders(['AMediaCodec','FFmpeg'])，等于在模拟器上
    // 强行指定不存在的 AMediaCodec → 点播卡死（215004 实证：硬解/软解均冻结）。
    // 因此：硬解设置=开（默认）时不下发、交给 fvp 内置逻辑；
    // 软解设置=开时显式下发 ['FFmpeg'] 以按用户意图强制软解（模拟器上即 fvp 默认，
    // 不会触发 AMediaCodec 缺失问题）。
    final hw = await UserDataService.getHardwareDecoding();
    final fvpVideoDecoders = hw ? null : const ['FFmpeg'];
    // 缓冲窗口：透传调用方传入的 bufferConfig，为 null 时回退到
    // BufferProfileConfig.current()（与 ExoPlayerBackend:39 一致，
    // 点播/回放=放大窗口 min=1500/max=20000ms、直播=低延迟）。
    //
    // 🔴 该窗口最终由 _impl 在 `initialize()` **之后**调用 setBufferRange 下发
    // （2026-09-22 修复）——fvp 的 FVPControllerExtensions 要求其所有方法在
    // initialize() 后调用，否则 `_players[playerId]?.…` 静默无操作。此处只负责
    // 选档与透传，实际下发点见 video_player_backend_impl.dart「缓冲窗口下发」处。
    // ⚠️ 与 ExoPlayerBackend.open 对齐：直播恒用低延迟档。
    // 调用方 live_player 不传 bufferConfig，若此处不判 isLive，就会回退到用户设置的
    // 「点播」档（如增强档 min=1500/max=20000ms）并下发到直播 —— 直播预读 20 秒会
    // 抬高延迟、拖慢换台（注册级 lowLatency 已归零，直播低延迟完全靠这里的
    // 低延迟档 min=0/max=1000/drop=true 下发）。
    final effectiveConfig = isLive
        ? BufferProfileConfig.forProfile(BufferProfile.lowLatency)
        : (bufferConfig ?? await BufferProfileConfig.current());
    try {
      await _impl.open(
        url,
        startAt: startAt,
        // fvp/libmdk 不解析 x-heinplay- 内部键，强制过滤避免泄漏到上游。
        headers: stripInternalRequestHeaders(headers, force: true),
        proxyMode: proxyMode,
        bufferConfig: effectiveConfig,
        isLive: isLive,
        formatHint: formatHint,
        isFvpBackend: true,
        fvpVideoDecoders: fvpVideoDecoders,
        // ⚠️ 不要把 Android 的 fvp 改成 textureView —— 实测会卡死，保持 platformView。
        //
        // 曾误以为「platformView + fvp 点播卡死」是 fvp 专属缺陷，遂传
        // preferTextureView: true。真机实测（SAMSUNG SM-S9360 / Android 14）证明：
        // 走 platformView 的 fvp 点播正常（11:27 那次 5.7s 起播、position 正常递增），
        // 而改成 textureView 之后**每一次**点播都卡死，日志表现为：
        //   initialize 报「完成，耗时 3088ms」（假成功）→ 仅建 2 个 EGL context +
        //   AAudio 通路 → 此后 27 秒无 MediaCodec/CCodec/OMX 解码器活动、
        //   无任何分片网络请求、无 libmdk 输出 → 画面永久黑屏。
        // 同一条 HLS、同一个起播点下，ExoPlayer（platformView）解码器正常拉起，
        // 进一步说明问题出在 texture 这条渲染路径上，而非 platformView。
        //
        // 之前被误认为「fvp 卡死」的那几次（09:43、11:14），真实原因是去广告过滤器
        // 把 master playlist 换成了子 playlist 后被 _removeMinorityUrl 误删分片，
        // 已在 services/ad_filter_engine.dart 中修复。与本标志无关。
        //
        // Windows/Linux 的 fvp 仍按平台走 textureView（由 _impl 内部的
        // Platform.isWindows || Platform.isLinux 分支决定），本标志只影响 Android。
        preferTextureView: false,
      );
      final cfgDesc =
          'min=${effectiveConfig.fvpMinMs}ms max=${effectiveConfig.fvpMaxMs}ms '
          'drop=${effectiveConfig.fvpDrop}';
      debugPrint('FvpBackend 缓冲配置: $cfgDesc');
      debugPrint('FvpBackend 视频解码器: ${fvpVideoDecoders == null ? '跟随 fvp 内置' : fvpVideoDecoders.join(',')}'
          '（硬件解码设置=$hw）');
      WindowsLogger.log(
        'FvpBackend',
        '缓冲配置: $cfgDesc${isLive ? ' [直播]' : ' [点播/回放]'}',
      );
      WindowsLogger.log(
        'FvpBackend',
        '视频解码器: ${fvpVideoDecoders == null ? '跟随 fvp 内置（模拟器感知：真机硬解/模拟器 FFmpeg）' : fvpVideoDecoders.join(',')}（硬件解码设置=$hw）',
      );
      WindowsLogger.log('FvpBackend', 'open 成功: $url');
    } catch (e, stack) {
      debugPrint('FvpBackend open error: $e');
      debugPrint('$stack');
      WindowsLogger.log('FvpBackend', 'open 失败: $e');
      WindowsLogger.log('FvpBackend', 'stack: $stack');
      rethrow;
    }
  }

  @override
  Future<void> play() => _impl.play();

  @override
  Future<void> pause() => _impl.pause();

  @override
  Future<void> seek(Duration position) => _impl.seek(position);

  @override
  Future<void> setSpeed(double speed) => _impl.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _impl.setVolume(volume);

  @override
  Stream<Duration> get positionStream => _impl.positionStream;

  @override
  Stream<Duration> get durationStream => _impl.durationStream;

  @override
  Stream<Duration> get bufferedStream => _impl.bufferedStream;

  @override
  Stream<bool> get playingStream => _impl.playingStream;

  @override
  Stream<void> get completedStream => _impl.completedStream;

  @override
  Future<void> dispose() => _impl.dispose();
}
