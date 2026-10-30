import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/services/playback_activity.dart';
import 'package:hain_tv/models/skip_segment.dart';
import 'package:hain_tv/models/video_detail.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
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

class _MobilePlayerScreenState extends State<MobilePlayerScreen> {
  late VideoDetail _currentVideoDetail;
  late int _currentSourceIndex;
  // 记录进入播放页时详情页选中的源标识，用于 sourcesNotifier 更新后
  // 仍能准确找回当前源，避免仅依赖 VideoDetail 的 source/id 匹配失败
  // 导致播放源被重置到列表首位。
  String? _initialSourceKey;
  VideoPlayerBackend? _backend;
  bool _switchingBackend = false; // fvp 续播卡死→原地重建 fvp 后端过程中防重入
  int _fvpStallRetries = 0; // fvp 续播卡死重建次数（防止无限重建循环）
  static const int _kMaxFvpStallRetries = 2; // 最多重建 2 次，仍失败则放弃自动恢复
  final PlayerSwitchGate _switchGate = PlayerSwitchGate();
  late int _currentEpisodeIndex;
  bool _controlsVisible = true;
  bool _controlsLocked = false;
  bool _lockIndicatorVisible = false;
  Timer? _lockIndicatorTimer;
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

  /// 🔴 提前常驻挂载的视频层缓存（见 [VideoPlayerBackend.requiresEagerMount]）。
  ///
  /// mpv 的原生实例在 PlatformView 被 Flutter 创建时才 new 出来，而
  /// `MpvBackend.open()` 要等该 view 的 id。若 `_buildVideo()` 因
  /// `_initialized == false` 而不挂载视频层，就构成闭环死锁：
  ///   open 等 view → view 等 buildVideoWidget → 被 _initialized 拦住
  ///     → _initialized 等 open 成功。
  /// 故对 requiresEagerMount 的后端，缓存**同一个 widget 实例**并全程挂载；
  /// 定位前的画面由不透明遮罩盖住。
  Widget? _eagerVideoLayer;

  /// mpv 画面所在的 Flutter 外部纹理 id（原生经事件通道首条消息回传）。
  ///
  /// 🔴 纹理路线下**画面只能靠它出**：原生给的 PlatformView 只是零尺寸锚点。
  ///    为 null 时说明原生还没把纹理注册结果推回来，此时保持黑场即可。
  int? _mpvTextureId;

  // 🔴 2026-10-15：原有两个字段 `_videoAspectWidth/_videoAspectHeight`
  //    （写死 1920x1080）已删除。它们只被 `FittedBox` 用来对纹理做二次
  //    缩放，而那个尺寸**从未随视频真实宽高比更新过**，正是点播画面
  //    左右拉伸的直接原因。现在纹理裸铺满、比例交由 mpv 依
  //    video-params + keepaspect/panscan 自行计算，见 buildVideoArea
  //    中的说明。

  // 固定快进快退步长
  static const int _seekStep = 20;
  static const int _controlsAutoHideSeconds = 10;
  late int _pendingInitialPositionMs;

  /// 🔴 2026-10-17 起播精确定位的**观测埋点**（TV 版已有，手机版本次补齐）。
  ///
  /// 取值 > 0 表示「本次起播带了定位目标，且**尚未落地**」。
  ///
  /// 【2026-10-23 真机铁证（手机版 mpv 后端）】
  ///   手机版点播进入播放三次，只有第一次出现「先跳开头 → 再到播放记录」，
  ///   第二、三次正常；TV 版（exo 后端）全程正常。
  ///   根因：mpv 后端的起播定位（startAt）是**异步**的，起播瞬间位置流仍上报 0，
  ///   而 0 必然落在片头区间 [0, openingEnd] 内 ⇒ 误触发自动跳过片头，
  ///   把画面 seek 到片头结束处；紧接着续播定位落地，画面又跳回播放记录。
  ///   exo 后端的起播定位在位置流建立前就已完成，因此不会踩到这个窗口。
  ///
  /// 【为什么用 mpv 会更明显】
  ///   首次进入时 skip 配置的网络请求比播放器起播慢（配置晚到），
  ///   于是「起播定位未落地」窗口与「片头配置已就绪」发生重叠；
  ///   第二、三次进入网络更快（连接已建立/服务端已缓存），
  ///   配置在起播前就位，窗口不重叠 —— 所以只有第一次出问题。
  ///   这解释了「只有第一次」和「mpv 有、exo 没有」两个现象。
  ///
  /// 【修复方式】起播定位**未落地期间不参与片头/片尾判定**，
  ///   落地后自动恢复正常判定；定位失败（超时）也自动解除，不会永久屏蔽。
  ///   ⚠️ 这不是禁用跳过片头（用户明确要求保留该功能）：
  ///     · 从头播放（无续播点）⇒ _pendingStartTargetMs == 0 ⇒ 照常跳过 ✅
  ///     · 从播放记录恢复 ⇒ 落地后 position 已在片头区间之外 ⇒ 也不会触发 ✅
  ///     · 播放记录本身就落在片头区间 ⇒ 由「片头起始定位」提前处理，不依赖此处。
  int _pendingStartTargetMs = 0;
  DateTime? _pendingStartAt;

  bool _isRecordSaveThrottled = false;
  bool _recordSaveInFlight = false;

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
        debugPrint('MobilePlayerScreen: 应用退到后台，已暂停播放');
      },
      onResume: () {
        if (!_pausedByLifecycle) return;
        _pausedByLifecycle = false;
        unawaited(_backend?.play() ?? Future<void>.value());
        debugPrint('MobilePlayerScreen: 应用回到前台，已恢复播放');
      },
    );
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
      await WakelockPlus.enable();
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

    try {
      _currentVolume = await VolumeController.instance.getVolume();
      debugPrint('MobilePlayerScreen: 当前音量 $_currentVolume');
    } catch (e) {
      debugPrint('MobilePlayerScreen: 获取音量失败: $e');
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
        '[FVP-REOPEN] fvp 续播卡死已重建 $_kMaxFvpStallRetries 次仍失败，放弃自动恢复',
      );
      return;
    }
    _fvpStallRetries++;
    _switchingBackend = true;
    Future.microtask(() => _reopenFvpOnStall());
  }

  /// fvp 救不活时：释放当前 fvp 后端，原地重建 fvp 后端，并从冻结的续播点继续播放
  /// （不再从片头重启，避免「读取播放记录后自动重新开始」）。保持 fvp 后端，不切 ExoPlayer。
  /// 重建经由 prepare(position:) 原生定位续播点，绕开读取器死寂竞态。
  Future<void> _reopenFvpOnStall() async {
    if (!mounted) {
      _switchingBackend = false;
      return;
    }
    final resumeMs = _position.inMilliseconds; // 冻结位置即续播点
    debugPrint(
      '[FVP-REOPEN] fvp 续播卡死，原地重建 fvp 后端（续播点=$resumeMs ms，第 $_fvpStallRetries/$_kMaxFvpStallRetries 次）',
    );

    // 注销旧 fvp 后端监听器并释放
    for (final s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
    await _backend?.dispose();
    _backend = null;

    // 保持 fvp 后端（不切 ExoPlayer），从续播点恢复，不丢进度。
    _pendingInitialPositionMs = resumeMs;

    final backend = PlayerBackendFactory.create(_currentPlayerBackend);
    _backend = backend;
    // 🔴 换后端必须丢弃旧的 eager 视频层缓存，否则会继续渲染上一个后端的
    //    widget（其 PlatformView 已被 dispose），画面永远出不来。
    _eagerVideoLayer = null;
    _mpvTextureId = null;
    _backend?.fit = _videoFit;
    backend.onUnrecoverableStall = _onFvpStallUnrecoverable;
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

  /// 订阅 mpv 的纹理就绪流：拿到 textureId 后重建视频层，让
  /// `Texture(textureId)` 出画。非 mpv 后端直接跳过。
  ///
  /// 🔴 纹理 id 是**异步**由原生经事件通道回传的，而 `buildVideoWidget()`
  ///    必须在它之前就已挂载（否则原生 PlatformView 不创建、纹理也不会注册），
  ///    所以这里必须是「挂载 → 等 textureId → setState 重建」的顺序。
  ///
  /// 🔴🔴 2026-10-21 桌面端「点播有声音无画面 / 直播一直加载」根因：
  ///    此处原先只判断 `backend is! MpvBackend`。
  ///    但桌面 Linux/Windows 走的是 **`MpvDesktopBackend`**，它和
  ///    `MpvBackend` 是**两个互不相干的类**（都只 `implements
  ///    VideoPlayerBackend`，没有继承关系）→ 该判断对桌面恒为真
  ///    → 直接 return，**textureId 永远不被监听** → `_mpvTextureId` 恒为
  ///    null → 视频层里那个 `Texture(textureId:)` 分支永不构建 →
  ///    Flutter 从不采样外部纹理 → 壳侧 `populate` 调用 **0 次**。
  ///    而 mpv 内核此时解码、出声、渲染帧计数全都正常，
  ///    表现正是「有声音、无画面」，与用户实测完全一致。
  ///
  ///    真机铁证：渲染帧已到 #661、`纹理已注册 id=...` 正常，
  ///    但 `populate 次数: 0`，且日志中无任何「收到 mpv textureId」。
  ///
  ///    修法：不再按具体类判断，改为按**能力**判断——两个 mpv 后端都提供
  ///    `textureReadyStream`，用 dynamic 调用即可覆盖桌面与移动两条链路。
  void _attachMpvTextureListener(dynamic backend) {
    // 按能力判断：只处理提供 textureReadyStream 的后端（mpv 家族）。
    // 不用 `is MpvBackend`，否则会漏掉桌面端的 MpvDesktopBackend。
    // 🔴 2026-10-21 实锤：点播段 `hasListener=false` 但 `_textureId` 已有值，
    //    说明 `is MpvDesktopBackend` 判断在 AOT 下没命中（直播页同样写法却命中了），
    //    监听器从未挂上；textureId 只由事件通道写进 `_textureId`，而流上无人听。
    //    改为 duck-typing：只要后端暴露了 `textureReadyStream` 就订阅，
    //    彻底摆脱类型判断。用 dynamic 访问，避免静态类型不匹配。
    Stream<int>? stream;
    try {
      final dynamic dyn = backend;
      final Object? s = dyn.textureReadyStream;
      if (s is Stream<int>) stream = s;
    } catch (_) {
      stream = null;
    }
    // 🔴 诊断（2026-10-21）：点播段 hasListener=false，需确认此方法是否真被
    //    调用、backend 运行时类型是什么。确认后移除。
    debugPrint('[MPV-DIAG] attach 监听 backend=${backend.runtimeType} '
        'stream=${stream == null ? "null" : "ok"}');
    if (stream == null) return;
    _subscriptions.add(
      stream.listen((tid) {
        if (!mounted) return;
        debugPrint('播放页收到 mpv textureId=$tid，重建视频层出画');
        setState(() => _mpvTextureId = tid);
      }),
    );
    // 🔴 时序兜底：init 往往早于本监听建立，那一帧的 textureId 事件已经丢了。
    //    订阅后立刻主动读一次当前值，不等下一次推送。
    try {
      final dynamic dyn = backend;
      final Object? cur = dyn.currentTextureId;
      if (cur is int && cur >= 0) {
        debugPrint('播放页补取 mpv textureId=$cur（监听建立时已有）');
        // 下一帧再 setState，避免在 initState 同步阶段调用。
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
    // 🔴 换后端必须丢弃旧的 eager 视频层缓存，否则会继续渲染上一个后端的
    //    widget（其 PlatformView 已被 dispose），画面永远出不来。
    _eagerVideoLayer = null;
    _mpvTextureId = null;
    _backend?.fit = _videoFit;
    backend.onUnrecoverableStall = _onFvpStallUnrecoverable;
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
          // 播放器原生完成事件作为兜底，防止 position 流未精确到片尾时漏切。
          if (mounted &&
              !_autoNextTriggered &&
              _currentEpisodeIndex < _currentVideoDetail.episodes.length - 1) {
            _autoNextTriggered = true;
            debugPrint('播放器报告播放完成，触发下一集');
            _nextEpisode();
          }
        }),
      );

    // 🔴 mpv 这类 requiresEagerMount 的后端要等 PlatformView 创建
    //    （`_onViewCreated` 拿到 viewId）才能下发命令。`_initBackend` 在
    //    initState 里同步调用时 build 尚未跑过，直接 open() 会白等满
    //    MpvBackend 的 5 秒轮询后抛「等待 AndroidView view 创建超时」。
    //    这里先触发一次 setState + 让出一帧，确保视频层有创建机会。
    if (backend.requiresEagerMount) {
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }

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
    _backend?.seek(Duration(milliseconds: targetMs));
  }

  /// 起播定位落地的判定容差（ms）。
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

  /// 起播定位是否已落地（或超时放弃）。
  ///
  /// 落地 ⇒ 解除「未落地期间不参与片头/片尾判定」的守卫；
  /// 超时 ⇒ seek 没生效（源不支持/网络失败），解除守卫并留日志，
  ///         避免永久屏蔽片头跳过。
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

    // 🔴🔴🔴 2026-10-23（与 TV 版 2026-10-18 修复同源）：起播定位**尚未落地**时，
    // 不得参与跳过片头。
    //
    //   mpv 后端起播定位是异步的，起播瞬间 position 流仍上报 0
    //   （真实位置还没建立），0 必然落在片头区间 [0, openingEnd] 内
    //   ⇒ 误触发自动跳过，把画面 seek 到片头结束处；
    //   紧接着续播定位落地，画面又跳回播放记录 —— 即用户看到的
    //   「先跳开头，再到播放记录」。
    //
    //   ⚠️ 这不是禁用跳过片头：
    //     · 从头播放（无续播点）⇒ _pendingStartTargetMs == 0 ⇒ 照常跳过 ✅
    //     · 从播放记录恢复 ⇒ 落地后 position 已不在片头区间 ⇒ 也不会触发 ✅
    //   唯一差别是「不在起播暂态期间做判断」，属**排序修正**而非功能阉割。
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
          _backend?.seek(Duration(milliseconds: clampedMs));
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

  Future<void> _openEpisodeImpl(
    int index, {
    bool isStallRecovery = false,
    bool isFirstOpen = false,
  }) async {
    // 非卡死重建的正常开播：清零 fvp 续播卡死重建计数，避免上次残留计数误杀本次。
    if (!isStallRecovery) {
      _fvpStallRetries = 0;
    }
    final episodes = _currentVideoDetail.episodes;
    if (index < 0 || index >= episodes.length) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

    // 🔴 切集：先停止播放、保存播放记录、释放旧后端，再加载新集。
    //    fvp 续播卡死的原地重建（isStallRecovery）与首次开播都不走这里 ——
    //    前者复用同一后端、仅重建实例，后者 _backend 尚为 null。
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
      // 观测埋点：记录本次起播的定位目标，落地/超时由 _maybeClearPendingStartPosition 记日志。
      // 目标 > 0 期间（起播定位未落地）不参与片头/片尾判定，避免 mpv 后端
      // 起播瞬间上报的 0 被误判为「正在片头」而误触发自动跳过。
      if (initialPositionMs > 0) {
        _pendingStartTargetMs = initialPositionMs;
        _pendingStartAt = DateTime.now();
        debugPrint('起播定位已登记 target=${initialPositionMs}ms');
      }
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
            .timeout(openTimeout);

        // 等待播放器真正就绪（获取到有效时长），总耗时不超过 openTimeout
        final elapsed = DateTime.now().difference(startTime);
        final remaining = openTimeout - elapsed;
        final ready = remaining > Duration.zero
            ? await _waitForPlayerReady(remaining)
            : _duration.inMilliseconds > 0;
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
        debugPrint('MobilePlayerScreen 片头起始定位: ${openingSegment.end}s');
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
            _backend?.seek(Duration(milliseconds: clampedMs));
          }
          debugPrint(
            '[HeinPlay] 已定位到恢复点: ${clampedMs}ms（时长=${durMs}ms）',
          );
          _pendingInitialPositionMs = 0;
        }
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
      // 🔴 换后端必须丢弃旧的 eager 视频层缓存，理由同 _initBackend。
      _eagerVideoLayer = null;
    _mpvTextureId = null;
      _backend?.fit = _videoFit;
      backend.onUnrecoverableStall = _onFvpStallUnrecoverable;
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
      _switchGate.run(
        () => _switchSourceImpl(index),
        label: 'mobile 换源 #$index',
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
      // 🔴 停止播放 → 保存播放记录 → 释放旧后端（统一链路）。
      //   原先只读 _position 不落播放记录，用户切源后进度可能丢失。
      final previousPositionMs = await _stopSaveAndReleaseBackend().timeout(
        // 🔴 2026-10-23：释放旧后端带超时。该步骤内部含「保存播放记录」，
        //   一旦存储层或原生回调不返回，整个换源（连同闸门队列）都会挂死。
        const Duration(seconds: 30),
        onTimeout: () {
          debugPrint('[HeinPlay] 停止/释放旧后端超时，继续走换源起播');
          return 0;
        },
      );
      debugPrint('[HeinPlay] 旧后端已释放（播放记录已落盘），进入重建/起播阶段');

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
      _initBackend();
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
    _showControls();
  }

  Duration _clampDuration(Duration value) {
    if (value < Duration.zero) return Duration.zero;
    if (value > _duration) return _duration;
    return value;
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

    // 2) 停止并释放旧后端。必须先 await dispose 完成再返回，
    //    否则平台播放器会在后台继续播放。
    final previousBackend = _backend;
    _backend = null;
    // 先摘引用并等一帧，让视频层（PlatformView）先卸载，再释放原生播放器。
    // 否则 Android 侧重建 platformView 时 surface 回调可能打到已释放的
    // player handle 上（fvp 时代实测 SIGSEGV 闪退，mpv/exo 同样有风险）。
    if (mounted) {
      setState(() => _initialized = false);
      // 🔴 2026-10-23：endOfFrame 在无帧调度时可能长时间不返回，必须带超时。
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
    // 🔴 2026-10-23：原生 dispose 可能阻塞，必须带超时，
    //   避免整个切源流程（含闸门队列）永久挂死。
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
    //    才真正起播，慢源可达 12 秒）。此时写盘会用 playTime=0 覆盖掉
    //    切换前刚保存的有效进度 —— 真机（荣耀平板 V8 Pro 2026-10-23）
    //    实测：换源前存了 431s，换源后被覆盖成 0s，
    //    用户侧表现为「换源后读取播放记录失败 / 进度丢失」。
    if (_pendingStartTargetMs > 0) return false;
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
    _continuousSeekTarget = _position;
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
      _backend?.seek(_clampDuration(_continuousSeekTarget));
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
      // fvp 已摘除，保留分支仅为穷尽 switch（历史存储值由迁移兜底）
      case PlayerBackendType.fvp:
        return 'FVP（已移除）';
      case PlayerBackendType.vlc:
        return 'VLC';
      case PlayerBackendType.mpv:
        return 'MPV';
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
    if (mounted) {
      setState(() {
        _initialized = false;
        // 🔴 2026-10-29 真机复盘：退出播放页时必须**同时清掉 mpv 纹理 id**。
        //   原生 dispose 会 release 对应的 SurfaceProducer，而 Dart 侧若仍持有
        //   textureId，widget 树里就还挂着指向「已失效纹理」的 Texture
        //   → 渲染管线采样失败 → Android 停止提交新帧 → 画面停在最后一帧
        //   （用户表现为「退出播放页后卡死」；实测日志：
        //     EGL_BAD_MATCH / updateAcquireFence: Did not find frame /
        //     SurfaceSyncGroup: Failed to receive transaction ready in 1000ms）。
        _mpvTextureId = null;
      });
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
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _controlsTimer?.cancel();
    _lockIndicatorTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _clockTimer?.cancel();
    _autoSwitchTimer?.cancel();
    _initialPositionRestoreTimer?.cancel();
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
    WakelockPlus.disable().catchError((e) {
      debugPrint('MobilePlayerScreen: 禁用屏幕常亮失败: $e');
    });

    widget.sourcesNotifier?.removeListener(_onSourcesChanged);

    // 若已经由 [_handleBack] 触发退出，则所有资源释放、方向/UI 恢复均已在该路径中
    // 调度，dispose 中不再重复执行，避免两次方向恢复、两次播放器释放竞争导致卡死。
    if (_isExiting) {
      _backend = null;
      super.dispose();
      return;
    }

    // 非用户主动退出（如路由被直接替换）时的兜底清理：将后端释放、代理释放、
    // 方向恢复、系统 UI 恢复推迟到路由转场完成后异步执行，避免阻塞 dispose。
    final backend = _backend;
    _backend = null;
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
      final rawPos = _position.inSeconds;
      // 🔴 2026-10-23：起播位置为 0 时**不得覆盖**已有的有效进度。
      //   真机（荣耀平板 V8 Pro 2026-10-23 14:58，手机版换源到 zuidazy.co）：
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
    if (_isExiting) {
      return ColoredBox(color: Colors.black);
    }

    // 🔴 mpv 这类 requiresEagerMount 的后端：视频层必须**提前且常驻**挂载，
    //    否则 open() 等 view、view 等 buildVideoWidget、buildVideoWidget 等
    //    _initialized、_initialized 又等 open() —— 闭环死锁，播放永远起不来。
    //    真机实测：点播卡满 5 秒后抛「等待 AndroidView view 创建超时」。
    //    这里**不**受 _switchingSource / _initialized 早退影响：遮罩层已能盖住
    //    画面，不需要靠「不挂载」来遮挡。widget 实例全程复用，避免重建 view。
    final eager = _backend?.requiresEagerMount ?? false;
    if (eager && _backend != null) {
      _eagerVideoLayer ??= _backend!.buildVideoWidget();
      return Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.black),
          // 🔴 mpv 画面走 Flutter 外部纹理：原生只给一个零尺寸占位锚点，
          //    真正的画面是这里叠上去的 `Texture(textureId)`。
          //    真机铁证（未改前）：解码已通（`● Video`/`● Audio` 都解出来了、
          //    强制 GL 路线连 `VO: [gpu-next]` 都出了），却因为原路线是
          //    SurfaceView 直画 ANativeWindow 而永远到不了屏幕。
          //
          // 🔴🔴 2026-10-15 点播画面左右拉伸的根因：此处原先包了
          //    `FittedBox(fit: _videoFit, child: SizedBox(1920x1080, child: Texture))`。
          //    那个 1920x1080 是**写死的常量**（_videoAspectWidth/Height 全文件
          //    只在声明处赋值、从无更新），并不是视频的真实宽高比。于是产生
          //    **两次错误缩放**：
          //      ① mpv 把视频铺满 2560x1600 的 Surface（android-surface-size
          //         即屏幕物理分辨率）—— 这是第一次拉伸；
          //      ② FittedBox 再把这个「16:9 的块」贴合屏幕 —— 第二次缩放，
          //         而且基准比例本身就是错的。
          //    exo 之所以比例正确，是因为它走 SurfaceView 直出，由
          //    SurfaceFlinger/HWC 按视频真实宽高比合成，完全不经过这一层。
          //    修法（与 legacy 工程一致）：裸 `Texture` 直接铺满，**由 mpv
          //    自己**依据 video-params 与 keepaspect/panscan 计算留黑边或裁剪
          //    （默认 keepaspect=yes 即「原始比例 + 不裁剪」，正是用户期望的
          //    默认表现）。前端 _videoFit 的三态切换经 setFit 下发到 mpv。
          if (_mpvTextureId != null)
            Texture(textureId: _mpvTextureId!),
          _eagerVideoLayer!,
          // 未就绪前用不透明黑遮罩盖住视频层，避免露出定位前的片头画面。
          if (!_initialized) const ColoredBox(color: Colors.black),
          if (!_initialized) const Center(child: TechLoadingIndicator()),
        ],
      );
    }

    // 切换源/播放器期间由切换遮罩显示加载提示，避免与视频层加载图标重叠。
    if (_switchingSource) {
      return ColoredBox(color: Colors.black);
    }
    if (!_initialized || _backend == null) {
      return Center(
        child: TechLoadingIndicator(),
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
