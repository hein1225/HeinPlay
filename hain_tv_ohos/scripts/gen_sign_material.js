#!/usr/bin/env node
/*
 * gen_sign_material.js —— 为 hvigor 生成 DevEco 兼容的签名口令加密材料
 *
 * 背景
 * ----
 * hvigor 不允许在 build-profile.json5 里写明文口令：storePassword / keyPassword
 * 必须是 DevEco Studio 用「签名材料」加密后的十六进制串（长度 ≥32 且为偶数）。
 * 解密逻辑见 hvigor-ohos-plugin/src/utils/decipher-util.js，算法完全确定：
 *
 *   1) material/fd/<3 个子目录，各含 1 个 16 字节文件>   → fd1, fd2, fd3
 *   2) material/ac/<1 个文件>                            → salt（16 字节）
 *   3) material/ce/<1 个文件>                            → 被加密的工作密钥
 *   4) xored   = fd1 ^ fd2 ^ fd3 ^ component
 *      rootKey = PBKDF2(xored.toString(), salt, 10000, 16, 'sha256')
 *      workKey = AES-128-GCM-Decrypt(rootKey, material/ce 文件)   ← 16 字节
 *   5) 明文口令 = AES-128-GCM-Decrypt(workKey, hex 串)
 *
 * 密文容器格式（由 decrypt() 反推）：
 *   [4 字节大端 = 密文长度 + 16][12 字节 IV][密文][16 字节 GCM tag]
 *   校验：i = 总长 - 4 - e 必须等于 IV 长度 12
 *
 * 本脚本按上述格式生成 material/ 目录与两个加密口令，
 * 使 Linux/CI 环境下 `flutter build hap` 能完成自动签名，无需 DevEco GUI。
 *
 * 用法：
 *   node scripts/gen_sign_material.js <signatureDir> <storePwd> <keyPwd>
 * 例：
 *   node scripts/gen_sign_material.js ohos/signature 123456 123456
 */

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

// 与 decipher-util.js 中的 DecipherUtil.component 完全一致
const COMPONENT = Buffer.from([
  49, 243, 9, 115, 214, 175, 91, 184, 211, 190, 177, 88, 101, 131, 192, 119,
]);

/** 按 hvigor 的容器格式加密：header || iv || ciphertext || tag */
function seal(key, plaintext) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-128-gcm', key, iv);
  const ct = Buffer.concat([cipher.update(plaintext), cipher.final()]);
  const tag = cipher.getAuthTag();
  const header = Buffer.alloc(4);
  header.writeInt32BE(ct.length + tag.length, 0);
  return Buffer.concat([header, iv, ct, tag]);
}

function xorAll(bufs) {
  const out = Buffer.alloc(bufs[0].length);
  for (let i = 0; i < out.length; i++) {
    let v = 0;
    for (const b of bufs) v ^= b[i];
    out[i] = v;
  }
  return out;
}

function main() {
  const [, , sigDirArg, storePwdArg, keyPwdArg] = process.argv;
  if (!sigDirArg || !storePwdArg) {
    console.error('用法: node gen_sign_material.js <signatureDir> <storePwd> [keyPwd]');
    process.exit(2);
  }
  const sigDir = path.resolve(sigDirArg);
  const storePwd = storePwdArg;
  const keyPwd = keyPwdArg || storePwdArg;
  const matDir = path.join(sigDir, 'material');

  // 幂等：每次重建，避免残留旧材料导致口令对不上
  fs.rmSync(matDir, { recursive: true, force: true });
  for (const d of ['fd', 'ac', 'ce']) {
    fs.mkdirSync(path.join(matDir, d), { recursive: true });
  }

  // 1) fd：3 个子目录，各放 1 个 16 字节随机文件
  const fdParts = [];
  for (let i = 0; i < 3; i++) {
    const part = crypto.randomBytes(16);
    fdParts.push(part);
    const sub = path.join(matDir, 'fd', `p${i}`);
    fs.mkdirSync(sub, { recursive: true });
    fs.writeFileSync(path.join(sub, 'd'), part);
  }

  // 2) ac：盐，16 字节
  const salt = crypto.randomBytes(16);
  fs.writeFileSync(path.join(matDir, 'ac', 's'), salt);

  // 3) 推导 rootKey，并用它加密「工作密钥」
  const xored = xorAll([...fdParts, COMPONENT]);
  const rootKey = crypto.pbkdf2Sync(xored.toString(), salt, 1e4, 16, 'sha256');
  const workKey = crypto.randomBytes(16);
  fs.writeFileSync(path.join(matDir, 'ce', 'w'), seal(rootKey, workKey));

  // 4) 用工作密钥加密明文口令，得到 build-profile.json5 里该填的十六进制串
  const storeEnc = seal(workKey, Buffer.from(storePwd, 'utf8')).toString('hex');
  const keyEnc = seal(workKey, Buffer.from(keyPwd, 'utf8')).toString('hex');

  const outFile = path.join(sigDir, 'encrypted-passwords.json');
  fs.writeFileSync(
    outFile,
    JSON.stringify({ storePassword: storeEnc, keyPassword: keyEnc }, null, 2) + '\n',
  );

  console.log('已生成签名材料: ' + matDir);
  console.log('storePassword(加密): ' + storeEnc);
  console.log('keyPassword(加密)  : ' + keyEnc);
  console.log('已写出: ' + outFile);
}

main();