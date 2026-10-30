/// TS PTS/DTS/PCR 归一化核心（长度保持不变）。
///
/// 背景：某些 HLS 源在 #EXT-X-DISCONTINUITY 处存在真实 PTS 断点（实测约 30s），
/// 而 ffmpeg 的 HLS demuxer（hls.c）并不解析 DISCONTINUITY / PROGRAM-DATE-TIME，
/// 只会把"EXTINF 名义累加轴"与"首个分片真实 PTS(first_timestamp)"对齐一次，
/// 导致续播 seek 后极大一段分片命中"在 seek 目标之前"的丢弃判据 → 起播前看门狗
/// 触发 STALL-RECOVER → 重建 → 死循环（fvp 点播无法续播）。
///
/// 本模块在本地代理侧把每个分片的 PTS/DTS/PCR 平移一个**逐段常量 delta**，
/// 使"真实 PTS 轴"与"EXTINF 名义累加轴"对齐（real' = 名义轴）。平移后
/// ffmpeg 的 ts_offset≈0、丢弃窗口归零、起播即准确定位，且 mdk 上报位置 = 名义轴
/// = avplayer 口径（消除跨后端 ~30s 漂移）。
///
/// delta 按段计算：delta(i) = (firstSegRealPts + Σ_{k<i} extinfDur) − segFirstRealPts(i)。
/// 干净源(无断点)各段 delta≈0，本模块对 |delta|<阈值 的段直接透传，字节零改动。
library;

import 'dart:async';
import 'dart:typed_data';

/// 在 [data] 中定位 TS 包边界起点，返回首个同步字节偏移；找不到返回 -1。
///
/// 🔴 2026-10-09 加固：此前 `normalizeTsPts` / `firstPesPtsMs` 只在
/// `data.length % 188 != 0` 时才扫描同步字节。当一段数据「恰好 188 对齐
/// 但开头带前导垃圾（如 CDN 注入的头、AES 去填充残留）」时，`start` 会
/// 被当成 0，于是整段按固定 188 步长错位解读包边界 →
/// **PTS/DTS 被系统性改写到错误位置，且长度不变、无任何报错（静默损坏）**。
/// 现改为**无条件扫描**，并用「连续 N 个包落在同一 188 栅格」交叉验证，
/// 避免把 payload 里偶然出现的 0x47 误判为包边界。
int findTsPacketStart(Uint8List data) {
  const kTsPacket = 188;
  const kConfirm = 4; // 需连续确认的包数（含首包）
  final n = data.length;
  if (n < kTsPacket) return -1;
  for (var i = 0; i + kTsPacket * kConfirm <= n; i++) {
    if (data[i] != 0x47) continue;
    var ok = true;
    for (var k = 1; k < kConfirm; k++) {
      if (data[i + k * kTsPacket] != 0x47) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  // 数据不足 kConfirm 个包时，退化为「能找到多少个就确认多少个」。
  for (var i = 0; i + kTsPacket <= n; i++) {
    if (data[i] != 0x47) continue;
    var ok = true;
    for (var k = 1; i + k * kTsPacket < n; k++) {
      if (data[i + k * kTsPacket] != 0x47) {
        ok = false;
        break;
      }
    }
    if (ok) return i;
  }
  return -1;
}

/// 🔴 2026-10-24：单个 TS 包（188 字节）内的 PTS/DTS/PCR 平移（**就地改写**）。
///
/// 【为什么单独抽出来】
///   本函数是「整段平移」[normalizeTsPts] 与「流式平移」[shiftTsStream] 的
///   **唯一**包内实现。两套实现一旦分叉，就会出现「整段改对了、流式改错了」
///   的静默损坏（长度不变、无异常、无日志，播放器只表现为花屏/音画不同步）。
///   故整段与流式**共用同一份代码**，从根上杜绝分叉。
///
/// [base] 为该包首字节在 [buf] 中的偏移；[buf] 会被就地修改。
/// 非同步字节、越界、delta=0 时不做任何改动。
void shiftTsPacketInPlace(
  Uint8List buf,
  int base,
  int deltaMs, {
  bool rewritePcr = true,
}) {
  const kTsPacket = 188;
  if (deltaMs == 0) return;
  if (base < 0 || base + kTsPacket > buf.length) return;
  if (buf[base] != 0x47) return;

  final deltaTicks = deltaMs * 90; // 33-bit PTS 域单位
  final deltaPcr = deltaMs * 27000; // 42-bit PCR 域单位 (90kHz*300)

  final pusi = (buf[base + 1] >> 6) & 0x01;
  final afc = (buf[base + 3] >> 4) & 0x03;
  var off = 4;
  // adaptation field
  if (afc & 0x02 != 0) {
    final afLen = buf[base + 4];
    if (afLen > 0 && 5 + afLen <= kTsPacket) {
      final afFlags = buf[base + 5];
      if (rewritePcr && (afFlags & 0x10) != 0 && 6 + afLen + 6 <= kTsPacket) {
        // PCR 占 6 字节 (base 33-bit + ext 9-bit)
        _shiftPcr(buf, base + 6, deltaPcr);
      }
      off = 5 + afLen;
    }
  }
  // PES start + payload present
  // PES 头布局（相对包内 payload 起点 off）：
  //   [0..2]=00 00 01 起始码, [3]=stream_id, [4..5]=PES 长度,
  //   [6]=10xxxxxx(标记/加扰), [7]=PTS/DTS flags 等, [8]=PES header length,
  //   [9..13]=PTS(5字节), [14..18]=DTS(5字节, 仅当 DTS flag)。
  // 故需 off+19<=188 才能安全读 DTS 末字节；PTS 只需 off+14<=188。
  if (pusi != 0 && (afc & 0x01) != 0 && off + 14 <= kTsPacket) {
    if (buf[base + off] == 0x00 &&
        buf[base + off + 1] == 0x00 &&
        buf[base + off + 2] == 0x01) {
      final sid = buf[base + off + 3];
      if ((0xE0 <= sid && sid <= 0xEF) || (0xC0 <= sid && sid <= 0xDF)) {
        final flags = buf[base + off + 7];
        final ptsFlag = (flags >> 7) & 0x01;
        final dtsFlag = (flags >> 6) & 0x01;
        if (ptsFlag != 0) {
          _shiftPts(buf, base + off + 9, deltaTicks);
          if (dtsFlag != 0 && off + 19 <= kTsPacket) {
            _shiftPts(buf, base + off + 14, deltaTicks);
          }
        }
      }
    }
  }
}

/// 对一段 TS（188 字节对齐）按 [deltaMs] 毫秒平移所有 PTS/DTS/PCR。
/// [deltaMs] 可为负。返回新字节（长度与原数据相同）。
/// 若数据非 188 对齐或不含同步字节，原样返回。
Uint8List normalizeTsPts(Uint8List data, int deltaMs, {bool rewritePcr = true}) {
  const kTsPacket = 188;
  if (deltaMs == 0) return data;
  final start = findTsPacketStart(data);
  if (start < 0) return data; // 无 TS 包 → 透传。
  final total = data.length - start;
  // 尾部残缺包不参与改写（改写只发生在 start 起的完整 188 包内）。
  final packetAligned = start + (total ~/ kTsPacket) * kTsPacket;

  final out = Uint8List.fromList(data); // 复制，长度不变。
  final n = packetAligned;
  var i = start;
  // 🔴 2026-10-24：包内改写统一走 [shiftTsPacketInPlace]，
  //   与流式平移 [shiftTsStream] 共用同一份实现，杜绝两套逻辑分叉。
  while (i + kTsPacket <= n) {
    shiftTsPacketInPlace(out, i, deltaMs, rewritePcr: rewritePcr);
    i += kTsPacket;
  }
  return out;
}

/// 🔴 2026-10-24：流式 TS 平移的**增量处理器**。
///
/// 【为什么单独做一个类】
///   流式转发需要「先缓冲前缀判定 delta，再边下边改边吐」，
///   而「边下边改」要求一个能跨 chunk 维持 188 字节包边界的**有状态**对象。
///   把这个状态机抽出来（而不是写成一个匿名生成器）有两个好处：
///     ① 代理侧可以「先喂前缀、再喂后续流」，中间不丢一个字节；
///     ② [shiftTsStream] 与代理的流式出口**共用同一份实现**，杜绝分叉。
///
/// 【使用约定】
///   · 喂入的字节必须**从 TS 包边界开始**（可含前置垃圾字节，
///     但那部分需由调用方先行处理掉）；
///   · [add] 返回「已平移、可立即输出」的字节，可能为空；
///   · 流结束时用 [flush] 取走剩余不足一包的字节（原样输出）。
class TsStreamShifter {
  TsStreamShifter(this.delta, {this.rewritePcr = true});

  /// 平移量（ms）。0 表示原样透传。
  final int delta;

  /// 是否改写 PCR。
  final bool rewritePcr;

  /// 跨 chunk 保留的残余字节（不足一个 188 字节包）。
  Uint8List _carry = Uint8List(0);

  /// 追加一段数据，返回已平移、可立即输出的字节（可能为空）。
  Uint8List add(List<int> chunk) {
    if (chunk.isEmpty) return Uint8List(0);
    if (delta == 0) return Uint8List.fromList(chunk);
    const kTsPacket = 188;
    final Uint8List data;
    if (_carry.isEmpty) {
      data = Uint8List.fromList(chunk);
    } else {
      data = Uint8List(_carry.length + chunk.length)
        ..setRange(0, _carry.length, _carry)
        ..setRange(_carry.length, _carry.length + chunk.length, chunk);
    }
    final n = (data.length ~/ kTsPacket) * kTsPacket;
    if (n == 0) {
      _carry = data;
      return Uint8List(0);
    }
    for (var p = 0; p < n; p += kTsPacket) {
      shiftTsPacketInPlace(data, p, delta, rewritePcr: rewritePcr);
    }
    _carry = Uint8List.sublistView(data, n);
    return Uint8List.sublistView(data, 0, n);
  }

  /// 流结束：取走剩余不足一个包的字节（**原样**，不改写）。
  Uint8List flush() {
    final out = _carry;
    _carry = Uint8List(0);
    return out;
  }
}

/// 🔴 2026-10-24：分片级**流式**平移的探测前缀上限（字节）。
/// 32 个 TS 包 = 6016 字节。首个视频 PES 的 PTS 通常在前 2~3 个包内。
const int kTsSegmentProbeBytes = 188 * 32;

/// 🔴 2026-10-24：**分片级**流式平移 —— 自己完成「定位包起点 → 探测首帧
/// PTS → 判定 delta → 边下边改边吐」的全过程。
///
/// 【与 [shiftTsStream] 的分工】
///   · [shiftTsStream] 是**裸**逐包改写器：要求输入从包边界开始，
///     不认识「前置垃圾字节」，也不知道 delta 从哪来；
///   · 本函数是**分片级**封装：先缓冲前缀、定位包起点、探测首个视频 PES
///     的 PTS、把 [resolveDelta] 交给业务方判定，再流式输出。
///   代理出口与离线验证脚本**共用本函数** ⇒ 脚本证明的正是线上行为。
///
/// 【安全设计】
///   ① 判定 delta 之前**不吐出任何字节** ⇒ 判据不成立时可安全退回
///      「原样透传」；
///   ② 平移后会做一次**出口自校验**（平移前后首帧 PTS 差必须 == delta），
///      不等即放弃平移、原样透传（与整段路径回退原字节的语义一致）——
///      PTS 改写一旦落错字节是**静默损坏**（长度不变、无异常、无日志），
///      这个自检是最后一道防线；
///   ③ 字节守恒：垃圾前缀 + 对齐部分 + 残余 + 后续流 = 输入全长。
///
/// [resolveDelta]：探测到前缀后调用，参数是本分片**首个视频 PES 的 PTS**
///   （可能为 null，表示前缀里还没出现视频 PES），返回值是平移量
///   （0 表示不平移）。业务判据（阈值、上限、源级短路）由调用方实现。
///
/// [onDecided]：delta 判定完成后回调一次（用于记录日志/写缓存）。
/// [onVerifyFailed]：出口自校验失败时回调（此时已改为原样透传）。
Stream<Uint8List> shiftTsSegment(
  Stream<List<int>> src,
  int Function(int? firstPts) resolveDelta, {
  int probeBytes = kTsSegmentProbeBytes,
  void Function(int delta, int? firstPts)? onDecided,
  void Function(String reason, int? beforeMs, int? afterMs)? onVerifyFailed,
}) {
  const kTsPacket = 188;
  final it = StreamIterator<List<int>>(src);

  Stream<Uint8List> gen() async* {
    // ── 阶段 A：缓冲前缀，判定 delta（此时尚未吐出任何字节）────────
    final head = BytesBuilder(copy: false);
    var headLen = 0;
    while (headLen < probeBytes) {
      if (!await it.moveNext()) break;
      head.add(it.current);
      headLen += it.current.length;
    }
    final headBytes = head.takeBytes();

    var delta = 0;
    int? firstPts;
    final start = findTsPacketStart(headBytes);
    if (start >= 0) {
      firstPts = firstPesPtsMs(headBytes, videoOnly: true);
      delta = resolveDelta(firstPts);
      if (delta != 0) {
        // 出口自校验：平移前后首帧 PTS 差必须 == delta，否则放弃平移。
        final shifted = normalizeTsPts(headBytes, delta);
        final chk = verifyPtsShift(headBytes, shifted, delta, videoOnly: true);
        if (!chk.ok) {
          delta = 0;
          onVerifyFailed?.call(chk.reason, chk.beforeMs, chk.afterMs);
        }
      }
    }
    onDecided?.call(delta, firstPts);

    // ── 阶段 B：输出（字节守恒：垃圾 + 对齐部分 + 残余 + 后续流）────
    if (start < 0) {
      // 不是标准 TS（无同步字节）⇒ 原样透传。
      if (headBytes.isNotEmpty) yield headBytes;
      while (await it.moveNext()) {
        yield Uint8List.fromList(it.current);
      }
      return;
    }
    final shifter = TsStreamShifter(delta);
    // ① 头部垃圾字节（不在 188 栅格上的前缀）原样输出
    if (start > 0) yield Uint8List.sublistView(headBytes, 0, start);
    // ② 对齐部分：按 delta 平移后输出
    final alignedEnd = start + ((headBytes.length - start) ~/ kTsPacket) * kTsPacket;
    if (delta != 0) {
      final shiftedHead = normalizeTsPts(headBytes, delta);
      yield Uint8List.sublistView(shiftedHead, start, alignedEnd);
    } else {
      yield Uint8List.sublistView(headBytes, start, alignedEnd);
    }
    // ③ 残余（不足一包）+ 后续流：逐块喂给 shifter，边下边改边吐。
    //    残余起点 alignedEnd 恰在 188 栅格上 ⇒ shifter 的包边界不会错位。
    final carry = Uint8List.sublistView(headBytes, alignedEnd);
    if (carry.isNotEmpty) {
      final o = shifter.add(carry);
      if (o.isNotEmpty) yield o;
    }
    while (await it.moveNext()) {
      final o = shifter.add(it.current);
      if (o.isNotEmpty) yield o;
    }
    final tail = shifter.flush();
    if (tail.isNotEmpty) yield tail;
  }

  return gen();
}

/// 🔴 2026-10-24：**流式** TS 平移 —— 边收字节边逐包改写，**不做整段缓冲**。
///
/// 【为什么需要它 —— 这正是「画面偶尔卡一下、声音正常」的根因】
///   PTS 平移是「给每个包加同一个常数」，**包与包之间完全独立**，
///   根本不需要「整段缓冲后一次性改写」。主工程 `hain_tv` 注释里的
///   「PTS 平移依赖分片内所有 PES 的连续性，边流边改会切断这个前提」
///   是一个**错误的技术假设** —— 平移不依赖任何跨包连续性。
///
///   而「整段缓冲」的实际代价是巨大的：
///   代理必须**把整个分片下载完**才能吐出第一个字节。真机实测
///   （hilog 2026-10-24 07:52，本片源 1328 段）：
///     · 分片从「收到请求」到「吐出首字节」中位 **1168ms**、首片 **2.3s**；
///     · 而每个分片只有约 2 秒内容 ⇒ 播放器缓冲在每个分片边界被反复饿空
///       ⇒ **画面停住、音频照常**（音频走 native 播放线程）。
///   同一份日志里 mpv 的 position 推进速率全程 1.00x（数据供给跟得上），
///   但 `OH_NativeImage_AcquireNativeWindowBuffer() failed` 爆发 1436 次
///   ⇒ 卡在**帧交付**环节，不在数据环节。
///
/// 【前置条件】
///   ① 必须是**完整分片**请求（不能带 Range）：Range 拿不到分片开头，
///      无法可靠判定首个 PES，误判会静默损坏字节。
///   ② [src] 必须是**从分片第一个字节开始**的字节流。
///
/// [delta] 为 0 时原样透传（不逐包处理）。
Stream<Uint8List> shiftTsStream(
  Stream<Uint8List> src,
  int delta, {
  bool rewritePcr = true,
}) {
  if (delta == 0) return src;
  final shifter = TsStreamShifter(delta, rewritePcr: rewritePcr);
  Stream<Uint8List> gen() async* {
    await for (final chunk in src) {
      final out = shifter.add(chunk);
      if (out.isNotEmpty) yield out;
    }
    final tail = shifter.flush();
    if (tail.isNotEmpty) yield tail;
  }

  return gen();
}

/// 计算 [pid] 为视频/音频 PES 的首帧 PTS（单位 ms），无则返回 null。
/// 用于代理探测每段首帧真实 PTS。
int? firstPesPtsMs(Uint8List data, {bool videoOnly = false}) {
  const kTsPacket = 188;
  final start = findTsPacketStart(data);
  if (start < 0) return null;
  final n = data.length;
  var i = start;
  while (i + kTsPacket <= n) {
    final base = i;
    if (data[base] != 0x47) {
      i += kTsPacket;
      continue;
    }
    final pusi = (data[base + 1] >> 6) & 0x01;
    final afc = (data[base + 3] >> 4) & 0x03;
    var off = 4;
    if (afc & 0x02 != 0) {
      final afLen = data[base + 4];
      if (afLen > 0 && 5 + afLen <= kTsPacket) off = 5 + afLen;
    }
    if (pusi != 0 && (afc & 0x01) != 0 && off + 14 <= kTsPacket) {
      if (data[base + off] == 0x00 &&
          data[base + off + 1] == 0x00 &&
          data[base + off + 2] == 0x01) {
        final sid = data[base + off + 3];
        final isVideo = 0xE0 <= sid && sid <= 0xEF;
        if (videoOnly && !isVideo) {
          i += kTsPacket;
          continue;
        }
        if (isVideo || (0xC0 <= sid && sid <= 0xDF)) {
          final flags = data[base + off + 7];
          if ((flags >> 7) & 0x01 != 0) {
            final ticks = _readPts(data, base + off + 9);
            return (ticks / 90).round();
          }
        }
      }
    }
    i += kTsPacket;
  }
  return null;
}

void _shiftPts(Uint8List b, int o, int delta) {
  final v = (_readPts(b, o) + delta) & 0x1FFFFFFFF; // 33-bit wrap
  // byte0: 保留高 4 位(prefix/marker)与最低位(marker)，仅改写 bit3..1 = PTS[32..30]。
  b[o] = (b[o] & 0xF1) | (((v >> 30) & 0x07) << 1);
  b[o + 1] = (v >> 22) & 0xFF;
  b[o + 2] = 0x01 | (((v >> 15) & 0x7F) << 1);
  b[o + 3] = (v >> 7) & 0xFF;
  b[o + 4] = 0x01 | ((v & 0x7F) << 1);
}

int _readPts(Uint8List b, int o) {
  final a = b[o], c = b[o + 2], d = b[o + 3], e = b[o + 4];
  return ((a >> 1) & 0x07) << 30 |
      (b[o + 1] << 22) |
      ((c >> 1) & 0x7F) << 15 |
      (d << 7) |
      ((e >> 1) & 0x7F);
}

void _shiftPcr(Uint8List b, int o, int delta) {
  // 6 字节 PCR 字段布局（TS 标准）：
  //   33-bit base(90kHz) | 6-bit reserved('111111') | 9-bit ext(27MHz 内相位)
  // 实际 PCR(27MHz 单位) = base*300 + ext。统一按 27MHz 单位平移后再拆回。
  final base = ((b[o] << 25) |
          (b[o + 1] << 17) |
          (b[o + 2] << 9) |
          (b[o + 3] << 1) |
          (b[o + 4] >> 7)) &
      0x1FFFFFFFF;
  final reserved = (b[o + 4] >> 1) & 0x3F;
  final ext = (((b[o + 4] & 0x01) << 8) | b[o + 5]) & 0x1FF;
  var total27 = (base * 300 + ext + delta) & ((1 << 42) - 1);
  final newBase = (total27 ~/ 300) & 0x1FFFFFFFF;
  final newExt = total27 % 300;
  b[o] = (newBase >> 25) & 0xFF;
  b[o + 1] = (newBase >> 17) & 0xFF;
  b[o + 2] = (newBase >> 9) & 0xFF;
  b[o + 3] = (newBase >> 1) & 0xFF;
  b[o + 4] = ((newBase & 0x01) << 7) | ((reserved & 0x3F) << 1) | ((newExt >> 8) & 0x01);
  b[o + 5] = newExt & 0xFF;
}

/// 平移自校验结果。
class PtsShiftCheck {
  const PtsShiftCheck({
    required this.ok,
    required this.beforeMs,
    required this.afterMs,
    required this.expectedDeltaMs,
    required this.actualDeltaMs,
    required this.reason,
  });

  /// 是否通过自校验（通过才允许把平移结果写回响应体）。
  final bool ok;
  final int? beforeMs;
  final int? afterMs;
  final int expectedDeltaMs;
  final int? actualDeltaMs;
  final String reason;
}

/// 平移后自校验：对同一段字节，平移前后的首帧 PTS 差值必须等于 [deltaMs]。
///
/// 🔴 这是「打开 kPtsNormalizeObserveOnly 开关」的前置保险。原因：
/// [normalizeTsPts] 只改写 TS 字节里的 PTS/DTS/PCR，**不修改
/// continuity_counter**，一旦包边界判断错位或 PTS 解析落到错误字节，
/// 输出长度不变、无异常、无日志 —— 属于静默损坏，播放器只会表现为
/// 花屏/音画不同步/时长异常，排查成本极高。
///
/// 故在真正写回字节前，用「平移前后首帧 PTS 差 == delta」做一次端到端
/// 自证：不等即判定本次平移不可信，调用方应**放弃平移、返回原始字节**。
///
/// 注意：输入段若无 PTS（纯空包/纯 PSI 段），返回 ok=false、reason='no-pts'，
/// 调用方同样按「不平移」处理（平移本就无意义）。
PtsShiftCheck verifyPtsShift(
  Uint8List before,
  Uint8List after,
  int deltaMs, {
  bool videoOnly = false,
}) {
  final b = firstPesPtsMs(before, videoOnly: videoOnly);
  final a = firstPesPtsMs(after, videoOnly: videoOnly);
  if (b == null || a == null) {
    return PtsShiftCheck(
      ok: false,
      beforeMs: b,
      afterMs: a,
      expectedDeltaMs: deltaMs,
      actualDeltaMs: null,
      reason: b == null ? 'no-pts-before' : 'no-pts-after',
    );
  }
  // PTS 是 33-bit @90kHz，回绕周期 ≈ 26.5 小时。firstPesPtsMs 返回的是
  // **毫秒**，而回绕发生在 90kHz tick 域，故统一换算到 tick 再取模比较。
  // （曾误把 expected 乘 90 而 actual 不乘 → 恒报 diff≈3139920tick 的假失败。）
  const kMod = 0x1FFFFFFFF;
  final beforeTicks = b * 90;
  final afterTicks = a * 90;
  // ⚠️ Dart 的 `%` 对负数返回**非负**结果（欧几里得余数），与 C 不同。
  // 负 delta 时 (after-before) 为负，直接 % kMod 会得到「同余但不等」的大正数，
  // 再经下面的 >kMod/2 判断会被折成错误值。故先做一次有符号归一化。
  var actualTicks = (afterTicks - beforeTicks) % kMod;
  if (actualTicks > kMod ~/ 2) actualTicks -= kMod;
  var expectedTicks = (deltaMs * 90) % kMod;
  if (expectedTicks > kMod ~/ 2) expectedTicks -= kMod;
  // 允许 45 tick(=0.5ms@90kHz) 误差：firstPesPtsMs 的 ms 域做过 round。
  final diff = (actualTicks - expectedTicks).abs();
  final ok = diff <= 45;
  return PtsShiftCheck(
    ok: ok,
    beforeMs: b,
    afterMs: a,
    expectedDeltaMs: deltaMs,
    actualDeltaMs: (actualTicks / 90).round(),
    reason: ok ? 'ok' : 'delta-mismatch(diff=${diff}tick)',
  );
}
