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

/// 缓冲窗口的适用判据：本文件服务的后端是 ExoPlayer（Android）。
/// 🔴 2026-10-16：fvp 已全平台摘除，原先「fvp 走 setBufferRange、ExoPlayer 走
/// ExoPlayerBufferConfig」的双路径判据随之失效，现仅由 ExoPlayerBufferConfig
/// 经 MethodChannel 下发。mpv 后端的缓冲档位由 MpvBackend 换算成 cacheSecs 下发。

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

  // —— 续播 seek 自愈 ——
  //
  // 🔴 2026-10-16：fvp 摘除后本文件只服务 ExoPlayer。
  //   原 `_fvpMode` 标志（由调用方传 isFvpBackend 决定）已删除 —— 它存在的前提是
  //   「同一控制器要区分 fvp / ExoPlayer 两种后端」，而现在不存在 fvp 后端了。
  //   原先「仅 fvp 走自愈、ExoPlayer seek 可靠不走」的分流，随之简化为：
  //   自愈逻辑保留（它对任何后端的「时钟在跑但读取线程冻结」都是有效的兜底），
  //   但不再需要后端判据 —— 由 _resumeTarget 是否存在自然门控。
  //
  // _resumeTarget：本次 open 的续播目标位置。部分后端在特定源上 seekTo 仅设置时钟、
  //   读取线程未跳到目标段，且 value.position/value.buffered 会谎报为时钟值，导致
  //   「基于 bufferedEnd 的判定」失效 → 永久冻结（时钟在续播点、读取停在分段 0）。
  //   故在播放中检测到「playing 但 position 持续不推进且非网络缓冲等待」时，主动
  //   重试 seek；重试耗尽则回退从片头播放（远比永久冻结可接受）。
  // _stallRecoveries / _lastStallRecoverAt：限制自愈重试频率，避免正常网络缓冲抖动误触发。
  Duration? _resumeTarget;

  // _resumeSeekDeadline：「续播定位自愈」的**有效期截止时间**。
  //
  // 🔴 2026-09-28 修复「fvp 偶发播放记录定位失败」（鸿蒙版实证，本工程同源缺陷）。
  //
  // 原实现里 _resumeTarget 只在 open() 赋值、仅在「回退片头」时清空，
  // 于是整个播放期间它都非 null，stall 自愈判定会一直拿着**起播点**做校验。
  // 用户一旦手动 seek 到别处，自愈就可能把正常播放误判成「续播定位失败」，
  // 然后 seek 回起播点 —— 观感即「画面突然跳回很久以前的位置」，
  // 用户报告为「播放记录定位失败」。
  // 实测日志（设备 9CN0223912004329，鸿蒙版）：
  //     12:18:31 seek target=695859ms          （用户快退）
  //     12:18:34 seek target=649320ms          （用户再快退）
  //              进度 position=649320ms buffered=651199ms   ← 正常播放中
  //     ⚠️ FVP_DECODE_STALL: position 卡在 649320ms 已≥2s 无推进
  //     [STALL-RECOVER] 续播定位疑似失败，重试 seek(743000ms) 第 1/3 次
  //                                    ↑ 跳回起播点 743s
  //     随后第 2/3、3/3 次，重试耗尽后上抛 onUnrecoverableStall → 重建播放器。
  //
  // 该缺陷与平台无关，只取决于「是否用 fvp 后端 + 缓冲预读是否偏弱」：
  // ExoPlayer 预读充足、buffered 长期领先 position，故安卓默认后端很少触发；
  // 一旦用户切到 fvp 后端，本工程同样会中招。故与鸿蒙版同步修复。
  //
  // 处置：给自愈加明确有效期。真需要自愈的场景是「起播定位后读取线程没跳段」，
  // 必然在起播后很短时间内暴露；窗口内仍救不回来就说明不是该机制能处理的问题，
  // 应放手让播放继续，而不是无限期拿旧目标反复 seek。
  DateTime? _resumeSeekDeadline;
  static const Duration _resumeSeekWindow = Duration(seconds: 20);

  int _stallRecoveries = 0;
  DateTime? _lastStallRecoverAt;
  static const int _maxStallRecoveries = 3;
  // onUnrecoverableStall：续播定位卡死且 App 层 seek 重试/回退片头均 no-op
  // （读取线程真死）时上抛，由播放页重建播放器（保留续播点）。
  // 仅回调已注册时触发。
  VoidCallback? onUnrecoverableStall;
  bool _unrecoverableSignaled = false;

  VideoPlayerController? get controller => _controller;

  /// video_player 走 Flutter 纹理，view 由插件内部管理，
  /// 不依赖播放页先 build 视频层，故无需提前挂载。
  @override
  bool get requiresEagerMount => false;

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
  }) async {
    await dispose();
    _completedReported = false;
    // 重置诊断状态（仅日志用）
    _firstFrameReported = false;
    _lastStallPosition = Duration.zero;
    _lastStallCheck = DateTime.now();
    _lastProgressLog = DateTime.now();
    // 续播 seek 自愈状态重置（_resumeTarget 在下方按续播点赋值，非空即启用自愈）
    _resumeTarget = null;
    _resumeSeekDeadline = null;
    _stallRecoveries = 0;
    _lastStallRecoverAt = null;
    _unrecoverableSignaled = false;

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

      // 🔴 2026-10-16：原「fvp 解码器强制」块已删除（fvpVideoDecoders 参数随之移除）。
      //   ExoPlayer 的解码器选择由原生侧按用户「硬件解码」开关决定，不在此干预。

      // 分段耗时日志：直播首次进入偶发长时间无画面，需要区分卡在「创建 controller」
      // 「initialize（原生 prepare / DNS / TLS 握手）」还是后续步骤。仅 debugPrint
      // 会被节流丢弃，这里用落盘日志。

      // ⚠️ 2026-09-24 23:2x 回退：曾在此处对 fvp 用 prepare(position:) 把续播点下发给
      // libmdk（避免 post-init seek 的读取器死寂）。实测**反而更糟**：libmdk 收到
      // prepare(续播点) 后并不跳段，而是从第 0 片**顺序下载**到续播点（日志实证 init 期间
      // 依次请求播放列表第 1/2/3…片），导致 initialize 耗时 14-32s（安卓侧虽 init 快但
      // 定位无效），超过 openTimeout(15s) → 误报「播放失败，即将进行自动换源」、起播显著
      // 变慢、Windows 全线播不了。fvp 仍改回「prepare(0) + initialize 后 seek 续播点」。
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

      // 🔴 2026-10-16：原「fvp 缓冲窗口下发（setBufferRange）」整段已删除。
      //   该扩展仅 fvp/libmdk 控制器提供，fvp 摘除后不再有调用对象。
      //   「缓冲模式」档位现由各后端各自的通道承担：
      //     · ExoPlayer → ExoPlayerBufferConfig 经 MethodChannel 下发给原生
      //     · mpv       → MpvBackend 换算成 cacheSecs 经 open 下发
      //     · VLC       → vlcCachingMs

      // 🔴 2026-10-16：原「Windows fvp 补设 MDK http-header 属性」块已删除。
      //   `setProperty` 是 fvp 的 FVPControllerExtensions 扩展方法，不属于
      //   VideoPlayerController 原生 API —— fvp 摘除后该方法不存在（编译期报错）。
      //   它原本是为绕过 mdkio 不继承子请求 header 的缺陷而设的双保险；
      //   mpv 后端不存在该缺陷（原生按 http-header-fields 处理子请求），
      //   ExoPlayer 则由 ExoPlayerBackend 在原生侧统一设 header。

      // 若指定了起始位置（播放记录续播 / 拖进度条），在 initialize() 完成后**立即**
      // seek，再开始播放 —— 即「播放记录第一时间读取」。
      //
      // 🔴 2026-10-16：原 fvp 分支（3 次带抖动延迟重试 + 依赖运行期 stall 自愈兜底）
      //   已随 fvp 摘除删除。本文件现只服务 ExoPlayer，其 seek 行为可靠，
      //   沿用「基于实际缓冲位置」的判定 + 失败回退 0 即可。
      //
      // 此处之所以在 play() 之前 seek：让首帧就从目标位置产出，避免从 0 起播后
      // 再跳一下（mpv 同理）。
      if (startAt != null && startAt > Duration.zero) {
        _resumeTarget = startAt;
        // 「续播定位自愈」的有效期只到起始定位结束为止，详见 _resumeSeekDeadline 注释。
        _resumeSeekDeadline = DateTime.now().add(_resumeSeekWindow);
        {
          await seek(startAt);
          // ExoPlayer：seek 可靠，沿用「基于实际缓冲位置」的判定 + 失败回退 0。
          // 成功定位后 buffered 会预读到目标点，失败则仅覆盖开头几秒。
          var seekResolved = false;
          for (var attempt = 0; attempt < 5; attempt++) {
            await Future.delayed(const Duration(milliseconds: 200));
            final buffered = _controller?.value.buffered ?? const [];
            final bufferedEnd =
                buffered.isNotEmpty ? buffered.last.end : Duration.zero;
            if (bufferedEnd >= startAt) {
              seekResolved = true;
              break;
            }
            debugPrint(
              'VideoPlayerBackendImpl 起始定位未生效(尝试 $attempt): '
              'bufferedEnd=${bufferedEnd.inMilliseconds}ms '
              'target=${startAt.inMilliseconds}ms，再次 seek',
            );
            await seek(startAt);
          }
          if (!seekResolved) {
            debugPrint(
              'VideoPlayerBackendImpl 起始定位彻底失败，回退从 0 播放: '
              'target=${startAt.inMilliseconds}ms',
            );
            await seek(Duration.zero);
          }
          // ExoPlayer 的定位已在上面同步确认完毕（判据成立即 break），无需运行期再自愈，
          // 故立即关闭「续播自愈」作用域，避免它在此后整个播放期持续拿起播点做 stall
          // 校验、把用户的手动 seek 误判为「定位失败」而拉回。
          _resumeTarget = null;
          _resumeSeekDeadline = null;
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
        final buf = value.buffered;
        final buffered = buf.isNotEmpty ? buf.last.end : Duration.zero;
        // [FVP-DIAG] bufN = value.buffered 的条目数，是区分两种「buffered 恒等于
        // position」的关键：bufN>0 表示 fvp 确实上报了缓冲事件、但队列时长为 0
        // （读取线程未预取）；bufN==0 表示从未上报过缓冲事件（则缓冲条在 fvp 上
        // 天然画不出来，与读取无关）。isBuffering 反映 mdk 自己是否在等数据。
        WindowsLogger.log(
          'VideoPlayerBackendImpl',
          '进度 playing=${value.isPlaying} buffering=${value.isBuffering} '
              'position=${value.position.inMilliseconds}ms '
              'buffered=${buffered.inMilliseconds}ms '
              'bufN=${buf.length}'
              '${buf.isEmpty ? '' : ' bufFirst=${buf.first.start.inMilliseconds}/${buf.first.end.inMilliseconds}'} '
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
          // —— fvp 续播定位失败自愈（2026-09-24）：时钟在续播点但读取线程未跳段 →
          // 永久冻结。fvp 会谎报 position/buffered 为时钟值，无法靠 bufferedEnd 判定，
          // 故在此「playing 但 position 持续不推进且非网络缓冲等待」时主动回退：
          // 先重试 seek 目标段（抖动以绕过 libmdk seek no-op）；重试耗尽后回退从片头
          // 播放（远比永久冻结可接受）。4s 冷却 + 次数上限避免正常网络缓冲抖动误触发。
          // fvp 续播卡死时往往 isBuffering==true（假缓冲：读取线程卡在某段，
          // libmdk 自认为在等数据），用 !isBuffering 会把这类卡死永久排除，
          // 导致自愈从不触发。改用「buffered 是否领先 position」区分：
          // 真网络缓冲时 buffered 会明显领先 position；卡死时 buffered≈position（不领先）。
          final _bufferedEnd = value.buffered.isNotEmpty
              ? value.buffered.last.end
              : Duration.zero;
          final _noForwardBuffer =
              _bufferedEnd <= value.position + const Duration(milliseconds: 1000);

          // 🔴 2026-09-28 修复「fvp 偶发播放记录定位失败」（详见 _resumeSeekDeadline 注释）：
          // 原判据会让自愈在整个播放期持续生效 —— 用户手动 seek 到别处后，
          // 只要 position 有 2 秒没推进，就会被判成「续播定位失败」并 seek 回起播点。
          // 这里补两道闸：
          //  1) 有效期：自愈只服务于「起播定位」这一小段时间（_resumeSeekWindow），
          //     窗口外一律不再干预，避免拿着旧目标把用户拉回很久以前的位置；
          //  2) 位置闸：只有当前播放位置仍**停留在续播点附近**时才可能是「定位后没跳段」。
          //     若用户已经 seek 走了（position 明显偏离 _resumeTarget），那属于用户
          //     主动操作引发的正常缓冲，绝不该回退到起播点。
          final _resumeDeadline = _resumeSeekDeadline;
          final _withinResumeWindow =
              _resumeDeadline != null && now.isBefore(_resumeDeadline);
          final _stillNearResumePoint = _resumeTarget != null &&
              (value.position - _resumeTarget!).abs() <=
                  const Duration(seconds: 10);
          if (!_withinResumeWindow && _resumeTarget != null) {
            // 窗口已过：关闭自愈作用域，之后不再参与判定。
            _resumeTarget = null;
            _resumeSeekDeadline = null;
          }
          if (_resumeTarget != null &&
              _withinResumeWindow &&
              _stillNearResumePoint &&
              _noForwardBuffer &&
              now
                      .difference(_lastStallRecoverAt ??
                          DateTime.fromMillisecondsSinceEpoch(0))
                      .inMilliseconds >
                  4000) {
            _stallRecoveries++;
            _lastStallRecoverAt = now;
            if (_stallRecoveries <= _maxStallRecoveries) {
              // 抖动目标，绕过 libmdk「已在目标位置」的 seek no-op，强制读取线程重跳。
              final jittered = _stallRecoveries.isOdd
                  ? _resumeTarget!
                  : _resumeTarget! + const Duration(milliseconds: 500);
              WindowsLogger.log(
                'VideoPlayerBackendImpl',
                '[STALL-RECOVER] 续播定位疑似失败，重试 '
                'seek(${jittered.inMilliseconds}ms) 第 $_stallRecoveries/$_maxStallRecoveries 次',
              );
              seek(jittered); // fire-and-forget，下次 stall 判定验证是否生效
            } else {
              // 重试耗尽且 App 层任何 seek（续播点/片头）都是 no-op（fvp reader 真死）：
              // 上抛由播放页原地重建 fvp 后端（仍从续播点），而非切 ExoPlayer。重建等于
              // 再给 libmdk 一次「prepare(position:) 从续播点打开」的机会，绕开读取器死寂
              // 竞态；若仍卡死，重建有次数上限，超限则回退片头避免永久冻结。
              if (!_unrecoverableSignaled && onUnrecoverableStall != null) {
                _unrecoverableSignaled = true;
                WindowsLogger.log(
                  'VideoPlayerBackendImpl',
                  '[STALL-RECOVER] fvp 续播重试耗尽且 reader 真死，上抛重建 fvp 后端 '
                  '(target=${_resumeTarget!.inMilliseconds}ms)',
                );
                onUnrecoverableStall!();
              } else {
                // 无回调兜底：回退片头，避免永久冻结。
                WindowsLogger.log(
                  'VideoPlayerBackendImpl',
                  '[STALL-RECOVER] 续播重试耗尽，回退从 0 播放 '
                  '(target=${_resumeTarget!.inMilliseconds}ms)',
                );
                seek(Duration.zero);
                _resumeTarget = null; // 已回退，避免反复回退到片头
              }
            }
          }
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
    // —— 诊断埋点（[FVP-DIAG]，用于定位「seek 后读取线程不预取」）——
    final before = _controller?.value.position ?? Duration.zero;
    final t0 = DateTime.now();
    await _controller?.seekTo(position);
    final after = _controller?.value.position ?? Duration.zero;
    final buf = _controller?.value.buffered ?? const [];
    WindowsLogger.log(
      'VideoPlayerBackendImpl',
      '[FVP-DIAG] seek target=${position.inMilliseconds}ms '
          'before=${before.inMilliseconds}ms after=${after.inMilliseconds}ms '
          'elapsed=${DateTime.now().difference(t0).inMilliseconds}ms '
          'bufN=${buf.length}'
          '${buf.isEmpty ? '' : ' bufEnd=${buf.last.end.inMilliseconds}ms'}',
    );
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
    _unrecoverableSignaled = false;
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
      // ⚠️ controller.dispose() 必须加超时兜底（fvp 全平台退出卡死的通病点，
      // 2026-09-22 定案）：libmdk 原生 stop 会等待读取/解码/渲染线程退出，
      // 当读取线程卡在饿死状态（缓冲失效期的高发态，如 seek 后 reader 不预取、
      // 网络阻塞读）时，原生销毁永不返回，上面的 try/catch 拦不住「不返回」，
      // 退出流程就永远停在这里 → 退出卡死。超时后放弃等待，保证 UI 退出不被
      // 拖死；代价是该极端情况下可能残留一个原生播放器实例（可接受的权衡）。
      await controller.dispose().timeout(
        const Duration(milliseconds: 2000),
        onTimeout: () {
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            'dispose: ⚠️ controller.dispose() 超时 2s，放弃等待原生销毁（可能残留一个原生播放器）',
          );
        },
      );
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: 完成');
    } catch (e) {
      // 初始化失败时底层 playerId 可能不存在，dispose 会抛 IllegalStateException，
      // 忽略该异常避免影响下一次播放。
      debugPrint('VideoPlayerBackendImpl dispose 忽略异常: $e');
      WindowsLogger.log('VideoPlayerBackendImpl', 'dispose: 异常 $e');
    }
  }
}
