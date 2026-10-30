import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/m3u8_utils.dart';

/// 🔴🔴 2026-10-23 回归测试：分辨率**归类**口径。
///
/// 【用户原话】
/// 「很多视频不是标准的1080、720、480、360分辨率，应该按接近哪个返回哪个，
///   而不是对不上就返回360」
///
/// 【实测背景】
/// 资源站大量用**宽屏电影**分辨率（1920x818 / 1280x546 / 1920x800），
/// 长边是标准档、短边不是。它们走 media playlist，没有 RESOLUTION，
/// 旧逻辑只能按码率落档：
///   `play.xluuss.com` 真实 1920x818，码率仅 661kbps → 判 360P（错）
///   同一片源在另一站点的 master playlist 里写着 RESOLUTION=1920x818 → 判 1080P
///   **同一个视频两个结论**。
///
/// 【修复】
///   1. 真实宽高 → 按**长边最近邻**归到标准档（1920x818 → 1080P）；
///   2. 码率兜底 → 也改成最近邻，不再「对不上就掉最低档」；
///   3. `hd` / `sd` 这类**无数字的别名**不再命中 URL 的 host
///      （`https://hd.kuktxu.com/...` 曾被判 720P）。
void main() {
  group('真实宽高 → 最近邻标准档', () {
    test('宽屏电影 1920x818 → 1080P（长边 1920）', () {
      expect(M3u8Utils.nearestResolutionLabelFromSize(1920, 818), '1080P');
    });

    test('其他宽屏电影尺寸同样按长边归类', () {
      expect(M3u8Utils.nearestResolutionLabelFromSize(1920, 800), '1080P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(1920, 804), '1080P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(1280, 546), '720P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(1280, 536), '720P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(3840, 1600), '4K');
      expect(M3u8Utils.nearestResolutionLabelFromSize(2560, 1080), '2K');
    });

    test('标准档位原样返回', () {
      expect(M3u8Utils.nearestResolutionLabelFromSize(1920, 1080), '1080P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(1280, 720), '720P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(854, 480), '480P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(640, 360), '360P');
    });

    test('竖屏按长边判定（720x1280 → 720P）', () {
      expect(M3u8Utils.nearestResolutionLabelFromSize(720, 1280), '720P');
      expect(M3u8Utils.nearestResolutionLabelFromSize(1080, 1920), '1080P');
    });

    test('非标准长边取最近邻而不是掉到最低档', () {
      // 1152 离 1280(720P) 更近 → 720P
      expect(M3u8Utils.nearestResolutionLabelFromSize(1152, 480), '720P');
      // 960 离 854(480P) 更近 → 480P
      expect(M3u8Utils.nearestResolutionLabelFromSize(960, 540), '480P');
      // 2100 离 1920(1080P) 更近 → 1080P
      expect(M3u8Utils.nearestResolutionLabelFromSize(2100, 900), '1080P');
    });
  });

  group('码率兜底 → 最近邻', () {
    test('不再「对不上就落 360P」', () {
      // 1100kbps 正好落在 480P 档中心
      expect(M3u8Utils.resolutionFromBitrateKbps(1100), '480P');
      // 2200kbps → 720P
      expect(M3u8Utils.resolutionFromBitrateKbps(2200), '720P');
      // 4500kbps → 1080P
      expect(M3u8Utils.resolutionFromBitrateKbps(4500), '1080P');
    });

    test('最近邻：1000kbps 离 1100(480P) 更近 → 480P', () {
      expect(M3u8Utils.resolutionFromBitrateKbps(1000), '480P');
    });

    test('非正码率返回 null', () {
      expect(M3u8Utils.resolutionFromBitrateKbps(0), isNull);
      expect(M3u8Utils.resolutionFromBitrateKbps(-1), isNull);
    });
  });

  group('文本/URL 推断不再误伤', () {
    test('主机名里的 hd 不再被判成 720P', () {
      // 旧逻辑命中 `hd` 别名 → 720P（与视频清晰度毫无关系）
      expect(
        M3u8Utils.extractResolutionFromText('https://hd.kuktxu.com/play/eXD5yD8e'),
        isNull,
      );
      expect(
        M3u8Utils.extractResolutionFromText('https://v.gsuus.com/play/hls/eVOQwOBa/index.m3u8'),
        isNull,
      );
    });

    test('path 里的 hd 目录仍能识别为 720P', () {
      expect(
        M3u8Utils.extractResolutionFromText('https://x.com/hd/index.m3u8'),
        '720P',
      );
    });

    test('URL 里的真实分辨率/码率信号仍有效', () {
      expect(
        M3u8Utils.extractResolutionFromText('https://x.com/1920x818/hls/index.m3u8'),
        '1080P',
      );
      // 🔴 2026-10-23（第八轮）：码率口径也统一成最近邻 ——
      // 3000kbps 离 720P 中心(2200) 差 800、离 1080P 中心(4500) 差 1500
      // → 720P。旧口径（>=2500 就 1080P）会把 3000k 判成 1080P。
      //
      // 注意：**码率本来就不等于分辨率**。实测 `1180kb/hls` 目录的片源
      // 真实分辨率是 1920x818（1080P 级）—— 码率推断只作兜底，
      // 主力是 SPS 实测。宁可标得保守，也不能拿码率当分辨率的证据。
      expect(
        M3u8Utils.extractResolutionFromText('https://x.com/3000k/hls/index.m3u8'),
        '720P',
      );
    });

    test('纯文本标签不受影响', () {
      expect(M3u8Utils.extractResolutionFromText('1080P'), '1080P');
      expect(M3u8Utils.extractResolutionFromText('蓝光'), '1080P');
      expect(M3u8Utils.extractResolutionFromText('高清'), '720P');
    });
  });

  // 🔴 2026-10-23（第八轮）：口径统一回归。
  //
  // 修复前代码里有**三套**分辨率映射并存：
  //   1. `_estimateHeight`（master playlist 变体用）—— 离散阈值 + 宽屏特判；
  //   2. `extractResolutionFromText` 的维度/码率分支 —— 另一套离散阈值；
  //   3. `nearestResolutionLabelFromSize`（SPS 实测用）—— 最近邻。
  //
  // 三套对**同一个尺寸**给出三个不同答案：1200x674 分别是
  // 1080P / 480P / 720P。现在统一到「最近邻」这一个真相源。
  group('三套口径统一', () {
    test('同一尺寸：文本提取 与 最近邻 结论一致', () {
      const sizes = <List<int>>[
        [1920, 818], // 宽屏电影
        [1920, 1080], // 标准
        [1280, 546], // 宽屏
        [864, 368], // 非标准
        [1200, 674], // 旧口径打架的那一档
        [2560, 1080], // 超宽
        [3840, 1600],
        [720, 1280], // 竖屏
      ];
      for (final s in sizes) {
        final w = s[0];
        final h = s[1];
        final bySize = M3u8Utils.nearestResolutionLabelFromSize(w, h);
        final byText = M3u8Utils.extractResolutionFromText('${w}x$h');
        expect(byText, bySize, reason: '${w}x$h 两条路径结论不一致');
      }
    });

    test('master playlist 的 RESOLUTION 与最近邻一致', () async {
      // 本地起 HTTP 服务喂 master playlist，验证「变体 RESOLUTION 路径」
      // 与「SPS 实测路径」结论一致（两者都要走最近邻）。
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = req.uri.path.contains('master')
            ? '#EXTM3U\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=1180000,RESOLUTION=1920x818\n'
                '/child.m3u8\n'
            : '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\n/seg1.ts\n';
        req.response.headers.contentType =
            ContentType('application', 'x-mpegURL', charset: 'utf-8');
        req.response.write(body);
        await req.response.close();
      });
      try {
        final result = await M3u8Utils.analyzeM3u8ForSpeedTest(
          'http://127.0.0.1:${server.port}/master.m3u8',
          timeout: const Duration(seconds: 5),
        );
        expect(result.isMaster, isTrue);
        expect(result.resolution, '1080P');
        expect(
          result.resolution,
          M3u8Utils.nearestResolutionLabelFromSize(1920, 818),
        );
      } finally {
        await server.close(force: true);
      }
    });

    test('master playlist 变体按最近邻清晰度降序（高分辨率在前）', () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final body = req.uri.path.contains('master')
            ? '#EXTM3U\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=500000,RESOLUTION=640x360\n'
                '/low.m3u8\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=1180000,RESOLUTION=1920x818\n'
                '/high.m3u8\n'
                '#EXT-X-STREAM-INF:BANDWIDTH=900000,RESOLUTION=1280x536\n'
                '/mid.m3u8\n'
            : '#EXTM3U\n#EXT-X-TARGETDURATION:10\n#EXTINF:10.0,\n/seg1.ts\n';
        req.response.headers.contentType =
            ContentType('application', 'x-mpegURL', charset: 'utf-8');
        req.response.write(body);
        await req.response.close();
      });
      try {
        final result = await M3u8Utils.analyzeM3u8ForSpeedTest(
          'http://127.0.0.1:${server.port}/master.m3u8',
          timeout: const Duration(seconds: 5),
        );
        // 最高清度的变体（1920x818 → 1080P）必须排在最前并被选中。
        expect(result.resolution, '1080P');
        expect(result.playlistUrl, contains('high.m3u8'));
      } finally {
        await server.close(force: true);
      }
    });
  });
}
