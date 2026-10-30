// 离线复现：代理对「加密 + DISCONTINUITY + METHOD=NONE」源的过滤/重写输出。
// 用法：dart run tool/repro_avp_playlist.dart
import 'dart:io';

import 'package:hain_tv/services/local_m3u8_proxy.dart';
import 'package:hain_tv/services/m3u8_ad_filter.dart';

void analyze(String label, String content) {
  final lines = content.split('\n');
  var segIdx = 0;
  String? activeKey;
  final keySpans = <String>[];
  final segKeys = <int, String>{};
  for (final raw in lines) {
    final t = raw.trim();
    if (t.startsWith('#EXT-X-KEY')) {
      activeKey = t;
    }
    if (t.isNotEmpty && !t.startsWith('#')) {
      segKeys[segIdx] = activeKey ?? '(none)';
      if (keySpans.isEmpty || keySpans.last.key != (activeKey ?? '(none)')) {
        keySpans.add(_Span(segIdx, activeKey ?? '(none)'));
      } else {
        keySpans.last.end = segIdx;
      }
      segIdx++;
    }
  }
  stdout.writeln('\n===== $label =====');
  stdout.writeln('媒体段总数: $segIdx');
  stdout.writeln('--- KEY 区间（按段下标）---');
  for (final s in keySpans) {
    stdout.writeln('  段 ${s.start}..${s.end}  key=${_short(s.key)}');
  }
  stdout.writeln('--- 关键下标处的 KEY 状态 ---');
  for (final i in [0, 1, 2, 5, 6, 745, 759, 762, 763, 778]) {
    if (i < segKeys.length) {
      stdout.writeln('  seg[$i] key=${_short(segKeys[i]!)}');
    }
  }
}

class _Span {
  _Span(this.start, this.key);
  final int start;
  String key;
  int end = 0;
}

String _short(String k) {
  if (k == '(none)') return '(none)';
  final m = RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(k);
  final method = m?.group(1) ?? '?';
  final iv = RegExp(r'IV=(0x[0-9A-Fa-f]+)').firstMatch(k)?.group(1) ?? 'noIV';
  final uri = RegExp(r'URI="([^"]+)"').firstMatch(k)?.group(1) ?? '';
  return 'METHOD=$method IV=$iv URI=${uri.length > 90 ? uri.substring(0, 90) + '…' : uri}';
}

void main() {
  final src = File('/tmp/src.m3u8').readAsStringSync();
  const base = 'https://vod1.maowushi.com/20260915/IHKsJ00i/1066kb/hls/index.m3u8';
  const proxy = 'http://127.0.0.1:39043';

  analyze('源站原始', src);

  final filter = M3u8AdFilter();
  final filtered = filter.purify(base, src, cleanDiscontinuities: false);
  stdout.writeln('\n[purify] removed=${filter.currentAdCount}');
  if (filtered == null) {
    stdout.writeln('purify 返回 null');
    return;
  }
  File('/tmp/filtered.m3u8').writeAsStringSync(filtered);
  analyze('过滤后（purify, cleanDiscontinuities=false）', filtered);

  final resolved = LocalM3u8Proxy.resolveRelativeUrls(filtered, base);
  final rewritten = LocalM3u8Proxy.rewriteToLocalProxy(
    resolved,
    proxy,
    decryptAes: false,
  );
  File('/tmp/rewritten_avp.m3u8').writeAsStringSync(rewritten);
  analyze('重写后（avp 路径 decryptAes=false）', rewritten);

  final rewrittenMpv = LocalM3u8Proxy.rewriteToLocalProxy(
    resolved,
    proxy,
    decryptAes: true,
  );
  File('/tmp/rewritten_mpv.m3u8').writeAsStringSync(rewrittenMpv);
  analyze('重写后（mpv 路径 decryptAes=true）', rewrittenMpv);
}
