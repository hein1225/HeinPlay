import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import '../services/user_data_service.dart';
import '../utils/app_logger.dart';
import '../utils/windows_logger.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart'; // 复用 stripInternalRequestHeaders

/// mpv 后端（Windows / Linux 桌面，基于官方 libmpv + 自写 C++ 壳）。
///
/// 与 Android 的 [MpvBackend] 同源同责，差别只在原生侧载体：
///   Android   → Kotlin PlatformView + JNI（MpvPlayerView.kt）
///   桌面       → C++ 壳（src/mpv_desktop/hein_mpv_core.c）
///                · Linux  : fl_method_channel + fl_texture_registrar（GL 外部纹理）
///                · Windows: MethodChannel + FlutterDesktopTextureRegistrar
///                · 内核   : libmpv.so / libmpv-2.dll（官方构建）
///
/// 【为什么桌面端原来选 mpv 会「走空」】
///   桌面默认后端历史上就是 mpv（见 UserDataService._platformDefaultBackend），
///   但 Android 版 MpvBackend 走的是 MethodChannel `hain_tv/mpv` +
///   PlatformView `heinplay_mpv`，桌面 runner 从未注册这两个东西，
///   于是桌面端一旦选中 mpv：无纹理、无控制、无事件。
///   本类就是补上桌面侧载体，让「全平台统一 mpv」真正落地。
///
/// 【渲染路线】
///   桌面与 Android 一样走**外部纹理**：原生把 mpv 画面渲染进自建 FBO，
///   再把该 GL 纹理注册进 Flutter 纹理注册器；Dart 侧用 `Texture(textureId)`
///   出画。`buildVideoWidget()` 只产出一个零尺寸占位（挂载锚点），不出画。
///
/// 【移植自 Android 的教训】
///   ① 起播定位：open 时把 startAt 以 mpv `start=` 选项传入（加载时即定位），
///      原生同时在 file-loaded 事件里补一次立即 seek 双保险。
///   ② 位置/时长流不加节流（Android 的 onMpvEvent 有 10% 节流，会制造稀疏假象）。
///   ③ 缓冲量取 mpv 的 `demuxer-cache-time`（物理缓存末端，与 Android 双判据一致）。
///   ④ 续播/PTS 归一化/三态探测/并发预载全部在 Dart 侧
///      （local_m3u8_proxy + ad_filter_engine），跨平台共用，本类不重复实现。
class MpvDesktopBackend implements VideoPlayerBackend {
  // Linux 与 Windows 共用同一通道名（壳两侧同名，便于 Dart 侧不区分平台）。
  static const String _channelName = 'hain_tv/mpv_desktop';
  static const String _eventChannelName = 'hain_tv/mpv_desktop_events';

  final MethodChannel _channel = const MethodChannel(_channelName);

  int? _textureId;

  /// 最后一次**推给 [textureReadyStream]** 的纹理 id（幂等去重用）。
  ///
  /// 🔴🔴 2026-10-23 Linux 闪屏根因（78 真机日志实锤）：
  ///   同一个 textureId 会被推送**两次**——
  ///     ① 原生事件通道的 'textureId' 回调（见 [_onEvent]）；
  ///     ② [initMpv] 拿到 init 返回值后的那次推送。
  ///   直播页（`lib/widgets/live/live_player.dart`）在 init **之前**就订阅了流
  ///   → 两次都收到 → `setState` 重建视频层两次 → **画面闪一下**。
  ///   点播页（`lib/screens/tv|windows/player_screen.dart`）在 init **之后**才订阅
  ///   → 只收到 1 次 → 正常。这就是"只有 Linux 直播闪屏"的原因。
  ///   本字段只存在于桌面后端（Linux/Windows），手机/鸿蒙走 Android 的
  ///   `MpvBackend`，不受影响。
  int? _lastPublishedTextureId;

  final _textureReadyController = StreamController<int>.broadcast();

  bool get textureReady => _textureId != null && _textureId! >= 0;
  int? get textureId => _textureId;

  /// 订阅后立即拉取当前 textureId：init 可能早于监听建立，
  /// 那种情况下流里的那一次事件已经丢了，只能靠主动读取兜底。
  int? get currentTextureId => _textureId;
  Stream<int> get textureReadyStream => _textureReadyController.stream;

  // ---- 状态流（无节流）----
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();

  /// 注销共享事件订阅的回调（见 _registerEventListener）。
  void Function()? _releaseEventListener;
  bool _disposed = false;
  bool _firstFrameEmitted = false;
  bool _completedReported = false;

  // 🔴🔴 2026-10-22 直播回放无法播放根因（mpv 侧，VLC 正常）：
  //
  //   壳里的 mpv 是**进程级全局单例**（g_mpv），而 Dart 侧每个
  //   MpvDesktopBackend 实例都会调 `init` / `dispose` 这一对通道方法。
  //   LivePlayer.dispose() 为了规避 FVP 纹理竞态，**延迟 500ms** 才真正
  //   dispose 后端（见 live_player.dart 的延迟销毁）。于是进回放时：
  //
  //     ① 旧 LivePlayer dispose → 排入 500ms 延迟销毁
  //     ② 新 LivePlayer init → 壳 initialized 仍为 1，直接复用同一 mpv，
  //        并 open 回放 URL（START_FILE 已收到）
  //     ③ 500ms 到点，旧实例的延迟回调执行 backend.dispose()
  //        → invokeMethod('dispose') → hein_mpv_shutdown()
  //        → **把新实例正在用的那个全局 mpv 关掉**
  //
  //   实测日志（12:55:39.521 init(initialized=1) → 39.523 open 回放
  //   → 39.530 START_FILE → 40.018 渲染线程退出 → 40.179 mpv 已完全关闭）
  //   正是这条链。VLC 不受影响是因为它不用这个全局单例。
  //
  //   修法：给壳的归属加「代际」——每次 init 成功领一个递增代际号，
  //   只有当前最新代际的实例才有权关壳。旧实例的延迟 dispose 发现
  //   自己已被取代，就只清理自己的 Dart 侧资源，绝不下发 dispose。
  static int _engineGeneration = 0;
  int _myGeneration = -1;

  /// 自己是否仍是壳的当前持有者。从未 init 过（-1）也算「不是」。
  bool get _ownsEngine => _myGeneration >= 0 && _myGeneration == _engineGeneration;

  // ==========================================================================
  // 🔴🔴 2026-10-23 直播换台「卡住」根因之二：EventChannel 多实例互相踢下线
  //
  // 壳里的 mpv 与其 EventChannel 都是**进程级全局单例**。而
  // Flutter 的 EventChannel 在同一 channel 名上**只允许一个活跃的 Dart
  // stream 监听器**：后一个实例调用 receiveBroadcastStream().listen() 时，
  // 框架会先把前一个 stream 取消（触发其 onCancel → 原生 listening_--）。
  //
  // 无缝换台时新旧两个 MpvDesktopBackend 实例并存：
  //   ① 新实例构造 → listen → 框架踢掉旧实例的 stream → 旧实例的
  //      _eventSub 实际已失效，但旧实例的 onCancel 会让原生 listening_--
  //   ② 旧实例 500ms 后 dispose → _eventSub?.cancel()（已失效则空操作）
  //   ③ 结果：原生侧 listen 计数与实际订阅数不匹配，且旧实例的 stream
  //      被踢后不再接收事件 → 事件可能投递给已废弃的 sink → **新实例收不到
  //      任何 mpv 事件**（playing / texture / 帧），状态机永远停在「未就绪」
  //      → 用户看到「换台后卡住不动」
  //
  // 修法：EventChannel 订阅改为**进程级单例**，所有实例共享同一条事件流，
  // 再按订阅者列表分发。这样原生侧永远只有 1 次 listen / 1 次 cancel，
  // 计数精确，且旧实例销毁不影响新实例收事件。
  // ==========================================================================
  static final EventChannel _sharedEventChannel = const EventChannel(
    _eventChannelName,
  );
  static StreamSubscription<dynamic>? _sharedEventSub;
  static final List<void Function(dynamic)> _eventListeners = [];

  /// 注册事件回调。返回注销函数。
  ///
  /// 首个注册者会真正建立原生 EventChannel 订阅；后续注册者复用同一条流。
  static void Function() _registerEventListener(void Function(dynamic) onEvent) {
    _eventListeners.add(onEvent);
    if (_sharedEventSub == null) {
      _sharedEventSub = _sharedEventChannel.receiveBroadcastStream().listen(
        (dynamic payload) {
          // 复制一份再遍历：回调里可能注销自己（dispose 路径），边遍历边改会崩。
          final snapshot = List<void Function(dynamic)>.from(_eventListeners);
          for (final listener in snapshot) {
            try {
              listener(payload);
            } catch (e) {
              debugPrint('MpvDesktopBackend 事件回调异常: $e');
            }
          }
        },
      );
    }
    var released = false;
    return () {
      if (released) return;
      released = true;
      _eventListeners.remove(onEvent);
      // 没有任何监听者了才真正取消原生订阅（保证 listen/cancel 计数配平）。
      final sub = _sharedEventSub;
      if (_eventListeners.isEmpty && sub != null) {
        _sharedEventSub = null;
        unawaited(sub.cancel());
      }
    };
  }

  VoidCallback? _onUnrecoverableStall;
  BoxFit _fit = BoxFit.contain;

  MpvDesktopBackend() {
    // 🔴 2026-10-23：不再各自 listen 全局 EventChannel（多实例会互相踢下线，
    // 详见 _registerEventListener 的注释），改为共享单例订阅 + 回调分发。
    _releaseEventListener = _registerEventListener(_onEvent);
  }

  @override
  bool get requiresEagerMount => true;

  @override
  BoxFit get fit => _fit;

  // 🔴🔴 2026-10-21 点播画面比例失真根因：此处原为纯赋值
  //    `set fit(BoxFit value) => _fit = value;` —— **只存字段，从不下发**。
  //    壳侧也从未设置过 keepaspect/panscan，于是 mpv 用默认行为把画面
  //    拉伸铺满，16:9 片源在 1080x1920 竖屏掌机上被压扁。
  //    这正是「安卓版踩过的老坑」（整条缩放控制链路丢失）在桌面壳上的复刻。
  //    现按 Android MpvPlayerView 的 setFit 分支映射三态并真正下发。
  @override
  set fit(BoxFit value) {
    _fit = value;
    _pushFit(value);
  }

  /// 把 BoxFit 三态下发给壳：contain=原始比例 / cover=保持比例填满 / fill=拉伸。
  void _pushFit(BoxFit value) {
    if (_disposed) return;
    final name = switch (value) {
      BoxFit.cover => 'cover',
      BoxFit.fill => 'fill',
      _ => 'contain',
    };
    _channel.invokeMethod<int>('setFit', {'fit': name}).catchError((_) => 0);
  }

  @override
  void set onUnrecoverableStall(VoidCallback? cb) => _onUnrecoverableStall = cb;

  /// 上报视频层控件的**物理像素**尺寸。
  ///
  /// 🔴 为什么必须上报：壳的 FBO 若按 video-out-params（视频自身尺寸）创建，
  ///    mpv 渲染出来的画面就没有黑边、恰好是视频原始比例；Flutter 再把这块
  ///    纹理拉伸铺满竖屏 → 比例被压扁，且 keepaspect/panscan 完全失效。
  ///    让 FBO = 控件尺寸，mpv 才会在该尺寸内按 video-params 做 letterbox。
  ///    这与 Android 侧「mpv 渲染进全屏 Surface」等价。
  int _lastViewW = 0;
  int _lastViewH = 0;

  void updateViewSize(int width, int height) {
    if (_disposed) return;
    if (width <= 0 || height <= 0) return;
    if (width == _lastViewW && height == _lastViewH) return;
    _lastViewW = width;
    _lastViewH = height;
    _channel.invokeMethod<int>('setViewSize', {
      'width': width,
      'height': height,
    }).catchError((_) => 0);
  }

  @override
  Widget buildVideoWidget() => const SizedBox.shrink();

  // ---- 事件上行（教训②：无节流，避免稀疏假象）----
  void _onEvent(dynamic payload) {
    if (payload is! Map) return;
    final name = payload['name'] as String?;
    final value = payload['value'];
    switch (name) {
      case 'textureId':
        final tid = (value as num?)?.toInt();
        if (tid != null && tid >= 0) {
          _textureId = tid;
          // 幂等：同一个 id 只推一次，否则视频层会被重复重建 → 闪屏。
          if (_lastPublishedTextureId != tid) {
            _lastPublishedTextureId = tid;
            _textureReadyController.add(tid);
          }
        }
        break;
      case 'time-pos':
        if (value is num) {
          final ms = (value * 1000).round();
          _positionController.add(Duration(milliseconds: ms));
          if (!_firstFrameEmitted) _firstFrameEmitted = true;
          // 🔴 2026-10-27 诊断埋点（限流 2 秒一次）：属性事件链一旦断掉，
          //   症状只会表现为「进度条/时间全空」而画面照播，极难定位。
          //   这里定期打出 position/duration/buffered 三元组，
          //   日志里能直接看出「事件有没有到」「值域对不对」。
          _logPropDiag('pos', ms);
          // 播放完成判定：位置接近总长且仍在推进（桌面无 eof 事件时兜底）。
          final durMs = _lastDurationMs;
          if (durMs > 0 && ms >= durMs - 500) {
            if (!_completedReported) {
              _completedReported = true;
              _completedController.add(null);
            }
          }
        }
        break;
      case 'duration':
        if (value is num) {
          final ms = (value * 1000).round();
          _lastDurationMs = ms;
          _durationController.add(Duration(milliseconds: ms));
          _logPropDiag('dur', ms);
        }
        break;
      case 'demuxer-cache-end':
        // 🔴🔴 2026-10-27 Linux 端缓冲条：改用 `demuxer-cache-state` 的
        //   `cache-end` = demuxer 已缓冲到的**文件位置（秒）**，语义与进度条
        //   需要的「缓冲右端」完全一致。
        //
        //   为什么不能用 `demuxer-cache-time`：它是**已缓冲总时长**，
        //   随播放持续堆积（真机上可达数百秒），当作位置会把缓冲条撑到
        //   远超播放点的位置（截图：播放 46% 而缓冲条画到 65%）。
        //
        //   ⚠️ 仅 Linux 生效：Windows 的缓冲显示目前正常，行为保持不变。
        if (Platform.isLinux && value is num) {
          final ms = (value * 1000).round();
          if (ms > 0) {
            _lastBufferedMs = ms;
            _bufferedController.add(Duration(milliseconds: ms));
            _logPropDiag('buf', ms);
          }
        }
        break;
      case 'demuxer-cache-time':
        // ⚠️ 仅 Windows 沿用旧语义（已缓冲时长当位置）；Linux 走上面的
        //   `demuxer-cache-end`，这里对 Linux 不做任何处理。
        if (!Platform.isLinux && value is num) {
          _bufferedController.add(
            Duration(milliseconds: (value * 1000).round()),
          );
        }
        break;
      case 'paused':
        if (value is bool) _playingController.add(!value);
        break;
      case 'eof':
        if (!_completedReported) {
          _completedReported = true;
          _completedController.add(null);
        }
        break;
      case 'unrecoverable-stall':
        _onUnrecoverableStall?.call();
        break;
    }
  }

  int _lastDurationMs = 0;

  /// 🔴 2026-10-27 诊断埋点：最近一次收到的各属性值（ms）。
  int _lastPositionMs = 0;
  int _lastBufferedMs = 0;
  DateTime _lastPropDiagAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// 属性事件诊断日志（限流 2 秒一次，避免刷屏）。
  ///
  /// 用途：属性事件链（native → EventChannel → Dart）断掉时，故障只表现为
  /// 「进度条与时间全空」而画面照播，没有这行日志就只能靠猜。
  /// 输出形如：`[MPV-DIAG] 属性 pos=1339000 dur=2763000 buffered=1345000`
  void _logPropDiag(String tag, int ms) {
    if (tag == 'pos') _lastPositionMs = ms;
    final now = DateTime.now();
    if (now.difference(_lastPropDiagAt) <
        const Duration(milliseconds: 2000)) {
      return;
    }
    _lastPropDiagAt = now;
    debugPrint('[MPV-DIAG] 属性 $tag=$ms | pos=$_lastPositionMs '
        'dur=$_lastDurationMs buffered=$_lastBufferedMs');
  }


  // ---- 控制 ----
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
    if (_disposed) return;
    _firstFrameEmitted = false;
    _completedReported = false;
    _lastDurationMs = 0;

    // 初始化原生（幂等）：首次调用时创建 mpv 实例并注册纹理。
    final init = await _channel.invokeMapMethod<String, dynamic>('init');
    final tid = (init?['textureId'] as num?)?.toInt();
    // 领代际号：init 一旦成功，本实例即成为壳的当前持有者，
    // 先前实例（可能还在 500ms 延迟销毁队列里）随即失去关壳资格。
    if (init != null && init['ok'] == true) {
      _myGeneration = ++_engineGeneration;
    }
    // 🔴 诊断（2026-10-21）：点播页始终收不到 textureId，需实证 init 返回值
    //    与是否真的 add 到流。确认问题后应移除。
    debugPrint('[MPV-DIAG] init 返回=$init tid=$tid 已有_textureId=$_textureId '
        'hasListener=${_textureReadyController.hasListener}');
    // 🔴 2026-10-21：原先带 `_textureId == null` 条件，导致「首次 init 时
    //    监听器还没挂上 → 丢了这一次推送」，之后 _textureId 已有值 → 永远
    //    不再推送 → 点播页 `_mpvTextureId` 恒为 null → 视频层永不构建。
    // 🔴🔴 2026-10-23 闪屏修复：这次推送与上面「平台事件」推送的是**同一个 id**，
    //    早订阅者（直播页）会因此收到两次 → 视频层重建两次 → 闪屏。
    //    现在改为：**没推过这个 id**（首次）或**当前没有监听者**（后挂的点播页
    //    仍要靠这次推送拿到 id）时才推；已有监听者且该 id 推过 → 跳过。
    if (tid != null && tid >= 0) {
      _textureId = tid;
      final bool alreadyPushed = _lastPublishedTextureId == tid;
      final bool hasListener = _textureReadyController.hasListener;
      if (!alreadyPushed || !hasListener) {
        _lastPublishedTextureId = tid;
        _textureReadyController.add(tid);
        debugPrint('[MPV-DIAG] 已向 textureReadyStream 推入 tid=$tid');
      } else {
        debugPrint('[MPV-DIAG] 跳过重复推送 tid=$tid（同一纹理已推给在听者）');
      }
    } else {
      debugPrint('[MPV-DIAG] 未推送：tid=$tid _textureId=$_textureId');
      // 🔴🔴🔴 2026-10-26：init 失败（textureId=0）时**明确报出根因**。
      //
      // 【背景】2026-10-26 掌机游戏模式（gamescope）下完全无法播放，
      //   而桌面模式正常。真机日志只给出 `init 返回={ok:false, textureId:0}`
      //   与 native 侧「eglGetPlatformDisplayEXT 未取到 surface/device 平台」
      //   「eglMakeCurrent 失败 0x3002」，**看不出为什么**。
      //
      // 【根因】mpv 壳走纹理共享路线，用 `eglGetCurrentContext()` 取
      //   「当前线程 current 的 EGL 上下文」与 Flutter 共享。
      //   若 GTK 走了 X11 后端（GLX），`eglGetCurrentContext()` 就返回
      //   EGL_NO_CONTEXT ⇒ 共享失败（Mesa 不支持 GLX↔EGL 跨 API 共享）。
      //
      // ⚠️ 2026-10-27 实测（69 掌机游戏模式）：`XDG_SESSION_TYPE=x11`、
      //   `WAYLAND_DISPLAY` **不存在**、`XDG_CURRENT_DESKTOP=gamescope`、
      //   `GAMESCOPE_WAYLAND_DISPLAY=gamescope-0`。
      //   ⇒ 这两个变量都不能用来判断会话类型；GTK 实际走了哪个后端，
      //     以 native boot.log 的「diag: GDK display=」一行为准。
      if (init != null && init['ok'] != true) {
        AppLogger.log('MpvDesktopBackend',
            'init 失败（textureId=$tid）—— mpv 壳无法与 Flutter 共享 GL 纹理。'
            '具体后端与失败阶段请查 native 日志 hein_native.log 与 boot.log'
            '（boot.log 里 "diag: GDK display=" 一行给出 GDK 实际后端类型）。');
      }
    }

    // 🔴 纹理共享失败但 init 仍 ok 的情况：界面正常、视频黑。
    //   不再猜测会话类型（环境变量在 gamescope 下不可信：
    //   XDG_SESSION_TYPE 报 x11 而实际合成器是 Wayland），
    //   只如实记录 WAYLAND_DISPLAY 供比对，不据此下结论。
    if (Platform.isLinux && init != null && init['ok'] == true) {
      final wd = Platform.environment['WAYLAND_DISPLAY'];
      final st = Platform.environment['XDG_SESSION_TYPE'];
      AppLogger.log('MpvDesktopBackend',
          'GL 环境：WAYLAND_DISPLAY=${wd ?? "(null)"} '
          'XDG_SESSION_TYPE=${st ?? "(null)"} '
          '（仅供比对，后端真实类型见 boot.log 的 GDK display 一行）');
    }

    final hardwareDecoding = await UserDataService.getHardwareDecoding();
    final bufCfg = bufferConfig ?? await BufferProfileConfig.current();
    final cacheSecs = (bufCfg.exoMaxBufferMs / 1000).round();

    await _channel.invokeMapMethod<String, dynamic>('open', {
      'url': url,
      'startAtMs': startAt?.inMilliseconds ?? 0,
      'headers': stripInternalRequestHeaders(headers, force: true),
      'isLive': isLive,
      'hardwareDecoding': hardwareDecoding,
      'cacheSecs': cacheSecs,
    });
    // open 后补发一次比例：set fit 可能发生在 mpv 实例创建之前（首帧前），
    // 那时壳里 g_mpv.mpv 为 NULL，设置会被丢弃。
    _pushFit(_fit);
  }

  @override
  Future<void> play() async {
    // 🔴 2026-10-23：与 pause 一样做代际保护。
    //    旧实例（已被新实例取代）若再下发 play，会让新频道从头重播。
    if (!_ownsEngine) {
      WindowsLogger.log(
        'MpvDesktopBackend',
        'play 忽略（代际已被取代，避免重播新实例的流）',
      );
      return;
    }
    await _channel.invokeMethod<void>('play');
  }

  @override
  Future<void> pause() async {
    // 🔴🔴 2026-10-23 直播换台「卡住」根因（Windows 实测，server 日志实证）：
    //
    //   壳里的 mpv 是**进程级全局单例**（g_mpv），pause/play/seek 等命令
    //   都作用在它身上（hein_mpv_core.c: hein_mpv_pause → mpv_command(g_mpv,
    //   {"set","pause","yes"})）。无缝换台时新旧两个 MpvDesktopBackend 实例
    //   并存于同一个全局 mpv 上：
    //     ① 新实例 init（initialized=1，复用同一 mpv）→ open(新URL) → START_FILE
    //     ② 旧实例随后被 LivePlayer.dispose() 释放，其 dispose() 会先调
    //        backend.pause() —— 这一下把**新频道正在播的流也暂停了**
    //     ③ 旧实例的延迟 dispose 虽被代际保护跳过（不会关壳），但
    //        _eventSub?.cancel() 仍会取消**全局 EventChannel**，
    //        新实例从此收不到任何 mpv 事件 → 状态机永远停在「未就绪」
    //   实测（08:30:11 换台）：原生层 08:30:12.909 已出画，
    //   Dart 层同刻判 timeout 撤掉旧画面 → 用户看到「换台卡住」。
    //
    //   修法：pause/play 与 dispose 一样做**代际保护** ——
    //   只有仍是壳当前持有者（_ownsEngine）的实例才有权操作全局 mpv。
    //   已被取代的旧实例调用 pause 一律忽略。
    if (!_ownsEngine) {
      WindowsLogger.log(
        'MpvDesktopBackend',
        'pause 忽略（代际已被取代，避免暂停新实例的 mpv）',
      );
      return;
    }
    await _channel.invokeMethod<void>('pause');
  }

  @override
  Future<void> seek(Duration position) =>
      _channel.invokeMethod<void>('seek', {'positionMs': position.inMilliseconds});

  @override
  Future<void> setSpeed(double speed) =>
      _channel.invokeMethod<void>('setSpeed', {'rate': speed});

  @override
  Future<void> setVolume(double volume) {
    // 🔴🔴 2026-10-21 直播「有画面无声音」根因（两个直播源都复现）：
    //
    //    本接口的 volume 是**归一化值 0.0~1.0**（与 video_player / vlc
    //    后端一致），但 mpv 的 `volume` 属性是**百分比 0~100**。
    //    此前这里把 0.0~1.0 原样下发，于是：
    //      live_player.dart 传 1.0（正常播放）→ mpv volume=1 → **1% 音量**
    //      → 听感上完全没声音。
    //
    //    日志铁证（69 真机）：
    //      点播 音频: codec=aac ao=pulse mute=no vol=100  ← 未调 setVolume，默认 100
    //      直播 音频: codec=mp2 ao=pulse mute=no vol=1    ← 调了 setVolume(1.0)
    //    解码器、音频输出、声道全部正常，唯一异常就是 vol。
    //
    //    修法：这里做单位换算，0.0~1.0 → 0~100，与 mpv 对齐。
    //    注意 vlc 后端是 volume*100 后 clamp 到 0~200，语义一致。
    final double percent = volume.clamp(0.0, 1.0) * 100.0;
    return _channel.invokeMethod<void>('setVolume', {'volume': percent});
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

  /// 全局关闭 mpv 内核（供 App 退出时调用）。
  ///
  /// 页面级的 [dispose] 只释放 Dart 侧订阅；mpv 的 render context / EGL /
  /// 事件线程必须由壳侧 `dispose` 方法走完整 shutdown 才会释放。窗口关闭时
  /// 若不先做这一步，进程会因为渲染线程仍持有 EGL 而退不掉（关闭卡死）。
  /// 这里直接用一条独立 channel 调用，不依赖任何后端实例是否还存活。
  static Future<void> shutdownEngine() async {
    // 应用退出是真正的「无差别关壳」：直接把代际推到失效，
    // 让任何仍在延迟销毁队列里的实例都不会再重复下发 dispose。
    _engineGeneration++;
    try {
      const channel = MethodChannel('hain_tv/mpv_desktop');
      await channel.invokeMethod<void>('dispose');
    } catch (_) {
      // 已关闭 / 壳未加载都视为成功：目标是「尽力关掉」，失败不应阻止退出。
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // 🔴 只有「仍是壳的当前持有者」才允许下发 dispose 关掉全局 mpv。
    //    被后来者取代的旧实例（典型：LivePlayer 500ms 延迟销毁撞上
    //    回放/换台新建实例）若照旧下发，会把新实例正在播放的 mpv 关掉，
    //    表现为「回放点了没反应 / 直播换台后黑屏」。见 _engineGeneration 注释。
    if (_ownsEngine) {
      _engineGeneration++; // 让位：本实例不再持有壳
      _myGeneration = -1;
      try {
        await _channel.invokeMethod<void>('dispose');
      } catch (_) {}
    } else {
      WindowsLogger.log('MpvDesktopBackend',
          'dispose 跳过关壳（代际已被取代，避免关掉新实例的 mpv）');
    }
    // 🔴 2026-10-23：注销**共享**事件订阅（见 _registerEventListener）。
    //    旧写法是 await _eventSub?.cancel()，而 _eventSub 订阅的是全局
    //    EventChannel —— 旧实例销毁时会把新实例的事件通道一并取消，
    //    导致换台后新实例再也收不到 mpv 事件（用户看到「换台卡住」）。
    //    现在只有当**没有任何**监听者时才真正取消原生订阅。
    _releaseEventListener?.call();
    _releaseEventListener = null;
    await _positionController.close();
    await _durationController.close();
    await _bufferedController.close();
    await _playingController.close();
    await _completedController.close();
    await _textureReadyController.close();
  }
}
