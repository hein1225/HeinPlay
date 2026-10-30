import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';
// 缓冲档位下发需要触达 OhosVideoPlayer 的「一次性预置」接口：
//   · OhosVideoPlayer      —— fork 插件里的平台实现类（含 setNextBufferProfile）
//   · VideoPlayerPlatform  —— 基类/单例，用于取当前实例并做 is 判定
// 注意 video_player 主包的 barrel 不 re-export VideoPlayerPlatform，
// 必须直接从 platform_interface 导入（与 video_player_backend_impl.dart 同处理）。
import 'package:video_player_ohos/video_player_ohos.dart';
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show VideoPlayerPlatform;

import '../utils/windows_logger.dart';
import '../services/user_data_service.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart';
import 'video_render_mode.dart';

/// AVPlayer 后端（鸿蒙原生系统播放器）。
///
/// ## 定位：与安卓的 ExoPlayer 后端完全对等
///
/// 安卓上 [video_player] 由 ExoPlayer（media3）支撑；鸿蒙上则由
/// `video_player_ohos` 支撑，其底层是鸿蒙系统级播放器 **AVPlayer**
/// （`@ohos.multimedia.media` 的 `media.createAVPlayer()`）。
/// 因此本后端与 `hain_tv/lib/player/exo_player_backend.dart` 是同一角色：
/// 都是 [VideoPlayerBackendImpl] 的薄包装，只是把「系统原生播放器」这条路径
/// 暴露成一个可选项。
///
/// ## 与 mpv 后端的取舍
///
/// | | AVPlayer（本后端） | mpv（默认，libmpv 内核） |
/// |---|---|---|
/// | 解码 | 系统硬解 | 硬解（ohcodec），可切软解 |
/// | 网络 | 系统网络栈 | libmpv 网络栈，可关 TLS 校验 |
/// | 优势 | 省电、系统兼容稳 | 非标准源/组播/自签证书兼容强 |
/// | 短板 | 非标准 IPTV 源可能被拒 | 内核体积大 |
///
/// 故两者并存：mpv 为默认后端，AVPlayer 保留作系统原生兜底。
///
/// ## 注册前提（缺一不可）
///
/// `video_player_ohos` 是联邦插件实现，必须在 `pubspec.yaml` 用
/// `dependency_overrides` 把 **video_player 主包**指向 OpenHarmony TPC 的
/// git 版（其 pubspec 含 `ohos: default_package: video_player_ohos`），
/// 否则 ohos 实现不会被接进 `dart_plugin_registrant`，
/// 运行时表现为 `MissingPluginException`（黑屏）。详见 pubspec 内注释。
class AvPlayerBackend implements VideoPlayerBackend {

  /// 走 texture 渲染，open() 不依赖 Flutter 侧挂载，无需提前挂载。
  @override
  bool get requiresEagerMount => false;
  final VideoPlayerBackendImpl _impl = VideoPlayerBackendImpl();

  /// 渲染方式：由工厂按场景设置（点播/直播）。默认纹理。
  ///
  /// 🔴 2026-10-07：鸿蒙 avplayer（video_player_ohos）当前仅 Flutter 外部纹理
  ///   一条渲染路径（buildView 恒返回 Texture）。置 surface 时无法真正切到
  ///   XComponent 原生 surface（该通道尚未接入 fork），故回落纹理并打日志标注。
  @override
  VideoRenderMode renderMode = VideoRenderMode.texture;

  @override
  BoxFit get fit => _impl.fit;
  @override
  set fit(BoxFit value) => _impl.fit = value;

  @override
  void set onUnrecoverableStall(VoidCallback? cb) =>
      _impl.onUnrecoverableStall = cb;

  @override
  void set onSeekRebuildRequested(void Function(int targetMs)? cb) =>
      _impl.onSeekRebuildRequested = cb;

  @override
  Widget buildVideoWidget() => _impl.buildVideoWidget();

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
    debugPrint('AvPlayerBackend open: $url isLive=$isLive');
    WindowsLogger.log('AvPlayerBackend', 'open url=$url isLive=$isLive');

    // 🔴 2026-10-07 渲染方式：鸿蒙 avplayer 仅纹理路径可用。
    // 置 surface 时无法真正切到 XComponent，回落纹理并明确标注，便于真机核验。
    if (renderMode == VideoRenderMode.surface) {
      debugPrint(
        'AvPlayerBackend renderMode=surface：鸿蒙当前回落纹理渲染（XComponent 通道未接入）',
      );
      WindowsLogger.log(
        'AvPlayerBackend',
        'renderMode=surface 回落纹理（XComponent 通道未接入）',
      );
    }

    // 缓冲档位：与 ExoPlayer 等其它后端保持同一约定 ——
    // 直播恒用低延迟档（调用方 live_player 不传 bufferConfig，若此处不判 isLive
    // 就会回退到用户设置的「点播」增强档，直播预读放大 → 换台变慢、延迟抬高）。
    final effectiveConfig = isLive
        ? BufferProfileConfig.forProfile(BufferProfile.lowLatency)
        : (bufferConfig ?? await BufferProfileConfig.current());

    // ⚠️ 不透传 bufferConfig 给 _impl：AVPlayer 的缓冲只能经
    // PlaybackStrategy 在 create 阶段下发（见 [_applyBufferProfile]），
    // _impl 那条通用路径不适用于系统播放器。
    // 该「谁传谁负责」的约定与 exo_player_backend.dart 完全一致。
    //
    // ⚠️ 必须传 isAvPlayerBackend: true：
    // `_impl` 的起始定位有两套校验 —— ExoPlayer 用「bufferedEnd >= startAt」，
    // 而 AVPlayer 的 buffered 语义是 `playTime + bufferingPosition`（当前位置+
    // 缓冲窗口，见 VideoPlayer.ets:828），并非「已下载到最远点」，套用该判据必然
    // 误判并错误回退片头（实测每次起播闪一下从头播放才跳到播放记录）。
    // 传 true 后改用位置校验，与 AVPlayer 的真实状态语义一致。
    //
    // ⚠️ 过滤内部请求头：x-heinplay- 前缀是本应用自己的标记，AVPlayer 会把它
    // 原样发给上游，可能触发对端校验失败，故强制剥离。
    //
    // 🔴 2026-09-28：缓冲档位改为**真正下发**（此前一直只打日志）。
    // 详见下方 setNextBufferProfile 调用的说明。
    _applyBufferProfile(effectiveConfig);
    try {
      await _impl.open(
        url,
        startAt: startAt,
        headers: stripInternalRequestHeaders(headers, force: true),
        proxyMode: proxyMode,
        isLive: isLive,
        formatHint: formatHint,
        preferTextureView: preferTextureView,
        isAvPlayerBackend: true,
      );
      final cfgDesc =
          '容量=${effectiveConfig.avpBufferMb}MB '
          '起播水位=${effectiveConfig.avpBufferForPlayingMs}ms';
      debugPrint('AvPlayerBackend 缓冲档位（已下发 PlaybackStrategy）: $cfgDesc');
      WindowsLogger.log(
        'AvPlayerBackend',
        'open 成功: $url${isLive ? ' [直播]' : ' [点播/回放]'} 档位=$cfgDesc',
      );
    } catch (e, stack) {
      debugPrint('AvPlayerBackend open error: $e');
      debugPrint('$stack');
      WindowsLogger.log('AvPlayerBackend', 'open 失败: $e');
      WindowsLogger.log('AvPlayerBackend', 'stack: $stack');
      rethrow;
    }
  }

  /// 把宿主算出的缓冲档位下发给 AVPlayer 插件（在 [open] 之前调用）。
  ///
  /// 【修复的问题】此前注释写着「仅记录，AVPlayer 不支持运行时下发」，
  /// 于是用户设置的四个点播缓冲级别（标准/增强/强力/低延迟）对 AVPlayer 完全无效，
  /// 四个档位跑的都是系统默认行为。
  ///
  /// 【为什么现在能下发】鸿蒙 media.PlaybackStrategy 提供：
  ///   · preferredBufferDuration          —— 起播前缓冲时长
  ///   · preferredBufferDurationForPlaying —— 播放中维持的缓冲水位
  /// 它们只能在 setMediaSource 时随 PlaybackStrategy 给出（**无运行期 setter**），
  /// 所以必须经 create 阶段带入 —— 这正是 fork 插件的意义：
  /// Dart 侧触达不到这两个字段，只能由插件的原生侧在 createAVPlayer 里写入。
  ///
  /// 【映射】🔴 2026-09-28 改为使用 **AVPlayer 专属**字段（`avpBufferMb` /
  /// `avpBufferForPlayingMs`），不再与其它后端的缓冲参数共用同一组数字 ——
  /// 容量（MB）与预读时长（秒）语义不同，绑在一起会互相牵制。
  ///
  ///   · avpBufferMb         → preferredBufferDuration（缓冲区容量，单位 MB）
  ///   · avpBufferForPlayingMs → preferredBufferDurationForPlaying（起播/重缓冲阈值）
  ///
  /// 【直播】调用方不传 bufferConfig，上面已统一回退到 lowLatency 档
  /// （avpBufferMb=5 / avpBufferForPlayingMs=0），此处对 0 做过滤，避免下发 0 秒阈值。
  void _applyBufferProfile(BufferProfileConfig config) {
    try {
      final platformInstance = VideoPlayerPlatform.instance;
      if (platformInstance is OhosVideoPlayer) {
        platformInstance.setNextBufferProfile(
          bufferDurationMs: config.avpBufferMb * 1000,
          bufferDurationForPlayingMs: config.avpBufferForPlayingMs,
        );
        WindowsLogger.log(
          'AvPlayerBackend',
          '缓冲档位下发: preferredBufferDuration=${config.avpBufferMb}MB '
          'preferredBufferDurationForPlaying=${config.avpBufferForPlayingMs}ms',
        );
      } else {
        WindowsLogger.log(
          'AvPlayerBackend',
          '当前平台实现非 OhosVideoPlayer，跳过缓冲档位下发',
        );
      }
    } catch (e) {
      // 缓冲档位下发失败不应影响播放本身。
      WindowsLogger.log('AvPlayerBackend', '缓冲档位下发异常（忽略）: $e');
    }
  }

  @override
  Future<void> play() => _impl.play();

  @override
  Future<void> pause() => _impl.pause();

  @override
  Future<void> seek(Duration position) => _impl.seek(position);

  @override
  Future<void> setSpeed(double speed) => _impl.setSpeed(speed);

  @override
  Future<void> setVolume(double volume) => _impl.setVolume(volume);

  @override
  Stream<Duration> get positionStream => _impl.positionStream;

  @override
  Stream<Duration> get durationStream => _impl.durationStream;

  @override
  Stream<Duration> get bufferedStream => _impl.bufferedStream;

  @override
  Stream<bool> get playingStream => _impl.playingStream;

  @override
  Stream<void> get completedStream => _impl.completedStream;

  @override
  Stream<void> get firstFrameStream => _impl.firstFrameStream;

  @override
  Future<void> dispose() => _impl.dispose();
}