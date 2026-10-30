import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/media_resolution_probe.dart';

/// 🔴🔴 2026-10-23 回归测试：从码流 SPS 探测真实分辨率。
///
/// 【背景】资源站大量用「media playlist + AES-128 加密 TS」交付，
/// 播放列表里没有 RESOLUTION，只能靠码率反推分辨率 —— 而码率与分辨率
/// 没有必然关系。
///
/// 【真实样本】`https://play.xluuss.com/play/bW6qx64a/index.m3u8`
///   · 真实分辨率 **1920x818**（宽屏电影，1080P 级别）
///   · 首段 10.417s / 860864 字节 → 码率仅 **661 kbps**
///   · 旧逻辑按码率落档 → 判成 **360P**（错的）
///   · 同一片源在另一站点是 master playlist，写着 RESOLUTION=1920x818
///     → 正确判 1080P —— 同一个视频两个结论。
///
/// fixture 是该源首段的前 96KB（明文 + AES 密文 + key）。
void main() {
  Uint8List readFixture(String name) {
    final f = File('test/fixtures/$name');
    expect(f.existsSync(), isTrue, reason: '缺少 fixture $name');
    return f.readAsBytesSync();
  }

  test('明文 TS 分片能解出真实宽高 1920x818', () {
    final plain = readFixture('seg1920x818_plain.ts');
    final res = MediaResolutionProbe.probe(plain);
    expect(res, isNotNull);
    expect(res!.width, 1920);
    expect(res.height, 818);
  });

  test('AES-128 加密分片解密后同样能解出 1920x818', () {
    final enc = readFixture('seg1920x818_aes.ts');
    final key = readFixture('seg1920x818_key.bin');
    final iv = Uint8List(16); // EXT-X-KEY 里 IV=0x0...0
    final res = MediaResolutionProbe.probe(enc, aesKey: key, aesIv: iv);
    expect(res, isNotNull);
    expect(res!.width, 1920);
    expect(res.height, 818);
  });

  test('不给 key 时加密数据解不出（返回 null，不误报）', () {
    final enc = readFixture('seg1920x818_aes.ts');
    final res = MediaResolutionProbe.probe(enc);
    expect(res, isNull);
  });

  test('非媒体数据（HTML / 文本）不误报分辨率', () {
    final junk = Uint8List.fromList('<html><body>player</body></html>'.codeUnits);
    expect(MediaResolutionProbe.probe(junk), isNull);
    expect(MediaResolutionProbe.probe(Uint8List(0)), isNull);
  });

  test('JPEG 伪视频分片（ly166 源形态）不误报', () {
    // 资源站有用 .jpeg 片段拼伪视频的形态，字节流里没有 TS 同步头，
    // 更没有 SPS —— 必须返回 null 而不是瞎猜一个分辨率。
    final jpeg = Uint8List.fromList(List<int>.generate(4096, (i) => (i * 7) % 256));
    expect(MediaResolutionProbe.probe(jpeg), isNull);
  });
}
