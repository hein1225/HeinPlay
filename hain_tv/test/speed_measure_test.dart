import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

/// 限速 HTTP 服务器参数：首包延迟 + 固定发送速率，模拟真实 CDN。
const int kChunkSize = 16 * 1024;
const int kBytesPerSec = 8 * 1024 * 1024; // 8 MB/s ≈ 64 Mbps
const int kFirstByteDelayMs = 60; // 排队 + RTT

/// 复刻 LunaTVService._measureSpeed 的**现网口径**：
///   计时从响应头到达开始（首包等待被计入），用整数毫秒。
Future<({double? speed, String? error})> measureCurrent(
  http.Client client,
  String url,
  int maxBytes,
) async {
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers.putIfAbsent('Range', () => 'bytes=0-${maxBytes - 1}');
    final resp = await client.send(req);
    if (resp.statusCode == 200 || resp.statusCode == 206) {
      final transfer = Stopwatch()..start();
      var received = 0;
      await for (final chunk in resp.stream) {
        received += chunk.length;
        if (received >= maxBytes) break;
      }
      // 工程自定义 drain：吞掉二次 listen 的 StateError
      try {
        await resp.stream.drain<void>();
      } catch (_) {}
      transfer.stop();
      final seconds = transfer.elapsedMilliseconds / 1000.0;
      return (speed: seconds > 0 ? received / seconds : 0.0, error: null);
    }
    return (speed: null, error: 'status ${resp.statusCode}');
  } catch (e) {
    return (speed: null, error: '$e');
  }
}

/// 修正口径：速度按「首字节到达 → 末字节到达」的传输时间计算，排除首包等待；
/// 计时精度提高到微秒。
Future<({double? speed, String? error})> measureFixed(
  http.Client client,
  String url,
  int maxBytes,
) async {
  try {
    final req = http.Request('GET', Uri.parse(url));
    req.headers.putIfAbsent('Range', () => 'bytes=0-${maxBytes - 1}');
    final resp = await client.send(req);
    if (resp.statusCode == 200 || resp.statusCode == 206) {
      var received = 0;
      int? firstUs;
      int? lastUs;
      final transfer = Stopwatch()..start();
      await for (final chunk in resp.stream) {
        received += chunk.length;
        firstUs ??= transfer.elapsedMicroseconds;
        lastUs = transfer.elapsedMicroseconds;
        if (received >= maxBytes) break;
      }
      transfer.stop();
      final transferUs = lastUs! - firstUs!;
      if (transferUs <= 0) {
        return (speed: null, error: '单 chunk，传输时间不可分');
      }
      return (speed: received * 1000000.0 / transferUs, error: null);
    }
    return (speed: null, error: 'status ${resp.statusCode}');
  } catch (e) {
    return (speed: null, error: '$e');
  }
}

void main() {
  late HttpServer server;
  late String base;
  final payload = Uint8List(5 * 1024 * 1024);

  setUp(() async {
    server = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    base = 'http://127.0.0.1:${server.port}';
    server.listen((req) async {
      await Future<void>.delayed(const Duration(milliseconds: kFirstByteDelayMs));
      req.response.headers.contentType = ContentType.binary;

      final range = req.headers.value('range');
      int start = 0;
      int end = payload.length - 1;
      bool partial = false;
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        if (m != null) {
          start = int.tryParse(m.group(1) ?? '0') ?? 0;
          final endStr = m.group(2);
          end = (endStr != null && endStr.isNotEmpty)
              ? int.tryParse(endStr)!
              : payload.length - 1;
          partial = true;
        }
      }
      // ignore-range 路径：忽略 Range，返回完整 5MB（真实 CDN 常见行为）
      final slice = Uint8List.sublistView(payload, start, end + 1);
      req.response.statusCode = partial ? 206 : 200;
      req.response.contentLength = slice.length;

      for (var off = 0; off < slice.length; off += kChunkSize) {
        final n = min(kChunkSize, slice.length - off);
        req.response.add(Uint8List.sublistView(slice, off, off + n));
        await req.response.flush();
        await Future<void>.delayed(
          Duration(microseconds: (n / kBytesPerSec * 1000000).round()),
        );
      }
      await req.response.close();
    });
  });

  tearDown(() async => server.close(force: true));

  test('现网口径 vs 修正口径（限速 8MB/s，首包 60ms）', () async {
    const realBytesPerSec = 8 * 1024 * 1024;
    for (final maxBytes in [512 * 1024, 128 * 1024]) {
      for (final path in ['/ignore-range', '/range']) {
        final client = http.Client();
        final cur = await measureCurrent(client, '$base$path', maxBytes);
        final fix = await measureFixed(client, '$base$path', maxBytes);
        client.close();
        final curMbps = (cur.speed ?? 0) * 8 / 1000000;
        final fixMbps = (fix.speed ?? 0) * 8 / 1000000;
        final realMbps = realBytesPerSec * 8 / 1000000;
        // ignore_print
        print('样本 ${(maxBytes / 1024).round()}KB  $path  '
            '现网=${curMbps.toStringAsFixed(1)}Mbps  '
            '修正=${fixMbps.toStringAsFixed(1)}Mbps  '
            '真实=${realMbps.toStringAsFixed(0)}Mbps  '
            '现网/真实=${(curMbps / realMbps).toStringAsFixed(2)}  '
            '修正/真实=${(fixMbps / realMbps).toStringAsFixed(2)}');
      }
    }
  });
}
