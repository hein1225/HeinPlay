#!/usr/bin/env bash
#
# gen_ohos_signature.sh —— 在 Linux/CI 环境下生成鸿蒙 HAP 自动签名材料
#
# 为什么需要这个脚本
# ------------------
# DevEco Studio 的「自动签名」依赖 GUI 与 Windows 路径（C:\Users\<user>\.ohos\config\...），
# 在 Linux/CI 上无法使用。而 hvigor 又强制要求 build-profile.json5 中的
# storePassword / keyPassword 必须是加密串（长度 ≥32 的十六进制），不接受明文。
#
# 本脚本用 SDK 自带的 OpenHarmony 调试签名材料（command-line-tools/sdk/.../toolchains/lib）
# 生成一套完全自包含、可离线复现的签名材料，放在工程内的 ohos/signature/ 下：
#
#   signature/
#   ├── OpenHarmony.p12          SDK 自带密钥库（含调试私钥与 CA 链）
#   ├── ohos_debug.cer           应用证书链：叶子 → Application CA → Root CA
#   ├── profile.json             按 bundleName 定制的调试 Profile（明文）
#   ├── profile.p7b              Profile 签名结果（hap-sign-tool sign-profile 产出）
#   ├── material/                hvigor 口令解密所需的加密材料（fd/ac/ce 三段）
#   └── encrypted-passwords.json 加密后的 storePassword / keyPassword
#
# 关键点（踩坑记录）
# ------------------
# 1) 叶子证书必须取 UnsgnedDebugProfileTemplate.json 里的 development-certificate，
#    它由 Application CA 签发；直接 keytool -exportcert 导出的
#    "openharmony application release" 是自签名证书（链长 1），会导致
#    "verify certificate chain failed! Signature does not match."
# 2) profile.json 的 development-certificate 必须是真实换行，写成字面 \n 会触发
#    "Illegal base64 character 20"。
# 3) 口令密文格式：[4字节大端 密文长度][12字节 IV][密文][16字节 GCM tag]，
#    由 scripts/gen_sign_material.js 按 hvigor 的 decipher-util 逻辑生成。
#
# 用法：
#   bash scripts/gen_ohos_signature.sh [storePwd] [keyPwd]     # 默认均为 123456
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SIG_DIR="$PROJ_DIR/ohos/signature"
STORE_PWD="${1:-123456}"
KEY_PWD="${2:-${1:-123456}}"

# 载入工具链环境（提供 OHOS_CLT / JAVA_HOME 等）
# shellcheck source=/dev/null
source "$SCRIPT_DIR/env_ohos_linux.sh"

LIB="$OHOS_CLT/sdk/default/hms/toolchains/lib"
P12_SRC="$LIB/OpenHarmony.p12"
TEMPLATE="$LIB/UnsgnedDebugProfileTemplate.json"
SIGN_TOOL="$LIB/hap-sign-tool.jar"
# 必须与 ohos/AppScope/app.json5 的 bundleName 完全一致，否则 profile 签名虽通过，
# 但 hap 安装时 bundle 校验失败。
# 2026-10-12：由 com.heinplay.hain_tv 改为 com.heinplay.hain_tv_ohos —— 与 Android
# 主工程（com.heinplay.hain_tv）解耦，便于同一设备并存安装。
BUNDLE_NAME="com.heinplay.hain_tv_ohos"

for f in "$P12_SRC" "$TEMPLATE" "$SIGN_TOOL"; do
  [ -f "$f" ] || { echo "缺少签名素材: $f" >&2; exit 1; }
done

mkdir -p "$SIG_DIR"
echo "==> 签名目录: $SIG_DIR"

# --- 1. 密钥库 ---
cp -f "$P12_SRC" "$SIG_DIR/OpenHarmony.p12"

# --- 2. 应用证书链：模板叶子证书 + Application CA + Root CA ---
python3 - "$TEMPLATE" "$SIG_DIR/ohos_debug.cer" <<'PY'
import json, sys
tpl, out = sys.argv[1], sys.argv[2]
d = json.load(open(tpl))
cert = d['bundle-info']['development-certificate']
if '\\n' in cert:                      # 防御：字面 \n 会破坏 base64 解析
    cert = cert.replace('\\n', '\n')
if not cert.endswith('\n'):
    cert += '\n'
open(out, 'w').write(cert)
print('    叶子证书已提取（签发者应为 OpenHarmony Application CA）')
PY

# 从密钥库导出 Application CA 与 Root CA 并追加，构成完整链
for alias in "openharmony application ca" "openharmony application root ca"; do
  keytool -exportcert -alias "$alias" -keystore "$SIG_DIR/OpenHarmony.p12" \
    -storetype PKCS12 -storepass "$STORE_PWD" -rfc 2>/dev/null \
    | sed -n '/BEGIN CERTIFICATE/,/END CERTIFICATE/p' >> "$SIG_DIR/ohos_debug.cer"
done
CHAIN_LEN=$(grep -c 'BEGIN CERTIFICATE' "$SIG_DIR/ohos_debug.cer")
echo "==> 证书链长度: $CHAIN_LEN（应为 3）"
[ "$CHAIN_LEN" -eq 3 ] || { echo "证书链拼装失败" >&2; exit 1; }

# --- 3. 定制 Profile（bundleName 与工程一致，有效期 5 年）---
python3 - "$TEMPLATE" "$SIG_DIR/profile.json" "$SIG_DIR/ohos_debug.cer" "$BUNDLE_NAME" <<'PY'
import json, sys, time
tpl, out, cerfile, bundle = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
d = json.load(open(tpl))
d['bundle-info']['bundle-name'] = bundle
d['bundle-info']['development-certificate'] = open(cerfile).read()   # 真实换行
now = int(time.time())
d['validity'] = {'not-before': now - 3600, 'not-after': now + 5 * 365 * 24 * 3600}
d.pop('debug-info', None)          # 去掉 udid 白名单，便于任意设备安装
json.dump(d, open(out, 'w'), indent=4)
print('    profile.json 已生成, bundle-name =', bundle)
PY

# --- 4. 签名 Profile ---
java -jar "$SIGN_TOOL" sign-profile \
  -keyAlias "openharmony application profile release" \
  -signAlg "SHA256withECDSA" -mode "localSign" \
  -profileCertFile "$LIB/OpenHarmonyProfileRelease.pem" \
  -inFile "$SIG_DIR/profile.json" -keystoreFile "$SIG_DIR/OpenHarmony.p12" \
  -outFile "$SIG_DIR/profile.p7b" \
  -keyPwd "$STORE_PWD" -keystorePwd "$STORE_PWD" >/dev/null
echo "==> profile.p7b 已签名"

# --- 5. hvigor 口令加密材料 ---
node "$SCRIPT_DIR/gen_sign_material.js" "$SIG_DIR" "$STORE_PWD" "$KEY_PWD" >/dev/null
echo "==> 加密口令材料已生成"

echo
echo "完成。build-profile.json5 的 signingConfigs.material 应指向："
echo "  certpath   ./signature/ohos_debug.cer"
echo "  profile    ./signature/profile.p7b"
echo "  storeFile  ./signature/OpenHarmony.p12"
echo "  口令请取 signature/encrypted-passwords.json 中的加密串"