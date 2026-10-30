import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/services/playback_activity.dart';
import 'package:hain_tv/models/skip_segment.dart';
import 'package:hain_tv/models/video_detail.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/player/mpv_desktop_backend.dart';
import 'package:hain_tv/player/vlc_backend.dart';
import 'package:hain_tv/player/video_player_backend.dart';
import 'package:hain_tv/player/switch_gate.dart';
import 'package:hain_tv/services/ad_filter_engine.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';
import 'package:hain_tv/widgets/tv/skip_config_dialog.dart';
import 'package:hain_tv/platform/device_utils.dart';

class PlayerScreen extends StatefulWidget {
  final VideoDetail videoDetail;
  final int episodeIndex;
  final List<SourceOption>? sources;
  final ValueNotifier<List<SourceOption>>? sourcesNotifier;
  final int initialSourceIndex;
  final PlayerBackendType playerBackend;
  final int initialPositionMs;

  PlayerScreen({
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
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> {
  /// 是否已发起退出播放，防止连续按返回触发多次 pop（会导致退出到错误页面）。
  bool _exitingPlayer = false;

  late VideoDetail _currentVideoDetail;
  late int _currentSourceIndex;
  // 记录进入播放页时详情页选中的源标识，用于 sourcesNotifier 更新后
  // 仍能准确找回当前源，避免仅依赖 VideoDetail 的 source/id 匹配失败
  // 导致播放源被重置到列表首位。
  String? _initialSourceKey;
  VideoPlayerBackend? _backend;
  final PlayerSwitchGate _switchGate = PlayerSwitchGate();
  late int _currentEpisodeIndex;
  bool _controlsVisible = true;

  /// 🔴🔴 键盘返回键的「已消费」时间戳（2026-10-17）。
  ///
  /// 【为什么需要】同一个遥控器返回键会**依次**触发两条路径：
  ///   ① `Focus.onKeyEvent` → `_handleKeyEvent` 的 `goBack/escape` 分支
  ///      → 控制栏可见时 `_hideControls()`，返回 `KeyEventResult.handled`；
  ///   ② 紧接着系统返回事件 → `PopScope.onPopInvokedWithResult`。
  ///
  /// ①把 `_controlsVisible` 置为 false 后，②读到的已经是 false，于是判定
  /// 「控制栏已隐藏 ⇒ 再按一次 ⇒ 退出播放」，**直接退出了播放页**。
  ///
  /// 现场证据（真机 XiaoPaiTech BA001 2026101711）：
  ///     11:37:50.305  隐藏控制栏: _controlsVisible=true
  ///     11:37:50.305  按键: ..., 控制栏可见=false
  ///     11:37:51.136  LocalM3u8Proxy stopped          ← 0.8s 后就退出了
  /// 用户观感即「有控制栏时按返回键，错误的退出播放」。
  ///
  /// 【修法】① 消费掉返回键时记下时刻，②在窗口期内直接忽略 —— 一次物理
  /// 按键只应产生一次行为。窗口取 250ms：系统返回事件紧随键盘事件到达
  /// （实测同一毫秒级），250ms 足够覆盖且不会误吞「用户真的又按了一次」。
  DateTime? _lastBackKeyHandledAt;
  static const Duration _kBackKeyDedupWindow = Duration(milliseconds: 250);
  bool _playing = true;

  /// 🔴 2026-10-29 真机复盘：退到后台时自动暂停、回前台自动恢复。
  AppLifecycleListener? _lifecycleListener;

  /// 标记「这次暂停是我们自己在后台发起的」，回前台才恢复，避免误恢复用户手动暂停的播放。
  bool _pausedByLifecycle = false;
  Duration _position = Duration.zero;

  /// 🔴 2026-10-17：起播精确定位的**观测埋点**（纯日志，不参与任何判定）。
  ///
  /// 【为什么只是埋点】曾经想用它去"暂缓片头跳过"和"拦住播放记录写入"，
  /// 但这两条都被证伪：
  ///   · 跳过片头本身是**正确**行为 —— 从 0 播到片头结束就该跳过去，
  ///     拿它去卡片头跳过反而会让正常跳转失效；
  ///   · 换源瞬间 `_position` 是可信的（真机：源1 心跳 240.956s →
  ///     换源 open startAt=243.796s，吻合），无需用目标值兜底。
  ///
  /// 保留它是因为「定位到底有没有落地」是排查起播偏位的核心事实，
  /// 落没落地必须能在日志里看到。
  int _pendingStartTargetMs = 0;
  DateTime? _pendingStartAt;

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

  /// mpv 这类 requiresEagerMount 后端的常驻视频层实例。
  ///
  /// 🔴 为什么不复用默认路径：mpv 的原生实例随 PlatformView 创建，而 `open()`
  ///    要等该 view 的 id。若 `_buildVideo()` 用 `_initialized` 早退拦住挂载，
  ///    就形成 `open 等 view → view 等 _initialized → _initialized 等 open`
  ///    的闭环死锁（主工程移动版已因此踩坑，真机实测卡满 5 秒后抛超时）。
  ///    故对 eager 后端必须**常驻挂载**并复用同一 widget 实例，
  ///    避免 setState 触发 PlatformView 重建、mpv 实例被销毁而画面中断。
  Widget? _eagerVideoLayer;

  /// 上一次上报给壳的视频层物理像素尺寸（避免每帧重复下发）。
  int _reportedViewW = 0;
  int _reportedViewH = 0;

  /// 「就绪后再定位」定时器：起播慢的后端在 open 返回时 `_duration` 仍为 0，
  /// 此时若用 `_duration` 给续播恢复点做上限钳制，恢复点会被压成 0 ——
  /// 新后端便从头播放。等时长上报后再 seek 到恢复点。
  Timer? _initialPositionRestoreTimer;

  /// 「就绪后再定位」：见 [_initialPositionRestoreTimer]。
  ///
  /// open() 成功但时长未就绪时，续播恢复点不能被钳成 0（=从头播）。
  /// 这里每 300ms 轮询时长，一旦拿到有效时长就定位到恢复点；
  /// 超过 30 秒仍未就绪则放弃定位（绝不阻断播放）。
  static const Duration _kInitialPositionRestoreTimeout = Duration(seconds: 30);

  void _scheduleInitialPositionRestore() {
    _initialPositionRestoreTimer?.cancel();
    final targetMs = _pendingInitialPositionMs;
    final deadline = DateTime.now().add(_kInitialPositionRestoreTimeout);
    _initialPositionRestoreTimer = Timer.periodic(
      const Duration(milliseconds: 300),
      (t) {
        if (!mounted || _backend == null) {
          t.cancel();
          _initialPositionRestoreTimer = null;
          return;
        }
        final durMs = _duration.inMilliseconds;
        if (durMs > 0) {
          t.cancel();
          _initialPositionRestoreTimer = null;
          final maxMs = durMs > 500 ? durMs - 500 : durMs;
          final clampedMs = targetMs.clamp(0, maxMs);
          _seekTo(Duration(milliseconds: clampedMs), showControls: false);
          debugPrint(
            '[HeinPlay] 就绪后定位到恢复点: ${clampedMs}ms（时长=${durMs}ms）',
          );
          _pendingInitialPositionMs = 0;
          return;
        }
        if (DateTime.now().isAfter(deadline)) {
          t.cancel();
          _initialPositionRestoreTimer = null;
          debugPrint(
            '[HeinPlay] 恢复点定位超时（时长始终未就绪），放弃定位: ${targetMs}ms',
          );
          _pendingInitialPositionMs = 0;
        }
      },
    );
  }

  /// 把视频层控件的**物理像素**尺寸上报给桌面 mpv 壳。
  ///
  /// 🔴 壳用该尺寸创建 FBO，mpv 才会在其内部按 video-params 做 letterbox。
  ///    若壳按 video-out-params（视频尺寸）建 FBO，mpv 输出的画面就没有黑边、
  ///    恰为视频原始比例，Flutter 拉伸铺满竖屏即比例失真，且 keepaspect/
  ///    panscan 完全失效 —— 这正是 69 真机点播画面比例不对的根因。
  void _reportVideoViewSize(BoxConstraints constraints) {
    final backend = _backend;
    if (backend is! MpvDesktopBackend) return;
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final w = (constraints.maxWidth * dpr).round();
    final h = (constraints.maxHeight * dpr).round();
    if (w <= 0 || h <= 0) return;
    if (w == _reportedViewW && h == _reportedViewH) return;
    _reportedViewW = w;
    _reportedViewH = h;
    // 🔴 2026-10-21 诊断：确认 FBO 尺寸是否被算得过大。
    //    69 物理屏 1080x1920，若这里报出 2880x1526（=4.4M 像素，
    //    是屏幕的 2.2 倍），说明逻辑尺寸/DPR 取值有问题，
    //    白白让 mpv 每帧渲染 2 倍以上的像素 —— 直接导致幻灯片。
    debugPrint('[MPV-DIAG] 视频层尺寸上报 ${w}x$h '
        '(逻辑 ${constraints.maxWidth.toStringAsFixed(1)}x'
        '${constraints.maxHeight.toStringAsFixed(1)} dpr=$dpr)');
    backend.updateViewSize(w, h);
  }

  /// mpv 画面所在的 Flutter 外部纹理 id（原生经事件通道首条消息回传）。
  int? _mpvTextureId;
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

  // ── seek 意图基准（修复「快进快退进度条往后偏移，越往后越偏」）────────────
  //
  // 🔴 这是**独立于历史 PTS 归一化修复**的另一条缺陷链，此前从未修过。
  //    （历史几次修复针对的是「mpv time-pos 走真实 PTS 轴、duration 走去广告
  //      名义轴」的比例性偏差，那个已由 PTS 归一化解决；本次是 seek 基准漂移。）
  //
  // 真机日志铁证（XiaoPaiTech BA001，2026101522）：
  //   用户在约 20 秒内连按快进快退，mpv `time-pos` 事件流为
  //     1115.04 → 1142.28(+27.24) → 1211.68(+67.96) → 1186.60(-25.12)
  //            → 1147.84(-38.76) → 1096.12(-51.80)
  //   —— 一次 HLS seek 期间，mpv 会**连续推送多个中间落点**，最终值才稳定。
  //
  // 缺陷：`_seekBy()` 用 `_position + delta` 计算目标，而 `_position` 是
  //   `positionStream` 直接赋值的**裸值**，正处于上述抖动中。于是每次按键的
  //   基准点都不同，误差在连续操作中**累积** ⇒ 进度条越走越偏。
  //
  // 修法：维护一个「最近的 seek 意图位置」及其时间戳。在合理的时间窗内，
  //   `_seekBy` 以意图位置为基准而非抖动的 `_position`；窗口过后自动回落到
  //   `_position`（保证正常播放时基准仍跟随真实进度）。
  Duration? _lastSeekIntent;
  DateTime? _lastSeekIntentAt;

  /// seek 意图的有效期。真机 32 位机顶盒完成一次 HLS seek 通常数百毫秒，
  /// 取 2 秒足以覆盖「连按」节奏，又不会在停止操作后长期压住真实位置。
  static const Duration _seekIntentTtl = Duration(seconds: 2);

  late final FocusScopeNode _bottomControlsFocusNode;
  late final FocusNode _playPauseFocusNode;
  late final FocusNode _skipFocusNode;
  late final FocusNode _rootFocusNode;

  // 标记是否有弹窗打开，打开时禁止控制栏自动隐藏，避免焦点丢失。
  bool _dialogOpen = false;

  // 触摸手势状态
  bool _gestureIndicatorVisible = false;
  String _gestureIndicatorText = '';
  IconData _gestureIndicatorIcon = Icons.touch_app;
  Timer? _gestureIndicatorTimer;
  bool _isLongPressSeeking = false;
  String _longPressDirection = 'right';
  double _currentBrightness = 0.5;
  double _currentVolume = 0.5;
  double _gestureStartBrightness = 0.5;
  double _gestureStartVolume = 0.5;
  Offset? _gestureStartPosition;
  double _cumulativeDeltaY = 0.0;
  double _cumulativeDeltaX = 0.0;
  static const double _verticalGestureSensitivity = 0.005;
  static const double _horizontalGestureSensitivity = 0.5;

  /// 最近一次切换集数/源的时间，用于跳过片头片尾时避免初始化阶段位置抖动。
  DateTime? _episodeSwitchAt;

  List<SourceOption> get _sources =>
      widget.sourcesNotifier?.value ?? widget.sources ?? [];
  bool get _canSwitchSource => _sources.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // 🔴 2026-10-29 真机复盘（真机日志 22:58:46~56 复现「切后台回来后画面卡死」）：
    //   mpv 在应用退到后台后仍继续解码 + 渲染，会持续吃 CPU；而系统此时正要
    //   销毁并重建 Flutter 的窗口 surface。CPU 被抢占 ⇒ 回前台后第一帧迟迟
    //   提交不出来（实测铁证：`E EGL_emulation: eglSurfaceAttrib(1504):
    //   error 0x3009 (EGL_BAD_MATCH)`、`E FrameEvents: updateAcquireFence: Did
    //   not find frame.`、`E SurfaceSyncGroup: Failed to receive transaction
    //   ready in 1000ms`）⇒ 整窗不再出帧 ⇒ 用户看到画面停在最后一帧 = 卡死。
    //   修法：退后台暂停播放（省 CPU、也避免往即将失效的 surface 继续写），
    //   回前台恢复（只恢复我们自己暂停的那一次）。
    _lifecycleListener = AppLifecycleListener(
      onPause: () {
        if (!_playing) return;
        _pausedByLifecycle = true;
        unawaited(_backend?.pause() ?? Future<void>.value());
        debugPrint('PlayerScreen: 应用退到后台，已暂停播放');
      },
      onResume: () {
        if (!_pausedByLifecycle) return;
        _pausedByLifecycle = false;
        unawaited(_backend?.play() ?? Future<void>.value());
        debugPrint('PlayerScreen: 应用回到前台，已恢复播放');
      },
    );
    _bottomControlsFocusNode = FocusScopeNode();
    _playPauseFocusNode = FocusNode(debugLabel: 'playPause');
    _skipFocusNode = FocusNode(debugLabel: 'skip');
    _rootFocusNode = FocusNode(debugLabel: 'playerRoot');
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
    // 若传入的后端在当前平台不可用，回退到平台默认。
    if (!PlayerBackendFactory.availableBackends.contains(
      _currentPlayerBackend,
    )) {
      _currentPlayerBackend = PlayerBackendFactory.platformDefault;
    }
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
    if (!DeviceUtils.isDesktop) {
      _initBrightnessAndVolume();
    }
    _startClock();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
      }
    });
  }

  Future<void> _initWakelock() async {
    try {
      await WakelockPlus.enable();
      debugPrint('PlayerScreen: 已启用屏幕常亮');
    } catch (e) {
      debugPrint('PlayerScreen: 启用屏幕常亮失败: $e');
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
      debugPrint('PlayerScreen: 当前亮度 $_currentBrightness');
    } catch (e) {
      debugPrint('PlayerScreen: 获取亮度失败: $e');
      _currentBrightness = 0.5;
    }
    _gestureStartBrightness = _currentBrightness;

    try {
      _currentVolume = await VolumeController.instance.getVolume();
      debugPrint('PlayerScreen: 当前音量 $_currentVolume');
    } catch (e) {
      debugPrint('PlayerScreen: 获取音量失败: $e');
      _currentVolume = 0.5;
    }
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

  /// 订阅 mpv 的纹理就绪流：拿到 textureId 后重建视频层，让
  /// `Texture(textureId)` 出画。非 mpv 后端直接跳过。
  ///
  /// 🔴 纹理 id 由原生**异步**经事件通道回传，而 PlatformView 必须先挂载
  ///    才会创建、纹理才会注册，所以顺序必须是「挂载 → 等 textureId → setState 重建」。
  void _attachMpvTextureListener(dynamic backend) {
    // 🔴🔴 2026-10-21 点播黑屏真因（78 真机日志实锤）：
    //    原实现是 `if (backend is! MpvBackend) return;`。
    //    但 Linux 桌面走 main.dart → HainTvApp（TV 版页面），后端由工厂返回的是
    //    **MpvDesktopBackend**（桌面 C++ 壳），它和 MpvBackend（Android Kotlin/JNI）
    //    都只是 `implements VideoPlayerBackend`，彼此**没有继承关系**，
    //    所以 `backend is! MpvBackend` 恒为 true → 函数一进来就 return →
    //    textureReadyStream 从未订阅 → _mpvTextureId 恒 null →
    //    `Texture(textureId:)` 那层永不构建 → Flutter 不来采样（populate=0）→
    //    壳侧渲染帧一路涨、share_ok=yes、FBO 无错，但用户只看到黑屏 + 有声音。
    //    改法同直播页 live_player.dart：只认「是否暴露 textureReadyStream」这个能力。
    Stream<int>? stream;
    try {
      final dynamic dyn = backend;
      final Object? s = dyn.textureReadyStream;
      if (s is Stream<int>) stream = s;
    } catch (_) {
      stream = null;
    }
    debugPrint('[MPV-DIAG] TV attach backend=${backend.runtimeType} '
        'stream=${stream == null ? "null" : "ok"}');
    if (stream == null) return;
    _subscriptions.add(
      stream.listen((tid) {
        if (!mounted) return;
        debugPrint('TV 播放页收到 mpv textureId=$tid，重建视频层出画');
        setState(() => _mpvTextureId = tid);
      }),
    );
    // 时序兜底：init 通常早于本监听建立，那一帧事件已丢，订阅后主动读一次当前值。
    try {
      final dynamic dyn = backend;
      final Object? cur = dyn.currentTextureId;
      if (cur is int && cur >= 0) {
        debugPrint('TV 播放页补取 mpv textureId=$cur（监听建立时已有）');
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          setState(() => _mpvTextureId = cur);
        });
      }
    } catch (_) {}
  }

  /// [autoOpen] 为 true 时，建好后端后立即起播当前集（首播路径）。
  ///
  /// 🔴 2026-10-23：切集路径需要「只重建后端、不自动起播」，
  ///   否则会与 [_openEpisodeImpl] 形成递归（建后端 → 起播 → 释放后端 → 重建 → …）。
  Future<void> _initBackend({bool autoOpen = true}) async {
    final backend = PlayerBackendFactory.create(_currentPlayerBackend);
    _backend = backend;
    _backend?.fit = _videoFit;
    // 🔴 换后端必须丢弃旧的 eager 视频层缓存，否则会继续渲染已被 dispose 的
    //    上一个后端 widget，画面永远出不来。
    _eagerVideoLayer = null;
    _mpvTextureId = null;
    _attachMpvTextureListener(backend);
    _subscriptions
      ..add(
        backend.positionStream.listen((position) {
          _reportBufferHealth(position);
          if (mounted) {
            setState(() => _position = position);
            _maybeClearPendingStartPosition(position);
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
      );

    // 🔴 2026-10-23：首播必须带 isFirstOpen —— 后端刚由本方法建好，
    //   若 _openEpisodeImpl 走「切集释放」分支会把它置空，
    //   `_backend?.open(...)` 被 ?. 短路，open() 根本不执行，
    //   表现为「尝试播放」后直接超时、屏幕上无任何画面。
    if (autoOpen) {
      await _openEpisodeImpl(_currentEpisodeIndex, isFirstOpen: true);
    }
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
    _seekTo(Duration(milliseconds: targetMs), showControls: false);
  }


  /// 🔴 2026-10-17：观测「起播精确定位是否真正落地」，只打日志，不改变行为。
  ///
  /// 【为什么要看这个】起播偏位的排查全靠这一条事实：
  ///   目标 243.796s，位置第几秒才真正到达 243.796？
  /// 真机（XiaoPaiTech BA001 2026101719 源2）的教训：
  ///   `补 seek absolute` 下发后心跳直接是 `105.579`，说明 seek **没生效**；
  ///   而源3 同样代码却精确落在 426.440 —— 差别只能从落地情况上看出来。
  static const int kPendingStartToleranceMs = 3000;
  static const Duration kPendingStartObserveWindow = Duration(seconds: 8);

  /// 🔴 2026-10-23（荣耀平板 V8 Pro 真机日志实证）：起播定位的**硬上限**。
  ///
  /// 真机现场（2026-10-23 14:58 手机版换源到 zuidazy.co）：
  /// ```
  ///   14:58:15.563 open url → 14:58:27.627 mpv FILE_LOADED（**12.07 秒**）
  /// ```
  /// 慢源的本地代理要先展开 master（下载 5344ms）再预取首片，
  /// mpv 拿到 file-loaded 天然会超过 8 秒观测窗。
  ///
  /// 原实现只要「超过 8 秒」就断言 seek 失败并解除片头跳过守卫，
  /// 于是在 file-loaded 的 seek **即将落地**（实测只差 130ms）时抢先判负：
  /// ```
  ///   14:58:27.846 file-loaded 立即 seek rc=0
  ///   14:58:27.855 ⚠️ 起播定位未落地（超时）  ← 抢跑 9ms
  ///   14:58:27.986 起播 seek 已落地 pos=431.960s ← 实际是成功的
  /// ```
  /// 后果：① 片头跳过守卫被误解除 → 画面被拉回片头（实测 time-pos=91.023s）；
  ///       ② 紧接其后的播放记录保存用 position=0 覆盖了切换前保存的 431s。
  ///
  /// 修正：超时判定必须建立在「**播放器确实跑起来了**」之上 ——
  /// 位置流仍为 0 只说明「还在加载/未起播」，此时断言「seek 未生效」是错的。
  /// 位置流一旦非零（播放器在跑却没 seek 到目标）才判定超时；
  /// 硬上限只作兜底，防止播放器始终起不来时永久屏蔽片头跳过。
  static const Duration kPendingStartHardTimeout = Duration(seconds: 60);

  void _maybeClearPendingStartPosition(Duration position) {
    final target = _pendingStartTargetMs;
    if (target <= 0) return;
    final posMs = position.inMilliseconds;
    final reached = (posMs - target).abs() <= kPendingStartToleranceMs;
    final elapsed = _pendingStartAt == null
        ? Duration.zero
        : DateTime.now().difference(_pendingStartAt!);
    // 🔴 超时前提：播放器已经跑起来（位置流非零）。
    //    位置恒为 0 时只是「还在加载」，不能断言 seek 失败。
    final timedOut = elapsed > kPendingStartObserveWindow &&
        (posMs > 0 || elapsed > kPendingStartHardTimeout);
    if (reached) {
      _pendingStartTargetMs = 0;
      _pendingStartAt = null;
      debugPrint('起播定位已落地：position=${posMs}ms target=${target}ms');
    } else if (timedOut) {
      _pendingStartTargetMs = 0;
      _pendingStartAt = null;
      debugPrint(
        '⚠️ 起播定位未落地（超时）：position=${posMs}ms target=${target}ms '
        '偏差=${posMs - target}ms —— seek 未生效，播放器停在了别处',
      );
    }
  }

  void _checkSkipSegments(Duration position) {
    // 刚切换集数/源的前 2 秒内不处理跳过/自动下一集，避免初始化阶段位置抖动导致误触发。
    final switchAt = _episodeSwitchAt;
    if (switchAt != null &&
        DateTime.now().difference(switchAt) < Duration(seconds: 2)) {
      return;
    }

    // 🔴🔴🔴 2026-10-18：起播定位**尚未落地**时，不得参与跳过片头。
    //
    //   真机铁证（XiaoPaiTech BA001 2026101816，起播目标 317000ms）：
    //     16:27:40.836 触发跳过片段: type=opening start=0.0 end=105.279
    //     16:27:41.790 心跳 time-pos=105.579
    //   105.579 = 105.279 + 0.3 —— 与本函数 `_safeSeekToSeconds(end + 0.3)`
    //   **逐位吻合**，证明播放器确实被这次自动跳过拉到了片头结束处。
    //
    //   为什么会发生：起播瞬间 position 流仍上报 0（真实位置 317s 还没建立），
    //   0 必然落在片头区间 [0, 105.279] 内 ⇒ 立即触发自动跳过。
    //   这一次 seek 会让原生侧把 `userSeeked` 置 true（rc==0），
    //   于是**起播精确定位的补 seek 被永久跳过** ⇒ 播放器停在片头。
    //
    //   ⚠️ 这不是禁用跳过片头（用户明确要求保留该功能）：
    //     · 从头播放（无续播点）⇒ _pendingStartTargetMs == 0 ⇒ 照常跳过 ✅
    //     · 从播放记录恢复（317s）⇒ 落地后 position=317s 本就不在片头区间
    //       ⇒ 也不会触发 ✅
    //   唯一的差别是「不在起播暂态期间做判断」，属**排序修正**而非功能阉割。
    //   兜底：_pendingStartTargetMs 有 8 秒观测窗（kPendingStartObserveWindow），
    //   超时会自动清零，不会永久屏蔽片头跳过。
    if (_pendingStartTargetMs > 0) {
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

  /// 等待播放器报告有效时长，超时返回 false。
  /// 等待播放真正就绪。
  ///
  /// 🔴🔴 2026-10-21 修复「点播第二次变成播放失败 / 直播一直转圈」：
  ///    原实现**只认 `_duration > 0`** 这一个信号。但 duration 是 mpv 回报的
  ///    时长，HLS(m3u8) 源在软渲染/弱网环境下经常回报不出来或回报很晚——
  ///    78 日志实测：壳侧「渲染帧 #121→#541」持续增长、populate share_ok=yes，
  ///    画面**确实在正常播放**，可 Dart 侧却打出「等待播放就绪超时」并判失败，
  ///    于是触发换源；换源又超时，循环下去就表现为「播放失败」或一直转圈。
  ///    也就是说：**画面没问题，是就绪判据错了。**
  ///
  ///    现在改为任一条件成立即视为就绪：
  ///      ① 拿到有效 duration（原逻辑，最可靠）
  ///      ② 拿到纹理 id 且 mpv 已在推进播放进度（position 变化）
  ///         —— 有画面且时间在走，等价于「已经在放了」，无需死等 duration。
  Future<bool> _waitForPlayerReady(Duration timeout) async {
    if (_duration.inMilliseconds > 0) return true;
    final start = DateTime.now();
    final startPosition = _position;
    var sawPositionAdvance = false;
    while (DateTime.now().difference(start) < timeout) {
      if (_duration.inMilliseconds > 0) return true;
      // ② 画面已在推进：有纹理 + 播放进度相对起播前发生了变化。
      if (_mpvTextureId != null && _position != startPosition) {
        sawPositionAdvance = true;
        debugPrint(
          'PlayerScreen 就绪判据②命中：duration 未回报但进度已在推进 '
          '(${startPosition.inMilliseconds}ms → ${_position.inMilliseconds}ms)，'
          '判定为就绪',
        );
        return true;
      }
      await Future.delayed(Duration(milliseconds: 200));
    }
    if (sawPositionAdvance) return true;
    return _duration.inMilliseconds > 0;
  }

  Future<void> _openEpisode(int index) =>
      _switchGate.run(() => _openEpisodeImpl(index));

  Future<void> _openEpisodeImpl(int index, {bool isFirstOpen = false}) async {
    final episodes = _currentVideoDetail.episodes;
    if (index < 0 || index >= episodes.length) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

    // 🔴 切集：先停止播放、保存播放记录、释放旧后端，再加载新集。
    //    首次进入播放页（_initBackend → 本方法）时 _backend 为 null，
    //    helper 会自动退化为空操作，无需调用方区分。
    if (!isFirstOpen) {
      // 🔴🔴 桌面端：复用同一个后端实例切集（只换 URL）——
      //   不关壳 → 纹理 id 不变 → 视频层不重建 → **不闪屏**；
      //   也不与新实例抢渲染线程 → **不卡死**。
      final reuseBackend = _reuseDesktopBackend;
      await _stopSaveAndReleaseBackend(keepBackend: reuseBackend);
      if (reuseBackend) {
        debugPrint('[HeinPlay] 桌面端切换集：复用后端实例（不重建，避免闪屏/卡死）');
      } else {
        debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');
      }
      // 🔴 2026-10-23 修复：切集必须清零上一集的续播位置。
      //   播放记录是「每部剧一条」（含 index=集号、playTime=该集秒数），
      //   上一集的位置套到新集上会直接落在错误的时间点（用户实测：记录错乱）。
      _pendingInitialPositionMs = 0;
      debugPrint('[HeinPlay] 切换集：目标 index=$index，续播位置已归零（避免沿用上一集）');
      if (!reuseBackend) {
        // 🔴 2026-10-23 修复：释放后必须重建后端。
        //    _stopSaveAndReleaseBackend 会把 _backend 置 null，而下面 tryOpen 用的是
        //    `_backend?.open(...)` —— _backend 为 null 时 Dart 的 ?. 直接短路，
        //    open() 根本不会被调用，tryOpen 只能轮询 _duration 到超时 →
        //    每次切集白等 15 秒后判失败（用户实测：加载反而变慢、记录读不出来）。
        //    autoOpen:false = 只重建后端，不在此递归触发起播。
        await _initBackend(autoOpen: false);
      }
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

    // 先加载跳过配置，确保打开播放器前已知片头片尾区间，
    // 避免异步加载完成前错过 startAt 定位时机。
    await _loadSkipConfig();

    final timeoutSeconds = await UserDataService.getAutoSwitchSourceTimeout();
    final openTimeout = Duration(seconds: timeoutSeconds);

    Future<bool> tryOpen(String url, {int initialPositionMs = 0}) async {
      final startTime = DateTime.now();
      // 观测埋点：记录本次起播的定位目标，落地/超时由 _maybeClearPendingStartPosition 记日志。
      if (initialPositionMs > 0) {
        _pendingStartTargetMs = initialPositionMs;
        _pendingStartAt = DateTime.now();
        debugPrint('起播定位已登记 target=${initialPositionMs}ms');
      }
      try {
        debugPrint('PlayerScreen 尝试播放 [$_currentPlayerBackend]: $url');
        await _backend
            ?.open(
              url,
              proxyMode: _currentVideoDetail.proxyMode,
              startAt: initialPositionMs > 0
                  ? Duration(milliseconds: initialPositionMs)
                  : null,
            )
            .timeout(openTimeout);

        // 🔴 2026-10-23：桌面端复用同一实例换源时，显式把播放态拉回来。
        //   mpv 的 pause 是持久属性，native open 只做 loadfile，不会复位 pause；
        //   一旦残留 pause=yes，新源会停在首帧不动。play() 幂等（set pause no）。
        if (_reuseDesktopBackend) {
          await _backend?.play();
        }

        // 等待播放器真正就绪（获取到有效时长），总耗时不超过 openTimeout
        final elapsed = DateTime.now().difference(startTime);
        final remaining = openTimeout - elapsed;
        final ready = remaining > Duration.zero
            ? await _waitForPlayerReady(remaining)
            : _duration.inMilliseconds > 0;
        if (!ready) {
          debugPrint('PlayerScreen 等待播放就绪超时 [$_currentPlayerBackend]');
          return false;
        }

        debugPrint('PlayerScreen 播放初始化成功 [$_currentPlayerBackend]');
        return true;
      } catch (e, stackTrace) {
        debugPrint('PlayerScreen 播放失败 [$_currentPlayerBackend]: $url');
        debugPrint('错误: $e');
        debugPrint('$stackTrace');
        if (e is StateError && e.message.isNotEmpty) {
          _error = e.message;
        }
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

    // 对 M3U8 地址应用本地去广告过滤
    final filteredUrl = await AdFilterEngine.filterM3u8(
      sourceType: _currentVideoDetail.source,
      originalUrl: url,
      // 🔴 把起播位置告诉探测逻辑：源 PTS 轴错乱的取样点应落在用户真正要看的
      //   那一段附近，而不是播放列表开头。只探测开头会漏判后段才有的错乱。
      probeAtMs: _pendingInitialPositionMs > 0 ? _pendingInitialPositionMs : null,
    );
    if (filteredUrl != null && filteredUrl.isNotEmpty) {
      url = filteredUrl;
    }

    // 若已配置自动跳过片头，且待恢复位置落在片头区间内，
    // 则直接从片头结束处开始播放，避免初始化完成后再 seek 失效。
    final openingSegment = _skipConfig?.segments
        .where((s) => s.type == 'opening' && s.autoSkip)
        .firstOrNull;
    if (openingSegment != null) {
      final startMs = (openingSegment.start * 1000).toInt();
      final endMs = (openingSegment.end * 1000).toInt();
      if (_pendingInitialPositionMs >= startMs &&
          _pendingInitialPositionMs <= endMs) {
        _pendingInitialPositionMs = endMs;
        _skippedSegments.add(
          '${openingSegment.type}_${openingSegment.start}_${openingSegment.end}',
        );
        debugPrint('PlayerScreen 片头起始定位: ${openingSegment.end}s');
      }
    }

    bool success = await tryOpen(
      url,
      initialPositionMs: _pendingInitialPositionMs,
    );

    if (!mounted) return;

    // 如果超时判定失败，但当前源实际已就绪（ duration 有效），修正为成功，
    // 避免初始化较慢的源已经开始播放却仍显示“播放失败”。
    if (!success &&
        _backend != null &&
        _duration.inMilliseconds > 0 &&
        _error == null) {
      debugPrint('PlayerScreen 当前源已就绪，修正超时判定为成功');
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
      // 🔴 2026-10-16：原「fvp 后端跳过本段」的特判已删除（fvp 已摘除）。
      //   历史背景：fvp 的起点定位由 VideoPlayerBackendImpl 在 initialize() 后立即
      //   执行，若此处再赶在 open 后 ~200ms 抢先 seek，会把 libmdk 打进冻结
      //   （2026-09-20 17:20 日志实证）。该缺陷属 libmdk 专有，mpv/exo/vlc 无此问题，
      //   故不再需要后端特判。
      if (_pendingInitialPositionMs > 0) {
        // 🔴🔴 2026-10-23：时长未就绪时**不能**把恢复点钳成 0，否则从头播放。
        final durMs = _duration.inMilliseconds;
        if (durMs <= 0) {
          debugPrint(
            '[HeinPlay] 恢复点待定位（时长未就绪）: ${_pendingInitialPositionMs}ms',
          );
          _scheduleInitialPositionRestore();
        } else {
          final maxMs = durMs > 500 ? durMs - 500 : durMs;
          final clampedMs = _pendingInitialPositionMs.clamp(0, maxMs);
          await Future.delayed(Duration(milliseconds: 200));
          if (mounted) {
            _seekTo(Duration(milliseconds: clampedMs), showControls: false);
          }
          debugPrint(
            '[HeinPlay] 已定位到恢复点: ${clampedMs}ms（时长=${durMs}ms）',
          );
          _pendingInitialPositionMs = 0;
        }
      }
      _showControlsWithoutFocusShift();
    } else if (autoSwitchSource && _sources.length > 1) {
      // 自动换源开启且有其他源时，按设置时间延迟后尝试下一个源。
      // 若已有具体错误信息，优先保留。
      final hasSpecificError = _error != null && _error!.isNotEmpty;
      setState(() {
        if (!hasSpecificError) {
          _error = '播放失败，即将进行自动换源';
        }
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
            if (_error == null || _error!.isEmpty) {
              _error = '播放失败，请手动更换播放源';
            }
            _initialized = true;
          });
        }
      });
    } else {
      setState(() {
        if (_error == null || _error!.isEmpty) {
          _error = '播放失败，请手动更换播放源';
        }
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

    final previousPositionMs = _position.inMilliseconds;

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

      // 🔴 桌面端自动换源：复用同一后端实例（只换 URL）——
      //   不关壳 → 纹理 id 不变、视频层不重建（不闪屏），
      //   也不与新实例抢渲染线程（不卡死）。
      final reuseBackend = _reuseDesktopBackend;
      if (!reuseBackend) {
        await _backend?.dispose();
        for (final sub in _subscriptions) {
          sub.cancel();
        }
        _subscriptions.clear();
      }

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

      if (!reuseBackend) {
        final backend = PlayerBackendFactory.create(_currentPlayerBackend);
        _backend = backend;
        _backend?.fit = _videoFit;
        // 🔴 换后端必须丢弃旧的 eager 视频层缓存，否则会继续渲染已被 dispose 的
        //    上一个后端 widget，画面永远出不来。
        _eagerVideoLayer = null;
        _mpvTextureId = null;
        _attachMpvTextureListener(backend);
        _subscriptions
          ..add(
            backend.positionStream.listen((position) {
              _reportBufferHealth(position);
              if (mounted) {
                setState(() => _position = position);
                _maybeClearPendingStartPosition(position);
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
      }

      var url = newEpisodes[targetEpisodeIndex].trim();
      final filteredUrl = await AdFilterEngine.filterM3u8(
        sourceType: _currentVideoDetail.source,
        originalUrl: url,
      );
      if (filteredUrl != null && filteredUrl.isNotEmpty) {
        url = filteredUrl;
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
        final ready = remaining > Duration.zero
            ? await _waitForPlayerReady(remaining)
            : _duration.inMilliseconds > 0;
        if (!ready) {
          debugPrint('自动切换源等待播放就绪超时');
          continue;
        }

        if (mounted) {
          setState(() => _initialized = true);
          _showControlsWithoutFocusShift();
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
      _switchGate.run(
        () => _switchSourceImpl(index),
        label: 'tv 换源 #$index',
        onTimeout: () {
          // 🔴 熔断后必须复位 UI 状态，否则「切换中」遮罩永久停留 = 看起来卡死。
          if (!mounted) return;
          setState(() {
            _switchingSource = false;
            _error = '切换播放源超时，请重试';
          });
        },
      );

  Future<void> _switchSourceImpl(int index) async {
    if (index < 0 || index >= _sources.length) return;
    if (index == _currentSourceIndex) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

    setState(() => _switchingSource = true);
    try {
      final option = _sources[index];
      debugPrint(
        '[HeinPlay] 换源开始: index=$index source=${option.source} id=${option.id}',
      );
      final response = await LunaTVService.getDetail(
        source: option.source,
        id: option.id,
        title: option.title,
      ).timeout(
        // 🔴 2026-10-23：详情请求必须带超时。个别源（如 iqiyizyapi.com）
        //   的 /api/detail 会 404 或长时间不返回，不能让换源流程无限期挂住。
        const Duration(seconds: 25),
        onTimeout: () {
          debugPrint('[HeinPlay] 换源详情请求超时: source=${option.source}');
          throw TimeoutException('换源详情请求超时', const Duration(seconds: 25));
        },
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
      // 🔴🔴 停止播放 → 保存播放记录 → 释放旧后端（全平台统一链路）。
      //   必须在 detail 请求成功之后调用，位置取自仍在运行的旧后端。
      //   桌面端改为「复用同一后端实例、只换 URL」：不关壳 → 纹理 id 不变 →
      //   视频层不重建（不闪屏），也不与新实例抢渲染线程（不卡死）。
      final reuseBackend = _reuseDesktopBackend;
      final previousPositionMs = await _stopSaveAndReleaseBackend(
        keepBackend: reuseBackend,
      ).timeout(
        // 🔴 2026-10-23：释放旧后端带超时。该步骤内部含「保存播放记录」，
        //   一旦存储层或原生回调不返回，整个换源（连同闸门队列）都会挂死。
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[HeinPlay] 停止/释放旧后端超时，继续走换源起播');
          return 0;
        },
      );
      if (reuseBackend) {
        debugPrint('[HeinPlay] 桌面端换源：复用后端实例（不重建，避免闪屏/卡死）');
      } else {
        debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');
      }
      debugPrint('换源：恢复点=${previousPositionMs}ms');

      if (!mounted) return;

      // 🔴 2026-10-23：新源可能没有剧集（详情为空/404）。此时 clamp(0, -1)
      //   会抛 ArgumentError（min > max），把整条换源流程打断。
      final maxEpisodeIndex = response.data!.episodes.length - 1;
      final safeEpisodeIndex =
          maxEpisodeIndex < 0 ? 0 : previousEpisodeIndex.clamp(0, maxEpisodeIndex);

      setState(() {
        _currentVideoDetail = response.data!;
        _currentSourceIndex = index;
        _currentEpisodeIndex = safeEpisodeIndex;
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
      if (reuseBackend) {
        // 桌面端：不重建后端，直接用同一实例起播新源（mpv loadfile 换 URL）。
        await _openEpisodeImpl(_currentEpisodeIndex, isFirstOpen: true);
      } else {
        _initBackend();
      }
    } catch (e) {
      // 🔴 2026-10-23：换源任何异常都要落到这里，不能让异常冒泡成「无响应」。
      debugPrint('[HeinPlay] 换源失败: $e');
      if (!mounted) return;
      setState(() {
        _switchingSource = false;
        _error = '切换播放源失败: $e';
      });
    }
  }

  void _togglePlay() {
    if (_playing) {
      _backend?.pause();
    } else {
      _backend?.play();
    }
    _showControlsWithoutFocusShift();
  }

  Duration _clampDuration(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (value > _duration) return _duration;
    return value;
  }

  /// 进度条/时间文字应显示的播放位置。
  ///
  /// seek 意图有效期内返回**意图位置**（用户点了哪里就显示哪里），否则返回
  /// 播放器回传的真实 [_position]。这样既避免进度条被 mpv 中间落点拽动，
  /// 又保证 stop 操作后能立刻跟随真实进度。
  Duration get _displayPosition {
    final intent = _lastSeekIntent;
    final at = _lastSeekIntentAt;
    if (intent != null &&
        at != null &&
        DateTime.now().difference(at) <= _seekIntentTtl) {
      return intent;
    }
    return _position;
  }

  /// 当前 seek 应采用的基准位置。
  ///
  /// 若近期有过 seek 意图（[_lastSeekIntent] 未过期），以**意图位置**为基准；
  /// 否则回落到播放器回传的 [_position]。这是修复「越按越偏」的核心：
  /// 连续按键时基准必须是「用户以为自己在哪里」，而不是 mpv 抖动中的落点。
  Duration get _seekBase {
    final intent = _lastSeekIntent;
    final at = _lastSeekIntentAt;
    if (intent != null &&
        at != null &&
        DateTime.now().difference(at) <= _seekIntentTtl) {
      return intent;
    }
    return _position;
  }

  /// 发起一次 seek，并记录意图位置作为后续操作的基准。
  ///
  /// 所有用户主动 seek（快进/快退/拖拽/百分比跳转）都应经由本方法，
  /// 否则意图基准会与实际发出 seek 脱节。
  void _seekTo(Duration target, {bool showControls = true}) {
    final clamped = _clampDuration(target);
    _lastSeekIntent = clamped;
    _lastSeekIntentAt = DateTime.now();
    _backend?.seek(clamped);
    if (showControls) {
      _showControlsWithoutFocusShift();
    }
  }

  void _seekBy(Duration delta) {
    _seekTo(_seekBase + delta);
  }

  void _seekToPercent(double percent) {
    _seekTo(
      Duration(milliseconds: (_duration.inMilliseconds * percent).toInt()),
      showControls: false,
    );
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
    // 先取消旧计时器：无论本次是否要重新计时，都不能留下一个「到点就隐藏」的
    // 遗留计时器去打断正在进行的操作。
    _controlsTimer?.cancel();
    // 弹窗打开时保持控制栏可见，不启动隐藏定时器
    if (_dialogOpen) return;
    _controlsTimer = Timer(
      Duration(seconds: _controlsAutoHideSeconds),
      () {
        debugPrint('控制栏自动隐藏定时器触发');
        _hideControls();
      },
    );
  }

  void _showControls() {
    debugPrint('显示控制栏（请求焦点）');
    setState(() => _controlsVisible = true);
    _startControlsTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_controlsVisible) return;
      // 按下键显示控制栏时，优先聚焦“跳过”按钮；不可用则回退到播放/暂停
      final hasSkipButton =
          _currentVideoDetail.source.isNotEmpty &&
          _currentVideoDetail.id.isNotEmpty;
      if (hasSkipButton && !_skipFocusNode.hasPrimaryFocus) {
        _skipFocusNode.requestFocus();
      } else if (!_playPauseFocusNode.hasPrimaryFocus) {
        _playPauseFocusNode.requestFocus();
      }
    });
  }

  void _showControlsWithoutFocusShift() {
    debugPrint('显示控制栏（不移动焦点）');
    setState(() => _controlsVisible = true);
    _startControlsTimer();
  }

  void _hideControls() {
    // 弹窗打开时不隐藏控制栏，避免弹窗焦点被强制移走
    if (_dialogOpen) return;
    debugPrint('隐藏控制栏: _controlsVisible=$_controlsVisible');
    _controlsTimer?.cancel();
    _controlsTimer = null;
    // 仅释放控制栏焦点，避免 unfocus 全局焦点后被平台视图夺走
    _bottomControlsFocusNode.unfocus();
    setState(() => _controlsVisible = false);
    // 在下一帧把焦点移回根 Focus，保证隐藏控制栏后按键仍能进入 _handleKeyEvent
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      debugPrint('控制栏隐藏后焦点: ${FocusManager.instance.primaryFocus?.debugLabel}');
      _rootFocusNode.requestFocus();
    });
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
    setState(() => _dialogOpen = true);
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
        setState(() => _dialogOpen = false);
        _startControlsTimer();
      }
    });
  }

  void _showSourceSelectorDialog() {
    _showControls();
    _controlsTimer?.cancel();
    setState(() => _dialogOpen = true);
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
        setState(() => _dialogOpen = false);
        _startControlsTimer();
      }
    });
  }

  void _showPlayerBackendSelectorDialog() {
    _showControls();
    _controlsTimer?.cancel();
    setState(() => _dialogOpen = true);
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
          content: FocusScope(
            autofocus: true,
            child: SizedBox(
              width: 400,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: PlayerBackendFactory.availableBackends.length,
                itemBuilder: (context, index) {
                  final type = PlayerBackendFactory.availableBackends[index];
                  final selected = type == _currentPlayerBackend;
                  final String label;
                  switch (type) {
                    case PlayerBackendType.exo:
                      label = 'ExoPlayer';
                      break;
                    // fvp 已摘除，保留分支仅为穷尽 switch（历史存储值由迁移兜底）
                    case PlayerBackendType.fvp:
                      label = 'FVP（已移除）';
                      break;
                    case PlayerBackendType.vlc:
                      label = 'VLC';
                      break;
                    case PlayerBackendType.mpv:
                      label = 'MPV';
                      break;
                  }
                  return FocusableWidget(
                    autofocus: selected,
                    padding: EdgeInsets.zero,
                    onTap: () {
                      Navigator.of(context).pop();
                      _switchPlayerBackend(type);
                    },
                    child: Container(
                      margin: EdgeInsets.only(bottom: AppSpacing.sm),
                      padding: EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primaryTint
                            : Color(0xFF1C1C2E),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : Color(0x14FFFFFF),
                        ),
                      ),
                      child: Text(
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
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    ).then((_) {
      if (mounted) {
        setState(() => _dialogOpen = false);
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
  /// 桌面端（Windows / Linux）换源/换集时是否**复用同一个后端实例**。
  ///
  /// 桌面壳里的 mpv 是**进程级全局单例**（native 侧 g_mpv，壳只向 Flutter
  /// 注册一次纹理）。换源时若把旧后端连壳一起关掉再重建，会连带：
  ///   ① 重建 mpv + EGL 两阶段 + 纹理注册 → **纹理 id 变化** → Flutter 必须
  ///      重建 `Texture(textureId:)` 与 PlatformView → 中间一帧黑屏 → **闪屏**；
  ///      重建本身还要重走两阶段初始化 → **切换明显变慢**；
  ///   ② 旧实例的延迟 dispose 与新实例的创建在桌面端抢同一个渲染线程 →
  ///      表现为**换源/换播放器时软件卡死**（Windows server 实测）。
  /// 复用同一实例、只换 URL（mpv loadfile 语义），上述问题都不发生。
  bool get _reuseDesktopBackend =>
      DeviceUtils.isComputer &&
      (_backend is MpvDesktopBackend || _backend is VlcBackend);

  Future<int> _stopSaveAndReleaseBackend({bool keepBackend = false}) async {
    final lastPositionMs = _position.inMilliseconds;

    debugPrint('[HeinPlay] 切换操作开始：停止播放 → 保存播放记录 → 释放旧后端');
    // 1) 先落一次播放记录（节流窗口内也强制写，因为这是用户主动切换的明确意图）。
    // 🔴🔴 2026-10-23：这里必须带超时 + 计时日志。实测卡死现场
    //   （Windows 12:55:13 换源到 iqiyizyapi.com）就停在本步骤之后：
    //   本行打印后再无任何日志，进程最终被强杀。超时则**继续切换**，
    //   绝不让「存记录」拖死整条切源链路。
    if (!_recordSaveInFlight && _isPlaybackReadyForRecord()) {
      final sw = Stopwatch()..start();
      debugPrint('[HeinPlay] 保存播放记录开始');
      try {
        await _savePlayRecordToLunaTV().timeout(const Duration(seconds: 20));
        debugPrint(
          '[HeinPlay] 保存播放记录完成 耗时=${sw.elapsedMilliseconds}ms',
        );
      } catch (e) {
        debugPrint(
          '[HeinPlay] 保存播放记录异常/超时（继续切换）: $e '
          '耗时=${sw.elapsedMilliseconds}ms',
        );
      }
    }

    // 🔴🔴 桌面端换源/换集：保留同一个后端实例，只换 URL。
    //   不关壳 → 纹理 id 不变 → 视频层不重建 → **不闪屏**；
    //   也不与新实例抢渲染线程 → **不卡死**。
    //   订阅保持不变（继续用同一个后端的流），所以这里必须**先于**退订返回。
    if (keepBackend && _reuseDesktopBackend) {
      debugPrint('[HeinPlay] 桌面端：保留后端实例（不关壳、不重建），仅换 URL');
      // 🔴🔴 2026-10-23：这里**不能**再调 pause()。
      //   mpv 的 pause 是**持久属性**（native: set pause yes），而 native open
      //   只做 loadfile(url, replace) —— 不会把 pause 复位。残留 pause=yes 时，
      //   新源解码完会**停在首帧不动**（看起来就是换源后黑屏/卡住）。
      //   旧播放的停止由 loadfile replace 本身完成，无需在此 pause。
      // 旧的时长/进度会让「等待播放就绪」判据立刻命中（_duration > 0 即返回
      // true），换源后就会误判为已就绪 → 画面还没出来就当成功。必须清零，
      // 让就绪判据重新等新源的 duration / 进度推进。
      if (mounted) {
        setState(() {
          _initialized = false;
          _duration = Duration.zero;
          _position = Duration.zero;
        });
      }
      return lastPositionMs;
    }

    // 2) 停止并释放旧后端。必须先 await dispose 完成再返回，
    //    否则平台播放器会在后台继续播放。
    final previousBackend = _backend;
    _backend = null;
    // 先摘引用并等一帧，让视频层（PlatformView）先卸载，再释放原生播放器。
    // 否则 Android 侧重建 platformView 时 surface 回调可能打到已释放的
    // player handle 上（fvp 时代实测 SIGSEGV 闪退，mpv/exo 同样有风险）。
    if (mounted) {
      setState(() => _initialized = false);
      // 🔴 2026-10-23：endOfFrame 在无帧调度时可能长时间不返回（窗口最小化/
      //   后台/渲染阻塞），必须带超时，否则释放旧后端这一步就能把切源挂死。
      await WidgetsBinding.instance.endOfFrame.timeout(
        const Duration(seconds: 2),
        onTimeout: () {},
      );
    }
    // 🔴 2026-10-23：必须先退订、再 dispose。
    //    dispose() 会关闭后端的全部 StreamController，若此时订阅仍挂着，
    //    期间到达的原生事件会抛「Cannot add new events after calling close」
    //    并中断整个切换流程（表现为播放记录存不下去、切换变慢甚至直接失败）。
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    // 🔴 2026-10-23：原生 dispose 可能阻塞（等网络/解码线程退出），
    //   必须带超时，避免整个切源流程（含闸门队列）永久挂死。
    try {
      await previousBackend?.dispose().timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('[HeinPlay] 释放旧后端异常/超时（继续）: $e');
    }
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

    // 🔴🔴 停止播放 → 保存播放记录 → 释放旧后端（全平台统一链路）。
    //   必须在新后端 create() 之前完成，否则两个播放器会同时在后台解码。
    final restoreMs = await _stopSaveAndReleaseBackend();
    debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');
    _pendingInitialPositionMs = restoreMs;
    debugPrint('切换播放器：${_currentPlayerBackend} → $type 恢复点=${restoreMs}ms');

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
    setState(() => _dialogOpen = true);
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
        setState(() => _dialogOpen = false);
        _startControlsTimer();
      }
    });
  }

  // 遥控器左右键快进/快退时显示手势标识，长按期间持续显示直至松手。
  void _showKeySeekIndicator(bool forward) {
    setState(() {
      _isLongPressSeeking = true;
      _gestureIndicatorVisible = true;
      _gestureIndicatorText = forward ? '快进中' : '快退中';
      _gestureIndicatorIcon = forward ? Icons.fast_forward : Icons.fast_rewind;
    });
  }

  // 长按连续快进/快退，支持加速
  void _startLongPressSeek(String direction) {
    _longPressSeekTimer?.cancel();
    _longPressSeekTimer = Timer(Duration(milliseconds: 400), () {
      _continuousSeekTimer?.cancel();
      final startTime = DateTime.now();
      _continuousSeekTimer = Timer.periodic(Duration(milliseconds: 200), (
        _,
      ) {
        final elapsedMs = DateTime.now().difference(startTime).inMilliseconds;
        int step;
        if (elapsedMs < 1000) {
          step = _seekStep;
        } else if (elapsedMs < 3000) {
          step = _seekStep * 2;
        } else if (elapsedMs < 6000) {
          step = _seekStep * 4;
        } else {
          step = _seekStep * 8;
        }
        _seekBy(Duration(seconds: direction == 'left' ? -step : step));
      });
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
    //    才真正起播，慢源可达 12 秒）。此时写盘会用 playTime=0 覆盖掉
    //    切换前刚保存的有效进度 —— 真机（荣耀平板 V8 Pro 2026-10-23）
    //    实测：换源前存了 431s，换源后被覆盖成 0s，
    //    用户侧表现为「换源后读取播放记录失败 / 进度丢失」。
    if (_pendingStartTargetMs > 0) return false;
    return true;
  }

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    // 处理按键释放，停止长按连续seek
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _stopLongPressSeek();
        _isLongPressSeeking = false;
        // 左右键释放后重新计时，确保操作结束后控制栏不会立刻消失
        if (_controlsVisible) _startControlsTimer();
        // 释放后隐藏快进/快退手势标识。
        if (_gestureIndicatorVisible) {
          setState(() => _gestureIndicatorVisible = false);
        }
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    debugPrint('按键: ${event.logicalKey}, 控制栏可见=$_controlsVisible');

    // 控制栏显示时，检测焦点是否在控制栏内
    if (_controlsVisible) {
      // 控制栏可见期间的任何按键都视为「用户仍在操作」，重置自动隐藏倒计时。
      // 否则用户在控制栏上左右移动焦点挑选选项时，10 秒到点控制栏仍会自动隐藏，
      // 表现为「还没选完控制栏就没了」——超时必须只在无操作时才开始计算。
      _startControlsTimer();
      final currentFocus = FocusManager.instance.primaryFocus;
      final isFocusInControls =
          currentFocus != null &&
          _bottomControlsFocusNode.hasFocus &&
          _bottomControlsFocusNode.traversalDescendants.contains(currentFocus);

      switch (event.logicalKey) {
        // 返回/Esc 在控制栏显示时不在这里处理，统一交给 _handleHardwareKeyEvent
        // 兜底处理，以保证控制栏显示时先隐藏控制栏，再按一次才返回。
        case LogicalKeyboardKey.select:
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.mediaPlayPause:
          // 焦点在控制栏内时，交给焦点系统处理按钮选择
          // 焦点不在控制栏内时，触发播放/暂停
          if (isFocusInControls) {
            return KeyEventResult.ignored;
          } else {
            _togglePlay();
            return KeyEventResult.handled;
          }
        case LogicalKeyboardKey.mediaPlay:
          _backend?.play();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.mediaPause:
          _backend?.pause();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.mediaTrackNext:
          _nextEpisode();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.mediaTrackPrevious:
          _previousEpisode();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.contextMenu:
        case LogicalKeyboardKey.mediaFastForward:
        case LogicalKeyboardKey.mediaRewind:
          _toggleControls();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowLeft:
          // 焦点不在控制栏内时，左键作为快退
          if (!isFocusInControls) {
            _seekBy(Duration(seconds: -_seekStep));
            _startLongPressSeek('left');
            _showKeySeekIndicator(false);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        case LogicalKeyboardKey.arrowRight:
          // 焦点不在控制栏内时，右键作为快进
          if (!isFocusInControls) {
            _seekBy(Duration(seconds: _seekStep));
            _startLongPressSeek('right');
            _showKeySeekIndicator(true);
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        case LogicalKeyboardKey.arrowDown:
          // 无论控制栏是否显示，下键都重新激活控制栏焦点
          _showControls();
          return KeyEventResult.handled;
        default:
          // 其他方向键交给焦点遍历处理
          return KeyEventResult.ignored;
      }
    }

    // 控制栏隐藏时，方向键用于播放器快捷操作
    // 返回键统一交给 PopScope 处理，避免与系统返回事件重复响应。
    switch (event.logicalKey) {
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPlay:
        _backend?.play();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaPause:
        _backend?.pause();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
        _seekBy(Duration(seconds: -_seekStep));
        _startLongPressSeek('left');
        _showKeySeekIndicator(false);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seekBy(Duration(seconds: _seekStep));
        _startLongPressSeek('right');
        _showKeySeekIndicator(true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _showControlsWithoutFocusShift();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _showControls();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackNext:
        _nextEpisode();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.mediaTrackPrevious:
        _previousEpisode();
        return KeyEventResult.handled;
      case LogicalKeyboardKey.contextMenu:
      case LogicalKeyboardKey.mediaFastForward:
      case LogicalKeyboardKey.mediaRewind:
        _toggleControls();
        return KeyEventResult.handled;
      default:
        return KeyEventResult.ignored;
    }
  }

  /// 全局硬件按键兜底处理。
  ///
  /// 当控制栏隐藏、平台视图或其他焦点节点夺走焦点时，根 Focus 的 onKeyEvent
  /// 可能无法收到事件。此 handler 在 HardwareKeyboard 层面监听，确保遥控器
  /// 按键始终能响应播放控制。
  bool _handleHardwareKeyEvent(KeyEvent event) {
    // 只处理按下事件，避免重复触发
    if (event is! KeyDownEvent) return false;

    // 仅在当前页面位于栈顶时处理，避免影响其他页面/对话框
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;

    // 控制栏显示时交给焦点系统处理按钮选择，但下键与返回/ESC 键始终兜底处理。
    if (_controlsVisible &&
        event.logicalKey != LogicalKeyboardKey.arrowDown &&
        event.logicalKey != LogicalKeyboardKey.goBack &&
        event.logicalKey != LogicalKeyboardKey.escape) {
      return false;
    }

    debugPrint('HardwareKeyboard 兜底: ${event.logicalKey}');

    switch (event.logicalKey) {
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.mediaPlayPause:
        _togglePlay();
        return true;
      case LogicalKeyboardKey.mediaPlay:
        _backend?.play();
        return true;
      case LogicalKeyboardKey.mediaPause:
        _backend?.pause();
        return true;
      case LogicalKeyboardKey.arrowLeft:
        _seekBy(Duration(seconds: -_seekStep));
        _startLongPressSeek('left');
        return true;
      case LogicalKeyboardKey.arrowRight:
        _seekBy(Duration(seconds: _seekStep));
        _startLongPressSeek('right');
        return true;
      case LogicalKeyboardKey.arrowUp:
        _showControlsWithoutFocusShift();
        return true;
      case LogicalKeyboardKey.arrowDown:
        _showControls();
        return true;
      case LogicalKeyboardKey.mediaTrackNext:
        _nextEpisode();
        return true;
      case LogicalKeyboardKey.mediaTrackPrevious:
        _previousEpisode();
        return true;
      case LogicalKeyboardKey.contextMenu:
      case LogicalKeyboardKey.mediaFastForward:
      case LogicalKeyboardKey.mediaRewind:
        _toggleControls();
        return true;
      case LogicalKeyboardKey.goBack:
      case LogicalKeyboardKey.escape:
        // TV/Android：控制栏显示时先隐藏控制栏；隐藏后再按则安全退出播放页
        //（先摘视频 widget、等一帧再 dispose 后端，避免 fvp surface 竞态闪退）。
        // 🔴 记账：告诉 PopScope「这一次返回已由键盘层处理」，
        // 否则系统返回事件会把刚隐藏控制栏的同一按键当成「第二次按返回」
        // 而直接退出播放页（详见 `_lastBackKeyHandledAt` 注释）。
        _lastBackKeyHandledAt = DateTime.now();
        if (_controlsVisible) {
          _hideControls();
        } else {
          _exitPlayer();
        }
        return true;
      default:
        return false;
    }
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
    _toggleControls();
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
    _showGestureIndicator(
      isRight ? '3X 快进中' : '3X 快退中',
      isRight ? Icons.fast_forward : Icons.fast_rewind,
    );
    _start3xSeek();
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    _isLongPressSeeking = false;
    _stopLongPressSeek();
    setState(() => _gestureIndicatorVisible = false);
  }

  void _start3xSeek() {
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _continuousSeekTimer = Timer.periodic(Duration(milliseconds: 200), (
      _,
    ) {
      if (!_isLongPressSeeking || _backend == null) return;
      final step = _longPressDirection == 'right'
          ? _seekStep * 3
          : -_seekStep * 3;
      // 🔴 必须用 _seekBase 而非 _position：长按场景每 200ms 触发一次，
      //   若基准取自抖动中的 _position，60 秒长按可累积出十几秒的偏移。
      _seekTo(_seekBase + Duration(seconds: step), showControls: false);
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
      VolumeController.instance.setVolume(_currentVolume);
      _showGestureIndicator(
        '音量 ${(_currentVolume * 100).toInt()}%',
        _currentVolume > 0 ? Icons.volume_up : Icons.volume_off,
      );
    }
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
    final target = _position + Duration(seconds: deltaSeconds.toInt());
    _showGestureIndicator(
      '跳转至 ${_formatDuration(_clampDuration(target))}',
      deltaSeconds >= 0 ? Icons.fast_forward : Icons.fast_rewind,
    );
  }

  void _onHorizontalDragEnd(DragEndDetails details) {
    if (_gestureStartPosition == null) return;
    final deltaSeconds = _cumulativeDeltaX * _horizontalGestureSensitivity;
    // 同 _seekBy：基准取意图位置，避免拖拽过程中基准随 mpv 落点抖动。
    _seekTo(_seekBase + Duration(seconds: deltaSeconds.toInt()),
        showControls: false);
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
    _showControlsWithoutFocusShift();
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
    _showControlsWithoutFocusShift();
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
      // fvp 已摘除，保留分支仅为穷尽 switch（历史存储值由迁移兜底）
      case PlayerBackendType.fvp:
        return 'FVP（已移除）';
      case PlayerBackendType.vlc:
        return 'VLC';
      case PlayerBackendType.mpv:
        return 'MPV';
    }
  }

  /// 安全退出播放页：先拆后端再 pop，避免退出闪退。
  /// 安全退出播放页。
  ///
  /// 🔴🔴 2026-10-21 修复「退出播放时软件卡死」（78 真机反复复现）：
  ///    原实现是「先 await 后端 dispose，成功后才 pop」——
  ///    **先等后端销毁完，才允许页面出栈**。而 mpv 的 dispose 要销毁渲染上下文、
  ///    join 渲染/事件线程，在 78 这类无 GPU 的软渲染环境里可能长时间不返回，
  ///    甚至永久阻塞；只要它不返回，页面就永远停在播放页，用户看到的就是
  ///    「点退出后软件卡死」。
  ///
  ///    现在改为**先出栈、再后台清理**：页面立刻退出（用户可感知），
  ///    后端销毁放到不阻塞 UI 的异步任务里做，并加超时兜底，避免它拖住进程。
  ///    dispose() 里还有一层「_backend 非空则再释放一次」的兜底，不会泄漏。
  Future<void> _exitPlayer() async {
    if (_exitingPlayer) return;
    _exitingPlayer = true;
    debugPrint('PlayerScreen 退出播放：先出栈，再后台清理后端');
    // ① 立即出栈，绝不等待后端销毁。
    if (mounted) Navigator.of(context).pop();
    // ② 后台清理：不 await，异常/超时都不影响页面已经退出的事实。
    final backend = _backend;
    _backend = null;
    _initialized = false;
    if (backend != null) {
      unawaited(
        backend
            .dispose()
            .timeout(const Duration(seconds: 3))
            .catchError((e) {
          debugPrint('PlayerScreen 后台释放后端异常/超时（已忽略）：$e');
        }),
      );
    }
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
    _lifecycleListener?.dispose();
    _lifecycleListener = null;
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _controlsTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _clockTimer?.cancel();
    _autoSwitchTimer?.cancel();
    _initialPositionRestoreTimer?.cancel();
    _bottomControlsFocusNode.dispose();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    // 释放播放会话：后台测速恢复全速
    final sessionId = _playbackSessionId;
    if (sessionId != null) {
      PlaybackActivity.instance.closeSession(sessionId);
      _playbackSessionId = null;
    }

    // 立即保存播放记录到 LunaTV
    _savePlayRecordToLunaTV();

    // 正常退出路径已在 _exitPlayer() 的后台清理里把 _backend 置空并释放；
    // 此处兜底：若框架在其他路径直接 dispose（如页面被系统回收），同样先摘引用再释放。
    final backend = _backend;
    _backend = null;
    backend?.dispose();

    // 退出播放页后允许系统自动休眠/降亮度
    WakelockPlus.disable().catchError((e) {
      debugPrint('PlayerScreen: 禁用屏幕常亮失败: $e');
    });

    // 释放本地 M3U8 代理
    AdFilterEngine.dispose();

    _playPauseFocusNode.dispose();
    _skipFocusNode.dispose();
    _rootFocusNode.dispose();
    widget.sourcesNotifier?.removeListener(_onSourcesChanged);

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
      final rawPos = _position.inSeconds;
      // 🔴 2026-10-23：起播位置为 0 时**不得覆盖**已有的有效进度。
      //   真机（荣耀平板 V8 Pro 2026-10-23 14:58，换源到 zuidazy.co）：
      //   mpv 的 file-loaded 迟了 12 秒，期间位置流恒为 0，被写盘成
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
    // 🔴 mpv 这类 requiresEagerMount 的后端：视频层必须**提前且常驻**挂载，
    //    否则 open() 等 view、view 等 buildVideoWidget、buildVideoWidget 等
    //    _initialized、_initialized 又等 open() —— 闭环死锁，播放永远起不来。
    //    这里**不**受 _switchingSource / _initialized 早退影响。
    final eager = _backend?.requiresEagerMount ?? false;
    if (eager && _backend != null) {
      _eagerVideoLayer ??= _backend!.buildVideoWidget();
      // 🔴🔴 2026-10-21 点播画面比例失真的架构根因（与 Android 对齐）：
      //    壳的 FBO 原先按 video-out-params（视频自身尺寸）创建，mpv 渲染出来
      //    就没有黑边、恰是视频原始比例；Flutter 再把它拉伸铺满竖屏 → 压扁，
      //    且 keepaspect/panscan 在 mpv 内部完全失效（FBO 就是视频尺寸）。
      //    这里用 LayoutBuilder 把**视频层控件尺寸**上报给壳，壳据此建 FBO，
      //    mpv 才会在控件范围内按 video-params 做 letterbox。
      //    这等价于 Android 侧「mpv 渲染进全屏 Surface」。
      return LayoutBuilder(
        builder: (context, constraints) {
          _reportVideoViewSize(constraints);
          return Stack(
            fit: StackFit.expand,
            children: [
              ColoredBox(color: Colors.black),
              // 🔴 mpv 画面走 Flutter 外部纹理：原生只给零尺寸锚点，
              //    真正出画的是这里叠上去的 `Texture(textureId)`。
              //
              // 🔴🔴 2026-10-15 点播画面左右拉伸的根因：此处原先包了
              //    `FittedBox(fit: _videoFit, child: SizedBox(1920x1080, child: Texture))`，
              //    那个 1920x1080 是写死常量、并非视频真实宽高比，导致「mpv 先铺满
              //    2560x1600 的 Surface 拉伸一次」+「FittedBox 再按错误基准缩放一次」
              //    的双重错误。exo 走 SurfaceView 直出不经此层，故比例正常。
              //    修法（与 legacy 一致）：裸 Texture 铺满，比例交由 mpv 依据
              //    video-params 与 keepaspect/panscan 自行计算；前端 _videoFit
              //    三态经 setFit 下发。
              if (_mpvTextureId != null) Texture(textureId: _mpvTextureId!),
              _eagerVideoLayer!,
              if (!_initialized) const ColoredBox(color: Colors.black),
              if (!_initialized) const Center(child: TechLoadingIndicator()),
            ],
          );
        },
      );
    }

    // 🔴🔴 2026-10-23 修复：换源期间**不能**把视频层从 widget 树里卸载。
    //   卸载会让 VLC 的 PlatformView detach → controller 失去 attach →
    //   原地换源的 setMedia 落在未 attach 的 controller 上 → 画面不再输出 → 黑屏。
    //   （Windows 端已实证同一根因；本页为 Linux/TV 共享页，一并修正。）
    //   切换提示由上层 _buildSwitchingOverlay() 叠加呈现。
    if (!_initialized || _backend == null) {
      return Center(
        child: TechLoadingIndicator(),
      );
    }
    // 🔴 非 eager 的 mpv 兜底路径同样需要纹理层（例如平台判定差异时）。
    //    裸 Texture 铺满，理由同上方 eager 分支（去掉写死 1920x1080 的 FittedBox）。
    final mpvTextureId = _mpvTextureId;
    if (mpvTextureId != null) {
      return Container(
        color: Colors.black,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Texture(textureId: mpvTextureId),
            _backend!.buildVideoWidget(),
          ],
        ),
      );
    }
    return Container(color: Colors.black, child: _backend!.buildVideoWidget());
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
        onTap: _onTapScreen,
        onDoubleTap: _onDoubleTapScreen,
        onLongPressStart: DeviceUtils.isDesktop ? null : _onLongPressStart,
        onLongPressEnd: DeviceUtils.isDesktop ? null : _onLongPressEnd,
        onVerticalDragStart: DeviceUtils.isDesktop
            ? null
            : _onVerticalDragStart,
        onVerticalDragUpdate: DeviceUtils.isDesktop
            ? null
            : _onVerticalDragUpdate,
        onVerticalDragEnd: DeviceUtils.isDesktop ? null : _onVerticalDragEnd,
        onHorizontalDragStart: _onHorizontalDragStart,
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
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
      child: Stack(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => _exitPlayer(),
                icon: Icon(
                  Icons.arrow_back,
                  color: Color(0xFFF0F0F5),
                ),
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
            ],
          ),
          Positioned.fill(
            child: Center(
              child: Text(
                _formatClock(_currentTime),
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 18,
                  fontWeight: FontWeight.w500,
                  color: Color(0xFFF0F0F5),
                  shadows: [
                    Shadow(
                      color: Colors.black54,
                      blurRadius: 4,
                      offset: Offset(0, 1),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls() {
    return FocusScope(
      node: _bottomControlsFocusNode,
      child: Container(
        padding: EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [Color(0xD90A0A0F), Colors.transparent],
          ),
        ),
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
                        // 🔴 使用 _displayPosition 而非 _position：seek 意图有效期内
                        //   显示用户点击的目标位置，避免 mpv 的中间落点把进度条
                        //   拽出去再弹回来（真机日志实测跨度可达 115 秒）。
                        value: _duration.inMilliseconds > 0
                            ? _displayPosition.inMilliseconds /
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
            Row(
              children: [
                _buildControlIconButton(
                  focusNode: _playPauseFocusNode,
                  onTap: _togglePlay,
                  icon: _playing ? Icons.pause : Icons.play_arrow,
                ),
                SizedBox(width: AppSpacing.sm),
                _buildControlIconButton(
                  onTap: _previousEpisode,
                  icon: Icons.skip_previous,
                ),
                SizedBox(width: AppSpacing.sm),
                _buildControlIconButton(
                  onTap: _nextEpisode,
                  icon: Icons.skip_next,
                ),
                SizedBox(width: AppSpacing.md),
                Text(
                  '${_formatDuration(_displayPosition)} / ${_formatDuration(_duration)}',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    color: Color(0xFFF0F0F5),
                  ),
                ),
                Spacer(),
                if (_currentVideoDetail.source.isNotEmpty &&
                    _currentVideoDetail.id.isNotEmpty)
                  FocusableWidget(
                    focusNode: _skipFocusNode,
                    onTap: _showSkipConfigDialog,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color:
                            _skipConfig != null &&
                                _skipConfig!.segments.isNotEmpty
                            ? AppColors.primaryTint
                            : Color(0xFF1C1C2E),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: Color(0x14FFFFFF)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_skipConfigLoading)
                            SizedBox(
                              width: 16,
                              height: 16,
                              child: TechLoadingIndicator(
                                size: 16,
                                strokeWidth: 2,
                              ),
                            )
                          else
                            Icon(
                              Icons.skip_next,
                              color:
                                  _skipConfig != null &&
                                      _skipConfig!.segments.isNotEmpty
                                  ? AppColors.primary
                                  : Color(0xFFF0F0F5),
                              size: 18,
                            ),
                          SizedBox(width: AppSpacing.xs),
                          Text(
                            '跳过',
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              fontSize: 13,
                              color:
                                  _skipConfig != null &&
                                      _skipConfig!.segments.isNotEmpty
                                  ? AppColors.primary
                                  : Color(0xFFF0F0F5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                SizedBox(width: AppSpacing.md),
                FocusableWidget(
                  onTap: _cycleVideoFit,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: Color(0xFF1C1C2E),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: Color(0x14FFFFFF)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.aspect_ratio,
                          color: Color(0xFFF0F0F5),
                          size: 18,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          _videoFitLabel(_videoFit),
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 13,
                            color: Color(0xFFF0F0F5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: AppSpacing.md),
                FocusableWidget(
                  onTap: _showPlayerBackendSelectorDialog,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: Color(0xFF1C1C2E),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: Color(0x14FFFFFF)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.settings_applications,
                          color: Color(0xFFF0F0F5),
                          size: 18,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          _playerBackendLabel(_currentPlayerBackend),
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 13,
                            color: Color(0xFFF0F0F5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: AppSpacing.md),
                FocusableWidget(
                  onTap: _cyclePlaybackSpeed,
                  child: Container(
                    padding: EdgeInsets.symmetric(
                      horizontal: AppSpacing.md,
                      vertical: AppSpacing.xs,
                    ),
                    decoration: BoxDecoration(
                      color: Color(0xFF1C1C2E),
                      borderRadius: BorderRadius.circular(AppRadius.md),
                      border: Border.all(color: Color(0x14FFFFFF)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.speed,
                          color: Color(0xFFF0F0F5),
                          size: 18,
                        ),
                        SizedBox(width: AppSpacing.xs),
                        Text(
                          _playbackSpeedLabel(_playbackSpeed),
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 13,
                            color: Color(0xFFF0F0F5),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                SizedBox(width: AppSpacing.md),
                if (_canSwitchSource)
                  FocusableWidget(
                    onTap: _showSourceSelectorDialog,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: Color(0xFF1C1C2E),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: Color(0x14FFFFFF)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.swap_horiz,
                            color: Color(0xFFF0F0F5),
                            size: 18,
                          ),
                          SizedBox(width: AppSpacing.xs),
                          Text(
                            '换源',
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              fontSize: 13,
                              color: Color(0xFFF0F0F5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_canSwitchSource) SizedBox(width: AppSpacing.md),
                if (_currentVideoDetail.episodes.length > 1)
                  FocusableWidget(
                    onTap: _showEpisodeSelectorDialog,
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: AppSpacing.md,
                        vertical: AppSpacing.xs,
                      ),
                      decoration: BoxDecoration(
                        color: Color(0xFF1C1C2E),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(color: Color(0x14FFFFFF)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.list,
                            color: Color(0xFFF0F0F5),
                            size: 18,
                          ),
                          SizedBox(width: AppSpacing.xs),
                          Text(
                            '选集',
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              fontSize: 13,
                              color: Color(0xFFF0F0F5),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_currentVideoDetail.episodes.length > 1)
                  SizedBox(width: AppSpacing.md),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建控制栏图标按钮，使用 FocusableWidget 以获得明显的焦点边框。
  Widget _buildControlIconButton({
    required VoidCallback onTap,
    required IconData icon,
    FocusNode? focusNode,
    bool autofocus = false,
  }) {
    return FocusableWidget(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
      child: Icon(icon, color: Color(0xFFF0F0F5), size: 28),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // TV 版无窗口全屏概念：控制栏显示时先隐藏控制栏，再按返回才退出播放页。
      // canPop 恒为 false：所有退出（系统返回手势 / 滑动返回）统一走 _exitPlayer，
      // 先摘视频 widget、等一帧再 dispose 后端，避免退出时 fvp surface 竞态闪退。
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // 🔴🔴 去重：键盘层刚刚已消费掉这次返回（隐藏了控制栏），系统返回事件
        //   紧随其后到达时不能再当成「第二次按返回」，否则会直接退出播放页。
        //   一次物理按键只产生一次行为。
        final handled = _lastBackKeyHandledAt;
        if (handled != null &&
            DateTime.now().difference(handled) < _kBackKeyDedupWindow) {
          debugPrint('返回键已由键盘层消费，忽略重复的系统返回事件');
          return;
        }
        if (_controlsVisible) {
          _hideControls();
        } else {
          _exitPlayer();
        }
      },
      child: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        onKeyEvent: (_, event) => _handleKeyEvent(event),
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
              Positioned.fill(child: IgnorePointer(child: _buildVideo())),
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
              // 手势操作提示（亮度/音量/进度）
              _buildGestureIndicator(),
            ],
          ),
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
  late final List<FocusNode> _focusNodes;
  late final List<GlobalKey> _itemKeys;
  int _focusedIndex = 0;

  @override
  void initState() {
    super.initState();
    _focusedIndex = widget.currentIndex.clamp(0, widget.sources.length - 1);
    _scrollController = ScrollController();
    _focusNodes = List.generate(widget.sources.length, (_) => FocusNode());
    _itemKeys = List.generate(widget.sources.length, (_) => GlobalKey());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
      _focusItem(_focusedIndex);
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _scrollController.dispose();
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    var currentIndex = _focusNodes.indexWhere((node) => node.hasPrimaryFocus);
    if (currentIndex < 0) currentIndex = _focusedIndex;

    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (currentIndex + 1 < widget.sources.length) {
        setState(() => _focusedIndex = currentIndex + 1);
        _focusItem(_focusedIndex);
        return true;
      }
    } else if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      if (currentIndex > 0) {
        setState(() => _focusedIndex = currentIndex - 1);
        _focusItem(_focusedIndex);
        return true;
      }
    }
    return false;
  }

  void _focusItem(int index) {
    if (index < 0 || index >= _focusNodes.length) return;
    _focusNodes[index].requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
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
      content: FocusScope(
        child: Actions(
          // 禁用默认方向键焦点遍历，避免与自定义 HardwareKeyboard 处理冲突导致跳格。
          actions: <Type, Action<Intent>>{
            DirectionalFocusIntent: CallbackAction<DirectionalFocusIntent>(
              onInvoke: (_) => null,
            ),
          },
          child: SizedBox(
              width: 640,
              height: 240,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                controller: _scrollController,
                child: Row(
                  children: List.generate(widget.sources.length, (index) {
                    return Padding(
                      padding: EdgeInsets.only(
                        right: index < widget.sources.length - 1
                            ? AppSpacing.md
                            : 0,
                      ),
                      child: _SourceSelectorCard(
                        key: _itemKeys[index],
                        focusNode: _focusNodes[index],
                        autofocus: index == widget.currentIndex,
                        source: widget.sources[index],
                        selected: index == widget.currentIndex,
                        rank: index + 1,
                        formatSpeed: widget.formatSpeed,
                        speedColor: widget.speedColor,
                        onTap: () => widget.onSelect(index),
                      ),
                    );
                  }),
                ),
              ),
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
  final FocusNode? focusNode;
  final bool autofocus;

  const _SourceSelectorCard({
    super.key,
    required this.source,
    required this.selected,
    required this.rank,
    required this.formatSpeed,
    required this.speedColor,
    required this.onTap,
    this.focusNode,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final speedText = formatSpeed(source.speed);
    final resolutionText = source.resolution?.trim() ?? '';

    return FocusableWidget(
      focusNode: focusNode,
      autofocus: autofocus,
      onTap: onTap,
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
  final _selectedFocusNode = FocusNode();

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
      _selectedFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _selectedFocusNode.dispose();
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
      content: FocusScope(
        autofocus: true,
        child: SizedBox(
          width: 400,
          height: 360,
          child: GridView.count(
            controller: _scrollController,
            crossAxisCount: 4,
            crossAxisSpacing: AppSpacing.md,
            mainAxisSpacing: AppSpacing.md,
            childAspectRatio: 2.2,
            children: List.generate(widget.titles.length, (index) {
              final selected = index == widget.currentIndex;
              return FocusableWidget(
                key: selected ? _selectedKey : null,
                focusNode: selected ? _selectedFocusNode : null,
                autofocus: selected,
                onTap: () => widget.onSelect(index),
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
                      color: selected
                          ? AppColors.primary
                          : Color(0xFFF0F0F5),
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}
