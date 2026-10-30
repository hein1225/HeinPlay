/// TS PTS/DTS/PCR 归一化核心（长度保持不变）。
///
/// 移植来源：`hain_tv_legacy/lib/services/ts_pts_normalizer.dart`（TV 独立工程，
/// 已真机验证 residual 恒 0）。鸿蒙 `hain_tv_ohos` 是同源的另一实现。
///
/// ═══ 为什么主工程必须要有它（进度偏移根因）═══
///
/// mpv（以及任何走 ffmpeg HLS demuxer 的后端）的 `time-pos` 和 `duration`
/// **来自两个不同来源**：
///   · `time-pos`  ← 解码出来的**帧真实 PTS**（含被删广告的原始时间线）
///   · `duration`  ← 播放列表 **EXTINF 累加**（去广告后的名义轴）
/// 只要两条轴速率不同（去广告、拼接、转码、切片重编号都会造成），进度条
/// `position / duration` 就必然漂移，**且漂移量随播放单调增长**——用户表现为
/// 「拖动后再播一会儿又往后偏，越往后偏得越多」。
///
/// 真机铁证（详见 `plan/worklogs/2026-10-11-mpv进度漂移根治-跨平台通用总结.md`）：
/// 某时刻 duration=2603280ms 与去广告轴 1304×2000 仅差 −720ms（0.03%），
/// 而同一时刻 position 与去广告轴差 84.6 秒 ⇒ 两轴确实不同源。
///
/// 修复的本质**不是调数值**，而是把分片字节里的 PTS 改写到 EXTINF 名义轴上，
/// 让两个量同源。
///
/// ═══ 与 legacy 的差异（移植时的有意取舍，勿当成疏漏）═══
///
/// 本文件是**纯算法模块**，与平台、与播放器后端均无关，故与 legacy 版本
/// 保持逐行一致，不做平台化改写。所有平台差异都在调用方（LocalM3u8Proxy）
/// 处理。理由：两份实现需长期同步维护，任何"顺手优化"都会让它们产生分歧，
/// 而分歧点恰恰是 PTS 静默损坏的高发区。
///
/// ═══ 主工程特有的注意事项 ═══
///
/// 1. 主工程有多个后端（mpv / exo / vlc），其中 **fvp 已被 mpv 取代**
///    （见 player_backend_factory.dart）。只有**走本地代理**的后端才能受益，
///    直连 CDN 的路径本模块无法介入。
/// 2. 主工程此前的媒体分片是**纯流式转发**（`out.addStream`），要在字节上做
///    平移就必须先整段缓冲。调用方需自行控制单段体积上限。
/// 3. 平移只改 PTS/DTS/PCR，**不动 continuity_counter**（与 legacy 一致）。
///    改 PTS 之外字段会破坏解复用，勿做。
///
/// delta 按段计算：delta(i) = (firstSegRealPts + Σ_{k<i} extinfDur) − segFirstRealPts(i)。
/// 干净源(无断点)各段 delta≈0，调用方对 |delta|<阈值 的段直接透传，字节零改动。
library;

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

  final deltaTicks = deltaMs * 90; // 33-bit PTS 域单位
  final deltaPcr = deltaMs * 27000; // 42-bit PCR 域单位 (90kHz*300)

  final out = Uint8List.fromList(data); // 复制，长度不变。
  final n = packetAligned;
  var i = start;
  while (i + kTsPacket <= n) {
    final base = i;
    if (out[base] != 0x47) {
      i += kTsPacket;
      continue;
    }
    final pusi = (out[base + 1] >> 6) & 0x01;
    final afc = (out[base + 3] >> 4) & 0x03;
    var off = 4;
    // adaptation field
    if (afc & 0x02 != 0) {
      final afLen = out[base + 4];
      if (afLen > 0 && 5 + afLen <= kTsPacket) {
        final afFlags = out[base + 5];
        if (rewritePcr && (afFlags & 0x10) != 0 && 6 + afLen + 6 <= kTsPacket) {
          // PCR 占 6 字节 (base 33-bit + ext 9-bit)
          _shiftPcr(out, base + 6, deltaPcr);
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
      if (out[base + off] == 0x00 &&
          out[base + off + 1] == 0x00 &&
          out[base + off + 2] == 0x01) {
        final sid = out[base + off + 3];
        if ((0xE0 <= sid && sid <= 0xEF) || (0xC0 <= sid && sid <= 0xDF)) {
          final flags = out[base + off + 7];
          final ptsFlag = (flags >> 7) & 0x01;
          final dtsFlag = (flags >> 6) & 0x01;
          if (ptsFlag != 0) {
            _shiftPts(out, base + off + 9, deltaTicks);
            if (dtsFlag != 0 && off + 19 <= kTsPacket) {
              _shiftPts(out, base + off + 14, deltaTicks);
            }
          }
        }
      }
    }
    i += kTsPacket;
  }
  return out;
}

/// 计算首个 PES 首帧 PTS（单位 ms），无则返回 null。
/// 用于代理探测每段首帧真实 PTS。
///
/// [videoOnly] 只取视频 PES（stream_id 0xE0–0xEF）；
/// [audioOnly] 只取音频 PES（stream_id 0xC0–0xDF）。
/// 二者不可同时为 true；都为 false 时取遇到的第一个（视频通常在前）。
///
/// 🔴 2026-10-15 新增 [audioOnly]：`normalizeTsPts` 会连音频 PES 一起平移，
///    便于分别校验音视频两条流的实际平移量。
///    ⚠️ 但**不要**据此就断定「音频被改坏」—— 2026-10-16 已用「mpv 与 exo 播
///    同一份代理字节流、只有 mpv 报 Invalid audio PTS」反证了该假设。
///    详见 `local_m3u8_proxy.dart` 中 `_shiftPtsChecked` 的注释。
int? firstPesPtsMs(Uint8List data, {bool videoOnly = false, bool audioOnly = false}) {
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
      // 🔴🔴 2026-10-12 修正说明：**不要**在这里跳 pointer_field。
      //
      //   实测真实源（分片 b866）包的字节布局：
      //     [0]=47 [1]=41(PUSI+PID 0x100) [3]=32(afc=3) [4]=07(afLen)
      //     [5]=50(AF flags, PCR present) [6..11]=PCR(6字节)
      //     [12]=00 00 01 e0 ...  ← PES 起始码就在这里
      //   即 `off = 5 + afLen = 12` **已经**指向 PES 起始码，且该处 byte=0x00
      //   （不是 pointer_field；对 PID 0x100 这种承载 PES 的包，PUSI 包的
      //    载荷首字节是 pointer_field，其值为 0 时 PES 紧随其后）。
      //
      //   曾误加「跳过 pointer_field」逻辑，导致从 byte13 起找 `00 00 01`
      //   而恒失败 ⇒ firstPesPtsMs 返回 null。**已回退**。
      if (off + 14 <= kTsPacket &&
          data[base + off] == 0x00 &&
          data[base + off + 1] == 0x00 &&
          data[base + off + 2] == 0x01) {
        final sid = data[base + off + 3];
        final isVideo = 0xE0 <= sid && sid <= 0xEF;
        final isAudio = 0xC0 <= sid && sid <= 0xDF;
        if (videoOnly && !isVideo) {
          i += kTsPacket;
          continue;
        }
        if (audioOnly && !isAudio) {
          i += kTsPacket;
          continue;
        }
        if (isVideo || isAudio) {
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
