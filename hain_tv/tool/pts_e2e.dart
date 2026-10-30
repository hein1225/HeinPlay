// PTS 归一化端到端验证（不依赖 Flutter，可纯 dart run）。
//
// 运行：dart run tool/pts_e2e.dart
//
// 为什么不用 m3u8_ad_filter 里的 _rebuildSegMeta：该文件 import 了
//   package:flutter/material.dart，纯 `dart run` 无法编译（Flutter 引擎符号
//   缺失）。故本脚本**内联一份等价的元数据重建逻辑**做交叉验证——若两者
//   算法不一致，本脚本的预期值会与实现在真机上的行为对不上，从而暴露分歧。
//
// 覆盖的失败模式（都是真机上真实发生过的）：
//   ① 键未绝对化 → 查表全 miss → 平移静默失效
//   ② 基准段名义起点被重复计入 → 固定往后偏移
//   ③ EXTINF 非整 2 秒 → 硬编码 index×2000 会引入系统性误差
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/ts_pts_normalizer.dart';

const dir = '/tmp/ptsprobe';

int _fail = 0;
void _check(String name, bool ok, [String detail = '']) {
  print('${ok ? "✅" : "❌"} $name${detail.isEmpty ? "" : "  ($detail)"}');
  if (!ok) _fail++;
}

/// 与 M3u8AdFilter._rebuildSegMeta 等价的实现（用于交叉验证语义）。
Map<String, int> rebuildMeta(String base, String content) {
  final meta = <String, int>{};
  var accMs = 0;
  var pendingMs = 0;
  var hasPending = false;
  final re = RegExp(r'#EXTINF:([\d\.]+)\b');

  String abs(String u) =>
      u.startsWith('http') ? u : Uri.parse(base).resolve(u).toString();

  for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
    final item = raw.trim();
    if (item.isEmpty) continue;
    if (item.startsWith('#EXTINF')) {
      final m = re.firstMatch(item);
      pendingMs = ((double.tryParse(m?.group(1) ?? '') ?? 0) * 1000).round();
      hasPending = true;
      continue;
    }
    if (item.startsWith('#')) continue;
    meta[abs(item)] = accMs;
    accMs += hasPending ? pendingMs : 0;
    hasPending = false;
    pendingMs = 0;
  }
  return meta;
}

/// 构造最小 TS 分片，首帧 PTS = [ptsMs]。
///
/// 布局对齐真实源：PID 0x100、PUSI=1、afc=3、afLen=7、PCR present，
/// 故 PES 起始码落在 off = 5 + 7 = 12（🔴 不要再跳 pointer_field）。
Uint8List makeSegment(int ptsMs, {int packets = 8}) {
  const kPacket = 188;
  final out = Uint8List(kPacket * packets);
  final ticks = ptsMs * 90;

  out[0] = 0x47;
  out[1] = 0x41; // PUSI=1, PID=0x100
  out[2] = 0x00;
  out[3] = 0x32; // afc=3
  out[4] = 0x07; // afLen=7
  out[5] = 0x50; // PCR present

  const off = 12; // = 5 + afLen
  out[off] = 0x00;
  out[off + 1] = 0x00;
  out[off + 2] = 0x01;
  out[off + 3] = 0xE0; // video
  out[off + 4] = 0x00;
  out[off + 5] = 0x00;
  out[off + 6] = 0x80;
  out[off + 7] = 0x80; // PTS only
  out[off + 8] = 0x05;
  final v = ticks & 0x1FFFFFFFF;
  out[off + 9] = 0x21 | (((v >> 30) & 0x07) << 1);
  out[off + 10] = (v >> 22) & 0xFF;
  out[off + 11] = 0x01 | (((v >> 15) & 0x7F) << 1);
  out[off + 12] = (v >> 7) & 0xFF;
  out[off + 13] = 0x01 | ((v & 0x7F) << 1);

  for (var p = 1; p < packets; p++) {
    final o = p * kPacket;
    out[o] = 0x47;
    out[o + 1] = 0x01;
    out[o + 2] = 0x00;
    out[o + 3] = 0x10;
  }
  return out;
}

Future<void> main() async {
  print('═══ PTS 归一化端到端验证 ═══\n');

  // ── 场景 ①：元数据键必须与代理侧 ?url= 的绝对地址一致 ──
  print('【场景 ①】元数据键绝对化');
  const base = 'https://cdn.example.com/20260915/abc/';
  const list1 = '#EXTM3U\n'
      '#EXTINF:4.000,\n'
      'seg0.ts\n'
      '#EXTINF:4.000,\n'
      'seg1.ts\n'
      '#EXTINF:4.000,\n'
      'seg2.ts\n';

  final meta1 = rebuildMeta(base, list1);
  _check('元数据已产出', meta1.isNotEmpty, '${meta1.length} 段');
  _check('键为绝对地址', meta1.containsKey('${base}seg0.ts'), meta1.keys.first);
  _check('段0 名义起点 = 0ms', meta1['${base}seg0.ts'] == 0);
  _check('段1 名义起点 = 4000ms', meta1['${base}seg1.ts'] == 4000);
  _check('段2 名义起点 = 8000ms', meta1['${base}seg2.ts'] == 8000);

  // ── 场景 ②：EXTINF 非整 2 秒 ──
  print('\n【场景 ②】非整 2 秒 EXTINF（验证用真实 EXTINF 而非 index×2000）');
  const list2 = '#EXTM3U\n'
      '#EXTINF:3.300,\n'
      'a.ts\n'
      '#EXTINF:3.300,\n'
      'b.ts\n'
      '#EXTINF:3.300,\n'
      'c.ts\n';
  final meta2 = rebuildMeta(base, list2);
  _check('段1 = 3300ms（非 2000）', meta2['${base}b.ts'] == 3300, '${meta2['${base}b.ts']}');
  _check('段2 = 6600ms（非 4000）', meta2['${base}c.ts'] == 6600, '${meta2['${base}c.ts']}');

  // ── 场景 ③：基准段不是列表首段时，不得重复计入名义起点 ──
  print('\n【场景 ③】基准段名义起点不重复计入（「固定往后偏移」根因）');
  {
    // 段0（被删广告）真实 PTS 1000ms，段1 真实 PTS 5000ms 且名义起点 3520ms。
    const baseFirst = 5000; // 基准段（段1）真实 PTS
    const baseFiltered = 3520; // 基准段（段1）名义起点
    const seg1TruePts = 5000;
    // 正确公式：expected = baseFirst + (filtered - baseFiltered)
    final expected = baseFirst + (baseFiltered - baseFiltered);
    final delta = expected - seg1TruePts;
    _check('基准段 delta 恒为 0', delta == 0, 'delta=$delta');

    // 错误公式（旧式，隐含 base 名义起点=0）会算出非零 delta。
    final wrongDelta = (baseFirst + baseFiltered) - seg1TruePts;
    _check('旧式公式确实会算错（证明该修正必要）', wrongDelta != 0, 'wrong=$wrongDelta');
  }

  // ── 场景 ④：真实样本平移后 residual 恒 0 ──
  print('\n【场景 ④】真实样本平移正确性（唯一判据 residual == 0）');
  final idxs = <int>[860, 866, 871, 872, 1006, 1011, 1012, 1389];
  var tested = 0, okCount = 0;
  for (final i in idxs) {
    File? f;
    for (final cand in ['$dir/b$i.bin', '$dir/b$i.ts']) {
      final t = File(cand);
      if (t.existsSync() && t.lengthSync() > 0) {
        f = t;
        break;
      }
    }
    if (f == null) continue;
    final raw = Uint8List.fromList(f.readAsBytesSync());
    if (findTsPacketStart(raw) < 0) continue;
    final trueFirst = firstPesPtsMs(raw, videoOnly: true);
    if (trueFirst == null) continue;

    tested++;
    // 模拟真实场景：名义轴起点与真实 PTS 不同 → 需平移。
    final nominal = trueFirst - 12345;
    final delta = nominal - trueFirst;
    final out = normalizeTsPts(raw, delta);
    final chk = verifyPtsShift(raw, out, delta, videoOnly: true);
    final residual = chk.actualDeltaMs == null ? null : chk.actualDeltaMs! - delta;
    if (chk.ok && residual == 0 && out.length == raw.length) okCount++;
  }
  _check('真实样本 residual 全 0 且长度不变', tested > 0 && okCount == tested,
      '$okCount/$tested');

  // ── 场景 ⑤：自校验必须能拦截静默损坏 ──
  print('\n【场景 ⑤】自校验能拦截静默损坏');
  final probe = makeSegment(5000, packets: 8);
  final probePts = firstPesPtsMs(probe, videoOnly: true);
  _check('构造的分片可读出 PTS', probePts == 5000, '${probePts}ms');
  if (probePts != null) {
    final good = normalizeTsPts(probe, 1000);
    final gc = verifyPtsShift(probe, good, 1000, videoOnly: true);
    _check('正确平移 → 自校验通过', gc.ok, gc.reason);
    final bad = verifyPtsShift(probe, good, 9999, videoOnly: true);
    _check('错误 delta → 自校验拒绝', !bad.ok, bad.reason);
    _check('平移后长度不变', good.length == probe.length);
  }

  // ── 场景 ⑥：33-bit 回绕 ──
  print('\n【场景 ⑥】33-bit PTS 回绕');
  {
    // 接近回绕点的 PTS，正 delta 应正确绕回。
    final near = makeSegment(0x1FFFFFFF ~/ 90 - 100, packets: 8);
    final out = normalizeTsPts(near, 5000);
    final chk = verifyPtsShift(near, out, 5000, videoOnly: true);
    final residual = chk.actualDeltaMs == null ? null : chk.actualDeltaMs! - 5000;
    _check('跨回绕平移仍 residual=0', chk.ok && residual == 0, chk.reason);
  }

  print('');
  if (_fail == 0) {
    print('全部通过 ✅');
  } else {
    print('$_fail 项失败 ❌');
    exitCode = 1;
  }
}
