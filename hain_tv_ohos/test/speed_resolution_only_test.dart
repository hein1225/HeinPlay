import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/lunatv_service.dart';

/// 「正在播放的源不测速，只识别分辨率」的单元测试。
///
/// 🔴 2026-10-23：播放中的源流量正被播放器占用，再测一次会让速度值被自身
/// 播放流污染（表现为「一开始播放，源速度就显示很慢」），还会重复占用带宽。
/// 本测试用本地 HTTP 服务器直接验证**服务端有没有收到分片下载请求**。
void main() {
  late HttpServer server;
  late List<String> requestedPaths;

  setUp(() async {
    requestedPaths = [];
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final path = request.uri.path;
      requestedPaths.add(path);
      if (path.endsWith('.m3u8')) {
        request.response.headers.contentType =
            ContentType('application', 'vnd.apple.mpegurl');
        if (path.contains('1080p')) {
          // media playlist：带一个分片
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg1.ts\n',
          );
        } else if (path.contains('media')) {
          // 纯 media playlist：文本与 URL 均无分辨率线索，只能靠码率推算
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg1.ts\n',
          );
        } else {
          // master playlist：指向 1080p 子 playlist
          request.response.write(
            '#EXTM3U\n'
            '#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1920x1080\n'
            '1080p.m3u8\n',
          );
        }
      } else {
        // 分片：返回 1MB 数据
        //
        // ⚠️ 必须显式设置 contentLength：chunked 编码下 Dart 的 HttpServer
        // 会忽略 Range 头（返回 200 且没有 content-length），测不出
        // `Content-Range` 里的分片总大小，码率推算路径就走不通。
        // 真实 CDN 对 Range 请求返回 206 + Content-Range，这里保持一致。
        request.response.headers.contentType = ContentType('video', 'mp2t');
        request.response.contentLength = 1024 * 1024;
        request.response.add(List<int>.filled(1024 * 1024, 0));
      }
      await request.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
  });

  String masterUrl() =>
      'http://${server.address.address}:${server.port}/master.m3u8';

  /// 纯 media playlist（URL 与文本都不含分辨率线索），
  /// 用于验证「码率 → 分辨率」这条推算路径。
  String mediaUrl() =>
      'http://${server.address.address}:${server.port}/media.m3u8';

  group('speedTestEpisode resolutionOnly 模式', () {
    test('只识别分辨率：服务端不会收到任何分片下载请求', () async {
      requestedPaths.clear();
      await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        resolutionOnly: true,
      );

      final segmentRequests =
          requestedPaths.where((p) => p.endsWith('.ts')).toList();
      expect(
        segmentRequests,
        isEmpty,
        reason: '正在播放的源不应被下载测速，实际请求了 $segmentRequests',
      );
      expect(
        requestedPaths.where((p) => p.endsWith('.m3u8')),
        isNotEmpty,
        reason: '仍应请求 M3U8 以识别分辨率',
      );
    });

    test('只识别分辨率：速度标记为 -1.0（可用但速度未知），分辨率可识别', () async {
      final result = await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        resolutionOnly: true,
      );

      expect(result.speed, -1.0);
      expect(result.resolution, isNotNull);
      expect(result.resolution!.toUpperCase(), contains('1080'));
    });

    test('对照：正常模式会下载分片并测出速度', () async {
      requestedPaths.clear();
      final result = await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
      );

      final segmentRequests =
          requestedPaths.where((p) => p.endsWith('.ts')).toList();
      expect(segmentRequests, isNotEmpty, reason: '正常模式应下载分片测速');
      expect(result.speed, isNotNull);
      expect(result.speed, greaterThan(0));
    });

    test('对照：正常模式与只识别模式的服务端请求量差异显著', () async {
      requestedPaths.clear();
      await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        resolutionOnly: true,
      );
      final onlyModeRequests = requestedPaths.length;

      requestedPaths.clear();
      await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
      );
      final normalModeRequests = requestedPaths.length;

      expect(
        onlyModeRequests,
        lessThan(normalModeRequests),
        reason: '只识别模式请求数应少于正常测速（$onlyModeRequests vs $normalModeRequests）',
      );
    });
  });

  group('speedTestEpisode 延迟与速度合并为一次请求', () {
    // 🔴 2026-10-23（第二轮调整）：上一轮 Windows 实测「播放期间测速太慢」，
    // 根因之一是同一个分片被请求了两遍 —— 先用 HEAD 探一次 RTT，再用 GET
    // 下一次样本。每源白付一个完整 RTT（实测 0.6~1.6 秒）。
    // 现在一次请求同时产出首字节延迟与传输速度。
    test('正常模式：分片只被请求 1 次（不再单独发延迟探测）', () async {
      requestedPaths.clear();
      await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
      );

      final segmentRequests =
          requestedPaths.where((p) => p.endsWith('.ts')).toList();
      expect(
        segmentRequests.length,
        1,
        reason: '延迟与速度应合并为一次分片请求，实际请求了 $segmentRequests',
      );
    });

    test('正常模式：合并后仍能测出正速度', () async {
      final result = await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
      );
      expect(result.speed, isNotNull);
      expect(result.speed, greaterThan(0));
      // 响应时间来自合并后的首字节延迟，不应为负
      expect(result.responseTime.inMilliseconds, greaterThanOrEqualTo(0));
    });

    test('只识别分辨率模式：分片至多被请求 1 次（码率估算不再扫 5 片）', () async {
      requestedPaths.clear();
      await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        resolutionOnly: true,
      );

      final segmentRequests =
          requestedPaths.where((p) => p.endsWith('.ts')).toList();
      expect(
        segmentRequests.length,
        lessThanOrEqualTo(1),
        reason: '码率估算探测数应降到 1 片，实际请求了 $segmentRequests',
      );
    });
  });

  // 🔴 2026-10-23（第三轮）：码率估算的请求被**并入测速请求**。
  //
  // 原实现为「按分片码率推断分辨率」单独发一次 Range 请求，与测速请求
  // 串行叠加，高延迟源要多付 1.5~2 秒 RTT —— 这是整轮测速慢的主因之一。
  // 现在解析阶段只读文本里的 #EXTINF 时长，码率改由测速响应头的
  // `Content-Range` 总大小推算。
  group('speedTestEpisode 码率估算并入测速请求（第三轮）', () {
    test('解析阶段不再为码率估算发分片请求', () async {
      requestedPaths.clear();
      await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
      );

      final segmentRequests =
          requestedPaths.where((p) => p.endsWith('.ts')).toList();
      expect(
        segmentRequests.length,
        1,
        reason: '分片只应被测速请求命中 1 次，实际请求了 $segmentRequests',
      );
    });

    test('码率可由测速响应头的总大小推算分辨率', () async {
      // media playlist：URL 与文本都不含分辨率线索，只能靠码率推算。
      final result = await LunaTVService.speedTestEpisode(
        mediaUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
      );
      // 服务端分片固定 1MB、时长 4.0s
      // → 码率 = 1048576 × 8 / 4000 ≈ 2097kbps → 720P
      expect(result.resolution, isNotNull);
      expect(result.resolution, '720P');
    });

    test('取消令牌生效：取消后不再发出分片请求', () async {
      requestedPaths.clear();
      final token = SpeedTestCancelToken()..cancel();
      final result = await LunaTVService.speedTestEpisode(
        masterUrl(),
        sourceType: 'test-source',
        sampleBytes: 128 * 1024,
        maxConcurrency: 1,
        cancelToken: token,
      );
      expect(
        requestedPaths.where((p) => p.endsWith('.ts')).isEmpty,
        isTrue,
        reason: '已取消的源不应再发分片请求，实际请求了 $requestedPaths',
      );
      // 语义：可用但速度未知（-1.0）
      expect(result.speed, -1.0);
    });
  });
}
