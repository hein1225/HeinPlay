import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/models/source_option.dart';
import 'package:hain_tv/models/skip_segment.dart';
import 'package:hain_tv/models/video_detail.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/player/video_player_backend.dart';
import 'package:hain_tv/services/ad_filter_engine.dart';
import 'package:hain_tv/services/hain_tv_cache_manager.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/tv/skip_config_dialog.dart';

class MobilePlayerScreen extends StatefulWidget {
  final VideoDetail videoDetail;
  final int episodeIndex;
  final List<SourceOption>? sources;
  final ValueNotifier<List<SourceOption>>? sourcesNotifier;
  final int initialSourceIndex;
  final PlayerBackendType playerBackend;
  final int initialPositionMs;

  const MobilePlayerScreen({
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
  late int _currentEpisodeIndex;
  bool _controlsVisible = true;
  bool _controlsLocked = false;
  bool _lockIndicatorVisible = false;
  Timer? _lockIndicatorTimer;
  bool _playing = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _initialized = false;
  String? _error;
  bool _switchingSource = false;
  late PlayerBackendType _currentPlayerBackend;
  BoxFit _videoFit = BoxFit.contain;

  EpisodeSkipConfig? _skipConfig;
  bool _skipConfigLoading = false;
  final Set<String> _skippedSegments = {};
  bool _autoNextTriggered = false;

  final List<StreamSubscription> _subscriptions = [];
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
  void _captureOriginalOrientation() {
    final view = WidgetsBinding.instance.platformDispatcher.views.firstOrNull;
    if (view == null) return;
    final size = view.physicalSize / view.devicePixelRatio;
    _originalOrientation = size.width < size.height
        ? Orientation.portrait
        : Orientation.landscape;
  }

  @override
  void initState() {
    super.initState();
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
        backend.playingStream.listen((playing) {
          if (mounted) setState(() => _playing = playing);
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
    if (_skipConfig == null || _skipConfig!.segments.isEmpty) return;

    // 刚切换集数/源的前 2 秒内不处理跳过，避免初始化阶段位置抖动导致误触发或 seek 失效。
    final switchAt = _episodeSwitchAt;
    if (switchAt != null &&
        DateTime.now().difference(switchAt) < const Duration(seconds: 2)) {
      return;
    }

    final seconds = position.inMilliseconds / 1000.0;
    final totalSeconds = _duration.inMilliseconds / 1000.0;
    if (totalSeconds <= 0) return;

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
      final passedSegment = seconds > segment.end + 1.0;

      if (inSegment) {
        // 仅在首次触发时打印日志，但允许重复 seek 直到真正离开片段。
        if (!_skippedSegments.contains(key)) {
          debugPrint(
            '触发跳过片段: type=${segment.type} start=${segment.start} end=${segment.end}',
          );
        }
        // 跳到片段结束后 1 秒，确保越过片尾并给 ExoPlayer 留出缓冲余量。
        _safeSeekToSeconds(segment.end + 1.0);
        break;
      } else if (passedSegment && !_skippedSegments.contains(key)) {
        // 播放器位置已确实越过片段，才标记为已跳过，避免 seek 失效后不再重试。
        _skippedSegments.add(key);
        debugPrint(
          '跳过片段已生效: type=${segment.type} end=${segment.end} current=$seconds',
        );
      }
    }

    // 总时长过短（如 HLS 直播或解析异常）时不触发片尾下一集
    if (totalSeconds <= 10) return;

    for (final segment in _skipConfig!.segments) {
      // 只有片尾类型的 segment 才允许触发自动下一集
      if (segment.type != 'ending' ||
          !segment.autoNextEpisode ||
          _autoNextTriggered)
        continue;
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
        break;
      }
    }

    const fallbackRemaining = 5.0;
    if (!_autoNextTriggered && totalSeconds - seconds <= fallbackRemaining) {
      final endingSegments = _skipConfig!.segments
          .where((s) => s.type == 'ending' && s.autoNextEpisode)
          .toList();
      if (endingSegments.isNotEmpty) {
        _autoNextTriggered = true;
        debugPrint('触发片尾自动下一集: position=$seconds total=$totalSeconds');
        _nextEpisode();
      }
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
      _showControls();
    } else if (autoSwitchSource && _sources.length > 1) {
      // 自动换源开启且有其他源时，按设置时间延迟后尝试下一个源。
      setState(() {
        _error = '播放失败，即将进行自动换源';
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
      const Duration(seconds: _controlsAutoHideSeconds),
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
                  trailing: selected
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

  // 播放记录节流保存（10秒内最多保存一次）
  void _savePlayRecordThrottled() {
    if (_isRecordSaveThrottled) return;
    _isRecordSaveThrottled = true;
    _savePlayRecordToLunaTV();
    Timer(const Duration(seconds: 10), () {
      _isRecordSaveThrottled = false;
    });
  }

  // 触摸手势相关方法
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
    _lockIndicatorTimer = Timer(const Duration(seconds: 3), () {
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
    _showGestureIndicator(
      isRight ? '0.5X 快进中' : '0.5X 快退中',
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
    _continuousSeekTimer = Timer.periodic(const Duration(milliseconds: 200), (
      _,
    ) {
      if (!_isLongPressSeeking || _backend == null) return;
      final step = _longPressDirection == 'right'
          ? _seekStep ~/ 2
          : -(_seekStep ~/ 2);
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
    _gestureIndicatorTimer = Timer(const Duration(milliseconds: 500), () {
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
    _gestureIndicatorTimer = Timer(const Duration(milliseconds: 500), () {
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
      setState(() => _initialized = false);
    }

    // 3. 尝试暂停播放，但不阻塞退出流程
    unawaited(
      backend
          ?.pause()
          .timeout(const Duration(seconds: 1))
          .catchError((e) {
        debugPrint('MobilePlayerScreen: 暂停失败: $e');
      }),
    );

    // 4. 立即恢复系统 UI 与方向，不等待完成
    unawaited(
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
          .timeout(const Duration(seconds: 2))
          .catchError((e) {
        debugPrint('MobilePlayerScreen: 恢复系统 UI 模式失败: $e');
      }),
    );
    unawaited(
      _restoreOrientation(_originalOrientation)
          .timeout(const Duration(seconds: 2))
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
    Future.delayed(const Duration(milliseconds: 300), () {
      if (backend != null) {
        unawaited(
          backend.dispose().timeout(const Duration(seconds: 5)).catchError((e) {
            debugPrint('MobilePlayerScreen: 释放播放器后端失败/超时: $e');
          }),
        );
      }
      unawaited(
        AdFilterEngine.dispose().timeout(const Duration(seconds: 5)).catchError(
            (e) {
          debugPrint('MobilePlayerScreen: 释放 M3U8 代理失败/超时: $e');
        }),
      );
    });
  }

  @override
  void dispose() {
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _controlsTimer?.cancel();
    _lockIndicatorTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _clockTimer?.cancel();
    _autoSwitchTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();

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
      await Future.delayed(const Duration(milliseconds: 300));
      unawaited(
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge)
            .timeout(const Duration(seconds: 2))
            .catchError((e) {
          debugPrint('MobilePlayerScreen: 恢复系统 UI 模式失败: $e');
        }),
      );
      unawaited(
        _restoreOrientation(original)
            .timeout(const Duration(seconds: 2))
            .catchError((e) {
          debugPrint('MobilePlayerScreen: 恢复方向失败/超时: $e');
        }),
      );
      if (backend != null) {
        unawaited(
          backend.dispose().timeout(const Duration(seconds: 5)).catchError((e) {
            debugPrint('MobilePlayerScreen: 释放播放器后端失败/超时: $e');
          }),
        );
      }
      unawaited(
        AdFilterEngine.dispose().timeout(const Duration(seconds: 5)).catchError(
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
    if (_isExiting) {
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
      child: SafeArea(
        bottom: false,
        child: Row(
          children: [
            IconButton(
              onPressed: () => _handleBack(forceExit: true),
              icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
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
            Text(
              _formatClock(_currentTime),
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.textPrimary,
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
      padding: const EdgeInsets.all(AppSpacing.lg),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [AppColors.bgOverlay, Colors.transparent],
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
                  child: LinearProgressIndicator(
                    value: _duration.inMilliseconds > 0
                        ? _position.inMilliseconds / _duration.inMilliseconds
                        : 0.0,
                    backgroundColor: AppColors.border,
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      AppColors.primary,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
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
                          color: AppColors.textPrimary,
                          size: 32,
                        ),
                      ),
                      IconButton(
                        onPressed: _previousEpisode,
                        icon: const Icon(
                          Icons.skip_previous,
                          color: AppColors.textPrimary,
                          size: 28,
                        ),
                      ),
                      IconButton(
                        onPressed: _nextEpisode,
                        icon: const Icon(
                          Icons.skip_next,
                          color: AppColors.textPrimary,
                          size: 28,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      Text(
                        '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 14,
                          color: AppColors.textPrimary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.sm),
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
                      color: AppColors.textPrimary,
                      size: 32,
                    ),
                  ),
                  IconButton(
                    onPressed: _previousEpisode,
                    icon: const Icon(
                      Icons.skip_previous,
                      color: AppColors.textPrimary,
                      size: 28,
                    ),
                  ),
                  IconButton(
                    onPressed: _nextEpisode,
                    icon: const Icon(
                      Icons.skip_next,
                      color: AppColors.textPrimary,
                      size: 28,
                    ),
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
                  const Spacer(),
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
        padding: const EdgeInsets.symmetric(
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
              const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.primary,
                ),
              )
            else
              Icon(
                icon,
                color: active ? AppColors.primary : AppColors.textPrimary,
                size: 22,
              ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 11,
                color: active ? AppColors.primary : AppColors.textPrimary,
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
            const Positioned.fill(child: ColoredBox(color: Colors.black)),
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
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.bgOverlay.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: const Icon(
                        Icons.lock,
                        color: AppColors.textPrimary,
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
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: AppColors.bgOverlay.withValues(alpha: 0.6),
                        borderRadius: BorderRadius.circular(AppRadius.md),
                      ),
                      child: const Icon(
                        Icons.lock_open,
                        color: AppColors.textPrimary,
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
          duration: const Duration(milliseconds: 200),
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
      backgroundColor: AppColors.bgSurface,
      title: const Text(
        '切换播放源',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: AppColors.textPrimary,
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
                  placeholder: (_, __) => Container(color: AppColors.bgSurface),
                  errorWidget: (_, __, ___) => Container(
                    color: AppColors.bgSurface,
                    child: Center(
                      child: Text(
                        source.title.isNotEmpty
                            ? source.title.substring(0, 1)
                            : '',
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 24,
                          color: AppColors.textMuted,
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
                    padding: const EdgeInsets.fromLTRB(
                      AppSpacing.sm,
                      AppSpacing.md,
                      AppSpacing.sm,
                      AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.bgElevated.withValues(alpha: 0.95),
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
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: AppColors.textPrimary,
                            height: 1.2,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          source.sourceName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.xs,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.bgElevated.withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(AppRadius.sm),
                  ),
                  child: Text(
                    'No.$rank',
                    style: const TextStyle(
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
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: speedColor(source.speed),
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      speedText,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textPrimary,
                      ),
                    ),
                  ),
                ),
              if (resolutionText.isNotEmpty)
                Positioned(
                  top: speedText.isNotEmpty ? 28 : 6,
                  right: 6,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.xs,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.warning,
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: Text(
                      resolutionText,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        color: AppColors.textInverse,
                      ),
                    ),
                  ),
                ),
              if (selected)
                const Positioned(
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
          duration: const Duration(milliseconds: 200),
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
      backgroundColor: AppColors.bgSurface,
      title: const Text(
        '选集',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: AppColors.textPrimary,
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
                      : AppColors.bgElevated,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  border: Border.all(
                    color: selected ? AppColors.primary : AppColors.border,
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
                    color: selected ? AppColors.primary : AppColors.textPrimary,
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
