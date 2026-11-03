import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

/// 起播预热（prime）的**后台下载器**：把分片下载从 UI isolate 挪到独立 isolate。
///
/// 🔴 2026-11-02 新增（TV 版 mpv 起播卡死修复）
///
/// 【为什么必须挪走】
///   Flutter 的 Dart UI isolate 在 Android 上跑在**主线程**（= platform 线程），
///   MethodChannel 的原生处理也在这条线程上。于是：
///     · UI isolate 只要在做重活（下载、解压、字节搬运），
///       platform 线程就没空处理「open（loadfile）」这类原生命令；
///     · 更糟的是 UI isolate 一旦被占满，**连原生回包都递不回来**。
///   实测（XiaoPaiTech BA001 / armeabi-v7a / Android 9）：
///     `MpvBackend open:` → `Prime: 落点 2061000ms → 分片 #686` 之后
///     **再无任何日志**，native 侧 `open url=` 从未出现、代理端口零连接，
///     主线程 100% CPU（ANR 栈全在 libapp.so / Dart AOT）。
///   即：预热把 UI isolate 占住了 ⇒ open 命令下不去 ⇒ 整机 ANR。
///
/// 【本类做什么】
///   独立 isolate 持有一条自己的 [HttpClient]（自己解 gzip、自己搬字节），
///   UI isolate 只负责「发请求 + 收字节」，全程不碰 socket 与字节流。
///
/// 【降级】
///   isolate 起不来（极端环境）时抛 [_PrimeDownloaderUnavailable]，
///   由调用方回落到「同 isolate 下载」的旧路径（宁可慢，也不能不播）。
class PrimeDownloader {
  /// 全局单例（一个应用一个下载 isolate 足够：dart:io 内部异步并发）。
  static PrimeDownloader? _instance;

  static PrimeDownloader get instance => _instance ??= PrimeDownloader._();

  PrimeDownloader._() {
    _inbox.listen(_onMessage);
  }

  final ReceivePort _inbox = ReceivePort();
  final Map<int, Completer<Uint8List?>> _pending = {};
  SendPort? _commands;
  int _seq = 0;
  bool _spawnFailed = false;
  Future<void>? _spawning;
  Completer<void>? _spawnCompleter;

  /// 是否可用（isolate 未能启动时为 false，调用方需回落旧路径）。
  bool get available => !_spawnFailed;

  /// 在后台 isolate 下载一个分片；失败返回 null。
  ///
  /// [headers] 为请求头（可为空）。抛 [_PrimeDownloaderUnavailable]
  /// 表示 isolate 不可用，调用方应回落到同 isolate 下载。
  Future<Uint8List?> download(
    String url,
    Map<String, String> headers,
  ) async {
    if (_spawnFailed) {
      throw const PrimeDownloaderUnavailable('prime 下载 isolate 不可用');
    }
    await _ensureStarted();
    final id = ++_seq;
    final completer = Completer<Uint8List?>();
    _pending[id] = completer;
    _commands!.send(<String, Object?>{
      'id': id,
      'url': url,
      'headers': headers,
    });
    return completer.future;
  }

  Future<void> _ensureStarted() async {
    if (_commands != null) return;
    final inFlight = _spawning;
    if (inFlight != null) return inFlight;
    final completer = Completer<void>();
    final future = completer.future;
    _spawning = future;
    _spawnCompleter = completer;
    try {
      final isolate = await Isolate.spawn(
        _primeWorkerEntry,
        _inbox.sendPort,
        debugName: 'heinplay-prime-dl',
      );
      // isolate 意外退出时不能让调用方永远挂着。
      isolate.addOnExitListener(
        _inbox.sendPort,
        response: <String, Object?>{'exit': true},
      );
    } catch (e) {
      _spawnFailed = true;
      _spawning = null;
      _spawnCompleter = null;
      completer.completeError(
        PrimeDownloaderUnavailable('prime 下载 isolate 启动失败: $e'),
      );
      return;
    }
    // 等 worker 把命令端口回传（_onMessage 里完成）。
    return future;
  }

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    final map = Map<Object?, Object?>.from(raw);
    if (map['port'] != null) {
      _commands = map['port'] as SendPort;
      final c = _spawnCompleter;
      _spawning = null;
      _spawnCompleter = null;
      if (c != null && !c.isCompleted) c.complete();
      return;
    }
    if (map['exit'] == true) {
      // isolate 退出了：所有在途请求按失败收口，避免永久挂起。
      _spawnFailed = true;
      for (final c in _pending.values) {
        if (!c.isCompleted) c.complete(null);
      }
      _pending.clear();
      return;
    }
    final id = map['id'];
    if (id is! int) return;
    final completer = _pending.remove(id);
    if (completer == null || completer.isCompleted) return;
    if (map['ok'] == true) {
      final data = map['data'];
      if (data is TransferableTypedData) {
        completer.complete(data.materialize().asUint8List());
      } else {
        completer.complete(null);
      }
    } else {
      completer.complete(null);
    }
  }
}

/// isolate 不可用（需要调用方回落旧路径）。
class PrimeDownloaderUnavailable implements Exception {
  const PrimeDownloaderUnavailable(this.message);
  final String message;
  @override
  String toString() => 'PrimeDownloaderUnavailable: $message';
}

/// 后台 isolate 的入口函数（顶层函数，AOT 下必须可静态定位）。
///
/// 协议：
///   主 → worker：`{'id': int, 'url': String, 'headers': Map<String,String>}`
///   worker → 主：`{'port': SendPort}`（握手）
///                  `{'id': int, 'ok': true, 'data': TransferableTypedData}`
///                  `{'id': int, 'ok': false}`
void _primeWorkerEntry(SendPort toMain) {
  final inbox = ReceivePort();
  toMain.send(<String, Object?>{'port': inbox.sendPort});

  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 15)
    ..idleTimeout = const Duration(seconds: 30);

  inbox.listen((dynamic raw) async {
    if (raw is! Map) return;
    final map = Map<Object?, Object?>.from(raw);
    final id = map['id'];
    final url = map['url'];
    if (id is! int || url is! String) return;
    final headers = <String, String>{};
    final rawHeaders = map['headers'];
    if (rawHeaders is Map) {
      rawHeaders.forEach((k, v) {
        if (k is String && v is String) headers[k] = v;
      });
    }
    try {
      final req = await client.getUrl(Uri.parse(url));
      headers.forEach((k, v) {
        // dart:io 自己管 connection / transfer-encoding 等少数头，
        // 强行设置会抛异常 ⇒ 逐个头 try，失败就跳过。
        if (k.toLowerCase() == 'connection') return;
        try {
          req.headers.set(k, v);
        } catch (_) {}
      });
      final resp = await req.close().timeout(const Duration(seconds: 20));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        toMain.send(<String, Object?>{'id': id, 'ok': false});
        return;
      }
      final builder = BytesBuilder(copy: false);
      await for (final chunk in resp) {
        builder.add(chunk);
      }
      final bytes = builder.takeBytes();
      toMain.send(<String, Object?>{
        'id': id,
        'ok': true,
        'data': TransferableTypedData.fromList(<Uint8List>[bytes]),
      });
    } catch (_) {
      toMain.send(<String, Object?>{'id': id, 'ok': false});
    }
  });
}
