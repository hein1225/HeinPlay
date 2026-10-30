import 'dart:async';
// Platform.isOhos：鸿蒙 fork 特有的平台判定，用于决定就绪前是否等待纹理出帧。
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../platform/device_utils.dart';
import '../../player/mpv_backend.dart';
import '../../player/player_backend_factory.dart';
import '../../player/video_player_backend.dart';
import '../../services/playback_activity.dart';
import '../../theme.dart';
import '../../utils/windows_logger.dart';
import '../common/tech_loading_indicator.dart';

/// 直播播放器控制器：用于在播放器外部对已挂载的播放器进行定位（回放流内 seek）。
class LivePlayerController {
  _LivePlayerState? _state;

  void _attach(_LivePlayerState state) => _state = state;
  void _detach(_LivePlayerState state) {
    if (_state == state) _state = null;
  }

  /// 是否已挂载到实际播放器。
  bool get isAttached => _state != null;

  /// 定位到指定位置（相对当前打开的流起点）。
  Future<void> seek(Duration position) => _state?._seek(position) ?? Future.value();

  /// 暂停播放（停止渲染），供退出播放前停止直播流推帧使用。
  Future<void> pause() => _state?._pause() ?? Future.value();

  /// 恢复播放。
  Future<void> play() => _state?._play() ?? Future.value();

  /// 直播播放器是否因进入后台而被关闭（需用户手动继续）。
  bool get isStopped => _state?._stopped ?? false;
}

/// 通用直播播放器组件。
///
/// 直播播放器独立于点播播放器，不继承点播源的去广告等设置。
/// 按当前平台直播默认后端初始化播放器，组件 dispose 时自动释放播放器资源。
class LivePlayer extends StatefulWidget {
  final String url;
  final VideoFormat? formatHint;
  final bool paused;
  final LivePlayerController? controller;

  /// 附加到播放请求的 HTTP 请求头（可包含内部特殊键如代理地址）。
  final Map<String, String>? headers;

  /// 是否静音。无缝换台时后台预载的频道以静音方式解码，
  /// 切换为主画面后再取消静音，避免两路声音同时输出。
  final bool muted;

  /// 首帧就绪回调（底层开始播放/拿到时长）。同一个 URL 只回调一次。
  final VoidCallback? onReady;

  /// 打开失败回调，供无缝换台在预载失败时立即放弃等待。
  final void Function(String message)? onFailed;

  /// 是否显示内置的加载圈/错误提示遮罩。
  /// 后台预载时置 false，避免预载中的提示层影响后续画面。
  final bool showOverlay;

  LivePlayer({
    super.key,
    required this.url,
    this.formatHint,
    this.paused = false,
    this.controller,
    this.headers,
    this.muted = false,
    this.onReady,
    this.onFailed,
    this.showOverlay = true,
  });

  @override
  State<LivePlayer> createState() => _LivePlayerState();
}

class _LivePlayerState extends State<LivePlayer> {
  VideoPlayerBackend? _backend;
  bool _initializing = true;
  String? _error;
  final List<StreamSubscription> _subscriptions = [];

  /// 全局播放活动会话 id（直播同样占用带宽），dispose 时释放。
  int? _playbackSessionId;

  /// 🔴 2026-10-06：mpv 后端（路线B）的 Flutter 纹理是否已就绪。
  ///   mpv 的 buildVideoWidget() 只返回透明挂载锚点，真实画面需在锚点之上
  ///   额外渲染 `Texture(textureId)`。此标志控制是否切到纹理渲染，
  ///   否则直播会「有声音、黑屏」。
  bool _mpvTextureReady = false;

  /// 是否因进入后台（最小化/待机）而关闭了播放。直播流无法暂停，后台时直接
  /// 释放播放器与视频纹理；回到前台后停留在“已停止”态，由用户手动继续播放，
  /// 避免自动重载在部分设备出现黑屏有声音的僵尸播放器。
  bool _stopped = false;

  /// 当前 URL 的就绪回调是否已触发，避免 playing/duration 流重复回调。
  bool _readyNotified = false;

  /// 桌面端（Windows/Linux）无缝换台的就绪延后时长。
  ///
  /// fvp 在桌面端走 texture 渲染，底层 `play()` 返回时视频纹理往往还没产出第一帧
  /// （Android 的 platformView 路径不存在该问题）。若此时就让上层撤掉旧画面，
  /// 会露出「声音已切、画面还是黑的」空档（Linux 电脑版实测换台黑屏数秒）。
  /// 因此桌面端在底层报告开始播放后再等这段时间，让纹理确实出帧后才通知就绪。
  static const Duration _kReadyFallbackDelay = Duration(milliseconds: 3000);

  /// 桌面端"等待画面上屏"的定时器，见 [_scheduleDesktopReady]。
  Timer? _readyTimer;

  @override
  void initState() {
    super.initState();
    widget.controller?._attach(this);
    // 直播流持续拉流，同样要占带宽：申请播放会话让后台测速让路。
    _playbackSessionId = PlaybackActivity.instance.openSession();
    PlaybackActivity.instance.reportPlaying(_playbackSessionId ?? -1, true);
    _initBackend();
  }

  @override
  void didUpdateWidget(covariant LivePlayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      oldWidget.controller?._detach(this);
      widget.controller?._attach(this);
    }
    if (oldWidget.url != widget.url || oldWidget.headers != widget.headers) {
      _openUrl(widget.url);
    } else if (oldWidget.paused != widget.paused && _backend != null) {
      if (widget.paused) {
        _backend!.pause();
      } else {
        _backend!.play();
      }
    }
    if (oldWidget.muted != widget.muted) {
      _applyVolume();
    }
  }

  /// 按 [LivePlayer.muted] 应用音量（静音 0，正常 1）。
  Future<void> _applyVolume() async {
    try {
      await _backend?.setVolume(widget.muted ? 0.0 : 1.0);
    } catch (_) {
      // 部分后端在未就绪时设置音量会抛错，忽略即可。
    }
  }

  /// 触发一次就绪回调（同一 URL 只触发一次）。
  void _notifyReady() {
    if (_readyNotified) return;
    _readyNotified = true;
    final callback = widget.onReady;
    if (callback == null) return;
    // 避免在 build/stream 回调栈内直接触发父级 setState。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) callback();
    });
  }

  /// 底层报告“已开始播放/拿到时长”。
  ///
  /// 该信号用于撤掉加载圈与错误提示；是否算“画面已就绪”按渲染方式区分：
  /// 走 platformView 的平台（Android/TV），底层开始播放时画面已可见，保持立即就绪；
  /// 走 texture 的平台（Windows/Linux/**HarmonyOS**），需要再等纹理出帧。
  /// 详见 [_scheduleDesktopReady]。
  void _onPlaybackSignal() {
    if (mounted && (_initializing || _error != null)) {
      setState(() {
        _initializing = false;
        _error = null;
      });
    }
    if (!_needsTextureReadyWait) {
      _notifyReady();
      return;
    }
    _scheduleDesktopReady();
  }

  /// 就绪前是否需要等待视频纹理真正出帧。
  ///
  /// 🔴 2026-09-28：鸿蒙（HarmonyOS）必须包含在内。
  /// 鸿蒙的 video_player_ohos 插件与桌面端一样走 `Texture` 渲染
  /// （见 VideoPlayer.ets 的 `flutterRenderer.registerTexture(textureId)`，
  ///  插件内**没有** XComponent / PlatformView 渲染路径），
  /// 因此「底层报告 playing」并不等于「画面已经可见」。
  /// 该走 platformView 分支时会表现为：无缝换台一撤旧画面就黑屏，
  /// 过一会儿纹理出帧才恢复正常 —— 用户感受即「换台卡一下」。
  bool get _needsTextureReadyWait => DeviceUtils.isDesktop || Platform.isOhos;

  /// 延后就绪回调，等视频纹理确实产出首帧后再通知上层。
  ///
  /// 少这一步时，无缝换台会在底层刚 `play()` 就撤掉旧画面，而新画面还要过几秒
  /// 才从纹理里出来 —— 表现为“有声音但黑屏”（鸿蒙上即“换台卡一下”）。
  ///
  /// 🔴 2026-09-28：改为「真帧优先 + 超时兜底」。
  ///   - 首选：订阅 [VideoPlayerBackend.firstFrameStream]，纹理出帧即放行（最快且准确）；
  ///   - 兜底：起播后 [_kReadyFallbackDelay] 内仍未出帧（个别源纹理迟迟不来、
  ///     或后端以空实现满足契约）就放行，避免永远停在旧画面上不切换。
  ///   原实现是固定延迟 [_kReadyFallbackDelay] 后无条件放行 —— 既可能等太久
  ///   （出帧早于它时画面白等），也可能等不够（出帧晚于它时仍然黑屏一下）。
  void _scheduleDesktopReady() {
    if (!_needsTextureReadyWait || _readyNotified) return;
    _readyTimer?.cancel();
    _readyTimer = Timer(_kReadyFallbackDelay, () {
      _readyTimer = null;
      WindowsLogger.log(
        'LivePlayer',
        '等待首帧超时 ${_kReadyFallbackDelay.inMilliseconds}ms，兜底通知就绪',
      );
      _notifyReady();
    });
  }

  /// 取消就绪兜底计时（换 URL / 销毁 / 已收到首帧时调用）。
  void _cancelReadyFallback() {
    _readyTimer?.cancel();
    _readyTimer = null;
  }

  /// 定位到指定位置（相对当前打开的流起点）。
  Future<void> _seek(Duration position) async {
    try {
      await _backend?.seek(position);
    } catch (_) {
      // 部分后端/流不支持定位时静默忽略。
    }
  }

  /// 暂停播放（停止渲染）。
  Future<void> _pause() async {
    try {
      await _backend?.pause();
    } catch (_) {
      // 初始化失败/已销毁时忽略。
    }
  }

  /// 恢复播放。
  Future<void> _play() async {
    try {
      await _backend?.play();
    } catch (_) {
      // 初始化失败/已销毁时忽略。
    }
  }

  Future<void> _initBackend() async {
    final backend = await PlayerBackendFactory.createForLive();
    _backend = backend;
    backend.fit = BoxFit.contain;
    _subscriptions
      ..add(
        backend.playingStream.listen((_) {
          // 直播流通常没有固定时长，只要底层开始播放即视为就绪。
          // 同时清除可能因 transient 异常（如 VLC controller 尚未 attach）
          // 而残留的播放失败提示，避免画面已正常播放却仍显示错误。
          _onPlaybackSignal();
        }),
      )
      ..add(
        backend.durationStream.listen((_) {
          _onPlaybackSignal();
        }),
      )
      // 🔴 真正的首帧信号：纹理出帧后才通知就绪。
      //    见 _needsTextureReadyWait —— 鸿蒙与桌面端都走 texture，
      //    「底层报 playing」不等于「画面可见」，必须等这里。
      ..add(
        backend.firstFrameStream.listen((_) {
          if (!_needsTextureReadyWait) return;
          _cancelReadyFallback();
          _notifyReady();
        }),
      );

    // 🔴 2026-10-06 修复「直播有声音黑屏」：
    //   mpv 后端在鸿蒙上走「Flutter 纹理」路线（路线B）——
    //   buildVideoWidget() 返回的 OhosView 只是**挂载锚点**（透明，仅用于触发
    //   原生 create→registerTexture 拿到 surfaceId），真实画面必须由调用方
    //   额外渲染 `Texture(textureId)` 才能显示。
    //
    //   点播页 player_screen.dart 实现了这层（_buildVideo 里按 textureReady
    //   叠加 Texture(textureId)），而本直播页此前**只挂了锚点**，
    //   于是 mpv 解码一切正常（日志可见 VO: [gpu-next] 1920x1080 ohcodec[nv12]）
    //   但画面上什么都没有 —— 正是「有声音、黑屏」。
    //
    //   textureId 由原生经事件通道首条消息回传，故订阅 textureReadyStream，
    //   就绪后 setState 让 build 切换到 Texture 渲染。
    if (backend is MpvBackend) {
      // `backend is MpvBackend` 已让类型收窄，无需再 as（否则 analyzer 报 unnecessary_cast）。
      final mpv = backend;
      _subscriptions.add(
        mpv.textureReadyStream.listen((_) {
          if (!mounted) return;
          setState(() {
            _mpvTextureReady = mpv.textureReady;
          });
        }),
      );
      // 订阅建立前可能已经就绪，这里补一次同步检查，避免错过首条事件。
      _mpvTextureReady = mpv.textureReady;
    }

    await _openUrl(widget.url);
  }

  Future<void> _openUrl(String url) async {
    if (_backend == null || url.isEmpty) return;

    _readyNotified = false;
    _cancelReadyFallback();
    setState(() {
      _initializing = true;
      _error = null;
    });

    try {
      await _backend!.open(
        url,
        isLive: true,
        formatHint: widget.formatHint,
        headers: widget.headers,
      );
      await _applyVolume();
      if (widget.paused) {
        await _backend!.pause();
      } else {
        await _backend!.play();
      }
      // 桌面端兜底：即使底层没有推送播放信号，也要在延时后放行就绪，
      // 否则无缝换台会一直停在旧画面上不切换。
      _scheduleDesktopReady();
    } catch (e, stackTrace) {
      debugPrint('LivePlayer 播放失败: $e');
      debugPrint('$stackTrace');
      WindowsLogger.log('LivePlayer', 'open/play 失败: $e');
      if (mounted) {
        setState(() {
          _error = '播放失败: $e';
          _initializing = false;
        });
      }
      final failed = widget.onFailed;
      if (failed != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) failed('$e');
        });
      }
    }
  }

  /// 后台关闭后由用户手动继续播放：恢复入口在 live_player_screen 通过卸载并
  /// 重挂 LivePlayer（全新实例）实现。卸载走 Flutter 正常的平台视图拆除流程，
  /// 由系统先释放 fvp 视频纹理与 SurfaceView，再延迟释放后端，规避“组件仍挂载时
  /// 手动 dispose 后端 → 原生 surface 回调打在已释放后端上 → SIGSEGV 闪退”的问题。

  @override
  void dispose() {
    WindowsLogger.log('LivePlayer', 'dispose 开始');
    _cancelReadyFallback();
    widget.controller?._detach(this);
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    // 释放播放会话：后台测速恢复全速
    final sessionId = _playbackSessionId;
    if (sessionId != null) {
      PlaybackActivity.instance.closeSession(sessionId);
      _playbackSessionId = null;
    }
    // 销毁播放器后端。
    //
    // 立即销毁时 VideoPlayer 纹理仍挂载于正在卸载的子树，Windows FVP 释放
    // 纹理时易与渲染线程竞态导致退出卡死/闪退。因此先立即暂停（停止渲染
    // 与声音），再延迟到 widget 树卸载完成后销毁，且不阻塞页面退出。
    final backend = _backend;
    _backend = null;
    if (backend != null) {
      // 🔴 2026-10-24：把 `catchError().then()` 改成 `then().catchError()`。
      //
      //   原写法的问题：catchError 的回调返回后 Future 仍以**成功**完成，
      //   于是后面的 then 照样执行 —— 暂停失败时日志会先打「pause 失败」
      //   再打「pause 完成」，自相矛盾，误导排障。
      //
      //   ⚠️ 只调整日志分支，**不改动调用顺序与任何时序参数**（pause 仍
      //      先于下方 500ms 延迟销毁），故桌面端行为完全不变。
      unawaited(
        backend.pause().then((_) {
          WindowsLogger.log('LivePlayer', 'pause 完成');
        }).catchError((Object e) {
          debugPrint('LivePlayer 退出暂停播放器失败: $e');
          WindowsLogger.log('LivePlayer', 'pause 失败: $e');
        }),
      );
      unawaited(
        Future<void>.delayed(Duration(milliseconds: 500), () async {
          WindowsLogger.log('LivePlayer', '开始延迟销毁');
          try {
            await backend.dispose();
            WindowsLogger.log('LivePlayer', '延迟销毁完成');
          } catch (e) {
            debugPrint('LivePlayer 延迟销毁播放器失败: $e');
            WindowsLogger.log('LivePlayer', '延迟销毁失败: $e');
          }
        }),
      );
    }
    super.dispose();
    WindowsLogger.log('LivePlayer', 'dispose 结束');
  }

  @override
  Widget build(BuildContext context) {
    // 🔴 2026-10-06 修复「直播有声音黑屏」：mpv 后端必须额外渲染 Flutter 纹理。
    //   见 _mpvTextureReady 的说明与 _initBackend 里的订阅。
    //   注意锚点（buildVideoWidget 的 OhosView）必须**始终留在树里**——
    //   它一旦被移除，原生侧的 create→registerTexture 就不再触发，
    //   surfaceId 也就没了。所以这里用 Stack 把锚点与纹理叠加共存：
    //   锚点透明（Opacity 0.0），纹理负责出画。
    final mpv = _backend is MpvBackend ? _backend as MpvBackend : null;
    final textureId = (mpv != null && _mpvTextureReady) ? mpv.textureId : null;

    return Container(
      color: Colors.black,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (_backend != null)
            mpv != null
                // mpv（路线B）：透明锚点常驻 + 纹理出画。
                ? Stack(
                    fit: StackFit.expand,
                    children: [
                      Opacity(opacity: 0.0, child: _backend!.buildVideoWidget()),
                      if (textureId != null)
                        Texture(textureId: textureId),
                    ],
                  )
                // 其他后端（video_player/fvp 等）自行渲染，直接铺满即可。
                : _backend!.buildVideoWidget(),
          if (_initializing && widget.showOverlay)
            Container(
              color: Colors.black54,
              child: Center(
                child: TechLoadingIndicator(),
              ),
            ),
          if (_error != null && widget.showOverlay)
            Container(
              color: Colors.black87,
              child: Center(
                child: Padding(
                  padding: EdgeInsets.all(AppSpacing.lg),
                  child: Text(
                    _error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: AppColors.error,
                      fontSize: 14,
                    ),
                  ),
                ),
              ),
            ),
          if (_stopped)
            Container(
              color: Colors.black87,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.play_circle_outline,
                      color: AppColors.primary,
                      size: 48,
                    ),
                    SizedBox(height: AppSpacing.md),
                    Text(
                      '已停止播放，点击屏幕继续',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Color(0xFFF0F0F5),
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
