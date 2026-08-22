import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/models/skip_segment.dart';
import 'package:hain_tv/models/video_detail.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/player/video_player_backend.dart';
import 'package:hain_tv/services/ad_filter_engine.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/windows/skip_config_dialog.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/platform/windows_fullscreen_mixin.dart';
import 'package:hain_tv/platform/windows_window_utils.dart';

class WindowsPlayerScreen extends StatefulWidget {
  final VideoDetail videoDetail;
  final int episodeIndex;
  final List<SourceOption>? sources;
  final ValueNotifier<List<SourceOption>>? sourcesNotifier;
  final int initialSourceIndex;
  final PlayerBackendType playerBackend;
  final int initialPositionMs;

  const WindowsPlayerScreen({
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
  State<WindowsPlayerScreen> createState() => _WindowsPlayerScreenState();
}

class _WindowsPlayerScreenState extends State<WindowsPlayerScreen>
    with WindowsFullscreenMixin<WindowsPlayerScreen> {
  late VideoDetail _currentVideoDetail;
  late int _currentSourceIndex;
  // 记录进入播放页时详情页选中的源标识，用于 sourcesNotifier 更新后
  // 仍能准确找回当前源，避免仅依赖 VideoDetail 的 source/id 匹配失败
  // 导致播放源被重置到列表首位。
  String? _initialSourceKey;
  VideoPlayerBackend? _backend;
  late int _currentEpisodeIndex;
  bool _controlsVisible = true;
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

  // 快进/快退手势标识
  bool _gestureIndicatorVisible = false;
  String _gestureIndicatorText = '';
  IconData _gestureIndicatorIcon = Icons.fast_forward;
  Timer? _gestureIndicatorTimer;

  // Windows 小窗播放状态
  bool _isMiniPlayer = false;
  bool _togglingMiniPlayer = false;
  Rect? _previousWindowBounds;
  TitleBarStyle _previousTitleBarStyle = TitleBarStyle.normal;
  bool _isAlwaysOnTop = false;
  bool _wasFullScreenBeforeMini = false;

  // Windows 全屏鼠标自动隐藏（仅全屏时启用）
  /// 鼠标无操作自动隐藏定时器。
  Timer? _mouseInactivityTimer;
  /// 当前光标是否已隐藏。
  bool _isCursorHidden = false;
  /// 鼠标无操作多少秒后自动隐藏光标。
  static const Duration _kMouseHideDelay = Duration(seconds: 5);

  /// window_manager 的 SetMaximumSize 不支持 Size.infinite（会传一个异常值给
  /// Windows MINMAXINFO，导致窗口最大尺寸被限制为 0 或极小值），因此用一个大尺寸
  /// 常量代替“无限制”。
  static const Size _kUnboundedSize = Size(100000, 100000);

  /// 普通窗口最小尺寸，进入/恢复普通模式时使用。
  static const Size _kNormalMinSize = Size(900, 600);

  /// 小窗模式最小尺寸。
  static const Size _kMiniMinSize = Size(320, 180);

  /// 判断保存的窗口边界是否为正常窗口尺寸。
  bool _isValidNormalBounds(Rect? bounds) {
    if (bounds == null) return false;
    return bounds.width >= _kNormalMinSize.width &&
        bounds.height >= _kNormalMinSize.height;
  }

  /// 判断窗口边界是否接近屏幕尺寸（用于排除全屏状态）。
  bool _isNearScreenSize(Rect bounds) {
    try {
      final view = View.of(context);
      final pixelRatio = view.devicePixelRatio;
      final displaySize = view.display.size;
      final screenWidth = displaySize.width / pixelRatio;
      final screenHeight = displaySize.height / pixelRatio;
      return bounds.width >= screenWidth * 0.95 &&
          bounds.height >= screenHeight * 0.95;
    } catch (e) {
      return false;
    }
  }

  EpisodeSkipConfig? _skipConfig;
  bool _skipConfigLoading = false;
  final Set<String> _skippedSegments = {};
  bool _autoNextTriggered = false;

  /// 记录最近一次触发片头片尾跳过 seek 的时间，避免 seek 后位置未立即更新导致重复触发。
  DateTime? _lastSkipSeekAt;

  final List<StreamSubscription> _subscriptions = [];
  Timer? _controlsTimer;
  Timer? _clockTimer;
  Timer? _autoSwitchTimer;
  DateTime _currentTime = DateTime.now();

  // 固定快进快退步长
  static const int _seekStep = 20;
  static const int _controlsAutoHideSeconds = 10;
  late int _pendingInitialPositionMs;
  bool _isRecordSaveThrottled = false;

  // 标记是否有弹窗打开，打开时禁止控制栏自动隐藏。
  bool _dialogOpen = false;

  /// 最近一次切换集数/源的时间，用于跳过片头片尾时避免初始化阶段位置抖动。
  DateTime? _episodeSwitchAt;

  List<SourceOption> get _sources =>
      widget.sourcesNotifier?.value ?? widget.sources ?? [];
  bool get _canSwitchSource => _sources.isNotEmpty;

  @override
  void initState() {
    super.initState();
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
    _initBackend();
    _initWakelock();
    _startClock();
    initWindowsFullscreen();
    _resetMouseTimer();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (mounted) {
        HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
      }
      if (DeviceUtils.isWindows && mounted) {
        try {
          final bounds = await windowManager.getBounds();
          if (_isValidNormalBounds(bounds) && !_isNearScreenSize(bounds)) {
            _previousWindowBounds = bounds;
          } else {
            _previousWindowBounds = null;
          }
          debugPrint('Windows 播放页初始化保存窗口边界: $_previousWindowBounds');
        } catch (e) {
          debugPrint('Windows 播放页初始化保存窗口边界失败: $e');
        }
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
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
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
    // 如果因超时/异常导致界面显示了播放失败提示，但实际视频已初始化成功（获取到有效时长），
    // 则取消待执行的自动换源并清除错误。
    if (duration.inMilliseconds > 0 && !_initialized) {
      _autoSwitchTimer?.cancel();
      _autoSwitchTimer = null;
      setState(() {
        _error = null;
        _initialized = true;
      });
    }
  }

  Future<void> _initBackend() async {
    final backend = PlayerBackendFactory.create(_currentPlayerBackend);
    _backend = backend;
    _backend?.fit = _videoFit;
    _subscriptions
      ..add(
        backend.positionStream.listen((position) {
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

    await _openEpisode(_currentEpisodeIndex);
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
        DateTime.now().difference(switchAt) < const Duration(seconds: 2)) {
      return;
    }

    final seconds = position.inMilliseconds / 1000.0;
    final totalSeconds = _duration.inMilliseconds / 1000.0;
    if (totalSeconds <= 0) return;

    // 跳过 seek 冷却：触发一次跳过后 3 秒内不再重复触发，避免 seek 后画面未更新
    // 导致位置流仍报告在片头片尾区间内而连续 seek。
    final skipSeekCooldown =
        _lastSkipSeekAt != null &&
        DateTime.now().difference(_lastSkipSeekAt!) <
            const Duration(seconds: 3);

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
      await Future.delayed(const Duration(milliseconds: 200));
    }
    return _duration.inMilliseconds > 0;
  }

  Future<void> _openEpisode(int index) async {
    final episodes = _currentVideoDetail.episodes;
    if (index < 0 || index >= episodes.length) return;

    _autoSwitchTimer?.cancel();
    _autoSwitchTimer = null;

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

    var success = await tryOpen(
      url,
      initialPositionMs: _pendingInitialPositionMs,
    );

    if (!mounted) return;

    // 如果判定失败，但当前源实际已就绪（duration 有效），修正为成功，
    // 避免初始化较慢或 open 抛出异常但仍在后台播放的源误报失败。
    if (!success && _backend != null && _duration.inMilliseconds > 0) {
      debugPrint('PlayerScreen 当前源已就绪，修正失败判定为成功');
      _error = null;
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
      if (_pendingInitialPositionMs > 0) {
        final maxMs = _duration.inMilliseconds > 500
            ? _duration.inMilliseconds - 500
            : _duration.inMilliseconds;
        final clampedMs = _pendingInitialPositionMs.clamp(0, maxMs);
        await Future.delayed(const Duration(milliseconds: 200));
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
        final switched = await _tryAutoSwitchSource(
          index,
          timeoutSeconds: timeoutSeconds,
        );
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

      _loadSkipConfig();

      final backend = PlayerBackendFactory.create(_currentPlayerBackend);
      _backend = backend;
      _backend?.fit = _videoFit;
      _subscriptions
        ..add(
          backend.positionStream.listen((position) {
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

  Future<void> _switchSource(int index) async {
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
    final previousPositionMs = _position.inMilliseconds;

    await _backend?.dispose();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

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

    _loadSkipConfig();
    // 切换源后恢复上次播放位置
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
    // 弹窗打开时保持控制栏可见，不启动隐藏定时器
    if (_dialogOpen) return;
    _controlsTimer?.cancel();
    _controlsTimer = Timer(
      const Duration(seconds: _controlsAutoHideSeconds),
      () {
        debugPrint('控制栏自动隐藏定时器触发');
        _hideControls();
      },
    );
  }

  void _showControls() {
    debugPrint('显示控制栏');
    setState(() => _controlsVisible = true);
    _startControlsTimer();
  }

  void _showControlsWithoutFocusShift() {
    debugPrint('显示控制栏（不移动焦点）');
    setState(() => _controlsVisible = true);
    _startControlsTimer();
  }

  void _hideControls() {
    // 弹窗打开时不隐藏控制栏
    if (_dialogOpen) return;
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

  // 快进/快退时显示手势标识，1 秒后自动隐藏。
  void _showGestureIndicator(String text, IconData icon) {
    setState(() {
      _gestureIndicatorVisible = true;
      _gestureIndicatorText = text;
      _gestureIndicatorIcon = icon;
    });
    _gestureIndicatorTimer?.cancel();
    _gestureIndicatorTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _gestureIndicatorVisible = false);
      }
    });
  }

  /// 快进/快退手势标识浮层（居中显示，样式与手机/TV 版一致）。
  Widget _buildGestureIndicator() {
    if (!_gestureIndicatorVisible) return const SizedBox.shrink();
    return Center(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.bgOverlay,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(_gestureIndicatorIcon, color: AppColors.textPrimary, size: 32),
            const SizedBox(height: AppSpacing.sm),
            Text(
              _gestureIndicatorText,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
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
        return AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: const Text(
            '切换播放源',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 480,
            height: 360,
            child: ListView.builder(
              itemCount: _sources.length,
              itemBuilder: (context, index) {
                final source = _sources[index];
                final selected = index == _currentSourceIndex;
                final speedText = _formatSpeed(source.speed);
                final resolutionText = source.resolution?.trim() ?? '';
                return ListTile(
                  selected: selected,
                  selectedTileColor: AppColors.primaryTint,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: BorderSide(
                      color: selected ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  leading: selected
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : Text(
                          'No.${index + 1}',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: selected
                                ? AppColors.primary
                                : AppColors.textSecondary,
                          ),
                        ),
                  title: Text(
                    source.title,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                  ),
                  subtitle: Text(
                    '${source.sourceName}${speedText.isNotEmpty ? ' · $speedText' : ''}${resolutionText.isNotEmpty ? ' · $resolutionText' : ''}',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 13,
                      color: selected
                          ? AppColors.primary.withValues(alpha: 0.8)
                          : AppColors.textSecondary,
                    ),
                  ),
                  onTap: () {
                    Navigator.of(context).pop();
                    _switchSource(index);
                  },
                );
              },
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

  void _showPlayerBackendSelectorDialog() {
    _showControls();
    _controlsTimer?.cancel();
    setState(() => _dialogOpen = true);
    showDialog(
      context: context,
      builder: (context) {
        return AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: const Text(
            '切换播放器',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textPrimary,
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
                  case PlayerBackendType.fvp:
                    label = 'FVP';
                    break;
                  case PlayerBackendType.vlc:
                    label = 'VLC';
                    break;
                }
                return ListTile(
                  selected: selected,
                  selectedTileColor: AppColors.primaryTint,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: BorderSide(
                      color: selected ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  title: Text(
                    label,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                  ),
                  leading: selected
                      ? const Icon(Icons.check, color: AppColors.primary)
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
        setState(() => _dialogOpen = false);
        _startControlsTimer();
      }
    });
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

    // 切换播放器前保存当前进度，初始化完成后恢复
    _pendingInitialPositionMs = _position.inMilliseconds;

    // 必须先 await dispose 旧后端，否则 ExoPlayer 等平台播放器会在后台继续播放。
    await _backend?.dispose();
    _backend = null;
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

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
        return AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: const Text(
            '选集',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 400,
            height: 360,
            child: ListView.builder(
              itemCount: titles.length,
              itemBuilder: (context, index) {
                final selected = index == _currentEpisodeIndex;
                return ListTile(
                  selected: selected,
                  selectedTileColor: AppColors.primaryTint,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(AppRadius.md),
                    side: BorderSide(
                      color: selected ? AppColors.primary : AppColors.border,
                    ),
                  ),
                  title: Text(
                    titles[index],
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.primary
                          : AppColors.textPrimary,
                    ),
                  ),
                  leading: selected
                      ? const Icon(Icons.check, color: AppColors.primary)
                      : null,
                  onTap: () {
                    Navigator.of(context).pop();
                    _openEpisode(index);
                  },
                );
              },
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

  // 播放记录节流保存（10秒内最多保存一次）
  void _savePlayRecordThrottled() {
    if (_isRecordSaveThrottled) return;
    _isRecordSaveThrottled = true;
    _savePlayRecordToLunaTV();
    Timer(const Duration(seconds: 10), () {
      _isRecordSaveThrottled = false;
    });
  }

  /// Windows 播放页键盘快捷键处理。
  ///
  /// 不再使用 Focus 控件（TV 遥控焦点环不适合桌面鼠标操作），直接通过
  /// HardwareKeyboard 全局监听，确保无论焦点在哪里都能响应播放控制。
  bool _handleHardwareKeyEvent(KeyEvent event) {
    // 页面销毁后 handler 可能仍在收到按键（如 ESC 的 KeyUp 落在 pop 销毁窗口），
    // 访问 defunct context 会抛异常导致闪退，先做 mounted 防护。
    if (!mounted) return false;
    // 仅在当前页面位于栈顶时处理，避免影响其他页面/对话框。
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;

    // 处理按键释放：停止长按连续 seek。
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        // 左右键释放后重新计时，确保操作结束后控制栏不会立刻消失。
        if (_controlsVisible) _startControlsTimer();
        return true;
      }
      return false;
    }

    if (event is! KeyDownEvent) return false;

    debugPrint('Windows 播放页按键: ${event.logicalKey}');

    switch (event.logicalKey) {
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
      case LogicalKeyboardKey.space:
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
        // 快退时显示控制栏（含进度条）与手势标识。
        _showControls();
        _showGestureIndicator('快退', Icons.fast_rewind);
        return true;
      case LogicalKeyboardKey.arrowRight:
        _seekBy(Duration(seconds: _seekStep));
        // 快进时显示控制栏（含进度条）与手势标识。
        _showControls();
        _showGestureIndicator('快进', Icons.fast_forward);
        return true;
      case LogicalKeyboardKey.arrowUp:
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
      case LogicalKeyboardKey.escape:
        // Windows：ESC 统一交给全局 handler（app_windows._handleEscKey）执行
        // maybePop，由本页 PopScope 决定：全屏先退出全屏、控制栏先隐藏、否则返回。
        // HardwareKeyboard 会调用所有注册的 handler，若这里也处理 ESC 会与全局
        // handler 同时触发异步窗口操作导致并发卡死/闪退，因此返回 false 不消费。
        return false;
      default:
        return false;
    }
  }

  void _onTapScreen() {
    _toggleControls();
  }

  void _onDoubleTapScreen() {
    if (_isMiniPlayer) {
      // 小窗双击：先恢复普通窗口，再进入全屏；
      // 直接从受限的小窗切全屏可能导致退出全屏后回到小窗尺寸。
      _restoreAndEnterFullscreen();
    } else {
      // 普通/全屏双击：切换全屏状态。
      // 先同步一次窗口状态，避免本地变量失步导致双击进入全屏被误判为退出。
      onWindowsDoubleTap();
    }
  }

  /// 小窗模式下双击：先恢复到普通窗口，再进入全屏。
  Future<void> _restoreAndEnterFullscreen() async {
    try {
      if (_isMiniPlayer) {
        debugPrint('小窗双击：先恢复普通窗口');
        await _toggleMiniPlayer();
        // 等待窗口管理器完成恢复，避免尺寸/状态不同步。
        await Future.delayed(const Duration(milliseconds: 400));
        await WindowsWindowUtils.ensureResizableFrame();
      }
      // 若恢复后已经处于全屏（进入小窗前就是全屏），无需再次切换。
      if (isWindowsFullScreen) {
        debugPrint('小窗双击：恢复后已是全屏，跳过切换');
        return;
      }
      debugPrint('小窗双击：再进入全屏');
      onWindowsDoubleTap();
    } catch (e) {
      debugPrint('小窗双击进入全屏失败: $e');
    }
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
    }
  }

  Future<void> _toggleMiniPlayer() async {
    if (!DeviceUtils.isWindows || _togglingMiniPlayer) return;
    _togglingMiniPlayer = true;
    try {
      if (_isMiniPlayer) {
        // 恢复普通窗口：必须先放开尺寸限制，否则 setBounds/setFullScreen 会被小窗的
        // 最大尺寸截断，导致窗口无法放大、无法真正全屏。
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setMinimumSize(const Size(320, 180));
        await windowManager.setResizable(true);
        await windowManager.setTitleBarStyle(_previousTitleBarStyle);
        await windowManager.setAlwaysOnTop(false);
        await WindowsWindowUtils.ensureResizableFrame();

        if (_wasFullScreenBeforeMini) {
          // 进入小窗前是全屏：先恢复保存的窗口尺寸，再重新进入全屏。
          if (_isValidNormalBounds(_previousWindowBounds)) {
            await windowManager.setBounds(_previousWindowBounds!);
            await Future.delayed(const Duration(milliseconds: 200));
          } else {
            await windowManager.setSize(_kNormalMinSize);
            await windowManager.center();
            await Future.delayed(const Duration(milliseconds: 200));
          }
          // 进入全屏前必须先恢复普通标题栏，否则 window_manager 在 is_frameless_
          // 为 true 时不会执行实际全屏 resize。
          await windowManager.setTitleBarStyle(TitleBarStyle.normal);
          await windowManager.setFullScreen(true);
          setWindowsFullScreenState(true);
        } else if (_isValidNormalBounds(_previousWindowBounds)) {
          await windowManager.setBounds(_previousWindowBounds!);
        } else {
          // 兜底：恢复到默认居中窗口。
          await windowManager.setSize(_kNormalMinSize);
          await windowManager.center();
        }
        // 恢复正常窗口的最小尺寸限制，并强制刷新框架确保可拉伸。
        await Future.delayed(const Duration(milliseconds: 100));
        await windowManager.setMinimumSize(_kNormalMinSize);
        await windowManager.setMaximumSize(_kUnboundedSize);
        await WindowsWindowUtils.ensureResizableFrame();
        // 兜底：如果恢复后的窗口仍然过小，强制设置为默认正常尺寸并居中。
        try {
          final restoredBounds = await windowManager.getBounds();
          if (restoredBounds.width < _kNormalMinSize.width ||
              restoredBounds.height < _kNormalMinSize.height) {
            debugPrint('小窗恢复后尺寸异常，强制恢复默认尺寸: $restoredBounds');
            await windowManager.setSize(_kNormalMinSize);
            await windowManager.center();
            await WindowsWindowUtils.ensureResizableFrame();
          }
        } catch (e) {
          debugPrint('小窗恢复后校验尺寸失败: $e');
        }
        if (mounted) setState(() => _isMiniPlayer = false);
      } else {
        // 进入小窗前若处于全屏，先通过 mixin 退出全屏（会正确保存/恢复窗口边界）。
        // 先同步一次窗口状态，避免本地变量与 window_manager 内部变量不一致。
        await syncWindowsFullscreenState();
        _wasFullScreenBeforeMini = isWindowsFullScreen;
        if (_wasFullScreenBeforeMini) {
          await toggleWindowsFullscreen();
          // 等待窗口管理器完成退出全屏，再读取正常窗口尺寸。
          await Future.delayed(const Duration(milliseconds: 500));
        }
        // 保存当前窗口尺寸、位置和标题栏样式。
        // 每次进入小窗都刷新保存的边界，避免使用过期尺寸导致恢复后窗口变小。
        // 以插件的 isFullScreen 为准排除全屏状态；若插件报告非全屏但边界接近
        // 屏幕尺寸（可能是手动最大化），则放弃保存，恢复时使用默认居中窗口。
        final isPluginFullscreen = await windowManager.isFullScreen();
        final bounds = await windowManager.getBounds();
        if (!isPluginFullscreen &&
            _isValidNormalBounds(bounds) &&
            !_isNearScreenSize(bounds)) {
          _previousWindowBounds = bounds;
        } else {
          _previousWindowBounds = null;
        }
        _previousTitleBarStyle = TitleBarStyle.normal;
        debugPrint(
          '进入小窗: previousBounds=$_previousWindowBounds, '
          'wasFullScreen=$_wasFullScreenBeforeMini',
        );
        // 使用物理显示器尺寸计算小窗位置，避免依赖当前窗口尺寸导致越界。
        final view = View.of(context);
        final pixelRatio = view.devicePixelRatio;
        final displaySize = view.display.size;
        final screenSize = Size(
          displaySize.width / pixelRatio,
          displaySize.height / pixelRatio,
        );
        const miniSize = Size(480, 270);
        final position = Offset(
          math.max(0, screenSize.width - miniSize.width - 20),
          math.max(0, screenSize.height - miniSize.height - 80),
        );
        // 小窗仅做界面精简，不限制最大尺寸，允许用户自由拉伸。
        await windowManager.setMinimumSize(_kMiniMinSize);
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setResizable(true);
        // 隐藏系统标题栏，通过播放区域拖动窗口，通过四周自定义热区调整大小。
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        await WindowsWindowUtils.ensureResizableFrame();
        await windowManager.setBounds(
          Rect.fromLTWH(
            position.dx,
            position.dy,
            miniSize.width,
            miniSize.height,
          ),
        );
        await Future.delayed(const Duration(milliseconds: 100));
        await WindowsWindowUtils.ensureResizableFrame();
        if (mounted) setState(() => _isMiniPlayer = true);
      }
    } catch (e) {
      debugPrint('小窗播放切换失败: $e');
    } finally {
      _togglingMiniPlayer = false;
    }
  }

  Future<void> _toggleAlwaysOnTop() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final current = await windowManager.isAlwaysOnTop();
      final next = !current;
      await windowManager.setAlwaysOnTop(next);
      if (mounted) setState(() => _isAlwaysOnTop = next);
    } catch (e) {
      debugPrint('切换置顶失败: $e');
    }
  }

  Future<void> _restoreNormalWindowIfMini() async {
    if (!DeviceUtils.isWindows || !_isMiniPlayer || _togglingMiniPlayer) return;
    _togglingMiniPlayer = true;
    try {
      // 先放开尺寸限制，再恢复窗口边界，避免被小窗最大尺寸截断。
      await windowManager.setMaximumSize(_kUnboundedSize);
      await windowManager.setMinimumSize(const Size(320, 180));
      await windowManager.setResizable(true);
      await windowManager.setTitleBarStyle(_previousTitleBarStyle);
      await windowManager.setAlwaysOnTop(false);
      await WindowsWindowUtils.ensureResizableFrame();
      if (_isValidNormalBounds(_previousWindowBounds)) {
        await windowManager.setBounds(_previousWindowBounds!);
      } else {
        await windowManager.setSize(_kNormalMinSize);
        await windowManager.center();
      }
      await Future.delayed(const Duration(milliseconds: 100));
      await windowManager.setMinimumSize(_kNormalMinSize);
      await windowManager.setMaximumSize(_kUnboundedSize);
      await WindowsWindowUtils.ensureResizableFrame();
      // 兜底：如果恢复后的窗口仍然过小，强制设置为默认正常尺寸并居中。
      try {
        final restoredBounds = await windowManager.getBounds();
        if (restoredBounds.width < _kNormalMinSize.width ||
            restoredBounds.height < _kNormalMinSize.height) {
          debugPrint('退出播放页恢复后尺寸异常，强制恢复默认尺寸: $restoredBounds');
          await windowManager.setSize(_kNormalMinSize);
          await windowManager.center();
          await WindowsWindowUtils.ensureResizableFrame();
        }
      } catch (e) {
        debugPrint('退出播放页恢复后校验尺寸失败: $e');
      }
      if (mounted) setState(() => _isMiniPlayer = false);
    } catch (e) {
      debugPrint('恢复普通窗口失败: $e');
    } finally {
      _togglingMiniPlayer = false;
    }
  }

  @override
  void dispose() {
    disposeWindowsFullscreen();
    _mouseInactivityTimer?.cancel();
    _mouseInactivityTimer = null;
    // 页面销毁时确保光标恢复可见，避免鼠标隐藏状态泄漏到其它页面。
    WindowsWindowUtils.setCursorVisible(true);
    _restoreNormalWindowIfMini();
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _controlsTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _clockTimer?.cancel();
    _autoSwitchTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }

    // 立即保存播放记录到 LunaTV
    _savePlayRecordToLunaTV();

    // 销毁播放器后端。
    //
    // 直播页的播放器挂在 LivePlayer widget 上，随 widget 树卸载时销毁，
    // 此时 VideoPlayer 纹理已从渲染树移除，释放无竞态；点播页后端挂在
    // State 上，若在 State.dispose 中立即销毁，VideoPlayer 纹理仍挂载于
    // 正在卸载的子树，Windows FVP 释放纹理时易与渲染线程竞态导致闪退。
    // 因此先立即暂停（停止渲染与声音），再延迟到 widget 树卸载完成后销毁。
    final backend = _backend;
    _backend = null;
    if (backend != null) {
      unawaited(
        backend.pause().catchError((Object e) {
          debugPrint('PlayerScreen 退出暂停播放器失败: $e');
        }),
      );
      unawaited(
        Future<void>.delayed(const Duration(milliseconds: 500), () async {
          try {
            await backend.dispose();
          } catch (e) {
            debugPrint('PlayerScreen 延迟销毁播放器失败: $e');
          }
        }),
      );
    }

    // 退出播放页后允许系统自动休眠/降亮度
    WakelockPlus.disable().catchError((e) {
      debugPrint('PlayerScreen: 禁用屏幕常亮失败: $e');
    });

    // 释放本地 M3U8 代理
    AdFilterEngine.dispose();

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
  }

  /// 保存播放记录：先写入本地确保立即可见，再异步上传 LunaTV。
  Future<void> _savePlayRecordToLunaTV() async {
    try {
      final record = PlayRecord(
        id: _currentVideoDetail.id,
        source: _currentVideoDetail.source,
        title: _currentVideoDetail.title,
        sourceName: _currentVideoDetail.source,
        cover: _currentVideoDetail.poster,
        year: _currentVideoDetail.year,
        index: _currentEpisodeIndex + 1, // 1-based
        totalEpisodes: _currentVideoDetail.episodes.length,
        playTime: _position.inSeconds,
        totalTime: _duration.inSeconds,
        saveTime: DateTime.now().millisecondsSinceEpoch,
        searchTitle: _currentVideoDetail.title,
        doubanId: _currentVideoDetail.doubanId?.toString(),
      );

      await PlayRecordService.save(record);
    } catch (e) {
      // 保存失败不阻塞退出
      debugPrint('保存播放记录失败: $e');
    }
  }

  Widget _buildVideo() {
    // 切换源/播放器期间由切换遮罩显示加载提示，避免与视频层加载图标重叠。
    if (_switchingSource) {
      return const ColoredBox(color: Colors.black);
    }
    if (!_initialized || _backend == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    return Container(color: Colors.black, child: _backend!.buildVideoWidget());
  }

  Widget _buildError() {
    if (_error == null) return const SizedBox.shrink();
    return Container(
      color: Colors.black54,
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Text(_error!, style: const TextStyle(color: AppColors.error)),
    );
  }

  Widget _buildSwitchingOverlay() {
    if (!_switchingSource) return const SizedBox.shrink();
    return Container(
      color: Colors.black54,
      child: const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: AppColors.primary),
            SizedBox(height: AppSpacing.md),
            Text('切换播放源中...', style: TextStyle(color: AppColors.textPrimary)),
          ],
        ),
      ),
    );
  }

  /// 重置鼠标无操作定时器（仅 Windows 全屏时生效）。
  ///
  /// 每次鼠标移动都会触发本方法：取消旧的隐藏定时器，若光标已隐藏则先恢复
  /// 显示，再重新启动 [._kMouseHideDelay] 后的自动隐藏。非全屏时仅确保光标
  /// 可见并取消定时器，不启用自动隐藏。
  void _resetMouseTimer() {
    if (!DeviceUtils.isWindows) return;
    _mouseInactivityTimer?.cancel();
    _mouseInactivityTimer = null;
    if (!isWindowsFullScreen) {
      // 非全屏不启用自动隐藏，并确保光标恢复可见。
      if (_isCursorHidden) {
        WindowsWindowUtils.setCursorVisible(true);
        _isCursorHidden = false;
      }
      return;
    }
    if (_isCursorHidden) {
      _showCursor();
    }
    _mouseInactivityTimer = Timer(_kMouseHideDelay, _hideCursor);
  }

  /// 隐藏鼠标光标（仅 Windows 全屏时生效）。
  void _hideCursor() {
    if (!DeviceUtils.isWindows || !isWindowsFullScreen) return;
    if (!mounted || _isCursorHidden) return;
    WindowsWindowUtils.setCursorVisible(false);
    _isCursorHidden = true;
    debugPrint('PlayerScreen: 全屏鼠标无操作，已自动隐藏光标');
  }

  /// 显示鼠标光标。
  void _showCursor() {
    if (!DeviceUtils.isWindows || !mounted) return;
    if (!_isCursorHidden) return;
    WindowsWindowUtils.setCursorVisible(true);
    _isCursorHidden = false;
  }

  @override
  void onWindowEnterFullScreen() {
    super.onWindowEnterFullScreen();
    // 进入全屏后启动鼠标无操作自动隐藏。
    _resetMouseTimer();
  }

  @override
  void onWindowLeaveFullScreen() {
    super.onWindowLeaveFullScreen();
    // 退出全屏后恢复光标显示并停用自动隐藏。
    _resetMouseTimer();
  }

  Widget _buildGestureOverlay() {
    if (DeviceUtils.isWindows && _isMiniPlayer) {
      return _buildMiniCentralGestureOverlay();
    }
    return Positioned.fill(
      child: MouseRegion(
        // 鼠标移动时重置无操作定时器（Windows 全屏自动隐藏光标）。
        onHover: (_) => _resetMouseTimer(),
        onExit: (_) => _resetMouseTimer(),
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: _onScreenPointerDown,
          onPointerUp: _onScreenPointerUp,
        child: Container(color: Colors.transparent),
      ),
      ),
    );
  }

  /// 最近一次指针按下的时间，用于手动识别双击/单击。
  DateTime? _lastPointerDownAt;

  /// 最近一次指针按下的位置，用于手动识别双击/单击。
  Offset? _lastPointerDownPosition;

  /// 最近一次屏幕单击/双击的按下时间。
  DateTime? _screenPointerDownAt;

  /// 最近一次屏幕单击/双击的按下位置。
  Offset? _screenPointerDownPosition;

  /// 双击最大间隔（毫秒）。
  static const int _doubleTapMaxMillis = 300;

  /// 双击最大允许位移（逻辑像素）。
  static const double _doubleTapMaxDistance = 40;

  /// 屏幕单击最大允许位移（逻辑像素）。
  static const double _singleTapMaxDistance = 40;

  /// 屏幕单击最大允许时长（毫秒）。
  static const int _singleTapMaxMillis = 400;

  /// 小窗模式最近一次 pointer down 的时间，用于手动识别双击。
  DateTime? _miniLastPointerDownAt;

  /// 小窗模式最近一次 pointer down 的位置，用于手动识别双击。
  Offset? _miniLastPointerDownPosition;

  /// 小窗模式拖动起始位置。
  Offset? _miniDragStartPosition;

  /// 小窗模式是否已进入拖动状态。
  bool _miniIsDragging = false;

  /// 小窗模式拖动识别阈值（逻辑像素）。
  static const double _miniDragThreshold = 6.0;

  /// 处理屏幕按下：记录单击/双击所需信息，并手动识别双击切换全屏。
  ///
  /// 不使用 [GestureDetector.onDoubleTap]，避免其参与手势竞技场导致
  /// 控制栏按钮的单击产生延迟。
  void _onScreenPointerDown(PointerDownEvent event) {
    final now = DateTime.now();
    final lastAt = _lastPointerDownAt;
    final lastPos = _lastPointerDownPosition;
    _lastPointerDownAt = now;
    _lastPointerDownPosition = event.position;

    _screenPointerDownAt = now;
    _screenPointerDownPosition = event.position;

    if (lastAt == null || lastPos == null) return;

    if (now.difference(lastAt).inMilliseconds > _doubleTapMaxMillis) return;
    if ((event.position - lastPos).distance > _doubleTapMaxDistance) return;

    _onDoubleTapScreen();
  }

  /// 处理屏幕释放：识别为单击时显示/隐藏控制栏。
  ///
  /// 控制栏区域已在外层通过 [GestureDetector] 消费事件，
  /// 因此此处只会收到非控制栏区域的释放事件。
  void _onScreenPointerUp(PointerUpEvent event) {
    final downAt = _screenPointerDownAt;
    final downPos = _screenPointerDownPosition;
    _screenPointerDownAt = null;
    _screenPointerDownPosition = null;

    if (downAt == null || downPos == null) return;

    final elapsed = DateTime.now().difference(downAt).inMilliseconds;
    if (elapsed > _singleTapMaxMillis) return;
    if ((event.position - downPos).distance > _singleTapMaxDistance) return;

    _onTapScreen();
  }

  /// 全屏双击切换覆盖层。
  ///
  /// 普通/全屏模式下已合并到 [_buildGestureOverlay] 的 [Listener] 中，
  /// 避免多个透明 [Listener] 叠加导致 pointer up 事件分发异常。
  /// 小窗模式下不启用此覆盖层，改由 [_buildMiniCentralGestureOverlay]
  /// 统一处理单击/双击/拖动。
  Widget _buildDoubleTapOverlay() {
    return const SizedBox.shrink();
  }

  /// 小窗模式的中间手势区：支持单击显示控制栏、双击切换全屏、拖动窗口。
  ///
  /// 四周留出 [edgeSize] 像素给调整大小热区，避免拖动与拉伸手势冲突。
  /// 使用 [Listener] 手动识别，避免 [GestureDetector] 参与手势竞技场
  /// 导致单击/拖动失效。
  Widget _buildMiniCentralGestureOverlay() {
    const edgeSize = 12.0;
    return Positioned(
      left: edgeSize,
      top: edgeSize,
      right: edgeSize,
      bottom: edgeSize,
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onMiniPointerDown,
        onPointerMove: _onMiniPointerMove,
        onPointerUp: _onMiniPointerUp,
        child: Container(color: Colors.transparent),
      ),
    );
  }

  /// 小窗模式 pointer down：记录单击/双击/拖动起始信息，并识别双击全屏。
  void _onMiniPointerDown(PointerDownEvent event) {
    final now = DateTime.now();
    final lastAt = _miniLastPointerDownAt;
    final lastPos = _miniLastPointerDownPosition;

    _miniLastPointerDownAt = now;
    _miniLastPointerDownPosition = event.position;
    _miniDragStartPosition = event.position;
    _miniIsDragging = false;

    if (lastAt == null || lastPos == null) return;
    if (now.difference(lastAt).inMilliseconds > _doubleTapMaxMillis) return;
    if ((event.position - lastPos).distance > _doubleTapMaxDistance) return;

    _onDoubleTapScreen();
  }

  /// 小窗模式 pointer move：移动超过阈值时进入拖动状态并拖动窗口。
  void _onMiniPointerMove(PointerMoveEvent event) {
    if (_miniDragStartPosition == null || _miniIsDragging) return;
    if ((event.position - _miniDragStartPosition!).distance <=
        _miniDragThreshold) {
      return;
    }

    _miniIsDragging = true;
    // 已经开始拖动，取消可能待确认的单击/双击。
    _miniLastPointerDownAt = null;
    _miniLastPointerDownPosition = null;
    debugPrint('Windows 小窗开始拖动');
    windowManager.startDragging();
  }

  /// 小窗模式 pointer up：未拖动时识别为单击，显示/隐藏控制栏。
  void _onMiniPointerUp(PointerUpEvent event) {
    if (_miniIsDragging) {
      _miniDragStartPosition = null;
      _miniIsDragging = false;
      return;
    }

    final downAt = _miniLastPointerDownAt;
    final downPos = _miniLastPointerDownPosition;
    _miniDragStartPosition = null;
    _miniIsDragging = false;

    if (downAt == null || downPos == null) return;

    final elapsed = DateTime.now().difference(downAt).inMilliseconds;
    if (elapsed > _singleTapMaxMillis) return;
    if ((event.position - downPos).distance > _singleTapMaxDistance) return;

    _onTapScreen();
  }

  /// 小窗模式下提供自定义窗口调整热区。
  ///
  /// 隐藏系统标题栏后，Windows 默认的拖拽边距可能无法命中，因此在窗口四周
  /// 放置 12px 热区，调用 window_manager.startResizing 实现自由拉伸。
  /// 使用 [Listener.onPointerDown] 立即触发，避免 [GestureDetector] 的拖拽识别
  /// 延迟导致 Windows 无法进入 resize 循环。
  /// 该热区位于 Stack 最顶层（除中间双击区外），确保控制栏显示时也能命中。
  Widget _buildResizeEdges() {
    if (!_isMiniPlayer) return const SizedBox.shrink();
    const edgeSize = 12.0;
    Widget edge({
      required ResizeEdge resizeEdge,
      required MouseCursor cursor,
      double? left,
      double? top,
      double? right,
      double? bottom,
      double? width,
      double? height,
    }) {
      return Positioned(
        left: left,
        top: top,
        right: right,
        bottom: bottom,
        width: width,
        height: height,
        child: MouseRegion(
          cursor: cursor,
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (_) {
              debugPrint('Windows 小窗调整热区触发: $resizeEdge');
              windowManager.startResizing(resizeEdge);
            },
            child: Container(color: Colors.transparent),
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        edge(
          resizeEdge: ResizeEdge.top,
          cursor: SystemMouseCursors.resizeUp,
          top: 0,
          left: edgeSize,
          right: edgeSize,
          height: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.bottom,
          cursor: SystemMouseCursors.resizeDown,
          bottom: 0,
          left: edgeSize,
          right: edgeSize,
          height: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.left,
          cursor: SystemMouseCursors.resizeLeft,
          left: 0,
          top: edgeSize,
          bottom: edgeSize,
          width: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.right,
          cursor: SystemMouseCursors.resizeRight,
          right: 0,
          top: edgeSize,
          bottom: edgeSize,
          width: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.topLeft,
          cursor: SystemMouseCursors.resizeUpLeft,
          top: 0,
          left: 0,
          width: edgeSize,
          height: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.topRight,
          cursor: SystemMouseCursors.resizeUpRight,
          top: 0,
          right: 0,
          width: edgeSize,
          height: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.bottomLeft,
          cursor: SystemMouseCursors.resizeDownLeft,
          bottom: 0,
          left: 0,
          width: edgeSize,
          height: edgeSize,
        ),
        edge(
          resizeEdge: ResizeEdge.bottomRight,
          cursor: SystemMouseCursors.resizeDownRight,
          bottom: 0,
          right: 0,
          width: edgeSize,
          height: edgeSize,
        ),
      ],
    );
  }

  Widget _buildTopBar() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 消费掉顶部控制栏背景点击，避免触发下层屏幕单击事件。
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [AppColors.bgOverlay, Colors.transparent],
          ),
        ),
        child: Stack(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () async {
                    if (isWindowsFullScreen) {
                      await toggleWindowsFullscreen();
                    } else {
                      Navigator.of(context).pop();
                    }
                  },
                  icon: const Icon(
                    Icons.arrow_back,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _currentVideoDetail.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                          color: AppColors.textPrimary,
                        ),
                      ),
                      Text(
                        _episodeTitle,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 14,
                          color: AppColors.textSecondary,
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
                  style: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 18,
                    fontWeight: FontWeight.w500,
                    color: AppColors.textPrimary,
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
      ),
    );
  }

  Widget _buildMiniPlayerControls() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 消费掉小窗控制栏背景点击，避免触发下层屏幕单击事件。
      },
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              AppColors.bgOverlay.withValues(alpha: 0.9),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              _buildMiniControlIconButton(
                onTap: _togglePlay,
                icon: _playing ? Icons.pause : Icons.play_arrow,
                tooltip: _playing ? '暂停' : '播放',
              ),
              _buildMiniControlIconButton(
                onTap: _nextEpisode,
                icon: Icons.skip_next,
                tooltip: '下一集',
              ),
              _buildMiniControlIconButton(
                onTap: _toggleMiniPlayer,
                icon: Icons.open_in_full,
                tooltip: '恢复窗口',
              ),
              _buildMiniControlIconButton(
                onTap: _toggleAlwaysOnTop,
                icon: _isAlwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
                tooltip: _isAlwaysOnTop ? '取消置顶' : '窗口置顶',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniControlIconButton({
    required VoidCallback onTap,
    required IconData icon,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.bgElevated.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, color: AppColors.textPrimary, size: 22),
        ),
      ),
    );
  }

  Widget _buildBottomControls() {
    if (_isMiniPlayer) {
      return _buildMiniPlayerControls();
    }
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {
        // 消费掉底部控制栏背景点击，避免触发下层屏幕单击事件。
      },
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [AppColors.bgOverlay, Colors.transparent],
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
                        backgroundColor: AppColors.border,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          Colors.white24,
                        ),
                      ),
                      LinearProgressIndicator(
                        value: _duration.inMilliseconds > 0
                            ? _position.inMilliseconds /
                                  _duration.inMilliseconds
                            : 0.0,
                        backgroundColor: Colors.transparent,
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppColors.primary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            Wrap(
              alignment: WrapAlignment.start,
              spacing: AppSpacing.sm,
              runSpacing: AppSpacing.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                _buildControlIconButton(
                  onTap: _togglePlay,
                  icon: _playing ? Icons.pause : Icons.play_arrow,
                  tooltip: _playing ? '暂停' : '播放',
                ),
                const SizedBox(width: AppSpacing.sm),
                _buildControlIconButton(
                  onTap: _previousEpisode,
                  icon: Icons.skip_previous,
                  tooltip: '上一集',
                ),
                const SizedBox(width: AppSpacing.sm),
                _buildControlIconButton(
                  onTap: _nextEpisode,
                  icon: Icons.skip_next,
                  tooltip: '下一集',
                ),
                const SizedBox(width: AppSpacing.md),
                Text(
                  '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                  style: const TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                if (DeviceUtils.isWindows)
                  _buildControlTextButton(
                    onTap: toggleWindowsFullscreen,
                    icon: isWindowsFullScreen
                        ? Icons.fullscreen_exit
                        : Icons.fullscreen,
                    label: isWindowsFullScreen ? '退出全屏' : '全屏',
                    tooltip: isWindowsFullScreen ? '退出全屏' : '全屏',
                  ),
                if (DeviceUtils.isWindows) const SizedBox(width: AppSpacing.md),
                if (DeviceUtils.isWindows)
                  _buildControlTextButton(
                    onTap: _toggleMiniPlayer,
                    icon: _isMiniPlayer
                        ? Icons.picture_in_picture_alt
                        : Icons.picture_in_picture_alt_outlined,
                    label: _isMiniPlayer ? '恢复窗口' : '小窗播放',
                    tooltip: _isMiniPlayer ? '恢复窗口' : '小窗播放',
                  ),
                if (DeviceUtils.isWindows) const SizedBox(width: AppSpacing.md),
                if (DeviceUtils.isWindows)
                  _buildControlTextButton(
                    onTap: _toggleAlwaysOnTop,
                    icon: _isAlwaysOnTop
                        ? Icons.push_pin
                        : Icons.push_pin_outlined,
                    label: _isAlwaysOnTop ? '取消置顶' : '置顶',
                    tooltip: _isAlwaysOnTop ? '取消置顶' : '窗口置顶',
                  ),
                if (DeviceUtils.isWindows) const SizedBox(width: AppSpacing.md),
                if (_currentVideoDetail.source.isNotEmpty &&
                    _currentVideoDetail.id.isNotEmpty)
                  _buildControlTextButton(
                    onTap: _showSkipConfigDialog,
                    icon: _skipConfigLoading ? null : Icons.skip_next,
                    label: '跳过',
                    tooltip: '跳过片头片尾',
                    foregroundColor:
                        _skipConfig != null && _skipConfig!.segments.isNotEmpty
                        ? AppColors.primary
                        : AppColors.textPrimary,
                    backgroundColor:
                        _skipConfig != null && _skipConfig!.segments.isNotEmpty
                        ? AppColors.primaryTint
                        : AppColors.bgElevated,
                    isLoading: _skipConfigLoading,
                  ),
                const SizedBox(width: AppSpacing.md),
                _buildControlTextButton(
                  onTap: _cycleVideoFit,
                  icon: Icons.aspect_ratio,
                  label: _videoFitLabel(_videoFit),
                  tooltip: '切换画面比例',
                ),
                const SizedBox(width: AppSpacing.md),
                _buildControlTextButton(
                  onTap: _showPlayerBackendSelectorDialog,
                  icon: Icons.settings_applications,
                  label: _playerBackendLabel(_currentPlayerBackend),
                  tooltip: '切换播放器',
                ),
                const SizedBox(width: AppSpacing.md),
                _buildControlTextButton(
                  onTap: _cyclePlaybackSpeed,
                  icon: Icons.speed,
                  label: _playbackSpeedLabel(_playbackSpeed),
                  tooltip: '切换倍速',
                ),
                const SizedBox(width: AppSpacing.md),
                if (_canSwitchSource)
                  _buildControlTextButton(
                    onTap: _showSourceSelectorDialog,
                    icon: Icons.swap_horiz,
                    label: '换源',
                    tooltip: '切换播放源',
                  ),
                if (_canSwitchSource) const SizedBox(width: AppSpacing.md),
                if (_currentVideoDetail.episodes.length > 1)
                  _buildControlTextButton(
                    onTap: _showEpisodeSelectorDialog,
                    icon: Icons.list,
                    label: '选集',
                    tooltip: '选集',
                  ),
                if (_currentVideoDetail.episodes.length > 1)
                  const SizedBox(width: AppSpacing.md),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 构建控制栏图标按钮。
  Widget _buildControlIconButton({
    required VoidCallback onTap,
    required IconData icon,
    String? tooltip,
  }) {
    return IconButton(
      onPressed: onTap,
      icon: Icon(icon, color: AppColors.textPrimary),
      iconSize: 28,
      tooltip: tooltip,
      padding: const EdgeInsets.all(AppSpacing.sm),
      constraints: const BoxConstraints(),
    );
  }

  /// 构建控制栏文字图标按钮。
  Widget _buildControlTextButton({
    required VoidCallback onTap,
    required IconData? icon,
    required String label,
    required String tooltip,
    Color? foregroundColor,
    Color? backgroundColor,
    bool isLoading = false,
  }) {
    final color = foregroundColor ?? AppColors.textPrimary;
    final bgColor = backgroundColor ?? AppColors.bgElevated;
    return Tooltip(
      message: tooltip,
      child: TextButton.icon(
        onPressed: isLoading ? null : onTap,
        icon: isLoading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              )
            : Icon(icon, color: color, size: 18),
        label: Text(
          label,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 13,
            color: color,
          ),
        ),
        style: TextButton.styleFrom(
          backgroundColor: bgColor,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
            side: const BorderSide(color: AppColors.border),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // 全屏或控制栏显示时禁止直接 pop：
      // - 全屏时先退出全屏；
      // - 控制栏显示时先隐藏控制栏；
      // - 两者都满足时优先退出全屏。
      // 全屏切换过程中禁止 pop，避免销毁与窗口操作并发导致卡死。
      canPop: !isWindowsFullScreen && !_controlsVisible && !isTogglingWindowsFullscreen,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isWindowsFullScreen) {
          toggleWindowsFullscreen();
        } else if (_controlsVisible) {
          _hideControls();
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            // 最底层：纯黑背景，确保黑边区域由 Flutter 绘制，
            // 避免 PlatformView 在隐藏控制栏后仍残留影像。
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
            // 视频层：只覆盖实际画面区域，黑边留给我 Flutter 背景。
            // IgnorePointer 避免 PlatformView 拦截触摸事件，确保手势层能正常工作。
            Positioned.fill(child: IgnorePointer(child: _buildVideo())),
            // 错误提示
            Center(child: _buildError()),
            // 切换源遮罩
            Positioned.fill(child: _buildSwitchingOverlay()),
            // 鼠标/触摸手势层：Windows 桌面端保留点击、拖动窗口。
            _buildGestureOverlay(),
            // 顶层双击覆盖层：全屏/小窗/普通模式下双击均切换全屏状态。
            _buildDoubleTapOverlay(),
            // 快进/快退手势标识浮层（居中显示）。
            _buildGestureIndicator(),
            // 控制栏覆盖层：提到双击/手势层之上，确保控制栏按钮优先响应鼠标点击。
            // 点击控制栏背景区域仍会通过下层的 gesture overlay 隐藏控制栏。
            Visibility(
              visible: _controlsVisible,
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
            // 小窗模式下的自定义窗口调整热区，位于控制栏之上，
            // 确保边缘拖拽事件优先被热区接收；中间区域不影响控制栏按钮。
            if (_isMiniPlayer) Positioned.fill(child: _buildResizeEdges()),
          ],
        ),
      ),
    );
  }
}
