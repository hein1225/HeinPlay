// 🔴🔴 2026-10-24 第九轮：上游 Range 转发判据 + 206 响应构造 的离线逐例验证。
//
// 【为什么要有这个脚本】
//   本轮修复的核心判据有两处：
//     ① 「播放器的 Range 要不要转发给上游」
//     ② 「上游回 200 时，要不要自己构造 206 + Content-Range」
//   这两处一旦判错，后果都是**静默的字节损坏**：
//     · 把 `bytes=0-65535`（部分 Range）误判成整段
//       ⇒ 上游只给 64KB，代理却按整段缓存/平移 ⇒ **残缺分片**；
//     · 该转发时不转发（只转 64KB 的请求被当成整段）
//       ⇒ 同样拿到部分字节当整段用。
//   判据必须能**离线逐例验证**（真机一轮要 3 分钟，且样本不可控）。
//
// 【跑法】
//   dart run tool/segment_range_forward_verify.dart
//
// 【依赖】纯 Dart 模块 `lib/services/hls_segment_range.dart`（无 Flutter 依赖），
//   故 `dart run` 下不会把 `dart:ui` 拖进来（那是本模块单独拆文件的原因）。

import '../lib/services/hls_segment_range.dart';

int _pass = 0;
int _fail = 0;

void expect(String label, bool got, bool want) {
  if (got == want) {
    _pass++;
    print('✅ $label ⇒ $got（期望 $want）');
  } else {
    _fail++;
    print('❌ $label ⇒ $got（期望 $want）');
  }
}

void expectStr(String label, String? got, String? want) {
  if (got == want) {
    _pass++;
    print('✅ $label ⇒ $got（期望 $want）');
  } else {
    _fail++;
    print('❌ $label ⇒ $got（期望 $want）');
  }
}

void main() {
  print('=== Range 转发判据 / 整段判据验证 ===');

  // ── ① rangeRequestsWholeSegment：播放器要的是不是「整个分片」 ──────────
  expect('无 Range（null）⇒ 整段',
      rangeRequestsWholeSegment(null), true);
  expect('无 Range（空串）⇒ 整段',
      rangeRequestsWholeSegment(''), true);
  expect('bytes=0-（mpv 实际形态）⇒ 整段',
      rangeRequestsWholeSegment('bytes=0-'), true);
  expect('bytes=0-65535（闭合结尾，部分）⇒ **不是**整段',
      rangeRequestsWholeSegment('bytes=0-65535'), false);
  expect('bytes=100-（起点>0）⇒ 不是整段',
      rangeRequestsWholeSegment('bytes=100-'), false);
  expect('bytes=100-200（部分）⇒ 不是整段',
      rangeRequestsWholeSegment('bytes=100-200'), false);
  expect('bytes=-1024（suffix）⇒ 不是整段',
      rangeRequestsWholeSegment('bytes=-1024'), false);
  expect('garbage ⇒ 不是整段（保守）',
      rangeRequestsWholeSegment('garbage'), false);
  expect('bytes=00-（前导零）⇒ 整段',
      rangeRequestsWholeSegment('bytes=00-'), true);

  // ── ② shouldForwardRange：Range 头要不要转发给上游 ───────────────────
  expect('播放列表 ⇒ 永不转发',
      shouldForwardRange(range: 'bytes=0-', isPlaylistUrl: true), false);
  expect('播放器没发 Range ⇒ 不转发',
      shouldForwardRange(range: null, isPlaylistUrl: false), false);
  expect('bytes=0-（整段）⇒ **不转发**（改走上游 200 完整路径）',
      shouldForwardRange(range: 'bytes=0-', isPlaylistUrl: false), false);
  expect('bytes=0-65535（部分）⇒ 转发',
      shouldForwardRange(range: 'bytes=0-65535', isPlaylistUrl: false), true);
  expect('bytes=100- ⇒ 转发',
      shouldForwardRange(range: 'bytes=100-', isPlaylistUrl: false), true);
  expect('bytes=-1024（suffix）⇒ 转发',
      shouldForwardRange(range: 'bytes=-1024', isPlaylistUrl: false), true);

  // ── ③ buildWholeSegmentContentRange：自构造 206 的 Content-Range ──────
  expectStr('total=314148 ⇒ bytes 0-314147/314148',
      buildWholeSegmentContentRange(314148), 'bytes 0-314147/314148');
  expectStr('total=1 ⇒ bytes 0-0/1',
      buildWholeSegmentContentRange(1), 'bytes 0-0/1');
  expectStr('total=0 ⇒ null（构造不出合法 Content-Range）',
      buildWholeSegmentContentRange(0), null);
  expectStr('total=-1 ⇒ null',
      buildWholeSegmentContentRange(-1), null);
  // ── ④ 一致性：能构造 206 ⇔ 上游 200 时会真的构造 ────────────────────
  //   上游 200 + 播放器要整段 ⇒ 必须能构造出合法的 Content-Range。
  for (final r in <String?>[null, '', 'bytes=0-']) {
    final whole = rangeRequestsWholeSegment(r);
    final cr = buildWholeSegmentContentRange(314148);
    expect('Range=$r 整段=$whole ⇒ Content-Range 可构造=${cr != null}',
        whole == (cr != null), true);
  }

  print('');
  if (_fail == 0) {
    print('✅ 全部通过：$_pass 例 / 0 失败 —— Range 转发判据正确。');
  } else {
    print('❌ 有失败：$_pass 通过 / $_fail 失败。');
    throw StateError('Range 转发判据验证失败');
  }
}
