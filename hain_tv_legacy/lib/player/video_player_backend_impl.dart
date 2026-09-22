import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
import 'package:fvp/fvp.dart';
import '../services/ad_filter_service.dart';
import '../services/user_data_service.dart';
import '../utils/windows_logger.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';

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
  VideoPlayerController? _controller;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  Timer? _timer;
  bool _completedReported = false;
  BoxFit _fit = BoxFit.contain;

  // —— 仅用于诊断打印，不影响任何播放行为 ——
  bool _firstFrameReported = false;
  Duration _lastStallPosition = Duration.zero;
  DateTime _lastStallCheck = DateTime.now();
  DateTime _lastProgressLog = DateTime.now();

  // —— fvp 起播后再定位（deferStartSeek=true 时启用，见 open() 中的说明）——
  // fvp/libmdk 在 HLS prepare 完成、play 之前 seek 会卡死（position 停在 seek
  // 目标、buffered 不涨、不再推进）。故 fvp 后端不在 open 阶段 seek，改为等真正
  // 起播（position 已推进）后再定位；若定位后仍停滞，则回退从头播放。
  Duration? _pendingStartSeek;
  bool _startSeekWatch = false;
  DateTime _startSeekAt = DateTime.now();
  Duration _startSeekPos = Duration.zero;

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
    List<String>? fvpVideoDecoders,
    bool deferStartSeek = false,
  }) async {
    await dispose();
    _completedReported = false;
    // 重置诊断状态（仅日志用）
    _firstFrameReported = false;
    _lastStallPosition = Duration.zero;
    _lastStallCheck = DateTime.now();
    _lastProgressLog = DateTime.now();
    // 重置「起播后再定位」状态
    _pendingStartSeek = null;
    _startSeekWatch = false;

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

      // fvp 解码器设置（仅 fvp 后端透传 fvpVideoDecoders，ExoPlayer 不传此参数
      // → 走原生默认，不受影响）：
      // - 硬解设置=开（默认）→ FvpBackend 传 null，不在此强制，交由 fvp 自身
      //   registerWith 的模拟器感知逻辑决定（真机偏好 MediaCodec 硬解、x86_64 模拟器
      //   跳过硬解改用 FFmpeg 软解，这正是 1.3.5 能正常播放的原因）。
      // - 硬解设置=关 → FvpBackend 传 ['FFmpeg']，按用户意图强制软解。
      // 注意：之前曾在此强制 ['AMediaCodec','FFmpeg']，等于在模拟器上指定了不存在的
      // AMediaCodec → 解码停滞卡死；现已改回「开硬解不强制」，由 fvp 内置逻辑接管。
      // 必须在 initialize() 之前设置，且经 fvp 的 FVPControllerExtensions 调用，
      // ExoPlayer 控制器无此扩展（fvpVideoDecoders 为 null 时不进入本分支）。
      if (fvpVideoDecoders != null) {
        try {
          _controller!.setVideoDecoders(fvpVideoDecoders);
          debugPrint(
            'VideoPlayerBackendImpl fvp 视频解码器已强制: ${fvpVideoDecoders.join(',')}',
          );
        } catch (e) {
          debugPrint('VideoPlayerBackendImpl 设置 fvp 视频解码器失败(可忽略): $e');
        }
      }

      // 缓冲窗口（fvp 专有扩展 setBufferRange）：
      //
      // 恢复 1.3.5 行为——fvp 后端（FvpBackend）现在会透传 bufferConfig
      // （调用方未传时回退 BufferProfileConfig.current()，点播/回放=放大窗口
      // min=1500/max=20000ms、直播=低延迟），故此处对 fvp 同样进入、下发放大窗口。
      //
      // 曾误信「放大缓冲窗口导致模拟器解码停滞」把 fvp 的 bufferConfig 钉成 null，
      // 但 11:27 那次「fvp + platformView + 放大缓冲窗口」5.7s 正常起播、position
      // 正常递增即为反证；194523/211609 冻结的真实根因是 fvp_backend 强制
      // setVideoDecoders(['AMediaCodec','FFmpeg']) 在模拟器指定了不存在的 AMediaCodec
      // （已于 fvp_backend 改回 `hw ? null : ['FFmpeg']` 修复），与缓冲窗口无关。
      // 故此处不再对 fvp 特殊豁免，统一按 bufferConfig 下发即可。
      //
      // 注意：setBufferRange 仅 fvp 控制器有此扩展；VLC（Windows 特有）控制器无
      // 此扩展，调用会被 try/catch 静默忽略；ExoPlayer（MethodChannel）不接收该调用。
      // 「缓冲模式」对 ExoPlayer / VLC 的放大仍各自生效。
      if (bufferConfig != null) {
        try {
          _controller!.setBufferRange(
            min: bufferConfig.fvpMinMs,
            max: bufferConfig.fvpMaxMs,
            drop: bufferConfig.fvpDrop,
          );
        } catch (e) {
          debugPrint('VideoPlayerBackendImpl pre-init setBufferRange 失败(可忽略): $e');
        }
      }

      // 分段耗时日志：直播首次进入偶发长时间无画面，需要区分卡在「创建 controller」
      // 「initialize（原生 prepare / DNS / TLS 握手）」还是后续步骤。仅 debugPrint
      // 会被节流丢弃，这里用落盘日志。
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

      // Windows fvp 直连根因修复双保险：main_windows 已设 demuxer.io=0 让 FFmpeg avio
      // 继承 player 级 avio.headers 到 HLS 子请求；此处再补设 MDK 的 http-header 属性，
      // 覆盖 mdkio 旧路径可能残留的 header 不继承问题，确保视频分片请求携带 UA/Referer。
      if (Platform.isWindows && !needsProxy && isNetwork) {
        try {
          final sb = StringBuffer();
          effectiveHeaders.forEach((k, v) => sb.writeln('$k: $v'));
          _controller!.setProperty('http-header', sb.toString());
          debugPrint('VideoPlayerBackendImpl 已补设 Windows 直连 http-header');
        } catch (e) {
          debugPrint('VideoPlayerBackendImpl 补设 http-header 失败(可忽略): $e');
        }
      }

      // 若指定了起始位置，先在暂停状态下 seek，再开始播放，
      // 避免 ExoPlayer 在 HLS 起播阶段 seek 被忽略或回退到 0。
      //
      // ⚠️ 但这段 seek 只对 ExoPlayer 安全：fvp/libmdk 在 HLS `prepare()` 完成、
      // `play()` 之前 seek 会卡死（2026-09-20 定稿根因）—— 表现为 position 停在
      // seek 目标、buffered==position 不涨、不再推进、`FVP_DECODE_STALL` 反复。
      // 铁证：同一 URL 同位置下 ExoPlayer 正常、fvp 冻结（exo 464000ms ✅ /
      // fvp 467863ms ❌；exo 105279ms ✅ / fvp 1227000ms ❌）。而直播/回放不传
      // startAt 故从不触发本段，正是"直播/回放正常、点播卡"的分水岭。
      // 因此 fvp 后端（FvpBackend）传 deferStartSeek: true —— 此处不 seek，
      // 改为在 position 定时器里等真正起播后再定位（见 _startPositionTimer）。
      if (startAt != null && startAt > Duration.zero) {
        if (deferStartSeek) {
          _pendingStartSeek = startAt;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '起始定位延后（fvp 起播后再 seek）: ${startAt.inMilliseconds}ms',
          );
        } else {
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
      }

      await _controller!.play();

      _durationController.add(_controller!.value.duration);
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

      // —— 以下均为诊断日志，不影响播放行为 ——
      final now = DateTime.now();

      // —— fvp 起播后再定位（deferStartSeek，见 open() 中说明）——
      // 起播判定：已在播放、无错误、且 position 已推进到 300ms 以上
      // （说明解码确实在跑，libmdk 已进入正常解封装/解码状态）。
      if (_pendingStartSeek != null && !value.hasError) {
        if (value.isPlaying &&
            value.position >= const Duration(milliseconds: 300)) {
          final target = _pendingStartSeek!;
          _pendingStartSeek = null;
          _startSeekWatch = true;
          _startSeekAt = now;
          _startSeekPos = value.position;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '起播稳定（position=${value.position.inMilliseconds}ms），'
                '执行起始定位 → ${target.inMilliseconds}ms',
          );
          unawaited(seek(target));
        }
      } else if (_startSeekWatch) {
        if (value.position > _startSeekPos + const Duration(milliseconds: 500)) {
          // 定位后 position 已正常推进 → 生效，结束观察。
          _startSeekWatch = false;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '起始定位生效，播放已推进 position=${value.position.inMilliseconds}ms',
          );
        } else if (now.difference(_startSeekAt).inMilliseconds >= 4000) {
          // 定位后 4s 仍无推进 → 判为 seek 卡死，回退从头播放（避免永久黑屏）。
          _startSeekWatch = false;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '⚠️ 起始定位后 position 停滞在 ${value.position.inMilliseconds}ms（≥4s），'
                '回退从头播放',
          );
          unawaited(seek(Duration.zero));
        }
      }

      // 首帧尺寸就绪：解码器已开始产出画面（size 由 0 变为有效值）。
      if (!_firstFrameReported &&
          value.size.width > 0 &&
          value.size.height > 0) {
        _firstFrameReported = true;
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          '首帧尺寸就绪 size=${value.size} position=${value.position.inMilliseconds}ms',
        );
      }

      // 每 1 秒打印一次进度，用于区分「网络缓冲」(buffered 在涨但 position 不动)
      // 与「解码卡住」(buffered/position 都不动)。
      if (now.difference(_lastProgressLog).inMilliseconds >= 1000) {
        _lastProgressLog = now;
        final buffered = value.buffered.isNotEmpty
            ? value.buffered.last.end
            : Duration.zero;
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          '进度 playing=${value.isPlaying} '
              'position=${value.position.inMilliseconds}ms '
              'buffered=${buffered.inMilliseconds}ms '
              'duration=${value.duration.inMilliseconds}ms '
              'size=${value.size} error=${value.errorDescription ?? '无'}',
        );
      }

      // 卡顿探测：正在播放但 position 连续 ≥2s 无推进 → 解码/渲染卡死。
      if (value.isPlaying) {
        if (value.position > _lastStallPosition) {
          _lastStallPosition = value.position;
          _lastStallCheck = now;
        } else if (now.difference(_lastStallCheck).inMilliseconds >= 2000) {
          final buffered = value.buffered.isNotEmpty
              ? value.buffered.last.end
              : Duration.zero;
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '⚠️ FVP_DECODE_STALL: 播放中 position 卡在 '
                '${value.position.inMilliseconds}ms 已≥2s 无推进; '
                'buffered=${buffered.inMilliseconds}ms size=${value.size} '
                'duration=${value.duration.inMilliseconds}ms '
                '=> 若 buffered 在涨=解码卡住, 若 buffered 也不动=网络/源卡住',
          );
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
    _pendingStartSeek = null;
    _startSeekWatch = false;
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
