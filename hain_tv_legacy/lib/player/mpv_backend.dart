import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import '../services/user_data_service.dart';
import '../services/local_m3u8_proxy.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'playback_headers.dart'; // 复用 stripInternalRequestHeaders

/// mpv 后端（Android TV / tvLegacy，基于官方 mpv 内核 + 自写 Kotlin/JNI 壳）。
///
/// **本工程（tvLegacy）的 mpv 是「自编译壳 + 官方内核」路线**：内核为官方 mpv
/// 源码经本工程 `.mpv-android/` 交叉编译出的 `libmpv.so`（OpenGL 路线，
/// `vo=gpu` + `gpu-context=android`，`-Dvulkan=disabled` 以覆盖 Android 5.0/API 21）；
/// 壳为本工程自写的 Kotlin PlatformView + C JNI（`libheinplay_mpv_jni.so`）。
/// 不依赖 media_kit / fvp。
///
/// **渲染路线：仅纹理（TextureView）**。
/// - 原生 `TextureRegistry.createSurfaceProducer()` 申请一块 Flutter 外部纹理，
///   mpv 把画面渲染到该纹理的 Surface，Flutter 侧用 `Texture(textureId)` 显示。
///   旋转/resize 由纹理自动跟随，无需手动下发尺寸。
///
/// ⚠️ **本工程已移除「渲染方式」选择（2026-10-07）**：原 surface 路线
/// （原生 SurfaceView 出画）在安卓上**无法实现**，两条合成路径都是黑屏，
/// 已实测确认：
/// 1. `AndroidView` 路径：引擎硬编码 `VIEW_TYPES_REQUIRE_VIRTUAL_DISPLAY =
///    {SurfaceView}`（`ViewUtils.hasChildViewOfType` 递归判定，包进 ViewGroup 也
///    躲不开），强制走 **Virtual Display**，mpv 画到离屏虚拟屏 → 有声音无画面。
/// 2. `PlatformViewLink` + `AndroidViewSurface`（Hybrid Composition）路径：
///    logcat 中 `flutter-vd` / `Display device added` **已归零**（证明 Hybrid
///    确实生效），但 **仍然黑屏** —— Hybrid 通过 `ImageReader` 把平台视图「画」
///    成纹理，而 `SurfaceView` 的内容不走 `View.draw()`，捕获到的是空帧。
///
/// 唯一能让 SurfaceView 可见的办法是 `setZOrderMediaOverlay(true)` 把它浮到
/// Flutter 窗口表面**之上**，但那样它会永久盖住控制条、弹幕、字幕等全部
/// Flutter UI —— 与「Flutter 渲染 UI + 原生 surface 出画」这套架构根本冲突。
/// 因此安卓侧固定纹理路线；鸿蒙版的 surface（ArkUI `XComponent` 通路，
/// 原生节点参与 UI 树 z-order）不受影响，保持原样。
///
/// 续播语义：open 时把 startAt 透传给原生，由 mpv 的 `start` 选项在加载时即定位
/// （秒），从根本上规避 fvp 的「空 buffer 下 inCache 式丢 seek → 续播死循环」缺陷。
///
/// ⚠️ 本工程**不含**「HLS 并发分片预取」等吃性能的功能（那是鸿蒙版专有，后续只
/// 移植到主工程 hain_tv/）；本后端只做基础播放能力。
class MpvBackend implements VideoPlayerBackend {
  static const String _viewType = 'heinplay_mpv';
  static const String _controlChannel = 'hain_tv/mpv';

  final MethodChannel _control = const MethodChannel(_controlChannel);
  int? _viewId;

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _firstFrameController = StreamController<void>.broadcast();

  bool _firstFrameEmitted = false;
  bool _completedReported = false;
  BoxFit _fit = BoxFit.contain;

  /// 纹理路线下的 Flutter 外部纹理 id，由原生注册后经事件通道回传。
  int? _textureId;
  final _textureReadyController = StreamController<int>.broadcast();

  StreamSubscription? _eventSub;
  bool _disposed = false;

  /// mpv 原生实例随 PlatformView 创建，播放页需提前挂载视频层，
  /// 否则「等待 view 创建」会与续播定位闸门互相死锁。
  @override
  bool get requiresEagerMount => true;

  @override
  BoxFit get fit => _fit;
  @override
  set fit(BoxFit value) {
    if (_fit == value) return;
    _fit = value;
    // 映射为 mpv 的 video-aspect-override + panscan，实时改变显示比例。
    if (_viewId != null) {
      _invoke('setFit', {'fit': value.name}).catchError((e) {
        debugPrint('MpvBackend setFit error: $e');
      });
    }
  }

  /// 纹理是否就绪（textureId 已由原生回传）。
  bool get textureReady => _textureId != null && _textureId! >= 0;

  /// Flutter 纹理 id，供播放页 `Texture(textureId)` 显示。
  int? get textureId => _textureId;

  /// 纹理就绪流（首帧前供播放页构建 `Texture`）。
  Stream<int> get textureReadyStream => _textureReadyController.stream;

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
    // 触发原生 create → registerTexture；真实画面由播放页的 Texture 显示。
    // creationParams 留空：原生已不再解析任何参数（历史 renderMode 键已废弃）。
    return AndroidView(
      viewType: _viewType,
      layoutDirection: TextDirection.ltr,
      onPlatformViewCreated: _onViewCreated,
    );
  }

  void _onViewCreated(int viewId) {
    _viewId = viewId;
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
    // 事件通道首条为纹理注册结果 {type:'texture', textureId}。
    if (map['type'] == 'texture') {
      final tid = map['textureId'] as int?;
      // ⚠️ 2026-10-12 直播绿屏诊断（只打印，不改行为）：
      //   确认原生是否真的推了纹理、推的是哪个 id、是否与当前持有的相同。
      //   若这里显示 tid 与 _textureId 相等而画面仍绿，则问题不在 Dart 侧接收。
      debugPrint(
        '[绿屏诊断] 收到纹理事件 textureId=$tid 原持有=$_textureId 是否更新=${tid != null && tid >= 0 && _textureId != tid}',
      );
      if (tid != null && tid >= 0 && _textureId != tid) {
        _textureId = tid;
        _textureReadyController.add(tid);
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
      _firstFrameController.add(null);
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
    // ⚠️ 2026-10-12 崩溃修复（真机 signal 11 / SIGSEGV）：
    //   dispose() 会把 _disposed 置 true 并调原生 dispose（销毁 mpv 实例），
    //   而 pause/seek/setVolume 等控制指令此前**不检查 _disposed**，二者可交错：
    //     T1 pause() 发起 IPC → T2 dispose() 发起 IPC → T3 原生先处理 dispose
    //     （Core.destroy → delete inst）→ T4 原生再处理 pause，访问已释放句柄 → 段错误。
    //   真机日志已直接印证该窗口：`mpv 实例已销毁` 之后 4ms 仍有一条
    //   `MpvBackend pause error: mpv view disposed` 到达。
    //   同时播放直播时切源/销毁/新建高频交错，命中概率被放大到必现。
    //   这里直接**静默返回**而不抛异常：调用方（player_screen.dart 多处）是
    //   不 await 的裸调用 `_backend?.pause()`，抛异常会变成未捕获 Future 异常
    //   并触发 FlutterError，反而制造新的崩溃面。已销毁即无事可做，直接吞掉最稳。
    if (_disposed) return;
    final callArgs = <String, dynamic>{'viewId': _viewId!, ...args};
    try {
      await _control.invokeMethod<void>(method, callArgs);
    } on PlatformException catch (e) {
      debugPrint('MpvBackend $method error: ${e.message}');
      rethrow;
    }
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
    // 调用方先 build 出 AndroidView，再调 open；先让出一帧让 widget 树挂载，
    // 再轮询 _viewId，避免 open 时 view 尚未创建。
    await WidgetsBinding.instance.endOfFrame;
    for (var i = 0; i < 250 && _viewId == null; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    if (_viewId == null) {
      throw StateError(
        'MpvBackend: 等待 AndroidView view 创建超时。'
        '请确认播放页对该后端启用了 requiresEagerMount 提前挂载，'
        '且 PlatformView 工厂 viewType=heinplay_mpv 已注册。',
      );
    }
    // mpv 不解析 x-heinplay- 内部头，强制过滤避免泄漏到上游。
    // 硬件解码开关：设置页「硬件解码」关闭时下发 hwdec=no，走纯软解；
    // 开启时要求真硬解（原生已设 hwdec-software-fallback=no，不静默回退）。
    final hardwareDecoding = await UserDataService.getHardwareDecoding();
    // 🔴🔴 2026-10-29：起播定位**之前**先把代理的预热窗口推到落点。
    //
    //   【真机实锤（小米 12S Pro 2026-10-29 21:31）】
    //     21:31:29.744 open startAt=1450000ms
    //     21:31:31.156~33.893 plist0~3 串行下载（2.7s，建索引阻塞）
    //     21:31:34.054 plist315（落点段）才下载完（open 后 4.3s）
    //     21:31:36.005 首帧（open 后 6.3s）
    //   代理侧并发预热（4 路）可把头部段与落点段提前备好。
    try {
      LocalM3u8Proxy.currentInstance?.primePrefetchAt(startAt ?? Duration.zero);
    } catch (e) {
      debugPrint('MpvBackend: 起播预热失败（不影响播放）: $e');
    }
    await _invoke('open', {
      'url': url,
      'startAtMs': startAt?.inMilliseconds ?? 0,
      'headers': stripInternalRequestHeaders(headers, force: true),
      'isLive': isLive,
      'hardwareDecoding': hardwareDecoding,
    });
  }

  @override
  Future<void> play() => _invoke('play', {});

  @override
  Future<void> pause() => _invoke('pause', {});

  @override
  Future<void> seek(Duration position) async {
    // 🔴 2026-10-29：seek **之前**把预热窗口推到新落点（与起播定位同一机制）。
    try {
      LocalM3u8Proxy.currentInstance?.primePrefetchAt(position);
    } catch (e) {
      debugPrint('MpvBackend: seek 预热失败（不影响播放）: $e');
    }
    await _invoke('seek', {'positionSec': position.inMilliseconds / 1000.0});
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
  Stream<void> get firstFrameStream => _firstFrameController.stream;

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
    await _firstFrameController.close();
    await _textureReadyController.close();
  }
}
