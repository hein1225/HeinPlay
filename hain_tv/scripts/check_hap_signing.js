#!/usr/bin/env node
/**
 * check_hap_signing.js — HarmonyOS HAP 签名材料自检工具
 *
 * 背景：hvigor SignHap 报 00303242 "Unsupported state or unable to authenticate data"
 *   根因 = build-profile.json5 的 storePassword/keyPassword 密文(DevEco IDE 私有加密,
 *   0000001B 前缀)与 <storeFile同目录>/material/ 解密材料错配。
 *
 * 本工具**直接复用 DevEco 官方 DecipherUtil**(hvigor-ohos-plugin/src/utils/decipher-util.js)
 * 来验证「材料能否解开密文」，结果与实际 hvigor 构建 100% 一致，绝不误判。
 * 仅 hook 掉官方模块对 ./log/ohos-logger.js 的依赖(注入无副作用 stub)。
 *
 * 用法：
 *   node scripts/check_hap_signing.js [build-profile.json5 路径]
 *   默认读取 hain_tv/harmony_haintv/build-profile.json5
 *
 * 输出：
 *   [OK]   storePassword/keyPassword 可解密 -> SignHap 将不再报 00303242
 *   [FAIL] 材料与密文错配 -> 需在 DevEco 强制重新生成签名
 */
const Module = require('module');
const fs = require('fs');
const path = require('path');

// DevEco 官方 decipher-util.js 路径（机器相关；升级 DevEco 版本时同步此路径）
const OFFICIAL_DECI =
  'D:/Program Files/Huawei/DevEco Studio/tools/hvigor/hvigor-ohos-plugin/src/utils/decipher-util.js';

// 拦截官方模块对 ./log/ohos-logger.js 的 require，注入无副作用 stub
// （官方在解密失败时用 printErrorExit 抛出错误码，我们用它来判定 FAIL）
const _origLoad = Module._load;
Module._load = function (request, parent, isMain) {
  if (request === './log/ohos-logger.js') {
    return {
      OhosLogger: {
        getLogger: () => ({
          printErrorExit: (code) => {
            throw new Error('LOG_' + code);
          },
          debug() {},
          error() {},
          info() {},
        }),
      },
    };
  }
  return _origLoad.apply(this, arguments);
};

let DecipherUtil;
try {
  DecipherUtil = require(OFFICIAL_DECI).DecipherUtil;
} catch (e) {
  console.error('[FAIL] 无法加载官方 decipher-util.js: ' + e.message);
  console.error('       请确认 OFFICIAL_DECI 路径指向本机 DevEco 安装目录。');
  process.exit(2);
}

// ---- 入口 ----
const bpFile = process.argv[2] || path.join(__dirname, '..', 'harmony_haintv', 'build-profile.json5');
if (!fs.existsSync(bpFile)) {
  console.error('找不到 build-profile.json5: ' + bpFile);
  process.exit(2);
}
const bp = JSON.parse(fs.readFileSync(bpFile, 'utf-8'));
const cfg = bp.app && bp.app.signingConfigs && bp.app.signingConfigs[0];
if (!cfg || !cfg.material) {
  console.error('[INFO] build-profile 未配置 signingConfigs[0].material —— 无需签名或尚未配置。');
  process.exit(0);
}
const m = cfg.material;
const materialDir = path.dirname(m.storeFile.replace(/\\\\/g, '\\'));
if (!fs.existsSync(path.join(materialDir, 'material'))) {
  console.error('[FAIL] material 目录不存在: ' + path.join(materialDir, 'material'));
  console.error('       请确认 .p12/.cer/.p7b 与 material/ 是否在同一目录（DevEco 自动签名产物）。');
  process.exit(1);
}
let ok = 0,
  fail = 0;
for (const [label, pwd] of [
  ['storePassword', m.storePassword],
  ['keyPassword', m.keyPassword],
]) {
  if (!pwd) {
    console.log('[SKIP] ' + label + ' 为空');
    continue;
  }
  try {
    const plain = DecipherUtil.decryptPwd(materialDir, pwd, label);
    console.log('[OK]   ' + label + ' 解密成功 (明文长度=' + plain.length + ')');
    ok++;
  } catch (e) {
    console.log('[FAIL] ' + label + ' 解密失败: ' + (e.message || e));
    fail++;
  }
}
console.log('签名配置: ' + cfg.name + ' | 材料目录: ' + materialDir);
console.log('引用: storeFile=' + m.storeFile + ' | certpath=' + m.certpath + ' | profile=' + m.profile);
if (fail > 0) {
  console.log('\n结论: [FAIL] material 材料与密文错配 —— 命令行/IDE 构建必报 00303242。');
  console.log('修复: DevEco 打开 harmony_haintv → File → Project Structure → Signing Configs');
  console.log('      取消勾选 Automatically generate signature → Apply → 重新勾选 → Apply(强制全量重生成)。');
  process.exit(1);
}
console.log('\n结论: [OK] 材料与密文匹配，SignHap 可正常执行。');
process.exit(0);
