// 桌面 mpv 出画链路的排障自检界面（**仅由 HEIN_MPV_SELFTEST 触发**）。
//
// 【存在理由】
//   桌面 mpv 壳的出画链路是：
//     mpv 渲染 → FBO → FlTextureGL.populate → Flutter 采样
//   其中 populate **只在 Dart 侧真的构建了 `Texture(textureId)` 时**才会被
//   Flutter 引擎调用（引擎侧证据：fl_engine.cc 的
//   fl_engine_gl_external_texture_frame_callback → fl_texture_gl_populate）。
//
//   若只让壳自播放而没有 UI 采样，populate 恒为 0 次 —— 日志上表现为
//   「渲染帧在稳定增长，但完全没有 populate/捕获记录」，无法验证
//   「捕获 Flutter EGL 上下文 → 建共享上下文 → 纹理名在 Flutter 侧有效」
//   这一段，也就无法定位黑屏。真机排障常无法人工点进播放页（无输入设备、
//   无人值守、自动化环境），故提供这个最小界面。
//
// 【安全】
//   仅在显式设置环境变量 HEIN_MPV_SELFTEST 时由 main() 走此分支，
//   正常启动路径完全不受影响。
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 最小自检界面：init → open → `Texture(textureId)` 出画。
class MpvSelfTestApp extends StatefulWidget {
  const MpvSelfTestApp({super.key, required this.media});

  /// 要加载的媒体（本地路径或 URL），来自 HEIN_MPV_SELFTEST。
  final String media;

  @override
  State<MpvSelfTestApp> createState() => _MpvSelfTestAppState();
}

class _MpvSelfTestAppState extends State<MpvSelfTestApp> {
  static const MethodChannel _channel = MethodChannel('hain_tv/mpv_desktop');
  static const EventChannel _events =
      EventChannel('hain_tv/mpv_desktop_events');

  int? _textureId;
  String _status = '初始化中…';
  StreamSubscription<dynamic>? _sub;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    // 先订阅事件通道：纹理 id 既可能由 init 返回值给出，也可能经事件通道
    // 推上来（壳里 push_event("textureId", ...)），两条都要接，漏一条就会
    // 永远等不到 textureId → 不建 Texture → populate 不被调用。
    _sub = _events.receiveBroadcastStream().listen((dynamic event) {
      if (event is! Map) return;
      if (event['name'] == 'textureId') {
        final tid = (event['value'] as num?)?.toInt();
        debugPrint('[SELFTEST] 事件通道收到 textureId=$tid');
        if (tid != null && tid >= 0 && mounted) {
          setState(() => _textureId = tid);
        }
      }
    }, onError: (Object e) => debugPrint('[SELFTEST] 事件通道错误: $e'));

    try {
      final r = await _channel.invokeMethod<Map<dynamic, dynamic>>('init');
      final tid = (r?['textureId'] as num?)?.toInt();
      debugPrint('[SELFTEST] init ok=${r?['ok']} textureId=$tid');
      if (mounted) {
        setState(() {
          _status = 'init ok=${r?['ok']}';
          if (tid != null && tid >= 0) _textureId = tid;
        });
      }

      // ⚠️ 壳侧 open 返回的是 Map{rc:int}（见 hein_mpv_linux_plugin.c），
      //    不是裸 int —— 之前按 <int> 解析会抛
      //    "type '_Map<Object?, Object?>' is not a subtype of type 'int?'"。
      final openRes = await _channel.invokeMethod<Map<dynamic, dynamic>>(
          'open', <String, dynamic>{
        'url': widget.media,
        'startAtMs': 0,
        'isLive': false,
        'hardwareDecoding': false,
        'cacheSecs': 30,
      });
      final rc = (openRes?['rc'] as num?)?.toInt();
      debugPrint('[SELFTEST] open rc=$rc media=${widget.media}');
      if (mounted) setState(() => _status = 'open rc=$rc');
    } catch (e) {
      debugPrint('[SELFTEST] 初始化异常: $e');
      if (mounted) setState(() => _status = '异常: $e');
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    // 尽力通知壳清理，但不阻塞退出（避免退出卡死）。
    unawaited(_channel.invokeMethod<void>('dispose').catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 🔴 核心：这个 Texture 就是让 Flutter 去调 populate 的唯一开关。
            if (_textureId != null)
              Texture(textureId: _textureId!)
            else
              const Center(
                child: Text(
                  '等待 textureId…',
                  style: TextStyle(color: Colors.white70),
                ),
              ),
            Positioned(
              left: 12,
              bottom: 12,
              child: Text(
                'SELFTEST | $_status | tex=$_textureId',
                style: const TextStyle(color: Colors.greenAccent, fontSize: 14),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
