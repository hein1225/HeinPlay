#!/usr/bin/env bash
# =============================================================================
# patch_oh_modules.sh — 对 oh_modules 中第三方/引擎源码做本地补丁
#
# 【为什么需要这个脚本】
# oh_modules/ 由 `ohpm install` 重新生成，**任何手工修改都会丢失**。
# 历史上已因此丢失过一次补丁（PlatformChannel 的屏幕方向映射）。
# 所有对 oh_modules 内文件的修改都必须落在此脚本中，并在构建前执行。
#
# 【幂等性】每项补丁先检测是否已应用，重复执行不会重复修改。
#
# 用法：bash scripts/patch_oh_modules.sh
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."

PATCHED=0

# -----------------------------------------------------------------------------
# 补丁 1：Flutter 引擎 Log 工具默认级别 WARN → INFO
#
# 【问题】Log.ets 默认 `_logLevel = HiLog.LogLevel.WARN`，而 isLoggable 判定
#   `level >= _logLevel`，于是 Log.i（INFO=4）在 WARN=5 下被判否，**日志全被丢弃**。
#   后果：video_player_ohos 插件 VideoPlayer.ets 里所有 Log.i 诊断
#   （起播定位、缓冲区间、起播耗时、SEEK_DONE）在 hilog 中完全不可见。
#
# 【附加事实】Log.i 写入 hilog 时 tag 固定为 Log.ets 内的常量 "Flutter"
#   （而非调用方传入的 tag）。抓日志须用 `hilog -T Flutter`，
#   业务 tag 会出现在正文中（格式：`Flutter: VideoPlayer --> <消息>`）。
# -----------------------------------------------------------------------------
LOG_ETS=$(find ohos/oh_modules -path '*flutter_ohos/src/main/ets/util/Log.ets' 2>/dev/null | head -1)

if [ -n "$LOG_ETS" ]; then
  if grep -q 'private static _logLevel = HiLog.LogLevel.WARN;' "$LOG_ETS"; then
    sed -i 's|private static _logLevel = HiLog.LogLevel.WARN;|private static _logLevel = HiLog.LogLevel.INFO;|' "$LOG_ETS"
    echo "✅ 补丁1：Log.ets 级别 WARN → INFO  ($LOG_ETS)"
    PATCHED=$((PATCHED + 1))
  elif grep -q 'private static _logLevel = HiLog.LogLevel.INFO;' "$LOG_ETS"; then
    echo "⏭  补丁1：已应用，跳过"
  else
    echo "⚠️  补丁1：未找到预期模式，请人工检查 $LOG_ETS" >&2
    exit 1
  fi
else
  echo "⚠️  补丁1：未找到 Log.ets（oh_modules 是否已安装？）" >&2
fi

# -----------------------------------------------------------------------------
# 补丁 2：屏幕方向映射（PlatformChannel）
#
# 【问题】Flutter 引擎默认的屏幕方向映射与鸿蒙预期不符，需把
#   setPreferredOrientations 的平台值映射到 AUTO_ROTATION_* 的受限档位。
#   历史记录：该补丁曾因 ohpm install 被重置而丢失（备份 md5 213aadec…）。
# -----------------------------------------------------------------------------
PC_ETS=$(find ohos/oh_modules -path '*flutter_ohos/src/main/ets/embedding/ohos/PlatformChannel.ets' 2>/dev/null | head -1)

if [ -n "$PC_ETS" ]; then
  if grep -q 'AUTO_ROTATION_PORTRAIT_RESTRICTED' "$PC_ETS"; then
    echo "⏭  补丁2：已应用，跳过"
  else
    echo "⚠️  补丁2：PlatformChannel.ets 尚未包含方向限制映射，需人工应用（见 /opt/team/tool-deps/cache/ohos-patch/PlatformChannel.ets.bak-orig 对照）"
  fi
else
  echo "⚠️  补丁2：未找到 PlatformChannel.ets" >&2
fi

echo
if [ "$PATCHED" -eq 0 ]; then
  echo "全部补丁已是最新状态。"
else
  echo "本次应用了 $PATCHED 项补丁。"
fi
