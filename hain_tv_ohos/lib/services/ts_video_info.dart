/// TS 分片视频分辨率解析（纯 Dart，零依赖）。
///
/// 用途：识别视频广告。很多 HLS 源的广告段与正片段的**画幅不同**
/// （典型：正片 1920x818 电影宽银幕，广告 1920x1080 满屏 16:9），
/// 本地代理（lib/services/local_m3u8_proxy.dart）改写 m3u8 时可以顺带
/// 嗅探每个分片的编码分辨率，作为广告判定的一路信号。
///
/// 算法来源：H.264/AVC 规范 **7.3.2.1.1 Sequence parameter set data syntax**
/// （SPS 语法）与 **7.4.2.1.1**（pic_width / frame_crop 语义），
/// 以及 ISO/IEC 13818-1（TS 包）与 13818-1 / H.264 Annex B（PES / NAL 起始码）。
/// 只解析到 SPS 的 frame_cropping 为止，不碰 VUI 之后的任何字段。
///
/// 设计原则：**绝不影响播放**。
///   * 本模块是热路径上的「尽力而为」嗅探器，调用方拿到 null 必须能照常播放；
///   * 因此所有解析路径都不抛异常（内部位读取器越界即返回安全默认值），
///     外层再套 try/catch 兜底，任何意外都只体现为 null；
///   * 遇到第一个 SPS 立刻返回，不遍历整个分片（大分片也不会拖慢代理）。
///
/// 与 ts_pts_normalizer.dart 保持同风格（中文注释、k 开头常量、段落分隔），
/// 但**刻意不 import 它**：解析所需的私有工具在本文件内独立重实现一份，
/// 保证两个文件零耦合，任一文件改动都不会波及对方。
library;

import 'dart:typed_data';

/// TS 包大小。
const kTsPacketSize = 188;

/// H.264 NAL 单元类型：SPS。
const kNalTypeSps = 7;

/// 需要额外读 chroma_format_idc 等字段的高 profile 集合
/// （H.264 规范 7.3.2.1.1）。
const kHighProfileIdcs = <int>{
  100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135,
};

/// 一个 TS 分片的视频编码信息。
class TsVideoInfo {
  const TsVideoInfo({
    required this.width,
    required this.height,
    this.profileIdc,
  });

  /// 编码宽度（已扣掉 frame cropping）。
  final int width;

  /// 编码高度（已扣掉 frame cropping）。
  final int height;

  /// profile_idc：100 = High，110 = High 10（10bit），122 = High 4:2:2……
  /// 可辅助判断「广告用高码率 profile、正片用 main profile」这类差异。
  final int? profileIdc;

  @override
  String toString() => 'TsVideoInfo(${width}x$height, profile=$profileIdc)';
}

/// 从 TS 分片字节解析 H.264 编码分辨率。
///
/// 返回 null 表示：没找到 SPS / 不是 H.264 / 数据不是合法 TS / 解析失败。
/// **绝不抛异常**（调用方在热路径上，异常会打断播放）。
TsVideoInfo? parseTsVideoInfo(Uint8List data) {
  try {
    return _parseTsVideoInfo(data);
  } catch (_) {
    // 兜底：任何未预料的越界/状态错误都吞掉，只表现为「没嗅到分辨率」。
    return null;
  }
}

TsVideoInfo? _parseTsVideoInfo(Uint8List data) {
  if (data.length < kTsPacketSize) return null;

  // 与 ts_pts_normalizer 一致：数据不 188 对齐时，先向后找第一个同步字节，
  // 允许分片头部有少量非 TS 前导字节。
  var start = 0;
  if (data.length % kTsPacketSize != 0) {
    for (var k = 0; k + kTsPacketSize <= data.length; k++) {
      if (data[k] == 0x47) {
        start = k;
        break;
      }
    }
    if (start + kTsPacketSize > data.length) return null; // 无 TS 包。
  }

  // 跨包拼接当前 PES 的 payload 片段：SPS 可能被切在包边界上，
  // 必须把「同一 PES 内」的片段接起来，否则 NAL 会断在中间。
  //
  // 说明：用 copy:true 的 Builder。它每次 takeBytes() 后即清空缓冲区，
  // 且内部按"已扫描游标"只解析新增部分（见 _scanForSps 的 from 参数），
  // 因此连续包不会重复扫描、也不会重复拼接旧数据。
  final pending = BytesBuilder();
  var pendingPid = -1;
  var scanned = 0; // pending 中已扫描过的字节数。

  final n = data.length;
  var i = start;
  while (i + kTsPacketSize <= n) {
    final base = i;
    if (data[base] != 0x47) {
      i += kTsPacketSize;
      continue;
    }

    final pusi = (data[base + 1] >> 6) & 0x01; // payload_unit_start_indicator
    final pid = ((data[base + 1] & 0x1F) << 8) | data[base + 2];
    final afc = (data[base + 3] >> 4) & 0x03;
    var off = 4;

    // adaptation field：afc 的 bit1 置位表示存在，首字节是长度。
    //   afLen == 0            → adaptation field 只有长度字节本身，
    //                           payload 从 5 开始（即 off = 5，不是 4！）。
    //   afLen == 183          → adaptation field 占满整包，off == 188，无 payload。
    //   afLen > 183（非法值） → 视为损坏包，保持 off = 4 由后续检查兜底。
    if (afc & 0x02 != 0) {
      final afLen = data[base + 4];
      if (5 + afLen <= kTsPacketSize) {
        off = 5 + afLen; // afLen == 0 时自然得到 off = 5。
      }
    }

    // afc 的 bit0 为 0 表示本包无 payload；off >= 188 同样表示没有可用 payload。
    if (afc & 0x01 == 0 || off >= kTsPacketSize) {
      i += kTsPacketSize;
      continue;
    }

    // 只在「视频 PES 起始包」处开始拼装：避免把音频/其他 PID 混进来。
    // 不做 PAT/PMT 解析 —— 直接认 video stream_id 0xE0-0xEF，
    // 与 ts_pts_normalizer 的 firstPesPtsMs 保持同一判据，简单且够用。
    if (pusi != 0) {
      if (off + 4 <= kTsPacketSize &&
          data[base + off] == 0x00 &&
          data[base + off + 1] == 0x00 &&
          data[base + off + 2] == 0x01 &&
          0xE0 <= data[base + off + 3] &&
          data[base + off + 3] <= 0xEF) {
        // 新 PES：丢弃上一段残留，重新开始拼装。
        pending.clear();
        scanned = 0;
        pendingPid = pid;
        // 跳过 PES 头（起始码 3 + stream_id 1 + 长度 2 + 标志 2 + 头长度 1），
        // 以及 PES header data length 指示的可选字段（PTS/DTS 等）。
        //
        // 注意：pesEnd **允许超出本包末尾**（此时表示本包 payload 全被 PES 头
        // 占满）。_appendRange 会因 from >= to 自然跳过，但绝不能因此丢掉
        // PID 状态 —— 后续包仍要按 pendingPid == pid 续拼，否则跨包边界的
        // SPS 会被 PES 头残留字节打断，永远扫不到起始码。
        final pesEnd = off + 9 + data[base + off + 8];
        _appendRange(pending, data, base + pesEnd, base + kTsPacketSize);
      } else {
        // 非视频 PES 起始包：结束上一段拼装。
        pending.clear();
        scanned = 0;
        pendingPid = -1;
      }
    } else if (pendingPid == pid) {
      // 同一视频 PID 的后续包：继续拼。
      _appendRange(pending, data, base + off, base + kTsPacketSize);
    } else {
      i += kTsPacketSize;
      continue;
    }

    // 每收一段就尝试找 SPS；找到立即返回（热路径，不遍历整个分片）。
    if (pending.length > scanned) {
      final buf = pending.toBytes();
      final r = _scanForSps(buf, scanned);
      if (r.info != null) return r.info;
      // 若是因为「SPS 还没收全」而中止，游标**不能越过 SPS 起点**，
      // 否则下一包到达时重扫会从 SPS 之后开始，永远补不齐这个 NAL。
      scanned = r.incompleteFrom ?? buf.length;
    }

    i += kTsPacketSize;
  }
  return null;
}

/// [_scanForSps] 的结果：要么给出解析结果，要么指出「SPS 未收全」的起点。
class _ScanResult {
  const _ScanResult(this.info, this.incompleteFrom);

  final TsVideoInfo? info;

  /// 非 null 表示在 [incompleteFrom] 处发现一个尚未收全的 SPS，
  /// 下一包到达后应从该位置重扫。
  final int? incompleteFrom;
}

void _appendRange(BytesBuilder b, Uint8List src, int from, int to) {
  if (from >= to || from < 0 || to > src.length) return;
  b.add(Uint8List.sublistView(src, from, to));
}

/// 从 [buf] 的 [from] 偏移开始扫描 Annex-B 起始码，找 SPS 并解析。
/// 从 [from] 而非 0 开始，避免同一段字节被反复扫描（热路径）。
///
/// 返回 null 既可能是「没找到 SPS」，也可能是「SPS 还没收全（跨包）」。
/// 后者由调用方在下一包到达后重扫解决 —— 因此这里**不能**把
/// 「解析失败」当成终态，也不要跳过该位置。
/// 返回 [_ScanResult]。若发现 SPS 但尚未收全（跨包），
/// 会给出应重扫的起点而不是终态 null。
_ScanResult _scanForSps(Uint8List buf, int from) {
  final n = buf.length;
  // 回退 3 字节：起始码可能横跨两次扫描的边界。
  var i = from > 3 ? from - 3 : 0;
  while (i + 3 < n) {
    // 起始码：00 00 01（4 字节形式 00 00 00 01 也含此三元组）。
    if (buf[i] == 0x00 && buf[i + 1] == 0x00 && buf[i + 2] == 0x01) {
      final nalStart = i + 3; // 指向 NAL header
      final nalType = buf[nalStart] & 0x1F;
      if (nalType == kNalTypeSps) {
        // SPS 数据 = 跳过 NAL header 之后，到下一个起始码或缓冲末尾。
        final spsStart = nalStart + 1;
        final spsEnd = _nextStartCode(buf, spsStart);
        // spsEnd 触到缓冲末尾说明 SPS 可能还没收全（跨包）。
        final atBufferEnd = spsEnd >= n;
        if (spsEnd > spsStart) {
          final info = _parseSps(Uint8List.sublistView(buf, spsStart, spsEnd));
          if (info != null) return _ScanResult(info, null);
        }
        // 未收全：记录起始码位置，等下一包补齐后从这里重扫。
        if (atBufferEnd) return _ScanResult(null, i);
      }
      i = nalStart;
    } else {
      i++;
    }
  }
  return const _ScanResult(null, null);
}

/// 从 [from] 起找下一个起始码位置，找不到返回 [src] 长度。
int _nextStartCode(Uint8List src, int from) {
  final n = src.length;
  for (var i = from; i + 2 < n; i++) {
    if (src[i] == 0x00 && src[i + 1] == 0x00 && src[i + 2] == 0x01) return i;
  }
  return n;
}

/// 解析一个 SPS（入参为「已跳过 NAL header」的 SPS 负载，可能含 emulation
/// prevention bytes）。失败返回 null。
TsVideoInfo? _parseSps(Uint8List raw) {
  final rbsp = _removeEmulationPrevention(raw);
  // 先剔除 rbsp_trailing_bits（末尾的 stop bit 0x80 与填充 0x00）。
  // 若不剔除，TS 填充用的 0xFF/0x00 尾巴会被当成合法字段读进去，
  // 从而在 SPS 被截断时解出「看似合法」的假分辨率。
  final trimmed = _trimRbspTrailing(rbsp);
  if (trimmed.length < 3) return null;

  final br = _BitReader(trimmed);
  if (trimmed.length < 4) return null;

  final profileIdc = br.u(8);
  br.u(8); // constraint_set0..5_flag + reserved_zero_2bits
  br.u(8); // level_idc
  br.ue(); // seq_parameter_set_id

  // 色度格式：缺省 4:2:0（chroma_format_idc = 1）；
  // separate_colour_plane_flag 决定 ChromaArrayType 是否为 0。
  var chromaFormatIdc = 1;
  var separateColourPlane = false;

  if (kHighProfileIdcs.contains(profileIdc)) {
    chromaFormatIdc = br.ue();
    if (chromaFormatIdc == 3) {
      separateColourPlane = br.u(1) != 0;
    }
    br.ue(); // bit_depth_luma_minus8
    br.ue(); // bit_depth_chroma_minus8
    br.u(1); // qpprime_y_zero_transform_bypass_flag
    final seqScalingMatrixPresent = br.u(1) != 0;
    if (seqScalingMatrixPresent) {
      // 关键：scaling list 的位长是可变的，跳过时**必须**逐项按 7.3.2.1.1.1
      // 的 delta_scale 语法推进，否则后续所有字段都会错位。
      final listCount = chromaFormatIdc != 3 ? 8 : 12;
      for (var i = 0; i < listCount; i++) {
        final present = br.u(1) != 0;
        if (!present) continue;
        final size = i < 6 ? 16 : 64; // 4x4 列表 16 项，8x8 列表 64 项。
        var lastScale = 8;
        var nextScale = 8;
        for (var j = 0; j < size; j++) {
          if (nextScale != 0) {
            final deltaScale = br.se();
            nextScale = (lastScale + deltaScale + 256) % 256;
          }
          lastScale = nextScale == 0 ? lastScale : nextScale;
          if (br.overflowed) break;
        }
        if (br.overflowed) break;
      }
    }
  }

  br.ue(); // log2_max_frame_num_minus4
  final picOrderCntType = br.ue();
  if (picOrderCntType == 0) {
    br.ue(); // log2_max_pic_order_cnt_lsb_minus4
  } else if (picOrderCntType == 1) {
    br.u(1); // delta_pic_order_always_zero_flag
    br.se(); // offset_for_non_ref_pic
    br.se(); // offset_for_top_to_bottom_field
    final cycle = br.ue(); // num_ref_frames_in_pic_order_cnt_cycle
    for (var i = 0; i < cycle; i++) {
      br.se(); // offset_for_ref_frame[i]
      if (br.overflowed) break;
    }
  }

  br.ue(); // max_num_ref_frames
  br.u(1); // gaps_in_frame_num_value_allowed_flag

  final picWidthInMbsMinus1 = br.ue();
  final picHeightInMapUnitsMinus1 = br.ue();
  final frameMbsOnlyFlag = br.u(1);
  if (frameMbsOnlyFlag == 0) {
    br.u(1); // mb_adaptive_frame_field_flag
  }
  br.u(1); // direct_8x8_inference_flag

  var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
  final frameCroppingFlag = br.u(1);
  if (frameCroppingFlag == 1) {
    cropLeft = br.ue();
    cropRight = br.ue();
    cropTop = br.ue();
    cropBottom = br.ue();
  }

  if (br.overflowed) return null;
  if (picWidthInMbsMinus1 < 0 || picHeightInMapUnitsMinus1 < 0) return null;

  // 规范 7.4.2.1.1：
  //   PicWidthInMbs = pic_width_in_mbs_minus1 + 1
  //   FrameHeightInMbs = (2 - frame_mbs_only_flag) * (pic_height_in_map_units_minus1 + 1)
  final frameMbsOnly = frameMbsOnlyFlag == 1 ? 1 : 0;
  var width = (picWidthInMbsMinus1 + 1) * 16;
  var height = (2 - frameMbsOnly) * (picHeightInMapUnitsMinus1 + 1) * 16;

  if (frameCroppingFlag == 1) {
    // ChromaArrayType：separate_colour_plane_flag=1 时为 0，否则 = chroma_format_idc。
    final chromaArrayType = separateColourPlane ? 0 : chromaFormatIdc;
    // SubWidthC / SubHeightC（规范表 6-1）：
    //   单色(0) 与 4:4:4(3)：1,1；4:2:2(2)：2,1；4:2:0(1，缺省)：2,2。
    final subWidthC = (chromaArrayType == 1 || chromaArrayType == 2) ? 2 : 1;
    final subHeightC = (chromaArrayType == 1) ? 2 : 1;
    width -= (cropLeft + cropRight) * subWidthC;
    height -= (cropTop + cropBottom) * subHeightC * (2 - frameMbsOnly);
  }

  if (width <= 0 || height <= 0) return null;
  // 合法性下限/上限：真实视频（哪怕 128x96 的缩略片）也远超 16x16；
  // 而 16x16 正是「SPS 被截断、尾部填充被误读」的典型假结果。
  if (width < 64 || height < 64) return null;
  if (width % 2 != 0 || height % 2 != 0) return null;
  if (width > 16384 || height > 16384) return null;

  return TsVideoInfo(width: width, height: height, profileIdc: profileIdc);
}

/// 去除 emulation prevention bytes：把 `00 00 03` 中的 `03` 去掉（生成 RBSP）。
///
/// 规范 7.4.1.1：编码器在 RBSP 中每出现两个连续 0x00 后跟 0x00/0x01/0x02/0x03
/// 时插入 0x03，解码侧需原样删除。注意只在「前两个字节确实是 00 00」时删，
/// 且删除后不清零计数 —— 标准实现就是每命中一次消耗掉整个三元组。
Uint8List _removeEmulationPrevention(Uint8List src) {
  final n = src.length;
  final out = Uint8List(n);
  var w = 0;
  var zeros = 0;
  for (var i = 0; i < n; i++) {
    final b = src[i];
    if (zeros == 2 && b == 0x03) {
      zeros = 0; // 丢弃该 0x03，且不写入。
      continue;
    }
    out[w++] = b;
    zeros = b == 0x00 ? zeros + 1 : 0;
  }
  return w == n ? out : Uint8List.sublistView(out, 0, w);
}

/// 剔除 RBSP 尾部的 TS stuffing 与 rbsp_trailing_bits（规范 7.3.2.11）。
///
/// 只处理「SPS 后面直接跟 TS 填充」这一种情况：调用方先按起始码切出 NAL，
/// 因此这里的 [src] 末尾要么是真正的 NAL 尾，要么是 0xFF/0x00 填充。
///
/// 注意**不要**无条件丢弃最后一个字节：正常的 SPS（末尾是 0x80 形式的
/// rbsp_stop_one_bit）如果把该字节当填充丢掉，就会少读一整字节，导致
/// 后续解析全部错位。仅当检测到填充时才裁剪。
Uint8List _trimRbspTrailing(Uint8List src) {
  var end = src.length;
  // 仅裁掉 0xFF stuffing（不可能是合法 SPS 尾部字节）。
  while (end > 0 && src[end - 1] == 0xFF) {
    end--;
  }
  if (end <= 0) return Uint8List(0);
  return end == src.length ? src : Uint8List.sublistView(src, 0, end);
}

/// 极简指数哥伦布位读取器。
///
/// 越界策略：读越界时 [overflowed] 置位并返回 0，**不抛异常** ——
/// 这样上层只需在若干关键点检查 overflowed，就能安全地放弃解析。
class _BitReader {
  _BitReader(this._d);

  final Uint8List _d;
  int _pos = 0; // 以 bit 为单位。

  bool overflowed = false;

  int get remaining => _d.length * 8 - _pos;

  /// 读 [n] 位无符号整数（n <= 32）。
  int u(int n) {
    if (n <= 0) return 0;
    if (_pos + n > _d.length * 8) {
      overflowed = true;
      _pos = _d.length * 8;
      return 0;
    }
    var v = 0;
    for (var i = 0; i < n; i++) {
      final byte = _d[_pos >> 3];
      final bit = (byte >> (7 - (_pos & 7))) & 1;
      v = (v << 1) | bit;
      _pos++;
    }
    return v;
  }

  /// 无符号指数哥伦布 ue(v)：前导 0 个数 = leadingZeros，
  /// 随后 1 位有效位 + leadingZeros 位后缀，值 = 2^z - 1 + suffix。
  int ue() {
    var zeros = 0;
    while (true) {
      if (_pos >= _d.length * 8) {
        overflowed = true;
        return 0;
      }
      final bit = (_d[_pos >> 3] >> (7 - (_pos & 7))) & 1;
      _pos++;
      if (bit == 1) break;
      zeros++;
      // 保护：合法 SPS 里不可能出现这么长的前导 0，说明数据已损坏；
      // 同时把 zeros 限制在 31 以内，避免 `1 << zeros` 溢出 Dart int 语义预期。
      if (zeros > 31) {
        overflowed = true;
        return 0;
      }
    }
    if (zeros == 0) return 0;
    final suffix = u(zeros);
    return (1 << zeros) - 1 + suffix;
  }

  /// 有符号指数哥伦布 se(v)：codeNum 为奇 → 正，为偶 → 负。
  int se() {
    final v = ue();
    if (overflowed) return 0;
    return (v & 1) != 0 ? (v + 1) >> 1 : -(v >> 1);
  }
}
