import 'dart:typed_data';

import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes_fast.dart';
import 'package:pointycastle/block/modes/cbc.dart';

/// 🔴🔴 2026-10-23：从媒体分片里探测**真实视频分辨率**。
///
/// 【背景】资源站大量用「media playlist + AES-128 加密 TS」交付，
/// 播放列表里**没有 `#EXT-X-STREAM-INF`、没有 RESOLUTION、没有码率目录**。
/// 这种源只能靠码率反推分辨率，而码率与分辨率**没有必然关系**：
///
/// 实测（2026-10-23）`https://play.xluuss.com/play/bW6qx64a/index.m3u8`
///   · 真实分辨率 **1920x818**（宽屏电影，1080P 级别）
///   · 首段 10.417s / 860864 字节 → 码率仅 **661 kbps**
///   · 旧逻辑按码率落档 → 判成 **360P**（错的）
///
/// 同一片源在另一个站点是 master playlist，写着
/// `RESOLUTION=1920x818` → 正确判 1080P —— 同一个视频两个结论。
///
/// 【结论】码率只能当兜底。真实分辨率必须从**码流里的 SPS** 读。
/// 本类负责：解密 → TS 解封装 → 取 SPS/VPS NAL → Exp-Golomb 解出宽高。
class MediaResolutionProbe {
  const MediaResolutionProbe._();

  /// 从分片字节探测真实宽高。
  ///
  /// [data] 需要覆盖分片开头（TS 的 SPS 在最前几个包里）。
  /// [aesKey] 非空时先做 AES-128-CBC 解密（配合 [aesIv]）。
  /// 解析失败一律返回 null，由调用方回退到码率估算。
  static ({int width, int height})? probe(
    Uint8List data, {
    Uint8List? aesKey,
    Uint8List? aesIv,
  }) {
    if (data.isEmpty) return null;
    var payload = data;
    if (aesKey != null && aesKey.length == 16) {
      final decrypted = _decryptAes128Cbc(data, aesKey, aesIv);
      if (decrypted == null || decrypted.length < 188) return null;
      payload = decrypted;
    }
    return _scanForSps(payload);
  }

  // ===== AES-128-CBC =====

  static Uint8List? _decryptAes128Cbc(
    Uint8List data,
    Uint8List key,
    Uint8List? iv,
  ) {
    try {
      const bs = 16;
      final len = (data.length ~/ bs) * bs;
      if (len == 0) return null;
      final cipherBlock = Uint8List.sublistView(data, 0, len);
      final ivBytes = (iv != null && iv.length == 16) ? iv : Uint8List(16);

      final cbc = CBCBlockCipher(AESFastEngine());
      cbc.init(false, ParametersWithIV(KeyParameter(key), ivBytes));
      final plain = Uint8List(len);
      var outOff = 0;
      for (var off = 0; off + bs <= cipherBlock.length; off += bs) {
        cbc.processBlock(cipherBlock, off, plain, outOff);
        outOff += bs;
      }
      // 末尾的 PKCS7 padding 对 SPS 探测无影响，不做去除。
      return plain;
    } catch (_) {
      return null;
    }
  }

  // ===== NAL 扫描 + SPS =====

  /// 直接在字节流里扫 H.264/HEVC 的 start code（00 00 01）找 SPS。
  ///
  /// 🔴 2026-10-23：**不能按「188 字节对齐的 TS 包」解析**。
  /// 实测 xluuss 源的 .ts 分片**前面带 564 字节自定义私有头**
  /// （ffprobe 首个包 pos=564），文件开头的 0x47 只是私有头里恰好对齐的字节。
  /// 逐包解析会因 afc=0 / 伪 PID 全部落空。
  ///
  /// start code 扫描不依赖封装结构，对「带私有头 / 非标准 TS / fMP4」都成立。
  /// 误命中（payload 里偶然出现 00 00 01）由 SPS 解析的严格校验挡掉：
  /// 位读取越界即判失败，宽高不合理即跳过。
  static ({int width, int height})? _scanForSps(Uint8List data) {
    final n = data.length;
    var p = 0;
    var scanned = 0;
    while (p + 4 <= n && scanned < 64) {
      var i = p;
      while (i + 3 < n &&
          !(data[i] == 0x00 && data[i + 1] == 0x00 && data[i + 2] == 0x01)) {
        i++;
      }
      if (i + 4 > n) break;
      scanned++;
      // 00 00 01 后面紧跟 NAL 头（4 字节形式 00 00 00 01 的 NAL 头位置相同）
      final nalStart = i + 3;
      var end = nalStart + 1;
      while (end + 3 < n &&
          !(data[end] == 0x00 &&
              data[end + 1] == 0x00 &&
              data[end + 2] == 0x01)) {
        end++;
      }
      if (end > nalStart + 1 && end <= n) {
        final nal = Uint8List.sublistView(data, nalStart, end);
        final parsed = _parseNal(nal);
        if (parsed != null) return parsed;
      }
      p = i + 3;
    }
    return null;
  }

  /// 解析单个 NAL，返回视频宽高（非 SPS/VPS 返回 null）。
  static ({int width, int height})? _parseNal(Uint8List nal) {
    if (nal.isEmpty) return null;
    final forbidden = (nal[0] & 0x80) != 0;
    if (forbidden) return null;

    // H.264：type = nal[0] & 0x1F，7 = SPS
    final h264Type = nal[0] & 0x1F;
    if (h264Type == 7) {
      // NAL 头是 1 个字节（8 bit），从第 8 bit 开始读 SPS 负载。
      final r = _BitReader(nal, 8);
      return _parseH264Sps(r);
    }

    // HEVC：type = (nal[0] >> 1) & 0x3F，33 = SPS
    final hevcType = (nal[0] >> 1) & 0x3F;
    if (hevcType == 33) {
      final r = _BitReader(nal, 2);
      return _parseHevcSps(r);
    }
    return null;
  }

  // ===== H.264 SPS =====

  static ({int width, int height})? _parseH264Sps(_BitReader r) {
    final profileIdc = r.bits(8);
    r.bits(8); // constraint flags + reserved
    r.bits(8); // level_idc
    r.ue(); // seq_parameter_set_id

    var chromaFormatIdc = 1;
    const highProfiles = <int>{
      100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135,
    };
    if (highProfiles.contains(profileIdc)) {
      chromaFormatIdc = r.ue();
      if (chromaFormatIdc == 3) r.bits(1); // separate_colour_plane_flag
      r.ue(); // bit_depth_luma_minus8
      r.ue(); // bit_depth_chroma_minus8
      r.bits(1); // qpprime_y_zero_transform_bypass_flag
      final scalingMatrixPresent = r.bits(1) == 1;
      if (scalingMatrixPresent) {
        final listCount = chromaFormatIdc != 3 ? 8 : 12;
        for (var i = 0; i < listCount; i++) {
          if (r.bits(1) == 1) _skipScalingList(r, i < 6 ? 16 : 64);
        }
      }
    }

    r.ue(); // log2_max_frame_num_minus4
    final picOrderCntType = r.ue();
    if (picOrderCntType == 0) {
      r.ue(); // log2_max_pic_order_cnt_lsb_minus4
    } else if (picOrderCntType == 1) {
      r.bits(1); // delta_pic_order_always_zero_flag
      r.se(); // offset_for_non_ref_pic
      r.se(); // offset_for_top_to_bottom_field
      final cycle = r.ue();
      for (var i = 0; i < cycle && i < 256; i++) {
        r.se();
      }
    }
    r.ue(); // max_num_ref_frames
    r.bits(1); // gaps_in_frame_num_value_allowed_flag

    final picWidthInMbsMinus1 = r.ue();
    final picHeightInMapUnitsMinus1 = r.ue();
    final frameMbsOnlyFlag = r.bits(1);
    if (frameMbsOnlyFlag == 0) r.bits(1); // mb_adaptive_frame_field_flag
    r.bits(1); // direct_8x8_inference_flag
    final frameCroppingFlag = r.bits(1);
    var cropLeft = 0, cropRight = 0, cropTop = 0, cropBottom = 0;
    if (frameCroppingFlag == 1) {
      cropLeft = r.ue();
      cropRight = r.ue();
      cropTop = r.ue();
      cropBottom = r.ue();
    }

    // crop 单位：单色 chroma_format_idc==0 时 crop_unit_x=1，
    // 否则 crop_unit_x=subWidthC；crop_unit_y=subHeightC*(2-frame_mbs_only_flag)。
    var subWidthC = 1;
    var subHeightC = 1;
    if (chromaFormatIdc == 1) {
      subWidthC = 2;
      subHeightC = 2;
    } else if (chromaFormatIdc == 2) {
      subWidthC = 2;
      subHeightC = 1;
    } else if (chromaFormatIdc == 3) {
      subWidthC = 1;
      subHeightC = 1;
    }
    final cropUnitX = chromaFormatIdc == 0 ? 1 : subWidthC;
    final cropUnitY = (chromaFormatIdc == 0 ? 1 : subHeightC) * (2 - frameMbsOnlyFlag);

    final width = (picWidthInMbsMinus1 + 1) * 16 - cropUnitX * (cropLeft + cropRight);
    final height = (2 - frameMbsOnlyFlag) * (picHeightInMapUnitsMinus1 + 1) * 16 -
        cropUnitY * (cropTop + cropBottom);
    if (!_plausible(width, height)) return null;
    return (width: width, height: height);
  }

  static void _skipScalingList(_BitReader r, int size) {
    var lastScale = 8;
    var nextScale = 8;
    for (var j = 0; j < size; j++) {
      if (nextScale != 0) {
        final deltaScale = r.se();
        nextScale = (lastScale + deltaScale + 256) % 256;
      }
      lastScale = nextScale == 0 ? lastScale : nextScale;
    }
  }

  // ===== HEVC SPS =====

  static ({int width, int height})? _parseHevcSps(_BitReader r) {
    r.bits(4); // sps_video_parameter_set_id
    final maxSubLayersMinus1 = r.bits(3);
    r.bits(1); // sps_temporal_id_nesting_flag
    _skipProfileTierLevel(r, maxSubLayersMinus1);
    r.ue(); // sps_seq_parameter_set_id
    final chromaFormatIdc = r.ue();
    if (chromaFormatIdc == 3) r.bits(1); // separate_colour_plane_flag
    final width = r.ue();
    final height = r.ue();
    final conformanceWindowFlag = r.bits(1);
    if (conformanceWindowFlag == 1) {
      r.ue(); // left
      r.ue(); // right
      r.ue(); // top
      r.ue(); // bottom
    }
    if (!_plausible(width, height)) return null;
    return (width: width, height: height);
  }

  static void _skipProfileTierLevel(_BitReader r, int maxSubLayersMinus1) {
    r.bits(2); // general_profile_space
    r.bits(1); // general_tier_flag
    r.bits(5); // general_profile_idc
    for (var i = 0; i < 32; i++) {
      r.bits(1); // general_profile_compatibility_flag
    }
    r.bits(1); // general_progressive_source_flag
    r.bits(1); // general_interlaced_source_flag
    r.bits(1); // general_non_packed_constraint_flag
    r.bits(1); // general_frame_only_constraint_flag
    r.bits(43); // reserved + constraint flags
    r.bits(8); // general_level_idc

    final subLayerProfilePresent = <int>[];
    final subLayerLevelPresent = <int>[];
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      subLayerProfilePresent.add(r.bits(1));
      subLayerLevelPresent.add(r.bits(1));
    }
    if (maxSubLayersMinus1 > 0) {
      for (var i = maxSubLayersMinus1; i < 8; i++) {
        r.bits(2); // reserved_zero_2bits
      }
    }
    for (var i = 0; i < maxSubLayersMinus1; i++) {
      if (subLayerProfilePresent[i] == 1) {
        r.bits(88);
      }
      if (subLayerLevelPresent[i] == 1) {
        r.bits(8);
      }
    }
  }

  static bool _plausible(int width, int height) {
    if (width < 16 || height < 16) return false;
    if (width > 8192 || height > 8192) return false;
    return true;
  }
}

/// 最小 Exp-Golomb 位读取器。
class _BitReader {
  final Uint8List data;
  int bitPos;

  _BitReader(this.data, this.bitPos);

  int bit() {
    if (bitPos >= data.length * 8) {
      bitPos = data.length * 8;
      return 0;
    }
    final b = (data[bitPos >> 3] >> (7 - (bitPos & 7))) & 1;
    bitPos++;
    return b;
  }

  int bits(int n) {
    var v = 0;
    for (var i = 0; i < n; i++) {
      v = (v << 1) | bit();
    }
    return v;
  }

  /// 无符号 Exp-Golomb。
  int ue() {
    var lz = 0;
    while (lz < 32 && bit() == 0) {
      lz++;
    }
    if (lz == 0) return 0;
    if (lz >= 32) return 0;
    return (1 << lz) - 1 + bits(lz);
  }

  /// 有符号 Exp-Golomb。
  int se() {
    final k = ue();
    if ((k & 1) == 0) return -(k >> 1);
    return (k + 1) >> 1;
  }
}
