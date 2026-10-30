import 'package:flutter/foundation.dart';

/// 全局播放活动跟踪器 —— 给「后台测速」提供让路信号。
///
/// ## 背景
///
/// 详情页的后台测速与播放页的取流是**并行**跑的（进入播放后测速仍在继续）。
/// 两侧网络栈彼此独立：
///   · 测速 → dart:io `HttpClient`（[LunaTVService] 的测速专用 client）
///   · 播放 → ExoPlayer(Android) / libcurl(Windows·Linux·Android mpv)
///           / AVPlayer(鸿蒙)
///
/// 连接池互不共享，但**物理网卡带宽是共享的**。测速并发下载会直接抢走播放
/// 缓冲的带宽，表现为起播慢、缓冲告急、重缓冲。
///
/// ## 为什么不能靠「协议优先级」
///
/// dart:io 的 `HttpClient` 没有 QoS / 优先级能力，TCP 也不区分应用优先级，
/// 所以「给播放缓冲提优先级」在协议层做不到。可行的等效做法是
/// **让测速主动让路**：
///   · 播放取流中 → 测速降档（并发 1、采样 128KB），带宽占用降约 24 倍；
///   · 播放缓冲告急 → 测速完全停手，把带宽全部留给缓冲。
class PlaybackActivity {
  PlaybackActivity._();

  static final PlaybackActivity instance = PlaybackActivity._();

  /// 是否有播放正在取流（含起播缓冲阶段）。
  ///
  /// 暂停时播放侧不再下载，此时无需让路，测速可恢复全速。
  final ValueNotifier<bool> active = ValueNotifier(false);

  /// 会话 id → 该会话是否正在取流。
  final Map<int, bool> _sessionPlaying = <int, bool>{};

  /// 会话 id → 该会话当前正在播放的源标识（格式 `source+id`）。
  ///
  /// 🔴 2026-10-23：用于让测速**跳过正在播放的源**。
  final Map<int, String> _sessionSourceKey = <int, String>{};

  /// 当前正在播放的源标识（格式 `source+id`）；无活跃播放会话时为 null。
  ///
  /// 测速据此跳过该源：它的流量正被播放器占用，再测一次既会让测出的
  /// 速度被自身播放流污染（表现为「播放后源速度很慢」），又会白白再抢
  /// 一遍带宽。被跳过的源只做分辨率识别，速度记为「可用但未知」。
  String? get currentSourceKey {
    for (final entry in _sessionSourceKey.entries) {
      if (_sessionPlaying.containsKey(entry.key)) return entry.value;
    }
    return null;
  }

  /// 告急去抖：缓冲低于阈值需**持续**这么久才判定为告急。
  ///
  /// 起播瞬间 buffered 还没上报，差值天然是 0，若立即判定告急，
  /// 会把「测速让路」误当成「缓冲不足」，白白停掉测速。
  static const Duration _starveConfirmDelay = Duration(seconds: 3);

  /// 告急持续上限：超过此时长仍未恢复，视为该源本身不上报缓冲
  /// （直连大文件 / 直播），自动解除告急、退回普通降档，
  /// 避免测速被永久阻断。
  static const Duration _starveMaxDuration = Duration(seconds: 45);

  /// 当前这次告急开始的时刻（null 表示未处于告急）。
  DateTime? _starvedSince;

  /// 时间源。测试可注入可控时钟以验证去抖与持续上限。
  @visibleForTesting
  DateTime Function() now = DateTime.now;

  int _nextSessionId = 0;

  /// 是否有播放正在取流。测速据此决定是否降档。
  bool get isActive => _sessionPlaying.values.any((v) => v);

  /// 是否有播放会话缓冲告急。测速据此决定是否完全停手。
  ///
  /// 判定是**实时**计算的（不依赖播放页持续上报），因此即使播放器卡住、
  /// position 流不再推进，告急也能在 [_starveConfirmDelay] 之后自行成立，
  /// 并在 [_starveMaxDuration] 之后自行解除。
  bool get mustYield {
    final since = _starvedSince;
    if (since == null) return false;
    final elapsed = now().difference(since);
    if (elapsed < _starveConfirmDelay) return false;
    return elapsed <= _starveMaxDuration;
  }

  /// 播放页在创建后端成功后申请一个会话，返回会话 id。
  ///
  /// 播放页在 `dispose()` 时必须调用 [closeSession] 释放。
  int openSession() {
    final id = ++_nextSessionId;
    _sessionPlaying[id] = false;
    return id;
  }

  /// 播放页释放会话（`dispose()` 时调用）。
  void closeSession(int id) {
    if (_sessionPlaying.remove(id) == null) return;
    _sessionSourceKey.remove(id);
    _starvedSince = null;
    _recompute();
  }

  /// 上报该会话当前正在播放的源标识（格式 `source+id`）。
  ///
  /// 换源时需重新上报；传 null 表示该会话当前没有有效源。
  void reportCurrentSource(int id, String? sourceKey) {
    if (!_sessionPlaying.containsKey(id)) return;
    final normalized =
        (sourceKey != null && sourceKey.isNotEmpty) ? sourceKey : null;
    if (_sessionSourceKey[id] == normalized) return;
    if (normalized == null) {
      _sessionSourceKey.remove(id);
    } else {
      _sessionSourceKey[id] = normalized;
    }
  }

  /// 上报该会话是否正在取流。
  void reportPlaying(int id, bool playing) {
    if (!_sessionPlaying.containsKey(id)) return;
    if (_sessionPlaying[id] == playing) return;
    _sessionPlaying[id] = playing;
    _recompute();
  }

  /// 上报该会话的缓冲告急状态（缓冲剩余量是否低于阈值）。
  void reportBufferStarved(int id, bool starved) {
    if (!_sessionPlaying.containsKey(id)) return;
    _starvedSince = starved ? (_starvedSince ?? now()) : null;
  }

  void _recompute() {
    final anyActive = _sessionPlaying.values.any((v) => v);
    if (active.value != anyActive) active.value = anyActive;
  }
}
