import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:hain_tv/services/screen_wake_ohos.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/services/playback_activity.dart';
import 'package:hain_tv/models/skip_segment.dart';
import 'package:hain_tv/models/video_detail.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/player/video_player_backend.dart';
import 'package:hain_tv/player/mpv_backend.dart';
import 'package:hain_tv/player/switch_gate.dart';
import 'package:hain_tv/services/ad_filter_engine.dart';
import 'package:hain_tv/services/local_m3u8_proxy.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';
import 'package:hain_tv/widgets/common/skip_config_dialog.dart';

class MobilePlayerScreen extends StatefulWidget {
  final VideoDetail videoDetail;
  final int episodeIndex;
  final List<SourceOption>? sources;
  final ValueNotifier<List<SourceOption>>? sourcesNotifier;
  final int initialSourceIndex;
  final PlayerBackendType playerBackend;
  final int initialPositionMs;

  MobilePlayerScreen({
    super.key,
    required this.videoDetail,
    this.episodeIndex = 0,
    this.sources,
    this.sourcesNotifier,
    this.initialSourceIndex = 0,
    this.playerBackend = PlayerBackendType.exo,
    this.initialPositionMs = 0,
  });

  @override
  State<MobilePlayerScreen> createState() => _MobilePlayerScreenState();
}

class _MobilePlayerScreenState extends State<MobilePlayerScreen>
    with WidgetsBindingObserver {
  late VideoDetail _currentVideoDetail;
  late int _currentSourceIndex;
  // 记录进入播放页时详情页选中的源标识，用于 sourcesNotifier 更新后
  // 仍能准确找回当前源，避免仅依赖 VideoDetail 的 source/id 匹配失败
  // 导致播放源被重置到列表首位。
  String? _initialSourceKey;
  VideoPlayerBackend? _backend;

  /// 🔴 2026-09-30：requiresEagerMount 后端（mpv）的常驻视频层实例。
  ///
  /// 必须在整个播放期复用**同一个** widget 实例：PlatformView 一旦被重建，
  /// 原生侧会销毁旧 Player（连同 viewId）并新建一个，导致播放中断、
  /// Dart 侧持有的 _viewId 失效。故缓存后不再重建，仅切换显隐。
  ///
  /// 生命周期：随 [_backend] 一起更换 —— 见 [_replaceBackend] 与 [dispose]。
  Widget? _eagerVideoLayer;

  /// 🔴 2026-10-07 换源修复：常驻视频层（OhosView 锚点）的「代数」。
  ///
  /// 换源时旧 PlatformView 已被原生 dispose，必须让 Flutter 重新创建
  /// PlatformView，原生才会 new 出新的 Player 与 viewId。
  /// 修改本字段并置 _eagerVideoLayer=null，锚点上的 ValueKey 随之变化，
  /// Flutter 便销毁旧 PlatformView、创建新的（详见 _buildVideo 内注释）。
  int _eagerLayerGeneration = 0;

  /// 让常驻视频层换代：销毁当前 PlatformView，下一次 build 创建全新的。
  ///
  /// 仅用于**换源/换集**这类「旧 view 已原生销毁、必须拿到新 view」的场景。
  /// 同一会话内的 pause/seek 等操作**不得**调用它，否则会白白中断播放。
  void _regenerateEagerVideoLayer() {
    _eagerLayerGeneration++;
    _eagerVideoLayer = null;
  }

  bool _switchingBackend = false; // fvp 续播卡死→原地重建 fvp 后端过程中防重入
  int _fvpStallRetries = 0; // fvp 续播卡死重建次数（防止无限重建循环）
  // 🔴 2026-10-07：硬解黑屏自动回退软解的「已用掉」标记。
  //   同一集内只回退一次，避免「软解也失败 → 再回退」的死循环；
  //   换到别的集时复位（比对 _hwdecFallbackEpisodeIndex）。
  bool _hwdecFallbackUsed = false;
  int _hwdecFallbackEpisodeIndex = -1;
  // 🔴 2026-10-07：硬解回退**重建之后**的兜底重开标记。
  //   与 _hwdecFallbackUsed 分开，是因为两者语义不同：
  //     _hwdecFallbackUsed       = 「已经决定降级软解」，防止反复降级；
  //     _sourceRetryAfterFallbackUsed = 「重建时可能撞上了未完成的代理分片请求，
  //                                     所以允许再重开一次」，防止整集直接失败。
  //   真机 22:44:52 现场：回退重建的第二次 open 与旧 open 的代理分片请求撞车，
  //   mpv 54ms 内报「hls: Error when loading first segment」，整集播放失败，
  //   而 _hwdecFallbackUsed 已置位 → 再无机会 → 用户必须退出重进。
  //   这个标记就是给那种情况留的一线生机，仅用一次。
  bool _sourceRetryAfterFallbackUsed = false;
  static const int _kMaxFvpStallRetries = 2; // 最多重建 2 次，仍失败则放弃自动恢复
  // 🔴 2026-10-24（第十六轮）：**seek 重建**的独立计数。
  //
  // 【为什么不复用 _fvpStallRetries】语义不同、额度也不该共用：
  //   · _fvpStallRetries 治「播放器死了」，一次会话里出现 2 次已很异常；
  //   · seek 重建治「用户想跳到裁剪落点之前」，这是**正常操作**
  //     （用户连续快退几次就会触发多次）⇒ 与故障额度共用会让
  //     用户退两下就再也跳不动了。
  // 【上限】取 8：够用户连续快退，又能挡住「重建后仍不可达」的死循环
  //   （正常情况下重建一次就落到目标，不会再触发）。
  int _seekRebuildRetries = 0;
  static const int _kMaxSeekRebuildRetries = 8;

  /// 🔴 2026-10-26（第二十一轮）：**「快进回退兜底重建」**的独立额度。
  ///
  /// 【与 [_seekRebuildRetries] 的区别】
  ///   · [_seekRebuildRetries]：落点前重建 —— 目标在裁剪列表里不存在，
  ///     可能反复触发 ⇒ **跨重建累积**，8 次封顶。
  ///   · [_seekFallbackRetries]：原生 seek 被 AVPlayer 放弃（I 帧稀疏 ⇒
  ///     播放头倒退重解）后的兜底重建 —— 重建到新落点**必然可达**
  ///     （重建全程不 seek）⇒ 额度宽松（50 次），且**重建成功后复位**。
  ///
  /// 【为什么必须分开】共用 8 次额度 ⇒ 用户连续快进 8 次后额度耗尽
  ///   ⇒ 第 9 次起快进**彻底没反应**（比不修还糟）。
  int _seekFallbackRetries = 0;
  static const int _kMaxSeekFallbackRetries = 50;
  final PlayerSwitchGate _switchGate = PlayerSwitchGate();
  late int _currentEpisodeIndex;
  bool _controlsVisible = true;
  bool _controlsLocked = false;
  bool _lockIndicatorVisible = false;
  Timer? _lockIndicatorTimer;
  bool _playing = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _initialized = false;
  String? _error;
  bool _switchingSource = false;
  late PlayerBackendType _currentPlayerBackend;
  BoxFit _videoFit = BoxFit.contain;
  double _playbackSpeed = 1.0;

  EpisodeSkipConfig? _skipConfig;
  bool _skipConfigLoading = false;
  final Set<String> _skippedSegments = {};
  bool _autoNextTriggered = false;

  /// 记录最近一次触发片头片尾跳过 seek 的时间，避免 seek 后位置未立即更新导致重复触发。
  DateTime? _lastSkipSeekAt;

  final List<StreamSubscription> _subscriptions = [];

  /// 全局播放活动会话 id（后台测速据此让路），dispose 时释放。
  int? _playbackSessionId;
  Timer? _controlsTimer;
  Timer? _longPressSeekTimer;
  Timer? _continuousSeekTimer;
  Timer? _clockTimer;
  Timer? _autoSwitchTimer;
  DateTime _currentTime = DateTime.now();

  // 固定快进快退步长
  static const int _seekStep = 20;
  static const int _controlsAutoHideSeconds = 10;
  late int _pendingInitialPositionMs;
  bool _isRecordSaveThrottled = false;
  bool _recordSaveInFlight = false;

  /// 最近一次「用户明确指定」的定位目标（毫秒）。0 表示无。
  ///
  /// 🔴 2026-10-08 新增：换源 / 切后端 / 长按快进的续播基准一律优先用它，
  ///   而不是用 `_position`。
  ///
  /// 【为什么】`_position` 是后端上报值的被动镜像。mpv 在 seek 期间上报的
  ///   `time-pos` 并不可信 —— 它会先吐**上一次播放位置的残留值**再收敛
  ///   （真机 h11：请求 857556ms → 8ms 后报 931596ms，偏后约 1 分钟）。
  ///   若把这个被污染的值当作新会话的续播点，新会话**一开播就落在错误位置**，
  ///   且方向恒为向后 —— 正是用户反馈的「定位完成后又往后跳 1 分钟」。
  ///
  /// 【为什么不能只靠原生守卫】原生守卫（PlayerStream.seekingCount + MpvBridge）
  ///   已经屏蔽了 seek 期间的残留值，但那是「后端内部」的自保；本字段是 Dart 侧
  ///   的**最后一层防线**：凡用户明确指定过的目标，永远优先于任何上报值。
  ///   两层叠加后，即使某次 seek 因极近落点未发 playback-restart，也不会污染续播点。
  ///
  /// 清零时机：`open()` 新会话开始时，**以及真实位置抵达锚点后自动失效**
  ///   （见 [_trustedPositionMs] 的证伪判据，2026-10-08 补）。
  int _lastUserSeekTargetMs = 0;

  /// 🔴 2026-10-08 新增：mpv 上报的**真实播放位置**（毫秒，不含 seek 期乐观置位）。
  ///
  /// 【与 `_position` 的区别】`_position` 在 seek 期间是**请求目标值**
  ///   （原生侧为让进度条停在目标点而乐观置位），因此它回答的是
  ///   「我们请求播到哪里」；本字段回答的是「mpv 实际播到哪里」。
  ///
  /// 【用途】证伪 [_lastUserSeekTargetMs]：只有当真实位置抵达锚点，
  ///   才说明这次定位真的落地了，锚点必须释放。否则会出现
  ///   「请求 1717.156s、实际落 1589.0s，但进度条永远显示 1717.2s」。
  int _realPositionMs = 0;

  /// 🔴 2026-10-08 新增：锚点 [_lastUserSeekTargetMs] 的**设立时刻**。
  ///
  /// 【用途】配合 [_kAnchorMaxLifetime] 做正向超时释放 —— 下界判据
  ///   （真实位置追平锚点）在「落点小于请求值」时永不满足，必须另有兜底。
  ///   仅靠下界容差无法覆盖落后型落空，两者量级必须匹配（见工作日志教训 80）。
  ///
  /// 【清零时机】与 [_lastUserSeekTargetMs] 严格同组：open 新会话、
  ///   锚点释放、以及本字段自身驱动的超时释放。
  DateTime? _lastUserSeekTargetAt;

  /// 锚点释放容差（毫秒）：真实位置到达「锚点 − 本值」即可判定定位已落地。
  ///
  /// 取 1500ms 的理由：定位落点通常不会精确等于请求值（关键帧对齐、
  /// 分片边界、mpv 自身 seek 精度），留一段容差避免锚点永不释放。
  /// 同时该值远小于「用户可感知的进度偏差」（分钟级），
  /// 不足以让残留的锚点继续污染进度显示。
  static const int _kAnchorReleaseSlackMs = 1500;

  /// 🔴 2026-10-08 新增：锚点生命期上限 —— 超过此时长无条件释放。
  ///
  /// 【为什么必须有】[_kAnchorReleaseSlackMs] 是**下界**判据（真实位置 ≥ 锚点 −
  ///   1.5s）。当 mpv 实际落点**小于**请求值时（往回拖 / HLS 分片量化偏前），
  ///   该判据永远不满足，锚点永不过期，`_trustedPositionMs` 退化成恒取较大值。
  ///
  /// 【取值依据】真机实测 seek 落定最晚约 15.5s（mpv 的 playback-restart 在
  ///   open 内建 seek 场景下 12.7~15.5s 才到），用户拖动那次是 3.469s。
  ///   取 15 秒覆盖「用户拖动」全部情形（3.469s 有 4 倍余量）。
  ///   ⚠️ 注意：ArkTS 的 seek 看门狗仍保持 3 秒**未放宽** —— 放宽它会让
  ///   mpv 真不发事件的 open 场景多挂数秒屏蔽期，反而加重「进度条卡住」。
  ///   二者是独立兜底，不要联动修改。
  static const Duration _kAnchorMaxLifetime = Duration(seconds: 15);

  /// 首次观测到「有效播放位置」的时刻（位置 > [_kSkipValidPositionThresholdMs]）。
  ///
  /// 🔴 2026-09-28 新增：用于抑制起播阶段的位置回跳误触发跳过片头/片尾。
  /// 起播瞬间 AVPlayer / fvp 会把 position 先报告成 0，若此时续播点本应在后半段，
  /// 0 会落进片头区间并触发跳过，把正确的续播位置覆盖成片头结束点。
  /// 详见 [_checkSkipSegments] 顶部说明。
  DateTime? _firstValidPositionAt;

  /// 判定「位置有效」的下限：超过 1 秒才认为播放器真的开始出帧了。
  /// 取 1 秒是因为起播瞬间常见的 0 / 负值 / 亚秒抖动都不应算作有效位置。
  static const int _kSkipValidPositionThresholdMs = 1000;

  /// 见到首个有效位置后，再等待这段时间才允许触发跳过。
  /// 留出窗口让位置流从「回跳值」收敛到真实续播点。
  static const Duration _kSkipStabilizeWindow = Duration(seconds: 3);

  /// 本次起播「用户要求到达的续播点」（毫秒），0 表示从头播。
  ///
  /// 🔴 2026-09-28 新增（真机日志定位到根因）：
  ///
  /// 【现象】AVPlayer 起播后「直接从头播放，无法继续播放」。
  /// 【日志铁证】hilog 2026-09-28 17:32:21~24（AVPlayer 后端）：
  ///   17:32:21.435  首帧 position=1064442ms   ← 定位已成功（setPlaybackRange 生效）
  ///   17:32:23.638  position=521ms            ← AVPlayer 位置流回跳到片头
  ///   17:32:24.037  触发跳过片段: type=opening start=0.0 end=105.279
  ///   17:32:24.041  [FVP-DIAG] seek target=105579ms before=925ms
  /// 即：正确的续播点 1064442ms 被「跳过片头」逻辑覆盖成了 105579ms。
  ///
  /// 【为什么会误判】[_checkSkipSegments] 唯一的判据是「位置落在片头区间内」。
  /// 它无法区分该位置是「用户要的续播点」还是「起播抖动」。
  /// 此前靠 [_firstValidPositionAt] 的 3 秒稳定窗口兜底，但窗口只从
  /// 「首次见到有效位置」起算，本例中 21.435 起算、24.435 到期，
  /// 而跳过在 24.037 触发 —— 差 0.4 秒，保护失效。
  ///
  /// 【正确判据】跳过片头/片尾是「用户没指定续播点时才做的补救」。
  /// 一旦本次起播有明确的续播点，且该续播点本身就落在区间之外，
  /// 那么任何「落在片头区间的位置」都只可能是抖动，**一律不得触发跳过**。
  /// 故这里保留续播点作为基线，供 [_checkSkipSegments] 判定。
  ///
  /// 注意与 [_pendingInitialPositionMs] 的区别：后者在 fvp/AVPlayer 起播成功后
  /// 会被清零（见 _openEpisode 中「fvp / avplayer 必须跳过二次 seek」那段），
  /// 清零后就不再能作判据，故必须另设本字段独立保存。
  int _resumeAnchorMs = 0;

  /// 🔴 2026-09-28：续播「定位闸门」——续播起播时，在位置真正抵达续播点之前
  /// **不显示视频层**，从根本上消除「闪开头」。
  ///
  /// 【为什么上面那些修复不够】此前做过两处尝试但都无效：
  ///   ① ArkTS 层把 sendInitialized() 延后到 SEEK_DONE —— 只对 avp 生效，
  ///      且无法阻止 texture 在 initialize() 后已开始产出画面；
  ///   ② Dart 层 _waitForPlayerReady 增加位置校验 —— 判据用的是 UI 侧 `_position`，
  ///      它由 positionStream **异步回调**更新，open() 返回时它往往仍是旧值，
  ///      于是校验失败走「宽限放行」，照样提前露出。
  ///
  /// 【真正的原因】视频层一旦挂载，Flutter 就会把 texture 当前内容画到屏幕上。
  /// avp 的 open() 内部虽然会阻塞到 seek 落地，但 initialize() 一完成 decode 就开始
  /// 按片头出帧，而 `_initialized = true` 在 open() 返回后立即设置 —— 观众先看到
  /// 片头画面，随后解码器跳到续播点，画面突变，即「闪开头」。
  ///
  /// 【闸门做法】续播场景下先让视频层保持隐藏（显示加载指示），
  /// 直到 [_position] 首次进入续播点邻域（±5s）再显示。设超时兜底，
  /// 避免个别源定位永不落地时黑屏。
  bool _locateGateOpen = true;

  /// 闸门开始等待的时刻；null 表示未在等待。
  DateTime? _locateGateSince;

  /// 闸门最长等待：超过则强制开闸（宁可闪一下也不能一直黑屏）。
  ///
  /// 🔴 2026-09-28 实测校准：原设 3s **太短**。真机时序（AVPlayer 续播到 1521s）：
  ///   20:31:41.834  下发缓冲档位
  ///   20:31:49.248  PREPARED      ← 准备耗时 7.4s
  ///   20:31:52.311  SEEK_DONE     ← seek 又耗 3.1s
  ///   20:31:55.708  首帧送显      ← 再等 3.4s
  /// 从 `_initialized` 置真到纹理真正出帧要 3.4s，**超过原来的 3s**，
  /// 于是闸门在帧到达前就超时打开 —— 这正是「闸门加了却仍然闪开头」的原因。
  /// 现放宽到 15s，对实测最坏情况（13.9s）留出余量。
  static const Duration _locateGateTimeout = Duration(seconds: 15);

  /// 闸门超时兜底定时器。位置流迟迟不来时（如定位失败卡住），
  /// 靠它把闸门打开，避免一直黑屏。
  Timer? _locateGateTimer;

  /// 🔴 2026-10-08【方案 C】闸门判据②的「独立观测」计数。
  ///
  /// 【为什么需要】判据②（位置进入续播点 ±5s）原先直接读 [_position] 的值，
  ///   但该值可能**不是播放器真实落点**，而是被「定位中」语义注入的请求值：
  ///   mpv 路径修复后，seek 期间原生侧上报的就是请求值本身
  ///   （对齐 AVP 的 `if (isSeeking) return seekPosition`）。
  ///   于是「位置已抵达续播点」会在 seek 下发的那一刻**瞬间为真** ——
  ///   闸门立刻打开，起播窗口内又露出片头/黑屏，等于闸门失效。
  ///
  ///   真机证据（h11）：open start=856s 后 **11ms** 就打印
  ///   `续播定位闸门开启: 首帧已出 position=0ms`，而真实落点要到 10s 后才出现。
  ///
  /// 【判据】要求连续 [_kLocateGateStableSamples] 次位置采样都落在续播点邻域，
  ///   单单一次（尤其是刚下发 seek 后的第一次）不算数 —— 真实落点稳定后
  ///   位置会持续停留/递增在该邻域，而注入值只会在最初出现一次，
  ///   随后被原生侧的真实采样覆盖掉。
  int _locateGateStableSamples = 0;

  /// 判据②所需的连续稳定采样次数。取 3 次即可区分「真实落点」与「注入目标值」，
  /// 又不会明显推迟开闸（位置流默认 1s 一次，即最多多等 2s，
  /// 远小于首帧本身的到达时间）。
  static const int _kLocateGateStableSamples = 3;

  // 触摸手势状态
  bool _gestureIndicatorVisible = false;
  String _gestureIndicatorText = '';
  IconData _gestureIndicatorIcon = Icons.touch_app;
  Timer? _gestureIndicatorTimer;
  bool _isLongPressSeeking = false;
  String _longPressDirection = 'right';
  /// 长按持续快退/快进时的目标位置（本地累加，保证画面实时平滑）。
  Duration _continuousSeekTarget = Duration.zero;
  double _currentBrightness = 0.5;
  double _currentVolume = 0.5;
  double _gestureStartBrightness = 0.5;
  double _gestureStartVolume = 0.5;
  Offset? _gestureStartPosition;
  double _cumulativeDeltaY = 0.0;
  double _cumulativeDeltaX = 0.0;
  static const double _verticalGestureSensitivity = 0.005;
  static const double _horizontalGestureSensitivity = 0.5;

  /// 记录进入播放页前设备/系统的方向，退出时恢复。
  Orientation? _originalOrientation;

  /// 是否正在退出播放页，防止重复触发退出流程。
  bool _isExiting = false;

  /// 最近一次切换集数/源的时间，用于跳过片头片尾时避免初始化阶段位置抖动。
  DateTime? _episodeSwitchAt;

  List<SourceOption> get _sources =>
      widget.sourcesNotifier?.value ?? widget.sources ?? [];
  bool get _canSwitchSource => _sources.isNotEmpty;

  /// 根据物理尺寸记录进入播放页时的设备方向。
  /// 默认视频缩放模式始终使用 contain，保持视频原始比例，
  /// 由手机屏幕比例与视频比例自然决定是否出现黑边，避免拉伸或裁剪。
  void _captureOriginalOrientation() {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;
    final size = view.physicalSize / view.devicePixelRatio;
    _originalOrientation = size.width < size.height
        ? Orientation.portrait
        : Orientation.landscape;
    _videoFit = BoxFit.contain;
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _captureOriginalOrientation();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _currentVideoDetail = widget.videoDetail;
    _currentEpisodeIndex = widget.episodeIndex;
    _currentSourceIndex = widget.initialSourceIndex.clamp(
      0,
      _sources.isEmpty ? 0 : _sources.length - 1,
    );
    _initialSourceKey = _sources.isNotEmpty && _currentSourceIndex < _sources.length
        ? '${_sources[_currentSourceIndex].source}+${_sources[_currentSourceIndex].id}'
        : '${_currentVideoDetail.source}+${_currentVideoDetail.id}';
    _currentPlayerBackend = widget.playerBackend;
    _pendingInitialPositionMs = widget.initialPositionMs;
    widget.sourcesNotifier?.addListener(_onSourcesChanged);
    _loadSkipConfig();
    // 申请播放会话：后台测速据此给播放缓冲让路
    _playbackSessionId = PlaybackActivity.instance.openSession();
    // 🔴 2026-10-23：上报当前播放的源，供测速跳过该源（只识别分辨率）。
    _syncPlaybackSourceKey();
    // 播放页一打开就可能在拉流（open→initialize→play），
    // 起播加载阶段同样需要带宽，先行标记为取流中。
    PlaybackActivity.instance.reportPlaying(_playbackSessionId ?? -1, true);
    _initBackend();
    _initWakelock();
    _initBrightnessAndVolume();
    _startClock();
  }

  Future<void> _initWakelock() async {
    try {
      await ScreenWakeOhos.enable();
      debugPrint('MobilePlayerScreen: 已启用屏幕常亮');
    } catch (e) {
      debugPrint('MobilePlayerScreen: 启用屏幕常亮失败: $e');
    }
  }

  void _startClock() {
    _currentTime = DateTime.now();
    _clockTimer = Timer.periodic(Duration(minutes: 1), (_) {
      if (mounted) {
        setState(() => _currentTime = DateTime.now());
      }
    });
  }

  String _formatClock(DateTime time) {
    final h = time.hour.toString().padLeft(2, '0');
    final m = time.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> _initBrightnessAndVolume() async {
    try {
      _currentBrightness = await ScreenBrightness().application;
      debugPrint('MobilePlayerScreen: 当前亮度 $_currentBrightness');
    } catch (e) {
      debugPrint('MobilePlayerScreen: 获取亮度失败: $e');
      _currentBrightness = 0.5;
    }
    _gestureStartBrightness = _currentBrightness;

    // 🔴🔴 2026-10-09 重定方案：音量语义改为【播放器音量】，起点固定 1.0。
    //
    // 【为什么不再读系统音量】旧实现读系统媒体音量作为手势起点（`VolumeOhos.get`），
    //   但写入侧已确证三方应用**无法**改系统音量（详见 `_onVerticalDragUpdate`
    //   内的完整说明）。若仍读系统值做起點，会出现「起点 0.89 → 下滑到 0.3」
    //   但实际只改了播放器音量、系统音量纹丝不动 —— 起点与终点的语义不一致，
    //   且下次进入又是 0.89，用户感觉「调了不记住」。
    //
    //   现统一为「播放器音量」这一个语义：起点 1.0（满音量，等价于 mpv/AVPlayer
    //   的默认值），手势只改播放器音量，行为自洽可预期。
    //
    //   `VolumeOhos` 的**读取**能力仍然可用（`getVolume`/`getVolumeByStream` 是
    //   公开 API，无 @systemapi），若日后要做「系统音量上限提示」再启用。
    //
    // 🔴 2026-10-11 补充：此处**不再**立即下发。
    //   真机日志（21:11:30.871）实测到 `MpvBackend setVolume 跳过：view 尚未创建
    //   或已销毁` —— `_loadPlaybackSettings` 在 `_replaceBackend` 之前执行，
    //   此刻 `_viewId` 仍为 null，调用被 `_invoke` 守卫吞掉。
    //   虽然没有副作用（mpv 默认音量本就是 100），但会留下一句误导性的日志，
    //   且一旦将来默认值不是 1.0 就会静默不生效。故改为**只记值、不下发**，
    //   真正的首次下发交给后端就绪后的 [_onBackendReady] 统一做。
    _currentVolume = 1.0;
    debugPrint('MobilePlayerScreen: 播放音量初始 $_currentVolume（待后端就绪后下发）');
    _gestureStartVolume = _currentVolume;
  }

  Future<void> _loadSkipConfig() async {
    final source = _currentVideoDetail.source;
    final id = _currentVideoDetail.id;
    if (source.isEmpty || id.isEmpty) return;

    setState(() => _skipConfigLoading = true);
    final response = await LunaTVService.getSkipConfigs(
      source: source,
      id: id,
      title: _currentVideoDetail.title,
      year: _currentVideoDetail.year,
      doubanId: _currentVideoDetail.doubanId,
      forceRefresh: true,
    );
    if (mounted) {
      setState(() {
        _skipConfigLoading = false;
        if (response.success && response.data != null) {
          _skipConfig = response.data;
          debugPrint(
            '跳过配置加载成功: source=$source id=$id segments=${_skipConfig!.segments.length}',
          );
          // 配置加载后立即检查当前位置是否处于片头片尾区间，
          // 避免网络较慢时初始化阶段已经错过了 _openEpisode 的 startAt。
          _checkSkipSegments(_position);
        } else {
          debugPrint(
            '跳过配置加载失败或为空: source=$source id=$id error=${response.message}',
          );
        }
      });
    }
  }

  Future<void> _saveSkipConfig(List<SkipSegment> segments) async {
    final source = _currentVideoDetail.source;
    final id = _currentVideoDetail.id;
    if (source.isEmpty || id.isEmpty) return;

    final response = await LunaTVService.setSkipConfigs(
      source: source,
      id: id,
      title: _currentVideoDetail.title,
      year: _currentVideoDetail.year,
      doubanId: _currentVideoDetail.doubanId,
      segments: segments,
    );
    if (mounted && response.success && response.data != null) {
      setState(() {
        _skipConfig = response.data;
        _skippedSegments.clear();
        _lastSkipSeekAt = null;
        _autoNextTriggered = false;
      });
    }
  }

  void _onDurationUpdate(Duration duration) {
    if (!mounted) return;
    setState(() => _duration = duration);
    // 如果因超时导致界面显示了播放失败提示，但实际视频已初始化成功，
    // 则取消待执行的自动换源并清除错误。
    final pendingAutoSwitch =
        _error == '播放失败，即将进行自动换源' ||
        _error == '播放失败，请手动更换播放源' ||
        _error == '播放失败，请尝试切换播放源';
    // 注意：这里**不能**加 `!_initialized` 守卫 —— 超时分支会先把 `_initialized` 置 true，
    // 加了守卫等于把本「清错误」逻辑自己关掉，于是出现「视频已经在播放、却仍显示播放失败」
    // （open 实际耗时 > openTimeout，但随后仍成功起播）。改用时长阈值 >1s 规避插件对
    // 直播/异常流的瞬时假时长（如 1ms）；真 VOD 时长是分钟级，不会误判。
    if (duration.inMilliseconds > 1000 && pendingAutoSwitch) {
      _autoSwitchTimer?.cancel();
      _autoSwitchTimer = null;
      setState(() {
        _error = null;
        _initialized = true;
      });
    }
  }

  /// fvp 续播卡死且 App 层 seek 重试/回退片头均 no-op（reader 真死）时由后端上抛。
  /// 在 microtask 中执行，避免在 fvp 自身 position 监听器回调内 dispose 旧后端。
  /// 原地重建 fvp 后端（仍从续播点）而非切 ExoPlayer：重建等于再给 libmdk 一次
  /// 「prepare(position:) 从续播点打开」的机会，绕开读取器死寂竞态。有次数上限防循环。
  void _onFvpStallUnrecoverable() {
    if (_switchingBackend) return;
    if (_currentPlayerBackend == PlayerBackendType.exo) return;
    if (_fvpStallRetries >= _kMaxFvpStallRetries) {
      // 已重建多次仍卡死，放弃自动恢复（维持 fvp，避免无限循环）。
      debugPrint(
        '[BACKEND-REOPEN] 续播卡死已重建 $_kMaxFvpStallRetries 次仍失败，放弃自动恢复',
      );
      return;
    }
    _fvpStallRetries++;
    _switchingBackend = true;
    Future.microtask(() => _reopenFvpOnStall());
  }

  /// 🔴🔴🔴 2026-10-24（第十六轮）：**seek 目标落在裁剪落点之前 ⇒ 请求重建**。
  ///
  /// 【场景】裁剪模式下代理返回的列表第 0 片 = 落点片 ⇒ 落点之前不可 seek。
  ///   后端检测到后上抛本回调（携带目标用户轴毫秒）。
  ///
  /// 【处置】与「卡死自愈」同一套重建机制，但**落点取用户的目标位置**：
  ///   释放旧后端 → 新建后端 → `tryOpen(url, initialPositionMs: 目标)`
  ///   ⇒ 代理按新落点重新裁剪列表 ⇒ AVPlayer 从目标位置直接起播（实测 2.4s）。
  ///
  /// 【真机实证】hilog 2026-10-24 22:13:24：userTarget=1053991ms <
  ///   trimOffset=1132520ms ⇒ 硬 seek 只会跳到落点并触发 5400103 ⇒ 界面冻住。
  void _onSeekRebuildRequested(int targetMs) {
    if (_switchingBackend) return;
    if (_currentPlayerBackend == PlayerBackendType.exo) return;
    // 🔴🔴🔴 2026-10-26（第二十一轮）：**区分两种重建请求，用两套独立额度**。
    //
    // 【为什么必须分开 —— 额度语义不同】
    //   · 落点前（targetMs < 当前裁剪落点）：目标在裁剪列表里**不存在**，
    //     重建后若用户再往更早处 seek 还会再触发 ⇒ 存在死循环风险
    //     ⇒ 必须**跨重建累积**额度（[_seekRebuildRetries]，8 次）。
    //   · 回退兜底（targetMs >= 当前裁剪落点）：原生 seek **已经落地**，
    //     只是被 AVPlayer 放弃（该源 I 帧稀疏 ⇒ 退回 I 帧重解）。
    //     重建到新落点是**必然可达**的（重建全程不 seek ⇒ 不会回退）
    //     ⇒ 不需要死循环保护 ⇒ 走**独立**的大额度，且**重建成功后复位**。
    //
    // 【真机依据】hilog 2026-10-26 13:03:39-13:03:43：用户快进 +83.4 秒 ⇒
    //   AVPlayer 把播放头倒退 38.9 秒（position 83570 → 4670）⇒ 触发回退兜底。
    //   若与「落点前」共用 8 次额度 ⇒ 用户连续快进 8 次后额度耗尽
    //   ⇒ 第 9 次起快进**不再有任何反应**（比不修还糟）。
    final trimOffset = LocalM3u8Proxy.currentInstance?.trimOffsetMs ?? 0;
    final isFallback = trimOffset > 0 && targetMs >= trimOffset;
    if (isFallback) {
      if (_seekFallbackRetries >= _kMaxSeekFallbackRetries) {
        debugPrint(
          '[SEEK-FALLBACK] 兜底重建已达 $_kMaxSeekFallbackRetries 次，放弃'
          '（目标=${targetMs}ms）',
        );
        return;
      }
      _seekFallbackRetries++;
      _switchingBackend = true;
      debugPrint(
        '[SEEK-FALLBACK] 原生 seek 被 AVPlayer 放弃（回退重解）⇒ 兜底重建播放器'
        '到目标=${targetMs}ms（第 $_seekFallbackRetries/$_kMaxSeekFallbackRetries 次）',
      );
      Future.microtask(() => _reopenFvpOnStall(targetMs: targetMs));
      return;
    }
    // ⚠️ 用**独立**额度（_seekRebuildRetries）：seek 重建是正常操作，
    //   不能消耗「播放器已死」的故障额度。
    if (_seekRebuildRetries >= _kMaxSeekRebuildRetries) {
      debugPrint(
        '[SEEK-REBUILD] 已重建 $_kMaxSeekRebuildRetries 次仍失败，放弃自动恢复'
        '（目标=${targetMs}ms）',
      );
      return;
    }
    _seekRebuildRetries++;
    _switchingBackend = true;
    debugPrint(
      '[SEEK-REBUILD] 目标=${targetMs}ms 落在裁剪落点之前 ⇒ 重建播放器到该位置'
      '（第 $_seekRebuildRetries/$_kMaxSeekRebuildRetries 次）',
    );
    Future.microtask(() => _reopenFvpOnStall(targetMs: targetMs));
  }

  /// fvp 救不活时：释放当前 fvp 后端，原地重建 fvp 后端，并从冻结的续播点继续播放
  /// （不再从片头重启，避免「读取播放记录后自动重新开始」）。保持 fvp 后端，不切 ExoPlayer。
  /// 重建经由 prepare(position:) 原生定位续播点，绕开读取器死寂竞态。
  Future<void> _reopenFvpOnStall({int? targetMs}) async {
    if (!mounted) {
      _switchingBackend = false;
      return;
    }
    // 🔴🔴🔴 2026-10-24（第十六轮）：落点优先取**用户的目标位置**。
    //
    // 【为什么不能只用当前播放位置】播放器已经死了 ⇒ position 冻结在旧值
    //   （真机：5400103 后 position 恒 0ms）⇒ 用它当落点会跳到错误位置，
    //   用户「快进到 2 分 22 秒」却看到播放器从别处重新起播。
    //   [_lastUserSeekTargetMs] 记录的是**用户意图**（每次用户 seek 都更新）⇒ 正确。
    //
    // 【三级回退】显式 targetMs（seek 重建请求）→ 用户最近 seek 目标 → 当前播放位置。
    final resumeMs =
        targetMs ??
        (_lastUserSeekTargetMs > 0 ? _lastUserSeekTargetMs : _position.inMilliseconds);
    debugPrint(
      '[BACKEND-REOPEN] 续播卡死，原地重建后端（续播点=$resumeMs ms，'
      '${targetMs != null ? "seek重建第 $_seekRebuildRetries/$_kMaxSeekRebuildRetries 次" : "卡死重建第 $_fvpStallRetries/$_kMaxFvpStallRetries 次"}，'
      '来源=${targetMs != null ? "seek重建请求" : (_lastUserSeekTargetMs > 0 ? "用户seek目标" : "当前播放位置")}）',
    );

    // 注销旧 fvp 后端监听器并释放
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    await _backend?.dispose();
    _backend = null;
    _eagerVideoLayer = null;

    // 保持 fvp 后端（不切 ExoPlayer），从续播点恢复，不丢进度。
    _pendingInitialPositionMs = resumeMs;

    // 🔴🔴🔴 2026-10-24（第十六轮）：**显式把代理的裁剪起点改到新落点**。
    //
    // 【为什么必须显式】代理的 `_updateTrimTarget()` 只在**首次**设定裁剪起点，
    //   一经设定就不再自动重算（否则普通 seek 也会把裁剪轴挪走、position 全错）。
    //   而重建后 AVPlayer 会重新拉 playlist，若代理仍按**旧落点**裁剪
    //   ⇒ 重建出来的播放器还是从旧位置起播 ⇒ 用户看到「跳转没生效」。
    //
    // 【真机反证】hilog 2026-10-24 22:13:24：用户退到 1053991ms（落点 1132520ms
    //   之前）⇒ 硬 seek 只跳到落点并 5400103 死掉。重建若不改裁剪起点，
    //   重建后仍会回到 1132520ms 附近 ⇒ 症状不变。
    if (resumeMs > 0) {
      LocalM3u8Proxy.currentInstance?.setTrimStartAtMs(resumeMs);
    }

    final backend = PlayerBackendFactory.create(_currentPlayerBackend);
    _backend = backend;
    // 后端已更换：丢弃旧的常驻视频层，否则会复用上一个后端的 PlatformView。
    _eagerVideoLayer = null;
    _backend?.fit = _videoFit;
    backend.onUnrecoverableStall = _onFvpStallUnrecoverable;
    // 🔴 2026-10-24（第十六轮）：seek 目标落在裁剪落点之前 ⇒ 请求重建。
    backend.onSeekRebuildRequested = _onSeekRebuildRequested;
    _bindTextureReady(backend);
    _subscriptions
      ..add(
        backend.positionStream.listen((position) {
          _reportBufferHealth(position);
          if (mounted) {
            setState(() => _position = position);
            _checkSkipSegments(position);
            _savePlayRecordThrottled();
          }
        }),
      )
      ..add(backend.durationStream.listen(_onDurationUpdate))
      ..add(
        backend.bufferedStream.listen((buffered) {
          if (mounted) setState(() => _buffered = buffered);
        }),
      )
      ..add(
        backend.playingStream.listen((playing) {
          PlaybackActivity.instance.reportPlaying(_playbackSessionId ?? -1, playing);
          if (mounted) setState(() => _playing = playing);
        }),
      )
      ..add(
        backend.completedStream.listen((_) {
          if (mounted &&
              !_autoNextTriggered &&
              _currentEpisodeIndex < _currentVideoDetail.episodes.length - 1) {
            _autoNextTriggered = true;
            debugPrint('播放器报告播放完成，触发下一集');
            _nextEpisode();
          }
        }),
      )
      // 🔴 首帧信号：纹理真正出帧，是「画面可以显示」最硬的判据。
      //    续播闸门靠它放行，避免在只有解码器空帧时就露出视频层（闪开头）。
      ..add(
        backend.firstFrameStream.listen((_) {
          _evalLocateGate(_position.inMilliseconds, firstFrame: true);
          // 🔴 2026-10-24（第十六轮）：**重建真正成功**（新会话出了首帧）
          //   ⇒ 复位「播放器已死」的故障额度。
          //
          // 【为什么在首帧这里复位，而不是 open 之后】
          //   open() 不抛异常 ≠ 播放正常（AVPlayer 可以在 open 后立刻 5400103）。
          //   首帧才是「真的能播」的硬证据。
          // 【为什么不复位 _seekRebuildRetries】
          //   它防的是「重建到某目标仍不可达」的死循环，必须跨重建累积。
          _fvpStallRetries = 0;
          // 🔴 2026-10-26（第二十一轮）：**兜底重建额度在此复位**。
          //   重建出了首帧 ⇒ 新会话正常 ⇒ 之前的「快进回退」已解决；
          //   而落点前重建的额度 [_seekRebuildRetries] 仍**不**复位
          //   （它防的是「目标仍不可达」的死循环，必须跨重建累积）。
          _seekFallbackRetries = 0;
        }),
      );

    setState(() {
      _error = null;
      _initialized = false;
    });

    await _openEpisodeImpl(_currentEpisodeIndex, isStallRecovery: true);
    if (mounted) {
      _switchingBackend = false;
      _showControls();
    }
  }

  /// [autoOpen] 为 true 时，建好后端后立即起播当前集（首播路径）。
  ///
  /// 🔴 2026-10-23：新增该开关。切集路径需要「只重建后端、不自动起播」，
  ///   否则会与 [_openEpisodeImpl] 形成递归（建后端 → 起播 → 释放后端 →
  ///   重建后端 → …）。
  Future<void> _initBackend({bool autoOpen = true}) async {
    final backend = PlayerBackendFactory.create(_currentPlayerBackend);
    _backend = backend;
    // 后端已更换：丢弃旧的常驻视频层，否则会复用上一个后端的 PlatformView。
    //
    // 🔴 2026-10-07 换源修复：光置 null 还不够 —— 旧 PlatformView 刚被
    //   _switchSourceImpl 中的 _backend?.dispose() 原生销毁，而此时若沿用同一代数
    //   （ValueKey 相同），Flutter 会认为「还是原来那个 widget」而复用其
    //   PlatformView 元素，原生不会重新走 MpvViewFactory.create()，
    //   于是永远没有新 Player / 新 viewId，Dart 侧 open() 只能等超时。
    //   换源后必须让锚点换代（递增代数），强制销毁旧 PlatformView 并创建新的。
    _regenerateEagerVideoLayer();
    _backend?.fit = _videoFit;
    // 🔴 2026-09-30：立即触发一次重建。requiresEagerMount 的后端（mpv）要在
    //    open() 之前就把 PlatformView 挂进 widget 树，而 _backend 是普通字段、
    //    赋值本身不会触发 build。缺这一次 setState，后续 open() 内部的
    //    endOfFrame 等到的仍是「_backend 为 null」的那一帧 → 依然拿不到 view。
    if (mounted) {
      setState(() {});
    }
    backend.onUnrecoverableStall = _onFvpStallUnrecoverable;
    // 🔴 2026-10-24（第十六轮）：seek 目标落在裁剪落点之前 ⇒ 请求重建。
    backend.onSeekRebuildRequested = _onSeekRebuildRequested;
    // 🔴 2026-09-30 路线 B：纹理就绪后重建 _buildVideo，让 Texture(textureId) 出画。
    _bindTextureReady(backend);
    _subscriptions
      ..add(
        backend.positionStream.listen((position) {
          _reportBufferHealth(position);
          if (mounted) {
            setState(() => _position = position);
            _checkSkipSegments(position);
            _savePlayRecordThrottled();
          }
        }),
      )
      ..add(backend.durationStream.listen(_onDurationUpdate))
      ..add(
        backend.bufferedStream.listen((buffered) {
          if (mounted) setState(() => _buffered = buffered);
        }),
      )
      ..add(
        backend.playingStream.listen((playing) {
          PlaybackActivity.instance.reportPlaying(_playbackSessionId ?? -1, playing);
          if (mounted) setState(() => _playing = playing);
        }),
      )
      ..add(
        backend.completedStream.listen((_) {
          // 播放器原生完成事件作为兜底，防止 position 流未精确到片尾时漏切。
          if (mounted &&
              !_autoNextTriggered &&
              _currentEpisodeIndex < _currentVideoDetail.episodes.length - 1) {
            _autoNextTriggered = true;
            debugPrint('播放器报告播放完成，触发下一集');
            _nextEpisode();
          }
        }),
      )
      // 🔴 首帧信号：纹理真正出帧，是「画面可以显示」最硬的判据。
      //    续播闸门靠它放行，避免在只有解码器空帧时就露出视频层（闪开头）。
      ..add(
        backend.firstFrameStream.listen((_) {
          _evalLocateGate(_position.inMilliseconds, firstFrame: true);
        }),
      );

    // 🔴 2026-10-23：首播必须带 isFirstOpen —— 后端刚由本方法建好，
    //   若 _openEpisodeImpl 走「切集释放」分支会把它置空，
    //   于是 `_backend?.open(...)` 被 ?. 短路，open() 根本不执行，
    //   表现为「尝试播放」后直接 15s 超时、屏幕上无任何画面。
    if (autoOpen) {
      await _openEpisodeImpl(_currentEpisodeIndex, isFirstOpen: true);
    }
  }

  /// 🔴 2026-09-30 路线 B：mpv 后端纹理就绪后通知播放页重建视频层。
  /// 原生 registerTexture 拿到 textureId 并经事件通道首条消息回传，
  /// 此时才应让 _buildVideo 切到 Texture(textureId) 出画。
  void _bindTextureReady(VideoPlayerBackend backend) {
    if (backend is MpvBackend) {
      _subscriptions.add(backend.textureReadyStream.listen((_) {
        if (mounted) {
          setState(() {});
        }
      }));
      // 🔴 2026-10-07：硬解黑屏自动回退软解。
      //
      // 【为什么需要它】鸿蒙 mpv 硬解（ohcodec[nv12]）对部分源会「解码成功、
      //   VO 出画成功，但帧进不了 Flutter 纹理」——Flutter 侧取帧恒失败
      //   （ret=40601000），画面全黑；而同一源用软解（yuv420p）正常播放。
      //   mpv 自身的 hwdec-software-fallback 只在 avcodec_send_packet 报解码错误
      //   时计数（vd_lavc.c:1162 handle_err），这种「出画了但纹理取不到」的情况
      //   计数器恒为 0，回退永不触发 —— 所以必须由原生看门狗 + 这里重建会话。
      //
      // 【行为】原生在硬解 open 后 8 秒内进度仍为 0 时上报一次；这里重建当前集，
      //   并让下一次 open 强制软解。回退只做一次（_hwdecFallbackUsed），避免死循环。
      _subscriptions.add(backend.hwdecNoFrameStream.listen((_) {
        _handleHwdecNoFrame();
      }));
      // 🔴 2026-10-08 新增：订阅 mpv 真实位置，用于**证伪续播/快进锚点**。
      //
      // 【为什么不能用 positionStream】后者在 seek 期间上报的是**请求目标值**
      //   （原生乐观置位），拿它去证伪锚点等于用锚点证明锚点，永远成立。
      //   只有 realPositionStream 是 mpv 播放时钟的原话。
      //
      // 【为什么必须证伪】真机实证：seek 请求 1717.156s、mpv 实际落在 1589.0s
      //   （差 128 秒）。若锚点永不过期，`_trustedPositionMs` 会永久返回
      //   1717156ms → 进度条显示 1717.2s，而实际只播到 1589.0s。
      _subscriptions.add(backend.realPositionStream.listen((real) {
        final ms = real.inMilliseconds;
        if (ms <= 0) return;
        _realPositionMs = ms;
        // 锚点已落地 → 立即释放，让进度显示回到 mpv 真实时钟。
        // 🔴 2026-10-08：顺带刷新一次 UI。锚点释放会改变 [_trustedPositionMs]
        //   的返回值（从「钉死的请求值」回到真实时钟），若等下一次
        //   positionStream 回调才重建，进度条会短暂停在错误值上。
        bool released = false;
        if (_lastUserSeekTargetMs > 0 &&
            ms >= _lastUserSeekTargetMs - _kAnchorReleaseSlackMs) {
          _logAnchorRelease(
            '真实位置追平（差 ${_lastUserSeekTargetMs - ms}ms）',
          );
          _lastUserSeekTargetMs = 0;
          _lastUserSeekTargetAt = null;
          released = true;
        }
        if (released && mounted) setState(() {});
      }));
    }
  }

  /// 🔴 2026-10-07：硬解黑屏 → 自动回退软解（每次播放会话最多一次）。
  ///
  /// 真机复测（22:44:52 那次）暴露的致命时序，勿再删掉这里的等待期：
  ///   open(hwdec=ohcodec) → 探针误判 → 立即在此处重建 → 新 open 与**旧 open
  ///   尚未完成的本地代理分片请求**撞在同一个 URL 上 → mpv 54ms 内报
  ///   「hls: Error when loading first segment」→ 整集播放失败，且因
  ///   _hwdecFallbackUsed 已置位，不会再有第二次机会 → 用户观感就是
  ///   「换源后必须退出重进」。
  ///
  /// 所以重建前必须：① 先停掉旧会话，让代理侧那次 IO 结束；② 留一小段
  /// 冷静期，避免新旧两次 open 抢同一个分片 URL。
  /// 这段等待只在**真的需要回退**时付出一次（~600ms），代价远低于整集失败。
  Future<void> _handleHwdecNoFrame() async {
    if (!mounted) return;
    final backend = _backend;
    if (backend is! MpvBackend) return;
    if (_hwdecFallbackUsed) {
      debugPrint('硬解回退：本会话已回退过，不再重试（避免死循环）');
      return;
    }
    _hwdecFallbackUsed = true;
    _hwdecFallbackEpisodeIndex = _currentEpisodeIndex;
    debugPrint('硬解回退：命中无帧上报，先停旧会话再重建当前集并改用软解');
    // ① 先暂停旧会话，让它在本地代理上的分片 IO 尽快收尾。
    //    （MpvBackend 没有 stop()，pause() 是这里能用的最小中断动作；
    //      紧接着会用 hwdec=no 重新 open，旧会话随即被新 open 取代。）
    try {
      await backend.pause();
    } catch (e) {
      debugPrint('硬解回退：暂停旧会话失败（忽略）: $e');
    }
    // ② 冷静期：给代理侧未完成的分片 IO 一点时间收尾。
    //    太快重开会撞上同一个分片 URL，正是本次「换源后必须重进」的成因。
    if (!mounted) return;
    await Future<void>.delayed(const Duration(milliseconds: 600));
    if (!mounted) return;
    backend.forceSoftwareDecodingForNextOpen();
    // 🔴 2026-10-23：必须带 isStallRecovery —— 本路径的语义是
    //   「复用同一后端实例重新 open 当前集」（软解标记刚打在 backend 实例上，
    //   释放后重建会让标记丢失，回退形同虚设）。
    //   安卓版没有这套 mpv 硬解回退逻辑，所以安卓不需要这个豁免；
    //   昨晚「全平台统一释放收尾链」套到鸿蒙时没为它留口子。
    await _openEpisodeImpl(_currentEpisodeIndex, isStallRecovery: true);
    // ③ 兜底复检：若重建后仍没能出画，再给一次机会。
    //
    //    为什么必须有这一步：上面 ①② 只是**降低**撞车概率，并不能消除 ——
    //    代理侧那次分片 IO 何时收尾由网络决定，我们无从同步。
    //    一旦仍撞上，mpv 会立刻报首分片失败，而 _hwdecFallbackUsed 已置位，
    //    旧逻辑就再也没有第二次机会，直接表现为「必须退出重进」。
    //    这里在重建后开一个宽限窗口，仍未出画则再开一次（此时旧 IO 肯定结束了）。
    //    仅重试一次，且仅在本会话尚未出过画时执行，不会造成循环。
    if (!mounted) return;
    await _verifyPlaybackAfterFallback();
  }

  /// 硬解回退重建后的复检：宽限窗口内仍未出画则再重开一次。
  ///
  /// 判据用「进度是否前进」而不是「有没有报错」——
  /// 因为首分片撞车时 mpv 不一定往上报错，只是安静地停在 0。
  /// 再加 `_initialized` 作为辅助判据（后端若连初始化都没完成，同样算失败）。
  Future<void> _verifyPlaybackAfterFallback() async {
    const grace = Duration(milliseconds: 2500);
    await Future<void>.delayed(grace);
    if (!mounted) return;
    if (_position.inMilliseconds > 0) {
      debugPrint('硬解回退复检：进度已前进（${_position.inMilliseconds}ms），无需再次重开');
      return;
    }
    if (_sourceRetryAfterFallbackUsed) {
      debugPrint('硬解回退复检：兜底重开已用过，不再重试');
      return;
    }
    _sourceRetryAfterFallbackUsed = true;
    debugPrint('硬解回退复检：仍未出画，判定为重建时撞上未完成的代理请求，再重开一次');
    // 🔴 2026-10-23：必须带 isStallRecovery —— 本次是「同一后端实例上再 open 一次」，
    //   释放重建会让 _handleHwdecNoFrame 设的软解标记（forceSoftwareDecodingForNextOpen）
    //   随旧实例一起丢失，回退彻底失效。
    await _openEpisodeImpl(_currentEpisodeIndex, isStallRecovery: true);
  }

  void _safeSeekToSeconds(double targetSeconds) {
    if (_backend == null || _duration.inMilliseconds <= 0) return;
    final currentMs = _position.inMilliseconds;
    var targetMs = (targetSeconds * 1000).toInt();
    // 避免跳到片尾导致播放器卡死，最多跳到总时长前 500ms
    final maxMs = _duration.inMilliseconds - 500;
    if (targetMs > maxMs) targetMs = maxMs;
    if (targetMs < 0) targetMs = 0;
    // 目标与当前位置太近时不执行 seek，减少抖动
    if ((targetMs - currentMs).abs() < 500) return;
    _seekFromUser(Duration(milliseconds: targetMs));
  }

  void _checkSkipSegments(Duration position) {
    // 刚切换集数/源的前 2 秒内不处理跳过/自动下一集，避免初始化阶段位置抖动导致误触发。
    final switchAt = _episodeSwitchAt;
    if (switchAt != null &&
        DateTime.now().difference(switchAt) < Duration(seconds: 2)) {
      return;
    }

    // 🔴 2026-09-28 修正：起播稳定前的位置「回跳」不得触发跳过。
    //
    // 【原来的 bug】AVPlayer / fvp 在起播阶段会先把 position 报告成 0（尚未出帧），
    // 随后才跳到真实续播点。若此刻续播点本应落在后半段，位置流却先送来一个 0，
    // 而 0 必然落在片头区间 [0, 105.279] 内 → 立即触发 `_safeSeekToSeconds(105.279+0.3)`
    // = seek 到 105579ms，把本来正确的续播位置**覆盖掉**。
    //
    // 【真机日志证据】hilog 2026-09-28 13:29:35-36（同一次 AVPlayer 会话内，
    // 期间没有任何新的 open/起播）：
    //   13:29:35.322  进度 position=718520ms      ← 续播点正确
    //   13:29:36.521  进度 position=105579ms      ← 被跳过逻辑改写成片头结束点
    //   13:29:36.324  [FVP-DIAG] seek target=105579ms before=0ms after=105579ms
    // （105.279 + 0.3 秒余量 = 105.579s，与日志数值逐位吻合，可确认是该 seek。）
    //
    // 【判据】只有「起播已稳定」后才允许跳过。稳定 = 收到过距 0 足够远的位置。
    // 用 [_resumeStabilizedAt] 记录首次观测到有效位置(>1s)的时刻，
    // 其后 [_kSkipStabilizeWindow] 内一律不触发跳过，等位置流稳定下来。
    final observedMs = position.inMilliseconds;

    // 🔴 续播定位闸门评估：这是位置流的汇聚点，用它判断是否已抵达续播点。
    //    必须放在最前面 —— 闸门开启状态会影响视频层是否挂载。
    _evalLocateGate(observedMs);

    if (observedMs > _kSkipValidPositionThresholdMs) {
      _firstValidPositionAt ??= DateTime.now();
    }

    // ── 续播锚点保护（🔴 2026-09-28 主修）★ ──
    //
    // 起播时若已指定续播点，则在位置流真正逼近该点之前，**一律不触发跳过**。
    //
    // 【为什么必须有这条】跳过片头/片尾本质是「用户没指定续播点时的补救」。
    // 一旦有明确续播点，任何落在片头区间的位置都只可能是起播抖动，
    // 此时触发跳过必然把正确位置覆盖掉 —— 这正是用户报的
    // 「avp 直接从头开始播放，无法继续播放」。
    //
    // 【真机日志】17:32:21 首帧已是 1064442ms（定位正确），
    // 17:32:23 位置流回跳报 521ms，17:32:24 即被跳过逻辑 seek 到 105579ms。
    // 单靠下面的 3 秒稳定窗口拦不住（起算晚、到期晚，例中差 0.4 秒），
    // 故改用「续播点」这一确定性判据。
    //
    // 【放行条件】位置已推进到锚点附近或越过锚点（容许 5 秒误差，兼顾
    // 关键帧对齐与起播抖动）；此时说明定位真的收敛了，跳过逻辑恢复正常工作
    // （例如用户手动把进度拖回片头区间内，仍应正常跳过）。
    if (_resumeAnchorMs > 0) {
      final reachedAnchor = observedMs >= _resumeAnchorMs - 5000;
      if (!reachedAnchor) {
        return;
      }
    }

    final validAt = _firstValidPositionAt;
    if (validAt == null ||
        DateTime.now().difference(validAt) < _kSkipStabilizeWindow) {
      // 尚未见到有效位置，或刚见到不久 —— 位置仍可能回跳，跳过一律不触发。
      return;
    }

    final seconds = position.inMilliseconds / 1000.0;
    final totalSeconds = _duration.inMilliseconds / 1000.0;
    if (totalSeconds <= 0) return;

    // 跳过 seek 冷却：触发一次跳过后 3 秒内不再重复触发，避免 seek 后画面未更新
    // 导致位置流仍报告在片头片尾区间内而连续 seek。
    final skipSeekCooldown = _lastSkipSeekAt != null &&
        DateTime.now().difference(_lastSkipSeekAt!) < Duration(seconds: 3);

    if (_skipConfig != null && _skipConfig!.segments.isNotEmpty) {
      for (final segment in _skipConfig!.segments) {
        final key = '${segment.type}_${segment.start}_${segment.end}';
        if (!segment.autoSkip) continue;

        // 过滤时长异常/超出总时长的无效 segment
        if (segment.end - segment.start < 1.0) continue;
        if (segment.type == 'opening' && segment.end >= totalSeconds - 1.0) {
          continue;
        }
        if (segment.type == 'ending' && segment.start <= 1.0) continue;

        final inSegment = seconds >= segment.start && seconds <= segment.end;
        final passedSegment = seconds > segment.end + 0.5;

        if (inSegment) {
          if (skipSeekCooldown) {
            // 冷却期内仅打印一次日志，避免刷屏
            if (!_skippedSegments.contains(key)) {
              debugPrint(
                '跳过片段冷却中: type=${segment.type} start=${segment.start} end=${segment.end}',
              );
              _skippedSegments.add(key);
            }
            continue;
          }
          // 仅在首次触发时打印日志，但允许重复 seek 直到真正离开片段。
          if (!_skippedSegments.contains(key)) {
            debugPrint(
              '触发跳过片段: type=${segment.type} start=${segment.start} end=${segment.end}',
            );
          }
          // 跳到片段结束后 0.3 秒处，减少跳转到非关键帧导致画面卡住的概率；
          // 同时仍保留少量缓冲余量，避免解码器停在片尾关键帧上。
          _lastSkipSeekAt = DateTime.now();
          _safeSeekToSeconds(segment.end + 0.3);
          break;
        } else if (passedSegment && !_skippedSegments.contains(key)) {
          // 播放器位置已确实越过片段，才标记为已跳过，避免 seek 失效后不再重试。
          _skippedSegments.add(key);
          debugPrint(
            '跳过片段已生效: type=${segment.type} end=${segment.end} current=$seconds',
          );
        }
      }
    }

    // 总时长过短（如 HLS 直播或解析异常）时不触发片尾下一集
    if (totalSeconds <= 10) return;

    if (!_autoNextTriggered &&
        _skipConfig != null &&
        _skipConfig!.segments.isNotEmpty) {
      for (final segment in _skipConfig!.segments) {
        // 只有片尾类型的 segment 才允许触发自动下一集
        if (segment.type != 'ending' || !segment.autoNextEpisode) continue;
        var remainingTime = segment.remainingTime;
        if (remainingTime == null) {
          remainingTime = totalSeconds - segment.start;
        }
        // 限制 remainingTime 不超过实际剩余时长，且不超过总时长一半，
        // 避免播放器报告错误时长时误触发。
        final actualRemaining = totalSeconds - segment.start;
        if (remainingTime > actualRemaining) remainingTime = actualRemaining;
        // 小于 1 秒视为无效，防止立即触发下一集导致卡死
        if (remainingTime < 1.0) continue;
        // 超过总时长一半视为异常配置，不触发
        if (remainingTime > totalSeconds * 0.5) continue;
        if (totalSeconds - seconds <= remainingTime) {
          _autoNextTriggered = true;
          debugPrint(
            '触发自动下一集: type=${segment.type} remainingTime=$remainingTime',
          );
          _nextEpisode();
          return;
        }
      }
    }

    // 兜底：即使没有片尾跳过配置，播放到最后 3 秒也自动下一集
    const fallbackRemaining = 3.0;
    if (!_autoNextTriggered &&
        _currentEpisodeIndex < _currentVideoDetail.episodes.length - 1 &&
        totalSeconds - seconds <= fallbackRemaining) {
      _autoNextTriggered = true;
      debugPrint('触发片尾自动下一集: position=$seconds total=$totalSeconds');
      _nextEpisode();
    }
  }

  /// 等待播放器「真正就绪」——即既有时长、又已定位到续播点。
  ///
  /// 🔴 2026-09-28 修复「闪开头」：原实现只判 `_duration > 0` 就返回 true，
  ///   而 HLS 的 duration 在 prepared 阶段（早于 seek 落地）就已上报。
  ///   于是调用方拿到 true → `_initialized = true` → `_buildVideo()` 露出视频层，
  ///   而此时播放位置仍在 0 —— 观众先看到片头画面，几十~几百毫秒后 seek 落地，
  ///   画面才跳到续播点，表现为「闪一下开头」。这正是 fvp 与 avp **共同**的
  ///   上层成因（两后端 internal 定位时机不同，但此判据都过早放行）。
  ///
  ///   修复：续播场景下额外要求位置进入续播点邻域。为避免个别源 seek 永不落地
  ///   而把起播卡死，采用「等待 + 宽限放行」：超时后即使位置未到位也返回 true，
  ///   交由既有的运行期 stall 自愈 / 回退逻辑兜底。
  ///
  /// [resumeTargetMs] 为本次续播点；<= 0 表示从片头播，无定位要求，行为与旧版一致。
  Future<bool> _waitForPlayerReady(
    Duration timeout, {
    int resumeTargetMs = 0,
  }) async {
    final start = DateTime.now();
    final needsLocate = resumeTargetMs > 0;

    // 位置是否已进入续播点邻域。容忍 ±5s：HLS 只能定位到分片边界，
    // 且播放器上报的 position 与实际 seek 目标天然存在片长级偏差。
    bool located() {
      if (!needsLocate) return true;
      final pos = _position.inMilliseconds;
      if (pos <= 0) return false;
      return (pos - resumeTargetMs).abs() <= 5000;
    }

    bool ready() => _duration.inMilliseconds > 0 && located();

    if (ready()) return true;

    while (DateTime.now().difference(start) < timeout) {
      if (ready()) return true;
      await Future.delayed(Duration(milliseconds: 100));
    }

    // 宽限期：定位迟迟不落地时不要卡死起播，只要有时长就放行（旧行为兜底）。
    if (_duration.inMilliseconds > 0 && needsLocate && !located()) {
      debugPrint(
        '起播就绪：时长已就绪但位置未到续播点 '
        'position=${_position.inMilliseconds}ms target=${resumeTargetMs}ms'
        ' —— 宽限放行，交由运行期自愈兜底',
      );
      return true;
    }
    return _duration.inMilliseconds > 0;
  }

  Future<void> _openEpisode(int index) {
    return _switchGate.run(() => _openEpisodeImpl(index));
  }

  /// [isFirstOpen] 为 true 表示「首次起播」：后端刚由 [_initBackend] 建好，
  ///   不能走切集的「释放旧后端」分支（否则 _backend 变 null，open 被短路）。
  Future<void> _openEpisodeImpl(
    int index, {
    bool isStallRecovery = false,
    bool isFirstOpen = false,
  }) async {
    // 非卡死重建的正常开播：清零 fvp 续播卡死重建计数，避免上次残留计数误杀本次。
    if (!isStallRecovery) {
      _fvpStallRetries = 0;
      // 🔴 2026-10-24（第十六轮）：正常开播（换集/换源/首播）⇒ seek 重建额度归零。
      //   额度是「本次播放会话内」的防死循环措施，跨会话不该累积。
      _seekRebuildRetries = 0;
      // 🔴 2026-10-26（第二十一轮）：兜底重建额度同样归零（跨会话不该累积）。
      _seekFallbackRetries = 0;
    }
    // 🔴 2026-10-07：硬解回退标记只在「换集」时复位。
    //   同一集内的重建（硬解回退、卡死重建）必须保留标记 —— 否则刚回退到软解，
    //   这次重建又清掉标记，一旦再次触发上报就会无限回退。
    if (index != _hwdecFallbackEpisodeIndex) {
      _hwdecFallbackEpisodeIndex = index;
      _hwdecFallbackUsed = false;
      // 换集 = 全新的一次播放尝试，兜底重开的额度一并重置。
      _sourceRetryAfterFallbackUsed = false;
    }
    final episodes = _currentVideoDetail.episodes;
    if (index < 0 || index >= episodes.length) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

    // 🔴 切集：先停止播放、保存播放记录、释放旧后端，再加载新集。
    //    卡死原地重建（isStallRecovery）复用同一后端实例，不走这里。
    //    首播（isFirstOpen）时后端刚建好，同样不能走释放分支。
    if (!isStallRecovery && !isFirstOpen) {
      await _stopSaveAndReleaseBackend();
      debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');
      // 🔴 2026-10-23 修复：切集必须清零上一集的续播位置。
      //   播放记录是「每部剧一条」（含 index=集号、playTime=该集秒数），
      //   上一集的位置套到新集上会直接落在错误的时间点（用户实测：记录错乱）。
      //   换源/换播放器保留位置是合理的（同集同内容），但换集必须归零。
      _pendingInitialPositionMs = 0;
      debugPrint('[HeinPlay] 切换集：目标 index=$index，续播位置已归零（避免沿用上一集）');
      // 🔴 2026-10-23 修复：释放后必须重建后端。
      //    _stopSaveAndReleaseBackend 会把 _backend 置 null，而下面 tryOpen 用的是
      //    `_backend?.open(...)` —— _backend 为 null 时 Dart 的 ?. 直接短路，
      //    open() 根本不会被调用（连「MpvBackend open」日志都没有），
      //    tryOpen 只能轮询 _duration 到超时 → 每次切集白等 15 秒后判失败。
      //    autoOpen:false = 只重建后端，不在此递归触发起播。
      await _initBackend(autoOpen: false);
    }

    setState(() {
      _initialized = false;
      _error = null;
      _skippedSegments.clear();
      _lastSkipSeekAt = null;
      _autoNextTriggered = false;
    });

    // 记录切换时间，用于跳过逻辑冷却。
    _episodeSwitchAt = DateTime.now();

    // 🔴 2026-09-28：重置「有效位置」观测点，让新的起播重新走一遍稳定窗口。
    // 不重置的话，上一次播放已建立的 _firstValidPositionAt 会让新起播立刻
    // 通过稳定窗口校验，起播瞬间回跳的 0 又会误触发跳过片头。
    _firstValidPositionAt = null;

    // 🔴 2026-09-28：续播锚点同样清零。新会话尚未确定续播点，此处若沿用上一次的
    // 锚点，会把「本次无续播点（应从片头播）」误判为「有锚点且远未到达」，
    // 导致片头跳过被永久抑制。真正的锚点在下方 tryOpen 之前重新写入。
    _resumeAnchorMs = 0;

    // 先加载跳过配置，确保打开播放器前已知片头片尾区间，
    // 避免异步加载完成前错过 startAt 定位时机。
    await _loadSkipConfig();

    final timeoutSeconds = await UserDataService.getAutoSwitchSourceTimeout();
    final openTimeout = Duration(seconds: timeoutSeconds);

    Future<bool> tryOpen(String url, {int initialPositionMs = 0}) async {
      // 🔴 2026-10-24（avp 起播修复）：**起播预算与「自动切换源超时」解耦**。
      //
      // 【问题 1 — 等待预算被扣光后直接判失败】
      //   原实现：`remaining = openTimeout - elapsed`，`remaining <= 0` 时直接
      //   用 `_duration > 0` 判成败 —— 而此时播放器**还没就绪**，duration 自然为 0
      //   ⇒ 必然判失败。真机 hilog 2026-10-24 20:34:27.695 就是这样误报的，
      //   而真正的就绪在 20:34:28.678（**只差 0.98 秒**）。
      //   ⇒ 用户的「播放失败 → 无法读取播放记录 → 直接从头播放」由此而来。
      //
      // 【问题 2 — avp 的 open() 语义是「等到就绪」，15s 对它是常态误报】
      //   mpv 的 open() 发起即返回；avp 的 open() 要等 initialize（含首帧尺寸）
      //   才返回。起播慢时 open() 超过 15s 就抛 TimeoutException
      //   （真机 hilog 20:34:52.051 / 20:35:45.058 各一次）⇒ 同样判失败。
      //
      // 【为什么给 avp 单独放宽】
      //   代理侧落点段排队曾造成 42.6 秒黑洞（本轮已在 LocalM3u8Proxy 修掉），
      //   优化后 avp 冷起播实测 ~2~5 秒；但 AVPlayer 探测 + 设备抖动仍可能到十几秒。
      //   用户明确反馈「宁可等，也不要失败」⇒ avp 给 30s 上限（防挂死），
      //   mpv 与换源逻辑沿用用户设置值不变。
      final bool isAvp = _currentPlayerBackend == PlayerBackendType.avplayer;
      final Duration openBudget = isAvp
          ? const Duration(seconds: 30)
          : openTimeout;
      // 「播放器就绪」等待预算：至少 20s，绝不因 open() 耗时而被清零。
      final Duration readyBudget = openTimeout > const Duration(seconds: 20)
          ? openTimeout
          : const Duration(seconds: 20);

      try {
        debugPrint('MobilePlayerScreen 尝试播放 [$_currentPlayerBackend]: $url');
        await _backend
            ?.open(
              url,
              proxyMode: _currentVideoDetail.proxyMode,
              startAt: initialPositionMs > 0
                  ? Duration(milliseconds: initialPositionMs)
                  : null,
            )
            .timeout(openBudget);

        // 等待播放器真正就绪（有时长 **且** 已定位到续播点）。
        // 🔴 传入 initialPositionMs：续播场景下必须确认位置已到续播点再放行，
        //    否则视频层会先露出片头画面（见 _waitForPlayerReady 注释）。
        final ready = await _waitForPlayerReady(
          readyBudget,
          resumeTargetMs: initialPositionMs,
        );
        if (!ready) {
          debugPrint('MobilePlayerScreen 等待播放就绪超时 [$_currentPlayerBackend]');
          return false;
        }

        debugPrint('MobilePlayerScreen 播放初始化成功 [$_currentPlayerBackend]');
        return true;
      } catch (e, stackTrace) {
        debugPrint('MobilePlayerScreen 播放失败 [$_currentPlayerBackend]: $url');
        debugPrint('错误: $e');
        debugPrint('$stackTrace');
        return false;
      }
    }

    final rawUrl = episodes[index];
    var url = rawUrl.trim();
    if (url.isEmpty) {
      setState(() {
        _error = '播放地址为空';
        _initialized = true;
      });
      return;
    }

    // 若已配置自动跳过片头，且待恢复位置落在片头区间内，
    // 则直接从片头结束处开始播放，避免初始化完成后再 seek 失效。
    //
    // 🔴 2026-09-28 修正：**只有「确实要续播」时才能触发片头跳过**。
    //
    // 【原来的 bug】切源 / 切集 / 换后端时，若 _pendingInitialPositionMs 拿到的是
    // 0（新后端初始化期间 _position 被推成 0，取值时机早于首帧），0 必然落在
    // 片头区间 [startMs, endMs] 内 → 被无条件抬到 endMs（片头结束点）。
    // 用户看到的就是「播放记录无法定位，直接从头播放，然后跳过片头」。
    //
    // 【真机日志证据】hilog 2026-09-28 13:29:35-36：
    //   13:29:35.322  进度 position=718520ms        ← 真实播放位置（播放记录）
    //   13:29:36.521  进度 position=105579ms        ← 被抬到片头结束点 105.279s
    //   13:29:36.324  [FVP-DIAG] seek target=105579ms before=0ms after=105579ms
    // 即：续播点本应是 718520ms，却因为中途 _position 归零而被改成了 105279ms。
    //
    // 【判据】0 (Duration.zero) 是「无有效续播点」的哨兵值，不是「用户想从第 0 秒看」。
    // 只有在调用方明确要求从头播时才应传 0，而那种情况本来就无需跳过片头。
    // 故此处要求 > 0 才判定，从根源上杜绝「归零 → 误判落进片头 → 抬到结束点」。
    final openingSegment = _skipConfig?.segments
        .where((s) => s.type == 'opening' && s.autoSkip)
        .firstOrNull;
    if (openingSegment != null && _pendingInitialPositionMs > 0) {
      final startMs = (openingSegment.start * 1000).toInt();
      final endMs = (openingSegment.end * 1000).toInt();
      if (_pendingInitialPositionMs >= startMs &&
          _pendingInitialPositionMs <= endMs) {
        _pendingInitialPositionMs = endMs;
        _skippedSegments.add(
          '${openingSegment.type}_${openingSegment.start}_${openingSegment.end}',
        );
        debugPrint('MobilePlayerScreen 片头起始定位: ${openingSegment.end}s');
      }
    }

    // 🔴 记录本次起播的续播锚点（供 _checkSkipSegments 判定用）。
    // 必须在 tryOpen 之前记录，且此后不再清零 —— 详见 _resumeAnchorMs 字段说明。
    _resumeAnchorMs = _pendingInitialPositionMs;

    // 🔴 续播定位闸门：有续播点时先关闸，等位置真正抵达再显示视频层。
    //    这是消除「闪开头」的关键 —— 无论后端在 initialize() 后多早开始出帧，
    //    只要视频层未挂载，观众就看不到定位前的片头画面。
    if (_resumeAnchorMs > 0) {
      _locateGateOpen = false;
      _locateGateSince = DateTime.now();
      // 复位稳定采样计数：判据②要求「连续 N 次」落在续播点邻域，
      // 上一次播放的计数绝不能带到这一次（否则本次第一次采样就可能凑够数）。
      _locateGateStableSamples = 0;
      debugPrint('续播定位闸门关闭，等待定位到 ${_resumeAnchorMs}ms');
      // 超时兜底：位置流可能因定位失败而永不抵达，此时必须开闸，
      // 否则会一直黑屏（比闪一下严重得多）。
      _locateGateTimer?.cancel();
      _locateGateTimer = Timer(_locateGateTimeout, () {
        if (!mounted || _locateGateOpen) return;
        _openLocateGate(
          '超时兜底 position=${_position.inMilliseconds}ms '
          'target=${_resumeAnchorMs}ms',
        );
      });
    } else {
      _locateGateOpen = true;
      _locateGateSince = null;
      _locateGateStableSamples = 0;
      _locateGateTimer?.cancel();
      _locateGateTimer = null;
    }

    // 对 M3U8 地址应用本地去广告过滤。
    // 🔴 2026-10-24：必须把**本次实际使用的后端**传给 filterM3u8。
    //   门控原先只读全局设置（getPlayerBackend），而播放页可能用的是
    //   「按视频/按源」的后端（UserDataService.getPlayerBackendForVideo）⇒
    //   两者不一致时，avplayer 会被错开 PTS 归一化，收到整体前移 25 秒的字节，
    //   AVFoundation 逐分片对齐失败 ⇒ 死锁 34 秒（真机 hilog 08:21 实锤）。
    final filteredUrl = await AdFilterEngine.filterM3u8(
      sourceType: _currentVideoDetail.source,
      originalUrl: url,
      playerBackend: _currentPlayerBackend,
    );
    if (filteredUrl != null && filteredUrl.isNotEmpty) {
      url = filteredUrl;
    } else {
      // 🔴 2026-10-08：过滤失败不再静默。此处是「用户看到广告没被跳过」的
      //   唯一分叉点 —— 必须留下可归因的日志，否则排查只能靠猜
      //   （此前 h12 里只有 AdFilterEngine 内部的失败，看不出最终走了哪条路）。
      debugPrint(
        '[去广告] 代理不可用，直连原始 URL（广告不会过滤）: $url '
        '[后端=${_currentPlayerBackend.name}]',
      );
    }

    bool success = await tryOpen(
      url,
      initialPositionMs: _pendingInitialPositionMs,
    );

    // 🔴 2026-10-08：新会话已开始，复位「用户定位锚点」。
    //   语义：_lastUserSeekTargetMs 描述的是**上一个会话**里用户的意图，
    //   新会话已按 _pendingInitialPositionMs 定位，旧的锚点不再适用 ——
    //   若不清零，换集后 _trustedPositionMs 会返回上一集的进度，
    //   换源/切后端时把新集拽回旧集位置。
    _lastUserSeekTargetMs = 0;
    // 🔴 2026-10-08 补齐：真实位置镜像也必须同组复位。
    //
    //   【为什么】_realPositionMs 是**页面级字段**，而 MpvBackend.dispose()
    //   只关闭流、不会（也不该）清页面字段。换集/换源时若不清零，
    //   新会话收到第一条 realPositionStream 之前，它仍是**上一集**的播放位置。
    //   若该值恰好 ≥ 新锚点 - 1500ms，_trustedPositionMs 会在新会话首个位置
    //   上报到来前就判定「锚点已落地」并清除 → 新会话的续播定位保底失效。
    //   与 _lastUserSeekTargetMs 成组管理，避免今后再漏。
    _realPositionMs = 0;
    // 🔴 2026-10-08：锚点时刻与锚点值必须同组复位，否则新会话的锚点
    //   会带着上一会话的时间戳，被 [_kAnchorMaxLifetime] 立刻判为超时。
    _lastUserSeekTargetAt = null;

    if (!mounted) return;

    // 如果超时判定失败，但当前源实际已就绪（ duration 有效），修正为成功，
    // 避免初始化较慢的源已经开始播放却仍显示“播放失败”。
    if (!success &&
        _backend != null &&
        _duration.inMilliseconds > 0 &&
        _error == null) {
      debugPrint('MobilePlayerScreen 当前源已就绪，修正超时判定为成功');
      success = true;
    }

    final autoSwitchSource = await UserDataService.getAutoSwitchSource();

    if (success) {
      _autoSwitchTimer?.cancel();
      _autoSwitchTimer = null;
      setState(() {
        _currentEpisodeIndex = index;
        _initialized = true;
        _error = null;
      });
      // 恢复上次播放位置，并限制在新视频总时长范围内。
      // 这里也作为 startAt 的二次确认，稍作延迟确保播放器已真正就绪。
      //
      // ⚠️ fvp 后端必须跳过这段：fvp 的起点定位已由 VideoPlayerBackendImpl 在
      // initialize() 完成后**立即**执行（2026-09-22 起不再延后 —— 即「播放记录
      // 第一时间读取」）。
      // 若此处赶在 open 后约 200ms 抢先 seek，会在 libmdk 尚未稳定时把它打进冻结：
      // 2026-09-20 17:20 日志实证第 1 次会话「起播稳定」读到的 position 已是续播点
      // 125000ms（即本段先动了手），随后冻结；而换源后未走本段的两次会话
      // （起播稳定时 position=1520ms）全部一次定位成功。
      //
      // ⚠️ 2026-09-28：AVPlayer 后端同样必须跳过。原因与 fvp 一致 ——
      // VideoPlayerBackendImpl 已在 initialize() 后立即定位，此处再 seek 一次是
      // 重复动作；实测「从 fvp 切换到 avplayer」时会因此再闪一下开头
      // （open 成功 → 已定位到续播点 → 本段 200ms 后二次 seek 造成画面回跳）。
      // 只有 ExoPlayer（安卓/TV/Linux）保留这段，因其 seek 可靠且与上述定位不冲突。
      if (_currentPlayerBackend == PlayerBackendType.fvp ||
          _currentPlayerBackend == PlayerBackendType.avplayer ||
          _currentPlayerBackend == PlayerBackendType.mpv) {
        // mpv 在 open() 内已把 startAt 经 MediaOptions.start 透传，加载时即定位，
        // 此处再 200ms 后追一次会造成回跳，故同样跳过。
        _pendingInitialPositionMs = 0;
      } else if (_pendingInitialPositionMs > 0) {
        final maxMs = _duration.inMilliseconds > 500
            ? _duration.inMilliseconds - 500
            : _duration.inMilliseconds;
        final clampedMs = _pendingInitialPositionMs.clamp(0, maxMs);
        await Future.delayed(Duration(milliseconds: 200));
        if (mounted) {
          _seekFromUser(Duration(milliseconds: clampedMs));
        }
        _pendingInitialPositionMs = 0;
      }
      _showControls();
    } else if (autoSwitchSource && _sources.length > 1) {
      // 自动换源开启且有其他源时，按设置时间延迟后尝试下一个源。
      setState(() {
        _error = '播放失败，即将进行自动换源';
        _initialized = true;
      });
      _autoSwitchTimer = Timer(Duration(seconds: timeoutSeconds), () async {
        if (!mounted) return;
        bool? _switchedResult;
        await _switchGate.run(() async {
          _switchedResult = await _tryAutoSwitchSource(
            index,
            timeoutSeconds: timeoutSeconds,
          );
        });
        final switched = _switchedResult ?? false;
        if (mounted && !switched) {
          setState(() {
            _error = '播放失败，请手动更换播放源';
            _initialized = true;
          });
        }
      });
    } else {
      setState(() {
        _error = '播放失败，请手动更换播放源';
        _initialized = true;
      });
    }
  }

  /// 当前源播放失败时，按详情页已有的测速排序依次尝试其他源。
  /// 全屏播放期间不再重新测速，仅做播放可用性切换。
  Future<bool> _tryAutoSwitchSource(
    int targetEpisodeIndex, {
    required int timeoutSeconds,
  }) async {
    if (_sources.length <= 1) return false;

    // 🔴 2026-09-28 修复「部分源自动换源后从头播放」：
    //
    // 原实现只取 `_position`（当前播放位置）作为换源后的起播点。但当**首个源
    // 一开始就打开失败**时（例如 VID_DEC_ERR / 404 / 无首帧），播放器从未上报过
    // 有效位置，`_position` 仍是 0（或 -1），于是下面 `startAt` 传 null，
    // 新源从 0 开始播——观众看到的就是「从头播放」。日志实证：
    //   起播定位已预置(create 阶段): 1050000ms   ← 首源续播点正确
    //   initialize 失败: VID_DEC_ERR-unsupport interface
    //   起播定位已预置(create 阶段): 0ms          ← 换源后续播点丢失
    //   首帧尺寸就绪 position=207ms               ← 从头播
    //
    // 修复：优先采用 `_pendingInitialPositionMs`（本次会话的续播点，尚未被消费），
    // 其次才用 `_position`（用户在本次播放中已推进到的位置）。二者取较大者，
    // 保证既不会丢掉记录点，也不会在用户已看到更靠后内容时倒退。
    _logTrustedPosition('换源续播基准');
    final playedMs = _trustedPositionMs > 0 ? _trustedPositionMs : 0;
    final pendingMs = _pendingInitialPositionMs > 0 ? _pendingInitialPositionMs : 0;
    final previousPositionMs = playedMs > pendingMs ? playedMs : pendingMs;
    debugPrint(
      '自动换源起播点: played=${playedMs}ms pending=${pendingMs}ms '
      '=> 采用 ${previousPositionMs}ms',
    );

    // 直接使用详情页测速后的源顺序（速度快的排在前面）
    for (var i = 0; i < _sources.length; i++) {
      if (i == _currentSourceIndex) continue;
      if (!mounted) break;

      setState(() {
        _switchingSource = true;
        _error = null;
      });

      final option = _sources[i];
      final response = await LunaTVService.getDetail(
        source: option.source,
        id: option.id,
        title: option.title,
      );

      if (!mounted) {
        setState(() => _switchingSource = false);
        break;
      }

      if (!response.success || response.data == null) {
        setState(() => _switchingSource = false);
        continue;
      }

      final newEpisodes = response.data!.episodes;
      if (targetEpisodeIndex >= newEpisodes.length) {
        setState(() => _switchingSource = false);
        continue;
      }

      await _backend?.dispose();
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();

      setState(() {
        _currentVideoDetail = response.data!;
        _currentSourceIndex = i;
        _currentEpisodeIndex = targetEpisodeIndex;
        _switchingSource = false;
        _skipConfig = null;
        _skippedSegments.clear();
        _lastSkipSeekAt = null;
        _autoNextTriggered = false;
        _initialized = false;
        _error = null;
      });
      _syncPlaybackSourceKey();

      _loadSkipConfig();

      final backend = PlayerBackendFactory.create(_currentPlayerBackend);
      _backend = backend;
      // 后端已更换：丢弃旧的常驻视频层，否则会复用上一个后端的 PlatformView。
      _eagerVideoLayer = null;
      _backend?.fit = _videoFit;
      _bindTextureReady(backend);
      backend.onUnrecoverableStall = _onFvpStallUnrecoverable;
      // 🔴 2026-10-24（第十六轮）：seek 目标落在裁剪落点之前 ⇒ 请求重建。
      backend.onSeekRebuildRequested = _onSeekRebuildRequested;
      _subscriptions
        ..add(
          backend.positionStream.listen((position) {
            _reportBufferHealth(position);
            if (mounted) {
              setState(() => _position = position);
              _checkSkipSegments(position);
            }
          }),
        )
        ..add(backend.durationStream.listen(_onDurationUpdate))
        ..add(
          backend.bufferedStream.listen((buffered) {
            if (mounted) setState(() => _buffered = buffered);
          }),
        )
        ..add(
          backend.playingStream.listen((playing) {
            PlaybackActivity.instance.reportPlaying(_playbackSessionId ?? -1, playing);
            if (mounted) setState(() => _playing = playing);
          }),
        );

      var url = newEpisodes[targetEpisodeIndex].trim();
      // 🔴 2026-10-24：同上，必须传本次实际使用的后端（换源后后端可能已变）。
      final filteredUrl = await AdFilterEngine.filterM3u8(
        sourceType: _currentVideoDetail.source,
        originalUrl: url,
        playerBackend: _currentPlayerBackend,
      );
      if (filteredUrl != null && filteredUrl.isNotEmpty) {
        url = filteredUrl;
      } else {
        // 🔴 2026-10-08：与主路径一致，过滤失败必须留痕（见上处注释）。
        debugPrint(
          '[去广告] 换源时代理不可用，直连原始 URL（广告不会过滤）: $url '
          '[后端=${_currentPlayerBackend.name}]',
        );
      }

      try {
        debugPrint('自动切换源播放: ${option.title} -> $url');
        final startTime = DateTime.now();
        await _backend
            ?.open(
              url,
              proxyMode: _currentVideoDetail.proxyMode,
              startAt: previousPositionMs > 0
                  ? Duration(milliseconds: previousPositionMs)
                  : null,
            )
            .timeout(Duration(seconds: timeoutSeconds));

        final elapsed = DateTime.now().difference(startTime);
        final remaining = Duration(seconds: timeoutSeconds) - elapsed;
        // 🔴 同样要求「位置已到续播点」才放行，否则换源瞬间会闪一下新源的片头。
        final ready = remaining > Duration.zero
            ? await _waitForPlayerReady(
                remaining,
                resumeTargetMs: previousPositionMs,
              )
            : _duration.inMilliseconds > 0;
        if (!ready) {
          debugPrint('自动切换源等待播放就绪超时');
          continue;
        }

        if (mounted) {
          setState(() => _initialized = true);
          _showControls();
          return true;
        }
      } catch (e, stackTrace) {
        debugPrint('自动切换源播放失败: $e');
        debugPrint('$stackTrace');
      }
    }

    return false;
  }

  Future<void> _switchSource(int index) =>
      _switchGate.run(() => _switchSourceImpl(index));

  Future<void> _switchSourceImpl(int index) async {
    if (index < 0 || index >= _sources.length) return;
    if (index == _currentSourceIndex) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

    setState(() => _switchingSource = true);
    final option = _sources[index];
    final response = await LunaTVService.getDetail(
      source: option.source,
      id: option.id,
      title: option.title,
    );

    if (!mounted) return;

    if (!response.success || response.data == null) {
      setState(() {
        _switchingSource = false;
        _error = response.message ?? '切换播放源失败';
      });
      return;
    }

    final previousEpisodeIndex = _currentEpisodeIndex;
    // 🔴 2026-09-28：手动换源同样优先沿用续播点，避免首个源从未产出有效位置
    //   （_position=0）时把记录点丢掉、从片头重播。详见 _tryAutoSwitchSource 注释。
    _logTrustedPosition('换源续播基准');
    final playedMs = _trustedPositionMs > 0 ? _trustedPositionMs : 0;
    final pendingMs = _pendingInitialPositionMs > 0 ? _pendingInitialPositionMs : 0;
    final previousPositionMs = playedMs > pendingMs ? playedMs : pendingMs;

    // 🔴 停止播放 → 保存播放记录 → 释放旧后端（统一链路）。
    //   helper 内部已保证「先退订、再 dispose」的顺序（2026-10-07 换源修复）。
    await _stopSaveAndReleaseBackend();
    debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');

    setState(() {
      _currentVideoDetail = response.data!;
      _currentSourceIndex = index;
      _currentEpisodeIndex = previousEpisodeIndex.clamp(
        0,
        response.data!.episodes.length - 1,
      );
      _switchingSource = false;
      _skipConfig = null;
      _skippedSegments.clear();
      _lastSkipSeekAt = null;
      _autoNextTriggered = false;
    });
    _syncPlaybackSourceKey();

    _loadSkipConfig();
    // 切换源后恢复上次播放位置
    _pendingInitialPositionMs = previousPositionMs;
    // 🔴 2026-10-07：换源是新会话，复位硬解回退标记 —— 新源可能支持硬解，
    //   应重新给它一次机会，而不是因为上个源回退过就一直软解。
    _hwdecFallbackUsed = false;
    _initBackend();
  }

  void _togglePlay() {
    if (_playing) {
      _backend?.pause();
    } else {
      _backend?.play();
    }
    _showControls();
  }

  Duration _clampDuration(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (value > _duration) return _duration;
    return value;
  }

  /// 当前「可信」的播放位置（毫秒）—— 作为换源 / 切后端 / 长按快进的基准。
  ///
  /// 🔴 2026-10-08 新增：保证基准不低于用户明确指定的目标 [_lastUserSeekTargetMs]。
  ///   仅当用户从未 seek 过时才直接用 `_position`。
  ///
  /// 【为什么要保底而不是全盘替换】用户 seek 到 A 之后正常播放到 B（B > A），
  ///   此时基准应是 B。`_position` 在**非 seek 期间**是可信的（原生守卫已屏蔽
  ///   seek 期间的残留值），所以「取二者较大值」既不会把正常前进的进度拉回去，
  ///   又能在 `_position` 因任何原因偏低（残留值/上报滞后）时用用户目标兜底。
  int get _trustedPositionMs {
    final pos = _position.inMilliseconds;
    if (_lastUserSeekTargetMs <= 0) return pos;
    if (pos <= 0) return _lastUserSeekTargetMs;
    // 🔴🔴 2026-10-08 修正：锚点必须能被**真实位置证伪**，不能无条件取较大值。
    //
    //   【原来的 bug】原实现是 `pos > _lastUserSeekTargetMs ? pos : _lastUserSeekTargetMs`
    //     —— 恒取较大值，且锚点**永不过期**。于是：
    //       用户 seek 到 1717.156s → 锚点=1717156
    //       mpv 实际落在 1589.0s（差 128 秒，未跳到目标）
    //       → 基准恒返回 1717156 → 进度条显示 1717.2s
    //     user 观感：「显示时间大于真实进度」。
    //
    //   【为什么会累积放大】基准被快进手势当起点：
    //       `target = _trustedPositionMs + deltaSeconds`
    //     —— 用被污染的基准算新目标 → 再污染锚点 → 越往后偏得越多，
    //     正是用户描述的「偏差值集中、进度越往后越大」。
    //
    //   【修法】引入「锚点已被真实位置覆盖」的失效判据：
    //     一旦 mpv 的真实位置（realPositionStream，不含 seek 期乐观置位）
    //     已经到达或越过锚点附近，说明这次定位**已经落地**，
    //     锚点的使命结束 —— 此后必须以 mpv 的真实时钟为准。
    //     代价是定位刚完成的一瞬间进度条可能回退一点，但这远好于
    //     永久性地把进度条钉在一个从未到达过的位置上。
    if (_realPositionMs > 0 &&
        _realPositionMs >= _lastUserSeekTargetMs - _kAnchorReleaseSlackMs) {
      return pos;
    }
    // 🔴🔴 2026-10-08 三次修正·新增「锚点正向超时释放」—— 防止恒取 max 退化。
    //
    //   【为什么必须有这一条】上面的负向判据（真实位置追平锚点）在一种
    //   情形下**永远不满足**：mpv 的实际落点**小于**请求值时（往回拖、
    //   或 HLS 分片量化导致落点偏前）。真机日志（23:24–23:27）4/4 次 seek
    //   全部「超时未收敛」，`_realPositionMs` 因上游缺陷恒为 0，
    //   于是负向判据恒假 → 锚点**永不过期** → 下面的
    //   `pos > anchor ? pos : anchor` 退化成**恒取较大值** ——
    //   这正是本函数注释开头声称已经修掉的原始 bug。
    //
    //   【判据】给锚点一个生命期上限。超过 [_kAnchorMaxLifetime] 后，
    //   无论真实位置有没有来，都强制释放 —— 因为「用户一次的 seek 意图」
    //   不该在几十秒后还在影响进度显示。mpv 若真没跳过去，进度条应该
    //   如实反映真实位置（这正是用户想要的）。
    //
    //   【取值依据】真机实测 mpv 的 playback-restart 最晚约 15.5s 才到
    //   （open 内建 seek 场景），用户拖动那次是 3.469s。
    //   取 15 秒覆盖「用户拖动」这一类的全部情形（3.469s 有 4 倍余量），
    //   同时不会让锚点长期驻留。
    //   ⚠️ 注意：seek 看门狗仍保持 3 秒超时**未放宽** —— 放宽它会让
    //   mpv 真不发事件的 open 场景多挂 5 秒屏蔽期，反而加重「进度条卡住」。
    //   二者是独立的兜底，不要联动修改。
    if (_lastUserSeekTargetAt != null &&
        DateTime.now().difference(_lastUserSeekTargetAt!) >
            _kAnchorMaxLifetime) {
      _logAnchorRelease('超时释放（${_kAnchorMaxLifetime.inSeconds}s 内未收到真实落点）');
      _lastUserSeekTargetMs = 0;
      _lastUserSeekTargetAt = null;
      return pos;
    }
    // 🔴🔴 2026-10-08 三次修正·**删除上界钳制分支**（它本身成了污染源）。
    //
    //   【上一版为什么错】我曾加过这样一段：
    //     `if (_realPositionMs > pos + 3000) { _lastUserSeekTargetMs = 0;
    //        return _realPositionMs; }`
    //   意图是「真实位置严重超前 _position 时以真实位置为准」。但真机日志
    //   （2026-10-08 23:24–23:27）证实它**制造了新的偏差**，而且正是用户
    //   这次报的「越来越往后」的直接来源：
    //
    //     23:24:59.868  上报 position=1490996ms（用户真实播放位置 1491s）
    //     23:24:59.956  handleMethod seek: 942.061s   ← 🔴 目标值本身就被污染
    //     23:24:59.957  锚点释放: 真实位置=1491076ms 已达锚点=942061ms
    //
    //   942.061 这个「用户 seek 目标」不是用户划出来的 —— 1391s 与 942s
    //   相差 549.015s，而长按快进步长是 `_seekStep ~/ 4 = 5` 秒，
    //   549.015 / 5 = 109.803 **不是整数**。它是**把真实位置（1491s）与
    //   某个被污染的基准混算**得到的产物。
    //
    //   【根因判据】本分支用 `_realPositionMs`（mpv 真实时钟）去覆盖
    //   `_position`，但 `_realPositionMs` 若来自 seek 的**落点快照**而非
    //   持续前进的时钟，它就不是「当前真实位置」而是「上次落点」。
    //   两者语义不同，混用必然出错。
    //
    //   【修法】删掉这个分支。真正的修复在 ArkTS 侧 —— 让
    //   realPositionSec 在 seek 落定后**持续前进**（见 MpvBridge.ets 的
    //   三段式守卫判据）。上游修好后，_realPositionMs 就是可信的当前
    //   位置，不需要在这里做「谁大取谁」的猜测。
    //   在下游做补偿性猜测，只会引入新的、更隐蔽的污染 —— 这正是教训。
    //
    // 未落地（真实位置尚未抵达锚点）→ 仍显示目标点，避免定位期间进度条回跳。
    return pos > _lastUserSeekTargetMs ? pos : _lastUserSeekTargetMs;
  }

  /// 🔴 2026-10-08 诊断：追踪「往后跳 1 分钟」的每一次基准取值。
  ///
  /// 【为什么必须打日志】用户报障「定位好的基础上再往前跳 1 分钟」，前几轮
  ///   我反复凭代码推断（布尔去重 / 代理失败 / 整条误删），**三次全错**。
  ///   根因是 `_position` 的来源链路太长（原生守卫 → 桥接 → 流 → setState），
  ///   任何一环都可能注入偏差值，而日志里看不到中间量。
  ///   此处把「基准是怎么算出来的」直接落盘，用数据代替推断。
  void _logTrustedPosition(String where) {
    final pos = _position.inMilliseconds;
    final trusted = _trustedPositionMs;
    // 只在「基准被锚点抬高了」或「基准为 0」时打印 —— 正常前进时不刷屏。
    if (trusted > pos + 500 || trusted == 0) {
      debugPrint(
        '基准诊断[$where]: _position=${pos}ms, '
        '锚点=$_lastUserSeekTargetMs, 基准=${trusted}ms '
        '${trusted > pos + 500 ? "⚠️ 基准高于实际位置 ${(trusted - pos) / 1000.0}s" : ""}',
      );
    }
  }

  /// 统一的用户定位入口 —— 所有「用户主动 seek」都必须走这里。
  ///
  /// 🔴 2026-10-08 新增：在转发给后端之前，先把目标位置记进
  ///   [_lastUserSeekTargetMs]。这样换源 / 切后端 / 长按快进取续播基准时，
  ///   拿到的是**用户意图**而非被 mpv 残留值污染过的 `_position`。
  ///
  /// 【为什么集中到一个方法】此前有 5 处直接调 `_backend?.seek(...)`
  ///   （跳过片头片尾 / 起播补定位 / 进度条点击 / 长按连续快进 / 快退按钮）。
  ///   分散记录必然会漏，且将来新增调用点也容易忘 —— 收口成一个入口，
  ///   漏记在结构上就不可能发生。
  void _seekFromUser(Duration target) {
    final clamped = _clampDuration(target);
    _lastUserSeekTargetMs = clamped.inMilliseconds;
    // 🔴 2026-10-08 新增：记录锚点设立时刻，供 [_kAnchorMaxLifetime] 正向释放使用。
    _lastUserSeekTargetAt = DateTime.now();
    _backend?.seek(clamped);
    // 🔴 2026-10-08 新增：必须 setState。
    //
    //   【为什么】锚点变了，[_trustedPositionMs] 的返回值也就变了，而它在
    //   build 路径里被调用（进度条、时间标签）。此处若不触发重建，
    //   进度条要等下一次 positionStream 回调（最多数百毫秒，且若播放卡住
    //   则永不发生）才会反映新目标 —— 用户会看到「拖了但进度条没动」。
    if (mounted) setState(() {});
  }

  /// 统一的锚点释放日志 —— 让锚点的完整生命周期在真机 hilog 中可见。
  ///
  /// 【为什么要收口】此前释放逻辑散落在 getter 与订阅回调两处，且
  ///   `_trustedPositionMs` 是**带副作用的 getter** 且在 build 路径被调用 ——
  ///   副作用发生在渲染期间，时机不可控、也容易被 Flutter 的重建策略影响。
  ///   收口到一个方法后，每次释放都有一条可核对的日志，且来源清晰。
  void _logAnchorRelease(String reason) {
    debugPrint(
      '锚点释放[$reason]: 锚点=${_lastUserSeekTargetMs}ms '
      '真实位置=${_realPositionMs}ms _position=${_position.inMilliseconds}ms',
    );
  }

  void _seekToPercent(double percent) {
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * percent).toInt(),
    );
    _seekFromUser(target);
    _showControls();
  }

  void _nextEpisode() {
    if (_currentEpisodeIndex < _currentVideoDetail.episodes.length - 1) {
      _openEpisode(_currentEpisodeIndex + 1);
    }
  }

  void _previousEpisode() {
    if (_currentEpisodeIndex > 0) {
      _openEpisode(_currentEpisodeIndex - 1);
    }
  }

  void _startControlsTimer() {
    _controlsTimer?.cancel();
    _controlsTimer = Timer(
      Duration(seconds: _controlsAutoHideSeconds),
      () {
        debugPrint('控制栏自动隐藏定时器触发');
        _hideControls();
      },
    );
  }

  void _showControls() {
    if (_controlsLocked) return;
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = true);
    _startControlsTimer();
  }

  void _hideControls() {
    debugPrint('隐藏控制栏: _controlsVisible=$_controlsVisible');
    _controlsTimer?.cancel();
    _controlsTimer = null;
    setState(() => _controlsVisible = false);
  }

  void _toggleControls() {
    if (_controlsVisible) {
      debugPrint('切换：隐藏控制栏');
      _hideControls();
    } else {
      debugPrint('切换：显示控制栏');
      _showControls();
    }
  }

  void _showSkipConfigDialog() {
    _showControls();
    _controlsTimer?.cancel();
    showDialog(
      context: context,
      builder: (context) => SkipConfigDialog(
        segments: _skipConfig?.segments ?? [],
        getCurrentPosition: () => _position,
        duration: _duration,
        onSave: _saveSkipConfig,
      ),
    ).then((_) {
      if (mounted) {
        _startControlsTimer();
      }
    });
  }

  void _showSourceSelectorDialog() {
    _showControls();
    _controlsTimer?.cancel();
    showDialog(
      context: context,
      builder: (context) {
        return _SourceSelectorDialog(
          sources: _sources,
          currentIndex: _currentSourceIndex,
          formatSpeed: _formatSpeed,
          speedColor: _speedColor,
          onSelect: (index) {
            Navigator.of(context).pop();
            _switchSource(index);
          },
        );
      },
    ).then((_) {
      if (mounted) {
        _startControlsTimer();
      }
    });
  }

  void _showPlayerBackendSelectorDialog() {
    _showControls();
    _controlsTimer?.cancel();
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: Color(0xFF14141F),
          title: Text(
            '切换播放器',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: Color(0xFFF0F0F5),
            ),
          ),
          content: SizedBox(
            width: 400,
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: PlayerBackendFactory.availableBackends.length,
              itemBuilder: (context, index) {
                final type = PlayerBackendFactory.availableBackends[index];
                final selected = type == _currentPlayerBackend;
                // 复用 _playerBackendLabel，避免标签在两处 switch 里重复维护
                // （新增 avplayer 后端时只需改一处）。
                final String label = _playerBackendLabel(type);
                return ListTile(
                  title: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.primary
                          : Color(0xFFF0F0F5),
                    ),
                  ),
                  trailing: selected
                      ? Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    _switchPlayerBackend(type);
                  },
                );
              },
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) {
        _startControlsTimer();
      }
    });
  }


  /// 🔴🔴 统一「停止播放 → 保存播放记录 → 释放旧后端」收尾链（2026-10-23 全平台统一）。
  ///
  /// 【背景】切换播放器 / 切换播放源 / 切换集 三种操作原先都只把 `_initialized`
  ///   置假，然后直接让旧后端 open() 新地址。平台播放器（ExoPlayer / AVPlayer /
  ///   libmpv / libvlc）在 open() 新源时**不会**自行停止旧的音频与解码线程，
  ///   于是切换瞬间出现「旧源仍在后台出声 + 新源同时起播」的双重解码，
  ///   低端电视/手机上表现为卡顿、音画不同步、内存与 CPU 峰值飙升。
  ///
  /// 【用法】任何要换后端/换源/换集的地方，**必须先 await 本方法**，再走后续
  ///   的 setState + _initBackend / _openEpisodeImpl 流程。
  ///
  /// 【顺序】save → dispose，不可颠倒：
  ///   · dispose 之后 _position/_duration 都停止更新，播放记录就写不准；
  ///   · 且 `_isPlaybackReadyForRecord()` 里 `_backend != null` 的前置条件失效，
  ///     会直接跳过保存，用户进度丢失。
  ///
  /// 【返回】旧后端的最后播放位置（ms），调用方应赋给 `_pendingInitialPositionMs`
  ///   以恢复续播。
  Future<int> _stopSaveAndReleaseBackend() async {
    // 位置基准用 _trustedPositionMs 而非 _position：直接取 _position 会在
    // mpv 换源/切后端时把位置退到 0，导致续播点丢失（2026-10-08 修复）。
    final lastPositionMs = _trustedPositionMs;

    debugPrint('[HeinPlay] 切换操作开始：停止播放 → 保存播放记录 → 释放旧后端');
    // 1) 先落一次播放记录（节流窗口内也强制写，因为这是用户主动切换的明确意图）。
    //    顺序不可颠倒：dispose 之后位置不再更新、_isPlaybackReadyForRecord()
    //    里 `_backend != null` 也失效，会直接跳过保存，用户进度丢失。
    if (!_recordSaveInFlight && _isPlaybackReadyForRecord()) {
      await _savePlayRecordToLunaTV();
    }

    // 2) 停止并释放旧后端。必须先 await dispose 完成再返回，
    //    否则平台播放器（AVPlayer / libmpv）会在后台继续播放。
    //    🔴 必须先退订、再 dispose：dispose() 会关闭全部 StreamController，
    //       若订阅仍挂在已关闭的流上，期间到达的原生事件会触发
    //       「Cannot add new events after calling close」并中断切换流程。
    //    🔴 必须清 _eagerVideoLayer：否则会复用已释放后端的 PlatformView。
    final previousBackend = _backend;
    _backend = null;
    _eagerVideoLayer = null;
    // 🔴 2026-10-23：必须先让视频层（PlatformView）从树上卸载、等一帧，
    //    再释放原生播放器。
    //    切集现在会「释放 → 重建后端」，若旧 PlatformView 还没卸干净就 dispose
    //    原生 player，重建时 surface 回调会打到已释放的 player handle 上
    //    （安卓 fvp 时代实测 SIGSEGV 闪退，鸿蒙 mpv 同样是原生壳，风险等价）。
    if (mounted) {
      setState(() => _initialized = false);
      await WidgetsBinding.instance.endOfFrame;
    }
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    await previousBackend?.dispose();
    return lastPositionMs;
  }

  Future<void> _switchPlayerBackend(PlayerBackendType type) async {
    if (type == _currentPlayerBackend) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

    setState(() => _switchingSource = true);

    await UserDataService.savePlayerBackendForVideo(
      _currentVideoDetail.source,
      _currentVideoDetail.id,
      type,
    );

    // 切换播放器前保存当前进度，初始化完成后恢复。
    //   🔴 2026-10-08：改用 _trustedPositionMs —— 直接取 _position 会把 mpv
    //   残留值/滞后值当成新后端的续播点，导致「切后端后一开播就落错位置」。
    _logTrustedPosition('切后端续播基准');
    // 🔴 停止播放 → 保存播放记录 → 释放旧后端（统一链路）。
    _pendingInitialPositionMs = await _stopSaveAndReleaseBackend();
    debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');

    setState(() {
      _currentPlayerBackend = type;
      _initialized = false;
      _error = null;
    });

    await _initBackend();
    _backend?.fit = _videoFit;

    if (mounted) {
      setState(() => _switchingSource = false);
    }
  }

  void _showEpisodeSelectorDialog() {
    _showControls();
    _controlsTimer?.cancel();
    final titles = _currentVideoDetail.episodesTitles.isNotEmpty
        ? _currentVideoDetail.episodesTitles
        : List.generate(
            _currentVideoDetail.episodes.length,
            (i) => '第${i + 1}集',
          );

    showDialog(
      context: context,
      builder: (context) {
        return _EpisodeSelectorDialog(
          titles: titles,
          currentIndex: _currentEpisodeIndex,
          onSelect: (index) {
            Navigator.of(context).pop();
            _openEpisode(index);
          },
        );
      },
    ).then((_) {
      if (mounted) {
        _startControlsTimer();
      }
    });
  }

  void _stopLongPressSeek() {
    _longPressSeekTimer?.cancel();
    _longPressSeekTimer = null;
    _continuousSeekTimer?.cancel();
    _continuousSeekTimer = null;
  }

  // 播放记录节流保存（15秒内最多保存一次；未真正起播时不落盘，避免覆盖上次进度）
  void _savePlayRecordThrottled() {
    if (_isRecordSaveThrottled) return;
    if (!_isPlaybackReadyForRecord()) return;
    _isRecordSaveThrottled = true;
    _savePlayRecordToLunaTV();
    Timer(const Duration(seconds: 15), () {
      _isRecordSaveThrottled = false;
    });
  }

  /// 仅当播放器已初始化且已取到有效时长时才允许写播放记录：
  /// 视频未就绪（黑屏卡死、duration 仍为 0）时不落盘，
  /// 防止用 playTime=0/totalTime=0 覆盖掉上次正常的续播进度。
  bool _isPlaybackReadyForRecord() {
    if (!(_initialized && _backend != null && _duration.inMilliseconds > 0)) {
      return false;
    }
    // 🔴 2026-10-23：起播定位尚未落地时，位置流恒为 0（mpv 要等 file-loaded
    //    才真正起播，慢源实测可达 12 秒）。此时写盘会用 playTime=0 覆盖掉
    //    切换前刚保存的有效进度 —— 真机（荣耀平板 V8 Pro 2026-10-23）
    //    实测：换源前存了 431s，换源后被覆盖成 0s，
    //    用户侧表现为「换源后读取播放记录失败 / 进度丢失」。
    if (_pendingInitialPositionMs > 0) return false;
    return true;
  }

  // 触摸手势相关方法
  void _showGestureIndicator(String text, IconData icon) {
    setState(() {
      _gestureIndicatorVisible = true;
      _gestureIndicatorText = text;
      _gestureIndicatorIcon = icon;
    });
    _gestureIndicatorTimer?.cancel();
    _gestureIndicatorTimer = Timer(Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _gestureIndicatorVisible = false);
      }
    });
  }

  void _onTapScreen() {
    if (_controlsLocked) {
      if (_lockIndicatorVisible) {
        _hideLockIndicator();
      } else {
        _showLockIndicator();
      }
      return;
    }
    _toggleControls();
  }

  void _toggleControlsLock() {
    setState(() {
      _controlsLocked = !_controlsLocked;
      if (_controlsLocked) {
        // 锁定时立即隐藏控制栏并停止自动隐藏计时，避免控制栏意外弹出。
        _controlsTimer?.cancel();
        _controlsTimer = null;
        _controlsVisible = false;
        _lockIndicatorVisible = false;
      }
    });
  }

  void _showLockIndicator() {
    _lockIndicatorTimer?.cancel();
    setState(() => _lockIndicatorVisible = true);
    _lockIndicatorTimer = Timer(Duration(seconds: 3), () {
      if (mounted) {
        setState(() => _lockIndicatorVisible = false);
      }
    });
  }

  void _hideLockIndicator() {
    _lockIndicatorTimer?.cancel();
    setState(() => _lockIndicatorVisible = false);
  }

  void _onDoubleTapScreen() {
    _togglePlay();
    _showGestureIndicator(
      _playing ? '播放' : '暂停',
      _playing ? Icons.play_arrow : Icons.pause,
    );
  }

  void _onLongPressStart(LongPressStartDetails details) {
    final width = MediaQuery.of(context).size.width;
    final isRight = details.globalPosition.dx >= width / 2;
    _isLongPressSeeking = true;
    _longPressDirection = isRight ? 'right' : 'left';
    // 长按快进快退期间显示控制栏（含进度条），并保持可见。
    _showControls();
    // 以长按开始时的播放位置为基准，持续累加定位，保证画面实时平滑。
    //   🔴 2026-10-08：用 _trustedPositionMs，避免以被残留值污染的位置为起点。
    _logTrustedPosition('长按快进起点');
    _continuousSeekTarget = Duration(milliseconds: _trustedPositionMs);
    _showGestureIndicator(
      isRight ? '0.25X 快进中' : '0.25X 快退中',
      isRight ? Icons.fast_forward : Icons.fast_rewind,
    );
    _startHalfSpeedSeek();
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _isLongPressSeeking = false;
    _stopLongPressSeek();
    setState(() => _gestureIndicatorVisible = false);
  }

  void _startHalfSpeedSeek() {
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _continuousSeekTimer = Timer.periodic(Duration(milliseconds: 200), (
      _,
    ) {
      if (!_isLongPressSeeking || _backend == null) return;
      final step = _longPressDirection == 'right'
          ? _seekStep ~/ 4
          : -(_seekStep ~/ 4);
      _continuousSeekTarget += Duration(seconds: step);
      _seekFromUser(_continuousSeekTarget);
    });
  }

  void _onVerticalDragStart(DragStartDetails details) {
    _gestureStartPosition = details.globalPosition;
    _gestureStartBrightness = _currentBrightness;
    _gestureStartVolume = _currentVolume;
    _cumulativeDeltaY = 0.0;
  }

  void _onVerticalDragUpdate(DragUpdateDetails details) {
    if (_gestureStartPosition == null) return;
    _cumulativeDeltaY -= details.delta.dy;
    final width = MediaQuery.of(context).size.width;
    final isLeft = _gestureStartPosition!.dx < width / 2;
    final delta = _cumulativeDeltaY * _verticalGestureSensitivity;

    if (isLeft) {
      _currentBrightness = (_gestureStartBrightness + delta).clamp(0.0, 1.0);
      ScreenBrightness().setApplicationScreenBrightness(_currentBrightness);
      _showGestureIndicator(
        '亮度 ${(_currentBrightness * 100).toInt()}%',
        Icons.brightness_6,
      );
    } else {
      _currentVolume = (_gestureStartVolume + delta).clamp(0.0, 1.0);
      // 🔴🔴 2026-10-09 重定方案：手势改为【直接驱动播放器自身音量】。
      //
      // 【为什么放弃原有两套做法】真机 + SDK 双重确证：
      //   ① `VolumeController.instance.setVolume()` —— volume_controller 插件无 ohos
      //      实现，鸿蒙上走空实现（只改 Dart 本地变量）。**已知无效**。
      //   ② `VolumeOhos.set()` → ArkTS `setAppVolumePercentage()` —— 该 API 只影响
      //      `AudioRendererInfo.volumeMode == APP_INDIVIDUAL` 的 AudioRenderer；
      //      而 mpv 走自带 ohaudio 输出，`ohos/mpv_arkts` 全模块 grep `volumeMode`
      //      零命中 → 调用成功返回但音量纹丝不动。**静默失效**。
      //      （SDK 原文见 @ohos.multimedia.audio.d.ts:4669）
      //
      // 【为什么不能调系统媒体音量】三方应用无此能力：
      //   · `AudioVolumeGroupManager.setVolume` = @systemapi +
      //     ohos.permission.ACCESS_NOTIFICATION_POLICY
      //   · `AudioVolumeManager.setVolume` 自 API 9 起废弃且 @systemapi
      //   · `AVVolumePanel` 官方明文「暂不支持TV设备使用」，且只能由用户拖动，
      //     无法程序化联动（volumeLevel 是 @Prop 初始档位，非写入通道）
      //
      // 【现方案】改调**播放器自身音量**（mpv `volume` 属性 / AVPlayer 流音量）：
      //   三方天然可用、无权限、无 API 版本门槛、TV 形态同样成立，且立即生效。
      //   语义由「系统音量」改为「播放音量」—— 提示条文案同步修改，避免预期落差。
      _applyPlayerVolume(_currentVolume);
      _showGestureIndicator(
        '音量 ${(_currentVolume * 100).toInt()}%',
        _currentVolume > 0 ? Icons.volume_up : Icons.volume_off,
      );
    }
  }

  /// 把归一化音量（0..1）下发给当前播放后端。
  ///
  /// 各后端的 [PlayerBackend.setVolume] 语义均为「播放器流音量」：
  /// mpv → `setProperty("volume", v)`（`Player.ets:609`）；
  /// AVPlayer → `avPlayer.setVolume(v)`（`VideoPlayer.ets`）。
  /// 两者都是 0..1 归一化，与手势值域一致，无需换算。
  void _applyPlayerVolume(double volume) {
    final backend = _backend;
    if (backend == null) return;
    backend.setVolume(volume).catchError((Object e) {
      debugPrint('MobilePlayerScreen: 设置播放音量失败: $e');
    });
  }
  void _onVerticalDragEnd(DragEndDetails details) {
    _gestureStartPosition = null;
    _cumulativeDeltaY = 0.0;
    _gestureIndicatorTimer?.cancel();
    _gestureIndicatorTimer = Timer(Duration(milliseconds: 500), () {
      if (mounted) setState(() => _gestureIndicatorVisible = false);
    });
  }

  void _onHorizontalDragStart(DragStartDetails details) {
    _gestureStartPosition = details.globalPosition;
    _cumulativeDeltaX = 0.0;
  }

  void _onHorizontalDragUpdate(DragUpdateDetails details) {
    if (_gestureStartPosition == null) return;
    _cumulativeDeltaX += details.delta.dx;
    final deltaSeconds = _cumulativeDeltaX * _horizontalGestureSensitivity;
    final target =
        Duration(milliseconds: _trustedPositionMs) +
        Duration(seconds: deltaSeconds.toInt());
    _showGestureIndicator(
      '跳转至 ${_formatDuration(_clampDuration(target))}',
      deltaSeconds >= 0 ? Icons.fast_forward : Icons.fast_rewind,
    );
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_gestureStartPosition == null) return;
    final deltaSeconds = _cumulativeDeltaX * _horizontalGestureSensitivity;
    final target =
        Duration(milliseconds: _trustedPositionMs) +
        Duration(seconds: deltaSeconds.toInt());
    _seekFromUser(target);
    _gestureStartPosition = null;
    _cumulativeDeltaX = 0.0;
    _gestureIndicatorTimer?.cancel();
    _gestureIndicatorTimer = Timer(Duration(milliseconds: 500), () {
      if (mounted) setState(() => _gestureIndicatorVisible = false);
    });
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    final twoDigits = (int n) => n.toString().padLeft(2, '0');
    if (hours > 0) {
      return '${twoDigits(hours)}:${twoDigits(minutes)}:${twoDigits(seconds)}';
    }
    return '${twoDigits(minutes)}:${twoDigits(seconds)}';
  }

  String get _episodeTitle {
    final titles = _currentVideoDetail.episodesTitles;
    if (titles.isNotEmpty && _currentEpisodeIndex < titles.length) {
      return titles[_currentEpisodeIndex];
    }
    return '第${_currentEpisodeIndex + 1}集';
  }

  String _formatSpeed(double? speedBps) {
    if (speedBps == null) return '';
    if (speedBps == -1.0) return '可用';
    if (speedBps <= 0) return '不可用';
    if (speedBps >= 1024 * 1024) {
      return '${(speedBps / 1024 / 1024).toStringAsFixed(2)} MB/s';
    }
    return '${(speedBps / 1024).toStringAsFixed(1)} KB/s';
  }

  Color _speedColor(double? speedBps) {
    if (speedBps == null || speedBps == 0) return AppColors.error;
    if (speedBps == -1.0) return AppColors.success;
    if (speedBps >= 1 * 1024 * 1024) return AppColors.success;
    if (speedBps >= 256 * 1024) return AppColors.primary;
    return AppColors.warning;
  }

  void _cycleVideoFit() {
    setState(() {
      switch (_videoFit) {
        case BoxFit.contain:
          _videoFit = BoxFit.cover;
          break;
        case BoxFit.cover:
          _videoFit = BoxFit.fill;
          break;
        default:
          _videoFit = BoxFit.contain;
      }
    });
    _backend?.fit = _videoFit;
    _showControls();
  }

  void _cyclePlaybackSpeed() {
    setState(() {
      switch (_playbackSpeed) {
        case 1.0:
          _playbackSpeed = 1.25;
          break;
        case 1.25:
          _playbackSpeed = 1.5;
          break;
        case 1.5:
          _playbackSpeed = 2.0;
          break;
        default:
          _playbackSpeed = 1.0;
      }
    });
    _backend?.setSpeed(_playbackSpeed);
    _showControls();
  }

  String _playbackSpeedLabel(double speed) {
    if (speed == 1.0) return '倍速';
    return '${speed}x';
  }

  String _videoFitLabel(BoxFit fit) {
    switch (fit) {
      case BoxFit.contain:
        return '原始比例';
      case BoxFit.cover:
        return '填充';
      case BoxFit.fill:
        return '拉伸';
      default:
        return '原始比例';
    }
  }

  String _playerBackendLabel(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        return 'ExoPlayer';
      case PlayerBackendType.fvp:
        return 'FVP';
      case PlayerBackendType.vlc:
        return 'VLC';
      case PlayerBackendType.avplayer:
        // 鸿蒙原生系统播放器，与安卓的 ExoPlayer 定位对等。
        return 'AVPlayer';
      case PlayerBackendType.mpv:
        return 'mpv';
    }
  }

  Future<void> _toggleOrientation() async {
    final size = MediaQuery.of(context).size;
    final isPortrait = size.width < size.height;
    if (isPortrait) {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.portraitUp,
        DeviceOrientation.portraitDown,
      ]);
    }
  }

  /// 处理退出播放页。
  ///
  /// 更实效的修改方案：
  /// 1. 退出路径只走一次（通过 [_isExiting] 标记），避免 [_handleBack] 和 [dispose]
  ///    重复执行方向恢复、播放器释放等耗时操作；
  /// 2. 先保存记录、取消监听、从 widget 树移除 PlatformView（渲染为黑屏），
  ///    让用户立刻看到即将返回的详情页；
  /// 3. 暂停、方向恢复、系统 UI 恢复、播放器释放全部改为异步/带超时，
  ///    不阻塞 pop 和页面转场动画；
  /// 4. 播放器与 M3U8 代理的释放延迟到转场动画开始后再执行。
  Future<void> _handleBack({bool forceExit = false}) async {
    if (_isExiting) return;

    // 非强制退出且控制栏可见时，先隐藏控制栏
    if (!forceExit && _controlsVisible) {
      _hideControls();
      return;
    }

    _isExiting = true;

    // 1. 保存播放记录并取消流监听，避免后续 setState 或回调在清理阶段触发
    _savePlayRecordToLunaTV();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

    // 2. 捕获后端引用，并立即从 widget 树中移除 PlatformView（渲染为黑屏）
    final backend = _backend;
    _backend = null;
    _eagerVideoLayer = null;
    if (mounted) {
      setState(() => _initialized = false);
    }

    // 3. 尝试暂停播放，但不阻塞退出流程
    unawaited(
      backend
          ?.pause()
          .timeout(Duration(seconds: 1))
          .catchError((e) {
        debugPrint('MobilePlayerScreen: 暂停失败: $e');
      }),
    );

    // 4. 立即恢复系统 UI 与方向，不等待完成
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
          .timeout(Duration(seconds: 2))
          .catchError((e) {
        debugPrint('MobilePlayerScreen: 恢复系统 UI 模式失败: $e');
      }),
    );
    unawaited(
      _restoreOrientation(_originalOrientation)
          .timeout(Duration(seconds: 2))
          .catchError((e) {
        debugPrint('MobilePlayerScreen: 恢复方向失败/超时: $e');
      }),
    );

    // 5. 下一帧执行 pop，确保黑屏已渲染、方向/UI 恢复已发起
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
      }
    });

    // 6. 延迟异步释放播放器与代理，不阻塞 pop 和页面转场
    Future.delayed(Duration(milliseconds: 300), () {
      if (backend != null) {
        unawaited(
          backend.dispose().timeout(Duration(seconds: 5)).catchError((e) {
            debugPrint('MobilePlayerScreen: 释放播放器后端失败/超时: $e');
          }),
        );
      }
      unawaited(
        AdFilterEngine.dispose().timeout(Duration(seconds: 5)).catchError(
            (e) {
          debugPrint('MobilePlayerScreen: 释放 M3U8 代理失败/超时: $e');
        }),
      );
    });
  }

  /// 旋转/尺寸变更去抖定时器。避免系统旋转动画过渡帧里 didChangeMetrics 被
  /// 反复触发（同一帧连发十余次），导致 mpv 在出帧途中反复 resize 纹理缓冲而
  /// 死锁卡死（与 AVPlayer 后端不同：AVPlayer 纹理由引擎自动管理、Dart 侧零干预；
  /// mpv 路线 B 纹理需 Dart 主动给定最终尺寸，但必须等布局稳定后只发一次）。
  Timer? _surfaceResizeTimer;

  @override
  void didChangeMetrics() {
    // 参照 AVPlayer 后端的稳的处理哲学：不在过渡帧里抢发，等旋转动画结束、
    // 布局真正稳定（下一帧）后再读取 MediaQuery 的**最终**尺寸并下发一次。
    super.didChangeMetrics();
    if (!mounted) return;
    final backend = _backend;
    if (backend is! MpvBackend || !backend.textureReady) return;
    // 先取消上一帧未触发的去抖，确保旋转过程中只保留最后一次（稳定后）的调用。
    _surfaceResizeTimer?.cancel();
    _surfaceResizeTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final b = _backend;
      if (b is! MpvBackend || !b.textureReady) return;
      // 此刻 MediaQuery 已是旋转完成后的最终尺寸（宽高比正确）。
      final size = MediaQuery.of(context).size;
      b.updateSurfaceSize(size, MediaQuery.of(context).devicePixelRatio);
    });
  }


  /// 上报播放缓冲水位，供后台测速让路判断。
  ///
  /// 缓冲剩余量 = 缓冲末端 - 当前播放位置；低于阈值说明播放器正在等数据，
  /// 此时后台测速应完全停手，把带宽全部让给缓冲。
  void _reportBufferHealth(Duration position) {
    final id = _playbackSessionId;
    if (id == null) return;
    final remaining = _buffered - position;
    PlaybackActivity.instance.reportBufferStarved(
      id,
      remaining < const Duration(seconds: 3),
    );
  }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _controlsTimer?.cancel();
    _lockIndicatorTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _clockTimer?.cancel();
    _autoSwitchTimer?.cancel();
    _locateGateTimer?.cancel();
    _surfaceResizeTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    // 释放播放会话：后台测速恢复全速
    final sessionId = _playbackSessionId;
    if (sessionId != null) {
      PlaybackActivity.instance.closeSession(sessionId);
      _playbackSessionId = null;
    }

    // 立即保存播放记录到 LunaTV（本地保存，异步上传不阻塞）
    _savePlayRecordToLunaTV();

    // 退出播放页后允许系统自动休眠/降亮度
    ScreenWakeOhos.disable().catchError((e) {
      debugPrint('MobilePlayerScreen: 禁用屏幕常亮失败: $e');
    });

    widget.sourcesNotifier?.removeListener(_onSourcesChanged);

    // 若已经由 [_handleBack] 触发退出，则所有资源释放、方向/UI 恢复均已在该路径中
    // 调度，dispose 中不再重复执行，避免两次方向恢复、两次播放器释放竞争导致卡死。
    if (_isExiting) {
      _backend = null;
      _eagerVideoLayer = null;
      super.dispose();
      return;
    }

    // 非用户主动退出（如路由被直接替换）时的兜底清理：将后端释放、代理释放、
    // 方向恢复、系统 UI 恢复推迟到路由转场完成后异步执行，避免阻塞 dispose。
    final backend = _backend;
    _backend = null;
    _eagerVideoLayer = null;
    final original = _originalOrientation;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future.delayed(Duration(milliseconds: 300));
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
            .timeout(Duration(seconds: 2))
            .catchError((e) {
          debugPrint('MobilePlayerScreen: 恢复系统 UI 模式失败: $e');
        }),
      );
      unawaited(
        _restoreOrientation(original)
            .timeout(Duration(seconds: 2))
            .catchError((e) {
          debugPrint('MobilePlayerScreen: 恢复方向失败/超时: $e');
        }),
      );
      if (backend != null) {
        unawaited(
          backend.dispose().timeout(Duration(seconds: 5)).catchError((e) {
            debugPrint('MobilePlayerScreen: 释放播放器后端失败/超时: $e');
          }),
        );
      }
      unawaited(
        AdFilterEngine.dispose().timeout(Duration(seconds: 5)).catchError(
            (e) {
          debugPrint('MobilePlayerScreen: 释放 M3U8 代理失败/超时: $e');
        }),
      );
    });

    super.dispose();
  }

  /// 详情页在后台搜索/测速到新源或重排后，通过 [sourcesNotifier] 同步到播放页。
  /// 保持当前正在播放的源仍处于选中状态，确保换源列表实时刷新且不会跳到其他源。
  void _onSourcesChanged() {
    if (!mounted) return;
    setState(() {
      final candidates = [
        '${_currentVideoDetail.source}+${_currentVideoDetail.id}',
        if (_initialSourceKey != null && _initialSourceKey!.isNotEmpty)
          _initialSourceKey!,
      ];
      final currentKey = _sources.isNotEmpty && _currentSourceIndex < _sources.length
          ? '${_sources[_currentSourceIndex].source}+${_sources[_currentSourceIndex].id}'
          : null;
      if (currentKey != null && currentKey.isNotEmpty && !candidates.contains(currentKey)) {
        candidates.add(currentKey);
      }

      var newIndex = -1;
      for (final key in candidates) {
        if (key.isEmpty || key == '+') continue;
        final index = _sources.indexWhere(
          (s) => '${s.source}+${s.id}' == key,
        );
        if (index >= 0) {
          newIndex = index;
          break;
        }
      }

      if (newIndex >= 0) {
        _currentSourceIndex = newIndex;
      } else {
        _currentSourceIndex = _currentSourceIndex.clamp(
          0,
          _sources.isEmpty ? 0 : _sources.length - 1,
        );
      }
    });
    _syncPlaybackSourceKey();
  }

  Future<void> _restoreOrientation(Orientation? original) async {
    try {
      if (original == Orientation.landscape) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else if (original == Orientation.portrait) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      } else {
        // 未能确定原始方向时恢复为系统默认（全部允许）
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
    } catch (e) {
      debugPrint('MobilePlayerScreen: 恢复方向失败: $e');
    }
  }

  /// 🔴 2026-10-23：把当前正在播放的源标识上报给 [PlaybackActivity]。
  ///
  /// 测速据此**跳过正在播放的源**（该源只识别分辨率、不测速），避免测出的
  /// 速度被自身播放流污染（表现为「一开始播放源速度就显示很慢」），也避免
  /// 对同一份流量重复占用带宽。换源后需要重新上报。
  void _syncPlaybackSourceKey() {
    final sessionId = _playbackSessionId;
    if (sessionId == null) return;
    final key = _sources.isNotEmpty && _currentSourceIndex < _sources.length
        ? '${_sources[_currentSourceIndex].source}+${_sources[_currentSourceIndex].id}'
        : '${_currentVideoDetail.source}+${_currentVideoDetail.id}';
    PlaybackActivity.instance.reportCurrentSource(sessionId, key);
  }

  /// 保存播放记录：先写入本地确保立即可见，再异步上传 LunaTV。
  /// 串行化（同一时间只允许一个保存任务）；未真正起播或进度无效时不落盘，
  /// 进度越界时钳制在 [0, 总时长] 内，防止脏数据导致下次续播 seek 异常。
  Future<void> _savePlayRecordToLunaTV() async {
    if (_recordSaveInFlight) return;
    if (!_isPlaybackReadyForRecord()) return;
    _recordSaveInFlight = true;
    try {
      final totalSec = _duration.inSeconds;
      // 🔴 2026-10-08 修复：播放记录**必须**用 _trustedPositionMs，不能用 _position。
      //
      //   【原来的 bug】_position 会被原生侧的「乐观置位」污染成 seek 的**请求值**
      //   （见 MpvBridge.ets 的 `this.positionSec = target`）。若 seek 因故落空
      //   （HLS 关键帧对齐 / 网络重载），_position 仍停在这个虚高值上，
      //   于是**虚高进度被写进播放记录并持久化**。
      //
      //   【为什么这解释了「偏差越往后越大」】单次会话内的偏差本可随锚点释放
      //   自我修正，但播放记录一旦落盘，下次进入就以这个虚高值为续播点 ——
      //   偏差被**跨会话固化**，且每次 seek 都可能再叠一层，误差只增不减。
      //
      //   【为什么 _trustedPositionMs 是对的】它内部会优先采用 mpv 真实时钟
      //   （realPositionSec），并在真实位置证伪锚点后立即释放锚点，故它给出的
      //   是「可以确信的当前位置」，正是播放记录需要的语义。
      //   进度条显示本就走 _trustedPositionMs，此处改为与之对齐，两者不再打架。
      final rawPos = _trustedPositionMs ~/ 1000;
      // 🔴 2026-10-23：起播位置为 0 时**不得覆盖**已有的有效进度。
      //   真机（荣耀平板 V8 Pro 2026-10-23 14:58，换源到 zuidazy.co）：
      //   mpv 的 file-loaded 迟了 12 秒，期间位置流恒为 0，被节流保存写盘成
      //   playTime=0s，把切换前刚保存的 431s 抹掉 ——
      //   用户侧表现为「换源后读取播放记录失败 / 进度丢失」。
      //   这里做双保险：既拦「起播定位未落地」，也拦「位置为 0 且已有进度」。
      if (rawPos <= 0) {
        final existing = await PlayRecordService.getLatestLocalByTitle(
          _currentVideoDetail.title,
          year: _currentVideoDetail.year,
        );
        if (existing != null && existing.playTime > 0) {
          debugPrint(
            '[HeinPlay] 起播位置为 0，保留既有进度 playTime=${existing.playTime}s（不覆盖）',
          );
          return;
        }
      }
      final playSec = rawPos < 0 ? 0 : (rawPos > totalSec ? totalSec : rawPos);
      final record = PlayRecord(
        id: _currentVideoDetail.id,
        source: _currentVideoDetail.source,
        title: _currentVideoDetail.title,
        sourceName: _currentVideoDetail.source,
        cover: _currentVideoDetail.poster,
        year: _currentVideoDetail.year,
        index: _currentEpisodeIndex + 1, // 1-based
        totalEpisodes: _currentVideoDetail.episodes.length,
        playTime: playSec,
        totalTime: totalSec,
        saveTime: DateTime.now().millisecondsSinceEpoch,
        searchTitle: _currentVideoDetail.title,
        doubanId: _currentVideoDetail.doubanId?.toString(),
      );

      await PlayRecordService.save(record);
      debugPrint(
        '[HeinPlay] 播放记录已保存: index=${record.index} playTime=${record.playTime}s totalTime=${record.totalTime}s',
      );
    } catch (e) {
      // 保存失败不阻塞退出
      debugPrint('保存播放记录失败: $e');
    } finally {
      _recordSaveInFlight = false;
    }
  }

  Widget _buildVideo() {
    if (_isExiting) {
      return ColoredBox(color: Colors.black);
    }
    // 切换源/播放器期间由切换遮罩显示加载提示，避免与视频层加载图标重叠。
    //
    // 🔴 2026-09-30：但 requiresEagerMount 的后端（mpv）**不能在这里早退**！
    //   切换后端走 [_replaceBackend]，它先置 _switchingSource=true，再调
    //   _initBackend()→_openEpisodeImpl()→backend.open()。而 open() 要等
    //   PlatformView 创建，PlatformView 又要 buildVideoWidget() 被调用。
    //   若此处因 _switchingSource 返回纯黑，就再次死锁：
    //   open 等 view → view 等 build → build 被 _switchingSource 拦住。
    //   真机日志表现：切换后端后 5 秒「等待 XComponent view 创建超时」，
    //   进度条归零并卡死。
    //   故对这类后端，_switchingSource 期间仍走下面的 eager 挂载分支
    //   （遮罩层已能盖住画面，不需要靠「不挂载」来遮挡）。
    if (_switchingSource && !(_backend?.requiresEagerMount ?? false)) {
      return ColoredBox(color: Colors.black);
    }

    // 🔴 2026-09-30：mpv（XComponent SURFACE）必须**提前且常驻**挂载。
    //
    // 【死锁成因】mpv-arkts 的原生 Player 实例是在 PlatformView 被 Flutter
    //   创建时才 new 出来的，而 MpvBackend.open() 要等这个 view 的 id。
    //   若此处沿用「_initialized 前不挂载 / 闸门未开不挂载」的既有逻辑，
    //   就会形成闭环死锁：
    //     open() 等 view 创建 → view 要 buildVideoWidget 被调用
    //       → 被 _initialized / 闸门拦住 → 闸门要等位置事件
    //       → 位置事件要 view 创建。
    //   真机日志表现：`Bad state: MpvBackend: 等待 XComponent view 创建超时`。
    //
    // 【处理】对 requiresEagerMount 的后端，视频层在 _openEpisodeImpl 一开始就
    //   挂载并**全程保持同一个 widget 实例**（_eagerVideoLayer 缓存），
    //   用 IndexedStack + 不透明黑遮罩来隐藏定位前的画面，
    //   从而既不死锁、也不露出片头画面。
    //
    //   走 texture 的后端（fvp/avplayer/video_player）不受影响 —— 它们的
    //   open() 不依赖 Flutter 侧挂载，引擎自行出帧并上报位置，闸门能正常开闸。
    if (_backend != null && _backend!.requiresEagerMount) {
      // 🔴 2026-09-30 路线 B：mpv 后端画面走 Flutter 纹理（Texture(textureId)）。
      //    buildVideoWidget() 返回的 OhosView 仅作「挂载锚点」——它进入渲染树会
      //    触发原生 create→registerTexture 拿到 surfaceId；本体透明，画面由
      //    Texture(textureId) 叠加显示，二者叠加共存（锚点必常驻，否则 create 不触发）。
      final mpv = _backend as dynamic;
      final textureReady = mpv is MpvBackend && mpv.textureReady;
      final textureId = textureReady ? mpv.textureId as int : null;
      final showVideo = _initialized && _locateGateOpen && textureReady;
      // 🔴🔴 2026-10-07 换源修复：锚点必须能「换代」，不能永久复用同一个 widget。
      //
      //   【原设计】_eagerVideoLayer ??= ... 让锚点全程只建一次，是为了避免
      //     「open() 等 view / view 等 buildVideoWidget」的死锁（见上方注释）。
      //
      //   【原设计的漏洞】换源时旧 PlatformView 已被原生 dispose()，而锚点 widget
      //     实例被复用、Flutter 不重建 PlatformView → 原生永远不再 new 出新的
      //     Player → Dart 侧 MpvBackend._viewId 仍指向**已销毁的旧 viewId** →
      //     open() 发出的 loadfile 落在死 view 上，画面永远出不来。
      //     真机证据：22:59:20.638 dispose viewId=2 → 22:59:21.928 open →
      //     22:59:27.424 抛「等待 XComponent view 创建超时」，且该窗口内
      //     完全没有 `MpvViewFactory.create()` 日志（原生根本没被要求建新 view）。
      //     而「退出播放重进」会新建 MpvBackend 实例 + 新 widget 树 → 又能播。
      //
      //   【修法】用 ValueKey 绑定「锚点代数」_eagerLayerGeneration。
      //     代数变化 → Flutter 视为不同 widget → 销毁旧 PlatformView 并创建新的
      //     → 触发 MpvViewFactory.create() → 新的 Player/viewId。
      //     Dart 侧 MpvBackend 的 _viewSeq 等待机制正好接住这一代新 view。
      //     死锁依旧不会发生：换源在 _openEpisodeImpl 里先递增代数并 setState，
      //     下一帧锚点即挂载完成，之后才轮到 open() 去等它。
      final anchor = _eagerVideoLayer ??= KeyedSubtree(
        key: ValueKey<int>(_eagerLayerGeneration),
        child: _backend!.buildVideoWidget(),
      );
      return SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 挂载锚点（OhosView，透明），常驻以触发原生 create/registerTexture。
            Opacity(opacity: 0.0, child: anchor),
            // 真实画面：纹理就绪后叠加 Texture 显示。
            if (textureId != null)
              Opacity(
                opacity: showVideo ? 1.0 : 0.0,
                child: Texture(textureId: textureId),
              ),
            if (!showVideo)
              ColoredBox(
                color: Colors.black,
                child: _initialized
                    ? null
                    : const Center(child: TechLoadingIndicator()),
              ),
          ],
        ),
      );
    }

    if (!_initialized || _backend == null) {
      return Center(
        child: TechLoadingIndicator(),
      );
    }
    // 🔴 续播定位闸门：位置未抵达续播点前不挂载视频层，避免露出片头画面。
    //    这是「闪开头」的最终兜底 —— 无论后端内部何时开始出帧，只要这里不挂载
    //    texture，观众就看不到定位前的画面。详见 _locateGateOpen 字段注释。
    if (!_locateGateOpen) {
      return const ColoredBox(color: Colors.black);
    }
    return Container(color: Colors.black, child: _backend!.buildVideoWidget());
  }

  /// 评估续播定位闸门。开闸条件（任一满足）：
  ///   ① 收到**首帧信号**（纹理真正出帧）—— 最可靠的硬信号；
  ///   ② 位置连续多次进入续播点邻域（±5s）—— 与①互补，覆盖不出首帧信号的场面；
  ///   ③ 无续播点（从片头播）—— 但必须确认「确实没有待定位目标」；
  ///   ④ 超时兜底 —— 宁可闪一下也不能一直黑屏。
  ///
  /// 由 [_onPositionUpdate]、首帧流订阅与 [_openEpisodeImpl] 调用。
  void _evalLocateGate(int positionMs, {bool firstFrame = false}) {
    if (_locateGateOpen) return;

    final target = _resumeAnchorMs;
    final started = _locateGateSince;

    // ① 首帧已出 → 画面内容就是续播点画面，可以安全显示。
    if (firstFrame) {
      _openLocateGate('首帧已出 position=${positionMs}ms');
      return;
    }
    // ③ 无续播点（从片头播）→ 立即可见。
    //
    //   🔴 2026-10-08【方案 C 修正】原判据是 `target <= 0`，会把「还没有续播点
    //   信息」误当成「确实不需要续播」：open 刚下发时 _resumeAnchorMs 可能仍为 0，
    //   此刻开闸就等于没闸。改为额外要求「已收到过有效位置」，即位置流确实
    //   开始工作、且没有待定位目标，才认定真的从片头播。
    //   （_pendingInitialPositionMs 非 0 时 _resumeAnchorMs 必定已同步为正数，
    //    见 L1051 赋值，故此处无需重复检查它。）
    if (target <= 0 && positionMs > 0) {
      _openLocateGate('无续播点 position=${positionMs}ms');
      return;
    }
    // ② 位置**连续多次**进入续播点邻域（±5s，容忍 HLS 分片边界偏差）。
    //
    //   🔴 2026-10-08【方案 C 核心修正】不再凭单次采样开闸。
    //   原因：mpv 路径在 seek 期间上报的就是「请求值」（原生侧对齐 AVP 语义），
    //   首次采样必然恰好等于 target，单次判据会立刻为真 → 闸门失效。
    //   真实落点稳定后位置会持续停留/递增在该邻域，注入值则只出现一次即被
    //   真实采样覆盖，故要求连续 N 次。
    final inNeighborhood =
        positionMs > 0 && (positionMs - target).abs() <= 5000;
    if (inNeighborhood) {
      _locateGateStableSamples++;
      if (_locateGateStableSamples >= _kLocateGateStableSamples) {
        _openLocateGate(
          '已定位 position=${positionMs}ms '
          '（连续${_locateGateStableSamples}次稳定采样）',
        );
        return;
      }
    } else {
      // 离开邻域（如仍在片头/尚未定位）→ 计数清零，防止抖动累积。
      _locateGateStableSamples = 0;
    }
    // ④ 超时兜底。
    if (started != null &&
        DateTime.now().difference(started) > _locateGateTimeout) {
      _openLocateGate(
        '超时兜底 position=${positionMs}ms target=${target}ms',
      );
    }
  }

  void _openLocateGate(String reason) {
    if (_locateGateOpen) return;
    _locateGateOpen = true;
    _locateGateSince = null;
    _locateGateStableSamples = 0;
    _locateGateTimer?.cancel();
    _locateGateTimer = null;
    debugPrint('续播定位闸门开启: $reason');
    if (mounted) setState(() {});
  }

  Widget _buildError() {
    if (_error == null) return SizedBox.shrink();
    return Container(
      color: Colors.black54,
      padding: EdgeInsets.all(AppSpacing.md),
      child: Text(_error!, style: TextStyle(color: AppColors.error)),
    );
  }

  Widget _buildSwitchingOverlay() {
    if (!_switchingSource) return SizedBox.shrink();
    return Container(
      color: Colors.black54,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TechLoadingIndicator(),
            SizedBox(height: AppSpacing.md),
            Text('切换播放源中...', style: TextStyle(color: Color(0xFFF0F0F5))),
          ],
        ),
      ),
    );
  }

  Widget _buildGestureIndicator() {
    if (!_gestureIndicatorVisible) return SizedBox.shrink();
    return Center(
      child: Container(
        padding: EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: Color(0xD90A0A0F),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_gestureIndicatorIcon, color: Color(0xFFF0F0F5), size: 32),
            SizedBox(height: AppSpacing.sm),
            Text(
              _gestureIndicatorText,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                color: Color(0xFFF0F0F5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGestureOverlay() {
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        // 锁定时单击屏幕仍用于显示/隐藏解锁功能键，其他手势全部禁用。
        onTap: _onTapScreen,
        onDoubleTap: _controlsLocked ? null : _onDoubleTapScreen,
        onLongPressStart: _controlsLocked ? null : _onLongPressStart,
        onLongPressEnd: _controlsLocked ? null : _onLongPressEnd,
        onVerticalDragStart: _controlsLocked ? null : _onVerticalDragStart,
        onVerticalDragUpdate: _controlsLocked ? null : _onVerticalDragUpdate,
        onVerticalDragEnd: _controlsLocked ? null : _onVerticalDragEnd,
        onHorizontalDragStart: _controlsLocked ? null : _onHorizontalDragStart,
        onHorizontalDragUpdate: _controlsLocked ? null : _onHorizontalDragUpdate,
        onHorizontalDragEnd: _controlsLocked ? null : _onHorizontalDragEnd,
        child: Container(color: Colors.transparent),
      ),
    );
  }

  Widget _buildTopBar() {
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color(0xD90A0A0F), Colors.transparent],
        ),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              onPressed: () => _handleBack(forceExit: true),
              icon: Icon(Icons.arrow_back, color: Color(0xFFF0F0F5)),
            ),
            SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _currentVideoDetail.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFF0F0F5),
                    ),
                  ),
                  Text(
                    _episodeTitle,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: Color(0xFF9CA3AF),
                    ),
                  ),
                ],
              ),
            ),
            Text(
              _formatClock(_currentTime),
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Color(0xFFF0F0F5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    final size = MediaQuery.of(context).size;
    final isPortrait = size.width < size.height;

    return Container(
      padding: EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Color(0xD90A0A0F), Colors.transparent],
        ),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            GestureDetector(
              onTapUp: (details) {
                final box = context.findRenderObject() as RenderBox?;
                if (box == null) return;
                final width = box.size.width;
                final percent = details.localPosition.dx / width;
                _seekToPercent(percent.clamp(0.0, 1.0));
              },
              child: Container(
                height: 12,
                color: Colors.transparent,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      LinearProgressIndicator(
                        value: _duration.inMilliseconds > 0
                            ? _buffered.inMilliseconds /
                                _duration.inMilliseconds
                            : 0.0,
                        backgroundColor: Color(0x14FFFFFF),
                        valueColor: AlwaysStoppedAnimation<Color>(
                          Colors.white24,
                        ),
                      ),
                      LinearProgressIndicator(
                        value: _duration.inMilliseconds > 0
                            ? _position.inMilliseconds /
                                _duration.inMilliseconds
                            : 0.0,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            SizedBox(height: AppSpacing.md),
            Center(
              child: Text(
                '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 13,
                  color: Color(0xFFF0F0F5),
                ),
              ),
            ),
            SizedBox(height: AppSpacing.xs),
            if (isPortrait)
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _buildControlsRow(
                    children: [
                      IconButton(
                        onPressed: _togglePlay,
                        icon: Icon(
                          _playing ? Icons.pause : Icons.play_arrow,
                          color: Color(0xFFF0F0F5),
                          size: 32,
                        ),
                      ),
                      IconButton(
                        onPressed: _previousEpisode,
                        icon: Icon(
                          Icons.skip_previous,
                          color: Color(0xFFF0F0F5),
                          size: 28,
                        ),
                      ),
                      IconButton(
                        onPressed: _nextEpisode,
                        icon: Icon(
                          Icons.skip_next,
                          color: Color(0xFFF0F0F5),
                          size: 28,
                        ),
                      ),
                      SizedBox(width: AppSpacing.sm),
                    ],
                  ),
                  SizedBox(height: AppSpacing.sm),
                  _buildControlsRow(children: _buildFunctionButtons()),
                ],
              )
            else
              Row(
                children: [
                  IconButton(
                    onPressed: _togglePlay,
                    icon: Icon(
                      _playing ? Icons.pause : Icons.play_arrow,
                      color: Color(0xFFF0F0F5),
                      size: 32,
                    ),
                  ),
                  IconButton(
                    onPressed: _previousEpisode,
                    icon: Icon(
                      Icons.skip_previous,
                      color: Color(0xFFF0F0F5),
                      size: 28,
                    ),
                  ),
                  IconButton(
                    onPressed: _nextEpisode,
                    icon: Icon(
                      Icons.skip_next,
                      color: Color(0xFFF0F0F5),
                      size: 28,
                    ),
                  ),
                  Spacer(),
                  ..._buildFunctionButtons(),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildControlsRow({required List<Widget> children}) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: children,
    );
  }

  List<Widget> _buildFunctionButtons() {
    return [
      if (_currentVideoDetail.source.isNotEmpty &&
          _currentVideoDetail.id.isNotEmpty)
        _buildControlButton(
          onTap: _showSkipConfigDialog,
          icon: Icons.skip_next,
          label: '跳过',
          active: _skipConfig != null && _skipConfig!.segments.isNotEmpty,
          loading: _skipConfigLoading,
        ),
      _buildControlButton(
        onTap: _cyclePlaybackSpeed,
        icon: Icons.speed,
        label: _playbackSpeedLabel(_playbackSpeed),
      ),
      _buildControlButton(
        onTap: _cycleVideoFit,
        icon: Icons.aspect_ratio,
        label: _videoFitLabel(_videoFit),
      ),
      _buildControlButton(
        onTap: _showPlayerBackendSelectorDialog,
        icon: Icons.settings_applications,
        label: _playerBackendLabel(_currentPlayerBackend),
      ),
      if (_canSwitchSource)
        _buildControlButton(
          onTap: _showSourceSelectorDialog,
          icon: Icons.swap_horiz,
          label: '换源',
        ),
      if (_currentVideoDetail.episodes.length > 1)
        _buildControlButton(
          onTap: _showEpisodeSelectorDialog,
          icon: Icons.list,
          label: '选集',
        ),
      _buildControlButton(
        onTap: _toggleOrientation,
        icon: Icons.screen_rotation,
        label: '旋转',
      ),
    ];
  }

  Widget _buildControlButton({
    required VoidCallback onTap,
    required IconData icon,
    required String label,
    bool active = false,
    bool loading = false,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.md),
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: active ? AppColors.primaryTint : Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading)
              SizedBox(
                width: 20,
                height: 20,
                child: TechLoadingIndicator(
                  size: 20,
                  strokeWidth: 2,
                ),
              )
            else
              Icon(
                icon,
                color: active ? AppColors.primary : Color(0xFFF0F0F5),
                size: 22,
              ),
            SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 11,
                color: active ? AppColors.primary : Color(0xFFF0F0F5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _handleBack();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 最底层：纯黑背景，确保黑边区域由 Flutter 绘制，
            // 避免 PlatformView 在隐藏控制栏后仍残留影像。
            Positioned.fill(child: ColoredBox(color: Colors.black)),
            // 视频层：只覆盖实际画面区域，黑边留给我 Flutter 背景。
            // IgnorePointer 避免 PlatformView 拦截触摸事件，确保手势层能正常工作。
            //
            // 🔴🔴 2026-10-24 第五轮：视频层必须用 **RepaintBoundary 隔离**。
            //
            // 【为什么】视频层与控制栏 / 手势层是同一个 `Stack` 的兄弟节点，
            //   而 `Stack` 默认把**所有子节点画进同一层** ⇒ 控制栏显示/隐藏、
            //   进度条每秒刷新、手势层变化 …… 都会**连带重画视频纹理区域**。
            //   视频是 Flutter **外部纹理**（OHOS external texture），
            //   每次重画都要向引擎申请一块消费缓冲
            //   （`OH_NativeImage_AcquireNativeWindowBuffer`）。
            //   消费队列瞬时为空时引擎报 `40601000`
            //   （= NATIVE_ERROR_NO_BUFFER / no idle buffer）并**回退显示上一帧**
            //   ⇒ 观感就是「小顿挫」，而 position 仍在正常推进。
            //
            // 【真机实锤：hilog 2026-10-24 09:09】595 次唯一取帧失败中，
            //   6 个「突发秒」（26~46 次/秒，基线仅 4~5 次/秒）里有 4 个
            //   落在控制栏切换后的 1~2 秒内，其余 2 个落在 seek / 换源处
            //   —— 两者都会重画整层。
            //
            // 【修法】给视频层套 `RepaintBoundary` ⇒ 控制栏/进度条的刷新
            //   不再弄脏视频层 ⇒ 引擎只在**真正有新视频帧**时才重画纹理。
            //   不改变布局、不改变纹理、不改变任何行为语义。
            Positioned.fill(
              child: RepaintBoundary(
                child: IgnorePointer(child: _buildVideo()),
              ),
            ),
            // 错误提示
            Center(child: _buildError()),
            // 切换源遮罩
            Positioned.fill(child: _buildSwitchingOverlay()),
            // 触摸手势层：响应点击、双击、长按、滑动等手势。
            _buildGestureOverlay(),
            // 控制栏覆盖层：完全不可见时从渲染树/焦点树中彻底移除。
            Visibility(
              visible: _controlsVisible || _isLongPressSeeking,
              maintainState: false,
              maintainAnimation: false,
              maintainSize: false,
              maintainInteractivity: false,
              child: Positioned.fill(
                child: Stack(
                  children: [
                    Positioned(
                      top: 0,
                      left: 0,
                      right: 0,
                      child: _buildTopBar(),
                    ),
                    Positioned(
                      bottom: 0,
                      left: 0,
                      right: 0,
                      child: _buildBottomControls(),
                    ),
                  ],
                ),
              ),
            ),
            // 未锁定时将锁定按钮放在右侧中间，与解锁图标位置一致。
            if (_controlsVisible && !_controlsLocked)
              Positioned(
                right: AppSpacing.lg,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _toggleControlsLock,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Color(0xD90A0A0F).withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Icon(
                        Icons.lock,
                        color: Color(0xFFF0F0F5),
                        size: 32,
                      ),
                    ),
                  ),
                ),
              ),
            // 锁定时点击屏幕显示解锁功能键，位于屏幕右侧中间，点击可解锁。
            if (_controlsLocked && _lockIndicatorVisible)
              Positioned(
                right: AppSpacing.lg,
                top: 0,
                bottom: 0,
                child: Center(
                  child: GestureDetector(
                    onTap: _toggleControlsLock,
                    behavior: HitTestBehavior.opaque,
                    child: Container(
                      padding: EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: Color(0xD90A0A0F).withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: Icon(
                        Icons.lock_open,
                        color: Color(0xFFF0F0F5),
                        size: 32,
                      ),
                    ),
                  ),
                ),
              ),
            // 手势操作提示（亮度/音量/进度）
            _buildGestureIndicator(),
          ],
        ),
      ),
    );
  }
}

class _SourceSelectorDialog extends StatefulWidget {
  final List<SourceOption> sources;
  final int currentIndex;
  final String Function(double?) formatSpeed;
  final Color Function(double?) speedColor;
  final ValueChanged<int> onSelect;

  const _SourceSelectorDialog({
    required this.sources,
    required this.currentIndex,
    required this.formatSpeed,
    required this.speedColor,
    required this.onSelect,
  });

  @override
  State<_SourceSelectorDialog> createState() => _SourceSelectorDialogState();
}

class _SourceSelectorDialogState extends State<_SourceSelectorDialog> {
  late final ScrollController _scrollController;
  late final List<GlobalKey> _itemKeys;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    _itemKeys = List.generate(widget.sources.length, (_) => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final index = widget.currentIndex.clamp(0, widget.sources.length - 1);
      final ctx = _itemKeys[index].currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: Duration(milliseconds: 200),
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color(0xFF14141F),
      title: Text(
        '切换播放源',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: Color(0xFFF0F0F5),
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 240,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          controller: _scrollController,
          child: Row(
            children: [
              for (var index = 0; index < widget.sources.length; index++)
                Padding(
                  padding: EdgeInsets.only(
                    right: index < widget.sources.length - 1
                        ? AppSpacing.md
                        : 0,
                  ),
                  child: _SourceSelectorCard(
                    key: _itemKeys[index],
                    source: widget.sources[index],
                    selected: index == widget.currentIndex,
                    rank: index + 1,
                    formatSpeed: widget.formatSpeed,
                    speedColor: widget.speedColor,
                    onTap: () => widget.onSelect(index),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SourceSelectorCard extends StatelessWidget {
  final SourceOption source;
  final bool selected;
  final int rank;
  final String Function(double?) formatSpeed;
  final Color Function(double?) speedColor;
  final VoidCallback onTap;

  const _SourceSelectorCard({
    super.key,
    required this.source,
    required this.selected,
    required this.rank,
    required this.formatSpeed,
    required this.speedColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final speedText = formatSpeed(source.speed);
    final resolutionText = source.resolution?.trim() ?? '';

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadius.sm),
      child: SizedBox(
        width: 140,
        child: AspectRatio(
          aspectRatio: 2 / 3,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AppRadius.sm),
                child: CachedNetworkImage(
                  imageUrl: source.poster?.isNotEmpty == true
                      ? source.poster!
                      : '',
                  fit: BoxFit.cover,
                  cacheManager: HainTvCacheManager(),
                  memCacheWidth: 300,
                  memCacheHeight: 450,
                  placeholder: (_, __) => Container(color: Color(0xFF14141F)),
                  errorWidget: (_, __, ___) => Container(
                    color: Color(0xFF14141F),
                    child: Center(
                      child: Text(
                        source.title.isNotEmpty
                            ? source.title.substring(0, 1)
                            : '',
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 24,
                          color: Color(0xFF6B7280),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 底部彩色背景 + 标题/源名
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: ClipRRect(
                  borderRadius: BorderRadius.vertical(
                    bottom: Radius.circular(AppRadius.sm),
                  ),
                  child: Container(
                    padding: EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: Color(0xFF1C1C2E).withValues(alpha: 0.95),
                      border: Border(
                        top: BorderSide(
                          color: AppColors.primary.withValues(alpha: 0.6),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          source.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFF0F0F5),
                            height: 1.2,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          source.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                            color: AppColors.primary,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              // 排名标识
              Positioned(
                top: 6,
                left: 6,
                child: Container(
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Color(0xFF1C1C2E).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    'No.$rank',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      color: AppColors.primary,
                    ),
                  ),
                ),
              ),
              if (speedText.isNotEmpty)
                Positioned(
                  top: 6,
                  right: 6,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: speedColor(source.speed),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      speedText,
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFF0F0F5),
                      ),
                    ),
                  ),
                ),
              if (resolutionText.isNotEmpty)
                Positioned(
                  top: speedText.isNotEmpty ? 28 : 6,
                  right: 6,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      resolutionText,
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFF0A0A0F),
                      ),
                    ),
                  ),
                ),
              if (selected)
                Positioned(
                  top: 28,
                  left: 6,
                  child: Icon(
                    Icons.check_circle,
                    color: AppColors.primary,
                    size: 20,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EpisodeSelectorDialog extends StatefulWidget {
  final List<String> titles;
  final int currentIndex;
  final ValueChanged<int> onSelect;

  const _EpisodeSelectorDialog({
    required this.titles,
    required this.currentIndex,
    required this.onSelect,
  });

  @override
  State<_EpisodeSelectorDialog> createState() => _EpisodeSelectorDialogState();
}

class _EpisodeSelectorDialogState extends State<_EpisodeSelectorDialog> {
  late final ScrollController _scrollController;
  final _selectedKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _selectedKey.currentContext;
      if (ctx != null) {
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: Duration(milliseconds: 200),
        );
      }
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Color(0xFF14141F),
      title: Text(
        '选集',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: Color(0xFFF0F0F5),
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        height: 360,
        child: GridView.count(
          controller: _scrollController,
          crossAxisCount: 4,
          crossAxisSpacing: AppSpacing.md,
          mainAxisSpacing: AppSpacing.md,
          childAspectRatio: 2.2,
          children: List.generate(widget.titles.length, (index) {
            final selected = index == widget.currentIndex;
            return InkWell(
              key: selected ? _selectedKey : null,
              onTap: () => widget.onSelect(index),
              borderRadius: BorderRadius.circular(AppRadius.md),
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? AppColors.primaryTint
                      : Color(0xFF1C1C2E),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: selected ? AppColors.primary : Color(0x14FFFFFF),
                  ),
                ),
                child: Text(
                  widget.titles[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: selected ? AppColors.primary : Color(0xFFF0F0F5),
                  ),
                ),
              ),
            );
          }),
        ),
      ),
    );
  }
}
