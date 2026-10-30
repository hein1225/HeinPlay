/// ts_video_info.dart 的最小自测。
///
/// 覆盖：
///   1) 1920x1080 的 SPS（frame_mbs_only_flag=1，cropping 4 行 → 1080）
///   2) 1920x818  的 SPS（frame_mbs_only_flag=1，map unit 高 832 + cropping 7 行 → 818）
///   3) 空数据 / 非法数据 / 非 TS 数据 → 返回 null 且**不抛异常**
///   4) 生成器往返（round-trip）验证：把 width/height 编码成合法 SPS 再解析回来
///   5) 跨 TS 包边界切开、以及带 adaptation field 的包
///
/// 测试向量全部为手工构造，不依赖任何外部文件。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hain_tv/services/ts_video_info.dart';

// ---------------------------------------------------------------------------
// 一、手工推导的固定测试向量
// ---------------------------------------------------------------------------

/// SPS: 1920x1080, High profile(100), 4:2:0, frame_mbs_only_flag=1,
///      frame_cropping bottom=4 行 → 1088-8 = 1080。
///
/// 逐位推导（RBSP，去掉 NAL header 0x67 后的 11 字节：
///   64 00 29 ac e8 07 80 22 7e 58 50）：
///   profile_idc=0x64=100            → 需读 chroma_format_idc 分支
///   constraint flags=0x00, level_idc=0x29=41
///   seq_parameter_set_id        ue=0
///   chroma_format_idc           ue=1   (4:2:0)
///   bit_depth_luma/chroma_minus8 ue=0, ue=0
///   qpprime_y_zero_bypass u(1)=0, seq_scaling_matrix_present u(1)=0
///   log2_max_frame_num_minus4   ue=0
///   pic_order_cnt_type          ue=0 → log2_max_pic_order_cnt_lsb_minus4 ue=0
///   max_num_ref_frames ue=1, gaps_in_frame_num u(1)=0
///   pic_width_in_mbs_minus1     ue=119 → (119+1)*16 = 1920
///   pic_height_in_map_units_minus1 ue=67 → (67+1)*16 = 1088
///   frame_mbs_only_flag u(1)=1, direct_8x8 u(1)=1
///   frame_cropping_flag u(1)=1 → left=0,right=0,top=0,bottom=4
///   → height = 1088 - (0+4)*2*1 = 1080  ✔
const _sps1920x1080 = <int>[
  0x67, // NAL header: forbidden_zero=0, nal_ref_idc=3, type=7 (SPS)
  0x64, 0x00, 0x29, // profile_idc=100, constraint=0x00, level_idc=41
  0xAC, 0xE8, 0x07, 0x80, 0x22, 0x7E, 0x58, 0x50, // SPS RBSP
];

/// SPS: 1920x818, High profile(100), 4:2:0, frame_mbs_only_flag=1,
///      frame_cropping bottom=7 行 → 832-14 = 818（典型电影宽银幕正片）。
///
/// 与上例唯一差别：pic_height_in_map_units_minus1 = ue=51 → (51+1)*16 = 832，
/// frame_crop_bottom_offset = ue=7 → 832 - 7*2 = 818  ✔
const _sps1920x818 = <int>[
  0x67,
  0x64, 0x00, 0x29,
  0xAC, 0xE8, 0x07, 0x80, 0x69, 0xF8, 0x88, 0x50,
];

// ---------------------------------------------------------------------------
// 二、TS 打包辅助（把 Annex-B NAL 序列装进 188 字节 TS 包）
// ---------------------------------------------------------------------------

/// 把一组 Annex-B NAL（不含起始码）打包成一个 TS 分片。
///
/// [chunkSize] 限制每个 TS 包携带的 PES 字节数，用于强制 NAL/SPS 跨包切开。
/// 不足 184 字节的余量一律用 **adaptation field stuffing** 填充（TS 规范做法），
/// **绝不把 0xFF 混进 payload** —— 否则会把 NAL 从中间截断，
/// 那是测试生成器的错误，不是解析器该容忍的输入。
/// [forceAdaptationField] 用于在**包已满**时也插入 adaptation field，
/// 专门覆盖「afc=3 且 afLen>0」这条解析路径。
Uint8List _packTs(
  List<List<int>> nals, {
  int pid = 0x0100,
  int chunkSize = 184,
  bool forceAdaptationField = false,
}) {
  final es = <int>[];
  for (final nal in nals) {
    es.addAll([0x00, 0x00, 0x00, 0x01]);
    es.addAll(nal);
  }
  // PES 头：起始码 00 00 01 + stream_id 0xE0 + 长度(0=不限) + '10'标志 + flags + hdrlen 0
  final pes = <int>[0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x00, 0x00];
  pes.addAll(es);

  final out = <int>[];
  var i = 0;
  var first = true;
  while (i < pes.length || first) {
    final avail = pes.length - i;
    final take = avail < chunkSize ? avail : chunkSize;
    final payload = pes.sublist(i, i + take);
    i += take;

    // afc=3（adaptation field + payload）：用 adaptation field 吸收全部余量。
    var afBytes = <int>[];
    final slack = 184 - payload.length;
    if (slack > 0 || (forceAdaptationField && slack >= 1)) {
      final afLen = slack - 1; // 减去 adaptation_field_length 自身 1 字节。
      if (afLen >= 1) {
        afBytes = [afLen, 0x00, ...List.filled(afLen - 1, 0xFF)];
      } else if (forceAdaptationField && slack >= 1) {
        // afLen == 0：adaptation field 只有长度字节本身（解析器需正确跳过）。
        afBytes = [0x00];
      }
    } else if (forceAdaptationField) {
      // 包已满，无余量可放 adaptation field → 本包必须少带 1 字节 payload。
      // 该场景由调用方通过 chunkSize < 184 保证，这里不做处理。
    }

    final need = 184 - afBytes.length;
    assert(payload.length <= need, 'payload 超出包容量');
    final body = [
      ...payload,
      ...List.filled(need - payload.length, 0x00), // 理论不可达（已被 af 吸收）。
    ];

    out.add(0x47);
    out.add(((first ? 0x40 : 0x00) | ((pid >> 8) & 0x1F)));
    out.add(pid & 0xFF);
    out.add(afBytes.isEmpty ? 0x10 : 0x30);
    out.addAll(afBytes);
    out.addAll(body);
    first = false;
  }
  return Uint8List.fromList(out);
}

// ---------------------------------------------------------------------------
// 三、SPS 生成器（用于 round-trip 验证）
//     —— 手工位级写入，与解析器走的是同一套 H.264 语法，方向相反。
// ---------------------------------------------------------------------------

class _BitWriter {
  final List<int> _bits = [];

  void u(int n, int v) {
    for (var i = n - 1; i >= 0; i--) {
      _bits.add((v >> i) & 1);
    }
  }

  void ue(int v) {
    final v1 = v + 1;
    var len = 0;
    while ((1 << (len + 1)) <= v1) {
      len++;
    }
    for (var i = 0; i < len; i++) {
      _bits.add(0);
    }
    for (var i = len; i >= 0; i--) {
      _bits.add((v1 >> i) & 1);
    }
  }

  void se(int v) => ue(v > 0 ? 2 * v - 1 : -2 * v);

  /// 收尾：rbsp_stop_one_bit + 对齐 0，并插入 emulation prevention bytes。
  List<int> finish() {
    _bits.add(1);
    while (_bits.length % 8 != 0) {
      _bits.add(0);
    }
    final raw = <int>[];
    for (var i = 0; i < _bits.length; i += 8) {
      var b = 0;
      for (var j = 0; j < 8; j++) {
        b = (b << 1) | _bits[i + j];
      }
      raw.add(b);
    }
    // 插入 emulation prevention：每两个连续 0x00 后若跟 <=0x03 则插 0x03。
    final out = <int>[];
    var zeros = 0;
    for (final b in raw) {
      if (zeros >= 2 && b <= 0x03) {
        out.add(0x03);
        zeros = 0;
      }
      out.add(b);
      zeros = b == 0x00 ? zeros + 1 : 0;
    }
    return out;
  }
}

/// 把 width/height 编码成一个合法的 High-profile SPS NAL（含 NAL header）。
///
/// 高度策略：用需要的 map unit 数承载目标高度，余数放进 frame_crop_bottom_offset。
/// 对 4:2:0 且 frame_mbs_only=1，crop 的 SubHeightC*1 = 2，
/// 故 padding 必然为偶数 —— 因此只支持「高度为偶数、且 16 对齐余数为偶数」的目标。
///
/// 宽度策略：宽度必须是 16 的倍数（PicWidthInMbs * 16）；若非 16 对齐，
/// 用 frame_crop_left/right 补足（SubWidthC = 2，故只能补偶数）。
List<int> _buildSpsNal(int width, int height, {int profileIdc = 100}) {
  final mapWidths = (width + 15) ~/ 16;
  final paddedW = mapWidths * 16;
  assert((paddedW - width) % 2 == 0, '宽度需为偶数且 16 对齐余数为偶数');
  final cropLeft = (paddedW - width) ~/ 2;
  final cropRight = 0;

  final mapUnits = (height + 15) ~/ 16;
  final padded = mapUnits * 16;
  final cropBottom = (padded - height) ~/ 2;
  assert(padded - cropBottom * 2 == height, '高度需为偶数');

  final bw = _BitWriter();
  bw.u(8, profileIdc);
  bw.u(8, 0x00); // constraint flags
  bw.u(8, 41); // level_idc
  bw.ue(0); // seq_parameter_set_id
  if (profileIdc == 100) {
    bw.ue(1); // chroma_format_idc = 4:2:0
    bw.ue(0); // bit_depth_luma_minus8
    bw.ue(0); // bit_depth_chroma_minus8
    bw.u(1, 0); // qpprime_y_zero_transform_bypass_flag
    bw.u(1, 0); // seq_scaling_matrix_present_flag
  }
  bw.ue(0); // log2_max_frame_num_minus4
  bw.ue(0); // pic_order_cnt_type = 0
  bw.ue(0); // log2_max_pic_order_cnt_lsb_minus4
  bw.ue(1); // max_num_ref_frames
  bw.u(1, 0); // gaps_in_frame_num_value_allowed_flag
  bw.ue(mapWidths - 1); // pic_width_in_mbs_minus1
  bw.ue(mapUnits - 1); // pic_height_in_map_units_minus1
  bw.u(1, 1); // frame_mbs_only_flag
  bw.u(1, 1); // direct_8x8_inference_flag
  if (cropBottom > 0 || cropLeft > 0 || cropRight > 0) {
    bw.u(1, 1); // frame_cropping_flag
    bw.ue(cropLeft); // left
    bw.ue(cropRight); // right
    bw.ue(0); // top
    bw.ue(cropBottom); // bottom
  } else {
    bw.u(1, 0);
  }
  bw.u(1, 0); // vui_parameters_present_flag
  return [0x67, ...bw.finish()];
}

void main() {
  group('手工构造的 SPS 向量', () {
    test('1920x1080（1088 map + crop bottom 4）', () {
      final ts = _packTs([_sps1920x1080]);
      final info = parseTsVideoInfo(ts);
      expect(info, isNotNull);
      expect(info!.width, 1920);
      expect(info.height, 1080);
      expect(info.profileIdc, 100);
    });

    test('1920x818（832 map + crop bottom 7）', () {
      final ts = _packTs([_sps1920x818]);
      final info = parseTsVideoInfo(ts);
      expect(info, isNotNull);
      expect(info!.width, 1920);
      expect(info.height, 818);
      expect(info.profileIdc, 100);
    });

    test('先出现 PPS/Slice 再出现 SPS 也能找到', () {
      // 0x68 = PPS, 0x65 = IDR slice；解析器应跳过它们，直到 type=7。
      final ts = _packTs([
        [0x68, 0xEB, 0xEC, 0xB2, 0x2C],
        [0x65, 0x88, 0x84, 0x00],
        _sps1920x1080,
      ]);
      expect(parseTsVideoInfo(ts)?.height, 1080);
    });
  });

  group('TS 容器健壮性', () {
    test('SPS 跨 TS 包边界被切开仍能解析', () {
      // chunkSize 取真实可能出现的小值，强制 SPS 分散到多个包；
      // 每个包用 adaptation field 吸收余量，payload 内不掺填充字节。
      for (final cs in <int>[184, 170, 60, 40, 20, 12, 8]) {
        final ts = _packTs([_sps1920x1080], chunkSize: cs);
        expect(parseTsVideoInfo(ts)?.width, 1920, reason: 'chunkSize=$cs 宽度');
        expect(parseTsVideoInfo(ts)?.height, 1080, reason: 'chunkSize=$cs 高度');
      }
    });

    test('带 adaptation field 的包仍能解析', () {
      final ts = _packTs([_sps1920x818], forceAdaptationField: true);
      expect(parseTsVideoInfo(ts)?.height, 818);
    });

    test('adaptation_field_length = 0 的包仍能解析', () {
      // afLen==0 时 adaptation field 只有长度字节本身，payload 从第 5 字节开始。
      // 用恰好 184 字节的 payload 构造：slack=0，强制走 afLen=0 分支。
      final es = <int>[0x00, 0x00, 0x00, 0x01, ..._sps1920x1080];
      final pes = <int>[
        0x00, 0x00, 0x01, 0xE0, 0x00, 0x00, 0x80, 0x00, 0x00,
        ...es,
      ];
      // 补齐到 184 字节 payload，构造 afc=3 且 afLen=0 的包。
      final payload = [...pes, ...List.filled(184 - pes.length, 0x00)];
      final pkt = <int>[
        0x47, 0x40, 0x00, 0x30, // afc=3
        0x00, // adaptation_field_length = 0
        ...payload,
      ];
      expect(parseTsVideoInfo(Uint8List.fromList(pkt))?.height, 1080);
    });

    test('数据尾部有非 188 对齐的前缀时仍能解析', () {
      final ts = _packTs([_sps1920x1080]);
      final withJunk = Uint8List.fromList([0xDE, 0xAD, 0xBE, ...ts]);
      expect(parseTsVideoInfo(withJunk)?.width, 1920);
    });
  });

  group('非法输入不抛异常', () {
    test('空数据', () {
      expect(parseTsVideoInfo(Uint8List(0)), isNull);
    });

    test('全零数据 / 随机垃圾', () {
      expect(parseTsVideoInfo(Uint8List(376)), isNull);
      expect(parseTsVideoInfo(Uint8List.fromList(List.filled(400, 0xAA))), isNull);
    });

    test('不足一个 TS 包', () {
      expect(parseTsVideoInfo(Uint8List.fromList(List.filled(100, 0x47))), isNull);
    });

    test('同步字节正确但内容是垃圾', () {
      final junk = Uint8List(188 * 4);
      for (var i = 0; i < junk.length; i += 188) {
        junk[i] = 0x47;
      }
      expect(parseTsVideoInfo(junk), isNull);
    });

    test('有 SPS 起始码但 RBSP 被截断', () {
      final truncated = Uint8List.fromList([
        ..._packTs([
          [0x67, 0x64, 0x00, 0x29, 0xAC], // 只有 5 字节，远不足 SPS 语法
        ]),
      ]);
      expect(parseTsVideoInfo(truncated), isNull);
    });

    test('所有非法输入均不抛异常', () {
      final inputs = <Uint8List>[
        Uint8List(0),
        Uint8List(1),
        Uint8List.fromList(List.filled(188, 0x47)),
        Uint8List.fromList(List.filled(188 * 3, 0xFF)),
        Uint8List.fromList(List.generate(500, (i) => (i * 37) & 0xFF)),
      ];
      for (final input in inputs) {
        expect(() => parseTsVideoInfo(input), returnsNormally);
      }
    });
  });

  group('生成器往返验证（round-trip）', () {
    const cases = <List<int>>[
      [1920, 1080],
      [1920, 818],
      [1280, 720],
      [640, 360],
      [3840, 2160],
      [1920, 800],
      [640, 480], // 4:3
      [720, 576], // PAL
      [1280, 532], // 宽银幕 + 非 16 对齐余数
    ];

    for (final c in cases) {
      final w = c[0], h = c[1];
      test('$w x $h', () {
        final nal = _buildSpsNal(w, h);
        final ts = _packTs([nal]);
        final info = parseTsVideoInfo(ts);
        expect(info, isNotNull, reason: '$w x $h 应被解析出来');
        expect(info!.width, w);
        expect(info.height, h);
        expect(info.profileIdc, 100);
      });
    }

    test('生成器产物与手写向量语义一致（尾部填充可不同）', () {
      // 说明：两者只在**结束位/填充**上可能不同 —— 手写向量末尾带了 VUI 段
      // （...58 50），生成器到 rbsp_stop 就结束（...7e 54）。SPS 的有效字段
      // （profile_idc / chroma / 宽高 / cropping）完全一致，解析结果必须相同。
      // 因此这里比较「解析出的语义」，而不是逐字节相等。
      final fromGen = parseTsVideoInfo(_packTs([_buildSpsNal(1920, 1080)]));
      final fromLit = parseTsVideoInfo(_packTs([_sps1920x1080]));
      expect(fromGen?.width, fromLit?.width);
      expect(fromGen?.height, fromLit?.height);
      expect(fromGen?.profileIdc, fromLit?.profileIdc);
      expect(fromGen?.width, 1920);
      expect(fromGen?.height, 1080);

      // 有效字段前缀应当一致（差异只允许出现在尾部的结束/填充位）。
      final gen = _buildSpsNal(1920, 1080).sublist(0, 10);
      final lit = _sps1920x1080.sublist(0, 10);
      expect(gen.sublist(0, 9), equals(lit.sublist(0, 9)),
          reason: '前 9 字节编码了 profile/chroma/crop 等全部有效字段');
    });
  });

  group('Main profile（无 chroma_format_idc 分支）', () {
    test('1920x1080 main profile 可解析', () {
      final nal = _buildSpsNal(1920, 1080, profileIdc: 77);
      final info = parseTsVideoInfo(_packTs([nal]));
      // main profile 走「chroma 缺省 4:2:0」分支，结果应一致。
      expect(info?.width, 1920);
      expect(info?.height, 1080);
      expect(info?.profileIdc, 77);
    });
  });
}
