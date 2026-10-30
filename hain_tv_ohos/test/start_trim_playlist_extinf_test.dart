// 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，第十五轮）：起播裁剪列表的
// **EXTINF/URL 配对回归测试**。
//
// 【为什么必须有这个测试】
// 真机 hilog 2026-10-24 21:50:14（13-50-45.txt）：
//   21:50:14.333 seekTo: target=0ms mode=SEEK_NEXT_SYNC current=3652ms
//   21:50:14.504 bindState, avplayerStatus=error
//   21:50:14.506 AvPlayer Avoid Error Reporting: {"code":5400103}  ← IO 错误
// ⇒ AVPlayer 在 seek 后进入 error 态且不可恢复 ⇒ 表现为「快进快退永久卡死」。
//
// 根因：裁剪从落点片的 **URL 行**开始保留，落点片的 `#EXTINF` 被丢弃
// ⇒ 裁剪后列表第 0 片没有 #EXTINF
// ⇒ 顺序播放能容忍（起播正常 2432ms），但 **seek 需要完整索引** ⇒ 定位失败。
//
// 本测试锁死「每个分片 URL 前必有 #EXTINF」这条不变量，防止回归。
//
// 用例数据取自真实源（已改写成代理的 /segment?url= 形式）：
//   https://vod1.maowushi.com/20260916/q5fnZoph/1125kb/hls/index.m3u8
import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/local_m3u8_proxy.dart';

const _cdnBase = 'https://vod1.maowushi.com/20260916/q5fnZoph/1125kb/hls';

String _proxyUrl(String file) =>
    '/segment?url=${Uri.encodeComponent('$_cdnBase/$file')}';

/// 构造一份「代理改写后」的 media playlist（结构与真实输出一致）。
List<String> _buildPlaylist(List<String> files, List<String> extinf) {
  final lines = <String>[
    '#EXTM3U',
    '#EXT-X-VERSION:3',
    '#EXT-X-TARGETDURATION:4',
    '#EXT-X-PLAYLIST-TYPE:VOD',
    '#EXT-X-MEDIA-SEQUENCE:0',
    '#EXT-X-KEY:METHOD=AES-128,URI="$_cdnBase/key.key",IV=0x00',
  ];
  for (var i = 0; i < files.length; i++) {
    lines.add('#EXTINF:${extinf[i]},');
    lines.add(_proxyUrl(files[i]));
  }
  lines.add('#EXT-X-ENDLIST');
  return lines;
}

void main() {
  const files = ['a.ts', 'b.ts', 'c.ts', 'd.ts', 'e.ts', 'f.ts'];
  const extinf = ['3.52', '2', '1.68', '2.52', '1.2', '2.8'];

  /// 校验：每个分片 URL 行前面紧邻的标签行必须是 #EXTINF。
  List<String> _findOrphanSegmentUrls(String playlist) {
    final lines = playlist.split('\n');
    final orphans = <String>[];
    for (var i = 0; i < lines.length; i++) {
      final t = lines[i].trim();
      if (t.isEmpty || t.startsWith('#')) continue;
      // 找到这个 URL 行的上一非空标签
      var j = i - 1;
      while (j >= 0 && lines[j].trim().isEmpty) {
        j--;
      }
      final prev = j >= 0 ? lines[j].trim() : '';
      if (!prev.startsWith('#EXTINF')) orphans.add(t);
    }
    return orphans;
  }

  test('裁剪后列表：落点片必须带 #EXTINF（第十五轮回归）', () {
    final playlist = _buildPlaylist(files, extinf).join('\n');
    // 落点 = 第 2 片（c.ts），下标 2
    final trimmed = applyStartTrimToPlaylist(
      playlist,
      startIndex: 2,
      targetCdnUrl: '$_cdnBase/c.ts',
    );
    expect(trimmed, isNotNull, reason: '应能找到落点片');

    final lines = trimmed!.split('\n');
    // 第 0 个分片 URL 前面必须是 #EXTINF
    final firstUrlIdx = lines.indexWhere(
      (l) => l.trim().isNotEmpty && !l.trim().startsWith('#'),
    );
    expect(firstUrlIdx, greaterThan(0));
    expect(
      lines[firstUrlIdx - 1].trim(),
      startsWith('#EXTINF'),
      reason: '第 0 片必须有 #EXTINF（否则 seek 时索引损坏 → 5400103 → 卡死）',
    );
    // 落点片时长被保留
    expect(lines[firstUrlIdx - 1].trim(), '#EXTINF:1.68,');
    // 落点片 URL 就是 c.ts
    expect(extractCdnUrlFromProxyUrl(lines[firstUrlIdx].trim()),
        '$_cdnBase/c.ts');

    // 全文没有任何「孤儿」分片 URL
    expect(_findOrphanSegmentUrls(trimmed), isEmpty);
  });

  test('裁剪后列表：EXTINF 个数 == 分片 URL 个数', () {
    final playlist = _buildPlaylist(files, extinf).join('\n');
    final trimmed = applyStartTrimToPlaylist(
      playlist,
      startIndex: 2,
      targetCdnUrl: '$_cdnBase/c.ts',
    )!;
    final lines = trimmed.split('\n');
    final extinfCount = lines.where((l) => l.trim().startsWith('#EXTINF')).length;
    final urlCount = lines
        .where((l) => l.trim().isNotEmpty && !l.trim().startsWith('#'))
        .length;
    expect(extinfCount, urlCount,
        reason: 'EXTINF 与分片 URL 必须一一对应');
    expect(extinfCount, 4, reason: '落点片及其后的 3 片');
  });

  test('裁剪后列表：头部标签保留 + MEDIA-SEQUENCE 重写为落点下标', () {
    final playlist = _buildPlaylist(files, extinf).join('\n');
    final trimmed = applyStartTrimToPlaylist(
      playlist,
      startIndex: 2,
      targetCdnUrl: '$_cdnBase/c.ts',
    )!;
    expect(trimmed, contains('#EXTM3U'));
    expect(trimmed, contains('#EXT-X-VERSION:3'));
    expect(trimmed, contains('#EXT-X-TARGETDURATION:4'));
    expect(trimmed, contains('#EXT-X-KEY:METHOD=AES-128'),
        reason: 'AES-128 加密源必须保留 KEY 标签，否则 AVPlayer 拿不到 key');
    expect(trimmed, contains('#EXT-X-MEDIA-SEQUENCE:2'));
    expect(trimmed, isNot(contains('#EXT-X-MEDIA-SEQUENCE:0')));
    expect(trimmed.split('\n').last.trim(), '#EXT-X-ENDLIST');
  });

  test('裁剪后列表：落点之前的内容全部丢弃（时间轴从 0 起算）', () {
    final playlist = _buildPlaylist(files, extinf).join('\n');
    final trimmed = applyStartTrimToPlaylist(
      playlist,
      startIndex: 2,
      targetCdnUrl: '$_cdnBase/c.ts',
    )!;
    // 注意：代理 URL 里是 **URL 编码** 过的 CDN 地址，故按编码串断言。
    final enc = (String f) => Uri.encodeComponent('$_cdnBase/$f');
    expect(trimmed, isNot(contains(enc('a.ts'))));
    expect(trimmed, isNot(contains(enc('b.ts'))));
    expect(trimmed, contains(enc('c.ts')));
    expect(trimmed, contains(enc('f.ts')));
  });

  test('找不到落点片时返回 null（调用方回退完整列表）', () {
    final playlist = _buildPlaylist(files, extinf).join('\n');
    final trimmed = applyStartTrimToPlaylist(
      playlist,
      startIndex: 2,
      targetCdnUrl: '$_cdnBase/not_exist.ts',
    );
    expect(trimmed, isNull);
  });

  test('extractCdnUrlFromProxyUrl：能正确解出 CDN 原始 URL', () {
    expect(extractCdnUrlFromProxyUrl(_proxyUrl('x.ts')), '$_cdnBase/x.ts');
    expect(extractCdnUrlFromProxyUrl('/segment?url='), '');
    expect(extractCdnUrlFromProxyUrl('not a url'), '');
  });
}
