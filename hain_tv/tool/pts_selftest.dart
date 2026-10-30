// 主工程 PTS 归一化自测（不依赖 AES，可直接运行）。
//
// 运行：dart run tool/pts_selftest.dart
//
// 判据（唯一可靠判据，勿改成"与某个参考值比对"）：
//   平移后 residual == 0，即 firstPesPtsMs(after) 与 before 的差 == deltaMs。
//
// 🔴 铁律：不要用「某个固定参考值」判断 PTS 是否正确。真机上曾因此误判
//    8 项（差恒定 182ms，实为测量口径差异而非缺陷）。唯一判据是 residual。
//
// 与 legacy 版 tool/pts_selftest.dart 的差异（有意为之）：
//   legacy 版依赖其自写 aes128_cbc.dart 解密后再测；主工程 AES 用的是
//   pointycastle（见 local_m3u8_proxy.dart），实现不同，故本脚本只测
//   PTS 本身、不含 AES，以免把两个模块的缺陷混在一起。
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/ts_pts_normalizer.dart';

const dir = '/tmp/ptsprobe';

Future<void> main() async {
  final idxs = <int>[860, 866, 871, 872, 1006, 1011, 1012, 1389];

  final files = <int, File>{};
  for (final i in idxs) {
    for (final cand in ['$dir/b$i.bin', '$dir/b$i.ts', '$dir/b$i.enc']) {
      final f = File(cand);
      if (f.existsSync() && f.lengthSync() > 0) {
        files[i] = f;
        break;
      }
    }
  }

  if (files.isEmpty) {
    print('（样本 $dir 不存在，跳过）');
    return;
  }

  print('${"分片".padRight(10)} ${"首帧PTS(ms)".padRight(14)} '
      '${"delta组".padRight(10)} ${"长度".padRight(8)} ${"residual".padRight(10)} 判定');

  var pass = 0, fail = 0, skip = 0;

  for (final i in idxs) {
    final f = files[i];
    if (f == null) {
      skip++;
      continue;
    }
    final raw = Uint8List.fromList(f.readAsBytesSync());

    // 若样本是 AES 密文（无法直接解析 TS），跳过而不是误判。
    final start = findTsPacketStart(raw);
    if (start < 0) {
      print('${"b$i".padRight(10)} ${"—".padRight(14)} ${"—".padRight(10)} '
          '${"—".padRight(8)} ${"—".padRight(10)} 跳过(非明文TS)');
      skip++;
      continue;
    }

    final before = firstPesPtsMs(Uint8List.sublistView(raw, start));
    if (before == null) {
      print('${"b$i".padRight(10)} ${"无PTS".padRight(14)} ${"—".padRight(10)} '
          '${"—".padRight(8)} ${"—".padRight(10)} 跳过');
      skip++;
      continue;
    }

    // 一组有代表性的 delta（含正负、含 0、含跨大值）验证平移与 33-bit 回绕。
    final deltas = <int>[0, 1000, -1000, 30000, -30000, 500000];
    var allOk = true;
    var lenSame = true;
    final details = <String>[];
    for (final delta in deltas) {
      final shifted = normalizeTsPts(raw, delta);
      if (shifted.length != raw.length) lenSame = false;
      final chk = verifyPtsShift(raw, shifted, delta);
      final residual =
          chk.actualDeltaMs == null ? null : chk.actualDeltaMs! - chk.expectedDeltaMs;
      final ok = chk.ok && residual == 0;
      if (!ok) {
        allOk = false;
        details.add('delta=$delta → residual=${residual}ms reason=${chk.reason}');
      }
    }

    if (allOk && lenSame) {
      pass++;
      print('${"b$i".padRight(10)} ${before.toString().padRight(14)} '
          '${deltas.length.toString().padRight(10)} '
          '${"不变".padRight(8)} ${"0".padRight(10)} ✅');
    } else {
      fail++;
      print('${"b$i".padRight(10)} ${before.toString().padRight(14)} '
          '${deltas.length.toString().padRight(10)} '
          '${(lenSame ? "不变" : "变了").padRight(8)} ${"—".padRight(10)} ❌');
      for (final d in details) {
        print('             $d');
      }
    }
  }

  print('');
  print('通过 $pass / 失败 $fail / 跳过 $skip  （样本目录 $dir）');
  if (fail > 0) exitCode = 1;
}
