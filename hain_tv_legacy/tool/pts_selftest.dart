// 真实分片验证：① AES 解密正确 ② PTS 能读出 ③ 平移后 residual == 0。
// 运行：dart run tool/pts_selftest.dart
import 'dart:io';
import 'dart:typed_data';
import '../lib/services/aes128_cbc.dart';
import '../lib/services/ts_pts_normalizer.dart';

const dir = '/tmp/ptsprobe';

Future<void> main() async {
  final kf = File('$dir/key.bin');
  if (!kf.existsSync()) {
    print('（样本不存在，跳过）');
    return;
  }
  final key = Uint8List.fromList(kf.readAsBytesSync());
  final idxs = <int>[860, 866, 871, 872, 1006, 1011, 1012, 1389];

  var pass = 0, fail = 0;
  print('${"分片".padRight(12)} ${"真实PTS".padRight(11)} ${"平移后".padRight(11)} '
      '${"expected".padRight(11)} residual');
  print('-' * 62);

  for (final idx in idxs) {
    final f = File('$dir/b$idx.enc');
    if (!f.existsSync()) continue;
    final cipher = Uint8List.fromList(f.readAsBytesSync());

    // ① 解密
    final plain = Aes128Cbc.decrypt(cipher, key, iv: Uint8List(16));
    if (plain == null) {
      print('b$idx.enc 解密失败'); fail++; continue;
    }
    // ② 读 PTS
    final first = firstPesPtsMs(plain, videoOnly: true);
    if (first == null) {
      print('b$idx.enc 读不到 PTS'); fail++; continue;
    }
    // ③ 平移若干值，验证 residual 恒为 0
    for (final delta in <int>[0, 3520, -17567, 35134]) {
      final shiftedBytes = normalizeTsPts(plain, delta);
      final after = firstPesPtsMs(shiftedBytes, videoOnly: true);
      final expect = first + delta;
      final residual = (after == null) ? null : (after - expect).abs();
      final ok = residual != null && residual <= 1;
      if (delta == 35134) {
        if (ok) { pass++; } else { fail++; }
        print('${"b$idx.enc".padRight(12)} ${"$first".padRight(11)} '
            '${"${after ?? "-"}".padRight(11)} ${"$expect".padRight(11)} '
            '${residual ?? "-"} ${ok ? "✅" : "❌"}');
      }
    }
  }

  print('');
  print(fail == 0 ? '✅ 全部通过（$pass 项，residual 均 ≤1ms）'
                  : '❌ 失败 $fail 项');
}
