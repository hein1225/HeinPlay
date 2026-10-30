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
import 'package:hain_tv/player/video_player_backend.dart';
import 'package:hain_tv/player/mpv_backend.dart';
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
  bool _playing = true;

  /// 🔴 2026-10-29 真机复盘：退到后台时自动暂停、回前台自动恢复。
  AppLifecycleListener? _lifecycleListener;

  /// 标记「这次暂停是我们自己在后台发起的」，回前台才恢复，避免误恢复用户手动暂停的播放。
  bool _pausedByLifecycle = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  Duration _buffered = Duration.zero;
  bool _initialized = false;
  String? _error;
  bool _switchingSource = false;
  late PlayerBackendType _currentPlayerBackend;
  BoxFit _videoFit = BoxFit.contain;
  double _playbackSpeed = 1.0;

  /// 🔴 2026-10-07：requiresEagerMount 后端（mpv）的常驻视频层实例。
  ///
  /// 必须在整个播放期复用**同一个** widget 实例：PlatformView 一旦被重建，
  /// 原生侧会销毁旧 Player（连同 viewId）并新建一个，导致播放中断、
  /// Dart 侧持有的 _viewId 失效。故缓存后不再重建，仅切换显隐。
  ///
  /// 生命周期：随 [_backend] 一起更换 —— 见 [_initBackend] 与 [_safeDisposeBackend]。
  Widget? _eagerVideoLayer;

  /// 续播定位闸门：有续播点时先关闸，等位置真正抵达（或首帧出画）再显示视频层。
  ///
  /// 【为什么需要】mpv 的续播定位由 open() 透传为 `loadfile ... start=<秒>`，
  /// 在加载时即定位；但纹理一旦挂载，Flutter 就会把 texture 当前内容画到屏幕上。
  /// 若定位尚未落地，观众会先看到片头画面再突变到续播点，即「闪开头」。
  ///
  /// 【闸门做法】续播场景下先让视频层保持隐藏（显示加载指示），
  /// 直到收到首帧信号或 [_position] 进入续播点邻域（±5s）再显示。
  /// 设超时兜底，避免个别源定位永不落地时一直黑屏。
  bool _locateGateOpen = true;

  /// 闸门开始等待的时刻；null 表示未在等待。
  DateTime? _locateGateSince;

  /// 本次起播的续播锚点（毫秒）。0 表示从片头播、无需关闸。
  ///
  /// 在 [_openEpisodeImpl] 中于 open 之前记录，且**此后不再清零**：
  /// 它是「用户想要的位置」而非「当前位置」，清掉会让闸门失去判据。
  int _resumeAnchorMs = 0;

  /// ⚠️ 2026-10-12 直播绿屏诊断：上一次打印的显示状态指纹。
  /// 用「值变化才打印」避免视频页每帧 rebuild 时刷屏。
  String? _greenDiagKey;

  /// 闸门最长等待：超过则强制开闸（宁可闪一下也不能一直黑屏）。
  ///
  /// 🔴 2026-10-23：15s → 6s。荣耀平板实测（legacy 换源日志）：
  ///   某些源不支持 startAt 续播定位，位置流始终为 0 → 既命中不了
  ///   「位置抵达邻域」，也收不到首帧信号 → 闸门**硬等满 15 秒**才兜底开闸，
  ///   表现为「换源后黑屏十几秒」。6s 足够覆盖正常源的定位耗时
  ///   （实测 1~2s），又不会让异常源把用户钉在黑屏里。
  static const Duration _locateGateTimeout = Duration(seconds: 6);
  Timer? _locateGateTimer;

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
    _initialSourceKey =
        _sources.isNotEmpty && _currentSourceIndex < _sources.length
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
    if (duration.inMilliseconds > 0 && pendingAutoSwitch && !_initialized) {
      _autoSwitchTimer?.cancel();
      _autoSwitchTimer = null;
      setState(() {
        _error = null;
        _initialized = true;
      });
    }
  }

  /// [autoOpen] 为 true 时，建好后端后立即起播当前集（首播路径）。
  ///
  /// 🔴 2026-10-23：切集路径需要「只重建后端、不自动起播」，
  ///   否则会与 [_openEpisodeImpl] 形成递归（建后端 → 起播 → 释放后端 → 重建 → …）。
  Future<void> _initBackend({bool autoOpen = true}) async {
    final backend = PlayerBackendFactory.create(_currentPlayerBackend);
    _backend = backend;
    // 后端已更换：丢弃旧的常驻视频层，否则会复用上一个后端的 PlatformView。
    _eagerVideoLayer = null;
    _backend?.fit = _videoFit;
    // 🔴 2026-10-07：立即触发一次重建。requiresEagerMount 的后端（mpv）要在
    //   open() 之前就把 PlatformView 挂进 widget 树，而 _backend 是普通字段、
    //   赋值本身不会触发 build。缺这一次 setState，后续 open() 内部的
    //   endOfFrame 等到的仍是「_backend 为 null」的那一帧 → 依然拿不到 view。
    if (mounted) {
      setState(() {});
    }
    // 🔴 纹理就绪后重建 _buildVideo，让 Texture(textureId) 出画。
    _bindTextureReady(backend);
    _subscriptions
      ..add(
        backend.positionStream.listen((position) {
          _reportBufferHealth(position);
          if (mounted) {
            setState(() => _position = position);
            _evalLocateGate(position.inMilliseconds);
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

  /// 纹理就绪后通知播放页重建视频层。
  /// 原生 registerTexture 拿到 textureId 并经事件通道首条消息回传，
  /// 此时才应让 _buildVideo 切到 Texture(textureId) 出画。
  void _bindTextureReady(VideoPlayerBackend backend) {
    if (backend is MpvBackend) {
      _subscriptions.add(
        backend.textureReadyStream.listen((_) {
          if (mounted) {
            setState(() {});
          }
        }),
      );
    }
  }

  /// 评估续播定位闸门。开闸条件（任一满足）：
  ///   ① 收到**首帧信号**（纹理真正出帧）—— 最可靠的硬信号；
  ///   ② 位置进入续播点邻域（±5s）—— 与①互补，覆盖不出首帧信号的场面；
  ///   ③ 无续播点（从片头播）；
  ///   ④ 超时兜底 —— 宁可闪一下也不能一直黑屏。
  ///
  /// 由位置流订阅、首帧流订阅与 [_openEpisodeImpl] 调用。
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
    if (target <= 0) {
      _openLocateGate('无续播点');
      return;
    }
    // ② 位置已抵达续播点邻域（±5s，容忍 HLS 分片边界偏差）。
    if (positionMs > 0 && (positionMs - target).abs() <= 5000) {
      _openLocateGate('已定位 position=${positionMs}ms');
      return;
    }
    // ④ 超时兜底。
    if (started != null &&
        DateTime.now().difference(started) > _locateGateTimeout) {
      // 🔴 2026-10-23：位置仍为 0 说明**续播定位失败**（该源不支持 seek 到
      //   目标点，实测这类源会让 position 永远停在 0）。此时只开闸仍是黑屏
      //   —— 没有帧可显示。必须主动回退：seek 到 0 让它从头播，
      //   **有画面远好过一直黑屏**。
      if (positionMs <= 0 && target > 0) {
        _resumeAnchorMs = 0;
        _pendingInitialPositionMs = 0;
        debugPrint('续播定位失败（position 仍为 0），回退从头起播');
        final backend = _backend;
        if (backend != null) {
          unawaited(
            backend.seek(Duration.zero).catchError((Object e) {
              debugPrint('续播回退 seek 失败: $e');
            }),
          );
        }
      }
      _openLocateGate('超时兜底 position=${positionMs}ms target=${target}ms');
    }
  }

  void _openLocateGate(String reason) {
    if (_locateGateOpen) return;
    _locateGateOpen = true;
    _locateGateSince = null;
    _locateGateTimer?.cancel();
    _locateGateTimer = null;
    debugPrint('续播定位闸门开启: $reason');
    if (mounted) setState(() {});
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
    _backend?.seek(Duration(milliseconds: targetMs));
  }

  void _checkSkipSegments(Duration position) {
    // 刚切换集数/源的前 2 秒内不处理跳过/自动下一集，避免初始化阶段位置抖动导致误触发。
    final switchAt = _episodeSwitchAt;
    if (switchAt != null &&
        DateTime.now().difference(switchAt) < Duration(seconds: 2)) {
      return;
    }

    final seconds = position.inMilliseconds / 1000.0;
    final totalSeconds = _duration.inMilliseconds / 1000.0;
    if (totalSeconds <= 0) return;

    // 跳过 seek 冷却：触发一次跳过后 3 秒内不再重复触发，避免 seek 后画面未更新
    // 导致位置流仍报告在片头片尾区间内而连续 seek。
    final skipSeekCooldown =
        _lastSkipSeekAt != null &&
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
  Future<bool> _waitForPlayerReady(Duration timeout) async {
    if (_duration.inMilliseconds > 0) return true;
    final start = DateTime.now();
    while (DateTime.now().difference(start) < timeout) {
      if (_duration.inMilliseconds > 0) return true;
      await Future.delayed(Duration(milliseconds: 200));
    }
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
    //    首次进入播放页时 _backend 为 null，helper 自动退化为空操作。
    if (!isFirstOpen) {
      await _stopSaveAndReleaseBackend();
      debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');
      // 🔴 2026-10-23 修复：切集必须清零上一集的续播位置。
      //   播放记录是「每部剧一条」（含 index=集号、playTime=该集秒数），
      //   上一集的位置套到新集上会直接落在错误的时间点（用户实测：记录错乱）。
      _pendingInitialPositionMs = 0;
      debugPrint('[HeinPlay] 切换集：目标 index=$index，续播位置已归零（避免沿用上一集）');
      // 🔴 2026-10-23 修复：释放后必须重建后端。
      //    _stopSaveAndReleaseBackend 会把 _backend 置 null，而下面 tryOpen 用的是
      //    `_backend?.open(...)` —— _backend 为 null 时 Dart 的 ?. 直接短路，
      //    open() 根本不会被调用，tryOpen 只能轮询 _duration 到超时 →
      //    每次切集白等 15 秒后判失败（用户实测：加载反而变慢、记录读不出来）。
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

    // 先加载跳过配置，确保打开播放器前已知片头片尾区间，
    // 避免异步加载完成前错过 startAt 定位时机。
    await _loadSkipConfig();

    final timeoutSeconds = await UserDataService.getAutoSwitchSourceTimeout();
    final openTimeout = Duration(seconds: timeoutSeconds);

    Future<bool> tryOpen(String url, {int initialPositionMs = 0}) async {
      final startTime = DateTime.now();
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
    );
    if (filteredUrl != null && filteredUrl.isNotEmpty) {
      url = filteredUrl;
    }

    // 若已配置自动跳过片头，且待恢复位置落在片头区间内，
    // 则直接从片头结束处开始播放，避免初始化完成后再 seek 失效。
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
        debugPrint('PlayerScreen 片头起始定位: ${openingSegment.end}s');
      }
    }

    // 🔴 记录本次起播的续播锚点（供 _evalLocateGate 判定用）。
    // 必须在 tryOpen 之前记录，且此后不再清零。
    _resumeAnchorMs = _pendingInitialPositionMs;

    // 🔴 续播定位闸门：有续播点时先关闸，等位置真正抵达再显示视频层。
    //    这是消除「闪开头」的关键 —— 无论后端在 open() 后多早开始出帧，
    //    只要视频层未挂载，观众就看不到定位前的片头画面。
    if (_resumeAnchorMs > 0) {
      _locateGateOpen = false;
      _locateGateSince = DateTime.now();
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
      _locateGateTimer?.cancel();
      _locateGateTimer = null;
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
      // ⚠️ fvp / mpv 后端必须跳过这段：
      //   · fvp 的起点定位已由 VideoPlayerBackendImpl 在 initialize() 完成后
      //     **立即**执行（2026-09-22 起不再延后 —— 即「播放记录第一时间读取」）。
      //     若此处赶在 open 后约 200ms 抢先 seek，会在 libmdk 尚未稳定时把它打进冻结：
      //     2026-09-20 17:20 日志实证第 1 次会话「起播稳定」读到的 position 已是续播点
      //     125000ms（即本段先动了手），随后冻结；而换源后未走本段的两次会话
      //     （起播稳定时 position=1520ms）全部一次定位成功。
      //   · mpv 的续播定位由 open() 把 startAt 透传为 `loadfile ... start=<秒>`，
      //     在加载时即定位；此处再 seek 一次属于重复定位，反而会打断首帧。
      if (_currentPlayerBackend == PlayerBackendType.fvp ||
          _currentPlayerBackend == PlayerBackendType.mpv) {
        _pendingInitialPositionMs = 0;
      } else if (_pendingInitialPositionMs > 0) {
        final maxMs = _duration.inMilliseconds > 500
            ? _duration.inMilliseconds - 500
            : _duration.inMilliseconds;
        final clampedMs = _pendingInitialPositionMs.clamp(0, maxMs);
        await Future.delayed(Duration(milliseconds: 200));
        if (mounted) {
          _backend?.seek(Duration(milliseconds: clampedMs));
        }
        _pendingInitialPositionMs = 0;
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

      // 🔴 自动换源同样先停止播放、保存记录、释放旧后端，避免双重解码。
      //   helper 内部走 _safeDisposeBackend（含「先摘引用、等视频层卸载一帧、
      //   再释放」的保护）。
      await _stopSaveAndReleaseBackend();
      debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');

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
      _subscriptions
        ..add(
          backend.positionStream.listen((position) {
            _reportBufferHealth(position);
            if (mounted) {
              setState(() => _position = position);
              _evalLocateGate(position.inMilliseconds);
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
    // 🔴 停止播放 → 保存播放记录 → 释放旧后端（统一链路）。
    //   原先只读 _position 不落播放记录，切源后进度可能丢失。
    //   helper 内部走 _safeDisposeBackend，已含「先卸载视频层、再释放原生播放器」
    //   的保护（下方注释保留，记录 2026-09-19 那次闪退的定位过程）。
    final previousPositionMs = await _stopSaveAndReleaseBackend();
    debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');
    //
    // ---------------------------------------------------------------------
    // 换源 = 释放旧后端 + 新建后端，必须「先卸载视频层，再释放原生播放器」。
    //
    // 2026-09-19 闪退定位（Android，fvp 唯一后端）：
    // fvp(Android) 的 FvpVideoView 在 surfaceCreated 里用**构造时缓存的 player
    // handle** 调 nativeSetSurface；该 handle 在 Dart 侧 controller 被 dispose 的
    // 那一刻就悬垂。libfvp 的 players[surfaceId] 仍保存着指向已销毁 TexturePlayer
    // 的 shared_ptr，只要之后还有一次 surface 回调落到这个 surfaceId 上，
    // mdk::abi::VideoPresenter::updateNativeSurface 就会解引用空的 VideoPresenter
    // → SIGSEGV（fault addr 0x88，进程直接闪退，无 Dart 异常可捕获）。
    //
    // 旧实现的两处缺失（对照 _switchPlayerBackend 已做对）：
    //   1) dispose 后没有把 _backend 置空；
    //   2) setState 里没有把 _initialized 置假，而 _initialized 仍是上一次播放
    //      成功的 true。
    // 于是 setState 之后 _buildVideo() 的判据 (_initialized && _backend != null)
    // 依旧成立，会把已释放的旧 controller / 尚未 initialize 完成的新 controller
    // 立刻送进 widget 树，Android 侧随即重建 platformView 并回调 surfaceCreated，
    // surface 回调就这样打在悬垂的 player handle 上。
    //
    // 修复：先摘掉视频层并等一帧（_buildVideo 走 loading 分支，platformView 卸载），
    // 再 dispose 旧后端；_initialized 保持假直到新源真正就绪。
    // ---------------------------------------------------------------------
    setState(() {
      _currentVideoDetail = response.data!;
      _currentSourceIndex = index;
      _currentEpisodeIndex = previousEpisodeIndex.clamp(
        0,
        response.data!.episodes.length - 1,
      );
      _initialized = false;
      _switchingSource = false;
      _skipConfig = null;
      _skippedSegments.clear();
      _lastSkipSeekAt = null;
      _autoNextTriggered = false;
    });
    _syncPlaybackSourceKey();

    _loadSkipConfig();
    // 切换源后恢复上次播放位置（值来自上方 _stopSaveAndReleaseBackend 的返回值，
    // 已由那里保存过播放记录；此处仅作为续播锚点传给新后端）。
    _pendingInitialPositionMs = previousPositionMs;
    _initBackend();
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

  void _seekBy(Duration delta) {
    final target = _position + delta;
    _backend?.seek(_clampDuration(target));
    _showControlsWithoutFocusShift();
  }

  void _seekToPercent(double percent) {
    final target = Duration(
      milliseconds: (_duration.inMilliseconds * percent).toInt(),
    );
    _backend?.seek(_clampDuration(target));
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
    _controlsTimer = Timer(Duration(seconds: _controlsAutoHideSeconds), () {
      debugPrint('控制栏自动隐藏定时器触发');
      _hideControls();
    });
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
                    case PlayerBackendType.fvp:
                      label = 'FVP';
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
  Future<int> _stopSaveAndReleaseBackend() async {
    final lastPositionMs = _position.inMilliseconds;

    debugPrint('[HeinPlay] 切换操作开始：停止播放 → 保存播放记录 → 释放旧后端');
    // 1) 先落一次播放记录（节流窗口内也强制写，因为这是用户主动切换的明确意图）。
    //    顺序不可颠倒：dispose 之后 _position 不再更新、_isPlaybackReadyForRecord()
    //    里 `_backend != null` 也失效，会直接跳过保存，用户进度丢失。
    if (!_recordSaveInFlight && _isPlaybackReadyForRecord()) {
      await _savePlayRecordToLunaTV();
    }

    // 2) 停止并释放旧后端，复用本工程既有的 _safeDisposeBackend
    //    （含「先摘视频层、等一帧、再 dispose」的原生释放保护）。
    // 🔴 2026-10-23：必须先退订、再 dispose。
    //    dispose() 会关闭后端的全部 StreamController，若此时订阅仍挂着，
    //    期间到达的原生事件会抛「Cannot add new events after calling close」
    //    并中断整个切换流程（表现为播放记录存不下去、切换变慢甚至直接失败）。
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    await _safeDisposeBackend();
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

    // 🔴 停止播放 → 保存播放记录 → 释放旧后端（统一链路）。
    //   helper 内部走 _safeDisposeBackend，已含「先摘引用、等视频层卸载一帧、
    //   再释放」的保护（见 _switchSourceImpl 的详细说明）。
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
      _continuousSeekTimer = Timer.periodic(Duration(milliseconds: 200), (_) {
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
    //    才真正起播，慢源实测可达 12 秒）。此时写盘会用 playTime=0 覆盖掉
    //    切换前刚保存的有效进度 —— 真机（荣耀平板 V8 Pro 2026-10-23）
    //    实测：换源前存了 431s，换源后被覆盖成 0s，
    //    用户侧表现为「换源后读取播放记录失败 / 进度丢失」。
    if (_pendingInitialPositionMs > 0) return false;
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

    // 🔴 2026-10-12 修复「控制栏显示时按返回直接退出播放」：
    //   返回/ESC 键**必须完全交给 PopScope**（见 build() 中的
    //   PopScope.onPopInvokedWithResult：控制栏可见则隐藏，否则退出），
    //   本兜底 handler 不得再消费它。
    //
    //   原因：HardwareKeyboard.instance 的 handler **不理会 KeyEventResult**，
    //   即使 _handleKeyEvent（Focus.onKeyEvent）已 return true「消费」了事件，
    //   本 handler 仍会收到同一次按键。于是返回键被处理两次：
    //     第 1 次：_controlsVisible=true  → _hideControls()（同步置 false）
    //     第 2 次：_controlsVisible 已是 false → _exitPlayer() → 直接退出播放
    //   这正是用户反馈的现象（期望先隐藏控制栏，实际直接退出）。
    //
    //   与直播页对齐：live_player_screen.dart 对 goBack/escape 显式
    //   `return false`，统一由 PopScope 决策，避免双动作。
    if (event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      return false;
    }

    // 仅在当前页面位于栈顶时处理，避免影响其他页面/对话框
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;

    // 控制栏显示时交给焦点系统处理按钮选择，但下键始终兜底处理。
    if (_controlsVisible && event.logicalKey != LogicalKeyboardKey.arrowDown) {
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
        // 🔴 2026-10-12 修复：返回/ESC **不再在此消费**，交回系统 →
        //   Navigator.maybePop → PopScope.onPopInvokedWithResult
        //   （控制栏可见则隐藏，否则 _exitPlayer）统一决策。
        //
        //   原先此处自行判断并 `return true`，与 HardwareKeyboard 兜底 handler
        //   形成双响应：第一次隐藏控制栏，第二次因 _controlsVisible 已为 false
        //   而直接退出播放 —— 用户反馈「有控制栏时按返回直接退出」即此。
        //   与直播页 live_player_screen.dart 的处理保持一致。
        return false;
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
    _continuousSeekTimer = Timer.periodic(Duration(milliseconds: 200), (_) {
      if (!_isLongPressSeeking || _backend == null) return;
      final step = _longPressDirection == 'right'
          ? _seekStep * 3
          : -_seekStep * 3;
      final target = _position + Duration(seconds: step);
      _backend?.seek(_clampDuration(target));
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
    final target = _position + Duration(seconds: deltaSeconds.toInt());
    _backend?.seek(_clampDuration(target));
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
      case PlayerBackendType.fvp:
        return 'FVP';
      case PlayerBackendType.vlc:
        return 'VLC';
      case PlayerBackendType.mpv:
        return 'MPV';
    }
  }

  /// 安全释放播放后端：先摘掉视频 widget（fvp 平台视图从渲染树移除、原生 surface 解绑），
  /// 等一帧后再 dispose player。否则 `_backend.dispose()` 释放 player 后，平台视图拆树
  /// 时的 surface 回调会在已释放的 player 上调用 nativeSetSurface → 空指针闪退
  ///（fault addr 0x0 @ libfvp.so）。详见 MEMORY.md fvp surface 竞态铁律。
  Future<void> _safeDisposeBackend() async {
    final backend = _backend;
    if (backend == null) return;
    _backend = null;
    _initialized = false;
    // 常驻视频层随后端一起丢弃，否则会复用已释放后端的 PlatformView。
    _eagerVideoLayer = null;
    _locateGateTimer?.cancel();
    _locateGateTimer = null;
    _locateGateOpen = true;
    _locateGateSince = null;
    _resumeAnchorMs = 0;
    if (mounted) setState(() {});
    await WidgetsBinding.instance.endOfFrame;
    await backend.dispose();
  }

  /// 安全退出播放页：先拆后端再 pop，避免退出闪退。
  Future<void> _exitPlayer() async {
    await _safeDisposeBackend();
    if (mounted) Navigator.of(context).pop();
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
    _locateGateTimer?.cancel();
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

    // 正常退出已通过 _safeDisposeBackend() 把 _backend 置空并安全释放；
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
      final currentKey =
          _sources.isNotEmpty && _currentSourceIndex < _sources.length
          ? '${_sources[_currentSourceIndex].source}+${_sources[_currentSourceIndex].id}'
          : null;
      if (currentKey != null &&
          currentKey.isNotEmpty &&
          !candidates.contains(currentKey)) {
        candidates.add(currentKey);
      }

      var newIndex = -1;
      for (final key in candidates) {
        if (key.isEmpty || key == '+') continue;
        final index = _sources.indexWhere((s) => '${s.source}+${s.id}' == key);
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
    // 切换源/播放器期间由切换遮罩显示加载提示，避免与视频层加载图标重叠。
    //
    // 🔴 2026-10-07：但 requiresEagerMount 的后端（mpv）**不能在这里早退**！
    //   切换源走 _switchSourceImpl，它先置 _switchingSource=true，再调
    //   _initBackend()→_openEpisodeImpl()→backend.open()。而 open() 要等
    //   PlatformView 创建，PlatformView 又要 buildVideoWidget() 被调用。
    //   若此处因 _switchingSource 返回纯黑，就再次死锁：
    //   open 等 view → view 等 build → build 被 _switchingSource 拦住。
    //   故对这类后端，_switchingSource 期间仍走下面的 eager 挂载分支
    //   （遮罩层已能盖住画面，不需要靠「不挂载」来遮挡）。
    if (_switchingSource && !(_backend?.requiresEagerMount ?? false)) {
      return ColoredBox(color: Colors.black);
    }

    // 🔴 2026-10-07：mpv 必须**提前且常驻**挂载。
    //
    // 【死锁成因】mpv 的原生 Player 实例是在 PlatformView 被 Flutter
    //   创建时才 new 出来的，而 MpvBackend.open() 要等这个 view 的 id。
    //   若此处沿用「_initialized 前不挂载 / 闸门未开不挂载」的既有逻辑，
    //   就会形成闭环死锁：
    //     open() 等 view 创建 → view 要 buildVideoWidget 被调用
    //       → 被 _initialized / 闸门拦住 → 闸门要等位置事件
    //       → 位置事件要 view 创建。
    //
    // 【处理】对 requiresEagerMount 的后端，视频层在 _openEpisodeImpl 一开始就
    //   挂载并**全程保持同一个 widget 实例**（_eagerVideoLayer 缓存），
    //   用不透明黑遮罩来隐藏定位前的画面，从而既不死锁、也不露出片头画面。
    if (_backend != null && _backend!.requiresEagerMount) {
      // 路线 B（对齐鸿蒙版）：mpv 画面走 Flutter 纹理（Texture(textureId)）。
      //    buildVideoWidget() 返回的 AndroidView 仅作「挂载锚点」——它进入渲染树会
      //    触发原生 create→registerTexture 拿到 textureId；本体透明，画面由
      //    Texture(textureId) 叠加显示，二者叠加共存（锚点必常驻，否则 create 不触发）。
      final backend = _backend!;
      final textureId = backend.textureId;
      final textureReady = textureId != null && textureId >= 0;
      final showVideo = _initialized && _locateGateOpen && textureReady;

      // ⚠️ 2026-10-12 直播绿屏诊断（只打印，不改行为）。
      //   实测现象：直播源「一直绿屏但有声音」，点播正常。
      //   绿屏 = Texture 参与了合成但内容未初始化；若 showVideo=false 则应看到
      //   上层 ColoredBox 黑遮罩（黑屏），能看到绿说明**显示路径与预期不一致**。
      //   必须量化三要素的实时值才能判断是哪一环：
      //     _initialized   —— 后端是否已初始化完
      //     _locateGateOpen—— 定位闸门（直播无续播点，应为 true）
      //     textureReady   —— textureId 是否已由原生回传
      //   用「值变化才打印」避免每帧刷屏（视频页会频繁 rebuild）。
      final diagKey =
          '$textureId|$showVideo|$_initialized|$_locateGateOpen|$textureReady';
      if (_greenDiagKey != diagKey) {
        _greenDiagKey = diagKey;
        debugPrint(
          '[绿屏诊断] textureId=$textureId textureReady=$textureReady '
          'initialized=$_initialized gateOpen=$_locateGateOpen showVideo=$showVideo '
          'backend=${backend.runtimeType}',
        );
      }

      final anchor = _eagerVideoLayer ??= backend.buildVideoWidget();
      return SizedBox.expand(
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 挂载锚点（AndroidView，透明），常驻以触发原生 create/registerTexture。
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
      return Center(child: TechLoadingIndicator());
    }
    // 续播定位闸门：位置未抵达续播点前不挂载视频层，避免露出片头画面。
    //    这是「闪开头」的最终兜底 —— 无论后端内部何时开始出帧，只要这里不挂载
    //    画面，观众就看不到定位前的画面。
    if (!_locateGateOpen) {
      return const ColoredBox(color: Colors.black);
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
                  '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
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
                        Icon(Icons.speed, color: Color(0xFFF0F0F5), size: 18),
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
                          Icon(Icons.list, color: Color(0xFFF0F0F5), size: 18),
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
      //
      // 🔴 2026-10-12 修复「有控制栏时按返回直接退出播放」：
      //   原先 canPop 恒为 false，且 _handleKeyEvent / _handleHardwareKeyEvent
      //   里各自处理了一次 goBack，三者叠加导致返回键被消费多次 ——
      //   第一次隐藏控制栏、第二次（此时 _controlsVisible 已为 false）直接退出。
      //   现改为：
      //     · 按键层不再消费 goBack/escape（两个 handler 都 return false）；
      //     · 本 PopScope 成为**唯一**的返回决策点；
      //     · canPop 用条件式（与直播页 live_player_screen.dart 一致）——
      //       控制栏可见时 canPop=false，明确拦截系统返回并触发 onPopInvoked，
      //       比恒 false 更可靠（恒 false 时系统返回的拦截路径依赖
      //       SystemNavigator，个别 Android TV 固件上可能不触发本回调）。
      //   退出仍走 _exitPlayer：先摘视频 widget、等一帧再 dispose 后端，
      //   避免退出时 surface 竞态闪退。
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
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
        style: TextStyle(fontFamily: 'NotoSansSC', color: Color(0xFFF0F0F5)),
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
        style: TextStyle(fontFamily: 'NotoSansSC', color: Color(0xFFF0F0F5)),
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
                    color: selected ? AppColors.primaryTint : Color(0xFF1C1C2E),
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
      ),
    );
  }
}
