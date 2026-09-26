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

  // —— 续播 seek 自愈（仅 fvp 需要；ExoPlayer seek 可靠，不走此路径）——
  // _fvpMode：后端是否为 fvp（由调用方显式传入 isFvpBackend 决定）。
  // 不再用「fvpVideoDecoders 是否为 null」判定 —— 真机默认硬解时 FvpBackend 传
  // fvpVideoDecoders=null（解码交 fvp 内置），但后端仍是 fvp；旧判定会把真机 fvp
  // 误算成 _fvpMode=false，导致续播重试/stall 自愈整段失效（2026-09-24 证伪）。
  //   故可用它可靠区分后端，避免给 ExoPlayer 加无谓的延迟重试。
  // _resumeTarget：本次 open 的续播目标位置。fvp 在部分源上 seekTo 仅设置时钟、
  //   读取线程未跳到目标段，且 value.position/value.buffered 会谎报为时钟值，导致
  //   「基于 bufferedEnd 的判定」失效 → 永久冻结（时钟在续播点、读取停在分段 0）。
  //   故在播放中检测到「playing 但 position 持续不推进且非网络缓冲等待」时，主动
  //   重试 seek；重试耗尽则回退从片头播放（远比永久冻结可接受）。
  // _stallRecoveries / _lastStallRecoverAt：限制自愈重试频率，避免正常网络缓冲抖动误触发。
  bool _fvpMode = false;
  Duration? _resumeTarget;
  int _stallRecoveries = 0;
  DateTime? _lastStallRecoverAt;
  static const int _maxStallRecoveries = 3;
  // onUnrecoverableStall：fvp 续播卡死且 App 层 seek 重试/回退片头均 no-op
  // （reader 真死）时上抛，由播放页重建为 ExoPlayer（保留续播点）。
  // 仅 _fvpMode=true 且回调已注册时触发。
  VoidCallback? onUnrecoverableStall;
  bool _unrecoverableSignaled = false;

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
    bool isFvpBackend = false,
    List<String>? fvpVideoDecoders,
  }) async {
    await dispose();
    _completedReported = false;
    // 重置诊断状态（仅日志用）
    _firstFrameReported = false;
    _lastStallPosition = Duration.zero;
    _lastStallCheck = DateTime.now();
    _lastProgressLog = DateTime.now();
    // 续播 seek 自愈状态重置（仅 fvp 后端启用；_fvpMode 由调用方显式传入的
    // isFvpBackend 决定，与解码器配置无关，确保真机硬解 fvp 也能触发续播自愈）
    _fvpMode = isFvpBackend;
    _resumeTarget = null;
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

      // ── 缓冲窗口下发（fvp 专有扩展 setBufferRange）★ 必须在 initialize() 之后 ──
      //
      // 🔴 2026-09-22 定稿根因：此前本段写在 initialize() **之前**，等于从未生效。
      // fvp 的 FVPControllerExtensions 开头就写明（controller.dart:29）：
      //   "All methods in this extension must be called after initialized,
      //    otherwise no effect."
      // 其 platform 层实现是 null-aware 调用（video_player_mdk.dart:486）：
      //   `_players[playerId]?.setBufferRange(min: min, max: max, drop: drop);`
      // initialize() 之前 player 尚未创建、playerId 无效 → `_players[playerId]` 为
      // null → **整句静默无操作，连异常都不抛**，故外层 try/catch 也拦不到、日志无痕。
      //
      // 后果（根因①，2026-09-22 上午修复）：libmdk 一直沿用创建时默认的
      // `setBufferRange(min: 0)`（max 保持 libmdk 默认，约 4 秒）——
      //   · 缓冲条永远只有一点点（实测 `value.buffered.last.end` 恒等于 position）；
      //   · 点播 2 秒/片且含大量 #EXT-X-DISCONTINUITY 的源网络稍慢即断流卡死；
      //   · 而 ExoPlayer 走 ExoPlayerBufferConfig（MethodChannel，无此时序问题），
      //     缓冲条一上来就明显 → "同一源 exo 快、fvp 慢"。
      // 候选原因②（2026-09-22 晚，**未证实**）：注册级 lowLatency=1 在 player 创建
      // 时写入 `avformat.fflags=+nobuffer`（首包关键帧被丢弃、reader 不预取）且 open
      // 后无法覆盖。已把 lowLatency 置 0，但 22:21 日志实测症状完全不变 —— 说明
      // nobuffer 不是充分原因，真正的「position 在 seek 目标附近冻结、buffered 恒等于
      // position」另有其因（见 seek/进度行里的 [FVP-DIAG] 埋点：bufN 可区分「fvp 从未
      // 上报缓冲事件」与「上报了但队列为 0」）。
      //
      // setBufferRange 是 libmdk 的**运行时**API（可在 prepare 后动态调整预读窗口），
      // 参考 fvp 自身用法（video_player_mdk.dart:320/322 在 player 级调用）。
      // 注意其语义：min=起播/重缓冲阈值，max=预读窗口上限。
      //
      // setBufferRange 仅 fvp 控制器有此扩展；VLC（Windows 特有）控制器无此扩展，
      // 调用被 try/catch 静默忽略；ExoPlayer（MethodChannel）不接收该调用。
      // 「缓冲模式」对 ExoPlayer / VLC 的放大仍各自生效。
      if (bufferConfig != null) {
        try {
          _controller!.setBufferRange(
            min: bufferConfig.fvpMinMs,
            max: bufferConfig.fvpMaxMs,
            drop: bufferConfig.fvpDrop,
          );
          WindowsLogger.log(
            'VideoPlayerBackendImpl',
            '缓冲窗口已下发（initialize 后）: '
                'min=${bufferConfig.fvpMinMs}ms max=${bufferConfig.fvpMaxMs}ms '
                'drop=${bufferConfig.fvpDrop}',
          );
        } catch (e) {
          debugPrint('VideoPlayerBackendImpl setBufferRange 失败(可忽略): $e');
        }
      }

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

      // 若指定了起始位置（播放记录续播 / 拖进度条），在 initialize() 完成后**立即**
      // seek，再开始播放 —— 即「播放记录第一时间读取」。
      //
      // 🔴 2026-09-22 修正：fvp 后端此前传 deferStartSeek: true，把定位推迟到
      // 「起播稳定后再 seek」，用户会先看到片头几十秒才跳走，观感上就是
      // 「fvp 定位不到播放记录、一播放直接播片头」。
      //
      // 当初认定「fvp 在 play() 之前 seek 会卡死」是**误判**：真因是 setBufferRange
      // 被写在 initialize() 之前而静默失效（见上方缓冲窗口处注释），seek 后需要重新
      // 缓冲却只有约 4 秒的预读窗口，于是表现为 position 冻结在 seek 目标、
      // `FVP_DECODE_STALL` 刷屏。缓冲窗口修好后，initialize() 之后直接 seek 安全，
      // 无需任何延迟。
      //
      // 此处之所以在 play() 之前 seek：让首帧就从目标位置产出，避免从 0 起播后
      // 再跳一下（ExoPlayer 同理）。
      if (startAt != null && startAt > Duration.zero) {
        _resumeTarget = startAt;
        if (isFvpBackend) {
          // fvp：initialize 之后立即定位到续播点。libmdk 在部分源上会「只设时钟、读取
          // 线程未跳段」，故做 3 次带抖动的延迟重试（抖动目标绕过 libmdk「已在目标位置」
          // 的 seek no-op，强制读取线程重跳）。仍失败则由运行时 stall 自愈 / 上抛重建兜底。
          // ⚠️ 不要改用 prepare(position:)：libmdk 会从第 0 片顺序下载到续播点，init 拖到
          // 16-32s 并超过 openTimeout（2026-09-24 已撞坑，见上方 initialize 前的回退注释）。
          for (var attempt = 0; attempt < 3; attempt++) {
            await Future.delayed(const Duration(milliseconds: 250));
            final target = attempt == 0
                ? startAt
                : startAt + Duration(milliseconds: 500 * attempt);
            await seek(target);
          }
        } else {
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
          if (_resumeTarget != null &&
              _fvpMode &&
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
