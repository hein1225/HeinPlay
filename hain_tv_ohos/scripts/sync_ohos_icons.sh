#!/usr/bin/env bash
#
# sync_ohos_icons.sh —— 把安卓手机版图标同步到鸿蒙工程
#
# 背景
# ----
# 鸿蒙工程初建时用的是 DevEco 默认模板图标（四个圆角方块的灰色图），
# 启动器实际读取的是 AppScope/resources/base/media/ 下的 layered_image
# （background + foreground），因此只改 entry 侧不会生效。
# 本脚本以「安卓手机版」图标为唯一来源，同时刷新 AppScope 与 entry 两侧，
# 保证鸿蒙版与安卓手机版图标完全一致。
#
# 图标来源
# --------
#   hain_tv/android/app/src/mobile/res/drawable-xxxhdpi/ic_launcher_foreground.png
#   该图由 flutter_launcher_icons（flutter_launcher_icons-mobile.yaml）从
#   ../plan/mo_ico.png 生成，是手机版的权威图标资产（432x432，带圆角透明）。
#   注：plan/mo_ico.png 源图已不在仓库中，故直接以该生成物为准。
#
# 产出（1024x1024，鸿蒙分层图标规范）
# ---------------------------------
#   background.png  由图标自身模糊放大得到的渐变底色，满幅无透明
#   foreground.png  图标主体，保留圆角透明区
#   startIcon.png   启动页图标（与前景层一致）
#
# 用法：bash scripts/sync_ohos_icons.sh
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"          # hain_tv_ohos/
REPO_DIR="$(cd "$PROJ_DIR/.." && pwd)"            # HeinPlay/

SRC="$REPO_DIR/hain_tv/android/app/src/mobile/res/drawable-xxxhdpi/ic_launcher_foreground.png"
[ -f "$SRC" ] || { echo "找不到安卓手机版图标: $SRC" >&2; exit 1; }

command -v magick >/dev/null || { echo "需要 ImageMagick (magick)" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 图标源: $SRC"
magick identify -format "    %wx%h type=%[type]\n" "$SRC"

# 背景层：先把圆角透明区用自身模糊色场补满，再做大尺度模糊得到纯净渐变
magick "$SRC" -background '#0a3ba0' -alpha remove -alpha off \
  -blur 0x45 -resize 1024x1024! "$TMP/background.png"

# 前景层：图标主体原样放大，保留透明圆角
magick "$SRC" -resize 1024x1024! "$TMP/foreground.png"

# 启动页图标与前景层一致
cp "$TMP/foreground.png" "$TMP/startIcon.png"

# 目标位置：AppScope（启动器实际读取）与 entry 两侧都要覆盖
TARGETS=(
  "$PROJ_DIR/ohos/AppScope/resources/base/media"
  "$PROJ_DIR/ohos/entry/src/main/resources/base/media"
)
for d in "${TARGETS[@]}"; do
  mkdir -p "$d"
  cp -f "$TMP/background.png" "$d/background.png"
  cp -f "$TMP/foreground.png" "$d/foreground.png"
  echo "==> 已更新: $d"
done
cp -f "$TMP/startIcon.png" "$PROJ_DIR/ohos/entry/src/main/resources/base/media/startIcon.png"

# 校验：两侧图标必须逐字节一致，且前景层保留透明
for d in "${TARGETS[@]}"; do
  if ! cmp -s "$d/foreground.png" "$TMP/foreground.png"; then
    echo "校验失败: $d/foreground.png 未同步" >&2; exit 1
  fi
done
ALPHA=$(magick "$TMP/foreground.png" -alpha extract -format '%[fx:minima]' info:)
echo "==> 前景层 alpha 最小值 = $ALPHA（应为 0，保留圆角透明）"
echo "==> 背景层四角 = $(magick "$TMP/background.png" -format '%[pixel:p{0,0}]' info:)"
echo
echo "完成。重新构建后启动器图标将与安卓手机版一致。"