// 端到端验证：方案 A（解密 → 去填充 → 读 PTS → 平移 → 自校验）全链路。
//
// 判据（2026-10-12 定下的铁律）：
//   ① 字节判据：Dart 解密 + PKCS7 去填充 == openssl 解密结果（逐字节）
//   ② residual 判据：平移前后 firstPts 差 == deltaMs（唯一可靠的 PTS 判据）
//   ③ 明文判据：明文里能读到 PTS（旧架构下密文恒读不到 ⇒ 50/50 全失败）
//
// 运行：dart run tool/pts_decrypt_e2e.dart
import 'dart:io';
import 'dart:typed_data';

import '../lib/services/aes128_cbc.dart';
import '../lib/services/ts_pts_normalizer.dart';

const String _probeDir = '/tmp/ptsprobe';

/// 与 local_m3u8_proxy.dart 的 _stripPkcs7 保持一致。
Uint8List stripPkcs7(Uint8List data) {
  if (data.isEmpty) return data;
  final pad = data[data.length - 1];
  if (pad < 1 || pad > 16 || pad > data.length) return data;
  return Uint8List.sublistView(data, 0, data.length - pad);
}

/// 与 local_m3u8_proxy.dart 的 _hexToBytes 保持一致。
Uint8List hexToBytes(String hex) {
  var h = hex.trim();
  if (h.length.isOdd) h = '0$h';
  final out = Uint8List(h.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(h.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

int _pass = 0;
int _fail = 0;

/// 把 33-bit PTS 的回绕表示归一化回有符号毫秒，便于阅读。
///
/// PTS 是 33-bit / 90kHz，约 26.5 小时回绕一次；负 delta 会让结果绕到
/// 接近 2^33 的大正数。这是**规范常态而非 bug**，但打印时必须还原成
/// 有符号值，否则显示成 95420581 会误判成「校验放水」。
int signedMs(int raw) {
  const mod = 0x1FFFFFFFF;
  final ticks = raw * 90;
  var t = ticks % (mod + 1);
  if (t > (mod + 1) ~/ 2) t -= (mod + 1);
  return t ~/ 90;
}

void check(bool ok, String label, String detail) {
  if (ok) {
    _pass++;
    print('  ✅ $label — $detail');
  } else {
    _fail++;
    print('  ❌ $label — $detail');
  }
}

/// 与 local_m3u8_proxy.dart 的 _looksLikePlainTs 保持一致。
bool looksLikePlainTs(Uint8List data) {
  if (data.length < 188 * 4) return false;
  const kTsPacket = 188;
  const kSync = 0x47;
  var hit = 0;
  for (var i = 0; i < 8; i++) {
    final off = i * kTsPacket;
    if (off >= data.length) break;
    if (data[off] == kSync) hit++;
  }
  return hit >= 6;
}

void main() {
  final dir = Directory(_probeDir);
  if (!dir.existsSync()) {
    print('❌ 探测目录不存在：$_probeDir');
    exit(1);
  }

  final keyFile = File('$_probeDir/key.bin');
  if (!keyFile.existsSync()) {
    print('❌ key.bin 不存在');
    exit(1);
  }
  final key = Uint8List.fromList(keyFile.readAsBytesSync());
  print('密钥 (${key.length} 字节): ${key.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}');
  print('IV: 全零（源声明 IV=0x0000...）\n');

  final iv = Uint8List(16);

  // 找出所有 .enc 且有对应 .ts（openssl 参考明文）的分片
  final encFiles = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.enc'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  print('共 ${encFiles.length} 个密文分片\n');

  for (final encFile in encFiles) {
    final name = encFile.uri.pathSegments.last.replaceAll('.enc', '');
    final refFile = File('$_probeDir/$name.ts');
    final cipher = Uint8List.fromList(encFile.readAsBytesSync());

    print('── $name ──');
    print('  下载 ${cipher.length} 字节');

    // ① 哨兵：先判是否本就是明文（探测集中有 4 个坏样本）
    if (looksLikePlainTs(cipher)) {
      final p = firstPesPtsMs(cipher, videoOnly: true);
      check(p != null, '明文哨兵',
          '源返回即明文（sync@188 命中 ≥6/8），直接读 PTS=${p ?? "null"}ms —— 不解密');
      if (p != null) {
        final shifted = normalizeTsPts(cipher, -24560);
        final v = verifyPtsShift(cipher, shifted, -24560, videoOnly: true);
        check(v.ok, 'residual（明文路径）',
            'before=${v.beforeMs}ms after=${signedMs(v.afterMs!)}ms'
            '（原始 33-bit=${v.afterMs}）差=${signedMs(v.afterMs!) - v.beforeMs!}ms'
            ' 期望=-24560ms');
      }
      print('');
      continue;
    }

    // ① 解密
    final padded = Aes128Cbc.decrypt(cipher, key, iv: iv);
    if (padded == null) {
      check(false, '解密', 'Aes128Cbc.decrypt 返回 null');
      continue;
    }

    // ② 去填充
    final plain = stripPkcs7(padded);
    print('  去填充 ${padded.length - plain.length} 字节 → 明文 ${plain.length} 字节');

    // ③ 字节判据：与 openssl 参考明文比对
    if (refFile.existsSync()) {
      final ref = Uint8List.fromList(refFile.readAsBytesSync());
      final same = plain.length == ref.length &&
          _equalBytes(plain, ref);
      check(same, '字节一致',
          same ? '与 openssl 参考明文逐字节相同' : 'Dart=${plain.length} openssl=${ref.length}（不一致）');
    } else {
      print('  ⚠️  无参考明文 $name.ts，跳过字节比对');
    }

    // ④ 明文判据：明文里必须能读到 PTS（旧架构在密文上恒 null）
    final firstPlain = firstPesPtsMs(plain, videoOnly: true);
    if (firstPlain == null) {
      check(false, '明文读 PTS', 'firstPesPtsMs 返回 null');
      continue;
    }
    final firstCipher = firstPesPtsMs(cipher, videoOnly: true);
    check(firstCipher == null, '密文读 PTS 应为 null',
        '明文=$firstPlain ms，密文=${firstCipher ?? "null"}'
        '${firstCipher == null ? "（印证旧架构 50/50 全失败）" : "（⚠️ 密文竟读到了 PTS）"}');

    // ⑤ residual 判据：平移前后差必须精确等于 delta
    for (final deltaMs in <int>[-24560, -25400, 0, 5000]) {
      if (deltaMs == 0) continue;
      final shifted = normalizeTsPts(plain, deltaMs);
      final v = verifyPtsShift(plain, shifted, deltaMs, videoOnly: true);
      check(v.ok, 'residual delta=$deltaMs',
          'ok=${v.ok} before=${v.beforeMs} after=${v.afterMs}'
          ' 差=${v.afterMs! - v.beforeMs!} 期望=$deltaMs reason=${v.reason ?? "-"}');
    }
    print('');
  }

  print('════════════════════════════════');
  print('通过 $_pass，失败 $_fail');
  if (_fail > 0) exit(1);
  print('✅ 方案 A 全链路验证通过');
}

bool _equalBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
