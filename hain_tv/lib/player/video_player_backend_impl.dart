import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/user_data_service.dart';
import 'video_player_backend.dart';

const _defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

Map<String, String> _refererFor(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.scheme.startsWith('http')) {
      final referer = '${uri.scheme}://${uri.host}/';
      return {
        'Referer': referer,
        'Origin': '${uri.scheme}://${uri.host}',
      };
    }
  } catch (_) {
    // 忽略无效 URL
  }
  return {};
}

class VideoPlayerBackendImpl implements VideoPlayerBackend {
  VideoPlayerController? _controller;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  Timer? _timer;
  BoxFit _fit = BoxFit.contain;

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
  }) async {
    await dispose();

    final lowerUrl = url.toLowerCase();
    String finalUrl = url;
    final proxyUrl = await UserDataService.getM3u8ProxyUrl();
    final needsProxy = proxyMode ||
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('/hls/');
    if (proxyUrl.isNotEmpty && needsProxy) {
      finalUrl = '$proxyUrl${Uri.encodeComponent(url)}';
    }

    final effectiveHeaders = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ..._refererFor(url),
      ...?headers,
    };

    final lowerFinalUrl = finalUrl.toLowerCase();
    final isNetwork = lowerFinalUrl.startsWith('http://') ||
        lowerFinalUrl.startsWith('https://');
    final isFile = lowerFinalUrl.startsWith('file://');

    VideoFormat? formatHint;
    if (lowerFinalUrl.contains('.m3u8') || lowerFinalUrl.contains('/hls/')) {
      formatHint = VideoFormat.hls;
    } else if (lowerFinalUrl.contains('.mpd')) {
      formatHint = VideoFormat.dash;
    } else if (lowerFinalUrl.contains('.ism')) {
      formatHint = VideoFormat.ss;
    } else if (lowerFinalUrl.contains('.mp4') ||
        lowerFinalUrl.contains('.mkv') ||
        lowerFinalUrl.contains('.flv') ||
        lowerFinalUrl.contains('.avi') ||
        lowerFinalUrl.contains('.mov') ||
        lowerFinalUrl.contains('.webm')) {
      formatHint = VideoFormat.other;
    }

    debugPrint('VideoPlayerBackendImpl open: $finalUrl');

    if (isNetwork) {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(finalUrl),
        httpHeaders: effectiveHeaders,
        formatHint: formatHint,
        viewType: VideoViewType.platformView,
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

    try {
      await _controller!.initialize();
    } catch (e, stackTrace) {
      debugPrint('VideoPlayerBackendImpl 初始化失败: $finalUrl');
      debugPrint('错误: $e');
      debugPrint('$stackTrace');
      rethrow;
    }

    await _controller!.play();

    _durationController.add(_controller!.value.duration);
    _startPositionTimer();

    if (startAt != null && startAt > Duration.zero) {
      await seek(startAt);
    }
  }

  void _onControllerValueChanged() {
    final value = _controller?.value;
    if (value == null) return;
    if (value.hasError && value.errorDescription != null) {
      debugPrint(
        'VideoPlayerBackendImpl 播放错误: ${value.errorDescription}',
      );
    }
  }

  void _startPositionTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(milliseconds: 200), (_) {
      final value = _controller?.value;
      if (value == null) return;
      _positionController.add(value.position);
      _durationController.add(value.duration);
      _playingController.add(value.isPlaying);
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
    await _controller?.seekTo(position);
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
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Future<void> dispose() async {
    _timer?.cancel();
    _timer = null;
    _controller?.removeListener(_onControllerValueChanged);
    await _controller?.dispose();
    _controller = null;
  }
}
