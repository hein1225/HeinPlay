import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
// 鸿蒙 AVPlayer 起播定位旁路入口（本地 fork 新增 setNextStartPosition）。
// ⚠️ 本工程是鸿蒙专属工程，video_player_ohos 恒为直接依赖；
//    但为不污染非鸿蒙平台的编译，引用点统一用 `if (Platform.isOhos)` 守卫。
import 'package:video_player_ohos/video_player_ohos.dart';
// ⚠️ 基类 VideoPlayerPlatform 必须从 interface 包直接 import：
// 本工程用的 video_player 是 TPC fork 版，其 barrel 未 re-export 该符号。
// 同一处理见 player_backend_factory.dart:11-13。
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show VideoPlayerPlatform;
import '../services/ad_filter_service.dart';
import '../services/local_m3u8_proxy.dart';
import '../services/user_data_service.dart';
import '../utils/windows_logger.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_render_mode.dart';

const _defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

/// 缓冲窗口的适用判据（详见 open() 中 setBufferRange 处的注释）：
/// 不能按操作系统判断 —— Android 上用户可在「ExoPlayer」与「fvp」两个后端之间切换
/// （见 player_backend_factory.dart 的 `availableBackends`），只有选中 fvp 时缓冲窗口
/// 才该由 setBufferRange 控制，选中 ExoPlayer 时由 ExoPlayerBufferConfig 经
/// MethodChannel 下发。本文件因此以「谁传了 bufferConfig」为判据。

Map<String, String> _refererFor(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.scheme.startsWith('http')) {
      final referer = '${uri.scheme}://${uri.host}/';
      return {'Referer': referer, 'Origin': '${uri.scheme}://${uri.host}'};
    }
  } catch (_) {
    // 忽略无效 URL
  }
  return {};
}

bool _isLocalProxyUrl(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.scheme.startsWith('http') &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost');
  } catch (_) {
    return false;
  }
}

/// 过滤播放请求头中的内部传输键（x-heinplay- 前缀）。
///
/// 仅 ExoPlayer 后端（Android 的 video_player_android）会由原生插件剥离
/// x-heinplay-proxy-url 并解析为 OkHttp 代理，因此该平台需保留；
/// 其余平台或后端（fvp/libmdk、vlc）不解析该键，丢弃避免泄漏到上游请求。
Map<String, String>? stripInternalRequestHeaders(
  Map<String, String>? headers, {
  bool force = false,
}) {
  if (headers == null) return null;
  if (!force && Platform.isAndroid) return headers;
  final filtered = <String, String>{};
  for (final entry in headers.entries) {
    if (!entry.key.toLowerCase().startsWith('x-heinplay-')) {
      filtered[entry.key] = entry.value;
    }
  }
  return filtered;
}

class VideoPlayerBackendImpl implements VideoPlayerBackend {

  /// 走 texture 渲染，open() 不依赖 Flutter 侧挂载，无需提前挂载。
  @override
  bool get requiresEagerMount => false;

  /// 渲染方式：实现接口契约。鸿蒙 avplayer 恒走 Flutter 纹理，
  /// 此值当前不改变实际渲染路径（仅由外层 AvPlayerBackend 记录并标注）。
  @override
  VideoRenderMode renderMode = VideoRenderMode.texture;
  VideoPlayerController? _controller;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();

  /// 首帧「纹理出帧」信号（每个 open 周期最多触发一次）。
  ///
  /// 🔴 2026-09-28 新增：供无缝换台判断「新频道画面是否真的可见了」。
  ///   此前鸿蒙走 `_onPlaybackSignal` 的立即就绪分支 —— 底层一报 playing 就撤掉
  ///   冻结的旧画面，而纹理此时尚未出帧，于是黑屏/花屏一下才恢复，
  ///   即用户反馈的「换台卡一下，过一下才正常播放」。
  ///   判据与下方诊断日志一致：解码器产出非零 size（说明真有画面了）。
  final _firstFrameController = StreamController<void>.broadcast();
  bool _firstFrameEmitted = false;

  Timer? _timer;
  bool _completedReported = false;
  BoxFit _fit = BoxFit.contain;

  // —— 仅用于诊断打印，不影响任何播放行为 ——
  bool _firstFrameReported = false;
  Duration _lastStallPosition = Duration.zero;
  DateTime _lastStallCheck = DateTime.now();
  DateTime _lastProgressLog = DateTime.now();
  /// 上一帧进度日志的「状态签名」（playing/buffering/error）。
  /// 🔴 2026-10-24（第十七轮）：进度日志改为「状态变化即打 + 5 秒心跳」，
  ///   用它判断状态是否切换（见 `_startPositionTimer` 内注释）。
  String _lastProgressState = '';

  // —— 续播 seek 自愈（仅 fvp 需要；ExoPlayer seek 可靠，不走此路径）——
  // _fvpMode：后端是否为 fvp（由调用方显式传入 isFvpBackend 决定）。
  // 不再用「fvpVideoDecoders 是否为 null」判定 —— 真机默认硬解时 FvpBackend 传
  // fvpVideoDecoders=null（解码交 fvp 内置），但后端仍是 fvp；旧判定会把真机 fvp
  // 误算成 _fvpMode=false，导致续播重试/stall 自愈整段失效（2026-09-24 证伪）。
  //   故可用它可靠区分后端，避免给 ExoPlayer 加无谓的延迟重试。
  // _resumeTarget：本次 open 的续播目标位置。fvp 在部分源上 seekTo 仅设置时钟、
  //   读取线程未跳到目标段，且 value.position/value.buffered 会谎报为时钟值，导致
  //   「基于 bufferedEnd 的判定」失效 → 永久冻结（时钟在续播点、读取停在分段 0）。
  //   故在播放中检测到「playing 但 position 持续不推进且非网络缓冲等待」时，主动
  //   重试 seek；重试耗尽则回退从片头播放（远比永久冻结可接受）。
  // _stallRecoveries / _lastStallRecoverAt：限制自愈重试频率，避免正常网络缓冲抖动误触发。
  bool _fvpMode = false;
  Duration? _resumeTarget;

  // _resumeSeekDeadline：「续播定位自愈」的**有效期截止时间**。
  //
  // 🔴 2026-09-28 修复「鸿蒙版 fvp 偶发播放记录定位失败」（用户报障）。
  //
  // 原实现里 _resumeTarget 只在 open() 赋值、仅在「回退片头」时清空，
  // 于是整个播放期间它都非 null，stall 自愈判定（见 _startPositionTimer）会一直
  // 拿着**起播点**做校验。用户一旦手动 seek 到别处，自愈就可能把正常播放误判成
  // 「续播定位失败」，然后 seek 回起播点 —— 观感就是「画面突然跳回很久以前的位置」，
  // 用户报告为「播放记录定位失败」。
  // 实测日志（设备 9CN0223912004329）：
  //     12:18:31 seek target=695859ms          （用户快退）
  //     12:18:34 seek target=649320ms          （用户再快退）
  //              进度 position=649320ms buffered=651199ms   ← 正常播放中
  //     ⚠️ FVP_DECODE_STALL: position 卡在 649320ms 已≥2s 无推进
  //     [STALL-RECOVER] 续播定位疑似失败，重试 seek(743000ms) 第 1/3 次
  //                                    ↑ 跳回起播点 743s，用户看到「定位失败」
  //     随后 12:18:39 第 2/3 次、12:18:54 第 3/3 次，重试耗尽后上抛
  //     onUnrecoverableStall → 播放页重建播放器（等于从头再来）。
  //
  // 处置：给自愈加一个明确的有效期。真需要自愈的场景是「起播定位后读取线程没跳段」，
  // 它必然在起播后很短时间内暴露；窗口内仍救不回来就说明不是该机制能处理的问题，
  // 应当放手让播放继续进行，而不是无限期地拿旧目标反复 seek。
  DateTime? _resumeSeekDeadline;
  static const Duration _resumeSeekWindow = Duration(seconds: 20);

  int _stallRecoveries = 0;
  static const int _maxStallRecoveries = 3;

  // _fvpStallSince：position 开始「不推进」的时刻；一旦 position 有推进即清零。
  //
  // 用于把「正常缓冲」与「读取线程真死」分开 —— 两者的观测特征完全相同
  // （position 不推进 + 前方无缓冲），唯一区别是**持续时间**：
  // 正常缓冲会在几秒内恢复，真死锁则无限期停滞。
  // 故不改用更复杂的判据，只把时限拉长到 [_fvpDeadlockMs]。
  DateTime? _fvpStallSince;

  // ══════════════════════════════════════════════════════════════════════
  // 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，第十五轮）：**avp 冻结自愈**。
  //
  // 【真机实证】hilog 2026-10-24 21:50:14（13-50-45.txt）：
  //   21:50:14.333 seekTo: target=0ms mode=SEEK_NEXT_SYNC current=3652ms
  //   21:50:14.504 bindState, avplayerStatus=error
  //   21:50:14.506 AvPlayer Avoid Error Reporting: {"code":5400103}
  //   ⇒ AVPlayer 在 seek 后进入 **error 态**，且**不可恢复**（直到 release）。
  //   ⇒ 原生把 5400103/5400102 当「良性错误」直接 return（不 reset、不上报）
  //     ⇒ Flutter 侧零感知 ⇒ 进度条与画面一起冻住 ⇒ 用户看到「卡死」。
  //
  // 【本字段的用途】在**无法拿到原生 error 信号**的前提下，用可观测的
  //   「position 与 buffered 同时冻结」来识别「播放器已死」，
  //   并**上抛重建后端**（onUnrecoverableStall）。
  //
  // 【为什么判据是「position 与 buffered 同时不推进」】
  //   · 真网络缓冲：position 停，但 **buffered 端点仍在涨**（数据继续下）
  //     ⇒ 只停一个 ⇒ 不触发 ✓（实测正常播放 buffered 8089→13889→14093→17087 在涨）
  //   · avp 死亡：position 停，buffered 也停（原生 prepareSeek 冻结了 buffered）
  //     ⇒ 两个都停 ⇒ 触发 ✓
  //   （真机实测：21:50:16→21:50:25 position 恒 0ms、buffered 恒 17087ms，纹丝不动）
  DateTime? _avpFrozenSince;
  Duration _avpLastPosition = Duration.zero;
  Duration _avpLastBufferedEnd = Duration.zero;

  /// 本次 open 是否已触发过 avp 冻结自愈（防止反复重建）。
  bool _avpRecoveryFired = false;

  /// 是否为 avp 后端（冻结自愈仅对 avp 生效）。
  ///
  /// ⚠️ mpv/fvp 也有自己的位置上报语义（mpv 走真实 PTS、fvp 会谎报 position），
  ///   「position 与 buffered 同时冻结」在它们身上不成立 ⇒ 不能复用本判据。
  bool _avpMode = false;

  /// 🔴 2026-10-24（第十六轮）：**seek 宽限截止时刻**。
  ///
  /// 【为什么需要】冻结判据是「position 与 buffered 同时不推进」。
  ///   但 seek 之后 position 会**跳变**（跳到目标）⇒ 判据里的
  ///   「position 变了」会把冻结计时清零 ⇒ 只要用户还在操作，就永远判不出冻结。
  ///
  /// 【真机反证】hilog 2026-10-24 22:13:24~22:13:40：
  ///   22:13:24 seek(0) → 5400103 → position 恒 0ms、buffered 恒 17925ms
  ///   22:13:33 seek(142000) → position 变 142000 ⇒ 计时清零
  ///   22:13:35 seek(45000)  → position 变 45000  ⇒ 计时清零
  ///   ⇒ 全程 [AVP-FREEZE-RECOVER] **一次都没触发**（真机计数 = 0）。
  ///
  /// 【修法】seek 之后给 6 秒宽限：宽限期内即便 position 跳变也不清零计时，
  ///   而是把计时起点重置到「此刻」——即「seek 之后再冻结满 6 秒」才判死。
  DateTime? _avpSeekGraceUntil;

  /// avp 冻结多久判定为「播放器已死」⇒ 触发重建。
  ///
  /// ⚠️ 取 6s：正常网络抖动/起播缓冲不会连续 6s「position 与 buffered 同时冻结」；
  ///   而真死是无限期的（实测冻了 17s 仍无任何进展）。
  static const Duration _avpFreezeRecoverMs = Duration(seconds: 6);

  /// fvp 判定「读取线程真死」所需的连续停滞时长。
  ///
  /// 🔴 2026-09-28 定标依据：起播缓冲期（含续播定位）实测最长约 2~4 秒，
  /// 网络抖动导致的重缓冲通常也在 5 秒内恢复。取 8 秒既能让正常场面全部平安
  /// 通过，又能在真死锁时及时兜底。**不要再调回 2 秒** —— 那正是
  /// 「每次打开播放记录都往前跳一些」误伤的根因。
  static const Duration _fvpDeadlockMs = Duration(seconds: 8);

  // _avPlayerMode：后端是否为鸿蒙原生 AVPlayer（video_player_ohos）。
  //
  // ⚠️ 它的唯一用途是**选择起始定位的校验判据**，不是给 AVPlayer 套 fvp 式补偿逻辑。
  // AVPlayer 与 ExoPlayer 同属系统级硬解播放器，起始定位共用同一套
  // 「seek 一次 → 校验 → 重试 → 失败回退」逻辑（见 open() 内该分支注释），
  // 只是二者 `VideoPlayerValue` 的语义不同，故校验字段不同：
  //   · ExoPlayer：`buffered` = exoPlayer.getBufferedPosition()，已下载到的最远位置，
  //                故判 `bufferedEnd >= startAt`；
  //   · AVPlayer ：`buffered` = playTime + bufferingPosition（VideoPlayer.ets:828），
  //                是「当前位置+缓冲窗口」而非「已下载最远点」，该判据必然误判；
  //                改判 `position`（其 getPosition 在 seek 期间直接返回目标值，
  //                见 VideoPlayer.ets:355-363，是可靠信号）。
  bool _avPlayerMode = false;

  // 🔴 2026-10-08：本次会话的起播定位是否已由「原生预置路径」完成。
  // 见 initialize() 中 create 阶段的 setNextStartPosition 说明，以及
  // 「AVPlayer 起始定位」分支处的完整故障分析。
  // 语义：true = 起点已由 ArkTS 侧在 prepare 阶段落地（SEEK_DONE 后才发
  // sendInitialized），Dart 侧**不得**再 seek 一次，否则会打断 AVPlayer
  // 状态机（真机实证 5400103 → error → 画面卡死）。
  // false = 预置未生效（平台实现非 OhosVideoPlayer 或抛异常），此时保留
  // 「init 后 seek 一次」的兜底路径。
  bool _startAtPresetApplied = false;

  /// 🔴 2026-10-24（第十三轮）：**起播裁剪偏移**（ms）。
  ///
  /// 代理把 playlist 裁成「第 0 片 = 落点片」后（见
  /// `LocalM3u8Proxy._applyStartTrim`），AVPlayer 上报的 position/duration
  /// 都是**相对落点**的值；而进度条、播放记录、用户拖动用的都是**用户轴**。
  /// 二者相差一个固定偏移 [_trimOffsetMs] ⇒ 统一在此换算。
  ///
  /// 实时读代理（而非缓存）：换源时代理会把裁剪状态清零，自动恢复为 0。
  int get _trimOffsetMs => LocalM3u8Proxy.currentInstance?.trimOffsetMs ?? 0;

  // —— seek 合并（coalescing）状态，见 seek() 的注释 ——
  // _seekInFlight：当前是否有一次 seek 正在下发（await 未返回）。
  // _pendingSeekTarget：下发期间到来的最新目标；循环取走后置空，
  //   为 null 表示没有更新的目标、合并循环可以退出。
  bool _seekInFlight = false;
  Duration? _pendingSeekTarget;

  // （已删除 _bufferConfig 字段与 seek 收紧窗口补丁）
  //
  // 🔴 2026-09-28 复盘：曾加过「seek 时把 fvp 预读窗口 max 压到 2000ms」
  // 想修「快进快退后往前跳」，**方向完全错误，已全部删除**。
  //
  // 真因是 seek flags（见 player_backend_factory.dart 中 fastSeek 的说明）：
  // mdk 头文件 global.h:120 写明不带 KeyFrame 的精确 seek
  // "implies backward seek internally" —— 会回溯到目标之前的关键帧再解码。
  //
  // 而收紧 max 恰恰让 SeekFlag.inCache 更容易失效（global.h:123：
  // "Target position must be in range (position(), position() + buffered()]"），
  // 缓存越小 → 越易落到范围外 → 越频繁退回 backward 回溯路径，
  // 等于**放大**了跳变。教训：改缓冲窗口前先确认 seek flags 是否正确。

  // onUnrecoverableStall：fvp 续播卡死且 App 层 seek 重试/回退片头均 no-op
  // （reader 真死）时上抛，由播放页重建为 ExoPlayer（保留续播点）。
  // 仅 _fvpMode=true 且回调已注册时触发。
  VoidCallback? onUnrecoverableStall;
  bool _unrecoverableSignaled = false;

  /// 🔴🔴🔴 2026-10-24（第十六轮）：**seek 目标落在「裁剪落点之前」时，请求重建**。
  ///
  /// 【为什么需要】
  /// 裁剪模式下代理返回给 AVPlayer 的列表第 0 片 = 落点片 ⇒ 落点**之前**的内容
  /// 在播放列表里**根本不存在** ⇒ 任何 seek 模式都定位不到
  /// （SEEK_CLOSEST 需要「目标之前有段」；SEEK_NEXT_SYNC 会把目标顶到落点片）。
  ///
  /// 【真机实证】hilog 2026-10-24 22:13:24（14-13-49.txt）：
  ///   22:13:24 [SEEK-DIAG] seek target=0ms userTarget=1053991ms
  ///                  trimOffset=1132520ms before=4471ms after=0ms
  ///   ⇒ 用户想退到 1053991ms（< 落点 1132520ms）⇒ clamp 后 target=0
  ///   ⇒ AVPlayer 实际跳到**落点片**（用户轴 1132520ms）⇒ **跳错了位置**，
  ///     且在往回 demux 时报 5400103 ⇒ 播放器直接死掉。
  ///
  /// 【本回调的语义】Dart 侧检测到「目标 < 裁剪偏移」⇒ 不做 seek，
  ///   而是上抛本回调，由播放页**重建播放器并以该目标为新落点起播**：
  ///   代理会按新落点重新裁剪列表 ⇒ AVPlayer 从目标位置直接起播（实测 2.4s）
  ///   ⇒ 位置准确、不会卡死。
  void Function(int targetMs)? onSeekRebuildRequested;

  /// 🔴 2026-10-24（第十六轮）：用户**最近一次 seek 的目标**（用户轴，毫秒）。
  ///
  /// 【用途】播放器报错/死亡后重建时，**必须**落到用户想去的位置，
  ///   而不是「当前播放位置」（播放器已死时 position 冻结 ⇒ 落点会错）。
  /// 详见 [onUnrecoverableStall] 的调用点。
  int _lastSeekTargetUserMs = 0;

  /// 🔴 2026-10-24（第十七轮）：**seek 快速失败判据**。
  ///
  /// 【为什么需要 —— 真机 hilog 2026-10-24 22:39（14-39-46.txt）】
  ///   四次 seek 里两次失败，失败时**原生既没派发 seekDone、也没报错**
  ///   （本轮 5400103 出现 0 次），于是只能等：
  ///     2.5s「seek 兜底：未收到 seekDone」+ 6s「AVP-FREEZE-RECOVER」
  ///     = **约 9 秒**才重建 ⇒ 用户感受就是「卡死」。
  ///   实测失败的两次在 seek 后 <1 秒就能判定：落点段没在缓存里
  ///   ⇒ 播放器卡在旧位置、position 一动不动。
  ///
  /// 【判据】seek 后 [_kSeekFastFailMs] 内 position **既没到目标附近、
  ///   也没比 seek 前推进** ⇒ 判定这次 seek 已失败，立即重建。
  ///   成功案例（第十五轮真机）都在 0.8~1.1s 内 position 跳到目标 ⇒ 不会误判。
  ///
  /// 🔴 2026-10-26（第二十一轮）：本判据已被「三判据」取代（见下方注释块），
  ///   原因是它只看「当前 position」，无法区分「seek 从未生效」与
  ///   「seek 已生效但 AVPlayer 随后回退重解」⇒ 真机 100% 误判。
  DateTime? _seekIssuedAt;
  Duration _seekIssuedFrom = Duration.zero;

  // ══════════════════════════════════════════════════════════════════
  // 🔴🔴🔴 2026-10-26（第二十一轮）：**原生 seek 结果三判据**。
  //
  // 【为什么必须重写 —— 真机 hilog 2026-10-26 13:03:39（05-04-31.txt）】
  //   用户快进 +83.4 秒（用户轴 1141594ms → 1222208ms）：
  //     13:03:39.377 [SEEK-DIAG] seek target=83570ms before=4670ms after=83570ms elapsed=1ms
  //     13:03:39.559 进度 position=83570ms buffered=83570ms
  //     13:03:41.560 ⚠️ AVP_DECODE_STALL: position 卡在 83570ms 已≥2s 无推进
  //     13:03:43.560 ⚠️ AVP_DECODE_STALL: position 卡在 4670ms 已≥2s 无推进  ← ★倒退 38.9 秒
  //     13:03:43.560 [AVP-SEEK-FASTFAIL] seek 后 4184ms position 仍停在 4670ms ⇒ 判失败 ⇒ 重建
  //
  // 【真相】原生 seek **其实已成功落地**（elapsed=1ms 就报出了目标位置 83570），
  //   但该源**关键帧稀疏** ⇒ AVPlayer 放弃目标点，把播放头**倒退 38.9 秒**
  //   回到更早的 I 帧重新解码（position 4670 = seek 前的值）。
  //   旧判据只看「**当前** position」⇒ 回退后 position 恰好等于 seek 起点
  //   ⇒ 100% 命中「既没到目标、也没比起点前进」⇒ **误判为 seek 失败**，
  //   白白多花 1.9 秒重建 + 画面二次中断。
  //
  // 【三判据（本轮）】
  //   ① 快速失败：观察窗 [_kSeekFastFailMs] 到期，**从未**到达过目标附近，
  //      且没比 seek 起点前进 ⇒ 真死锁（position 恒 0）⇒ 走卡死自愈。
  //   ② 到位后退回：目标比起点**更晚**（快进）但 position 退回起点附近
  //      ⇒ AVPlayer 放弃目标点 ⇒ 走「重建 + 新落点」。
  //   ③ 到位后卡死：到达过目标，此后 position 与 buffered **同时**不动
  //      ≥ [_kSeekReachedStallMs] ⇒ 走「重建 + 新落点」。
  //
  // 【为什么 ② ③ 要走「重建 + 新落点」而不是继续等】
  //   重建路径是「代理按新落点裁剪列表 ⇒ AVPlayer 从落点片**直接起播**」，
  //   **全程不做 seek** ⇒ 根本不会触发 I 帧回退（实测重建 1.8~2.6 秒必达）。
  //   而原生 seek 在 I 帧稀疏的源上会回退数十秒 ⇒ 「跳过去又跳回来」。
  //   ⇒ 用户报的「快进快退偶尔能用偶尔不能用」在此闭环。
  //
  // 【额度】② ③ 走 [onSeekRebuildRequested]（**独立额度** [_seekRebuildRetries]），
  //   不消耗「播放器已死」的 [_fvpStallRetries] ⇒ 连续多次快进也不会被限流。
  // ══════════════════════════════════════════════════════════════════

  /// 【第二十一轮】本次 seek 的目标（**代理相对轴**，毫秒）缓存。
  int _sfTargetRelMs = 0;

  /// 【第二十一轮】本次 seek 后是否**曾**到达目标附近（±2500ms）。
  ///
  /// 【为什么需要】旧判据只看「当前 position」，无法区分
  ///   「seek 从未生效」与「seek 已生效但 AVPlayer 随后回退重解」⇒ 误判。
  bool _sfReachedTarget = false;

  /// 【第二十一轮】到达目标附近的时刻（用于判据③的「到位后卡死」计时）。
  DateTime? _sfReachedAt;

  /// 【第二十一轮】到达目标那一刻的 position / buffered 末端（毫秒）。
  int _sfReachedPosMs = -1;
  int _sfReachedBufMs = -1;

  /// 【第二十一轮】判据②③ 是否已触发过「重建到新落点」（防重复触发）。
  bool _sfRebuildFired = false;

  /// 【第二十一轮】seek 发出那一刻的 **buffered 末端**（代理轴，毫秒）。
  ///
  /// 【用途】判据①「真死锁」的必要条件：position 不动 **且** buffered 也不动。
  ///   · 真死锁（原生 5400103 后）：position 恒 0、buffered 恒定 ⇒ 成立 ✓
  ///   · 只是网络慢：position 不动但 buffered 在涨 ⇒ 不成立 ⇒ 交给 6 秒冻结判据 ✓
  ///   ⇒ 避免「网络抖动 1.5 秒」被当成 seek 失败而白白重建。
  int _sfBufAtSeekMs = -1;

  /// 【第二十一轮】判据① 的观察窗：2200ms → **1500ms**。
  ///
  /// 【为什么可以缩短】旧实现在「每 2 秒一轮」的 STALL 块里检查，
  ///   2200ms 的阈值实际要等 **2.2~4.2 秒**才触发（真机实测 4184ms）。
  ///   本轮把检查提到「每次控制器值变化都执行」⇒ 阈值才真正生效。
  ///
  /// 【为什么 1500ms 够】成功的 seek 在 0.8~1.1 秒内 position 就到目标
  ///   （第十五轮真机实测）；失败的 seek position **完全不动** ⇒ 1.5 秒即可判定。
  static const Duration _kSeekFastFailMs = Duration(milliseconds: 1500);

  /// 【第二十一轮】判据③：「已到达目标但 position 与 buffered 同时不动」的容忍时长。
  ///
  /// 【取值依据】正常快进成功后 position 会持续前进；正常网络缓冲时
  ///   buffered 在涨 ⇒ 两者都不满足「同时不动」。
  ///   真机回退场景：position 停在 83570、buffered 也停在 83570（都不动）
  ///   ⇒ 2.5 秒即可判定，比旧实现的 4.2 秒提前 1.7 秒。
  static const Duration _kSeekReachedStallMs = Duration(milliseconds: 2500);

  /// 🔴 2026-10-26（第十八轮）：**缓冲末端相对播放点的最大外延**。
  ///
  /// 【为什么需要】原生侧在 HLS 裁剪列表上会把「可播放缓存时长」报成巨值
  ///   （真机 2026-10-26 08:02:47：seek 后上报 1253 秒），
  ///   进度条于是被画成「缓冲到快完」。
  ///   插件侧已按「缓冲档位」钳制，这里再兜一层底。
  ///
  /// 【取值】120 秒 = avp 缓冲档位上限（120MB ≈ 120s 媒体），
  ///   正常情况下不会触发（真实缓冲远小于此），只在异常上报时生效。
  static const Duration _kMaxBufferAhead = Duration(seconds: 120);

  VideoPlayerController? get controller => _controller;

  @override
  BoxFit get fit => _fit;
  @override
  set fit(BoxFit value) => _fit = value;

  @override
  Widget buildVideoWidget() {
    if (_controller == null) return const SizedBox.shrink();

    // 根据父约束和视频原始尺寸计算实际内容区域，
    // 让 VideoPlayer/PlatformView 只覆盖视频画面本身，
    // 黑边区域由外层 Flutter 的黑色背景渲染，
    // 避免 PlatformView 在隐藏控制栏后仍残留渐变/按钮影像。
    return LayoutBuilder(
      builder: (context, constraints) {
        final videoSize = _controller!.value.size;
        final box = constraints.biggest;

        // 尺寸未就绪时先回退到填满，避免初始化阶段白屏
        if (videoSize.width <= 0 ||
            videoSize.height <= 0 ||
            box.width == 0 ||
            box.height == 0) {
          return SizedBox.expand(child: VideoPlayer(_controller!));
        }

        final double contentW;
        final double contentH;
        switch (_fit) {
          case BoxFit.contain:
            final scale = math.min(
              box.width / videoSize.width,
              box.height / videoSize.height,
            );
            contentW = videoSize.width * scale;
            contentH = videoSize.height * scale;
          case BoxFit.cover:
            final scale = math.max(
              box.width / videoSize.width,
              box.height / videoSize.height,
            );
            contentW = videoSize.width * scale;
            contentH = videoSize.height * scale;
          case BoxFit.fill:
          default:
            contentW = box.width;
            contentH = box.height;
        }

        return Center(
          child: SizedBox(
            width: contentW,
            height: contentH,
            child: VideoPlayer(_controller!),
          ),
        );
      },
    );
  }

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
    bool isFvpBackend = false,
    List<String>? fvpVideoDecoders,
    bool isAvPlayerBackend = false,
  }) async {
    await dispose();
    _completedReported = false;
    // 重置诊断状态（仅日志用）
    _firstFrameReported = false;
    // 首帧信号同样重置，保证每个 open 周期都能重新广播一次。
    _firstFrameEmitted = false;
    _lastStallPosition = Duration.zero;
    _lastStallCheck = DateTime.now();
    _lastProgressLog = DateTime.now();
    _lastProgressState = '';
    // 续播 seek 自愈状态重置（仅 fvp 后端启用；_fvpMode 由调用方显式传入的
    // isFvpBackend 决定，与解码器配置无关，确保真机硬解 fvp 也能触发续播自愈）
    _fvpMode = isFvpBackend;
    // AVPlayer 后端标记：决定起始定位用「位置校验」还是「bufferedEnd 校验」。
    // 二者互斥（同一次 open 不可能既是 fvp 又是 avplayer），但仍显式赋值以免
    // 复用同一 impl 实例时残留上一次的后端标记。
    _avPlayerMode = isAvPlayerBackend;
    _resumeTarget = null;
    _resumeSeekDeadline = null;
    _stallRecoveries = 0;
    _fvpStallSince = null;
    _unrecoverableSignaled = false;
    // 🔴 2026-10-24（第十五轮）：avp 冻结自愈状态重置（换源/重建后端时）。
    _avpFrozenSince = null;
    _avpRecoveryFired = false;
    _avpLastPosition = Duration.zero;
    _avpLastBufferedEnd = Duration.zero;
    // ⚠️ 冻结自愈仅对 avp 后端生效（mpv/fvp 的冻结语义不同）。
    _avpMode = isAvPlayerBackend;
    // 🔴 2026-10-24（第十六轮）：新会话 ⇒ 清掉 seek 宽限与上次目标。
    _avpSeekGraceUntil = null;
    _lastSeekTargetUserMs = 0;
    // 🔴 2026-10-24（第十七轮）：新会话 ⇒ 清掉 seek 快速失败判据，
    //   否则上一会话残留的 _seekIssuedAt 会让新会话刚起播就被误判为 seek 失败。
    _seekIssuedAt = null;
    _seekIssuedFrom = Duration.zero;
    // 🔴 2026-10-26（第二十一轮）：新会话 ⇒ 清掉 seek 三判据的状态。
    _sfTargetRelMs = 0;
    _sfReachedTarget = false;
    _sfReachedAt = null;
    _sfReachedPosMs = -1;
    _sfReachedBufMs = -1;
    _sfRebuildFired = false;
    _sfBufAtSeekMs = -1;
    // seek 合并状态重置：上一次会话若在 seek 下发中被 dispose，可能残留
    // _seekInFlight=true，导致新会话的 seek 全部只被记录、永不真正下发。
    _seekInFlight = false;
    _pendingSeekTarget = null;

    final lowerUrl = url.toLowerCase();
    String finalUrl = url;

    // 点播：保持原逻辑（去广告/全局代理），不受本地代理总开关影响（点播本次未改动）。
    // 直播：仅在「本地代理」开关打开且配置了 M3U8 代理时，才把直播 M3U8 经本地代理转发，
    // 用于排查/兼容个别直播源（如神盾TV）。
    final proxyUrl = await UserDataService.getM3u8ProxyUrl();
    final adFilterEnabled = isLive ? false : await AdFilterService.isEnabled();
    final localProxyEnabled = await UserDataService.getLocalProxyEnabled();
    final isLocalProxy = _isLocalProxyUrl(url);
    final isM3u8 = lowerUrl.contains('.m3u8') || lowerUrl.contains('/hls/');
    final vodNeedsProxy = !isLive &&
        !isLocalProxy &&
        (proxyMode || (adFilterEnabled && proxyUrl.isNotEmpty && isM3u8));
    final liveNeedsProxy = isLive &&
        !isLocalProxy &&
        localProxyEnabled &&
        proxyUrl.isNotEmpty &&
        isM3u8;
    final needsProxy = vodNeedsProxy || liveNeedsProxy;
    if (needsProxy) {
      finalUrl = '$proxyUrl${Uri.encodeComponent(url)}';
    }

    // —— 诊断：打印代理/去广告判定，便于确认模拟器与真机是否走同一路径 ——
    WindowsLogger.log(
      'VideoPlayerBackendImpl',
      'open 判定: isLive=$isLive isM3u8=$isM3u8 isLocalProxy=$isLocalProxy '
          'adFilterEnabled=$adFilterEnabled localProxyEnabled=$localProxyEnabled '
          'proxyUrl=${proxyUrl.isEmpty ? "空" : proxyUrl} '
          'vodNeedsProxy=$vodNeedsProxy liveNeedsProxy=$liveNeedsProxy '
          '=> needsProxy=$needsProxy finalUrl=${finalUrl.length > 160 ? "${finalUrl.substring(0, 160)}..." : finalUrl}',
    );

    // 直播流优先使用低延迟缓冲配置；实际缓冲配置由后端包装类（ExoPlayerBackend / FvpBackend）在调用 open 前设置。

    final lowerFinalUrl = finalUrl.toLowerCase();
    final isNetwork =
        lowerFinalUrl.startsWith('http://') ||
        lowerFinalUrl.startsWith('https://');
    final isFile = lowerFinalUrl.startsWith('file://');

    final effectiveHeaders = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Accept': isLive
          ? 'application/vnd.apple.mpegurl,application/x-mpegurl,video/*,*/*;q=0.9'
          : '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      if (!isLive) ..._refererFor(url),
      // 仅 Android 直播路径：请求头透传一个内部标记，video_player_android 原生
      // 在构建 ExoPlayer 时据此启用 ffmpeg 音频软解（解 MediaCodec 硬解不了的
      // mp2 等）。点播/其它平台不带该头 → 原生维持纯硬解，不受影响。
      // 该头不会真正发给上游：原生端读取后剥离（见 stripInternalRequestHeaders 注释）。
      if (isLive && Platform.isAndroid) 'x-heinplay-soft-audio': '1',
      ...?stripInternalRequestHeaders(headers),
    };

    // 直播流补充 Referer / Origin，与 LunaTV 代理使用的请求头保持一致，
    // 提高 IPTV 源兼容性。
    if (isLive && isNetwork) {
      try {
        final uri = Uri.parse(finalUrl);
        final referer = '${uri.scheme}://${uri.host}${uri.path}';
        final origin = '${uri.scheme}://${uri.host}';
        effectiveHeaders.putIfAbsent('Referer', () => referer);
        effectiveHeaders.putIfAbsent('Origin', () => origin);
      } catch (_) {
        // 忽略 URL 解析异常
      }
    }

    VideoFormat? effectiveFormatHint = formatHint;
    if (effectiveFormatHint == null) {
      // udpxy 等 RTP over HTTP 代理以及原始 RTP/UDP/RTSP 组播通常传输 MPEG-TS，
      // 需要按普通媒体源播放，否则 ExoPlayer 会误按 HLS playlist 解析。
      if (lowerFinalUrl.contains('/rtp/') ||
          lowerFinalUrl.contains('/rtsp/') ||
          lowerFinalUrl.startsWith('rtp://') ||
          lowerFinalUrl.startsWith('udp://') ||
          lowerFinalUrl.startsWith('rtsp://')) {
        effectiveFormatHint = VideoFormat.other;
      } else if (lowerFinalUrl.contains('.smil')) {
        // LunaTV 等运营商代理把 RTSP/组播流包装成 http://.../rtsp/...xxx.smil?fcc=...
        // 实际返回 MPEG-TS 流，需走普通媒体源让 ExoPlayer 自动探测。
        effectiveFormatHint = VideoFormat.other;
      } else if (lowerFinalUrl.contains('.m3u8') ||
          lowerFinalUrl.contains('.m3u') ||
          lowerFinalUrl.contains('/hls/')) {
        effectiveFormatHint = VideoFormat.hls;
      } else if (lowerFinalUrl.contains('.mpd')) {
        effectiveFormatHint = VideoFormat.dash;
      } else if (lowerFinalUrl.contains('.ism')) {
        effectiveFormatHint = VideoFormat.ss;
      } else if (lowerFinalUrl.contains('.mp4') ||
          lowerFinalUrl.contains('.mkv') ||
          lowerFinalUrl.contains('.flv') ||
          lowerFinalUrl.contains('.avi') ||
          lowerFinalUrl.contains('.mov') ||
          lowerFinalUrl.contains('.webm') ||
          lowerFinalUrl.contains('.ts')) {
        effectiveFormatHint = VideoFormat.other;
      }
    }

    debugPrint('VideoPlayerBackendImpl open: $finalUrl');

    Future<void> doOpen() async {
      // viewType 选择规则（真机实测结论，勿再改动）：
      // - Windows / Linux：fvp/libmdk **必须** textureView —— platformView 会导致
      //   初始化失败或无法发起网络请求。
      // - Android：一律 platformView。曾传 preferTextureView=true 试让 Android 的 fvp
      //   也走 textureView，实测**每次都卡死**：initialize 假成功（报「完成」）后只建
      //   2 个 EGL context + AAudio 通路，随后无任何 MediaCodec/CCodec 解码器活动、
      //   无分片请求，画面永久黑屏。同一条 HLS 下 ExoPlayer（platformView）能正常
      //   拉起解码器，故卡死出在 texture 这条渲染路径，而非 platformView。
      // - 参数 preferTextureView 保留仅为兼容既有调用签名，当前无调用方传 true。
      final useTextureView =
          Platform.isWindows || Platform.isLinux || preferTextureView;
      // ── 鸿蒙 AVPlayer：起播定位预置（必须在 controller 创建之前）★ ──
      //
      // 🔴 2026-09-28 定稿：鸿蒙 AVPlayer 的公开 API **不支持「打开即定位」**——
      // media.PlaybackStrategy 无起始位置字段、createMediaSourceWithUrl 也只有
      // (url, headers) 两个参数。而 Dart 侧 initialize() 恰好 resolve 在 PREPARED
      // 时刻（原生 sendInitialized()），此时插件的 isPrepared 已为 true，内置的
      // pendingSeekPosition 通道永远走不到。
      //
      // 后果（真机日志实证）：AVPlayer 先按播放列表**第 0 片**拉流，之后才 seek 到
      // 续播点 → 用户看到「从片头缓冲」。日志里片头分片被请求了两次即为此故。
      //
      // 解法：调用本地 fork 新增的旁路入口，在 create 阶段把位置带下去，让原生侧
      // 预置到 pendingSeekPosition，从而在 prepare 阶段就完成定位。
      // 详见 deps/video_player_ohos 与 pubspec.yaml 的 fork 说明。
      //
      // ⚠️ 仅 avplayer 后端生效：fvp 与 ExoPlayer 无此入口（前者 libmdk 收到
      // prepare(位置) 会从第 0 片顺序下载、反而更糟，历史实测已记录；后者靠
      // seekTo 的内建「丢弃目标点前缓冲」即已满足）。
      if (_avPlayerMode && isNetwork && Platform.isOhos) {
        try {
          // 取全局平台单例并判定类型。
          // ⚠️ VideoPlayerPlatform 必须从 video_player_platform_interface 直接 import：
          // 本工程用的 video_player 是 TPC fork 版，其 barrel 文件未 re-export 该基类
          // （直接写 VideoPlayerPlatform 会 analyze 报 undefined_identifier）。
          // 同一写法已在 player_backend_factory.dart:11-13 使用，保持一致。
          final VideoPlayerPlatform platformInstance = VideoPlayerPlatform.instance;
          if (platformInstance is OhosVideoPlayer) {
            // 🔴🔴🔴 2026-10-24（第十三轮）：**不再下发原生起播定位（不 seek）**。
            //
            // 【为什么必须改】原生侧「预置起播定位」会让 AVPlayer 在播放前再
            // seek 一次落点，而这条路径在鸿蒙上是结构性死结：
            //   · PREPARED（未播放）态 seek ⇒ 与「拉第 0 片建索引」并发
            //     ⇒ 媒体服务内部冲突 ⇒ 5400103
            //     （真机证据 2026-10-24 20:01:44：位置跳变后 36ms 即 error）；
            //   · 改到 PLAYING 态 seek 才合法，但进 PLAYING 需要 surface，
            //     surface 要等 Flutter 建 texture、texture 要等 initialized、
            //     而 initialized 被「挂起等 seek 后首帧」锁住 ⇒ 三方死锁
            //     （真机证据 2026-10-24 21:06:55~21:07:25：三次起播全部
            //       30 秒超时失败；日志中「PLAYING 起播定位 seek」从未出现）。
            //
            // 【新做法】让**代理返回的列表第 0 片就是落点片**
            //   （LocalM3u8Proxy 起播裁剪，详见该文件 _applyStartTrim 注释）。
            //   AVPlayer 从落点片直接起播，**根本不需要 seek** ⇒
            //   原生侧走官方标准流程 prepare → prepared → play → playing，
            //   零状态机风险、零 5400103、首帧送显的就是落点画面。
            //
            // 【仍然要做的】primePrefetchAt：既预热落点分片，也让代理知道落点
            //   ⇒ 代理才能把列表裁到落点片。
            _startAtPresetApplied = startAt != null && startAt > Duration.zero;
            if (_startAtPresetApplied) {
              LocalM3u8Proxy.currentInstance?.primePrefetchAt(startAt!);
            }
            WindowsLogger.log(
              'VideoPlayerBackendImpl',
              '起播定位改为「代理裁剪列表」模式：落点 ${startAt?.inMilliseconds ?? 0}ms，'
              'AVPlayer 将从落点片直接起播，不再下发原生 seek',
            );
          } else {
            WindowsLogger.log(
              'VideoPlayerBackendImpl',
              '起播定位预置跳过：当前平台实现为 ${platformInstance.runtimeType}，'
                  '非 OhosVideoPlayer',
            );
          }
        } catch (e) {
          // 预置失败不应阻断播放：退化为原有的「init 后 seek」路径。
          debugPrint('起播定位预置失败(可忽略，将回退 init 后 seek): $e');
        }
      }

      if (isNetwork) {
        _controller = VideoPlayerController.networkUrl(
          Uri.parse(finalUrl),
          httpHeaders: effectiveHeaders,
          formatHint: effectiveFormatHint,
          viewType: useTextureView
              ? VideoViewType.textureView
              : VideoViewType.platformView,
        );
      } else if (isFile) {
        final filePath = Uri.parse(finalUrl).toFilePath();
        _controller = VideoPlayerController.file(
          File(filePath),
          httpHeaders: effectiveHeaders,
        );
      } else {
        _controller = VideoPlayerController.asset(finalUrl);
      }

      _controller!.addListener(_onControllerValueChanged);

      // 🔴 2026-10-06：fvp 已从本工程移除（鸿蒙仅 mpv + avplayer）。
      // 原 fvp 专有扩展 setVideoDecoders(fvpVideoDecoders 参数) 不再调用——
      // 鸿蒙无 fvp 后端，该分支恒不进入。fvpVideoDecoders 形参保留仅为兼容
      // 既有 open() 调用签名，已无任何引用。

      // 分段耗时日志：直播首次进入偶发长时间无画面，需要区分卡在「创建 controller」
      // 「initialize（原生 prepare / DNS / TLS 握手）」还是后续步骤。仅 debugPrint
      // 会被节流丢弃，这里用落盘日志。

      // ⚠️ 2026-09-24 23:2x 回退：曾在此处对 fvp 用 prepare(position:) 把续播点下发给
      // libmdk（避免 post-init seek 的读取器死寂）。实测**反而更糟**：libmdk 收到
      // prepare(续播点) 后并不跳段，而是从第 0 片**顺序下载**到续播点（日志实证 init 期间
      // 依次请求播放列表第 1/2/3…片），导致 initialize 耗时 14-32s（安卓侧虽 init 快但
      // 定位无效），超过 openTimeout(15s) → 误报「播放失败，即将进行自动换源」、起播显著
      // 变慢、Windows 全线播不了。fvp 仍改回「prepare(0) + initialize 后 seek 续播点」。
      WindowsLogger.log(
        'VideoPlayerBackendImpl',
        'controller 就绪，开始 initialize：format=$effectiveFormatHint '
            'viewType=${useTextureView ? 'texture' : 'platform'} '
            'isLive=$isLive',
      );
      final initStartedAt = DateTime.now();
      try {
        await _controller!.initialize();
      } catch (e, stackTrace) {
        debugPrint('VideoPlayerBackendImpl 初始化失败: $finalUrl');
        debugPrint('错误: $e');
        debugPrint('$stackTrace');
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          'initialize 失败（耗时 '
              '${DateTime.now().difference(initStartedAt).inMilliseconds}ms）: $e',
        );
        rethrow;
      }
      WindowsLogger.log(
        'VideoPlayerBackendImpl',
        'initialize 完成，耗时 ${DateTime.now().difference(initStartedAt).inMilliseconds}ms'
            '，首帧就绪 size=${_controller!.value.size}',
      );

      // 🔴 2026-10-06：fvp 已从本工程移除。原 fvp 专有扩展 setBufferRange
      // （缓冲窗口下发）不再调用——鸿蒙无 fvp 后端；Windows/Linux 桌面端的缓冲
      // 窗口后续将改为由 mpv 原生属性接管（见独立 mpv 桌面改造任务）。

      // 🔴 2026-10-06：fvp 已从本工程移除。原 Windows fvp 直连的 http-header 双保险
      // （_controller!.setProperty，fvp 专有扩展）删除——鸿蒙无此路径；桌面端 mpv
      // 改造时由 mpv 原生 http-header 属性接管。

      // 若指定了起始位置（播放记录续播 / 拖进度条），在 initialize() 完成后**立即**
      // seek，再开始播放 —— 即「播放记录第一时间读取」。
      //
      // 🔴 2026-09-22 修正：fvp 后端此前传 deferStartSeek: true，把定位推迟到
      // 「起播稳定后再 seek」，用户会先看到片头几十秒才跳走，观感上就是
      // 「fvp 定位不到播放记录、一播放直接播片头」。
      //
      // 当初认定「fvp 在 play() 之前 seek 会卡死」是**误判**：真因是 setBufferRange
      // 被写在 initialize() 之前而静默失效（见上方缓冲窗口处注释），seek 后需要重新
      // 缓冲却只有约 4 秒的预读窗口，于是表现为 position 冻结在 seek 目标、
      // `FVP_DECODE_STALL` 刷屏。缓冲窗口修好后，initialize() 之后直接 seek 安全，
      // 无需任何延迟。
      //
      // 此处之所以在 play() 之前 seek：让首帧就从目标位置产出，避免从 0 起播后
      // 再跳一下（ExoPlayer 同理）。
      if (startAt != null && startAt > Duration.zero) {
        _resumeTarget = startAt;
        // 🔴 2026-09-28：「续播定位自愈」的**有效期**只到起始定位结束为止。
        // 详见下方 _resumeSeekDeadline 的字段注释与 stall 判定处的修复说明。
        // 这里先登记窗口起点；各分支定位完成后会置 null 关闭自愈。
        _resumeSeekDeadline = DateTime.now().add(_resumeSeekWindow);
        if (isFvpBackend) {
          // fvp：initialize 之后一次性定位到续播点。
          //
          // ⚠️ 不要改用 prepare(position:)：libmdk 会从第 0 片顺序下载到续播点，
          // init 拖到 16-32s 并超过 openTimeout（2026-09-24 已撞坑）。
          //
          // 🔴 2026-09-28 删除「3 次带抖动重试」（用户指出）：
          // 旧实现连发 3 次 seek（startAt / +500ms / +1000ms），理由是「libmdk 在
          // 部分源上只设时钟、读取线程不跳段」。但用户明确：**当初「播不了」的真因
          // 是没有从播放记录处缓冲、卡住了**，而那是 setBufferRange 被写在
          // initialize() 之前静默失效导致的（见上方缓冲窗口处注释，已修）。
          // 预读窗口修好后，seek 到续播点本身就能正常缓冲，不需要抖动补偿 ——
          // 而这个抖动是有害的：即使第 1 次已跳段成功，后两次仍会把位置推到
          // target+1000ms，表现为用户报障的「读播放记录后先往前快进一点才开始播」，
          // 且污染 _resumeTarget 引发后续的「快退变快进」。
          // 故此处只发一次精确 seek，落点即为续播点本身。
          await Future.delayed(const Duration(milliseconds: 250));
          await _seekImpl(startAt);
          // ⚠️ 注意：fvp 分支这里**不**清空 _resumeTarget —— libmdk 的 seek 是
          // 「只设时钟、读取线程未必跳段」的异步行为，上面几次 seek 返回时无法确认
          // 读取线程是否真的跳了。故保留 _resumeTarget，交给运行期 stall 自愈在
          // _resumeSeekDeadline 窗口内做最终确认（这正是该自愈机制存在的意义）。
          // 窗口到期后它会被自动关闭（见 stall 判定处），不再干预后续播放。
        } else {
          // —— ExoPlayer（安卓/TV/Linux）与 AVPlayer（鸿蒙）共用同一套「系统播放器」
          //    起始定位逻辑：seek 一次 → 校验是否真正定位 → 未生效则重试 → 仍失败
          //    才回退片头。二者都是系统级硬解播放器，seek 语义可靠，不需要 fvp 那套
          //    「延迟抖动重试」补偿（那是为 libmdk 读取线程缺陷专门打的补丁）。
          //
          // 🔴 2026-09-28 修复「鸿蒙版点播起播必闪回片头」（用户报障）：
          // 此前 AVPlayer 被错误地并入了 ExoPlayer 分支，套用了
          // `bufferedEnd >= startAt` 判据 —— 但两个播放器的 buffered 语义**不同**：
          //   · ExoPlayer：`exoPlayer.getBufferedPosition()` = 已下载到的最远位置（绝对量）
          //   · AVPlayer ：VideoPlayer.ets:828 上报 `playTime + bufferingPosition`
          //                = 当前播放位置 + 缓冲窗口（相对量，并非「已下载到最远点」）
          // 于是 AVPlayer 上该判据必然误判：seek 发出后 200ms 内 playTime 还没更新，
          // bufferedEnd 恒为一个小值（实测恒 2880ms），5 次尝试全判失败 → 执行
          // `seek(Duration.zero)` → 用户看到「每次起播都闪一下从头播放才到播放记录」。
          // 实测日志（设备 9CN0223912004329，续播目标 752640ms）：
          //     seek target=752640ms before=0ms after=752640ms elapsed=5ms
          //     起始定位未生效(尝试 0..4): bufferedEnd=2880ms target=752640ms
          //     起始定位彻底失败，回退从 0 播放: target=752640ms
          //     seek target=0ms   ← 这就是用户看到的「闪一下从头播放」
          //     seek target=105579ms
          // 关键：此时 `position` 其实已经正确到 752640ms —— 是判据把正确结果否掉了。
          //
          // 因此改为按后端选用对应判据：ExoPlayer 用 bufferedEnd；
          // AVPlayer 则**不看 position**（理由见下），改为直接等待定位落地。
          //
          // 🔴 2026-09-28 修正 AVPlayer 判据（原判据恒为真，等于没有校验）：
          // 原实现用 `(position - startAt).abs() <= 5s` 判断是否定位成功，
          // 但 video_player_ohos 的 getPosition() 在 isSeeking=true 期间
          // **直接返回 seekPosition（即刚下发的目标值）** —— 于是 seek 一发出，
          // position 立刻「等于」目标，第一次 200ms 轮询就 break，判据永远为真。
          // 实测（avp 续播 1521s）：Dart 侧 200ms 就判「已定位」，
          // 而真实 SEEK_DONE 要 3.1 秒后才到，首帧更是 13.9 秒后才送显。
          // 这个假判据本身没造成误回退（它总是判成功），但也没提供任何保护，
          // 且掩盖了真实耗时，使问题长期不可见。
          //
          // 正确做法：AVPlayer 的起始定位由 ArkTS 侧保证 ——
          // VideoPlayer.ets 在 PREPARED 时挂起 sendInitialized，直到 SEEK_DONE 才发出，
          // 故**收到 initialized 事件即代表定位已完成**。Dart 侧此处只需发一次 seek，
          // 然后交给事件流；不再轮询、不再重复 seek（重复 seek 反而会打断
          // AVPlayer 正在进行的定位，把 SEEK_DONE 推得更晚）。
          //
          // ⚠️ 起始定位是**内部动作**，必须走 _seekImpl 而非公共 seek()：
          // 公共 seek() 会打印「用户手动 seek」并关闭续播自愈 —— 而这里是播放器
          // 自己的起播定位，不是用户操作。走公共 seek() 会误报日志、误关自愈。
          if (_avPlayerMode) {
            // 🔴🔴 2026-10-08 修复「读播放记录起播后画面卡死」（用户报障）。
            //
            // 真机日志实证（设备 9CN0223912004329，续播点 105279ms）：
            //   17:11:07.694 续播起播定位已预置: 105279ms
            //   17:11:07.694 createAVPlayer (textureId=1)
            //   17:11:10.090 avplayerStatus=prepared
            //   17:11:10.090 PREPARED 起播定位: 105279ms（挂起 sendInitialized，待 SEEK_DONE）
            //   17:11:10.090 起播定位完成(SEEK_DONE) time=105279ms → sendInitialized
            //   17:11:10.090 ← 旧实现的第二次 seek 正是在这里执行
            //   17:11:10.982 avplayerStatus=error
            //   17:11:10.983 AvPlayer Avoid Error Reporting: {"code":5400103}
            //   17:11:11.000+ reportBufferedPositionFromPlaybackInfo error: 5400102（连环）
            //   此后 position 恒为 105279ms、buffering 恒为 true → 画面永久卡死。
            //
            // 症结：`setNextStartPosition` 预置路径（见本文件 create 阶段说明）
            // **已经把定位做完了** —— ArkTS 侧在 PREPARED 时挂起 sendInitialized，
            // 直到 SEEK_DONE 才发出。因此 Dart 侧收到 initialized 这一个事实本身
            // 就等价于「定位已完成」。此时再 `_seekImpl(startAt)` 是对刚完成 seek 的
            // 播放器**重复 seek**，AVPlayer 状态机立刻进入非法态 → 5400103
            //（媒体服务内部错误）→ error → playbackInfo 查询连环 5400102。
            //
            // 关键证据：「SEEK_DONE → sendInitialized」与旧代码那一行**同为
            // 17:11:10.090**，零延迟；而 error 出现在 892ms 后。若定位真的还需要
            // Dart 再推一把，不可能在同一毫秒内就宣布完成。
            //
            // 这与上方注释写的设计意图一致（「AVPlayer 的起始定位由 ArkTS 侧保证」）,
            // 但原注释漏掉了「预置路径与 Dart 路径功能重复」这一点，故留下此缺陷。
            //
            // 判据：以「预置是否成功」为准（`_startAtPresetApplied` 在 create 阶段
            // setNextStartPosition 成功后置 true）。预置成功 → 不再 seek；
            // 预置失败（平台实现非 OhosVideoPlayer 或抛异常）→ 保留原行为发一次
            // seek，使无预置能力的平台仍能定位。
            if (!_startAtPresetApplied) {
              // 无落点定位需求（startAt 为空/0）⇒ 什么都不做。
              debugPrint('VideoPlayerBackendImpl AVPlayer 起始定位：无落点需求，跳过');
            } else if (_trimOffsetMs > 0) {
              // 🔴 2026-10-24（第十三轮）：**代理已把列表裁到落点片**
              //   ⇒ AVPlayer 从第 0 片（落点片）起播，**不需要任何 seek**。
              //   这是唯一不踩「PREPARED 态 seek ⇒ 5400103」且不触发
              //   「等 initialized ⇒ 等 PLAYING ⇒ 等 texture」死锁的路径。
              debugPrint(
                'VideoPlayerBackendImpl AVPlayer 起始定位：代理已裁剪列表，'
                'offset=${_trimOffsetMs}ms，AVPlayer 直接从落点片起播，无需 seek',
              );
            } else {
              // 🔴 2026-10-24 降级：裁剪未生效（分片表未就绪 / 落点越界等）
              //   ⇒ 回退为下发一次 seek。此时播放器已 prepared/playing，
              //   seek 是合法操作（旧实现是在 PREPARED 态 seek 才踩 5400103）。
              debugPrint(
                'VideoPlayerBackendImpl AVPlayer 起始定位：代理裁剪未生效，回退为'
                '下发一次 seek(${startAt.inMilliseconds}ms)',
              );
              await _seekImpl(startAt);
            }
          } else {
            await _seekImpl(startAt);
            var seekResolved = false;
            for (var attempt = 0; attempt < 5; attempt++) {
              await Future.delayed(const Duration(milliseconds: 200));
              final buffered = _controller?.value.buffered ?? const [];
              final bufferedEnd =
                  buffered.isNotEmpty ? buffered.last.end : Duration.zero;
              if (bufferedEnd >= startAt) {
                seekResolved = true;
                break;
              }
              debugPrint(
                'VideoPlayerBackendImpl 起始定位未生效(尝试 $attempt): '
                'bufferedEnd=${bufferedEnd.inMilliseconds}ms '
                'target=${startAt.inMilliseconds}ms，再次 seek',
              );
              await _seekImpl(startAt);
            }
            if (!seekResolved) {
              debugPrint(
                'VideoPlayerBackendImpl 起始定位彻底失败，回退从 0 播放: '
                'target=${startAt.inMilliseconds}ms',
              );
              await _seekImpl(Duration.zero);
            }
          }
          // ExoPlayer / AVPlayer 的定位已在上面同步确认完毕（判据成立即 break），
          // 无需运行期再自愈，故立即关闭「续播自愈」作用域，避免它在此后整个播放期
          // 持续拿起播点做 stall 校验、把用户的手动 seek 误判为「定位失败」而拉回。
          _resumeTarget = null;
          _resumeSeekDeadline = null;
        }
      }
      await _controller!.play();

      // 🔴 2026-10-24（第十三轮）：裁剪模式下 duration 是「相对落点」的，
      // 对外（进度条总长）必须换算回用户轴。
      _durationController.add(
        _controller!.value.duration + Duration(milliseconds: _trimOffsetMs),
      );
      _startPositionTimer();
    }

    // 直播网络源偶发因 CDN 调度到异常节点而返回 404/HTML/空响应，
    // 重试几次可换到正常节点。点播保持单次尝试。
    const maxAttempts = 3;
    final shouldRetry = isLive && isNetwork;
    Object? lastError;
    StackTrace? lastStack;
    for (var attempt = 1; attempt <= (shouldRetry ? maxAttempts : 1); attempt++) {
      try {
        await doOpen();
        return;
      } catch (e, stackTrace) {
        lastError = e;
        lastStack = stackTrace;
        debugPrint(
          'VideoPlayerBackendImpl 打开失败 (attempt $attempt/${shouldRetry ? maxAttempts : 1}): $e',
        );
        await dispose();
        if (shouldRetry && attempt < maxAttempts) {
          await Future.delayed(const Duration(milliseconds: 400));
        }
      }
    }

    debugPrint('VideoPlayerBackendImpl 初始化失败: $finalUrl');
    debugPrint('错误: $lastError');
    debugPrint('$lastStack');
    throw lastError!;
  }

  void _onControllerValueChanged() {
    final value = _controller?.value;
    if (value == null) return;
    if (value.hasError && value.errorDescription != null) {
      debugPrint('VideoPlayerBackendImpl 播放错误: ${value.errorDescription}');
      // 🔴🔴🔴 2026-10-24（第十六轮）：**原生上报的致命 seek 错误 ⇒ 立即重建**。
      //
      // 【真机实证】hilog 2026-10-24 22:13:24（14-13-49.txt）：
      //   22:13:24.965 code=5400103 message=IO Error: DEM_PARSE_ERR ...
      //              isSeeking=true seekPosition=0ms currentTime=-1ms
      //   ⇒ 往回 seek 时 AVPlayer 的 demuxer 无法回退（TS 已被消费释放）
      //   ⇒ 进入不可恢复的 error 态，且**不会自己重新拉流**（代理侧零分片请求）。
      //
      // 【为什么必须立即重建，而不是等 6 秒冻结判据】
      //   原生已确认「5400103 + 正在 seek」= 致命且不可恢复 ⇒ 等再久也起不来。
      //   立即重建到 [_lastSeekTargetUserMs] ⇒ 实测 2.4s 重新起播 ⇒ 秒级恢复。
      //
      // 【防重建风暴】[_avpRecoveryFired] 保证同一会话只重建一次
      //   （open() 会复位它 ⇒ 重建后的新会话可以再次自愈）。
      if (_avpMode && !_avpRecoveryFired) {
        _avpRecoveryFired = true;
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          '[AVP-FATAL-RECOVER] 收到原生致命错误（seek 期间 5400103）⇒ '
          '判定 AVPlayer 已死，立即重建播放器到用户目标 '
          '${_lastSeekTargetUserMs}ms',
        );
        final cb = onUnrecoverableStall;
        if (cb != null) {
          cb();
        }
      }
    }
    // 播放器原生报告播放完成时触发一次完成事件，
    // 避免仅依赖 position 流在片尾未精确更新时漏掉自动下一集。
    if (value.isCompleted && !_completedReported) {
      _completedReported = true;
      debugPrint('VideoPlayerBackendImpl 播放完成');
      _completedController.add(null);
    }
  }

  void _startPositionTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final value = _controller?.value;
      if (value == null) return;
      // 🔴 2026-10-24（第十三轮）：裁剪模式下 position / duration / buffered
      // 都是「相对落点」的值（AVPlayer 从落点片起播），对外统一加偏移换算回
      // 用户轴 —— 否则进度条会显示成"从头开始"，播放记录也会被写坏。
      final trimOff = Duration(milliseconds: _trimOffsetMs);
      _positionController.add(value.position + trimOff);
      _durationController.add(value.duration + trimOff);
      // 🔴 2026-10-26（第十八轮）：**兜底钳制缓冲末端**。
      //
      // 【真机实锤】hilog 2026-10-26 08:02:47.918（鸿蒙 TV 真机，第23集 46:03）：
      //   进度 position=79155ms buffered=1332257ms bufFirst=79147/1332257
      //         duration=1432625ms
      //   ⇒ 用户快进后，缓冲末端被推到接近片尾 ⇒ 进度条画成「缓冲到快完」（96%）。
      //   根因在原生侧（AVPlayer 的「可播放缓存时长」在 HLS 裁剪列表上会报成巨值），
      //   插件侧已钳到「缓冲窗口」内；这里再兜一层底：
      //   末端最多超出播放点 [_kMaxBufferAhead]（= avp 档位上限 120MB ≈ 120s）。
      //
      // ⚠️ 只影响**显示**的缓冲末端，不改任何播放行为；
      //   本文件仅被 avplayer_backend.dart 使用（exo/mpv/fvp 走各自后端）。
      final rawBufferedEnd =
          value.buffered.isNotEmpty ? value.buffered.last.end : value.position;
      final capEnd = value.position + _kMaxBufferAhead;
      final bufferedEnd = rawBufferedEnd > capEnd ? capEnd : rawBufferedEnd;
      _bufferedController.add(bufferedEnd + trimOff);
      _playingController.add(value.isPlaying);

      // —— 以下均为诊断日志，不影响播放行为 ——
      final now = DateTime.now();

      // 首帧尺寸就绪：解码器已开始产出画面（size 由 0 变为有效值）。
      if (!_firstFrameReported &&
          value.size.width > 0 &&
          value.size.height > 0) {
        _firstFrameReported = true;
        // 🔴 2026-10-24（第十四轮）：**首帧就绪时重置卡顿判据基准**。
        //
        // 【真机实证】hilog 2026-10-24 21:36:38.911（hailog-…-13-37-35.txt）：
        //   「首帧尺寸就绪 position=0ms」与「⚠️ AVP_DECODE_STALL: position 卡在
        //   0ms 已≥2s 无推进」**同一毫秒**打出 ⇒ 纯误报。
        //   根因：`_lastStallCheck` 的初值来自会话创建时刻，起播耗时 2.5s
        //   ⇒ 第一次采样就满足「距上次检查 ≥2s」，而此时 position 刚由
        //   undefined 变成 0（相对轴）⇒ 被判成「2 秒没推进」。
        //
        // 【修法】首帧就绪这一帧把基准对齐到「此刻 + 当时的 position」，
        //   卡顿计时从首帧开始算，而不是从会话创建开始算。
        _lastStallPosition = value.position;
        _lastStallCheck = now;
        _fvpStallSince = null;
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          '首帧尺寸就绪 size=${value.size} position=${value.position.inMilliseconds}ms',
        );
      }

      // 🔴 向订阅方广播「画面已可见」。与上面的诊断分开判断：
      //    诊断用 _firstFrameReported 只打一次日志，这里用 _firstFrameEmitted
      //    控制流的发送，二者语义一致但生命周期独立（避免互相干扰）。
      if (!_firstFrameEmitted &&
          value.size.width > 0 &&
          value.size.height > 0) {
        _firstFrameEmitted = true;
        if (!_firstFrameController.isClosed) {
          _firstFrameController.add(null);
        }
      }

      // 进度日志：用于区分「网络缓冲」(buffered 在涨但 position 不动)
      // 与「解码卡住」(buffered/position 都不动)。
      //
      // 🔴 2026-10-24（第十七轮）：**从「每 1 秒必打」改为「状态变化即打 + 5 秒心跳」**。
      //
      // 【为什么】真机 hilog 2026-10-24 22:38:46~22:39:45 里这条日志 20 秒打了
      //   36 条（hilog 每行再重复 15 次 ⇒ 540 行）。它走
      //   `WindowsLogger.log` → `print` → Flutter 引擎 → **同步 syslog 写**，
      //   属于主 isolate 上的同步开销，长播时累积可观。
      //   而正常播放时这条日志内容几乎不变（position 每 200ms 涨一次而已），
      //   信息量集中在「状态切换」与「长时间不动」两种时刻。
      //   ⇒ 状态变化立刻打；否则 5 秒打一次心跳（足够判断卡死趋势）。
      final _progressState =
          '${value.isPlaying}/${value.isBuffering}/'
          '${value.errorDescription ?? '无'}';
      final _stateChanged = _progressState != _lastProgressState;
      if (_stateChanged ||
          now.difference(_lastProgressLog).inMilliseconds >= 5000) {
        _lastProgressLog = now;
        _lastProgressState = _progressState;
        final buf = value.buffered;
        final buffered = buf.isNotEmpty ? buf.last.end : Duration.zero;
        // [FVP-DIAG] bufN = value.buffered 的条目数，是区分两种「buffered 恒等于
        // position」的关键：bufN>0 表示 fvp 确实上报了缓冲事件、但队列时长为 0
        // （读取线程未预取）；bufN==0 表示从未上报过缓冲事件（则缓冲条在 fvp 上
        // 天然画不出来，与读取无关）。isBuffering 反映 mdk 自己是否在等数据。
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          '进度 playing=${value.isPlaying} buffering=${value.isBuffering} '
              'position=${value.position.inMilliseconds}ms '
              'buffered=${buffered.inMilliseconds}ms '
              'bufN=${buf.length}'
              '${buf.isEmpty ? '' : ' bufFirst=${buf.first.start.inMilliseconds}/${buf.first.end.inMilliseconds}'} '
              'duration=${value.duration.inMilliseconds}ms '
              'size=${value.size} error=${value.errorDescription ?? '无'}',
        );
      }

      // ══════════════════════════════════════════════════════════════
      // 🔴🔴🔴 2026-10-26（第二十一轮）：**原生 seek 结果三判据**。
      //
      // 【必须放在 STALL 块之外】STALL 块每 2 秒才跑一轮，
      //   旧 FASTFAIL 关在里面 ⇒ 2200ms 阈值实际要等 2.2~4.2 秒才生效。
      //   本块**每次控制器值变化都执行** ⇒ 阈值才真正说了算。
      //
      // 【真机实证】hilog 2026-10-26 13:03:39（05-04-31.txt）：
      //   用户快进 +83.4 秒 ⇒ 原生 seek 1ms 就报出目标位置（after=83570），
      //   但该源 I 帧稀疏 ⇒ AVPlayer 随后把播放头**倒退 38.9 秒**回到
      //   I 帧重解（position 4670 = seek 前的值）。
      //   旧判据只看「当前 position」⇒ 100% 误判为 seek 失败。
      // ══════════════════════════════════════════════════════════════
      if (_avpMode && !_avpRecoveryFired) {
        final _sfPosMs = value.position.inMilliseconds;
        final _sfBufEndMs = value.buffered.isNotEmpty
            ? value.buffered.last.end.inMilliseconds
            : _sfPosMs;
        final _sfFromMs = _seekIssuedFrom.inMilliseconds;

        // ── 「曾到达目标附近」检测（每次都做，不受节流）─────────────
        if (!_sfReachedTarget && (_sfPosMs - _sfTargetRelMs).abs() < 2500) {
          _sfReachedTarget = true;
          _sfReachedAt = now;
          _sfReachedPosMs = _sfPosMs;
          _sfReachedBufMs = _sfBufEndMs;
          // 撤销判据①的观察窗：seek **已经落地**（哪怕随后因 I 帧稀疏而倒退重解）。
          // ⚠️ 旧实现在这里有 bug：撤销逻辑写在 else 分支里，只有「观察窗未到期」
          //    才会执行 ⇒ 一旦超过 2200ms 就永远撤不掉观察窗 ⇒ 必然误判。
          _seekIssuedAt = null;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '[AVP-SEEK-OK] seek 已到位 position=${_sfPosMs}ms '
                '（目标 ${_sfTargetRelMs}ms，用户目标 ${_lastSeekTargetUserMs}ms）'
                '⇒ 撤销快速失败观察，后续若发生「倒退/卡死」由判据②③接管',
          );
        }

        // ── 判据①：快速失败（真死锁）────────────────────────────────
        final _sfAt = _seekIssuedAt;
        // ⚠️ isPlaying 门控：用户**暂停**时 position 与 buffered 同样不动，
        //   若不排除，seek 后随手暂停会被当成「seek 失败」而白白重建。
        if (value.isPlaying &&
            _sfAt != null &&
            now.difference(_sfAt).inMilliseconds >= _kSeekFastFailMs.inMilliseconds) {
          final _sfProgressed = _sfPosMs > _sfFromMs + 1000;
          // 🔴 2026-10-26（第二十一轮）：真死锁 = position 不动 **且** buffered 不动。
          //   只判 position 会把「网络抖动 1.5 秒」误当成 seek 失败而白白重建
          //   （真机 5400103 后：position 恒 0ms、buffered 恒 17087ms ⇒ 两者都不动 ✓）。
          final _sfBufFrozen = _sfBufEndMs == _sfBufAtSeekMs;
          if (!_sfReachedTarget && !_sfProgressed && _sfBufFrozen) {
            _avpRecoveryFired = true;
            _seekIssuedAt = null;
            WindowsLogger.log(
              'VideoPlayerBackendImpl',
              '[AVP-SEEK-FASTFAIL] seek 后 '
                  '${now.difference(_sfAt).inMilliseconds}ms position 仍停在 '
                  '${_sfPosMs}ms（目标 ${_sfTargetRelMs}ms，seek 前 ${_sfFromMs}ms）'
                  '且 buffered 停在 ${_sfBufEndMs}ms 也不动'
                  '⇒ 判定本次 seek 已失败（原生无 seekDone 也无报错），'
                  '立即重建播放器到用户目标 ${_lastSeekTargetUserMs}ms',
            );
            if (onUnrecoverableStall != null) {
              onUnrecoverableStall!();
            }
          }
        }

        // ── 判据②：到位后退回（快进场景，AVPlayer 放弃目标点）────────
        //
        // 【真机实证】2026-10-26 13:03:43.560：position 从 83570 倒退到 4670
        //   （= seek 前的值），回退 38.9 秒 ⇒ 用户看到「跳过去又跳回来」。
        // 【为什么只对「快进」生效】用户主动**快退**时 position 本就该变小，
        //   那不是异常 ⇒ 只在「目标比起点更晚」时才把倒退当异常。
        if (_sfReachedTarget &&
            !_sfRebuildFired &&
            _sfTargetRelMs > _sfFromMs + 1000 &&
            _sfPosMs < _sfFromMs + 1000) {
          _sfRebuildFired = true;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '[AVP-SEEK-BACKWARD] seek 到位后播放头**倒退**回 seek 前的位置：'
                'position=${_sfPosMs}ms（seek 前 ${_sfFromMs}ms，'
                '目标 ${_sfTargetRelMs}ms，回退 ${_sfFromMs - _sfPosMs}ms）'
                '⇒ 该源关键帧稀疏，AVPlayer 放弃目标点退回 I 帧重解；'
                '改为重建播放器到用户目标 ${_lastSeekTargetUserMs}ms'
                '（重建走「代理按新落点裁剪 ⇒ 从落点片直接起播」，全程不 seek ⇒ 不会回退）',
          );
          final _cb = onSeekRebuildRequested;
          if (_cb != null) {
            _cb(_lastSeekTargetUserMs);
          } else {
            _sfRebuildFired = false;
          }
        }

        // ── 判据③：到位后卡死（position 与 buffered 同时不动）────────
        //
        // 【为什么需要】回退是**延迟发生**的（真机：到位后 4 秒才倒退），
        //   等到回退出现再重建，用户已经白等 4 秒。
        //   而「到位后 position 与 buffered 都不动」是回退的**早期信号**
        //   （真机 13:03:41.560 已可见）⇒ 2.5 秒即可判定并重建。
        // 【不会误伤】正常快进后 position 会持续前进；正常网络缓冲时
        //   buffered 在涨 ⇒ 两者都不满足「同时不动」。
        // ⚠️ isPlaying 门控：同上，暂停不算卡死。
        if (value.isPlaying &&
            _sfReachedTarget &&
            !_sfRebuildFired &&
            _sfReachedAt != null &&
            _sfPosMs == _sfReachedPosMs &&
            _sfBufEndMs == _sfReachedBufMs &&
            now.difference(_sfReachedAt!).inMilliseconds >=
                _kSeekReachedStallMs.inMilliseconds) {
          _sfRebuildFired = true;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '[AVP-SEEK-STUCK] seek 到位后 position(${_sfPosMs}ms) 与 '
                'buffered(${_sfBufEndMs}ms) **同时**不动 '
                '${now.difference(_sfReachedAt!).inMilliseconds}ms '
                '⇒ 判定此次 seek 实际未生效（该源 I 帧稀疏，AVPlayer 将回退重解），'
                '改为重建播放器到用户目标 ${_lastSeekTargetUserMs}ms',
          );
          final _cb = onSeekRebuildRequested;
          if (_cb != null) {
            _cb(_lastSeekTargetUserMs);
          } else {
            _sfRebuildFired = false;
          }
        }
      }

      // 卡顿探测：正在播放但 position 连续 ≥2s 无推进 → 解码/渲染卡死。
      if (value.isPlaying) {
        if (value.position > _lastStallPosition) {
          _lastStallPosition = value.position;
          _lastStallCheck = now;
          // 位置有推进 → 读取线程活着，死锁计时清零。
          _fvpStallSince = null;
        } else {
          // 位置未推进：开始（或继续）累计死锁时长。仅用于真死锁判定，
          // 不影响任何 UI —— 正常缓冲也走这里，但达不到 _fvpDeadlockMs。
          _fvpStallSince ??= now;
        }
        if (now.difference(_lastStallCheck).inMilliseconds >= 2000) {
          final buffered = value.buffered.isNotEmpty
              ? value.buffered.last.end
              : Duration.zero;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '⚠️ AVP_DECODE_STALL: 播放中 position 卡在 '
                '${value.position.inMilliseconds}ms 已≥2s 无推进; '
                'buffered=${buffered.inMilliseconds}ms size=${value.size} '
                'duration=${value.duration.inMilliseconds}ms '
                '=> 若 buffered 在涨=解码卡住, 若 buffered 也不动=网络/源卡住',
          );

          // 🔴🔴🔴 2026-10-24（第十五轮）：**avp 冻结自愈**。
          //
          // 【真机实证】hilog 2026-10-24 21:50:14（13-50-45.txt）：
          //   seek 后 171ms AVPlayer 进入 error 态（5400103）且不可恢复；
          //   进度 position 恒 0ms、buffered 恒 17087ms，**两个都纹丝不动**，
          //   直到用户退出（21:50:31.957 released）。
          //   原生屏蔽了 5400103/5400102（不 reset、不上报）⇒ Dart 侧零感知。
          //
          // 【判据】position 与 buffered **同时**不推进持续 ≥6s ⇒ 判定播放器已死。
          //   · 真网络缓冲：只有 position 停，buffered 仍在涨 ⇒ 不触发 ✓
          //   · 播放器已死：两个都停 ⇒ 触发 ✓
          //
          // 【处置】上抛 onUnrecoverableStall → 播放页**原地重建后端**，
          //   重建时以「冻结位置」作为新的起播落点 ⇒ 代理按新落点裁剪列表
          //   ⇒ AVPlayer 从该落点直接起播（实测 2.4s）⇒ **等价于跳转成功**，
          //   绝不会停在「卡死」状态。
          final _avpBufEnd = buffered;
          final _avpPosMoved = value.position != _avpLastPosition;
          final _avpBufMoved = _avpBufEnd != _avpLastBufferedEnd;

          // 🔴 2026-10-26（第二十一轮）：**旧的「seek 快速失败」判据已移出本块**。
          //
          // 【为什么要移】它被关在「每 2 秒一轮」的 STALL 块里 ⇒ 2200ms 的阈值
          //   实际要等 **2.2~4.2 秒**才生效（真机 2026-10-26 13:03:43 实测 4184ms）。
          // 【更要命的是判据本身】它只看「**当前** position」，
          //   而 AVPlayer 在 I 帧稀疏的源上会把播放头**倒退**回 seek 前的值
          //   （真机：倒退 38.9 秒）⇒ 100% 误判为 seek 失败。
          // ⇒ 新判据（三条）见下方「seek 结果三判据」块，**不受本块 2 秒节流约束**。

          // 🔴 2026-10-24（第十六轮）：seek 宽限期内的 position 跳变**不清零**计时，
          //   而是把起点重置到此刻 ⇒「seek 之后又冻结满 6 秒」才判死。
          final _avpInSeekGrace =
              _avpSeekGraceUntil != null && now.isBefore(_avpSeekGraceUntil!);
          if (_avpPosMoved || _avpBufMoved) {
            if (_avpInSeekGrace) {
              _avpFrozenSince = now;
            } else {
              _avpFrozenSince = null;
            }
          } else {
            _avpFrozenSince ??= now;
          }
          _avpLastPosition = value.position;
          _avpLastBufferedEnd = _avpBufEnd;
          final _avpFrozenAt = _avpFrozenSince;
          if (_avpMode && // ⚠️ 仅 avp 后端：mpv/fvp 的冻结语义不同，不在此自愈
              _avpFrozenAt != null &&
              !_avpRecoveryFired &&
              now.difference(_avpFrozenAt).inMilliseconds >=
                  _avpFreezeRecoverMs.inMilliseconds) {
            _avpRecoveryFired = true;
            WindowsLogger.log(
              'VideoPlayerBackendImpl',
              '[AVP-FREEZE-RECOVER] position(${value.position.inMilliseconds}ms) '
                  '与 buffered(${_avpBufEnd.inMilliseconds}ms) 同时冻结 '
                  '${_avpFreezeRecoverMs.inSeconds}s ⇒ 判定 AVPlayer 已死'
                  '（seek 后 error 态，真机 21:50:14.504 5400103），'
                  '上抛重建后端（按冻结位置重新起播）',
            );
            if (onUnrecoverableStall != null) {
              onUnrecoverableStall!();
            } else {
              // 无重建回调：退而求其次，至少把 isSeeking 状态清掉，别把界面冻住。
              WindowsLogger.log(
                'VideoPlayerBackendImpl',
                '[AVP-FREEZE-RECOVER] 无重建回调，跳过自愈',
              );
            }
          }

          // —— fvp 续播定位失败自愈（2026-09-24）：时钟在续播点但读取线程未跳段 →
          // 永久冻结。fvp 会谎报 position/buffered 为时钟值，无法靠 bufferedEnd 判定，
          // 故在此「playing 但 position 持续不推进且非网络缓冲等待」时主动回退：
          // 先重试 seek 目标段（抖动以绕过 libmdk seek no-op）；重试耗尽后回退从片头
          // 播放（远比永久冻结可接受）。4s 冷却 + 次数上限避免正常网络缓冲抖动误触发。
          // fvp 续播卡死时往往 isBuffering==true（假缓冲：读取线程卡在某段，
          // libmdk 自认为在等数据），用 !isBuffering 会把这类卡死永久排除，
          // 导致自愈从不触发。改用「buffered 是否领先 position」区分：
          // 真网络缓冲时 buffered 会明显领先 position；卡死时 buffered≈position（不领先）。
          final _bufferedEnd = value.buffered.isNotEmpty
              ? value.buffered.last.end
              : Duration.zero;
          final _noForwardBuffer =
              _bufferedEnd <= value.position + const Duration(milliseconds: 1000);

          // 🔴 2026-09-28 二次修复（用户报障「每次打开播放记录都往前跳一些，
          //    自己快退到记录点附近还会被弹回去」）：
          //
          // 上一版给自愈加了「有效期 + 位置闸」（见下方注释残段），但**判据本身
          // 仍然无法区分「正在正常缓冲」与「libmdk 读取线程真死」** ——
          // 两者在观测上完全一致：position 不推进、前方无缓冲。
          // 结果起播缓冲期必然被判成「定位失败」，于是盲试 seek 把位置推来推去
          // （抖动目标 +500ms 就是用户看到的「往前跳」），用户手动快退靠近记录点
          // 时又被拉回记录点（「快退变快进」）。误伤率高到这个自愈有害无益。
          //
          // 【处置】删掉「盲试 seek」这一步，只保留**最终兜底：上抛重建后端**。
          //  · 盲试 seek 删掉的理由：它既无法可靠判定故障，代价又是可见的位置跳变；
          //    而「真正读取线程死」的场景，重建后端（重新 open + 重新定位）才有效，
          //    重试同一个 seek 本就不可能救活一个已死的读取线程。
          //  · 上抛重建保留的理由：这是唯一能在「真死」时恢复的手段，
          //    且它由 isStalledSince 的**长时限**判定守护（见下），不会误触发。
          //
          // 触发门槛从「position 2s 不推进」提高到「position 连续 8s 不推进**且**
          // 前方始终无缓冲」：正常起播/网络缓冲不会连续 8 秒毫无进展，
          // 而真死锁是无限期的。宁可晚 6 秒兜底，也不要每次起播都误伤一次。
          final _resumeDeadline = _resumeSeekDeadline;
          final _withinResumeWindow =
              _resumeDeadline != null && now.isBefore(_resumeDeadline);
          if (!_withinResumeWindow && _resumeTarget != null) {
            // 窗口已过：关闭自愈作用域，之后不再参与判定。
            _resumeTarget = null;
            _resumeSeekDeadline = null;
          }
          // 真死锁判定：position 连续 _fvpDeadlockMs 毫无推进，且前方始终无缓冲。
          // 正常起播/网络缓冲不会这么久毫无进展；真死锁则是无限期停滞。
          final _deadlock = _resumeTarget != null &&
              _fvpMode &&
              _withinResumeWindow &&
              _noForwardBuffer &&
              now.difference(_fvpStallSince ?? now).inMilliseconds >=
                  _fvpDeadlockMs.inMilliseconds;
          if (_deadlock) {
            _stallRecoveries++;
            // 不再盲试 seek —— 见上方「二次修复」说明：重试同一个 seek 救不活
            // 已死的读取线程，只会制造可见的位置跳变。直接上抛重建后端。
            if (!_unrecoverableSignaled && onUnrecoverableStall != null) {
              _unrecoverableSignaled = true;
              WindowsLogger.log(
                'VideoPlayerBackendImpl',
                '[STALL-RECOVER] 读取线程疑似真死（position 停滞 '
                '${_fvpDeadlockMs.inSeconds}s），上抛重建 avp 后端 '
                '(target=${_resumeTarget!.inMilliseconds}ms)',
              );
              onUnrecoverableStall!();
            } else if (_stallRecoveries <= _maxStallRecoveries) {
              // 无重建回调：退而求其次回退片头，避免永久冻结。
              WindowsLogger.log(
                'VideoPlayerBackendImpl',
                '[STALL-RECOVER] 无重建回调，回退从 0 播放 '
                '(target=${_resumeTarget!.inMilliseconds}ms)',
              );
              _seekImpl(Duration.zero);
              _resumeTarget = null; // 已回退，避免反复回退到片头
            }
          }
          _lastStallCheck = now; // 避免每个 tick 重复刷
        }
      }
    });
  }

  @override
  Future<void> play() async {
    await _controller?.play();
    _playingController.add(true);
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
    _playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    // 🔴 2026-09-28：**用户手动 seek 必须立即关闭「续播定位自愈」**。
    //
    // 【用户报障】「滑动屏幕往后快退，却变成快进」「每次读取播放记录都会先往前
    //   快进一些才开始播放」。
    //
    // 【根因】自愈逻辑（见 _resumeTarget 字段说明）在起播后 20 秒窗口内，只要
    //   「位置仍停留在续播点附近（±10s）且前方无缓冲」就判定为「libmdk 只设时钟
    //   未跳段」，于是 seek 回续播点强制重跳。用户手动快退到续播点附近时恰好
    //   落进这个判定：自愈把位置**拉回续播点** = 观感「快退变快进」。
    //   起播时那 3 次 +500ms/+1000ms 抖动 seek 是同一机制的另一面，
    //   表现为「读记录后先往前跳一点才开始播」。
    //   判据本身没错，错在**没有区分「自愈发的 seek」与「用户发的 seek」**。
    //
    // 【处置】用户一动手就关掉自愈作用域 —— 用户已用行动表明他要看哪里，
    //   此后任何「拉回续播点」的行为都是错的。本次 open 周期内不再自愈。
    if (_resumeTarget != null) {
      WindowsLogger.log(
        'VideoPlayerBackendImpl',
        '用户手动 seek(${position.inMilliseconds}ms) → 关闭续播自愈 '
        '(原 target=${_resumeTarget!.inMilliseconds}ms)',
      );
      _resumeTarget = null;
      _resumeSeekDeadline = null;
    }
    await _seekImpl(position);
  }

  /// [seek] 的实际实现，也是自愈内部重跳的入口。
  ///
  /// 拆成两个方法是为了让「用户 seek 关自愈」与「自愈自己 seek」互不干扰：
  /// 自愈走本方法，不会把自己的作用域关掉。
  Future<void> _seekImpl(Duration position) async {
    // —— AVPlayer 专属：seek 合并（coalescing）——
    //
    // 🔴 2026-09-28 修复「鸿蒙版快进快退有时失效、回到快进前的位置」（用户报障）。
    //
    // 触发路径：长按快进/快退的调用方（player_screen.dart `_startHalfSpeedSeek`）
    // 每 200ms 下发一次 seek，一次长按连发十几到几十次 —— 安卓版同样如此，
    // 且安卓不出问题，因为 ExoPlayer 的 seek 是**队列化**的：请求按序处理，
    // getCurrentPosition() 立即跟随。而 video_player_ohos 的 ETS 实现
    // （VideoPlayer.ets）每次 seekTo 都执行：
    //     prepareSeek(pos) → isSeeking = true; seekPosition = pos
    //     avPlayer.seek(pos, SEEK_CLOSEST)
    // 其中 `isSeeking` **只由 SEEK_DONE 事件复位**，且 getPosition() 在
    // isSeeking=true 期间返回 seekPosition、复位后返回真实 avPlayer.currentTime。
    // 密集下发时 AVPlayer 会丢弃来不及完成的中间 seek，isSeeking 长期为 true；
    // 等最后一次 SEEK_DONE 到达、getPosition() 切回真实 currentTime 时，
    // 若那次 seek 恰被丢弃，真实位置仍在快进前 → 「快进失效、跳回原位」。
    // 实测日志（设备 9CN0223912004329）连续快进 5000ms/次期间，
    // buffered 始终落后目标约一个分片（bufEnd 恒比 target 小 5000ms）。
    //
    // 处置：仅对 AVPlayer 启用合并 —— 同一时刻只允许一个 seek 在下发中，
    // 期间到来的新目标只记录为「待下发的最新目标」，等当前 await 返回后再发最后一次。
    // 这样长按期间的 seek 次数从「每 200ms 一次」降到「受播放器处理速度约束」，
    // 既不去打播放器，也不会丢失最终目标。
    //
    // ⚠️ 为什么不做成全局（也影响 ExoPlayer/fvp）：
    //  · ExoPlayer 本就队列化，无需合并，加了反而改变已验证的行为；
    //  · fvp 的起始定位依赖「串行 await 的抖动重试」（3 次不同 target），
    //    全局合并会干扰其间隔，属于无谓风险。
    // 故只在 `_avPlayerMode` 下走合并路径，其余后端保持原有直通语义不变。
    if (!_avPlayerMode) {
      await _seekToInternal(position);
      return;
    }

    _pendingSeekTarget = position;
    if (_seekInFlight) return;

    _seekInFlight = true;
    try {
      // 循环直到「没有更新的目标」为止：每次取走当下最新的目标下发。
      while (_pendingSeekTarget != null) {
        final target = _pendingSeekTarget!;
        _pendingSeekTarget = null;
        await _seekToInternal(target);
      }
    } finally {
      _seekInFlight = false;
    }
  }

  /// 实际下发一次 seek 到播放器（含诊断埋点）。仅供 [seek] 的合并循环调用。
  Future<void> _seekToInternal(Duration position) async {
    // 🔴 2026-10-24（第十三轮）：裁剪模式下**播放器的时间轴是「相对落点」**的
    // （AVPlayer 从落点片起播），而对外的 position 是用户轴 ⇒ 下发给播放器前
    // 必须减掉偏移，否则会跳到错误位置。
    //
    // ⚠️ 代理预热（primePrefetchAt）必须仍用**用户轴**位置 ——
    //   代理的分片轴与用户轴同源，减去偏移会落到错误的段上。
    final trimOffsetMs = _trimOffsetMs;
    // 🔴 2026-10-24（第十六轮）：记录**用户轴**目标。
    //   播放器死亡后重建必须落到这个位置（播放器死后 position 会冻结，
    //   用 position 当落点会跳错位置）。
    _lastSeekTargetUserMs = position.inMilliseconds;
    // 🔴 2026-10-24（第十六轮）：seek 宽限 6 秒 —— 防止 seek 引发的 position
    //   跳变把「冻结自愈」计时清零（真机：连续 seek ⇒ 自愈一次都没触发）。
    _avpSeekGraceUntil = DateTime.now().add(_avpFreezeRecoverMs);

    // 🔴🔴🔴 2026-10-24（第十六轮）：**目标落在裁剪落点之前 ⇒ 不 seek，改重建**。
    //
    // 【为什么】裁剪列表的第 0 片 = 落点片 ⇒ 落点之前的内容在列表里不存在。
    //   硬 seek 只会：① 被 clamp 到落点（跳错位置）② 触发 5400103（播放器死）。
    //   ⇒ 正确做法是让代理按**新落点**重新裁剪列表，再从新落点起播。
    //
    // 【真机实证】hilog 2026-10-24 22:13:24：userTarget=1053991ms <
    //   trimOffset=1132520ms ⇒ target 被 clamp 成 0 ⇒ 实际跳到落点片，
    //   随后 138ms 报 5400103 ⇒ 界面永久冻住。
    if (trimOffsetMs > 0 && position.inMilliseconds < trimOffsetMs) {
      WindowsLogger.log(
        'VideoPlayerBackendImpl',
        '[SEEK-REBUILD] 目标 ${position.inMilliseconds}ms 落在裁剪落点之前'
        '（trimOffset=${trimOffsetMs}ms）⇒ 不可 seek，改为重建播放器到该位置',
      );
      final cb = onSeekRebuildRequested;
      if (cb != null) {
        cb(position.inMilliseconds);
        return;
      }
      WindowsLogger.log(
        'VideoPlayerBackendImpl',
        '[SEEK-REBUILD] 无重建回调，回退为普通 seek（会跳到落点）',
      );
    }
    final playerPosition = trimOffsetMs > 0
        ? Duration(
            milliseconds:
                (position.inMilliseconds - trimOffsetMs).clamp(0, 1 << 30),
          )
        : position;
    // —— 诊断埋点（[FVP-DIAG]，用于定位「seek 后读取线程不预取」）——
    final before = _controller?.value.position ?? Duration.zero;
    final t0 = DateTime.now();
    // 🔴 2026-10-24（第十七轮）：记录本次 seek 的发出时刻与起点，
    //   供 [positionTimer] 里的「seek 快速失败」判据使用（见字段注释）。
    _seekIssuedAt = t0;
    _seekIssuedFrom = before;
    // 🔴 2026-10-26（第二十一轮）：重置 seek 三判据的状态，并缓存本次目标
    //   （代理相对轴）供进度回调反复比对，避免每次重算。
    _sfTargetRelMs = (position.inMilliseconds - trimOffsetMs).clamp(0, 1 << 30);
    _sfReachedTarget = false;
    _sfReachedAt = null;
    _sfReachedPosMs = -1;
    _sfReachedBufMs = -1;
    _sfRebuildFired = false;
    // seek 发出那一刻的 buffered 末端（判据①「真死锁」需要 position 与
    // buffered **同时**不动 ⇒ 网络慢时 buffered 在涨，不会被误判）。
    final _bufNow = _controller?.value.buffered;
    _sfBufAtSeekMs = (_bufNow != null && _bufNow.isNotEmpty)
        ? _bufNow.last.end.inMilliseconds
        : before.inMilliseconds;

    // 🔴 2026-09-28 已删除「seek 前收紧预读窗口」补丁（曾把 max 压到 2000ms）。
    //
    // 【为什么删】该补丁方向错误，反而加剧了用户报障的「快退变快进、快进再往前跳」。
    //
    // 真因在 seek flags 而非缓冲窗口：mdk 头文件 global.h:120 明确
    //   "Accurate seek is slow and **implies backward seek internally**" ——
    // 不带 KeyFrame 的精确 seek 会**回溯到目标之前的关键帧**再解码，
    // 这正是「往回跳/往前跳」的来源。我们曾设 fastSeek:false 恰好激活该路径。
    //
    // 更糟的是，收紧 max 会让 mdk 的 SeekFlag.inCache 更快失效：
    //   global.h:123 — "Target position must be in range
    //                   (position(), position() + Player.buffered()]"
    // 缓存窗口越小，越容易落到 buffered() 之外 → 退回精确 seek 的 backward 回溯。
    // 即：本补丁把「seek 命中缓存」的概率改小了，与目标完全相反。
    //
    // 正确修复 = 恢复 fastSeek:true（见 player_backend_factory.dart 的说明），
    // 让 seek 走 key-frame forward 路径，不再回溯。
    //
    // 🔴 2026-10-24 第七轮：**seek 之前先把代理的预取窗口预热到落点**。
    //
    //   【真机实锤：hilog 2026-10-24 10:08】
    //     18:06:09.961 [SEEK-DIAG] seek target=1364790ms
    //     18:06:10.335 buffering=true … 18:06:12.735 buffering=true  ← 冻结 3.6 秒
    //     18:06:13.936 buffering=false
    //   冻结期间 buffered 一直是 1515891ms（远大于落点），
    //   说明**数据在代理手上都有**，但落点附近那几段还没被预取到
    //   ⇒ 播放器 seek 过去要现等 CDN（单段 ttfb 0.78~2.10s）。
    //   预热后落点附近的段已在缓存里 ⇒ seek 直接命中。
    // ⚠️🔴 2026-10-24（第十四轮）：预热目标必须**先按裁剪窗口收敛**。
    //
    //   【为什么】裁剪模式下播放器只能访问「落点之后」的内容。
    //   用户快退到落点之前（userTarget < trimOffset）时，下发给播放器的是
    //   相对 0（= 落点），但这里若仍用原始 userTarget 去预热，
    //   代理会去预取**裁剪列表里根本不存在**的段（白下载 + 污染预取队列，
    //   还会触发「位置跳变、丢弃过时队列」把真正要用的落点段丢掉）。
    //   ⇒ 预热目标取 max(userTarget, trimOffset) —— 与播放器实际能到的位置一致。
    final prefetchTargetMs = trimOffsetMs > 0
        ? (position.inMilliseconds < trimOffsetMs
            ? trimOffsetMs
            : position.inMilliseconds)
        : position.inMilliseconds;
    LocalM3u8Proxy.currentInstance?.primePrefetchAt(
      Duration(milliseconds: prefetchTargetMs),
    );

    // 🔴 2026-10-24 第七轮：**seek 后重置卡顿判据的高水位**。
    //
    //   【真机实锤：hilog 2026-10-24 10:08】avp 会话
    //     18:06:09.961 [SEEK-DIAG] seek target=1364790ms before=1515891ms
    //   倒退 seek 后 position 变成 1364790，而 `_lastStallPosition` 仍是
    //   seek 前的 1515891 ⇒ 「position 是否推进」永远为假
    //   ⇒ **18:06:12~18:06:57 连续误报 23 次 `AVP_DECODE_STALL`**，
    //   而这 46 秒里 position 实际以 1.0 倍速正常前进（1365573 → 1410767），
    //   buffered 领先 116~161 秒 —— **纯属误报**。
    //
    //   误报的危害：把真实卡顿淹没在噪声里（用户/我都要靠日志定位），
    //   而且日志里每次都打「若 buffered 不涨=网络卡」，误导归因。
    //
    //   修法：seek 一发生就重置高水位与计时基准。
    // ⚠️ 高水位必须与 `value.position` 同一根轴（都是**相对轴**），
    //   否则「position 是否推进」判据恒为假 ⇒ 连续误报 AVP_DECODE_STALL。
    _lastStallPosition = playerPosition;
    _lastStallCheck = DateTime.now();
    _fvpStallSince = null;

    await _controller?.seekTo(playerPosition);

    final after = _controller?.value.position ?? Duration.zero;
    final buf = _controller?.value.buffered ?? const [];
    WindowsLogger.log(
      'VideoPlayerBackendImpl',
      '[SEEK-DIAG] seek target=${playerPosition.inMilliseconds}ms '
          'userTarget=${position.inMilliseconds}ms trimOffset=${trimOffsetMs}ms '
          'before=${before.inMilliseconds}ms after=${after.inMilliseconds}ms '
          'elapsed=${DateTime.now().difference(t0).inMilliseconds}ms '
          'bufN=${buf.length}'
          '${buf.isEmpty ? '' : ' bufEnd=${buf.last.end.inMilliseconds}ms'}',
    );
    _positionController.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _controller?.setPlaybackSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    await _controller?.setVolume(volume.clamp(0.0, 1.0));
  }

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Stream<Duration> get bufferedStream => _bufferedController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Stream<void> get firstFrameStream => _firstFrameController.stream;

  @override
  Future<void> dispose() async {
    WindowsLogger.log('VideoPlayerBackendImpl', 'dispose 开始');
    _timer?.cancel();
    _timer = null;
    _completedReported = false;
    _unrecoverableSignaled = false;
    final controller = _controller;
    _controller = null;
    if (controller == null) return;
    controller.removeListener(_onControllerValueChanged);
    try {
      // Windows FVP/libmdk 在纹理仍处于高频渲染状态时销毁原生播放器，
      // 释放纹理/停止渲染线程会等待渲染协同一方，直播流（持续推帧）或
      // 点播刚退出全屏（窗口 surface 刚重建）时极易死锁导致退出卡死。
      // 先暂停停止渲染，让渲染线程空闲后再销毁，规避该竞态。
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: pause 前');
      await controller.pause().timeout(
        const Duration(milliseconds: 500),
        onTimeout: () {},
      );
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: pause 后');
    } catch (e) {
      // 初始化失败/已销毁时 pause 可能抛异常，忽略即可。
      debugPrint('VideoPlayerBackendImpl dispose 暂停忽略异常: $e');
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: pause 异常 $e');
    }
    try {
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: dispose 前');
      // ⚠️ controller.dispose() 必须加超时兜底（fvp 全平台退出卡死的通病点，
      // 2026-09-22 定案）：libmdk 原生 stop 会等待读取/解码/渲染线程退出，
      // 当读取线程卡在饿死状态（缓冲失效期的高发态，如 seek 后 reader 不预取、
      // 网络阻塞读）时，原生销毁永不返回，上面的 try/catch 拦不住「不返回」，
      // 退出流程就永远停在这里 → 退出卡死。超时后放弃等待，保证 UI 退出不被
      // 拖死；代价是该极端情况下可能残留一个原生播放器实例（可接受的权衡）。
      await controller.dispose().timeout(
        const Duration(milliseconds: 2000),
        onTimeout: () {
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            'dispose: ⚠️ controller.dispose() 超时 2s，放弃等待原生销毁（可能残留一个原生播放器）',
          );
        },
      );
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: 完成');
    } catch (e) {
      // 初始化失败时底层 playerId 可能不存在，dispose 会抛 IllegalStateException，
      // 忽略该异常避免影响下一次播放。
      debugPrint('VideoPlayerBackendImpl dispose 忽略异常: $e');
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: 异常 $e');
    }
  }
}
