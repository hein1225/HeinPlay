import 'dart:async';

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import '../../platform/device_utils.dart';
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

  /// 🔴 提前常驻挂载的视频层缓存（见 [VideoPlayerBackend.requiresEagerMount]）。
  ///
  /// mpv 的原生实例随 PlatformView 创建，而 `open()` 要等该 view 的 id。
  /// 缓存同一个 widget 实例有双重作用：
  ///  1. 保证 build 一旦跑过就持续挂载，`open()` 不会等到超时；
  ///  2. 避免 setState 触发 PlatformView 重建（重建会销毁 mpv 实例、画面中断）。
  Widget? _videoLayer;

  /// mpv 画面所在的 Flutter 外部纹理 id（原生经事件通道首条消息回传）。
  ///
  /// 🔴 纹理路线下**画面只能靠它出**：原生给的 PlatformView 只是零尺寸锚点。
  ///    为 null 时说明原生还没把纹理注册结果推回来，此时保持黑场即可。
  int? _mpvTextureId;

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
  static const Duration _kDesktopReadyDelay = Duration(milliseconds: 900);

  /// 桌面端"等待画面上屏"的定时器，见 [_scheduleDesktopReady]。
  Timer? _desktopReadyTimer;

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
  /// 该信号用于撤掉加载圈与错误提示；是否算“画面已就绪”按平台区分：
  /// Android/TV 走 platformView，底层开始播放时画面已可见，保持立即就绪；
  /// 桌面端（Windows/Linux）走 texture，需要再等纹理出帧（见 [_scheduleDesktopReady]）。
  void _onPlaybackSignal() {
    if (mounted && (_initializing || _error != null)) {
      setState(() {
        _initializing = false;
        _error = null;
      });
    }
    if (!DeviceUtils.isDesktop) {
      _notifyReady();
      return;
    }
    _scheduleDesktopReady();
  }

  /// 桌面端延后就绪回调，等视频纹理确实产出首帧后再通知上层。
  ///
  /// 少这一步时，无缝换台会在底层刚 `play()` 就撤掉旧画面，而新画面还要过几秒
  /// 才从纹理里出来 —— 表现为“有声音但黑屏”。
  void _scheduleDesktopReady() {
    if (!DeviceUtils.isDesktop || _readyNotified) return;
    _desktopReadyTimer?.cancel();
    _desktopReadyTimer = Timer(_kDesktopReadyDelay, () {
      _desktopReadyTimer = null;
      WindowsLogger.log(
        'LivePlayer',
        '桌面端等待画面出帧 ${_kDesktopReadyDelay.inMilliseconds}ms 后通知就绪',
      );
      // 🔴🔴 2026-10-21 修复「直播一直转圈」：
      //    此前这里只调 _notifyReady()，而**转圈遮罩由 _initializing 控制**，
      //    两者是两条互不相干的路径。桌面端 mpv 后端（MpvDesktopBackend）
      //    的 playingStream 只在壳侧上报 mpv 事件时才有值；直播流（尤其
      //    smil/RTSP 转封装）常常迟迟不推 playing 事件 → _onPlaybackSignal
      //    永不触发 → _initializing 永远为 true → 遮罩一直转圈。
      //    78 日志实证：13:20:27 open 成功、13:20:28 起「渲染帧 #181→#541」
      //    持续出帧、13:20:36「populate share_ok=yes」，画面**已经在播**，
      //    但 13:20:27 的「等待画面出帧 900ms 后通知就绪」只通知了上层，
      //    本页遮罩纹丝不动 —— 用户看到的就是一直转圈。
      //    修法：兜底到期即视为画面已就绪，同时撤掉加载遮罩。
      if (mounted && _initializing) {
        setState(() => _initializing = false);
      }
      _notifyReady();
    });
  }

  /// 取消桌面端延后计时（换 URL / 销毁时调用）。
  void _cancelDesktopReady() {
    _desktopReadyTimer?.cancel();
    _desktopReadyTimer = null;
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
    // 🔴 换后端必须丢弃旧的视频层缓存，否则会继续渲染已被 dispose 的
    //    上一个后端 widget，画面永远出不来。
    _videoLayer = null;
    _mpvTextureId = null;
    backend.fit = BoxFit.contain;
    // 🔴 mpv 画面走 Flutter 外部纹理：原生只给零尺寸锚点，
    //    真正出画要靠这里拿到 textureId 后叠加 `Texture(textureId)`。
    // 🔴🔴 2026-10-21 桌面直播「一直加载」根因：此处原先只判断
    //    `backend is MpvBackend`，但桌面 Linux/Windows 走的是
    //    **MpvDesktopBackend**（与 MpvBackend 无继承关系，都只
    //    implements VideoPlayerBackend）→ 判断恒为假 → textureId 永不监听
    //    → `_mpvTextureId` 恒 null → `Texture(textureId:)` 永不构建
    //    → 壳侧 populate 0 次 → 直播一直停在加载态。
    //    修法：按能力判断，两个 mpv 后端都覆盖。
    // 🔴🔴 2026-10-22：改为**纯 duck-typing**，不再用 `is` 判断具体类型。
    //    windows/player_screen.dart 有实证：`is` 在 AOT release 下可能不命中
    //    （78 真机日志里整段点播从未打印「收到 mpv textureId」）。
    //    这里原来靠 `is MpvBackend / is MpvDesktopBackend` 两个分支，
    //    目前虽然生效，但同类隐患必须一并消除：只认「暴露了
    //    textureReadyStream 这个能力」。
    Stream<int>? texStream;
    try {
      final dynamic dyn = backend;
      final Object? s = dyn.textureReadyStream;
      if (s is Stream<int>) texStream = s;
    } catch (_) {
      texStream = null;
    }
    if (texStream != null) {
      _subscriptions.add(
        texStream.listen((tid) {
          if (!mounted) return;
          debugPrint('直播页收到 mpv textureId=$tid，重建视频层出画');
          setState(() => _mpvTextureId = tid);
        }),
      );
    }
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
      );
    // 🔴 mpv 这类后端要等 PlatformView 创建（`_onViewCreated` 拿到 viewId）
    //    才能下发命令。`_initBackend` 在 initState 里同步调用时 build 尚未
    //    跑过，直接 open() 会白等满 MpvBackend 的 5 秒轮询后抛「等待
    //    AndroidView view 创建超时」。这里先让出一帧（并触发一次 setState
    //    把视频层挂上），确保 view 有创建机会。
    if (backend.requiresEagerMount) {
      if (mounted) setState(() {});
      await WidgetsBinding.instance.endOfFrame;
    }
    await _openUrl(widget.url);
  }

  Future<void> _openUrl(String url) async {
    if (_backend == null || url.isEmpty) return;

    _readyNotified = false;
    _cancelDesktopReady();
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
    _cancelDesktopReady();
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
      //   再打「pause 完成」，自相矛盾，误导排障（真机日志里确实如此）。
      //
      //   ⚠️ 只调整日志分支，**不改动调用顺序与任何时序参数**
      //      （pause 仍先于下方 500ms 延迟销毁），故桌面端行为完全不变。
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
    return Container(
      color: Colors.black,
      // 🔴🔴 2026-10-21 直播/点播画面比例失真根因（与 Android 对齐）：
      //    壳的 FBO 原先按 video-out-params（视频自身尺寸）创建，mpv 输出
      //    就没有黑边、恰是视频原始比例；Flutter 再拉伸铺满竖屏 → 压扁，
      //    且 keepaspect/panscan 在 mpv 内部完全失效。
      //    用 LayoutBuilder 把视频层控件尺寸上报给壳，壳据此建 FBO，
      //    mpv 才会在控件范围内按 video-params 做 letterbox。
      child: LayoutBuilder(
        builder: (context, constraints) {
          _reportViewSize(constraints);
          return Stack(
            fit: StackFit.expand,
            children: [
              // 🔴 视频层全程复用同一实例：既保证常驻挂载（`open()` 要等
              //    PlatformView 创建，见 requiresEagerMount），又避免 setState
              //    导致 PlatformView 重建、mpv 实例被销毁而画面中断。
              // ⚠️ 该实例**只能出现在 Stack 里一次**。此前误将 `_videoLayer!`
              //    同时放在纹理层前后两处，同一个 Widget 实例在 children 中出现两次，
              //    Flutter 的 element 匹配（Widget.canUpdate）随即错乱 →
              //    平台视图被反复创建销毁（实测 23ms 内连出 viewId 3/4/5、textureId 4/6/8），
              //    旧 view 先被 dispose、open() 的 await 回来时打到已销毁实例上 →
              //    直播报 `PlatformException(DISPOSED, mpv view disposed)` 且永远播不了。
              if (_backend != null) _videoLayer ??= _backend!.buildVideoWidget(),
              // 🔴 mpv 画面走 Flutter 外部纹理，必须叠在锚点之上才可见。
              //    裸 Texture 铺满，比例由 mpv 依据 video-params 与
              //    keepaspect/panscan 自行计算（同点播页修复，见 mobile/player_screen.dart
              //    中关于「写死 1920x1080 的 FittedBox 导致双重错误缩放」的说明）。
              if (_mpvTextureId != null) Texture(textureId: _mpvTextureId!),
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
          );
        },
      ),
    );
  }

  /// 上一次上报的视频层物理像素尺寸（避免每帧重复下发）。
  int _reportedViewW = 0;
  int _reportedViewH = 0;

  /// 把视频层控件尺寸（物理像素）上报给桌面 mpv 壳，供其建 FBO。
  void _reportViewSize(BoxConstraints constraints) {
    final backend = _backend;
    if (backend == null) return;
    if (!constraints.hasBoundedWidth || !constraints.hasBoundedHeight) return;
    // 🔴🔴 2026-10-22：必须 duck-typing，**不能**写 `backend is! MpvDesktopBackend`。
    //    与 windows/player_screen.dart 同一血泪教训：`is` 判断在 AOT release
    //    下没有命中（那边有 78 真机日志实证）。用 `is!` 早退 → setViewSize
    //    永远不下发 → 壳侧 view_w 恒为 0 → 纹理尺寸在「视频尺寸」与
    //    「控件尺寸」间每帧互相重建 → 共享句柄每帧被换掉 → 引擎采样空纹理
    //    → 黑屏且不报错。只认「暴露了 updateViewSize 这个能力」。
    final dynamic dyn = backend;
    void Function(int, int)? update;
    try {
      final Object? fn = dyn.updateViewSize;
      if (fn is void Function(int, int)) update = fn;
    } catch (_) {
      update = null;
    }
    if (update == null) return;
    final dpr = MediaQuery.of(context).devicePixelRatio;
    final w = (constraints.maxWidth * dpr).round();
    final h = (constraints.maxHeight * dpr).round();
    if (w <= 0 || h <= 0) return;
    if (w == _reportedViewW && h == _reportedViewH) return;
    _reportedViewW = w;
    _reportedViewH = h;
    debugPrint('[MPV-DIAG] 直播视频层尺寸上报 ${w}x$h');
    update(w, h);
  }
}
