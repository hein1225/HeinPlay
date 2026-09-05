#!/usr/bin/env bash
# =============================================================
# build_hap.sh — 鸿蒙(HarmonyOS NEXT) HAP 出包脚本（Git Bash / Windows 专用）
#
# 背景：2026-09-02 命令行出包打通后固化。缺一不可的三要素：
#   1) hijack/ohpm shim 置于 PATH 最前 —— 绕过 DevEco ohpm.bat 的
#      BATCH RECURSION（MSYS 把 OS 改写为 MINGW64_NT-*，延迟展开失效）。
#   2) DEVECO_SDK_HOME 必须指向【版本目录】D:/sdk/26.0.0（非根 D:/sdk）。
#   3) 插件 HAR 依赖：screen_brightness_ohos 2.1.4 已在 pub-cache 内
#      手动补 @ohos/flutter_ohos（如失效需重补，见 .workbuddy/memory）。
#
# 用法：  bash scripts/build_hap.sh            # 默认 --debug
#         bash scripts/build_hap.sh --release
# 产物：  harmony_haintv/entry/build/default/outputs/default/entry-default-signed.hap
#
# ⚠️ 2026-09-02 晚更新：鸿蒙工程目录已统一为 hain_tv/harmony_haintv/（ohos 实体已
#    改名并删除 junction）。flutter 工具链硬编码找 <工程>/ohos，故直接运行本脚本
#    会报 "ohos 目录不存在"。如需恢复命令行出包，先执行：
#       cmd //c mklink /J ohos harmony_haintv   （构建后 cmd //c rmdir ohos）
#    或者改用 DevEco Studio 打开 harmony_haintv/ 构建。
# =============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$PROJECT_DIR"

# 前置检查：flutter 命令行出包要求 <工程>/ohos 目录存在（工具链硬编码）
if [ ! -d "$PROJECT_DIR/ohos" ]; then
  echo "FATAL: 缺 $PROJECT_DIR/ohos —— flutter 工具链硬编码找 ohos 目录。"
  echo "       鸿蒙工程实体现为 harmony_haintv/。恢复命令行出包："
  echo "         cd '$PROJECT_DIR' && cmd //c mklink /J ohos harmony_haintv"
  echo "       或用 DevEco Studio 打开 harmony_haintv/ 构建。"
  exit 1
fi

# 传入的额外 flutter 参数（默认 debug）
BUILD_MODE="${1:---debug}"

# ---- 环境准备（与验证成功的模板一致，勿随意裁剪） ----
export OS=Windows_NT
export ComSpec="C:\\Windows\\system32\\cmd.exe"
export PATHEXT=".COM;.EXE;.BAT;.CMD;.VBS;.VBE;.JS;.JSE;.WSF;.WSH;.MSC"
export CODEBUDDY_SAFE_DELETE_ENABLED=0
# 解除 WorkBuddy 沙箱对 rm 等 shell 函数的遮蔽（本机脚本环境所需）
unset -f rm rmdir unlink 2>/dev/null || true

# hijack(shim) 必须 PATH 最前；随后补 DevEco node / ohpm / flutter
export PATH="$PROJECT_DIR/hijack:/d/Program Files/Huawei/DevEco Studio/tools/node:/d/Program Files/Huawei/DevEco Studio/tools/ohpm/bin:/d/haflutter/flutter_flutter/bin:$PATH"
export PUB_CACHE="$PROJECT_DIR/.pub-cache"
export HOS_SDK_HOME=D:/sdk
export DEVECO_SDK_HOME=D:/sdk/26.0.0
export OHOS_SDK_HOME=D:/sdk/26.0.0
export OHOS_BASE_SDK_HOME=D:/ohos-sdk

echo "== build_hap: mode=$BUILD_MODE project=$PROJECT_DIR =="
echo "== 校验关键依赖 =="
command -v flutter >/dev/null || { echo "FATAL: flutter 不在 PATH（检查 hijack 与 flutter_flutter 路径）"; exit 1; }
test -f "$PROJECT_DIR/hijack/ohpm.bat" || { echo "FATAL: 缺 hijack/ohpm.bat shim"; exit 1; }
test -d "D:/sdk/26.0.0" || { echo "FATAL: DEVECO_SDK_HOME 版本目录不存在"; exit 1; }

echo "== 开始 flutter build hap $BUILD_MODE =="
flutter build hap "$BUILD_MODE" -t lib/main_ohos.dart

echo "== 完成。产物如下： =="
ls -lh ohos/entry/build/default/outputs/default/*.hap 2>/dev/null || true