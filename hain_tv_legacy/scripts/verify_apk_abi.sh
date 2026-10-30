#!/usr/bin/env bash
# =============================================================================
# TV Legacy APK 架构自检 —— 出包后必须通过，否则不得交付
# =============================================================================
#
# 【Legacy 的定位：两类设备，v8a 是第一目标】
#
# 本工程针对的不是「老旧 32 位设备」，而是两件事：
#   ① 低版本 Android（引擎侧踩过 libc 符号坑：3.35+ 引擎引入
#      getifaddrs@LIBC_N，Android 5.0 的 libc 没有该符号，一加载即崩，
#      故 SDK 钉死 flutter-3.32.8）
#   ② 不支持 Vulkan 的 Android（渲染侧走 gpu-context=android 的
#      OpenGL/EGL 路线；Vulkan 需 API 24+，legacy 不用）
#
# 这两类设备中，**arm64-v8a 占绝大多数**（大量低版本 / 无 Vulkan 的电视盒子
# 与一体机都是 64 位芯片跑低版本系统）。所以：
#     arm64-v8a   = 第一目标架构（主力）
#     armeabi-v7a = 兜底兼容（真·老 32 位设备）
#
# 切勿因为「legacy = 低版本 = 老设备 = 32 位」就只打 v7a，或反过来只打 v8a。
# 两个架构必须同时完整。
#
# 【为什么需要这道检查】
#
# 2026-10-11 事故：交付的 APK 启动即崩，报
#     Could not find 'libflutter.so'.
#     Looked for: [armeabi-v7a, armeabi], but only found: [arm64-v8a].
#
# 根因不是设备架构，而是**包畸形**：
#   构建时误加 `--target-platform android-arm64`，Flutter 只往 lib/arm64-v8a/
#   放引擎库（libflutter.so + libapp.so），但插件经 jniLibs 塞入的
#   lib/armeabi-v7a/（mpv 等）仍被打进包 → 形成「v7a 目录存在、却缺引擎库」。
#
# 关键机制：Android 安装器选择 ABI 时，只比对 lib/<abi>/ **目录名**与设备
# 的 ro.product.cpu.abilist，**不校验目录里的 so 是否齐全**。目录残缺不会
# 让安装器跳过该架构，只会让它选中一个跑不起来的架构。所以「按设备自动
# 选择」不是包的能力，而是靠**各架构目录完整**换来的。
#
# 本脚本即校验该完整性：两架构的 so 清单必须逐一对齐且非空。
#
# 用法：
#   bash scripts/verify_apk_abi.sh [apk路径]
#   不传路径则自动取 build/app/outputs/apk/tvlegacy/release/app-tvlegacy-release.apk
#
# 退出码：0 = 通过可交付；1 = 不通过，禁止交付。
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

APK="${1:-$PROJECT_DIR/build/app/outputs/apk/tvlegacy/release/app-tvlegacy-release.apk}"

# 两个架构都必须存在且完整。
# arm64-v8a 是主力（大量低版本 / 无 Vulkan 设备是 64 位芯片），
# armeabi-v7a 是兜底（真·老 32 位设备）。任何一个残缺都可能被安装器选中。
REQUIRED_ABIS=("arm64-v8a" "armeabi-v7a")

# 每个架构都必须齐备的关键库。缺任何一个，该架构就跑不起来。
REQUIRED_LIBS=(
  "libflutter.so"                # Flutter 引擎本体 —— 缺它必然启动崩溃
  "libapp.so"                    # Dart AOT 快照
  "libmpv.so"                    # 自编译 mpv
  "libheinplay_mpv_jni.so"       # JNI 桥
)

RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; BOLD=$'\033[1m'; NC=$'\033[0m'

fail() { echo "${RED}${BOLD}[不通过]${NC} $*" >&2; exit 1; }
ok()   { echo "${GREEN}[通过]${NC} $*"; }
warn() { echo "${YELLOW}[注意]${NC} $*"; }

echo "${BOLD}=== TV Legacy APK 架构自检 ===${NC}"
echo "APK: $APK"

[ -f "$APK" ] || fail "APK 不存在：$APK"
echo "大小: $(stat -c %s "$APK") 字节"
echo "md5 : $(md5sum "$APK" | cut -d' ' -f1)"
echo

# zip 工具探测（容器/CI 环境不一）
if command -v unzip >/dev/null 2>&1; then
  list_zip() { unzip -l "$1" 2>/dev/null; }
elif command -v python3 >/dev/null 2>&1; then
  list_zip() { python3 -c "import zipfile,sys;[print(f'{i.file_size:>12}  {i.filename}') for i in zipfile.ZipFile(sys.argv[1]).infolist()]" "$1"; }
else
  fail "缺少 unzip 或 python3，无法读取 APK"
fi

# 清单只取一次并缓存到变量。
# 【坑】不能写成 `list_zip "$APK" | grep -q ...`：本脚本开了 set -o pipefail，
# 而 grep -q 匹配到首个结果就退出，会让上游 unzip 收到 SIGPIPE(141)，pipefail
# 把整条管道判为失败 —— 于是「明明存在」的库会被误报成缺失（本次踩过）。
# 缓存成字符串后在同一份数据上反复匹配，既无管道竞态，也避免重复解压。
ZIP_LIST="$(list_zip "$APK")"
[ -n "$ZIP_LIST" ] || fail "无法读取 APK 内容清单：$APK"

echo "${BOLD}--- 1. 各架构 so 数量 ---${NC}"
declare -A ABI_COUNT=()
for abi in "${REQUIRED_ABIS[@]}"; do
  n=$(printf '%s\n' "$ZIP_LIST" | grep -c "lib/$abi/" || true)
  ABI_COUNT[$abi]=$n
  echo "  lib/$abi/ : $n 个"
  [ "$n" -gt 0 ] || fail "架构 $abi 的 so 目录完全缺失 —— 该架构设备将无法启动"
done
echo

echo "${BOLD}--- 2. 关键库齐备性 ---${NC}"
LIB_FAIL=0
for abi in "${REQUIRED_ABIS[@]}"; do
  echo "  [$abi]"
  for lib in "${REQUIRED_LIBS[@]}"; do
    # 在缓存的清单文本上匹配，不用管道（理由见上方 ZIP_LIST 处注释）
    hit=$(printf '%s\n' "$ZIP_LIST" | grep "lib/$abi/$lib" || true)
    if [ -n "$hit" ]; then
      # unzip -l 行格式：Length  Date  Time  Name
      #   11277384  1981-01-01 01:01   lib/arm64-v8a/libflutter.so
      # 首列即体积（时间列含空格，故不能按倒数列取）。行首可能有空格。
      size=$(printf '%s\n' "$hit" | head -1 | awk '{print $1}')
      echo "    ${GREEN}OK${NC}   $lib ($size 字节)"
    else
      echo "    ${RED}缺失${NC} $lib"
      LIB_FAIL=1
    fi
  done
done
[ "$LIB_FAIL" -eq 0 ] || fail "存在缺失的关键库 —— 这就是 2026-10-11 启动崩溃的直接原因，禁止交付"
echo

echo "${BOLD}--- 3. 两架构 so 清单逐一对齐 ---${NC}"
V7A=$(printf '%s\n' "$ZIP_LIST" | grep "lib/armeabi-v7a/" | awk '{print $NF}' | sed 's|lib/armeabi-v7a/||' | sort)
V8=$(printf '%s\n' "$ZIP_LIST"  | grep "lib/arm64-v8a/"   | awk '{print $NF}' | sed 's|lib/arm64-v8a/||'   | sort)

ONLY_V8=$(comm -13 <(echo "$V7A") <(echo "$V8") || true)
ONLY_V7A=$(comm -23 <(echo "$V7A") <(echo "$V8") || true)

if [ -n "$ONLY_V8" ]; then
  echo "  ${RED}仅 arm64-v8a 有（v7a 缺这些 → 会触发误选崩溃）：${NC}"
  echo "$ONLY_V8" | sed 's/^/    /'
  LIB_FAIL=1
fi
if [ -n "$ONLY_V7A" ]; then
  echo "  ${RED}仅 armeabi-v7a 有：${NC}"
  echo "$ONLY_V7A" | sed 's/^/    /'
  LIB_FAIL=1
fi
if [ -z "$ONLY_V8" ] && [ -z "$ONLY_V7A" ]; then
  ok "两架构 so 清单完全一致（各 ${ABI_COUNT[arm64-v8a]} 个）"
fi
echo

echo "${BOLD}--- 4. manifest 校验 ---${NC}"
AAPT2=$(ls /opt/team/tool-deps/android-sdk/build-tools/*/aapt2 2>/dev/null | tail -1 || true)
if [ -n "$AAPT2" ]; then
  XML=$("$AAPT2" dump xmltree --file AndroidManifest.xml "$APK" 2>/dev/null || true)
  if echo "$XML" | grep -q "extractNativeLibs(0x010104ea)=true"; then
    ok "extractNativeLibs=true（安装器按设备 abilist 自动抽取）"
  else
    warn "未检测到 extractNativeLibs=true，请人工确认 ABI 抽取策略"
  fi
  if echo "$XML" | grep -qi "nativeLibraryDir"; then
    warn "manifest 中出现 nativeLibraryDir 覆写，会干扰 ABI 选择，请人工确认"
  else
    ok "无 nativeLibraryDir 覆写"
  fi
else
  warn "未找到 aapt2，跳过 manifest 校验"
fi
echo

if [ "$LIB_FAIL" -ne 0 ]; then
  fail "自检未通过 —— 禁止交付"
fi

echo "${GREEN}${BOLD}=== 自检全部通过，可交付 ===${NC}"
echo
echo "${BOLD}提醒：${NC}出包命令必须是双架构，不得省略 --target-platform："
echo "  flutter build apk --release --target lib/main_tv.dart --target-platform android-arm,android-arm64"
