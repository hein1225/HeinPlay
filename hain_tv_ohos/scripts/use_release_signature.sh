#!/usr/bin/env bash
#
# use_release_signature.sh —— 把 build-profile.json5 的签名配置切到 AGC 正式发布材料
#
# 背景
# ----
# 华为应用市场上传 .app 时若报「错误码 993 Profile文件非法」，几乎必然是包用的是
# SDK 自签的调试 Profile（type: debug）。自签材料只能让包在本机装上，
# 不具备上架资质。上架必须使用 AppGallery Connect（AGC）下发的：
#
#   - 发布证书链 .cer   （叶子 = 你的发布证书，中间 = Huawei CBG Developer Relations CA G2，
#                        根 = Huawei CBG Root CA G2）
#   - 发布 Profile .p7b （type: release，bundle-name 必须等于应用包名）
#   - 你自己的 .p12     （含与上面 .cer 叶子配对的私钥）
#
# 这些材料放在 ohos/signature/release/ 下，本脚本负责：
#   1) 校验材料齐全、证书链为 3 级、Profile 的 bundle-name 与工程一致
#   2) 用 gen_sign_material.js 生成 hvigor 接受的加密口令
#   3) 把加密口令与各项路径写回 build-profile.json5
#
# 为什么要写脚本而不是手改
# ------------------------
# hvigor 不接受明文口令（报 00303116），必须是加密串；而加密串由 material/ 目录的
# 随机材料决定，每次重新生成都会变（报 00303242）。把「生成 → 写回」固化成一步，
# 可以彻底消除手动同步遗漏。
#
# 用法：
#   bash scripts/use_release_signature.sh [storePwd] [keyPwd]     # 默认均为 123456
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REL_DIR="$PROJ_DIR/ohos/signature/release"
PROFILE_JSON5="$PROJ_DIR/ohos/build-profile.json5"
BUNDLE_NAME="com.heinplay.hain_tv_ohos"

STORE_PWD="${1:-123456}"
KEY_PWD="${2:-${1:-123456}}"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/env_ohos_linux.sh"

CER="$REL_DIR/heinplay-release.cer"
P7B="$REL_DIR/heinplay-release.p7b"
P12="$REL_DIR/heinplay-release.p12"
LIB="$OHOS_CLT/sdk/default/hms/toolchains/lib"

for f in "$CER" "$P7B" "$P12"; do
  [ -f "$f" ] || { echo "缺少发布签名材料: $f" >&2; exit 1; }
done

# --- 1. 前置校验 ---
CHAIN_LEN=$(grep -c 'BEGIN CERTIFICATE' "$CER")
if [ "$CHAIN_LEN" -ne 3 ]; then
  echo "证书链必须是 3 级（叶子 → Developer Relations CA G2 → Root CA G2），当前 $CHAIN_LEN 级" >&2
  echo "请从 AGC「证书管理」页下载「证书链」后覆盖 $CER" >&2
  exit 1
fi

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

java -jar "$LIB/hap-sign-tool.jar" verify-profile -inFile "$P7B" -outFile "$WORK/p.json" >/dev/null 2>&1
python3 - "$WORK/p.json" "$BUNDLE_NAME" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
want = sys.argv[2]
c = d['content']
bi = c['bundle-info']
assert d.get('verifiedPassed'), 'Profile 未通过官方工具校验'
assert c.get('type') == 'release', f"Profile type 必须是 release，实际 {c.get('type')}"
assert bi['bundle-name'] == want, f"Profile bundle-name={bi['bundle-name']} 与工程 {want} 不符"
print(f"    Profile OK: type={c['type']} bundle-name={bi['bundle-name']}"
      f" distribution={c.get('app-distribution-type')}")
PY

# --- 2. 生成加密口令 ---
node "$SCRIPT_DIR/gen_sign_material.js" "$REL_DIR" "$STORE_PWD" "$KEY_PWD" >/dev/null
echo "==> 加密口令材料已生成"

# --- 3. 写回 build-profile.json5 ---
python3 - "$PROFILE_JSON5" "$REL_DIR/encrypted-passwords.json" <<'PY'
import json, re, sys
profile, enc = sys.argv[1], sys.argv[2]
pwd = json.load(open(enc))
s = open(profile, encoding='utf-8').read()

repl = {
  r'"certpath"\s*:\s*"[^"]*"': '"certpath": "./signature/release/heinplay-release.cer"',
  r'"keyAlias"\s*:\s*"[^"]*"': '"keyAlias": "heinplay release"',
  r'"keyPassword"\s*:\s*"[^"]*"': f'"keyPassword": "{pwd["keyPassword"]}"',
  r'"profile"\s*:\s*"[^"]*"': '"profile": "./signature/release/heinplay-release.p7b"',
  r'"signAlg"\s*:\s*"[^"]*"': '"signAlg": "SHA256withECDSA"',
  r'"storeFile"\s*:\s*"[^"]*"': '"storeFile": "./signature/release/heinplay-release.p12"',
  r'"storePassword"\s*:\s*"[^"]*"': f'"storePassword": "{pwd["storePassword"]}"',
}
for pat, val in repl.items():
    s, n = re.subn(pat, val, s, count=1)
    if n != 1:
        raise SystemExit(f'未能替换 {pat}')
open(profile, 'w', encoding='utf-8').write(s)
print('    build-profile.json5 签名段已更新')
PY

echo
echo "完成。可直接构建："
echo "  cd ohos && \$OHOS_CLT/bin/hvigorw assembleApp -p product=default -p buildMode=release --no-daemon"
