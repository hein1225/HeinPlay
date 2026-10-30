// 🔴 2026-10-24（第十三轮）：**起播裁剪列表**的端到端验证。
//
// 目的：证明「代理返回的 playlist 第 0 片 == 落点片」，从而 AVPlayer 可以
//       从落点直接起播、**完全不需要 seek**（避开 PREPARED 态 seek 的 5400103
//       以及「等 initialized ⇒ 等 PLAYING ⇒ 等 texture」的三方死锁）。
//
// 验收判据：
//   ① 返回体首行必须是 #EXTM3U（AVPlayer 才认它是播放列表）；
//   ② 必须保留 #EXT-X-KEY（本片源是 AES-128 加密，缺 key 直接播不了）；
//   ③ 第 0 片必须是**落点片**（与完整列表里 944000ms 对应的那一片同一 URL）；
//   ④ 段数必须比完整列表少（确实裁掉了落点之前的片）；
//   ⑤ trimOffsetMs 必须等于落点片在用户轴上的起点（轴换算的基准）。
//
// 跑法：cd hain_tv_ohos && flutter test test/start_trim_verify_test.dart
// （需要容器内能访问该 CDN；网络不通时本测试会 fail 而不是静默跳过。）

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/local_m3u8_proxy.dart';

const _kSource = 'https://vod1.maowushi.com/20260916/q5fnZoph/index.m3u8';
const _kStartMs = 944000;

Future<String> _fetch(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close();
    if (resp.statusCode != 200) {
      throw HttpException('HTTP ${resp.statusCode} $url');
    }
    return await resp.transform(utf8.decoder).join();
  } finally {
    client.close(force: true);
  }
}

/// 从 playlist 文本里取媒体段的 URL（代理形式 /segment?url=...）。
List<String> _mediaUrls(String playlist) => playlist
    .split('\n')
    .map((l) => l.trim())
    .where((l) => l.isNotEmpty && !l.startsWith('#'))
    .toList();

void main() {
  test('起播裁剪：playlist 第 0 片 == 落点片（944000ms）', () async {
    final proxy = LocalM3u8Proxy();
    final base = await proxy.start();
    addTearDown(() async => proxy.stop());

    // avp 专属快起播模式（裁剪的门控条件）。
    proxy.setAvPlayerFastStart(true);

    final master = await _fetch(_kSource);
    expect(master, isNotEmpty, reason: 'master 拉取失败');
    // 真机链路里，master 在交给代理前已由 AdFilterEngine 把相对 URL 解析成
    // 绝对地址（LocalM3u8Proxy.resolveRelativeUrls）—— 否则代理展开变体时
    // 会拿到 "/20260916/.../index.m3u8" 这种无 host 的 URI 而失败。
    final resolved = LocalM3u8Proxy.resolveRelativeUrls(master, _kSource);
    proxy.setPlaylist(resolved, const {}, prefetch: true);

    // 落点定位：与真机一致的 944000ms。分片表此刻未就绪 ⇒ 代理内部挂起，
    // 待收集完分片表后补做。
    proxy.primePrefetchAt(const Duration(milliseconds: _kStartMs));

    // ① 完整列表（触发 master 展开 + 分片表收集 + 裁剪）。
    final trimmed = await _fetch('$base/playlist.m3u8');
    final trimmedLines = trimmed.trim().split('\n');

    // 判据 ①：首行必须是 #EXTM3U。
    expect(
      trimmedLines.first.trim(),
      '#EXTM3U',
      reason: '裁剪后首行必须是 #EXTM3U（否则 AVPlayer 不认这是播放列表）',
    );

    // 判据 ②：必须保留 #EXT-X-KEY（AES-128 加密源，缺 key 播不了）。
    expect(
      trimmed.contains('#EXT-X-KEY'),
      isTrue,
      reason: '裁剪后必须保留 #EXT-X-KEY（否则 AVPlayer 取不到解密密钥）',
    );

    final trimmedSegs = _mediaUrls(trimmed);
    expect(trimmedSegs, isNotEmpty, reason: '裁剪后没有媒体段');

    // 判据 ⑤：偏移必须已确定。
    final offset = proxy.trimOffsetMs;
    expect(
      offset,
      isNotNull,
      reason: 'trimOffsetMs 未确定：代理没有算出落点下标',
    );
    expect(
      offset!,
      lessThanOrEqualTo(_kStartMs),
      reason: 'offset（落点片起点）不应大于落点时间',
    );
    expect(
      _kStartMs - offset,
      lessThan(10000),
      reason: 'offset 与落点时间相差过大（落点片定位错误）',
    );

    // 判据 ③ + ④：第 0 片必须是落点片，且段数比完整列表少。
    //   完整列表：临时把裁剪关掉再取一次。
    proxy.setAvPlayerFastStart(false);
    final full = await _fetch('$base/playlist.m3u8');
    final fullSegs = _mediaUrls(full);

    expect(
      trimmedSegs.length,
      lessThan(fullSegs.length),
      reason: '裁剪后段数应少于完整列表（${trimmedSegs.length} vs '
          '${fullSegs.length}）',
    );

    // 落点片在完整列表里的下标：按累计时长二分找到覆盖 _kStartMs 的那一段。
    final extinf = RegExp(r'#EXTINF:\s*([\d.]+)');
    final starts = <int>[];
    var acc = 0;
    var pending = 0.0;
    var hasPending = false;
    for (final raw in full.trim().split('\n')) {
      final t = raw.trim();
      if (t.startsWith('#EXTINF')) {
        final m = extinf.firstMatch(t);
        pending = m != null ? double.parse(m.group(1)!) : 0;
        hasPending = true;
        continue;
      }
      if (t.isEmpty || t.startsWith('#')) continue;
      starts.add(acc);
      acc += hasPending ? (pending * 1000).round() : 0;
      hasPending = false;
    }
    var expectIdx = -1;
    for (var i = 0; i < starts.length; i++) {
      final end = (i + 1 < starts.length) ? starts[i + 1] : acc;
      if (_kStartMs >= starts[i] && _kStartMs < end) {
        expectIdx = i;
        break;
      }
    }
    expect(expectIdx, greaterThanOrEqualTo(0), reason: '完整列表里找不到落点片');
    expect(
      trimmedSegs.first,
      fullSegs[expectIdx],
      reason: '裁剪后第 0 片（${trimmedSegs.first}）'
          '≠ 落点片（完整列表第 $expectIdx 片：${fullSegs[expectIdx]}）',
    );
    expect(
      starts[expectIdx],
      offset,
      reason: 'offset（$offset）应等于落点片在用户轴上的起点（${starts[expectIdx]}）',
    );

    // 🔴🔴🔴 2026-10-24（第十五轮）：**裁剪后第 0 片必须有 #EXTINF**。
    //
    // 【真机实证】hilog 2026-10-24 21:50:14（13-50-45.txt）：
    //   21:50:14.333 seekTo: target=0ms mode=SEEK_NEXT_SYNC current=3652ms
    //   21:50:14.504 bindState, avplayerStatus=error
    //   21:50:14.506 AvPlayer Avoid Error Reporting: {"code":5400103}  ← IO 错误
    // ⇒ AVPlayer 在 seek 后进入 error 态且不可恢复 ⇒ 表现为「快进快退永久卡死」。
    //
    // 根因：裁剪从落点片的 **URL 行**开始保留，落点片的 `#EXTINF` 被丢弃
    // ⇒ 顺序播放能容忍（起播正常），但 **seek 需要完整索引** ⇒ 定位失败。
    final tl = trimmed.split('\n');
    final firstUrlIdx = tl.indexWhere(
      (l) => l.trim().isNotEmpty && !l.trim().startsWith('#'),
    );
    expect(firstUrlIdx, greaterThan(0));
    expect(
      tl[firstUrlIdx - 1].trim(),
      startsWith('#EXTINF'),
      reason: '裁剪后第 0 片缺少 #EXTINF ⇒ seek 时索引损坏 ⇒ 5400103 ⇒ 卡死',
    );
    // 全表 EXTINF 数 == 分片 URL 数
    final extinfCount = tl
        .where((l) => l.trim().startsWith('#EXTINF'))
        .length;
    expect(
      extinfCount,
      trimmedSegs.length,
      reason: '裁剪后 EXTINF 数应等于分片数',
    );

    // eslint-disable-next-line avoid_print
    print('✅ 裁剪验证通过：完整 ${fullSegs.length} 片 → 裁剪 ${trimmedSegs.length} 片，'
        '第 0 片 = 落点片(下标 $expectIdx)，offset=${offset}ms，'
        '第 0 片 EXTINF=${trimmedLines[firstUrlIdx - 1].trim()}');
  }, timeout: const Timeout(Duration(minutes: 3)));
}
