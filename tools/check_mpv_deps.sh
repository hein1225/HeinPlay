#!/usr/bin/env bash
# HeinPlay mpv 内核依赖巡检（防漂移闸门）
#
# 用途：构建前 / 发版前确认「四个工程的 mpv 内核来源」符合
#       docs/mpv-dependency-contract.md 的契约。
# 用法：bash tools/check_mpv_deps.sh
# 退出码：0 = 全部符合；1 = 存在不符合项（详见输出）
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

RC=0
ok()   { printf '  ✅ %s\n' "$1"; }
bad()  { printf '  ❌ %s\n' "$1"; RC=1; }
warn() { printf '  ⚠️  %s\n' "$1"; }

# 允许的来源：.mpv-android（Android 本地构建树）或 third_party（CI 资产解包）
# 禁止：.mpv-build（鸿蒙 master 交叉编译树，与 Android 0.41.0 不同源）
check_include() {
  local label="$1" dir="$2" expect_hdr="${3:-include/mpv/client.h}"
  if [ ! -e "$dir" ]; then
    bad "$label：来源不存在 -> $dir"
    return
  fi
  case "$dir" in
    *".mpv-build"*)
      bad "$label：来源非法（.mpv-build 鸿蒙树，与 Android 0.41.0 不同源） -> $dir"
      return;;
  esac
  if [ -e "$dir/$expect_hdr" ]; then
    local md5
    md5=$(md5sum "$dir/$expect_hdr" 2>/dev/null | cut -d' ' -f1)
    ok "$label：$dir  (client.h md5=$md5)"
  else
    bad "$label：缺少 $expect_hdr -> $dir"
  fi
}

echo "=== HeinPlay mpv 内核依赖巡检 ==="
echo "仓库根: $ROOT"
echo

echo "[1] Android 主工程 hain_tv"
H_MAIN="$ROOT/hain_tv"
if [ -e "$H_MAIN/../.mpv-android/src/mpv/include/mpv/client.h" ]; then
  check_include "hain_tv 头文件" "$ROOT/.mpv-android/src/mpv"
else
  check_include "hain_tv 头文件" "$H_MAIN/third_party"
fi
for abi in arm64-v8a armeabi-v7a; do
  so="$H_MAIN/android/app/src/main/jniLibs/$abi/libmpv.so"
  if [ -e "$so" ]; then
    ok "hain_tv libmpv.so [$abi]  $(md5sum "$so" | cut -d' ' -f1)"
  else
    warn "hain_tv libmpv.so [$abi] 未就位（构建时会由 CI/本地构建补齐）"
  fi
done

echo
echo "[2] Android tvLegacy hain_tv_legacy"
L="$ROOT/hain_tv_legacy"
if [ -e "$ROOT/.mpv-android/src/mpv/include/mpv/client.h" ]; then
  check_include "tvLegacy 头文件" "$ROOT/.mpv-android/src/mpv"
else
  check_include "tvLegacy 头文件" "$L/third_party"
fi
for abi in arm64-v8a armeabi-v7a; do
  so="$L/android/app/src/main/jniLibs/$abi/libmpv.so"
  if [ -e "$so" ]; then
    ok "tvLegacy libmpv.so [$abi]  $(md5sum "$so" | cut -d' ' -f1)"
  else
    warn "tvLegacy libmpv.so [$abi] 未就位（构建时会由 CI/本地构建补齐）"
  fi
done

echo
echo "[3] Windows 桌面壳 hain_tv/third_party/mpv-windows"
check_include "Windows 头文件" "$H_MAIN/third_party/mpv-windows" "include/mpv/client.h"
if [ -e "$H_MAIN/third_party/mpv-windows/bin/libmpv-2.dll" ]; then
  ok "Windows libmpv-2.dll  $(md5sum "$H_MAIN/third_party/mpv-windows/bin/libmpv-2.dll" | cut -d' ' -f1)"
else
  warn "Windows libmpv-2.dll 未就位（CI 会从 HeinPlayMPV 资产解包）"
fi

echo
echo "[4] Linux 桌面壳 hain_tv/third_party/mpv-linux"
if [ -e "$H_MAIN/third_party/mpv-linux/libmpv.so.2" ]; then
  ok "Linux libmpv.so.2（随包分发，与 CI 同源）  $(md5sum "$H_MAIN/third_party/mpv-linux/libmpv.so.2" | cut -d' ' -f1)"
else
  bad "Linux libmpv.so.2 未就位 —— 本地构建会回退到系统 libmpv（≠ CI 版本），发版前必须解包 third_party/mpv-linux"
fi
if [ -e "$H_MAIN/third_party/ffmpeg-mini/lib" ]; then
  ok "Linux 精简 ffmpeg（third_party/ffmpeg-mini）"
else
  warn "Linux 精简 ffmpeg 未就位（CI 会从 HeinPlayMPV 资产解包）"
fi

echo
echo "[5] 鸿蒙 hain_tv_ohos/ohos/mpv_arkts/libs"
if [ -d "$ROOT/hain_tv_ohos/ohos/mpv_arkts/libs/arm64-v8a" ]; then
  ls -1 "$ROOT/hain_tv_ohos/ohos/mpv_arkts/libs/arm64-v8a" | sed 's/^/     - /'
  ok "鸿蒙内核目录存在"
else
  warn "鸿蒙内核目录不存在（本地构建鸿蒙时需从 HeinPlayMPV 资产解包）"
fi

echo
echo "[6] 契约与内核仓指针"
[ -e "$ROOT/docs/mpv-dependency-contract.md" ] && ok "docs/mpv-dependency-contract.md 存在" || bad "缺少 docs/mpv-dependency-contract.md"
if [ -e "/workspace/code/HeinPlayMPV/docs/heinplay-integration.md" ]; then
  ok "上游权威文件 HeinPlayMPV/docs/heinplay-integration.md 存在"
  echo "     当前 pin："
  grep -n "MPV_DEPS_TAG" "$ROOT/.github/workflows/build-release.yml" | sed 's/^/     /' || true
else
  warn "未找到本地 HeinPlayMPV 仓（/workspace/code/HeinPlayMPV），无法核对上游契约"
fi

echo
if [ "$RC" -eq 0 ]; then
  echo "结果：全部符合契约（docs/mpv-dependency-contract.md）"
else
  echo "结果：存在不符合项，请按上面的 ❌ 处理"
fi
exit "$RC"
