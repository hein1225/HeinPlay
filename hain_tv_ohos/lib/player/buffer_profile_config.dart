import '../services/user_data_service.dart';

/// 分级缓冲策略的各后端参数配置。
class BufferProfileConfig {
  final int exoMinBufferMs;
  final int exoMaxBufferMs;
  final int exoBufferForPlaybackMs;
  final int exoBufferForPlaybackAfterRebufferMs;
  final int exoBackBufferMs;

  /// 鸿蒙 AVPlayer 缓冲区大小的**放大系数**（相对档位基准）。
  ///
  /// 🔴 2026-09-28 二次修订 —— 推翻上一版「容量 = exoMaxBufferMs」的推导。
  ///
  /// 【实测证据】真机日志（点播续播到 1521s，强力档）：
  ///   下发缓冲档位 preferredBufferDuration=120MB (源 120000ms → 120s)
  ///   起播耗时[首帧送显] 总计=13873ms  初始化=7ms 准备=7413ms 首帧=13873ms
  ///   起播耗时[首帧送显] 总计=10141ms  初始化=7ms 准备=3708ms 首帧=10141ms
  /// 而同机直播档（5MB）：
  ///   起播耗时[首帧送显] 总计=815/802/802/750ms
  /// **同一播放器、同一后端，容量 120MB 起播 10~14 秒，容量 5MB 起播 0.75~0.8 秒。**
  ///
  /// 【根因】`preferredBufferDuration` 的官方语义是 **buffer size（缓冲区容量）**
  /// （见 @ohos.multimedia.media.d.ts：*"is used to set the buffer size"*），
  /// 两者数值含义相近，行为完全不同：
  ///   · avp 120MB    → 只是容量上限，不产生等量预读条，反而拖慢 prepared
  ///
  /// 【修正】容量回归官方最佳实践区间（5~20MB），并让**档位比例**在其中体现。
  /// 上一版把「5~20MB 是测试推荐而非 API 限制」当作可以突破的理由，
  /// 实机证明那正是 API 的合理工作区间，超出后收益为负（起播慢、内存高）。
  /// 起播速度由 [avpBufferForPlayingMs]（起播水位）保证，与容量无关。
  ///
  /// 系数默认 1.0；如需整体收紧/放宽改此值即可，无需逐档改数。
  final double avpBufferScale;

  /// 鸿蒙 AVPlayer 的起播/重缓冲阈值（毫秒）。
  ///
  /// 对应 preferredBufferDurationForPlaying，官方语义为
  /// *"Customize the buffering threshold for start or restart playing"*，
  /// 即**起播水位**：缓冲达到该时长即开始播放。这才是决定「起播快慢」的参数。
  /// 取值应克制（1~3 秒），过大则每次轻微波动都触发长时间重缓冲。
  ///
  /// 与容量同理，默认由 exo 档位派生（exoMinBufferMs / 1000），保持各后端同构；
  /// 低延迟档（exoMin=1000）派生为 1 秒，符合直播低延迟诉求。
  final int avpBufferForPlayingMs;

  /// 鸿蒙 AVPlayer 的缓冲区容量（MB）。
  ///
  /// 🟢 2026-09-29 二次修正：**取消 20MB 天花板，按档位放大**。
  /// 依据华为官方「在线视频播放卡顿优化」实践（2026-09-14 更新，doccenter 原文）：
  ///   *"preferredBufferDuration 用于设置缓冲区大小……缓冲区越大，能够缓存的
  ///    视频数据量就越多，在遇到弱网环境或高码率视频源时可正常播放的时间也
  ///    越久，进而减少或推迟卡顿。"*
  /// 官方 5~20MB 表格是**推荐区间（内存考量），非 API 上限**（d.ts 无 @throws /
  /// value range，media.d.ts 已核实）。10/15/20MB 同档位对高码率源只够 ~10~20s，
  /// 弱网一抖就见底 —— 这正是「官方在线视频流畅、我们卡」的差异来源。
  ///
  ///   低延迟 5MB · 标准 30MB · 增强 60MB · 强力 120MB
  /// 起播速度由 [avpBufferForPlayingMs]（起播水位，仍 1~2s）保证，与容量无关，
  /// 故放大容量**不会**重演 2026-09-28 那次「120MB 起播慢 10~14s」——
  /// 那次是因为把起播水位也一并放大了。两参数现已解耦。
  int get avpBufferMb {
    final base = _avpBufferBaseMb;
    final raw = base * avpBufferScale;
    // 防呆钳制：不小于官方最小推荐 5MB，不超过 120MB（强力档满值，内存可控）。
    return raw.round().clamp(5, 120);
  }

  /// 各档位的 AVP 容量基准（MB），见 [avpBufferMb]。
  /// 与同档 exo 时长 1:1 对齐（5/30/60/120s），单位 MB（1s=1MB）。
  int get _avpBufferBaseMb {
    if (exoMaxBufferMs <= 5000) return 5; // 低延迟
    if (exoMaxBufferMs <= 30000) return 30; // 标准
    if (exoMaxBufferMs <= 60000) return 60; // 增强
    return 120; // 强力
  }

  /// VLC（libvlc）的网络/文件缓存毫秒数，对应 `--network-caching` /
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
    // 鸿蒙 AVPlayer：与 exo 基准 1:1 对齐（30 秒 → 30MB），系数 1.0 便于后续整体调。
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
    // 强力档：exo 120 秒 → 120MB（1:1）。该档定位即「牺牲内存换稳定」，弱网收益最大。
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
    // 直播低延迟档：exo 5 秒 → 5MB，恰好等于官方最小推荐值，无需特殊处理。
    // （直播要的是低延迟，大缓冲会直接推高延迟，与该档定位本就冲突，派生结果正合适。）
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
