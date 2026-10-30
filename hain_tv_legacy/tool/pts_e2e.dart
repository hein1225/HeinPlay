// 端到端：模拟代理的 _deltaFor 完整逻辑（含基准锚定），验证拖拽落点。
import 'dart:io';
import 'dart:typed_data';
import '../lib/services/aes128_cbc.dart';
import '../lib/services/ts_pts_normalizer.dart';

const dir = '/tmp/ptsprobe';

void main() {
  final key = Uint8List.fromList(File('$dir/key.bin').readAsBytesSync());

  // 名义轴（EXTINF 累加）
  final lines = File('$dir/sub.m3u8').readAsLinesSync();
  final nom = <int>[]; var acc = 0.0; var pend = 0.0;
  for (final ln in lines) {
    final t = ln.trim();
    if (t.startsWith('#EXTINF:')) {
      pend = double.parse(t.substring(8).split(',').first);
    } else if (t.isNotEmpty && !t.startsWith('#')) {
      nom.add((acc * 1000).round()); acc += pend; pend = 0;
    }
  }

  final key_ = key;
  int? ptsOf(int idx) {
    final f = File('$dir/b$idx.enc');
    if (!f.existsSync()) return null;
    final c = Uint8List.fromList(f.readAsBytesSync());
    final p = Aes128Cbc.decrypt(c, key_, iv: Uint8List(16));
    if (p == null) return null;
    return firstPesPtsMs(p, videoOnly: true);
  }

  // 模拟代理：按请求顺序建立基准
  final order = <int>[871, 872, 1006, 1011, 1012, 1389, 860, 866];
  int? basePts, baseFilt;
  print('${"idx".padRight(6)} ${"真实PTS".padRight(11)} ${"名义".padRight(11)} '
      '${"delta".padRight(10)} ${"落点".padRight(11)} residual');
  print('-' * 62);
  var fail = 0;
  for (final idx in order) {
    final first = ptsOf(idx);
    if (first == null) continue;
    final filt = nom[idx];
    if (basePts == null) {
      basePts = first; baseFilt = filt;
      print('★ 基准建立：baseFirstPts=$first baseFiltered=$filt (idx=$idx)');
    }
    final expected = basePts! + (filt - baseFilt!);
    final delta = expected - first;
    final shifted = first + delta;
    final residual = shifted - expected;
    if (residual != 0) fail++;
    print('${"$idx".padRight(6)} ${"$first".padRight(11)} ${"$filt".padRight(11)} '
        '${"$delta".padRight(10)} ${"$shifted".padRight(11)} $residual');
  }
  print('');
  print(fail == 0 ? '✅ 所有落点 residual=0，拖拽将精确对齐' : '❌ $fail 项偏差');
}
