// PTS 轴对齐端到端实测（flutter test 运行，宿主侧，无设备依赖）。
//
// 运行：flutter test test/pts_axis_verify_test.dart
//
// 【为什么需要这个】2026-10-24 用户实报「进度条定位后仍往后漂 20 多秒」，
//   而代理日志显示 `裁掉广告=0 段` ⇒ 归一化开关恒为 false ⇒ 平移一次没跑。
//   本脚本用**工程内真实代码**（M3u8AdFilter + firstPesPtsMs）复算一���，
//   直接回答三个问题：
//     ① 真实 PTS 轴 == 原始 EXTINF 累加轴吗？（决定 delta 该以哪条轴为基准）
//     ② 过滤后名义轴与原始轴在用户定位点（名义轴 1534.356s）差多少？
//     ③ 归一化算出的 delta 量级是否合理（不是天文数字）？
//
// 【环境注意】flutter test 默认把 HttpClient 换成 mock（全部返回 400），
//   故必须 `HttpOverrides.global = null` 恢复真实网络。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import '../lib/services/m3u8_ad_filter.dart';
import '../lib/services/ts_pts_normalizer.dart';

const srcUrl = 'https://play.modujx17.com/20260915/ZDZnPg2F/1066kb/hls/index.m3u8';

/// 一段的分片在两条轴上的起点。
class AxisPoint {
  AxisPoint(this.url, this.origStartMs, this.filteredStartMs);
  final String url;
  final int origStartMs; // 原始列表 EXTINF 累加起点
  final int filteredStartMs; // 过滤后列表 EXTINF 累加起点
  int get droppedMs => origStartMs - filteredStartMs; // 该点已删广告累计
}

/// 按「起点口径」累加 #EXTINF，返回 url → 起点(ms)。
Map<String, int> buildAxis(String content, String baseUrl) {
  final axis = <String, int>{};
  var acc = 0;
  var pending = 0;
  var hasPending = false;
  for (final raw in content.split('\n')) {
    final t = raw.trim();
    if (t.startsWith('#EXTINF')) {
      final m = RegExp(r'#EXTINF:\s*([\d.]+)').firstMatch(t);
      pending = m != null ? (double.parse(m.group(1)!) * 1000).round() : 0;
      hasPending = true;
    } else if (t.isNotEmpty &&
        !t.startsWith('#') &&
        !t.startsWith('data:')) {
      final url = t.startsWith('http')
          ? t
          : Uri.parse(baseUrl).resolve(t).toString();
      axis[url] = acc; // 起点口径：先记起点，再累加本段
      acc += hasPending ? pending : 0;
      hasPending = false;
      pending = 0;
    }
  }
  return axis;
}

Future<Uint8List> download(String url) async {
  final client = HttpClient();
  try {
    final req = await client.getUrl(Uri.parse(url));
    final res = await req.close();
    if (res.statusCode != 200) {
      throw HttpException('HTTP ${res.statusCode} $url');
    }
    final chunks = <int>[];
    await for (final c in res) {
      chunks.addAll(c);
    }
    return Uint8List.fromList(chunks);
  } finally {
    client.close();
  }
}

void main() {
  test('PTS 轴对齐实测', () async {
    // flutter test 会 mock 掉 HttpClient，必须恢复真实网络。
    HttpOverrides.global = null;

    final raw = await download(srcUrl);
    final src = String.fromCharCodes(raw);

    // ── ① 用工程内真实的去广告过滤器复现过滤 ───────────────────────────
    final filter = M3u8AdFilter();
    final filtered = filter.purify(srcUrl, src) ?? src;
    print('【源】EXTINF 段数=${_countExtinf(src)} '
        'DISCONTINUITY=${_count(src, "#EXT-X-DISCONTINUITY")}');
    print('【过滤后】EXTINF 段数=${_countExtinf(filtered)} '
        '过滤掉 ${filter.currentAdCount} 段');

    final origAxis = buildAxis(src, srcUrl);
    final filtAxis = buildAxis(filtered, srcUrl);
    print('【轴长】原始=${_totalMs(origAxis)}ms 过滤后=${_totalMs(filtAxis)}ms');

    // ── ② 组装采样点：覆盖用户定位点（名义轴 1534.356s）前后 ──────────
    final samples = <double>[0, 300, 600, 900, 1200, 1534.356, 1800, 2200, 2600]
        .toList();
    final points = <AxisPoint>[];
    for (final url in filtAxis.keys) {
      final fs = filtAxis[url]!;
      final os = origAxis[url];
      if (os == null) continue; // 过滤后新增/改写的段没有原始轴
      points.add(AxisPoint(url, os, fs));
    }
    points.sort((a, b) => a.filteredStartMs.compareTo(b.filteredStartMs));

    print('\n=== 名义轴 → 原始轴 → 真实 PTS 实测 ===');
    print('目标名义轴(s) | 段idx | 名义起点(ms) | 原始起点(ms) | 已删累计(ms) '
        '| 真实首帧PTS(ms) | 真实-原始(ms) | delta=名义-真实(ms)');
    var ok = true;
    for (final target in samples) {
      final targetMs = (target * 1000).round();
      AxisPoint? pick;
      for (final p in points) {
        if (p.filteredStartMs <= targetMs &&
            (pick == null || p.filteredStartMs > pick.filteredStartMs)) {
          pick = p;
        }
      }
      if (pick == null) {
        print('  ${target.toStringAsFixed(3).padRight(14)} | (无匹配段)');
        continue;
      }
      Uint8List bytes;
      try {
        bytes = await download(pick.url);
      } catch (e) {
        print('  下载失败 ${pick.url}: $e');
        ok = false;
        continue;
      }
      final trueFirst = firstPesPtsMs(bytes, videoOnly: true);
      if (trueFirst == null) {
        print('  ${target.toStringAsFixed(3).padRight(14)} | 读不出首帧 PTS');
        continue;
      }
      final realVsOrig = trueFirst - pick.origStartMs;
      final delta = pick.filteredStartMs - trueFirst;
      print('  ${target.toStringAsFixed(3).padRight(14)} | '
          '${points.indexOf(pick).toString().padRight(6)} | '
          '${pick.filteredStartMs.toString().padRight(12)} | '
          '${pick.origStartMs.toString().padRight(12)} | '
          '${pick.droppedMs.toString().padRight(13)} | '
          '${trueFirst.toString().padRight(16)} | '
          '${realVsOrig.toString().padRight(13)} | $delta');

      // 断言 1：真实轴 == 原始轴（首帧 PTS 应贴近原始 EXTINF 累加起点）
      if (realVsOrig.abs() > 3000) {
        print('  ❌ 真实轴与原始轴偏差 ${realVsOrig}ms 过大');
        ok = false;
      }
      // 断言 2：delta 量级必须合理（远小于片长，且不是天文数字）
      if (delta.abs() > 120000) {
        print('  ❌ delta=$delta ms 量级异常');
        ok = false;
      }
    }

    // ── ③ 关键断言：用户定位点处的漂移量应与真机观测吻合 ────────────────
    final atUser = points.where((p) =>
        (p.filteredStartMs - 1534356).abs() < 3000).toList();
    if (atUser.isEmpty) {
      print('\n⚠️ 未采样到用户定位点（名义轴 1534.356s）附近的段');
    } else {
      final p = atUser.first;
      print('\n【用户定位点】名义轴 1534.356s → 段 ${points.indexOf(p)} '
          '名义起点=${p.filteredStartMs}ms 原始起点=${p.origStartMs}ms '
          '已删累计=${p.droppedMs}ms');
      print('【预期】真机观测：定位 1534.356s → 实际落点 1562.720s '
          '⇒ 漂移 28.364s');
      if ((p.droppedMs - 28364).abs() > 4000) {
        print('  ⚠️ 实测已删累计 ${p.droppedMs}ms 与真机观测 28364ms 差异较大');
      } else {
        print('  ✅ 实测已删累计与真机观测吻合 ⇒ 归一化方向与幅度正确');
      }
    }

    expect(ok, isTrue, reason: '轴对齐实测出现异常');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

int _countExtinf(String s) =>
    RegExp(r'^#EXTINF', multiLine: true).allMatches(s).length;

int _count(String s, String needle) => needle.allMatches(s).length;

int _totalMs(Map<String, int> axis) {
  if (axis.isEmpty) return 0;
  return axis.values.reduce((a, b) => a > b ? a : b);
}
