import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import '../services/user_data_service.dart';
import '../services/local_m3u8_proxy.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart'; // 复用 stripInternalRequestHeaders

/// mpv 后端（Android，基于官方 mpv 内核 + 自写 Kotlin/JNI 壳）。
///
/// 与鸿蒙 mpv-arkts 同源：内核=官方 libmpv.so（mediacodec 硬解），壳=自写
/// Kotlin PlatformView 层 + libheinplay_mpv_jni.so（C JNI 直调 libmpv）。
/// 不依赖 media_kit / fvp。
///
/// **渲染路径：仅纹理（SurfaceProducer → Flutter 外部纹理）**。
///
/// 原生 `TextureRegistry.createSurfaceProducer()` 申请一块 Flutter 外部纹理，
/// mpv 把画面渲染到该纹理的 Surface，Dart 侧用 `Texture(textureId)` 显示。
/// 本后端的 `buildVideoWidget()` 只产出一个**零尺寸占位**（挂载锚点），不出画；
/// 真实画面由播放页读 [textureId] 后自行 `Texture(textureId: id)` 叠加显示。
///
/// ⚠️ 2026-10-15：**从 SurfaceView 路线改回纹理路线**（对齐 hain_tv_legacy /
/// 官方 mpv-android）。原 `SurfaceView` + `AndroidView` 直画 ANativeWindow 的
/// 方案在 Flutter 下无法出画，真机日志铁证：
///   · 强制 GL：`VO: [gpu-next] 1920x818` 已出，但
///     `h264_mediacodec: Both surface and native_window are NULL`；
///   · Vulkan：`● Video`/`● Audio` 已解出，却**没有 `VO:` 行**。
/// 详见 hain_tv_legacy/MpvPlayerView.kt 第 37-44 行的实测记录。
///
/// 续播语义：open 时把 startAt 透传给原生，由 mpv 的 start 选项在加载时即定位
/// （秒），从根本上规避 fvp 的「空 buffer 下 inCache 式丢 seek → 续播死循环」缺陷。
class MpvBackend implements VideoPlayerBackend {
  static const String _viewType = 'heinplay_mpv';
  static const String _controlChannel = 'hain_tv/mpv';

  final MethodChannel _control = const MethodChannel(_controlChannel);
  int? _viewId;

  /// Flutter 外部纹理 id（原生经事件通道首条消息回传）。
  /// 播放页读它构建 `Texture(textureId: id)` 出画。
  int? _textureId;
  final _textureReadyController = StreamController<int>.broadcast();

  /// 纹理是否就绪（textureId 已由原生回传）。
  bool get textureReady => _textureId != null && _textureId! >= 0;

  /// Flutter 纹理 id，供播放页 `Texture(textureId: id)` 显示。
  int? get textureId => _textureId;

  /// 纹理就绪流（首帧前供播放页构建 `Texture`）。
  Stream<int> get textureReadyStream => _textureReadyController.stream;

  /// 强制 OpenGL ES 开关的**预读快照**。
  ///
  /// 🔴 为什么必须预读：该开关要在 `buildVideoWidget()`（同步方法）里作为
  ///    `creationParams` 下发给原生，而原生在**构造期**就用它定渲染路线
  ///    （`applyRendererOptions` 必须早于 `mpv_initialize`）。
  ///    若等到 `open()` 才异步读取并下发，纹理 surface 早已就绪、路线早已定死，
  ///    开关必然无效 —— 这就是「打开强制 OpenGL 也无法播放」的根因。
  ///    故在构造时预读一次，并随视图创建一并注入。
  bool _forceOpenGlSnapshot = false;

  /// 由播放页在创建后端后立即调用，刷新强制 GL 开关快照。
  Future<void> refreshForceOpenGl() async {
    try {
      _forceOpenGlSnapshot = await UserDataService.getForceOpenGl();
    } catch (_) {
      _forceOpenGlSnapshot = false;
    }
  }

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();

  bool _firstFrameEmitted = false;
  bool _completedReported = false;
  BoxFit _fit = BoxFit.contain;

  StreamSubscription? _eventSub;
  bool _disposed = false;

  /// PlatformView 创建完成信号（`_viewId` 就绪）。
  /// 用事件驱动替代固定延时轮询，见 [open] 的说明。
  Completer<int>? _viewCreatedCompleter;

  /// 等待 view 创建的兜底超时。5 秒与调用方（player_screen 的
  /// `openTimeout`）默认值一致，避免内层比外层先抛。
  static const Duration _viewWaitTimeout = Duration(seconds: 5);

  /// 等待 PlatformView 就绪并返回其 viewId；超时返回 null。
  ///
  /// 优先走事件（`onPlatformViewCreated` 完成 Completer），
  /// 并用一个低频定时器兜底，防止回调因异常路径未触发。
  Future<int?> _waitForViewId() async {
    if (_viewId != null) return _viewId;
    final completer = _viewCreatedCompleter ??= Completer<int>();
    Timer? poll;
    if (_viewId == null) {
      poll = Timer.periodic(const Duration(milliseconds: 50), (t) {
        if (_viewId != null) {
          t.cancel();
          if (!completer.isCompleted) completer.complete(_viewId!);
        }
      });
    }
    try {
      return await completer.future.timeout(
        _viewWaitTimeout,
        onTimeout: () => throw TimeoutException('等待 PlatformView 创建超时'),
      );
    } on TimeoutException {
      debugPrint(
        'MpvBackend: 等待 PlatformView 创建超时（${_viewWaitTimeout.inSeconds}s），'
        'viewId 仍为 null。请确认视频层已提前挂载（requiresEagerMount）。',
      );
      return null;
    } finally {
      poll?.cancel();
    }
  }

  /// mpv 原生实例（PlatformView）随 Flutter build 视频层时才创建，
  /// 而 [open] 要等该 view 的 id 才能下发命令。
  /// 因此播放页必须**提前且常驻**挂载视频层，否则必然死锁：
  ///   open 等 view → view 等 buildVideoWidget 被调用
  ///     → 被 `_initialized` 拦住 → `_initialized` 又等 open 成功。
  @override
  bool get requiresEagerMount => true;

  @override
  BoxFit get fit => _fit;
  @override
  set fit(BoxFit value) {
    // 🔴 2026-10-15 点播画面左右拉伸的根因之一：此 setter 此前**只改本地字段、
    //    从不通知原生**（legacy 版会 _invoke('setFit', ...)），于是前端切换
    //    「原始比例 / 填充 / 拉伸」对 mpv 完全没有效果，mpv 始终按默认值渲染。
    //    现在同步下发到原生：contain→keepaspect=yes+panscan=0（默认），
    //    cover→keepaspect=yes+panscan=1.0，fill→keepaspect=no。
    if (_fit == value) return;
    _fit = value;
    if (_viewId == null || _disposed) return;
    _invoke('setFit', {'fit': value.name}).catchError((e) {
      debugPrint('MpvBackend setFit error: $e');
    });
  }

  @override
  void set onUnrecoverableStall(VoidCallback? cb) {
    // mpv 后端暂无自愈逻辑，留空满足契约。
  }

  @override
  Widget buildVideoWidget() {
    if (!Platform.isAndroid) {
      // mpv 安卓后端仅在 Android 平台有意义（PlatformView / 纹理限定）。
      return Container(color: Colors.black);
    }
    // 纹理路线：原生不提供 PlatformView 画面，这里只放一个零尺寸锚点，
    // 触发原生 create → createSurfaceProducer；真实画面由播放页的
    // `Texture(textureId)` 显示。
    //
    // 🔴 creationParams 必须带上 forceOpenGl：原生在**构造期**就据此定渲染
    //    路线（applyRendererOptions 必须早于 mpv_initialize），晚于此的任何
    //    下发都不会生效。
    return AndroidView(
      viewType: _viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: <String, dynamic>{
        'forceOpenGl': _forceOpenGlSnapshot,
      },
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onViewCreated,
    );
  }

  void _onViewCreated(int viewId) {
    _viewId = viewId;
    // 🔴 唤醒所有在 [open] 里等待 view 的调用方（事件驱动，见 _waitForViewId）。
    final completer = _viewCreatedCompleter;
    if (completer != null && !completer.isCompleted) {
      completer.complete(viewId);
    }
    if (_disposed) return;
    final events = EventChannel(
      'hain_tv/mpv_events_$viewId',
    ).receiveBroadcastStream();
    _eventSub = events.listen(
      _onNativeEvent,
      onError: (e) {
        debugPrint('MpvBackend event error: $e');
      },
    );
  }

  void _onNativeEvent(dynamic payload) {
    if (payload is! Map) return;
    final map = Map<String, dynamic>.from(payload);

    // 🔴 事件通道首条为纹理注册结果 {type:'texture', textureId}。
    //    播放页靠它构建 `Texture(textureId: id)` 出画；漏处理则永远黑屏。
    if (map['type'] == 'texture') {
      final tid = map['textureId'] as int?;
      debugPrint('[Mpv纹理] 收到 textureId=$tid（原持有=$_textureId）');
      if (tid != null && tid >= 0 && _textureId != tid) {
        _textureId = tid;
        if (!_textureReadyController.isClosed) {
          _textureReadyController.add(tid);
        }
      }
      return;
    }

    final positionSec = (map['positionSec'] as num?)?.toDouble() ?? 0;
    final durationSec = (map['durationSec'] as num?)?.toDouble() ?? 0;
    final playing = (map['playing'] as bool?) ?? false;
    final buffering = (map['buffering'] as bool?) ?? false;
    final eof = (map['eof'] as bool?) ?? false;

    _positionController.add(
      Duration(milliseconds: (positionSec * 1000).round()),
    );
    if (durationSec > 0) {
      _durationController.add(
        Duration(milliseconds: (durationSec * 1000).round()),
      );
    }
    _playingController.add(playing);
    final bufferSec = (map['buffer'] as num?)?.toDouble() ?? 0;
    _bufferedController.add(Duration(milliseconds: (bufferSec * 1000).round()));

    if (!_firstFrameEmitted && playing && !buffering) {
      _firstFrameEmitted = true;
    }
    if (eof && !_completedReported) {
      _completedReported = true;
      _completedController.add(null);
    }
    if (!eof) {
      _completedReported = false;
    }
  }

  Future<void> _invoke(String method, Map<String, dynamic> args) async {
    if (_viewId == null) {
      throw StateError('MpvBackend: view 尚未创建，无法调用 $method');
    }
    final callArgs = <String, dynamic>{'viewId': _viewId!, ...args};
    try {
      await _control.invokeMethod<void>(method, callArgs);
    } on PlatformException catch (e) {
      debugPrint('MpvBackend $method error: ${e.message}');
      rethrow;
    }
  }

  /// 与 [_invoke] 相同，但在 view 被销毁重建（`DISPOSED`）时**重试一次**。
  ///
  /// 🔴 2026-10-15 直播「永远播不了」根因之一：`buildVideoWidget()` 返回的
  ///    AndroidView 一旦被 Flutter 重建（例如同一 Widget 实例在 Stack 中
  ///    重复出现导致 element 匹配错乱），旧的原生 view 会被 dispose，
  ///    此时 `_viewId` 已被新 view 覆盖，而正在进行中的 `open()` 命令
  ///    会打到已销毁的旧 view 上 → `PlatformException(DISPOSED, mpv view disposed)`。
  ///    命令本身是幂等的（open 就是 loadfile），故此处对 DISPOSED 重试一次即可自愈。
  Future<void> _invokeResilient(String method, Map<String, dynamic> args) async {
    try {
      await _invoke(method, args);
    } on PlatformException catch (e) {
      if (e.code != 'DISPOSED') rethrow;
      final stale = _viewId;
      debugPrint('MpvBackend $method 命中已销毁 view(viewId=$stale)，等待新 view 后重试');
      // 必须等一个**不同于** stale 的新 viewId；否则 _waitForViewId 会立刻
      // 返回同一个已销毁的 id，重试仍旧失败。
      final fresh = await _waitForFreshViewId(stale);
      if (fresh == null) rethrow;
      await _invoke(method, args);
    }
  }

  /// 等待一个与 [stale] 不同的新 viewId（view 被重建时使用）。超时返回 null。
  Future<int?> _waitForFreshViewId(int? stale) async {
    final deadline = DateTime.now().add(_viewWaitTimeout);
    while (DateTime.now().isBefore(deadline)) {
      final current = _viewId;
      if (current != null && current != stale) return current;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    debugPrint('MpvBackend: 等待新 view 超时（旧 viewId=$stale）');
    return null;
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
    debugPrint('MpvBackend open: $url startAt=$startAt isLive=$isLive');
    _firstFrameEmitted = false;
    _completedReported = false;

    // 等待 PlatformView 创建（_viewId 在 onPlatformViewCreated 赋值）。
    //
    // 🔴 2026-10-14 重写：原实现是「await endOfFrame + 250×20ms 轮询」，
    //    有两个致命缺陷，真机实测点播必然失败：
    //    ① `endOfFrame` 在没有新帧待绘制时会一直挂起，与播放页的
    //       `_initialized` 门控叠加即死锁（view 因门控不挂载 → 无新帧 →
    //       endOfFrame 不返回 → open 卡住）。
    //    ② 纯 `Future.delayed` 轮询依赖主 isolate 调度；点播开播前
    //       主 isolate 正被 M3U8 分片解析/测速占满（实测 5 秒内 36 次
    //       同步解析），定时器回调根本轮不到执行，于是「明明 view 快建好了
    //       却判超时」——真机日志里 view 在抛错后 23ms 才创建。
    //    现改为**事件驱动**：`_viewCreatedCompleter` 在 onPlatformViewCreated
    //    里完成；轮询仅作兜底，且用 compute 让出事件循环而非固定延时。
    final viewId = await _waitForViewId();
    if (viewId == null) {
      throw StateError(
        'MpvBackend: 等待 AndroidView view 创建超时（${_viewWaitTimeout.inSeconds}s）。'
        '请确认 PlatformView 工厂 viewType=heinplay_mpv 已注册，'
        '且播放页对该后端启用了 requiresEagerMount 提前挂载。',
      );
    }
    // mpv 不解析 x-heinplay- 内部头，强制过滤避免泄漏到上游。
    // 硬件解码开关：设置页「硬件解码」关闭时下发 hwdec=no 走纯软解；
    // 开启时要求真硬解（原生按开关下发 hwdec-software-fallback=no，不静默回退）。
    // isLive 一并下发：直播无硬解开关，原生据此始终允许软解回退（避免硬解
    // 失败时 force_eof 导致只有声音没有画面）。
    final hardwareDecoding = await UserDataService.getHardwareDecoding();
    // 「强制 OpenGL ES」开关（默认 false）。渲染路线已由 `buildVideoWidget()`
    // 经 creationParams 注入并随视图创建生效（见 `_forceOpenGlSnapshot` 的说明），
    // 这里只刷新快照供下次重建视图使用，不再经 open 下发（下发为时已晚）。
    await refreshForceOpenGl();
    // 🔴🔴 2026-10-16 新增：把「缓冲模式」档位换算成秒数下发到 mpv。
    //
    //   此前 `bufferConfig` 形参**收了却从未使用**（全文件仅此一处声明），
    //   导致软件设置里的缓冲档位对 mpv 完全无效 —— 而 exo / fvp / VLC /
    //   鸿蒙 AVPlayer 四个后端都由该档位驱动，mpv 是唯一的例外。
    //
    //   取值依据 `exoMaxBufferMs`：它正是 `avpBufferMb` 的换算基线
    //   （`avpBufferMb = exoMaxBufferMs/1000 × scale`，官方换算 1 秒 ≈ 1MB），
    //   故 mpv 用同一字段换算成秒，四个档位的语义在各后端间保持一致：
    //     标准 30s / 增强 60s / 强力 120s / 低延迟 5s
    //   直播由原生侧固定为 5s（跟手优先），此处仍照常下发。
    //
    //   失败不回滚：mpv 未就绪时下发会被拒，重开即恢复，仅记日志。
    final bufCfg = bufferConfig ?? await BufferProfileConfig.current();
    final cacheSecs = (bufCfg.exoMaxBufferMs / 1000).round();
    // 🔴🔴 2026-10-29：起播定位**之前**先把代理的预热窗口推到落点。
    //
    //   【真机实锤（小米 12S Pro 2026-10-29 21:31）】
    //     21:31:29.744 open startAt=1450000ms
    //     21:31:31.156~33.893 plist0~3 串行下载（2.7s，建索引阻塞）
    //     21:31:34.054 plist315（落点段）才下载完（open 后 4.3s）
    //     21:31:36.005 首帧（open 后 6.3s）
    //   ⇒ 落点段 + 头部段全部串在回源 RTT 上。
    //   代理侧并发预热（4 路）可把这两批字节提前备好，播放器随后命中本地缓存。
    //
    //   startAt 为 0（从头播）时同样要预热：此时窗口 = 前若干段，
    //   正好覆盖 mpv 建索引要拉的头部段。
    try {
      LocalM3u8Proxy.currentInstance?.primePrefetchAt(startAt ?? Duration.zero);
    } catch (e) {
      debugPrint('MpvBackend: 起播预热失败（不影响播放）: $e');
    }
    await _invokeResilient('open', {
      'url': url,
      'startAtMs': startAt?.inMilliseconds ?? 0,
      'headers': stripInternalRequestHeaders(headers, force: true),
      'isLive': isLive,
      'hardwareDecoding': hardwareDecoding,
      'cacheSecs': cacheSecs,
    });

    // 🔴 open 之后重新下发当前缩放模式。原生 setFit 改的是 mpv 运行期属性
    //    （keepaspect/panscan），而每次 open 都可能是新实例或属性被重置，
    //    这里补发一次保证「切换集数后比例仍正确」。
    //    失败不影响播放，仅记日志。
    try {
      await _invoke('setFit', {'fit': _fit.name});
    } catch (e) {
      debugPrint('MpvBackend open 后下发 setFit 失败（不影响播放）: $e');
    }
  }

  @override
  Future<void> play() => _invokeResilient('play', {});

  @override
  Future<void> pause() => _invokeResilient('pause', {});

  @override
  Future<void> seek(Duration position) async {
    // 🔴 2026-10-29：seek **之前**把预热窗口推到新落点（与起播定位同一机制）。
    //   鸿蒙侧实测：不预热时 seek 落点要等 4.6s 才生效（现等 CDN 往返）。
    try {
      LocalM3u8Proxy.currentInstance?.primePrefetchAt(position);
    } catch (e) {
      debugPrint('MpvBackend: seek 预热失败（不影响播放）: $e');
    }
    await _invokeResilient(
      'seek',
      {'positionSec': position.inMilliseconds / 1000.0},
    );
  }

  @override
  Future<void> setSpeed(double speed) => _invoke('setSpeed', {'rate': speed});

  @override
  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume.clamp(0.0, 1.0)});

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
    _disposed = true;
    if (_viewId != null) {
      try {
        await _control.invokeMethod<void>('dispose', {'viewId': _viewId});
      } on PlatformException catch (_) {
        // 忽略原生侧已销毁的情况
      }
    }
    await _eventSub?.cancel();
    await _positionController.close();
    await _durationController.close();
    await _bufferedController.close();
    await _playingController.close();
    await _completedController.close();
    if (!_textureReadyController.isClosed) {
      await _textureReadyController.close();
    }
  }
}
