import 'dart:async';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:volume_controller/volume_controller.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../focus/focusable.dart';
import '../models/play_record.dart';
import '../models/source_option.dart';
import '../models/skip_segment.dart';
import '../models/video_detail.dart';
import '../player/player_backend_factory.dart';
import '../player/video_player_backend.dart';
import '../services/ad_filter_engine.dart';
import '../services/hain_tv_cache_manager.dart';
import '../services/lunatv_service.dart';
import '../services/play_record_service.dart';
import '../services/user_data_service.dart';
import '../theme.dart';
import '../widgets/skip_config_dialog.dart';

class PlayerScreen extends StatefulWidget {
  final VideoDetail videoDetail;
  final int episodeIndex;
  final List<SourceOption>? sources;
  final int initialSourceIndex;
  final PlayerBackendType playerBackend;
  final int initialPositionMs;

  const PlayerScreen({
    super.key,
    required this.videoDetail,
    this.episodeIndex = 0,
    this.sources,
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
  VideoPlayerBackend? _backend;
  late int _currentEpisodeIndex;
  bool _controlsVisible = true;
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
  DateTime _currentTime = DateTime.now();

  // 固定快进快退步长
  static const int _seekStep = 20;
  static const int _controlsAutoHideSeconds = 10;
  late int _pendingInitialPositionMs;
  bool _isRecordSaveThrottled = false;

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

  List<SourceOption> get _sources => widget.sources ?? [];
  bool get _canSwitchSource => _sources.length > 1;

  @override
  void initState() {
    super.initState();
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
    _currentPlayerBackend = widget.playerBackend;
    _pendingInitialPositionMs = widget.initialPositionMs;
    _loadSkipConfig();
    _initBackend();
    _initWakelock();
    _initBrightnessAndVolume();
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
    final response = await LunaTVService.getSkipConfigs(source: source, id: id);
    if (mounted) {
      setState(() {
        _skipConfigLoading = false;
        if (response.success && response.data != null) {
          _skipConfig = response.data;
          debugPrint(
            '跳过配置加载成功: source=$source id=$id segments=${_skipConfig!.segments.length}',
          );
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
    // 如果因超时导致界面显示了“播放失败”，但实际视频已初始化成功，则清除错误
    if (duration.inMilliseconds > 0 &&
        _error == '播放失败，请尝试切换播放源' &&
        !_initialized) {
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
      ..add(
        backend.durationStream.listen(_onDurationUpdate),
      )
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
    final seconds = position.inMilliseconds / 1000.0;
    final totalSeconds = _duration.inMilliseconds / 1000.0;

    for (final segment in _skipConfig!.segments) {
      final key = '${segment.type}_${segment.start}_${segment.end}';
      if (segment.autoSkip &&
          !_skippedSegments.contains(key) &&
          seconds >= segment.start &&
          seconds <= segment.end) {
        _skippedSegments.add(key);
        debugPrint(
          '触发跳过片段: type=${segment.type} start=${segment.start} end=${segment.end}',
        );
        _safeSeekToSeconds(segment.end);
        break;
      }
    }

    if (totalSeconds > 0) {
      for (final segment in _skipConfig!.segments) {
        // 只有片尾类型的 segment 才允许触发自动下一集
        if (segment.type != 'ending' ||
            !segment.autoNextEpisode ||
            _autoNextTriggered) continue;
        var remainingTime = segment.remainingTime;
        if (remainingTime == null) {
          remainingTime = totalSeconds - segment.start;
        }
        // 小于 1 秒视为无效，防止立即触发下一集导致卡死
        if (remainingTime < 1.0) continue;
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

    setState(() {
      _initialized = false;
      _error = null;
      _skippedSegments.clear();
      _autoNextTriggered = false;
    });

    final timeoutSeconds = await UserDataService.getAutoSwitchSourceTimeout();
    final openTimeout = Duration(seconds: timeoutSeconds);

    Future<bool> tryOpen(String url) async {
      final startTime = DateTime.now();
      try {
        debugPrint('PlayerScreen 尝试播放 [$_currentPlayerBackend]: $url');
        await _backend
            ?.open(
              url,
              proxyMode: _currentVideoDetail.proxyMode,
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

    bool success = await tryOpen(url);

    final autoSwitchSource = await UserDataService.getAutoSwitchSource();
    if (!success && autoSwitchSource && _sources.length > 1) {
      success = await _tryAutoSwitchSource(
        index,
        timeoutSeconds: timeoutSeconds,
      );
    }

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

    if (success) {
      setState(() {
        _currentEpisodeIndex = index;
        _initialized = true;
      });
      // 恢复上次播放位置，并限制在新视频总时长范围内
      if (_pendingInitialPositionMs > 0) {
        final maxMs = _duration.inMilliseconds > 500
            ? _duration.inMilliseconds - 500
            : _duration.inMilliseconds;
        final clampedMs = _pendingInitialPositionMs.clamp(0, maxMs);
        _backend?.seek(Duration(milliseconds: clampedMs));
        _pendingInitialPositionMs = 0;
      }
      _showControlsWithoutFocusShift();
    } else {
      setState(() {
        _error = '播放失败，请尝试切换播放源';
        _initialized = true;
      });
    }
  }

  Future<bool> _tryAutoSwitchSource(
    int targetEpisodeIndex, {
    required int timeoutSeconds,
  }) async {
    if (_sources.length <= 1) return false;

    // 记录切换前播放位置，切换成功后恢复
    final previousPositionMs = _position.inMilliseconds;

    // 按 speed 降序排序（最快的排前面），排除当前源
    final candidates = _sources.asMap().entries.toList()
      ..sort((a, b) => (b.value.speed ?? 0).compareTo(a.value.speed ?? 0));

    for (final entry in candidates) {
      if (entry.key == _currentSourceIndex) continue;
      if (!mounted) break;

      setState(() => _switchingSource = true);

      final option = _sources[entry.key];
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

      // 清理旧 backend
      _backend?.dispose();
      for (final sub in _subscriptions) {
        sub.cancel();
      }
      _subscriptions.clear();

      setState(() {
        _currentVideoDetail = response.data!;
        _currentSourceIndex = entry.key;
        _currentEpisodeIndex = targetEpisodeIndex;
        _switchingSource = false;
        _skipConfig = null;
        _skippedSegments.clear();
        _autoNextTriggered = false;
        _initialized = false;
        _error = null;
      });

      _loadSkipConfig();

      // 重新初始化 backend
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
        ..add(
          backend.durationStream.listen(_onDurationUpdate),
        )
        ..add(
          backend.playingStream.listen((playing) {
            if (mounted) setState(() => _playing = playing);
          }),
        );

      // 尝试播放目标集数，并对 M3U8 地址应用去广告过滤
      var url = newEpisodes[targetEpisodeIndex].trim();
      final filteredUrl = await AdFilterEngine.filterM3u8(
        sourceType: _currentVideoDetail.source,
        originalUrl: url,
      );
      if (filteredUrl != null && filteredUrl.isNotEmpty) {
        url = filteredUrl;
      }

      try {
        debugPrint(
          '自动切换源播放: ${option.title} -> $url',
        );
        final startTime = DateTime.now();
        await _backend
            ?.open(
              url,
              proxyMode: _currentVideoDetail.proxyMode,
            )
            .timeout(Duration(seconds: timeoutSeconds));

        final elapsed = DateTime.now().difference(startTime);
        final remaining = Duration(seconds: timeoutSeconds) - elapsed;
        final ready = remaining > Duration.zero
            ? await _waitForPlayerReady(remaining)
            : _duration.inMilliseconds > 0;
        if (!ready) {
          debugPrint('自动切换源等待播放就绪超时');
          // 继续尝试下一个源
          continue;
        }

        if (mounted) {
          setState(() => _initialized = true);
          // 恢复切换前播放位置，并限制在新视频总时长范围内
          if (previousPositionMs > 0) {
            final maxMs = _duration.inMilliseconds > 500
                ? _duration.inMilliseconds - 500
                : _duration.inMilliseconds;
            final clampedMs = previousPositionMs.clamp(0, maxMs);
            _backend?.seek(Duration(milliseconds: clampedMs));
          }
          _showControlsWithoutFocusShift();
          return true;
        }
      } catch (e, stackTrace) {
        debugPrint('自动切换源播放失败: $e');
        debugPrint('$stackTrace');
        // 继续尝试下一个源
      }
    }

    return false;
  }

  Future<void> _switchSource(int index) async {
    if (index < 0 || index >= _sources.length) return;
    if (index == _currentSourceIndex) return;

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

    _backend?.dispose();
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
      debugPrint(
        '控制栏隐藏后焦点: ${FocusManager.instance.primaryFocus?.debugLabel}',
      );
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
          backgroundColor: AppColors.bgSurface,
          title: const Text(
            '切换播放器',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textPrimary,
            ),
          ),
          content: FocusScope(
            autofocus: true,
            child: SizedBox(
              width: 400,
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: PlayerBackendType.values.length,
                itemBuilder: (context, index) {
                  final type = PlayerBackendType.values[index];
                  final selected = type == _currentPlayerBackend;
                  final String label;
                  switch (type) {
                    case PlayerBackendType.mediaKit:
                      label = 'MediaKit';
                      break;
                    case PlayerBackendType.exo:
                      label = 'ExoPlayer';
                      break;
                  }
                  return FocusableWidget(
                    autofocus: selected,
                    onTap: () {
                      Navigator.of(context).pop();
                      _switchPlayerBackend(type);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
                      padding: const EdgeInsets.all(AppSpacing.md),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppColors.primaryTint
                            : AppColors.bgElevated,
                        borderRadius: BorderRadius.circular(AppRadius.md),
                        border: Border.all(
                          color: selected
                              ? AppColors.primary
                              : AppColors.border,
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
                              : AppColors.textPrimary,
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

  Future<void> _switchPlayerBackend(PlayerBackendType type) async {
    if (type == _currentPlayerBackend) return;

    setState(() => _switchingSource = true);

    await UserDataService.savePlayerBackendForVideo(
      _currentVideoDetail.source,
      _currentVideoDetail.id,
      type,
    );

    // 切换播放器前保存当前进度，初始化完成后恢复
    _pendingInitialPositionMs = _position.inMilliseconds;

    _backend?.dispose();
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

  // 长按连续快进/快退，支持加速
  void _startLongPressSeek(String direction) {
    _longPressSeekTimer?.cancel();
    _longPressSeekTimer = Timer(const Duration(milliseconds: 400), () {
      _continuousSeekTimer?.cancel();
      final startTime = DateTime.now();
      _continuousSeekTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) {
          final elapsedMs =
              DateTime.now().difference(startTime).inMilliseconds;
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
        },
      );
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

  KeyEventResult _handleKeyEvent(KeyEvent event) {
    // 处理按键释放，停止长按连续seek
    if (event is KeyUpEvent) {
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _stopLongPressSeek();
        // 左右键释放后重新计时，确保操作结束后控制栏不会立刻消失
        if (_controlsVisible) _startControlsTimer();
      }
      return KeyEventResult.ignored;
    }

    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    debugPrint('按键: ${event.logicalKey}, 控制栏可见=$_controlsVisible');

    // 控制栏显示时，检测焦点是否在控制栏内
    if (_controlsVisible) {
      final currentFocus = FocusManager.instance.primaryFocus;
      final isFocusInControls =
          currentFocus != null &&
          _bottomControlsFocusNode.hasFocus &&
          _bottomControlsFocusNode.traversalDescendants.contains(currentFocus);

      switch (event.logicalKey) {
        // 返回/Esc 在控制栏显示时不在这里处理，统一交给 PopScope/路由返回处理，
        // 以避免焦点系统在控制栏内时与 PopScope 重复响应导致直接退出播放。
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
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        case LogicalKeyboardKey.arrowRight:
          // 焦点不在控制栏内时，右键作为快进
          if (!isFocusInControls) {
            _seekBy(Duration(seconds: _seekStep));
            _startLongPressSeek('right');
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
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowRight:
        _seekBy(Duration(seconds: _seekStep));
        _startLongPressSeek('right');
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

    // 控制栏显示时交给焦点系统处理按钮选择，但下键始终用于激活控制栏焦点
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
    _gestureIndicatorTimer = Timer(const Duration(seconds: 1), () {
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
    _continuousSeekTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) {
        if (!_isLongPressSeeking || _backend == null) return;
        final step = _longPressDirection == 'right' ? _seekStep * 3 : -_seekStep * 3;
        final target = _position + Duration(seconds: step);
        _backend?.seek(_clampDuration(target));
      },
    );
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
    if (speedBps <= 0) return '不可用';
    if (speedBps >= 1000 * 1000) {
      return '${(speedBps / 1000 / 1000).toStringAsFixed(1)} Mbps';
    }
    return '${(speedBps / 1000).toStringAsFixed(1)} Kbps';
  }

  Color _speedColor(double? speedBps) {
    if (speedBps == null || speedBps <= 0) return AppColors.error;
    if (speedBps >= 8 * 1000 * 1000) return AppColors.success;
    if (speedBps >= 2 * 1000 * 1000) return AppColors.primary;
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
      case PlayerBackendType.mediaKit:
        return 'MediaKit';
      case PlayerBackendType.exo:
        return 'ExoPlayer';
    }
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _longPressSeekTimer?.cancel();
    _continuousSeekTimer?.cancel();
    _controlsTimer?.cancel();
    _gestureIndicatorTimer?.cancel();
    _clockTimer?.cancel();
    _bottomControlsFocusNode.dispose();
    for (final sub in _subscriptions) {
      sub.cancel();
    }

    // 立即保存播放记录到 LunaTV
    _savePlayRecordToLunaTV();

    _backend?.dispose();

    // 退出播放页后允许系统自动休眠/降亮度
    WakelockPlus.disable().catchError((e) {
      debugPrint('PlayerScreen: 禁用屏幕常亮失败: $e');
    });

    // 释放本地 M3U8 代理
    AdFilterEngine.dispose();

    _playPauseFocusNode.dispose();
    _skipFocusNode.dispose();
    _rootFocusNode.dispose();

    super.dispose();
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
        index: _currentEpisodeIndex + 1, // 1-based，与 OrionTV 一致
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
    if (!_initialized || _backend == null) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }
    return Container(
      color: Colors.black,
      child: _backend!.buildVideoWidget(),
    );
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
            Icon(
              _gestureIndicatorIcon,
              color: AppColors.textPrimary,
              size: 32,
            ),
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
        onTap: _onTapScreen,
        onDoubleTap: _onDoubleTapScreen,
        onLongPressStart: _onLongPressStart,
        onLongPressEnd: _onLongPressEnd,
        onVerticalDragStart: _onVerticalDragStart,
        onVerticalDragUpdate: _onVerticalDragUpdate,
        onVerticalDragEnd: _onVerticalDragEnd,
        onHorizontalDragStart: _onHorizontalDragStart,
        onHorizontalDragUpdate: _onHorizontalDragUpdate,
        onHorizontalDragEnd: _onHorizontalDragEnd,
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
      child: Stack(
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () => Navigator.of(context).pop(),
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
    );
  }

  Widget _buildBottomControls() {
    return FocusScope(
      node: _bottomControlsFocusNode,
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
                      child: LinearProgressIndicator(
                        value: _duration.inMilliseconds > 0
                            ? _position.inMilliseconds /
                                  _duration.inMilliseconds
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
                Row(
                  children: [
                    _buildControlIconButton(
                      focusNode: _playPauseFocusNode,
                      onTap: _togglePlay,
                      icon: _playing ? Icons.pause : Icons.play_arrow,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildControlIconButton(
                      onTap: _previousEpisode,
                      icon: Icons.skip_previous,
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    _buildControlIconButton(
                      onTap: _nextEpisode,
                      icon: Icons.skip_next,
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
                    if (_currentVideoDetail.source.isNotEmpty &&
                        _currentVideoDetail.id.isNotEmpty)
                      FocusableWidget(
                        focusNode: _skipFocusNode,
                        onTap: _showSkipConfigDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color:
                                _skipConfig != null &&
                                    _skipConfig!.segments.isNotEmpty
                                ? AppColors.primaryTint
                                : AppColors.bgElevated,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_skipConfigLoading)
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.primary,
                                  ),
                                )
                              else
                                Icon(
                                  Icons.skip_next,
                                  color:
                                      _skipConfig != null &&
                                          _skipConfig!.segments.isNotEmpty
                                      ? AppColors.primary
                                      : AppColors.textPrimary,
                                  size: 18,
                                ),
                              const SizedBox(width: AppSpacing.xs),
                              Text(
                                '跳过',
                                style: TextStyle(
                                  fontFamily: 'NotoSansSC',
                                  fontSize: 13,
                                  color:
                                      _skipConfig != null &&
                                          _skipConfig!.segments.isNotEmpty
                                      ? AppColors.primary
                                      : AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    const SizedBox(width: AppSpacing.md),
                    FocusableWidget(
                      onTap: _cycleVideoFit,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bgElevated,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.aspect_ratio,
                              color: AppColors.textPrimary,
                              size: 18,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              _videoFitLabel(_videoFit),
                              style: const TextStyle(
                                fontFamily: 'NotoSansSC',
                                fontSize: 13,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    FocusableWidget(
                      onTap: _showPlayerBackendSelectorDialog,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: AppSpacing.md,
                          vertical: AppSpacing.xs,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.bgElevated,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          border: Border.all(color: AppColors.border),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.settings_applications,
                              color: AppColors.textPrimary,
                              size: 18,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              _playerBackendLabel(_currentPlayerBackend),
                              style: const TextStyle(
                                fontFamily: 'NotoSansSC',
                                fontSize: 13,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    if (_canSwitchSource)
                      FocusableWidget(
                        onTap: _showSourceSelectorDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.bgElevated,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.swap_horiz,
                                color: AppColors.textPrimary,
                                size: 18,
                              ),
                              SizedBox(width: AppSpacing.xs),
                              Text(
                                '换源',
                                style: TextStyle(
                                  fontFamily: 'NotoSansSC',
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    if (_canSwitchSource) const SizedBox(width: AppSpacing.md),
                    if (_currentVideoDetail.episodes.length > 1)
                      FocusableWidget(
                        onTap: _showEpisodeSelectorDialog,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.md,
                            vertical: AppSpacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.bgElevated,
                            borderRadius: BorderRadius.circular(AppRadius.md),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.list,
                                color: AppColors.textPrimary,
                                size: 18,
                              ),
                              SizedBox(width: AppSpacing.xs),
                              Text(
                                '选集',
                                style: TextStyle(
                                  fontFamily: 'NotoSansSC',
                                  fontSize: 13,
                                  color: AppColors.textPrimary,
                                ),
                              ),
                            ],
                          ),
                        ),
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
      child: Icon(
        icon,
        color: AppColors.textPrimary,
        size: 28,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_controlsVisible,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        _hideControls();
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
          duration: const Duration(milliseconds: 200),
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
      backgroundColor: AppColors.bgSurface,
      title: const Text(
        '切换播放源',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: AppColors.textPrimary,
        ),
      ),
      content: FocusScope(
        autofocus: true,
        child: SizedBox(
          width: 640,
          height: 240,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            controller: _scrollController,
            itemCount: widget.sources.length,
            itemBuilder: (context, index) {
              final source = widget.sources[index];
              final selected = index == widget.currentIndex;
              return Padding(
                padding: EdgeInsets.only(
                  right: index < widget.sources.length - 1
                      ? AppSpacing.md
                      : 0,
                ),
                child: _SourceSelectorCard(
                  key: selected ? _selectedKey : null,
                  focusNode: selected ? _selectedFocusNode : null,
                  autofocus: selected,
                  source: source,
                  selected: selected,
                  formatSpeed: widget.formatSpeed,
                  speedColor: widget.speedColor,
                  onTap: () => widget.onSelect(index),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _SourceSelectorCard extends StatelessWidget {
  final SourceOption source;
  final bool selected;
  final String Function(double?) formatSpeed;
  final Color Function(double?) speedColor;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final bool autofocus;

  const _SourceSelectorCard({
    super.key,
    required this.source,
    required this.selected,
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
                  placeholder: (_, __) => Container(
                    color: AppColors.bgSurface,
                  ),
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
                  top: 6,
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
          duration: const Duration(milliseconds: 200),
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
      backgroundColor: AppColors.bgSurface,
      title: const Text(
        '选集',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: AppColors.textPrimary,
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
                      color: selected
                          ? AppColors.primary
                          : AppColors.textPrimary,
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
