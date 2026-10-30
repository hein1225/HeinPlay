import '../services/user_data_service.dart';

/// 分级缓冲策略的各后端参数配置。
class BufferProfileConfig {
  final int exoMinBufferMs;
  final int exoMaxBufferMs;
  final int exoBufferForPlaybackMs;
  final int exoBufferForPlaybackAfterRebufferMs;
  final int exoBackBufferMs;

  /// 鸿蒙 AVPlayer 缓冲区大小的**放大系数**（相对 exo 基准档位）。
  ///
  /// 🔴 2026-09-28：四个「缓冲模式」档次不应是固定值，每个后端都该由档位模型推导。
  /// AVPlayer 的容量不单独存值，而由 exo 档位换算：
  ///
  ///     avpBufferMb = exoMaxBufferMs / 1000 × avpBufferScale
  ///
  /// 依据官方换算「preferredBufferDuration 单位为秒，缓冲区大小 = 该值 × 1MB」，
  /// 即 1 秒缓冲 ≈ 1MB，故 exo 的秒数可直接当 MB，档位比例天然继承：
  ///   标准 30、增强 60、强力 120、低延迟 5（恰为官方最小推荐值）。
  ///
  /// [avpBufferScale] 用于整体放大/缩小，默认 1.0 即与 exo 完全对齐；
  /// 实测内存压力大可调小该系数全局收紧，无需逐档改数。
  ///
  /// ⚠️ 官方「5MB~20MB」是测试场景推荐区间而非 API 限制
  /// （media.d.ts 中该字段无 @throws、无 value range），故不设 20MB 天花板。
  final double avpBufferScale;

  /// 鸿蒙 AVPlayer 的起播/重缓冲阈值（毫秒）。
  ///
  /// 对应 preferredBufferDurationForPlaying，官方语义为「起播或重启播放的缓冲阈值」，
  /// 即缓冲低于该值才停下来等待，**不是**水位线。取值应克制（1~3 秒），
  /// 过大会导致每次轻微波动都触发长时间重缓冲。
  final int avpBufferForPlayingMs;

  /// 鸿蒙 AVPlayer 的缓冲区大小（MB），由 exo 档位派生 —— 见 [avpBufferScale] 说明。
  int get avpBufferMb => ((exoMaxBufferMs / 1000) * avpBufferScale).round();

  /// VLC（libvlc）的网络/文件缓存毫秒数，对应 `--network-caching` /
  /// `--file-caching`。与 exo、fvp 一样由用户的「缓冲模式」设置驱动。
  final int vlcCachingMs;

  const BufferProfileConfig({
    required this.exoMinBufferMs,
    required this.exoMaxBufferMs,
    required this.exoBufferForPlaybackMs,
    required this.exoBufferForPlaybackAfterRebufferMs,
    required this.exoBackBufferMs,
    required this.avpBufferScale,
    required this.avpBufferForPlayingMs,
    required this.vlcCachingMs,
  });

  static const _standard = BufferProfileConfig(
    exoMinBufferMs: 15000,
    exoMaxBufferMs: 30000,
    exoBufferForPlaybackMs: 1000,
    exoBufferForPlaybackAfterRebufferMs: 3000,
    exoBackBufferMs: 30000,
    // 鸿蒙 AVPlayer：与 exo 基准 1:1 对齐（30 秒 → 30MB）。
    avpBufferScale: 1.0,
    avpBufferForPlayingMs: 1000,
    vlcCachingMs: 3000,
  );

  static const _enhanced = BufferProfileConfig(
    exoMinBufferMs: 30000,
    exoMaxBufferMs: 60000,
    exoBufferForPlaybackMs: 1500,
    exoBufferForPlaybackAfterRebufferMs: 3000,
    exoBackBufferMs: 60000,
    // 增强档：exo 60 秒 → 60MB（同为 1:1）。
    avpBufferScale: 1.0,
    avpBufferForPlayingMs: 1500,
    vlcCachingMs: 8000,
  );

  static const _power = BufferProfileConfig(
    exoMinBufferMs: 60000,
    exoMaxBufferMs: 120000,
    exoBufferForPlaybackMs: 2000,
    exoBufferForPlaybackAfterRebufferMs: 5000,
    exoBackBufferMs: 120000,
    // 强力档：exo 120 秒 → 120MB（1:1）。该档定位即「牺牲内存换稳定」。
    avpBufferScale: 1.0,
    avpBufferForPlayingMs: 2000,
    vlcCachingMs: 15000,
  );

  static const _lowLatency = BufferProfileConfig(
    exoMinBufferMs: 1000,
    exoMaxBufferMs: 5000,
    exoBufferForPlaybackMs: 200,
    exoBufferForPlaybackAfterRebufferMs: 500,
    exoBackBufferMs: 0,
    // 直播低延迟档：exo 5 秒 → 5MB，恰为官方最小推荐值。
    avpBufferScale: 1.0,
    avpBufferForPlayingMs: 0,
    vlcCachingMs: 1000,
  );

  static BufferProfileConfig forProfile(BufferProfile profile) {
    switch (profile) {
      case BufferProfile.standard:
        return _standard;
      case BufferProfile.enhanced:
        return _enhanced;
      case BufferProfile.power:
        return _power;
      case BufferProfile.lowLatency:
        return _lowLatency;
    }
  }

  static Future<BufferProfileConfig> current() async {
    final profile = await UserDataService.getBufferProfile();
    return forProfile(profile);
  }
}

String bufferProfileLabel(BufferProfile profile) {
  switch (profile) {
    case BufferProfile.standard:
      return '标准';
    case BufferProfile.enhanced:
      return '增强';
    case BufferProfile.power:
      return '强力';
    case BufferProfile.lowLatency:
      return '低延迟';
  }
}

String bufferProfileSubtitle(BufferProfile profile) {
  switch (profile) {
    case BufferProfile.standard:
      return '平衡流畅度与内存占用（默认）';
    case BufferProfile.enhanced:
      return '更大缓冲，适合多数网络环境';
    case BufferProfile.power:
      return '最大缓冲，适合弱网或高配置设备';
    case BufferProfile.lowLatency:
      return '最小缓冲，适合直播或实时源';
  }
}
