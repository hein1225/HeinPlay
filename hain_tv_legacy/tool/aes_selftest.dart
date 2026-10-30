// AES-128-CBC 自检：对 FIPS-197 / NIST SP 800-38A 官方向量。
// 运行：dart run tool/aes_selftest.dart
import 'dart:typed_data';
import '../lib/services/aes128_cbc.dart';

Uint8List hex(String s) {
  final out = Uint8List(s.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String toHex(Uint8List b) =>
    b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

int pass = 0, fail = 0;

void check(String name, String got, String want) {
  if (got == want) {
    pass++;
    print('  ✅ $name');
  } else {
    fail++;
    print('  ❌ $name\n     got  = $got\n     want = $want');
  }
}

void main() {
  print('=== NIST SP 800-38A F.2.2 CBC-AES128.Decrypt ===');
  // Key / IV / Ciphertext / Plaintext
  final key = hex('2b7e151628aed2a6abf7158809cf4f3c');
  final iv = hex('000102030405060708090a0b0c0d0e0f');
  final ct = hex('7649abac8119b246cee98e9b12e9197d'
      '5086cb9b507219ee95db113a917678b2'
      '73bed6b8e3c1743b7116e69e22229516'
      '3ff1caa1681fac09120eca307586e1a7');
  final pt = hex('6bc1bee22e409f96e93d7e117393172a'
      'ae2d8a571e03ac9c9eb76fac45af8e51'
      '30c81c46a35ce411e5fbc1191a0a52ef'
      'f69f2445df4f9b17ad2b417be66c3710');

  final out = Aes128Cbc.decrypt(ct, key, iv: iv);
  check('CBC 4 块解密', out == null ? 'null' : toHex(out), toHex(pt));

  print('');
  print('=== FIPS-197 C.1 AES-128 单块（IV=0 退化为 ECB）===');
  final k2 = hex('000102030405060708090a0b0c0d0e0f');
  final c2 = hex('69c4e0d86a7b0430d8cdb78070b4c55a');
  final p2 = hex('00112233445566778899aabbccddeeff');
  final o2 = Aes128Cbc.decrypt(c2, k2, iv: hex('0' * 32));
  check('AES-128 单块', o2 == null ? 'null' : toHex(o2), toHex(p2));

  print('');
  print('=== 边界：非法输入必须安全返回 null ===');
  final k = hex('000102030405060708090a0b0c0d0e0f');
  final iv0 = hex('0' * 32);
  if (Aes128Cbc.decrypt(hex('0011'), k, iv: iv0) == null) {
    pass++; print('  ✅ 非 16 倍数 → null');
  } else { fail++; print('  ❌ 非 16 倍数未返回 null'); }
  if (Aes128Cbc.decrypt(hex('00'*16), hex('0011'), iv: iv0) == null) {
    pass++; print('  ✅ 短密钥 → null');
  } else { fail++; print('  ❌ 短密钥未返回 null'); }
  if (Aes128Cbc.decrypt(hex('00'*16), k, iv: hex('0011')) == null) {
    pass++; print('  ✅ 短 IV → null');
  } else { fail++; print('  ❌ 短 IV 未返回 null'); }

  print('');
  print(fail == 0 ? '✅ 全部通过 ($pass)' : '❌ 失败 $fail 项');
}
