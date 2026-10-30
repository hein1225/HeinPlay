// 🔴🔴🔴 2026-10-24 第十轮：分片**完整性 / Range 切片 / TS 对齐**判据的离线验证。
//
// 【为什么要有这个脚本】
//   第十轮把媒体分片改成「完整下载 → 校验 → 一次性写出」，
//   出口要按 Range 切片、还要判断「这次切片能不能施加 PTS 平移」。
//   这两件事判错 ⇒ 字节损坏（Packet corrupt）或协议不合法 ⇒ 卡顿 / 卡死。
//   判据抽到纯 Dart 模块（lib/services/hls_segment_range.dart），
//   本脚本逐例验证，**不依赖 Flutter**（`dart run` 可直接跑）。
//
// 【真机背景：hilog 2026-10-24 19:30】
//   avp（AVPlayer）只请求了 1 个分片 6oxczFWF.ts，代理声明
//   Content-Length=214696 却只写出 32768 字节 ⇒ AVPlayer 永远等不到完整分片
//   ⇒ prepared 之后再无 playing ⇒ 画面卡死在开头画面、进度条却正确。
//
// 运行：dart run tool/segment_integrity_verify.dart
import '../lib/services/hls_segment_range.dart';

int _pass = 0;
int _fail = 0;

void check(String name, bool ok, [String detail = '']) {
  if (ok) {
    _pass++;
    print('✅ $name');
  } else {
    _fail++;
    print('❌ $name ${detail.isEmpty ? '' : '⇒ $detail'}');
  }
}

void main() {
  // ── ① 完整性判定（第十轮的核心闸门）────────────────────────────
  // 真机实锤：declared=214696 / got=32768 ⇒ 上游掐断 ⇒ 必须判为**不完整**。
  check(
    '完整分片 declared=214696 got=214696 ⇒ 完整',
    isCompleteSegment(declared: 214696, got: 214696),
  );
  check(
    '掐断分片 declared=214696 got=32768 ⇒ **不完整**（真机 avp 卡死现场）',
    !isCompleteSegment(declared: 214696, got: 32768),
  );
  check(
    '掐断分片 declared=314148 got=8272 ⇒ **不完整**（真机 mpv Packet corrupt 现场）',
    !isCompleteSegment(declared: 314148, got: 8272),
  );
  check(
    '上游未给 Content-Length ⇒ 视为完整（交由上层其它信号处理）',
    isCompleteSegment(declared: null, got: 12345),
  );
  check(
    '多 1 字节也算不完整（declared=100 got=101）',
    !isCompleteSegment(declared: 100, got: 101),
  );

  // ── ② Range 切片：播放器要整段（bytes=0-）────────────────────
  final whole = parseRangeBytes('bytes=0-', 214696);
  check(
    'bytes=0- ⇒ 整段切片 (0, 214695)',
    whole != null && whole.$1 == 0 && whole.$2 == 214695,
    '实际 $whole',
  );

  // ── ③ Range 切片：闭合区间 ───────────────────────────────────
  final part = parseRangeBytes('bytes=0-65535', 214696);
  check(
    'bytes=0-65535 ⇒ (0, 65535)',
    part != null && part.$1 == 0 && part.$2 == 65535,
    '实际 $part',
  );

  final mid = parseRangeBytes('bytes=1000-2999', 214696);
  check(
    'bytes=1000-2999 ⇒ (1000, 2999)',
    mid != null && mid.$1 == 1000 && mid.$2 == 2999,
    '实际 $mid',
  );

  // ── ④ Range 切片：suffix-range ───────────────────────────────
  final suffix = parseRangeBytes('bytes=-1024', 214696);
  check(
    'bytes=-1024 ⇒ (213672, 214695)',
    suffix != null && suffix.$1 == 213672 && suffix.$2 == 214695,
    '实际 $suffix',
  );

  // ── ⑤ Range 切片：非法/越界必须返回 null（宁可当无 Range）─────
  check('格式非法 items=1-2 ⇒ null', parseRangeBytes('items=1-2', 214696) == null);
  check('end 越界 bytes=0-999999 ⇒ null', parseRangeBytes('bytes=0-999999', 214696) == null);
  check('start>end bytes=500-100 ⇒ null', parseRangeBytes('bytes=500-100', 214696) == null);
  check('suffix N=0 bytes=-0 ⇒ null', parseRangeBytes('bytes=-0', 214696) == null);

  // ── ⑥ TS 包边界对齐（决定这次切片能否施加 PTS 平移）──────────
  check('无 Range（null）⇒ 对齐', rangeStartIsTsAligned(null));
  check('起点 0 ⇒ 对齐', rangeStartIsTsAligned(0));
  check('起点 188 ⇒ 对齐', rangeStartIsTsAligned(188));
  check('起点 376 ⇒ 对齐', rangeStartIsTsAligned(376));
  check('起点 1 ⇒ **不对齐**（部分 Range ⇒ 禁止平移）', !rangeStartIsTsAligned(1));
  check('起点 100 ⇒ **不对齐**', !rangeStartIsTsAligned(100));
  check('起点 187 ⇒ **不对齐**', !rangeStartIsTsAligned(187));
  check('起点 189 ⇒ **不对齐**', !rangeStartIsTsAligned(189));

  // ── ⑦ 交叉验证：Range 起点 与 切片起点 必须一致 ───────────────
  final r = 'bytes=1000-2999';
  final rs = rangeStartOf(r);
  final rr = parseRangeBytes(r, 214696);
  check(
    'rangeStartOf 与 parseRangeBytes 起点一致（1000）',
    rs == 1000 && rr != null && rr.$1 == 1000,
    'rangeStartOf=$rs parse=${rr?.$1}',
  );

  // ── ⑧ 整段判据与切片的一致性：bytes=0- 必须等于整段 ───────────
  final w = rangeRequestsWholeSegment('bytes=0-');
  final wSlice = parseRangeBytes('bytes=0-', 214696);
  check(
    'bytes=0- ⇒ 既判整段、切片也覆盖全段（0..len-1）',
    w && wSlice != null && wSlice.$1 == 0 && wSlice.$2 == 214695,
  );

  // ── ⑨ Content-Range 构造（代理回给播放器的 206 头）───────────
  check(
    'total=314148 ⇒ bytes 0-314147/314148',
    buildWholeSegmentContentRange(314148) == 'bytes 0-314147/314148',
  );
  check('total=0 ⇒ null（不构造非法头）', buildWholeSegmentContentRange(0) == null);

  print('');
  print('全部通过：$_pass 例 / $_fail 失败 —— 分片完整性与 Range 判据正确。');
  if (_fail > 0) {
    throw StateError('有 $_fail 条判据不通过');
  }
}
