// 🔴 2026-10-24 第五轮：`Range: bytes=0-` → 流式平移 的**决策判据**离线验证。
//
// 【为什么必须验证】本轮修复的核心改动只有一条判据：
//   「客户端的 Range 起点为 0 **且** 上游返回的是完整分片 ⇒ 允许走流式平移」。
// 判据写错的后果有两类，都很严重：
//   ① 误判为「完整」而实际只拿到部分字节 ⇒ 平移作用在残缺分片上
//      ⇒ 字节损坏（Packet corrupt / 花屏），且**静默**；
//   ② 误判为「不完整」而实际是完整分片 ⇒ 退回整段缓冲 ⇒ 首字节延迟
//      1.1 秒 ⇒ 卡顿回归（本轮要修的正是这个）。
// 故用**真实 CDN 响应头**（curl 实证本片源）+ 边界用例逐一验证。
//
// 运行：dart run tool/range_whole_segment_verify.dart
import '../lib/services/hls_segment_range.dart';

/// curl 实证的本片源 CDN 响应头（2026-10-24 实测，非推测）：
///   curl -D - -r 0-          → 206  content-range: bytes 0-310763/310764
///   curl -D - -r 0-65535     → 206  content-range: bytes 0-65535/310764
///   curl -D -                → 200  （无 content-range）
const int kTotal = 310764;

int failures = 0;

void check(String name, bool actual, bool expected) {
  final ok = actual == expected;
  if (!ok) failures++;
  print('${ok ? "✅" : "❌"} $name ⇒ $actual（期望 $expected）');
}

void main() {
  print('=== Range 整段判据验证 ===');

  // ① mpv 的真实形态：Range: bytes=0- → 上游 206 完整分片 ⇒ 完整
  check(
    '206 bytes 0-310763/310764（mpv 实际形态）',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'bytes 0-310763/310764',
    ),
    true,
  );

  // ② 部分 Range（起点 0 但只回了一部分）⇒ 必须判为「不完整」
  check(
    '206 bytes 0-65535/310764（部分分片）',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'bytes 0-65535/310764',
    ),
    false,
  );

  // ③ 续拉 Range（起点 > 0）⇒ 不完整（拿不到分片开头，不能判 delta）
  check(
    '206 bytes 100-310763/310764（续拉）',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'bytes 100-310763/310764',
    ),
    false,
  );

  // ④ 总长未知（`*`）⇒ 保守判为不完整
  check(
    '206 bytes 0-310763/*（总长未知）',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'bytes 0-310763/*',
    ),
    false,
  );

  // ⑤ 无 Range 的 200 ⇒ 完整
  check(
    '200（无 Range）',
    coversWholeSegment(statusCode: 200),
    true,
  );

  // ⑥ 206 但缺少 content-range ⇒ 保守判为不完整
  check(
    '206 且无 content-range',
    coversWholeSegment(statusCode: 206),
    false,
  );

  // ⑦ 单字节分片（total=1，end=0 ⇒ end >= total-1 ⇒ 完整）
  check(
    '206 bytes 0-0/1（最小分片）',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'bytes 0-0/1',
    ),
    true,
  );

  // ⑧ content-range 格式异常 ⇒ 保守判为不完整
  check(
    '206 content-range 格式非法',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'garbage',
    ),
    false,
  );

  // ⑨ 端点恰好等于 total-1（少一字节）⇒ 不完整
  check(
    '206 bytes 0-310762/310764（少一字节）',
    coversWholeSegment(
      statusCode: 206,
      contentRange: 'bytes 0-${kTotal - 2}/$kTotal',
    ),
    false,
  );

  print('');
  if (failures == 0) {
    print('✅ 全部通过：Range 整段判据正确。');
  } else {
    print('❌ $failures 项未通过。');
    throw StateError('Range 整段判据验证失败');
  }
}
