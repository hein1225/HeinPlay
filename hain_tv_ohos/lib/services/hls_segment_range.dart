// 🔴 2026-10-24 第五轮：HLS 分片的 **Range 整段判据**（纯 Dart，无 Flutter 依赖）。
//
// 【为什么独立成一个文件】判据必须能**离线逐例验证**（见
// `tool/range_whole_segment_verify.dart`）。若它留在 `local_m3u8_proxy.dart`
// 里，工具脚本 import 代理就会把 Flutter 框架拖进来 —— `dart run` 下
// `dart:ui` 不可用 ⇒ 根本跑不起来（实测报 banner.dart / text_painter.dart
// 一堆 invalid-type 错误）。纯 Dart 模块才有可测试性。
//
// 【判据是什么】mpv 对**每一个** HLS 分片都发 `Range: bytes=0-`
// （真机实测 100/100 起点=0），而不是干脆不发 Range。
// 「有没有 Range 头」这个旧判据因此永远判成「有 Range ⇒ 走整段缓冲」，
// 导致第三轮做好的**流式平移**在真机上一次都没触发 ⇒ 每分片首字节延迟
// 875ms ⇒ 分片边界饿空 ⇒ 小顿挫。
//
// 【正确判据】起点为 0 **且** 上游确实返回了**完整分片** ⇒ 可以安全走流式。
//   · 起点 0 ⇒ 手里有分片开头 ⇒ 首个视频 PES 可靠可判 ⇒ delta 可判；
//   · 完整分片 ⇒ 与整段缓冲路径**逐字节等价**（已用真实分片验证）。
// 只要「不是完整分片」（部分 Range / 续拉 / 总长未知）就退回整段缓冲 ——
// 那里拿不到分片开头，误判会**静默损坏字节**。
library;

/// 判断上游响应是否**覆盖了整个分片**（而不是只返回了分片的一部分字节）。
///
/// 【真实 CDN 响应形态】（curl 实证本片源 2026-10-24，非推测）
///   `Range: bytes=0-`       → 206 `content-range: bytes 0-310763/310764`  完整
///   `Range: bytes=0-65535`  → 206 `content-range: bytes 0-65535/310764`   部分
///   无 Range                → 200（无 content-range）                    完整
bool coversWholeSegment({
  required int statusCode,
  String? contentRange,
}) {
  if (statusCode == 200) return true;
  if (contentRange == null) return false;
  final m = RegExp(r'bytes\s+(\d+)-(\d+)/(\d+|\*)').firstMatch(contentRange);
  if (m == null) return false;
  final start = int.tryParse(m.group(1)!);
  final end = int.tryParse(m.group(2)!);
  final totalStr = m.group(3)!;
  if (start != 0 || end == null) return false;
  if (totalStr == '*') return false; // 总长未知 ⇒ 保守走整段缓冲
  final total = int.tryParse(totalStr);
  if (total == null) return false;
  return end >= total - 1;
}

/// 解析 Range 头中的**起始字节偏移**；无法解析（如 suffix-range `bytes=-N`）返回 null。
///
/// 【为什么需要它 —— 2026-10-24】
/// TS 分片按 **188 字节包边界**对齐，而播放器的 Range 起点是任意字节偏移。
/// 若对「起点不在包边界」的片段施加 PTS 归一化，平移器会按错误的包边界
/// 改写 4 字节 PTS 字段 ⇒ **静默损坏字节**（表现为 Packet corrupt / 解码花屏）。
/// 因此需要知道起点是否 188 对齐，才能判定该片段能否安全平移。
///
/// ⚠️ 真机实测（2026-10-24 09:09 日志）：mpv 的 100 次 Range 请求**起点全部为 0**
///    ⇒ 全部落在 TS 包边界上 ⇒ 起点对齐这一关天然满足。
int? rangeStartOf(String? range) {
  if (range == null || range.isEmpty) return null;
  final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
  if (m == null) return null;
  final startStr = m.group(1)!;
  if (startStr.isEmpty) return null; // suffix-range：无显式起点
  return int.tryParse(startStr);
}

// ── 🔴🔴 2026-10-24 第九轮：上游 Range 转发判据 + 206 响应构造 ──────────────
//
// 【为什么需要独立成纯 Dart 模块】同 [rangeStartOf] 的理由：
//   判据必须能离线逐例验证（见 `tool/segment_range_forward_verify.dart`）。
//
// 【真机实锤：hilog 2026-10-24 18:37】同一个分片 pUr8NL28.ts：
//   · 预取走「无 Range ⇒ 200」→ 314148 bytes **完整**（71 次全中，0 失败）；
//   · 直连走「`Range: bytes=0-` ⇒ 206」→ **两次被上游中途掐断**
//     （sent=245716 / sent=147392）⇒ 残缺分片 ⇒ 播放器重试 ⇒ 顿挫。
// ⇒ 206 路径在这个 CDN 上不可靠，**完整 GET 才是稳的那条**。

/// 播放器的 Range 头是否在要**整个分片**。
///
/// - null / 空 ⇒ 是（播放器根本没发 Range，天然要整段）；
/// - `bytes=0-` ⇒ 是（起点 0 且**开放结尾** ⇒ 整个分片）；
/// - `bytes=0-65535` ⇒ **否**（起点 0 但**闭合结尾** ⇒ 只要前 64KB，是部分 Range）；
/// - `bytes=100-` ⇒ 否；
/// - `bytes=-N`（suffix）⇒ 否；
/// - 无法解析 ⇒ 否（保守：不能当成整段）。
///
/// ⚠️ 起点 0 **不足以**判定整段 —— 必须同时「开放结尾」。
///    混淆这两者会让「部分 Range」被当成整段 ⇒ 上游给回部分字节
///    而代理却按整段处理 ⇒ **残缺分片**。
bool rangeRequestsWholeSegment(String? range) {
  if (range == null || range.isEmpty) return true;
  final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
  if (m == null) return false;
  final startStr = m.group(1)!;
  final endStr = m.group(2)!;
  if (startStr.isEmpty) return false; // suffix-range：没有显式起点
  if (endStr.isNotEmpty) return false; // 闭合结尾 ⇒ 部分 Range
  return int.tryParse(startStr) == 0; // bytes=0- ⇒ 整个分片
}

/// 是否应当把播放器的 `Range` 头**转发给上游**。
///
/// [range] = 播放器发来的 Range 头（null/空 = 未发）。
/// [isPlaylistUrl] = 目标是不是播放列表（播放列表必须拿完整内容）。
///
/// 规则：
///   · 播放列表 ⇒ 一律不转发（要完整内容算总时长）；
///   · 播放器要**整个分片**（含 `bytes=0-`）⇒ **不转发** ——
///     它语义上就是「整个分片」，去掉后走上游 200 完整路径，
///     内容完全等价但**更稳**（见本文件顶部实证）；
///   · 其余（部分 Range、suffix-range）⇒ 转发。
bool shouldForwardRange({
  required String? range,
  required bool isPlaylistUrl,
}) {
  if (isPlaylistUrl) return false;
  if (range == null || range.isEmpty) return false;
  return !rangeRequestsWholeSegment(range);
}

/// 上游因「未转发 Range」而返回 **200** 时，代理要回给播放器的
/// `Content-Range` 值（形如 `bytes 0-314147/314148`）。
///
/// 返回 null 表示**不该构造** 206（总长未知 ⇒ 无法构造合法 Content-Range）。
///
/// 【为什么要自己构造】播放器发的是 `Range: bytes=0-`，原先上游回 206；
///   现在上游回 200。若把 200 直接交回播放器，部分播放器（libmdk/fvp）
///   对 200/206 的处理路径不同 ⇒ 行为可能变化。
///   代理自己构造 206 + `bytes 0-(total-1)/total` ⇒
///   **与原先上游的 206 响应逐字节等价**，播放器侧零感知。
String? buildWholeSegmentContentRange(int total) {
  if (total <= 0) return null;
  return 'bytes 0-${total - 1}/$total';
}

// ── 🔴🔴🔴 2026-10-24 第十轮：分片**完整性**与 **Range 切片**判据 ────────────
//
// 【为什么需要】第十轮把媒体分片改成「完整下载 → 校验 → 一次性写出」，
//   出口要按 Range 切片、还要判断「这次切片能不能施加 PTS 平移」。
//   这两件事一旦判错 ⇒ 字节损坏（Packet corrupt）或协议不合法 ⇒ 卡顿/卡死。
//   ⇒ 抽成纯 Dart 判据，可离线逐例验证（见 tool/segment_integrity_verify.dart）。

/// TS 传输包长度（MPEG-TS 固定 188 字节）。
const int kTsPacketSize = 188;

/// 播放器请求的 Range 起点是否落在 **TS 包边界**上。
///
/// [start] 为 null 表示「无 Range」或「无法解析」⇒ 视为对齐（整段请求）。
///
/// 【为什么重要】PTS 平移是「给每个 TS 包加同一个常数」。若切片起点不在
///   188 边界上，一个包会被劈成两半分别被改写 ⇒ **静默损坏字节**
///   （真机表现：`[ffmpeg/demuxer:warn] mpegts: Packet corrupt`）。
///   ⇒ 部分 Range 且起点不对齐时，**禁止平移**。
bool rangeStartIsTsAligned(int? start) {
  if (start == null) return true;
  return start % kTsPacketSize == 0;
}

/// 上游响应是否**完整**（实际收到的字节数 == 声明的 Content-Length）。
///
/// [declared] 为 null 表示上游没给 Content-Length ⇒ 无法判定 ⇒ 视为完整
///   （交给调用方按其它信号处理）。
bool isCompleteSegment({required int? declared, required int got}) {
  if (declared == null) return true;
  return got == declared;
}

/// 解析 Range 头为「含端点」的字节区间；非法/越界返回 null。
///
/// 支持三种形态：
///   · `bytes=start-end`   ⇒ [start, end]（闭区间）
///   · `bytes=start-`      ⇒ [start, fullLen-1]
///   · `bytes=-N`          ⇒ [fullLen-N, fullLen-1]（suffix）
///
/// 返回 null 的情形：格式无法解析、N <= 0、start > end、end >= fullLen
///   （越界 ⇒ 宁可交给上层当作「无 Range」处理，也不要给出错误切片）。
(int, int)? parseRangeBytes(String range, int fullLen) {
  if (fullLen <= 0) return null;
  final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
  if (m == null) return null;
  final startStr = m.group(1)!;
  final endStr = m.group(2)!;
  int start;
  int end;
  if (startStr.isEmpty) {
    // suffix-range: bytes=-N（最后 N 字节）
    final n = int.tryParse(endStr);
    if (n == null || n <= 0) return null;
    start = (fullLen - n).clamp(0, fullLen - 1);
    end = fullLen - 1;
  } else {
    start = int.tryParse(startStr) ?? 0;
    end = endStr.isEmpty ? fullLen - 1 : int.tryParse(endStr) ?? (fullLen - 1);
  }
  if (start < 0 || end >= fullLen || start > end) return null;
  return (start, end);
}
