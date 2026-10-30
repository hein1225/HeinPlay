import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/m3u8_utils.dart';

/// 「HTML 播放器页入口」的单元测试。
///
/// 🔴🔴 2026-10-23（Windows 真机复现）：
///   源 jinyingzy.com 的播放地址 `https://hd.kuktxu.com/play/eXD5yD8e`
///   **没有 .m3u8 后缀**，服务器返回 1593 字节的 HTML 播放器页
///   （content-type: text/html），页面内用 hls.js 播
///   `https://hd.kuktxu.com/play/eXD5yD8e/index.m3u8`。
///
/// 旧逻辑按「URL 后缀」判定，导致三个症状：
///   1. 测速走 direct 分支，1ms 下载完 1593 字节 HTML → **假 18MB/s**，
///      界面把一个实际一播放就卡死的源显示成最快的源；
///   2. 播放时跳过本地代理，mpv 直连 HTML → **画面卡住**；
///   3. HTML 页没有时长信息 → **总时间读不出来**。
void main() {
  group('M3u8Utils.extractM3u8FromHtml', () {
    test('提取 hls.js loadSource 里的 m3u8（真机实测结构）', () {
      const html = '''
<head>
    <meta charset="utf-8">
    <script src="https://s2.pstatp.com/cdn/expire-1-M/hls.js/1.1.5/hls.min.js"></script>
</head>
<body>
<script>
    var videoConfig = {
        url: "https://hd.kuktxu.com/play/eXDMQ2Ve/index.m3u8",
        type: 'hls'
    };
    hls.loadSource(url);
</script>
</body>
''';
      expect(
        M3u8Utils.extractM3u8FromHtml(
          html,
          baseUrl: 'https://hd.kuktxu.com/play/eXDMQ2Ve',
        ),
        'https://hd.kuktxu.com/play/eXDMQ2Ve/index.m3u8',
      );
    });

    test('提取单引号写法', () {
      const html = "var url = 'https://a.example.com/hls/x/index.m3u8';";
      expect(
        M3u8Utils.extractM3u8FromHtml(html, baseUrl: 'https://a.example.com/'),
        'https://a.example.com/hls/x/index.m3u8',
      );
    });

    test('还原 JSON 转义的 \\/ 写法', () {
      const html = r'{"url":"https:\/\/a.example.com\/x\/index.m3u8"}';
      expect(
        M3u8Utils.extractM3u8FromHtml(html, baseUrl: 'https://a.example.com/'),
        'https://a.example.com/x/index.m3u8',
      );
    });

    test('相对路径按 baseUrl 解析', () {
      const html = 'var url = "./index.m3u8";';
      expect(
        M3u8Utils.extractM3u8FromHtml(html, baseUrl: 'https://a.example.com/p/'),
        'https://a.example.com/p/index.m3u8',
      );
    });

    test('页面里没有 m3u8 时返回 null', () {
      expect(
        M3u8Utils.extractM3u8FromHtml(
          '<html><body>404</body></html>',
          baseUrl: 'https://a.example.com/',
        ),
        isNull,
      );
    });
  });

  group('内容判定', () {
    test('HTML 播放器页（真机结构，无 <html> 标签）判定为 HTML', () {
      const html = '<head>\n<meta charset="utf-8">\n</head>';
      expect(M3u8Utils.looksLikeHtmlContent(html), isTrue);
    });

    test('m3u8 文本不判定为 HTML', () {
      expect(
        M3u8Utils.looksLikeHtmlContent('#EXTM3U\n#EXT-X-TARGETDURATION:4\n'),
        isFalse,
      );
    });

    test('m3u8 内容识别', () {
      expect(
        M3u8Utils.looksLikeM3u8Content('#EXTM3U\n'),
        isTrue,
      );
      expect(M3u8Utils.looksLikeM3u8Content('<head>'), isFalse);
    });

    test('直链媒体后缀识别（用于决定是否需要嗅探）', () {
      expect(
        M3u8Utils.looksLikeDirectMediaUrl('https://a.com/v/1.mp4'),
        isTrue,
      );
      expect(
        M3u8Utils.looksLikeDirectMediaUrl('https://a.com/play/eXD5yD8e'),
        isFalse,
      );
      expect(
        M3u8Utils.looksLikeDirectMediaUrl(
          'https://a.com/play/eXD5yD8e/index.m3u8',
        ),
        isFalse,
      );
    });
  });

  group('speedTestEpisode 处理 HTML 播放器页入口', () {
    late HttpServer server;
    late List<String> requestedPaths;

    setUp(() async {
      requestedPaths = [];
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        final path = request.uri.path;
        requestedPaths.add(path);
        if (path.endsWith('/index.m3u8')) {
          request.response.headers.contentType = ContentType(
            'application',
            'vnd.apple.mpegurl',
          );
          request.response.write(
            '#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.0,\nseg1.ts\n',
          );
        } else if (path.endsWith('.ts') || path.endsWith('.mp4')) {
          request.response.headers.contentType =
              ContentType('video', path.endsWith('.ts') ? 'mp2t' : 'mp4');
          request.response.add(List<int>.filled(300 * 1024, 0x11));
        } else {
          // HTML 播放器页入口
          request.response.headers.contentType =
              ContentType.html;
          request.response.write(
            '<head><meta charset="utf-8"></head>'
            '<script>var url = "http://127.0.0.1:${server.port}/index.m3u8";</script>',
          );
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('HTML 入口页会被嗅探出内嵌 m3u8 并按分片测速（不再是假高速）', () async {
      final entryUrl = 'http://127.0.0.1:${server.port}/play/eXD5yD8e';
      final result = await LunaTVService.speedTestEpisode(
        entryUrl,
        timeout: const Duration(seconds: 10),
        sampleBytes: 64 * 1024,
        maxConcurrency: 1,
      );

      // 必须真的请求了内嵌的 m3u8
      expect(requestedPaths, contains('/index.m3u8'));
      // 必须对分片做了测速（而不是直接下载 HTML 页面）
      expect(requestedPaths.any((p) => p.endsWith('.ts')), isTrue);

      // 🔴 关键断言：速度必须来自**分片**，而不是 HTML 页面。
      // （环回网络下分片本来就极快，速度数值本身没有参考意义，
      //   所以这里断言「请求了分片」而不是断言具体速度。）
      final speed = result.speed;
      expect(speed, isNotNull);
      expect(speed, isNot(-1.0));
      expect(speed, greaterThan(0));
    });

    test('直链媒体地址不做 HTML 嗅探（不额外发请求）', () async {
      // .mp4 结尾 → looksLikeDirectMediaUrl=true → 不嗅探
      final result = await LunaTVService.speedTestEpisode(
        'http://127.0.0.1:${server.port}/video.mp4',
        timeout: const Duration(seconds: 10),
        sampleBytes: 64 * 1024,
        maxConcurrency: 1,
      );
      expect(requestedPaths, isNot(contains('/index.m3u8')));
      expect(result.speed, isNotNull);
    });
  });

  group('文本响应不得产生速度值', () {
    late HttpServer server;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.headers.contentType = ContentType.html;
        request.response.write('<html><body>x</body></html>');
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
    });

    test('下到 HTML 时速度为 null（而不是假高速）', () async {
      final result = await LunaTVService.speedTestEpisode(
        'http://127.0.0.1:${server.port}/page.html',
        timeout: const Duration(seconds: 10),
        sampleBytes: 64 * 1024,
        maxConcurrency: 1,
      );
      expect(result.speed, isNull);
    });
  });
}
