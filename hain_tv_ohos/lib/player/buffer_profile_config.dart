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
    // 防呆钳制：不小于 2MB，不超过 120MB（强力档满值，内存可控）。
    //
    // 🔴 2026-10-31（第二十五轮）：下限由 5 放宽到 2。
    //   直播档需要下探到 3MB（见 [_avpBufferBaseMb]），5 的下限会把它顶回 5MB。
    return raw.round().clamp(2, 120);
  }

  /// 各档位的 AVP 容量基准（MB），见 [avpBufferMb]。
  /// 与同档 exo 时长 1:1 对齐（5/30/60/120s），单位 MB（1s=1MB）。
  int get _avpBufferBaseMb {
    // 🔴🔴🔴 2026-10-31（第二十五轮）：低延迟档 20MB → **3MB**。
    //
    // 【真机证据】hilog 2026-10-31 10-01-44（源② = 本地 iptv 组播裸 TS 直连）：
    //   · 起播 1085ms（首帧已送显）→ 随即 buffering=true 持续 6.4s → 才真正开始播
    //   · 同一档位容量为 5MB 的更早版本（2026-10-31 之前）：同样症状，持续 3~4s
    //   ⇒ **「卡一下」的时长 ≈ 容量 / 到达速率**：20MB→6.4s、5MB→3~4s。
    //     即 avp 起播后要把缓冲填到目标水位才恢复，容量越大等得越久。
    //
    // 【为什么不能靠「余量」解释】2026-10-31 实测源②供给（原始 socket 抓取 30s）：
    //   · 1660 个数据块，最大间隔 **67ms**，每秒稳定 1.06~1.14MB
    //   · 速率 8.83Mbps，**高于**该流码率 8.56Mbps ⇒ 供给充足且无断流
    //   ⇒ 所谓「1.0x 实时供给、余量零增长」是错判（供给其实略快于消费）。
    //
    // 【结论】直播档应取**小容量**：起播快、直播延迟小（容量 ≈ 落后直播边缘的秒数），
    //   源本身供给平滑（最大间隔 67ms），小容量也足以抗抖动。
    //   3MB ÷ 1.07MB/s ≈ 2.8s ⇒ 起播后「卡一下」约 2.8s（对比 20MB 的 6.4s）。
    if (exoMaxBufferMs <= 5000) return 3; // 低延迟（直播）
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
    // 直播低延迟档：exo 5 秒 → 20MB（见 [_avpBufferBaseMb] 的直播特例说明）。
    avpBufferScale: 1.0,
    //
    // 🔴🔴🔴 2026-10-31（第二十四轮）：0 → 1000ms。**这是鸿蒙 AVP 直播
    //   「起播后卡 3~4 秒」的根因修复。**
    //
    // 【原症状】本地 iptv 组播源（R2H 代理转出的裸 MPEG-TS，8.72Mbps），
    //   每个频道都是「首帧 0.7~2.1 秒就送显 → 随即 buffering 3~4 秒 → 才真正开始播」。
    //   同一源用 mpv 播完全流畅 ⇒ 与网络、与源无关。
    //
    // 【根因】原生层下发缓冲档位时写的是
    //   `if (bufferDurationForPlayingMs > 0) { ...下发... }`
    //   ⇒ 直播档传 0 时**整个字段根本没下发** ⇒ AVPlayer 退回**系统默认的
    //   动态起播水位线**。华为官方《在线视频播放卡顿优化》给出该默认值算法：
    //     · 下载速率 ≥ 码率 → 起播水位线 = 0.3 秒 × 码率
    //     · 下载速率 < 码率 → 起播水位线 = 5 秒 × 码率
    //   本地源下载速率 ≈ 码率 ≈ 8.72Mbps，统计窗口（≥500ms）稍有抖动就落进
    //   「下载速率 < 码率」分支 ⇒ 起播水位线 = 5s × 码率 = **5.45MB**，
    //   而直播档缓冲区只有 5MB ⇒ **永远达不到水位线**，AVPlayer 只能等到
    //   缓冲区写满才起播 ⇒ 实测 5MB ÷ 1.09MB/s = **4.6 秒**，与日志里的
    //   3~4 秒 buffering 完全对得上。
    //
    // 【修复】显式下发起播水位 1 秒（API 单位为秒，整数）：门槛固定为 1 秒数据
    //   ≈ 1.09MB，起播等待从「缓冲写满 4.6 秒」降到「约 1 秒」，
    //   且不再随下载速率测量抖动在 0.3s / 5s 两个分支间跳变。
    //   ⇒ **直播延迟不增加反减约 3.6 秒**（原来起播时缓冲里已积了 4.6 秒）。
    //
    // 🔴 2026-10-31（第二十五轮）补充：**这个值已经无法再调小**。
    //   原生侧下发为 `preferredBufferDurationForPlaying = Math.max(1, ceil(ms/1000))`
    //   —— API 官方单位是「秒」（@ohos.multimedia.media.d.ts：*"The unit is second"*），
    //   原生层下限 1 秒 ⇒ 1000ms 就是能下发的最小值。
    //   ⇒ 直播卡顿的调节旋钮只剩**容量**（avpBufferMb），见 [_avpBufferBaseMb]。
    //
    // 🔴🔴🔴 2026-10-31（第二十六轮）：1000ms → **2000ms**。修「起播后先卡一下
    //   再正常播放」（裸 MPEG-TS 源，mpv 同源无此现象）。
    //
    // 【真机证据】hilog 2026-10-31 19:04（3 次播同一裸 TS 源，规律完全一致）：
    //   playing 19:04:10.773 → 进度 buffered=**560ms** → buffering=true 19:04:11.742
    //   → buffering=false 19:04:13.942（**卡 2.2 秒**）→ 此后 15 秒以上全程正常。
    //   另两次：18.048→20.049（2.0s）、38.974→40.775（1.8s）。
    //   ⇒ 卡顿点固定在「开播约 1 秒后」，与源无关（源侧实测：PCR 连续、实时
    //     8.9Mbps、PTS 无跳变、PMT 不变、ffmpeg 连续解码 25 秒零丢帧）。
    //
    // 【根因】`preferredBufferDurationForPlaying` 既是**起播门槛**也是**重缓冲门槛**：
    //   水位 = 1 秒 ⇒ AVP 攒够 1 秒数据就开播，手里只有 ~0.5~1 秒余量
    //   （实测 buffered=560ms）⇒ 开播约 1 秒后余量耗尽 ⇒ 立刻 BUFFERING_START，
    //   再攒满 1 秒才恢复 ⇒ 表现为「先卡一下再正常播放」。
    //   实测起播耗时 1.5s ≈ 水位 1s（1.09MB）+ 0.4s 准备开销，也印证**起播由水位
    //   决定、而不是容量**（容量 3MB ≈ 2.7 秒数据，若由容量决定起播应是 2.7s）。
    //
    // 【修法】水位 1 秒 → 2 秒：起播时手里有 ~2 秒余量，源侧 1 秒级抖动不再断流；
    //   容量 3MB ≈ 2.7 秒 > 2 秒，水位仍可满足（不会被容量顶住）。
    //   代价：起播 +约 1 秒（源② 1.5s → ~2.5s，仍快于 HLS 源的 3~4 秒）；
    //   直播延迟增加约 1 秒。
    avpBufferForPlayingMs: 2000,

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
