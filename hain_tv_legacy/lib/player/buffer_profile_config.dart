import '../services/user_data_service.dart';

/// 分级缓冲策略的各后端参数配置。
class BufferProfileConfig {
  final int exoMinBufferMs;
  final int exoMaxBufferMs;
  final int exoBufferForPlaybackMs;
  final int exoBufferForPlaybackAfterRebufferMs;
  final int exoBackBufferMs;

  final int fvpMinMs;
  final int fvpMaxMs;
  final bool fvpDrop;

  /// VLC（libvlc）的网络/文件缓存毫秒数，对应 `--network-caching` /
  /// `--file-caching`。与 exo、fvp 一样由用户的「缓冲模式」设置驱动。
  final int vlcCachingMs;

  const BufferProfileConfig({
    required this.exoMinBufferMs,
    required this.exoMaxBufferMs,
    required this.exoBufferForPlaybackMs,
    required this.exoBufferForPlaybackAfterRebufferMs,
    required this.exoBackBufferMs,
    required this.fvpMinMs,
    required this.fvpMaxMs,
    required this.fvpDrop,
    required this.vlcCachingMs,
  });

  static const _standard = BufferProfileConfig(
    exoMinBufferMs: 15000,
    exoMaxBufferMs: 30000,
    exoBufferForPlaybackMs: 1000,
    exoBufferForPlaybackAfterRebufferMs: 3000,
    exoBackBufferMs: 30000,
    // fvp 的缓冲窗口（min=起播/重缓冲阈值，max=预读窗口）。
    // 注意 libmdk 默认是 min 1000 / max 4000：只预读 4 秒，网络一抖就断流重缓冲。
    // 这里把预读窗口放大到 12 秒，同时对起播阈值保持 libmdk 默认的 1 秒。
    // ⚠️ 该配置必须由 initialize() 之后的 setBufferRange 应用才有效，
    // 详见 video_player_backend_impl.dart 中 setBufferRange 调用点的说明。
    fvpMinMs: 1000,
    fvpMaxMs: 12000,
    fvpDrop: false,
    vlcCachingMs: 3000,
  );

  static const _enhanced = BufferProfileConfig(
    exoMinBufferMs: 30000,
    exoMaxBufferMs: 60000,
    exoBufferForPlaybackMs: 1500,
    exoBufferForPlaybackAfterRebufferMs: 3000,
    exoBackBufferMs: 60000,
    fvpMinMs: 1500,
    fvpMaxMs: 20000,
    fvpDrop: false,
    vlcCachingMs: 8000,
  );

  static const _power = BufferProfileConfig(
    exoMinBufferMs: 60000,
    exoMaxBufferMs: 120000,
    exoBufferForPlaybackMs: 2000,
    exoBufferForPlaybackAfterRebufferMs: 5000,
    exoBackBufferMs: 120000,
    fvpMinMs: 2000,
    fvpMaxMs: 30000,
    fvpDrop: false,
    vlcCachingMs: 15000,
  );

  static const _lowLatency = BufferProfileConfig(
    exoMinBufferMs: 1000,
    exoMaxBufferMs: 5000,
    exoBufferForPlaybackMs: 200,
    exoBufferForPlaybackAfterRebufferMs: 500,
    exoBackBufferMs: 0,
    fvpMinMs: 0,
    fvpMaxMs: 1000,
    fvpDrop: true,
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
