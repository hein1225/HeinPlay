// PTS 轴对齐离线实测（纯 dart，不依赖 Flutter / 设备）。
//
// 运行：dart run tool/pts_axis_probe.dart [源m3u8地址]
//
// 【背景】2026-10-24 用户实报「进度条定位后仍往后漂 20 多秒」。
//   代理日志显示 `裁掉广告=0 段` ⇒ 归一化开关恒为 false ⇒ 平移一次都没跑。
//   本脚本回答三个问题（都是**离线可判定**的，不需要复现去广告规则）：
//     ① `firstPesPtsMs` 能否准确读出分片首帧 PTS？（平移的前提）
//     ② 源的真实 PTS 轴是否等于 EXTINF 累加轴？（相等 ⇒ 只差「已删广告累计」）
//     ③ `normalizeTsPts` 的平移是否精确（平移后首帧 PTS == 目标，残差 0）？
//   另外顺带量化**源自身 #EXT-X-DISCONTINUITY 造成的真实轴跳变**——
//   ffmpeg/libmpv 的 HLS demuxer 不解析 DISCONTINUITY，
//   这一项即使不删广告也会让 time-pos 与 duration 分叉。
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/ts_pts_normalizer.dart';

const defaultSrc =
    'https://play.modujx17.com/20260915/ZDZnPg2F/1066kb/hls/index.m3u8';

class Seg {
  Seg(this.url, this.extinfMs, this.afterDiscontinuity);
  final String url;
  final int extinfMs;
  final bool afterDiscontinuity; // 该段之前是否有 #EXT-X-DISCONTINUITY
}

int _fail = 0;
void _check(String name, bool ok, [String detail = '']) {
  print('${ok ? "✅" : "❌"} $name${detail.isEmpty ? "" : "  ($detail)"}');
  if (!ok) _fail++;
}

Future<Uint8List> _get(String url) async {
  // ⚠️ 容器内 Dart 的 HttpClient 与该源站 TLS 握手失败（HandshakeException），
  //   curl 正常 ⇒ 统一走 curl 取**原始字节**。
  //   `stdoutEncoding: null` 关键：不指定编码时 stdout 是 List<int>（原始字节），
  //   否则会按系统编码把 TS 二进制解成字符串而损坏。
  //
  // ⚠️ 源站对高频请求会限流（TLS unexpected eof / 连接重置），
  //   故：本地缓存 + 退避重试。
  final cacheDir = Directory('/tmp/segcache');
  if (!cacheDir.existsSync()) cacheDir.createSync(recursive: true);
  final cacheFile = File('${cacheDir.path}/${url.hashCode.toUnsigned(32)}.ts');
  if (cacheFile.existsSync() && cacheFile.lengthSync() > 0) {
    return cacheFile.readAsBytesSync();
  }

  Object? lastErr;
  for (var attempt = 1; attempt <= 4; attempt++) {
    final r = await Process.run(
      'curl',
      ['-sS', '--max-time', '40', '-A', 'Mozilla/5.0', url],
      stdoutEncoding: null,
    );
    if (r.exitCode == 0) {
      final out = r.stdout as List<int>;
      if (out.isNotEmpty) {
        cacheFile.writeAsBytesSync(out);
        return Uint8List.fromList(out);
      }
      lastErr = 'empty body';
    } else {
      lastErr = 'curl exit=${r.exitCode}: ${r.stderr}';
    }
    await Future<void>.delayed(Duration(seconds: 5 * attempt));
  }
  throw HttpException('$lastErr  ($url)');
}

/// 解析 media playlist：返回分片列表（起点口径累加在调用处做）。
List<Seg> _parse(String content, String baseUrl) {
  final segs = <Seg>[];
  var pending = 0;
  var pendingDisc = false;
  for (final raw in content.split('\n')) {
    final t = raw.trim();
    if (t.isEmpty) continue;
    if (t == '#EXT-X-DISCONTINUITY') {
      pendingDisc = true;
    } else if (t.startsWith('#EXTINF')) {
      final m = RegExp(r'#EXTINF:\s*([\d.]+)').firstMatch(t);
      pending = m != null ? (double.parse(m.group(1)!) * 1000).round() : 0;
    } else if (!t.startsWith('#') && !t.startsWith('data:')) {
      final url = t.startsWith('http')
          ? t
          : Uri.parse(baseUrl).resolve(t).toString();
      segs.add(Seg(url, pending, pendingDisc));
      pendingDisc = false;
      pending = 0;
    }
  }
  return segs;
}

Future<void> main(List<String> args) async {
  final srcUrl = args.isNotEmpty && !args.first.startsWith('/')
      ? args.first
      : defaultSrc;

  // ⚠️ 源站对 playlist 域名的重复请求会限流（TLS unexpected eof），
  //   而分片域名正常 ⇒ 优先读本地已缓存的 playlist。
  final localPath = args.isNotEmpty && args.first.startsWith('/')
      ? args.first
      : '/tmp/src.m3u8';
  final localFile = File(localPath);
  final content = localFile.existsSync()
      ? localFile.readAsStringSync()
      : String.fromCharCodes(await _get(srcUrl));
  print('源：$srcUrl'
      '${localFile.existsSync() ? "  (本地缓存 $localPath)" : "  (在线下载)"}\n');
  final segs = _parse(content, srcUrl);
  print('【源结构】分片=${segs.length}  '
      'DISCONTINUITY=${RegExp(r'#EXT-X-DISCONTINUITY').allMatches(content).length}  '
      'EXTINF总和=${segs.fold<int>(0, (a, s) => a + s.extinfMs)}ms');

  // 原始 EXTINF 累加轴（起点口径）
  final origStart = <int>[];
  var acc = 0;
  for (final s in segs) {
    origStart.add(acc);
    acc += s.extinfMs;
  }

  // 采样：开头、普通段、以及每个断点前后各一段
  final picks = <int>{0, 1, segs.length ~/ 4, segs.length ~/ 2, segs.length - 2};
  for (var i = 0; i < segs.length; i++) {
    if (segs[i].afterDiscontinuity) {
      if (i > 0) picks.add(i - 1);
      picks.add(i);
    }
  }
  final idxs = picks.toList()..sort();

  print('\n=== 真实 PTS 轴 vs EXTINF 累加轴 ===');
  print('段idx | 断点 | EXTINF起点(ms) | 真实首帧PTS(ms) | 真实-累加(ms)');
  final jumpAtDiscontinuity = <int, int>{};
  var checked = 0;
  for (final i in idxs) {
    final s = segs[i];
    if (s.extinfMs <= 0) continue;
    Uint8List bytes;
    try {
      bytes = await _get(s.url);
    } catch (e) {
      print('  ${i.toString().padRight(5)} | 下载失败: $e');
      continue;
    }
    final first = firstPesPtsMs(bytes, videoOnly: true);
    if (first == null) {
      print('  ${i.toString().padRight(5)} | 读不出首帧 PTS');
      continue;
    }
    final diff = first - origStart[i];
    print('  ${i.toString().padRight(5)} | ${(s.afterDiscontinuity ? "是" : " ").padRight(4)} | '
        '${origStart[i].toString().padRight(16)} | ${first.toString().padRight(17)} | '
        '${diff.toString().padRight(14)}');
    if (s.afterDiscontinuity) {
      jumpAtDiscontinuity[i] = diff;
    }
    checked++;

    // ③ 平移算子精度。
    //    【语义】归一化要做的是「把真实首帧 PTS 搬到该段在**去广告名义轴**上的
    //    起点」，即 delta = 名义起点 − 真实首帧。这里用「搬到 0」等价验证：
    //    delta = −first ⇒ 平移后首帧必须精确为 0（残差 0）。
    //    这一步同时覆盖 **PTS 下溢边界**（first 很小 ⇒ delta 很负）。
    final shifted = normalizeTsPts(bytes, -first);
    final after = firstPesPtsMs(shifted, videoOnly: true);
    if (after == null) {
      _check('段$i 平移后仍可读首帧', false);
    } else {
      final residual = after - 0;
      _check('段$i 平移精确（残差=${residual}ms）', residual.abs() <= 2,
          'before=$first after=$after 目标=0');
    }
  }

  print('\n=== 结论 ===');
  _check('已采样分片数 > 0', checked > 0, 'checked=$checked');

  // ② 真实轴 == EXTINF 累加轴？（断点段除外）
  print('  断点处的「真实-累加」偏差（= 源自身时间轴跳变幅度）：');
  for (final e in jumpAtDiscontinuity.entries) {
    print('    段${e.key}: ${e.value}ms');
  }
  if (jumpAtDiscontinuity.isEmpty) {
    print('    （本次采样未命中断点段）');
  } else {
    _check('源存在 DISCONTINUITY 造成的真实轴跳变（归一化必需）',
        jumpAtDiscontinuity.values.any((v) => v.abs() > 1000));
  }

  print('\n${_fail == 0 ? "🎉 全部通过" : "⚠️ 失败 $_fail 项"}');
  exit(_fail == 0 ? 0 : 1);
}
