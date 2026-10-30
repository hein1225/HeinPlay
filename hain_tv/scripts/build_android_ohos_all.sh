#!/usr/bin/env bash
# ==============================================================================
# HeinPlay · Android(mobile/tv) + Android Legacy(tvLegacy) + 鸿蒙(hap/app) 串行重建
#
# 为什么需要这个脚本：
#   1) 交付目录里的产物必须与当前源码**严格一致**。Dart AOT 快照里内嵌
#      source line info（堆栈定位用），所以**哪怕只改注释**，重编译出的
#      app.so/libapp.so 也会出现字节差异（实测 194B / 9.2MB）。这不影响
#      任何功能，但会让「源码 ↔ 交付物」对不上账，埋下版本漂移的隐患。
#   2) 三个 flavor 分布在**两个** Android 工程里（tv/mobile 在 hain_tv，
#      tvlegacy 在独立的 hain_tv_legacy），加上独立的鸿蒙工程 hain_tv_ohos，
#      手工逐个敲容易漏 --target 或串错 flavor。
#
# 铁律（改动后必读）：
#   · --flavor 只决定 Android 配置，**必须显式 --target**（否则会构建到
#     默认 main.dart，产物是错的入口）。
#   · mobile → --flavor mobile --target lib/main_mobile.dart
#   · tv     → --flavor tv     --target lib/main_tv.dart
#   · tvLegacy→ --flavor tvlegacy --target lib/main_tv.dart（独立工程）
#   · 鸿蒙   → flutter build hap|app --release -t lib/main_ohos.dart
#   · 全平台必须**逐一串行**构建，不要并发（Gradle/ohpm 缓存会互相踩）。
#
# 用法：
#   ./scripts/build_android_ohos_all.sh            # 全部五个平台（串行）
#   ./scripts/build_android_ohos_all.sh main       # 只构建主工程 mobile + tv
#   ./scripts/build_android_ohos_all.sh legacy     # 只构建 tvLegacy
#   ./scripts/build_android_ohos_all.sh ohos       # 只构建鸿蒙 hap + app
#
#   ⚠️ 用户铁律：**一个一个平台来**，构建 → 用户验证通过 → 再下一个平台。
#      所以默认不要一次跑全，用 STAGES 指定当前阶段。
#
# 产物：  dist/heinplay-1.4.1-{mobile,tv,tvLegacy}.apk
#         dist/heinplay-1.4.1-ohos-unsigned.hap + heinplay-1.4.1-ohos-release.app
# ==============================================================================
set -euo pipefail

STAGES=${1:-all}

REPO=/workspace/code/HeinPlay
DIST=$REPO/dist
STAMP=$(date +%Y%m%d-%H%M%S)
LOG=$REPO/plan/worklogs/${STAMP}-android-ohos-build.log

mkdir -p "$DIST"
: > "$LOG"

log() { echo "[$(date +%H:%M:%S)] $*" | tee -a "$LOG"; }
die() { echo "[FATAL] $*" | tee -a "$LOG" >&2; exit 1; }

step() {   # step <名称> <工作目录> <环境脚本> <构建命令...>
  local name=$1 dir=$2 envscript=$3; shift 3
  log "▶ $name ..."
  local t0=$SECONDS
  ( cd "$dir" && source "$envscript" && "$@" ) 2>&1 | tee -a "$LOG"
  local rc=${PIPESTATUS[0]}
  [ "$rc" -eq 0 ] || die "$name 构建失败 (exit=$rc)，已中止后续步骤"
  log "✔ $name 完成（$((SECONDS-t0))s）"
}

# ---- 1. Android Mobile（主工程）----
if [ "$STAGES" = all ] || [ "$STAGES" = main ]; then
step "Android Mobile" "$REPO/hain_tv" "$REPO/hain_tv/scripts/env_team.sh" \
  flutter build apk --release --flavor mobile --target lib/main_mobile.dart

# ---- 2. Android TV（主工程）----
step "Android TV" "$REPO/hain_tv" "$REPO/hain_tv/scripts/env_team.sh" \
  flutter build apk --release --flavor tv --target lib/main_tv.dart
fi

# ---- 3. Android TV Legacy（独立工程，minSdk 21）----
if [ "$STAGES" = all ] || [ "$STAGES" = legacy ]; then
step "Android TV Legacy" "$REPO/hain_tv_legacy" "$REPO/hain_tv_legacy/scripts/env_team.sh" \
  flutter build apk --release --flavor tvlegacy --target lib/main_tv.dart
fi

# ---- 4. 鸿蒙 HAP ----
if [ "$STAGES" = all ] || [ "$STAGES" = ohos ]; then
step "鸿蒙 HAP" "$REPO/hain_tv_ohos" "$REPO/hain_tv_ohos/scripts/env_ohos_linux.sh" \
  flutter build hap --release -t lib/main_ohos.dart

# ---- 5. 鸿蒙 APP ----
step "鸿蒙 APP" "$REPO/hain_tv_ohos" "$REPO/hain_tv_ohos/scripts/env_ohos_linux.sh" \
  flutter build app --release -t lib/main_ohos.dart
fi

# ---- 6. 收集产物（只收本阶段构建出来的）----
log "收集产物到 dist/ ..."
collect() {   # collect <产物路径> <目标文件名>
  [ -f "$1" ] || die "产物缺失：$1"
  cp -f "$1" "$DIST/$2"
  log "  → $DIST/$2 ($(stat -c%s "$DIST/$2") bytes)"
}
if [ "$STAGES" = all ] || [ "$STAGES" = main ]; then
  collect "$REPO/hain_tv/build/app/outputs/flutter-apk/app-mobile-release.apk" \
          "heinplay-1.4.1-mobile.apk"
  collect "$REPO/hain_tv/build/app/outputs/flutter-apk/app-tv-release.apk" \
          "heinplay-1.4.1-tv.apk"
fi
if [ "$STAGES" = all ] || [ "$STAGES" = legacy ]; then
  collect "$REPO/hain_tv_legacy/build/app/outputs/flutter-apk/app-tvlegacy-release.apk" \
          "heinplay-1.4.1-tvLegacy.apk"
fi
if [ "$STAGES" = all ] || [ "$STAGES" = ohos ]; then
  # 交付命名规则（2026-10-29 用户定稿）：本地交付 = 发布版 app + unsigned.hap；
  # 已签名的单应用 HAP 不作为交付物（线上 CI 只构建 unsigned.hap）。
  collect "$REPO/hain_tv_ohos/ohos/entry/build/default/outputs/default/entry-default-unsigned.hap" \
          "heinplay-1.4.1-ohos-unsigned.hap"
  collect "$REPO/hain_tv_ohos/ohos/build/outputs/default/ohos-default-signed.app" \
          "heinplay-1.4.1-ohos-release.app"
fi

log "全部完成。日志：$LOG"
