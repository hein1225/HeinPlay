// 🔴 2026-10-24：**流式平移**与**整段平移**的逐字节等价性验证。
//
// 【为什么必须验证】PTS 平移要逐包定位 PES 头并改写 PTS/DTS/PCR。
//   整段路径（normalizeTsPts）与流式路径（shiftTsStream）若实现分叉，
//   会出现「长度不变、无异常、无日志」的**静默损坏**
//   （播放器只表现为花屏 / 音画不同步 / 时长异常，排查成本极高）。
//   故必须用**真实分片字节**证明两条路径结果完全一致。
//
// 【验证项】
//   ① 流式平移结果 == 整段平移结果（逐字节）；
//   ② 流式平移后首帧 PTS 差 == delta；
//   ③ 不规则 chunk 切分（模拟真实网络分片）不改变结果；
//   ④ 含前置垃圾字节的输入两条路径也一致。
//
// 运行：dart run tool/flow_shift_verify.dart
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/ts_pts_normalizer.dart';

/// 本片源的一个真实分片（1066kb 变体，正片中段，非断点段）。
const String kSegUrl =
    'https://bf.modujx17.com/20260915/ZDZnPg2F/1066kb/hls/B49MFgP5.ts';

/// 用 curl 取字节（Dart HttpClient 与该源站 TLS 握手失败，见 pts_axis_probe）。
Future<Uint8List> fetch(String url) async {
  final r = await Process.run(
    'curl',
    ['-sS', '--max-time', '40', '-H', 'User-Agent: Mozilla/5.0', url],
    // ⚠️ 必须 `stdoutEncoding: null` —— 否则 Process.run 会把 stdout 按 UTF-8
    //   解码，二进制 TS 字节会被破坏（抛 FormatException: Missing extension byte）。
    stdoutEncoding: null,
  );
  if (r.exitCode != 0) {
    throw StateError('curl 失败 exit=${r.exitCode}: ${r.stderr}');
  }
  final out = r.stdout as List<int>;
  if (out.isEmpty) throw StateError('下载为空');
  return Uint8List.fromList(out);
}

/// 把字节流按不规则长度切块（模拟真实网络 chunk），**必须覆盖全部数据**。
Stream<Uint8List> chunked(Uint8List data, List<int> sizes) async* {
  var off = 0;
  var k = 0;
  while (off < data.length) {
    final n = sizes[k % sizes.length];
    k++;
    final end = (off + n > data.length) ? data.length : off + n;
    yield Uint8List.sublistView(data, off, end);
    off = end;
  }
}

/// 收集流式平移的完整输出字节。
Future<Uint8List> _collect(Stream<Uint8List> src, int delta) async {
  final buf = <int>[];
  await for (final c in shiftTsSegment(src, (firstPts) => delta)) {
    buf.addAll(c);
  }
  return Uint8List.fromList(buf);
}

Future<void> main() async {
  stdout.writeln('=== 流式平移 vs 整段平移 等价性验证 ===');
  final bytes = await fetch(kSegUrl);
  stdout.writeln('分片大小: ${bytes.length} 字节');

  final first = firstPesPtsMs(bytes, videoOnly: true);
  if (first == null) {
    stdout.writeln('❌ 读不出视频首帧 PTS，无法验证');
    exit(2);
  }
  stdout.writeln('真实首帧 PTS = ${first}ms');

  // 取三个有代表性的 delta：
  //   · 负 delta（本片真实场景：-25 秒量级）
  //   · 正 delta（断点插入片段场景）
  //   · 1ms（最小非零，检验 90kHz tick 换算边界）
  const deltas = [-25920, 888000, 1];

  var allOk = true;
  for (final delta in deltas) {
    // ① 整段平移（代理的「旧路径」语义，作为基准）
    final whole = normalizeTsPts(bytes, delta);

    // ② 流式平移（**与代理线上出口完全同一个函数** shiftTsSegment）
    int? probedFirst;
    final chunks = <int>[];
    await for (final c in shiftTsSegment(
      chunked(bytes, [7919, 1024, 33333, 188, 65536]),
      (firstPts) {
        probedFirst = firstPts;
        return delta;
      },
    )) {
      chunks.add(c.length);
    }
    final flow = Uint8List.fromList(
      await _collect(chunked(bytes, [7919, 1024, 33333, 188, 65536]), delta),
    );

    final lenOk = whole.length == flow.length && flow.length == bytes.length;
    var diffAt = -1;
    final n = whole.length < flow.length ? whole.length : flow.length;
    for (var i = 0; i < n; i++) {
      if (whole[i] != flow[i]) {
        diffAt = i;
        break;
      }
    }
    final bytesOk = diffAt < 0 && lenOk;

    // ③ 首帧 PTS 差
    final chk = verifyPtsShift(bytes, flow, delta, videoOnly: true);

    // ④ 前置垃圾字节场景（分片级函数自己定位包起点，应完全一致）
    final withJunk = Uint8List(bytes.length + 37)
      ..setRange(0, 37, List<int>.filled(37, 0xAA))
      ..setRange(37, bytes.length + 37, bytes);
    final wholeJ = normalizeTsPts(withJunk, delta);
    final flowJ = await _collect(chunked(withJunk, [4096, 8192, 512]), delta);
    var junkOk = wholeJ.length == flowJ.length;
    if (junkOk) {
      for (var i = 0; i < wholeJ.length; i++) {
        if (wholeJ[i] != flowJ[i]) {
          junkOk = false;
          diffAt = i;
          break;
        }
      }
    }

    // ⑤ 渐进输出断言：第一个输出块必须远小于整段
    //    （证明确实「边下边吐」而非整段缓冲 —— 这正是消除首字节延迟的关键）
    final firstChunk = chunks.isEmpty ? 0 : chunks.first;

    final ok = bytesOk && chk.ok && junkOk && probedFirst == first &&
        firstChunk > 0 && firstChunk < bytes.length ~/ 10;
    allOk = allOk && ok;
    stdout.writeln(
      'delta=${delta}ms  逐字节一致=${bytesOk ? "✅" : "❌(diff@$diffAt)"}'
      '  首帧差校验=${chk.ok ? "✅" : "❌(${chk.reason})"}'
      '  实际首帧差=${chk.actualDeltaMs}ms'
      '  探测首帧=$probedFirst(期望$first)'
      '  含前置垃圾一致=${junkOk ? "✅" : "❌(diff@$diffAt)"}'
      '  长度=${flow.length}'
      '  首块=${firstChunk}B/${bytes.length}B(渐进=${firstChunk < bytes.length ~/ 10 ? "✅" : "❌"})',
    );
  }

  stdout.writeln(allOk ? '\n✅ 全部通过：流式平移与整段平移完全等价。'
      : '\n❌ 存在差异，不可交付。');
  exit(allOk ? 0 : 1);
}
