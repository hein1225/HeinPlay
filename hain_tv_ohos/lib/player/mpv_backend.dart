import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart' show VideoFormat;

import '../services/local_m3u8_proxy.dart';
import 'buffer_profile_config.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart'; // 复用 stripInternalRequestHeaders
import 'video_render_mode.dart';
import '../utils/log_redactor.dart';

/// mpv 后端（HarmonyOS，基于 @mpv-ohos/mpv-arkts）。
///
/// 与 avplayer / fvp 后端**不同**：mpv 不走 `video_player` 的
/// `VideoPlayerController`，而是经自己的 ArkTS 层（MpvBridge.ets）渲染与控
/// 制 —— 原生侧用鸿蒙 XComponent 承载 libmpv 的画面，Dart 侧只通过
/// MethodChannel（控制）+ EventChannel（状态）桥接。
///
/// 渲染路径是 **PlatformView（XComponent 层）**，不是 fvp 的 texture 推帧 —
/// 即 mpv-arkts 自带的 PlayerSurface 模式，故 buildVideoWidget 返回 OhosView。
///
/// 续播语义：open 时把 startAt 透传给原生，由 mpv-arkts 的 MediaOptions.start
/// 在加载时即定位（映射 mpv 的 start 选项，秒），从根本上规避 fvp 的
/// 「空 buffer 下 inCache 式丢 seek → 续播死循环」缺陷。
class MpvBackend implements VideoPlayerBackend {
  static const String _viewType = 'heinplay_mpv';
  static const String _controlChannel = 'hain_tv/mpv';

  final MethodChannel _control = const MethodChannel(_controlChannel);
  int? _viewId;

  /// 🔴 2026-10-07 换源修复：本后端实例当前**存活**的 view id。
  ///
  /// 【问题】换源时播放页不重建 MpvBackend 实例，只是让 OhosView 换 key 重新挂载。
  ///   旧 view 被原生 dispose 后，`_viewId` 仍留着旧 id（粘滞字段），于是 open()
  ///   里 `while (_viewId == null)` 的条件一开始就不成立 —— 等待新 view 的循环被
  ///   整个跳过，命令直接发往**已销毁的旧 view**，画面永远出不来。
  ///   而「退出播放重进」会新建后端实例，_viewId 归 null，等待恢复有效 → 又能播。
  ///   这正是「换源失败、重进就好」的真因（与硬解无关）。
  ///
  /// 【判据】不能只看 `_viewId != null`，必须确认拿到的是**本次挂载新生成**的 view。
  ///   为此引入自增序号：每次 open() 前 `_awaitedViewSeq++`，`_onViewCreated`
  ///   记录它拿到的序号，只有当新 view 的序号 ≥ 本次期望序号时才算就绪。
  // 🔴 2026-10-07 换源修复（第三版，前两版均为错误方案，勿重蹈）：
  //
  //   【问题】换源不重建 MpvBackend 实例，而旧 PlatformView 已被原生 dispose()。
  //     若 open() 只判 `_viewId == null`，换源时 _viewId 仍是旧 id（非 null），
  //     条件立即为假 → 整个等待被跳过 → loadfile 发往死 view → 画面永远出不来。
  //
  //   【错误方案一】open() 时 `_viewSeq++` 并等 `_viewIdSeq == _viewSeq`。
  //     崩因：挂载时序不可预测。点播是「先建 view、后 open」（日志实证：
  //     create viewId=1 → create viewId=2 → open），_onViewCreated 早已执行完，
  //     写入的是过去值，而 open 自增要的是未来值，必然对不上 → 点播 100% 超时。
  //     直播碰巧「先 open、后 create」才蒙对。**判据绝不能依赖挂载时序。**
  //
  //   【错误方案二】改用 `_mountGeneration > _consumedGeneration`。
  //     仍是在猜时序，同样无法覆盖「view 建完但已被销毁」的窗口，故一并废弃。
  //
  //   【现行方案】让原生如实上报生命周期：MpvPlayerView.dispose() 会通过事件通道
  //     发送 `{'event': 'viewDisposed'}`，Dart 收到即置 `_viewId = null`。
  //     于是 `_viewId == null` 的含义始终准确 ——「当前确实没有可用 view」，
  //     不再是一个会被旧 id 欺骗的假条件。open() 也无需任何世代/序号参与。

  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _bufferedController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _firstFrameController = StreamController<void>.broadcast();

  /// 🔴 2026-10-08 新增：**未被乐观置位污染的 mpv 真实位置流**。
  ///
  /// 【为什么必须与 positionStream 分开】
  ///   positionStream 在 seek 期间上报的是**请求目标值**（AVP 同款做法），
  ///   目的是让进度条停在用户拖到的位置、不被 mpv 的残留 time-pos 往后带。
  ///   但这样 positionStream 就**不再是「mpv 正在播到哪里」**：
  ///   seek 一旦落空（空 seek / 落点无关键帧 / 分片未就绪），
  ///   这个假值就会留在播放页当基准，造成
  ///   「显示时间大于真实进度、且越往后偏差越大」（真机实测 1717.156s 请求
  ///   实际落在 1589.0s，偏差 128 秒）。
  ///
  /// 【用途】播放页用本流**证伪并清除**续播/快进锚点：
  ///   一旦真实位置观测到已接近或越过锚点，锚点即完成使命，必须释放。
  final _realPositionController = StreamController<Duration>.broadcast();

  /// mpv 真实位置流（不做 seek 期乐观置位）。用于校准基准，不用于画进度条。
  Stream<Duration> get realPositionStream => _realPositionController.stream;

  bool _firstFrameEmitted = false;
  bool _completedReported = false;

  /// 位置遥测节流用（见 `_onEvent` 内 `MpvBackend 进度` 日志说明）。
  /// 仅用于诊断，不参与任何播放决策。
  DateTime _lastPositionLogAt = DateTime.fromMillisecondsSinceEpoch(0);
  // 🔴 2026-10-08：原 `_lastLoggedPositionSec` 已删除。它用于「位置未变则
  //   不打日志」的去重，但那恰好会把「位置钉死」这个核心故障藏起来。
  //   现改为纯时间节流，每 3 秒必打一条。
  BoxFit _fit = BoxFit.contain;

  /// 🔴 2026-09-30 路线 B：Flutter 纹理 textureId，由原生 registerTexture 生成并
  ///   经事件通道首条消息回传。Dart 侧用 Texture(textureId) 显示画面（替代 XComponent）。
  int? _textureId;
  final _textureReadyController = StreamController<int>.broadcast();

  /// 🔴 2026-10-07：硬解无帧上报流。
  ///   原生看门狗在硬解会话 open 后 8 秒内进度仍为 0 时发一次；
  ///   播放页收到后重建会话并强制软解，对用户表现为「自动回退软解」。
  final _hwdecNoFrameController = StreamController<void>.broadcast();

  /// 硬解无帧流（软解能出画时触发一次）——供播放页实现自动回退。
  Stream<void> get hwdecNoFrameStream => _hwdecNoFrameController.stream;

  StreamSubscription? _eventSub;
  bool _disposed = false;

  /// 渲染方式：由工厂按场景设置（点播/直播）。默认纹理。
  ///
  /// 🔴 2026-10-07：鸿蒙 mpv 当前走路线 B（Flutter 纹理）。路线 A（XComponent
  ///   SURFACE）代码保留但实测黑屏（flutter-ohos 纹理合成下 XComponent 拿不到
  ///   surface）。故置 surface 时当前仍回落到纹理，并打日志标注，待路线 A
  ///   打通后在此接入真正切换。
  @override
  VideoRenderMode renderMode = VideoRenderMode.texture;

  @override
  BoxFit get fit => _fit;
  @override
  set fit(BoxFit value) {
    if (_fit == value) return;
    _fit = value;
    // 🔴 2026-10-06 修复：控制栏改画面比例原先只改本地变量、从不下发原生，
    //   导致鸿蒙/安卓都「改了没反应」。这里映射成 mpv 的 video-aspect-override
    //   + panscan，实时改变显示比例（参考 mpv-android 的比例档位逻辑）。
    if (_viewId != null) {
      _invoke('setFit', {'fit': value.name}).catchError((e) {
        debugPrint('MpvBackend setFit error: $e');
      });
    }
  }

  /// 🔴 2026-09-30 路线 B：纹理是否就绪（textureId 已由原生回传）。
  bool get textureReady => _textureId != null && _textureId! >= 0;

  /// Flutter 纹理 id，供播放页 Texture(textureId) 显示。
  int? get textureId => _textureId;

  /// 纹理就绪流（首帧前供播放页构建 Texture 显示）。
  Stream<int> get textureReadyStream => _textureReadyController.stream;

  @override
  void set onUnrecoverableStall(VoidCallback? cb) {
    // mpv 后端暂无自愈逻辑，留空满足契约。
  }

  @override
  void set onSeekRebuildRequested(void Function(int targetMs)? cb) {
    // mpv 后端不走代理裁剪落点，无「落点之前不可 seek」问题，留空满足契约。
  }

  /// 🔴 2026-09-30：mpv 走 XComponent SURFACE，原生 Player 实例只在
  /// PlatformView 被创建时才 new 出来。若不提前挂载视频层，播放页的
  /// 「续播定位闸门」会与「等待 view 创建」互相死锁（详见接口注释）。
  @override
  bool get requiresEagerMount => true;

  @override
  Widget buildVideoWidget() {
    if (!Platform.isOhos) {
      // mpv 后端仅支持鸿蒙（mpv-arkts 限定 arm64-v8a）。非鸿蒙平台不应被选到，
      // 这里给一个占位避免崩溃。
      return Container(color: Colors.black);
    }
    // 🔴 2026-09-30 路线 B：OhosView 仅作「挂载锚点」，触发原生 create→registerTexture。
    //   真实画面走 Flutter 纹理（播放页用 Texture(textureId) 显示），不再依赖
    //   XComponent 的原生 surface（flutter-ohos 纹理合成路径下 XComponent 拿不到 surface）。
    //   锚点本身透明，显示层由 player_screen 的 _buildVideo 在 textureReady 后覆盖。
    return OhosView(
      viewType: _viewType,
      layoutDirection: TextDirection.ltr,
      creationParams: const <String, dynamic>{},
      creationParamsCodec: const StandardMessageCodec(),
      onPlatformViewCreated: _onViewCreated,
    );
  }

  void _onViewCreated(int viewId) {
    _viewId = viewId;
    if (_disposed) return;
    // 换源会重建 OhosView，旧的 PlatformView 随之失效：先退订旧事件通道，
    // 否则会同时收到「已销毁 view」的事件（真机曾出现 pause error: no mpv view for id N）。
    _eventSub?.cancel();
    _eventSub = null;
    // 新 view 意味着新纹理，旧的 textureId 必须作废，否则播放页仍去渲染已注销的纹理。
    _textureId = null;
    // 监听该视图的状态事件通道（原生按 viewId 命名）
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
    if (_disposed) return;
    if (payload is! Map) return;
    final map = Map<String, dynamic>.from(payload);
    // 🔴 2026-10-07：硬解生效探针上报（原生侧 open 后 1.2s 回读）。
    //   与 hwdecNoFrame 的区别：这是**信息性**上报，硬解成功时也会来一条，
    //   用于确认「硬解到底有没有真的生效」，不再靠推测。
    if (map['type'] == 'hwdecProbe') {
      final cur = map['hwdecCurrent'] as String? ?? '';
      final vf = map['videoFormat'] as String? ?? '';
      final voFmt = map['voPixelFormat'] as String? ?? '';
      final active = (map['hardwareActive'] as bool?) ?? false;
      debugPrint(
        'MpvBackend 硬解探针: hwdec-current=$cur video-format=$vf '
        '输出像素格式=$voFmt → '
        // 🔴 2026-10-26（第二十轮）：**仅日志文案修正，零行为改动**。
        //   原实现在「输出像素格式为空」（open 后 1.2s 回读过早，硬解尚未吐出
        //   第一帧）时一律打印「⚠️ 硬解未生效」，与随后的硬解看门狗结论
        //   （进度已前进 ⇒ 硬解正常）自相矛盾 —— 真机 hilog 2026-10-26 11:25:44
        //   就是这样误报的，会误导后续排查。
        //   现在区分「确实未生效」与「采样过早、取不到像素格式」。
        '${active ? "✅ 硬解已生效" : (voFmt.isEmpty ? "⚠️ 探针未取到输出像素格式（采样过早，不能据此判定硬解失效）" : "⚠️ 硬解未生效")}',
      );
      return;
    }
    // 🔴 2026-10-07：硬解黑屏看门狗上报。
    //   原生侧在硬解会话 open 后进度仍为 0 时上报此事件，
    //   播放页据此重建会话并强制软解（forceSoftwareDecodingForNextOpen）。
    if (map['type'] == 'hwdecNoFrame') {
      debugPrint('MpvBackend 收到硬解无帧上报，通知回退软解');
      _hwdecNoFrameController.add(null);
      return;
    }
    // 🔴 2026-10-07 换源修复：原生 view 已销毁，立即作废本地 viewId。
    //
    //   这是换源能播的关键：换源不重建 MpvBackend 实例，旧 PlatformView 被原生
    //   dispose() 后，若 Dart 仍持有旧 viewId（非 null），open() 的等待条件
    //   `_viewId == null` 会立即为假而被整个跳过，命令发往死 view，画面永不出来。
    //   原生在 dispose() 里主动上报本事件，Dart 据此把 _viewId 归零，
    //   使等待条件恢复准确语义。收到后同时作废旧纹理与旧事件通道。
    if (map['type'] == 'viewDisposed') {
      debugPrint('MpvBackend 收到原生 viewDisposed，作废 viewId=$_viewId');
      _viewId = null;
      _textureId = null;
      _eventSub?.cancel();
      _eventSub = null;
      return;
    }
    // 🔴 2026-09-30 路线 B：事件通道首条为纹理注册结果 {type:'texture', textureId}。
    if (map['type'] == 'texture') {
      final tid = map['textureId'] as int?;
      if (tid != null && tid >= 0 && _textureId != tid) {
        _textureId = tid;
        _textureReadyController.add(tid);
      }
      return;
    }
    final positionSec = (map['positionSec'] as num?)?.toDouble() ?? 0;
    // 🔴 2026-10-08：真实位置（未经 seek 期乐观置位）。缺省回落到 positionSec，
    //   保证与旧原生侧（尚未上报该字段）协同时行为不回退。
    final realPositionSec =
        (map['realPositionSec'] as num?)?.toDouble() ?? positionSec;
    final durationSec = (map['durationSec'] as num?)?.toDouble() ?? 0;
    final playing = (map['playing'] as bool?) ?? false;
    final buffering = (map['buffering'] as bool?) ?? false;
    final eof = (map['eof'] as bool?) ?? false;

    // 🔴 2026-10-08【方案 B 撤回】定位静默期 + 落点校准 + 采样平移 —— **已全部删除**。
    //
    //   【为什么撤回】这套机制建立在一个被真机数据推翻的假设上：以为 mpv 落点带
    //   「固定 ~796ms 偏差」，于是用 _locateOffsetMs 做整体平移。但 h11 日志显示
    //   偏差是 +74040ms / +68040ms（≈1 分钟）且方向不定 —— 它根本不是常量，
    //   而是「**上一次播放位置的残留值**」：
    //     19:39:27.485 定位静默期开始 target=857556ms
    //     19:39:27.493 落点稳定 position=931596ms   ← 仅 8ms 后，931596 是旧位置
    //   我的稳定判据 `positionMs >= targetMs - 1500` 遇到「旧位置 > 新目标」时
    //   瞬间为真，把残留值当成落点 → 偏移记成 +74040ms → 此后每帧采样都被
    //   平移 +74040ms → 表现为「定位好了又往前跳 1 分钟」。
    //   即：**这套补丁不但没修好问题，反而把误差放大了一分钟。**
    //
    //   【正确做法】已在原生侧根治，与 AVP 逐字对齐：
    //     · PlayerStream 新增 seeking 流，Player.seek()/open() 置位，
    //       MPV_EVENT_PLAYBACK_RESTART 复位（等价 AVP 的 SEEK_DONE）；
    //     · MpvBridge._bindStreams 在 seeking 期间丢弃 mpv 原始 time-pos，
    //       改报 seekTargetSec —— 即 AVP `if (this.isSeeking) return this.seekPosition;`。
    //   为什么必须放在原生侧：只有那里「确切知道 seek 何时开始、何时结束」，
    //   Dart 层只能靠猜位置来推断状态，而位置本身就不可信 —— 判据自指，必然出错。
    //
    //   故此处恢复为**纯透传**，不再对位置做任何加工。
    _positionController.add(Duration(milliseconds: (positionSec * 1000).round()));
    // 🔴 2026-10-08：真实位置单走一条流（> 0 才发，避免起播前的 0 触发误校准）。
    if (realPositionSec > 0) {
      _realPositionController.add(
        Duration(milliseconds: (realPositionSec * 1000).round()),
      );
    }
    if (durationSec > 0) {
      _durationController.add(
        Duration(milliseconds: (durationSec * 1000).round()),
      );
    }
    _playingController.add(playing);
    // buffered 用 demuxer-cache-time（秒）→ Duration
    final bufferSec = (map['buffer'] as num?)?.toDouble() ?? 0;
    _bufferedController.add(Duration(milliseconds: (bufferSec * 1000).round()));

    // 🔴 HeinPlay 新增（2026-10-08）：mpv 位置上报遥测。
    //
    //   【为什么必须加】h15 真机日志里，mpv 会话（21:22:00–21:24:10，130 秒）
    //   的 position 日志是 **0 条**，而同窗口的 AVP 会话有 89 条
    //   `[VideoPlayerBackendImpl] 进度 position=NNNms`。于是用户报告的
    //   「mpv 显示时间与 AVP 差约 1 分钟」**在这份日志里根本无法测量** ——
    //   不是测出来没有偏移，而是**没有任何数据点**。
    //   `seek 守卫: 在途=N` 证明 `_pushState()` 确实在调用、positionSec 确实在推，
    //   缺的不是功能而是观测。故此处补一条节流日志，让 mpv 的位置在真机
    //   hilog 中可见、可与 AVP 逐点对照。
    //
    //   【节流】position 推送频率约等于渲染帧率（可达 60 次/秒），全量打印会
    //   淹没日志并明显拖慢热路径。故与 AVP 侧 `进度 playing=` 的频率对齐，
    //   约每 3 秒一条。
    //
    //   【🔴🔴 2026-10-08 修正：去掉「位置未推进则不打」的条件】
    //
    //     原条件是 `&& positionSec != _lastLoggedPositionSec`，本意是
    //     「缓冲/卡顿时不刷屏」。但真机日志（23:24–23:27）证实它**把故障本身
    //     藏了起来**：本次 bug 的核心症状正是「位置被钉死不动」，而该条件下
    //     位置一旦不动，日志就**彻底静默** —— 排查时看到的是「没有任何异常
    //     输出」，而不是「位置停住了」。这和本文件上面记录的 r15 教训
    //     （「mpv 的 position 日志是 0 条」）是**同一类错误**：为了不刷屏
    //     而丢掉了唯一的观测通道。
    //
    //     正确做法是「按时间节流」而非「按变化节流」：每 3 秒必定输出一条，
    //     位置没变时如实打印相同的值。这样才能看到「钉死」这个关键形态
    //     （连续多条相同 position 就是钉死的直接证据）。
    final nowMs = DateTime.now();
    if (nowMs.difference(_lastPositionLogAt).inMilliseconds >= 3000) {
      _lastPositionLogAt = nowMs;
      // 🔴 同时带上 realPositionSec —— 本轮 bug 的根因就是它恒不前进，
      //   必须让它在日志里可见，否则下一轮仍要靠推断。
      debugPrint(
        'MpvBackend 进度 playing=$playing '
        'position=${(positionSec * 1000).round()}ms '
        'real=${(realPositionSec * 1000).round()}ms '
        'duration=${(durationSec * 1000).round()}ms '
        'buffered=${(bufferSec * 1000).round()}ms '
        'eof=$eof',
      );
    }

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
      // 已 dispose（或尚未创建 view）时不再下发 —— 发往不存在的 viewId 只会
      // 在原生侧留下 `no mpv view for id N` 噪音，命令本身必然落空。
      debugPrint('MpvBackend $method 跳过：view 尚未创建或已销毁');
      return;
    }
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

    // 🔴 2026-10-24 第七轮：**起播定位之前把代理的预取窗口预热到落点**。
    //
    //   【真机实锤：hilog 2026-10-24 10:08】
    //     18:07:00.621 MpvBackend open: ... startAt=0:23:30.767000
    //     18:07:03.628 [mpv-seek] 看门狗触发：3s 内未收到 playback-restart
    //     18:07:05.216 [mpv-event] seek       ← 4.6s 后 mpv 才真正开始 seek
    //     18:07:07.498 seek 落点核对: 请求=1410.767s 落点=1410.767s ✅
    //   ⇒ **open 到落点整整 6.9 秒**。
    //
    //   【真因】代理的预取窗口跟着播放头走，而 open 此刻播放头还是 0；
    //   落点（下标 ~700）附近的分片一个都没缓存 ⇒ mpv 只能现等 CDN。
    //
    //   注意：open 发生在 master 展开完成之前（展开要 1.1~2.8s），
    //   此刻代理还没有分片表 ⇒ 代理会先挂起目标，待分片表就绪后自动补预热。
    if (startAt != null && startAt > Duration.zero) {
      LocalM3u8Proxy.currentInstance?.primePrefetchAt(startAt);
    }

    // 🔴 2026-10-07 渲染方式：鸿蒙 mpv 当前仅路线 B（纹理）可用。
    // 置 surface 时无法真正切到路线 A（XComponent 实测黑屏），回落纹理并标注。
    if (renderMode == VideoRenderMode.surface) {
      debugPrint(
        'MpvBackend renderMode=surface：鸿蒙当前回落纹理渲染（路线A XComponent 待打通）',
      );
    }
    // mpv 后端自管状态流，复位每周期标记
    _firstFrameEmitted = false;
    _completedReported = false;

    // 🔴 2026-09-30：等待 PlatformView 创建（_viewId 在 onPlatformViewCreated 赋值）。
    //
    // 【为什么必须先让出一帧】调用方（播放页）在调 open() 之前只做了 setState，
    //   setState 仅「标记待重建」，真正的 build 发生在下一帧。若此处直接进入
    //   下面的轮询，widget 树里可能还没有本后端返回的 OhosView，
    //   PlatformView 自然也不会被创建 —— 轮询必然空转到超时。
    //   先等到下一帧结束（此时 eager mount 的 OhosView 已完成挂载），
    //   再轮询 _viewId，才能等到真实结果。
    await WidgetsBinding.instance.endOfFrame;

    // 等待 PlatformView 就绪。判据只有一个真实事实：`_viewId != null`。
    //
    // 🔴 2026-10-07：这里曾被改成「等一个自增的期望世代号」，导致点播 100% 超时。
    //   根因是挂载时序不可预测（点播先建 view 后 open、直播先 open 后建 view），
    //   任何依赖时序的判据都必然在部分路径上失效。
    //   现在原生 dispose() 会主动上报 `viewDisposed`（见 _onNativeEvent），
    //   Dart 收到即置 _viewId = null，因此本条件在换源场景下同样准确：
    //   旧 view 已销毁 → _viewId 被清空 → 正确进入等待 → 等新 view 建好再发命令。
    debugPrint(
      'MpvBackend open: 等待 view 就绪（当前 _viewId=$_viewId）',
    );

    // 首次创建 PlatformView 涉及原生 Player 构造 + 引擎侧 surface 装配，
    // 在低端设备上可能明显慢于普通 widget，故给到 5 秒（原 1 秒实测不够）。
    for (var i = 0; i < 250 && _viewId == null; i++) {
      await Future.delayed(const Duration(milliseconds: 20));
    }
    if (_viewId == null) {
      throw StateError(
        'MpvBackend: 等待 XComponent view 创建超时（当前 _viewId=$_viewId）。'
        '请确认播放页对该后端启用了 requiresEagerMount 提前挂载，'
        '且 PlatformView 工厂 viewType=heinplay_mpv 已注册。',
      );
    }
    // mpv 不解析 x-heinplay- 内部头，强制过滤避免泄漏到上游。
    // 🔴 2026-10-07：删除「硬件解码」软开关，mpv 始终优先硬解（ohcodec）。
    //   forceSoftware 由硬解黑屏看门狗在重建会话时置位（无 UI 入口），
    //   一次性消费 —— 消费后复位，后续 open 恢复优先硬解。
    final forceSoftware = _forceSoftwareForNextOpen;
    _forceSoftwareForNextOpen = false;

    // 🔴 2026-10-08【方案 B 撤回】原先此处进入「定位静默期」，现已删除。
    //
    //   起播定位与快进/快退是同一类问题（`--start` 与 seek 走 mpv 同一条
    //   queue_seek 路径、同精度，见 player/loadfile.c:2072-2080），但收口位置
    //   错了：Dart 层无法可靠判断「定位何时结束」，只能靠位置值反推，而位置值
    //   本身正是不可信的那个 —— 判据自指。
    //   现由原生侧 PlayerStream.seeking + MPV_EVENT_PLAYBACK_RESTART 精确界定，
    //   见 MpvBridge._bindStreams 的注释。

    await _invoke('open', {
      'url': url,
      'startAtMs': startAt?.inMilliseconds ?? 0,
      'headers': stripInternalRequestHeaders(headers, force: true),
      'isLive': isLive,
      'forceSoftware': forceSoftware,
      // 🔒 隐私：把需遮蔽的 LunaTV 服务器地址下发给原生层，
      //    使 mpv 原生日志（hilog）里的同一地址也被遮蔽。
      'sensitiveHosts': LogRedactor.sensitiveHosts,
    });
  }

  /// 🔴 2026-10-07：[forceSoftware] 由硬解黑屏看门狗在重建会话时置 true，
  /// 让本会话 directly 走软解，避免再次黑屏死循环。
  bool _forceSoftwareForNextOpen = false;

  /// 供播放页看门狗调用：下一次 open 强制软解。
  void forceSoftwareDecodingForNextOpen() {
    _forceSoftwareForNextOpen = true;
  }

  @override
  Future<void> play() => _invoke('play', {});

  @override
  Future<void> pause() => _invoke('pause', {});

  /// 🔴 2026-10-08【方案 B 撤回·改为原生侧收口】seek 恢复为纯命令透传。
  ///
  /// 【现象】mpv 每次「读播放记录续播」或「快进/快退」后，落点都会比请求值
  ///   再往前多出一截（用户实测「往前跳 1 分钟」），且每操作一次累加一次。
  ///
  /// 【真因·已用真机数据锁定】mpv 的 `time-pos` 在 seek 期间**不可信**：
  ///   它会先吐出上一次播放位置的**残留值**，再逐步收敛到新落点。
  ///   证据（h11，请求 857556ms）：
  ///     19:39:27.485  定位静默期开始 target=857556ms
  ///     19:39:27.493  落点稳定 position=931596ms   ← 仅 8ms 后，931596 是旧位置
  ///   偏差 +74040ms，正是用户感知的「往前跳 1 分钟」。
  ///
  /// 【为什么不由 Dart 层修】曾在此处实现「定位静默期 + 落点校准 + 采样平移」，
  ///   失败原因是**判据自指**：Dart 只能靠位置值反推「定位是否结束」，
  ///   而位置值本身正是不可信的那个。旧位置（931596）大于新目标（857556）时，
  ///   稳定判据 `positionMs >= targetMs - 1500` 瞬间为真 → 把残留值当落点 →
  ///   偏移记成 +74040ms → 此后每帧都被平移 +74040ms。
  ///   **该补丁反而把误差放大了一分钟，已全部删除。**
  ///
  /// 【现在】原生侧根治，与 AVP 逐字对齐：
  ///   · PlayerStream.seeking：Player.seek()/open() 置位，
  ///     MPV_EVENT_PLAYBACK_RESTART 复位（等价 AVP 的 SEEK_DONE）；
  ///   · MpvBridge._bindStreams：seeking 期间丢弃原始 time-pos，改报请求值
  ///     —— 即 AVP 的 `if (this.isSeeking) return this.seekPosition;`。
  ///   只有原生侧「确切知道 seek 何时开始、何时结束」，故收口必须在那里。
  ///
  /// 【为什么 mpv 不能像 AVP 那样精准】不是定位能力差异，而是**上报路径缺少
  ///   seek 状态守卫**：AVP 的 getPosition() 第一行就有 isSeeking 短路，
  ///   而 MpvBridge 原先是无脑转发 `s.position.listen((v) => positionSec = v)`。
  ///   mpv 本身的 seek 精度没问题（absolute 默认即 hr-seek，见
  ///   options/options.c:1050 `.hr_seek = 2;`），问题只出在「定位途中把中间态
  ///   当成最终值上报」。
  @override
  Future<void> seek(Duration position) {
    // 🔴 2026-10-24 第七轮：seek 之前把代理预取窗口预热到落点
    //   （否则落点附近的分片要现等 CDN，真机实测冻结 3~7 秒）。
    LocalM3u8Proxy.currentInstance?.primePrefetchAt(position);
    return _invoke('seek', {
      'positionSec': position.inMilliseconds / 1000.0,
    });
  }

  @override
  Future<void> setSpeed(double speed) => _invoke('setSpeed', {'rate': speed});

  @override
  Future<void> setVolume(double volume) =>
      _invoke('setVolume', {'volume': volume.clamp(0.0, 1.0)});

  /// 🔴 2026-10-06 修复：横竖屏旋转后画面被压扁 + 卡死。
  /// 路线 B 下没有 XComponent，mpv 的 ohos-surface-size 只构造时下发一次，
  /// 旋转后无机制更新 → mpv 仍按旧（竖）尺寸渲染，被 Flutter 横纹理拉伸压扁。
  /// 这里在旋转/显示区域尺寸**稳定后**（调用方已去抖，只发一次最终尺寸）下发
  /// 原生，让 mpv 重新按正确宽高比出画。
  ///
  /// 【为什么不再重发 setFit】setFit 映射的是用户选的画面比例
  /// （video-aspect-override / panscan，contain/cover/fill）；旋转只改变了**容器
  /// 尺寸**，用户选的比例没变，mpv 在 contain(-1) 下会自行按新容器重算，无需重发。
  /// 额外重发反而引入竞态（两次异步 invoke 之间 mpv 可能用「新尺寸 + 旧比例」渲染）。
  /// 压扁的真因是过渡帧里被写入了**错误的过渡尺寸**，故正确做法是去抖后只发最终值。
  ///
  /// 【参照 AVP 的稳的做法】AVPlayer 后端（video_player_ohos）把纹理 surfaceId 交给
  /// 系统播放器自渲染，旋转时 Dart 侧零干预、从不 resize；mpv 是自绘 VO 必须外部给
  /// 尺寸，但我们同样遵循「少动、稳定后只同步一次」的原则，不在过渡帧反复 resize
  /// （反复 setTextureBufferSize 会在出帧途中死锁，这正是此前卡死的根因）。
  /// [size] 为当前显示区域逻辑尺寸（MediaQuery.size），[devicePixelRatio] 用于换算。
  Future<void> updateSurfaceSize(Size size, double devicePixelRatio) async {
    if (_viewId == null || _disposed) return;
    final w = (size.width * devicePixelRatio).round();
    final h = (size.height * devicePixelRatio).round();
    if (w <= 0 || h <= 0) return;
    try {
      await _invoke('setSurfaceSize', {'width': w, 'height': h});
    } on PlatformException catch (e) {
      debugPrint('MpvBackend updateSurfaceSize error: $e');
    }
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
  Stream<void> get firstFrameStream => _firstFrameController.stream;

  @override
  Future<void> dispose() async {
    _disposed = true;
    // 注：原先此处复位 Dart 侧定位静默期标记，该机制已于 2026-10-08 移除
    //     （改由原生 PlayerStream.seeking 承担），故无需再复位任何状态。
    if (_viewId != null) {
      try {
        await _control.invokeMethod<void>('dispose', {'viewId': _viewId});
      } on PlatformException catch (_) {
        // 忽略原生侧已销毁的情况
      }
    }
    await _eventSub?.cancel();
    _eventSub = null;
    // 🔴 2026-10-07 换源修复：清空 view 归位信息。
    //   dispose 后这个 viewId 已不存在，若继续留着，后续任何走 _invoke 的调用
    //   （pause/seek/setFit）都会发往死 view，产生「no mpv view for id N」；
    //   若之后本实例被复用，open() 也会被残留的 _viewId 误导（见文件顶部方案说明）。
    _viewId = null;
    _textureId = null;
    await _positionController.close();
    await _durationController.close();
    await _bufferedController.close();
    await _playingController.close();
    await _completedController.close();
    await _firstFrameController.close();
    await _textureReadyController.close();
    await _hwdecNoFrameController.close();
    await _realPositionController.close();
  }
}
