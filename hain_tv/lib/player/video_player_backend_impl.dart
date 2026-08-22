import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import '../services/ad_filter_service.dart';
import '../services/user_data_service.dart';
import '../utils/windows_logger.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';

const _defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

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
  VideoPlayerController? _controller;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  Timer? _timer;
  bool _completedReported = false;
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
    BufferProfileConfig? bufferConfig,
    bool isLive = false,
    VideoFormat? formatHint,
  }) async {
    await dispose();
    _completedReported = false;

    final lowerUrl = url.toLowerCase();
    String finalUrl = url;

    // 直播流不应用点播源的代理、去广告等设置。
    final proxyUrl = isLive ? '' : await UserDataService.getM3u8ProxyUrl();
    final adFilterEnabled = isLive ? false : await AdFilterService.isEnabled();
    final isLocalProxy = _isLocalProxyUrl(url);
    final isM3u8 = lowerUrl.contains('.m3u8') || lowerUrl.contains('/hls/');
    // 统一逻辑：仅当源本身声明 proxyMode，或去广告开启且配置了全局 M3U8 代理且当前是 M3U8 时，
    // 才走全局代理；去广告关闭时直接播放原始 URL，与 Selene 保持一致。
    final needsProxy = !isLive &&
        !isLocalProxy &&
        (proxyMode || (adFilterEnabled && proxyUrl.isNotEmpty && isM3u8));
    if (needsProxy) {
      finalUrl = '$proxyUrl${Uri.encodeComponent(url)}';
    }

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
          lowerFinalUrl.startsWith('rtp://') ||
          lowerFinalUrl.startsWith('udp://') ||
          lowerFinalUrl.startsWith('rtsp://')) {
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

    if (isNetwork) {
      _controller = VideoPlayerController.networkUrl(
        Uri.parse(finalUrl),
        httpHeaders: effectiveHeaders,
        formatHint: effectiveFormatHint,
        // Windows 端 FVP/libmdk 使用 texture view 更稳定，
        // platform view 在部分 Windows 环境会导致初始化失败或无法发起网络请求。
        viewType: Platform.isWindows
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

    try {
      await _controller!.initialize();
    } catch (e, stackTrace) {
      debugPrint('VideoPlayerBackendImpl 初始化失败: $finalUrl');
      debugPrint('错误: $e');
      debugPrint('$stackTrace');
      rethrow;
    }

    // 若指定了起始位置，先在暂停状态下 seek，再开始播放，
    // 避免 ExoPlayer 在 HLS 起播阶段 seek 被忽略或回退到 0。
    if (startAt != null && startAt > Duration.zero) {
      await seek(startAt);
      // 给 ExoPlayer 一小段时间应用 seek，随后若位置仍被回退则再次 seek。
      await Future.delayed(const Duration(milliseconds: 100));
      final actual = _controller?.value.position ?? Duration.zero;
      if (actual.inMilliseconds < startAt.inMilliseconds * 0.5) {
        debugPrint(
          'VideoPlayerBackendImpl 起始定位未生效，再次 seek: actual=${actual.inMilliseconds}ms target=${startAt.inMilliseconds}ms',
        );
        await seek(startAt);
      }
    }

    await _controller!.play();

    _durationController.add(_controller!.value.duration);
    _startPositionTimer();
  }

  void _onControllerValueChanged() {
    final value = _controller?.value;
    if (value == null) return;
    if (value.hasError && value.errorDescription != null) {
      debugPrint('VideoPlayerBackendImpl 播放错误: ${value.errorDescription}');
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
      _positionController.add(value.position);
      _durationController.add(value.duration);
      _bufferedController.add(
        value.buffered.isNotEmpty ? value.buffered.last.end : value.position,
      );
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
  Stream<Duration> get bufferedStream => _bufferedController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Future<void> dispose() async {
    WindowsLogger.log('VideoPlayerBackendImpl', 'dispose 开始');
    _timer?.cancel();
    _timer = null;
    _completedReported = false;
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
      await controller.dispose();
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: 完成');
    } catch (e) {
      // 初始化失败时底层 playerId 可能不存在，dispose 会抛 IllegalStateException，
      // 忽略该异常避免影响下一次播放。
      debugPrint('VideoPlayerBackendImpl dispose 忽略异常: $e');
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: 异常 $e');
    }
  }
}
