#!/usr/bin/env bash
# 海因影视 HeinPlay —— Linux 电脑版安装脚本（在目标 Linux 机器上运行）
#
# 用法：
#   ./install_heinplay_linux.sh <AppImage路径> [版本号]
#   ./install_heinplay_linux.sh --uninstall
#
# 电脑版命名铁律：文件名 / 目录名一律英文，绝不用中文。
# 固定布局（与本脚本同为事实来源，改动须同步）：
#   ~/Applications/heinplay.appimage               可执行文件
#   ~/Applications/.icons/heinplay                 图标
#   ~/.local/share/applications/heinplay.desktop   桌面条目（显示名仍是「海因影视」）
#
# 设计要点：
# - 无需 root，全部装在用户目录；卸载 = 删这三个文件。
# - 先写临时文件再 mv 覆盖，正在运行的实例不受影响（旧 inode 继续可用）。
# - 会自动清理 1.3.3 及更早版本残留的中文名文件（海因影视.appimage / 图标 / desktop）。
set -euo pipefail

BIN_NAME="heinplay.appimage"
DESKTOP_NAME="heinplay.desktop"
ICON_NAME="heinplay"
APP_DISPLAY_NAME="海因影视"

APPLICATIONS_DIR="$HOME/Applications"
ICONS_DIR="$APPLICATIONS_DIR/.icons"
DESKTOP_DIR="$HOME/.local/share/applications"

DEST_BIN="$APPLICATIONS_DIR/$BIN_NAME"
DEST_ICON="$ICONS_DIR/$ICON_NAME"
DEST_DESKTOP="$DESKTOP_DIR/$DESKTOP_NAME"

# 历史中文名（1.3.3 及更早）——发现即清理，避免用户目录出现中文路径
LEGACY_NAMES=("海因影视")

log() { printf '%s\n' "$*"; }
die() { printf '错误：%s\n' "$*" >&2; exit 1; }

uninstall() {
  log "==> 卸载海因影视（Linux 电脑版）"
  rm -f "$DEST_BIN" "$DEST_DESKTOP" "$DEST_ICON"
  for n in "${LEGACY_NAMES[@]}"; do
    rm -f "$APPLICATIONS_DIR/$n.appimage" "$ICONS_DIR/$n" \
          "$DESKTOP_DIR/$n.desktop" "$DESKTOP_DIR/$n.desktop.bak"
  done
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
  fi
  log "    已删除 $DEST_BIN / $DEST_ICON / $DEST_DESKTOP"
  log "==> 卸载完成"
  exit 0
}

[ "${1:-}" = "--uninstall" ] && uninstall

SRC="${1:-}"
[ -n "$SRC" ] || die "用法：$0 <AppImage路径> [版本号]"
[ -f "$SRC" ] || die "找不到 AppImage 文件：$SRC"

# 版本号：显式传入优先，否则从文件名 heinplay-<ver>-linux-x86_64.AppImage 里提取
VERSION="${2:-}"
if [ -z "$VERSION" ]; then
  VERSION="$(printf '%s' "$(basename "$SRC")" \
    | sed -nE 's/.*heinplay-([0-9][0-9.]*)-linux.*/\1/p')"
fi
[ -n "$VERSION" ] || VERSION="0.0.0"

log "==> 安装海因影视 $VERSION → $DEST_BIN"
log "    来源：$SRC"
log "    SHA256: $(sha256sum "$SRC" | cut -d' ' -f1)"

mkdir -p "$APPLICATIONS_DIR" "$ICONS_DIR" "$DESKTOP_DIR"

# --- 1. 可执行文件（先写临时文件再原子替换）---
TMP_BIN="$DEST_BIN.new"
install -m 755 "$SRC" "$TMP_BIN"
mv -f "$TMP_BIN" "$DEST_BIN"

# --- 2. 图标：从 AppImage 内抽取，失败则保留已有图标 ---
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
ICON_SRC=""
if (cd "$TMPD" && "$DEST_BIN" --appimage-extract \
      'usr/share/icons/hicolor/256x256/apps/mo_ico.png' >/dev/null 2>&1); then
  ICON_SRC="$TMPD/squashfs-root/usr/share/icons/hicolor/256x256/apps/mo_ico.png"
fi
if [ ! -f "$ICON_SRC" ] && (cd "$TMPD" && "$DEST_BIN" --appimage-extract .DirIcon >/dev/null 2>&1); then
  ICON_SRC="$(ls "$TMPD"/squashfs-root/.DirIcon 2>/dev/null || true)"
fi
if [ -f "$ICON_SRC" ]; then
  install -m 644 "$ICON_SRC" "$DEST_ICON"
  log "    图标已更新：$DEST_ICON"
else
  log "    提示：未能从 AppImage 抽取图标，保留 $DEST_ICON 原样"
fi

# --- 3. 桌面条目（文件名英文，显示名中文）---
cat > "$DEST_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_DISPLAY_NAME
Name[zh_CN]=$APP_DISPLAY_NAME
Name[en]=HeinPlay
GenericName=影视播放器
Comment=$APP_DISPLAY_NAME · 跨平台影视播放器
Icon=$DEST_ICON
TryExec=$DEST_BIN
Exec=env DESKTOPINTEGRATION=1 "$DEST_BIN" %U
Terminal=false
Categories=AudioVideo;Player;
StartupWMClass=hain_tv
X-AppImage-Arch=x86_64
X-AppImage-Version=$VERSION
X-AppImage-Name=HeinPlay
EOF
chmod 644 "$DEST_DESKTOP"

# --- 4. 清理历史中文名残留 ---
for n in "${LEGACY_NAMES[@]}"; do
  for f in "$APPLICATIONS_DIR/$n.appimage" "$ICONS_DIR/$n" \
           "$DESKTOP_DIR/$n.desktop" "$DESKTOP_DIR/$n.desktop.bak"; do
    if [ -e "$f" ]; then
      rm -f "$f" && log "    已清理旧中文名文件：$f"
    fi
  done
done

# --- 5. 校验 ---
if command -v desktop-file-validate >/dev/null 2>&1; then
  desktop-file-validate "$DEST_DESKTOP" && log "    desktop 条目校验通过 ✓"
else
  log "    提示：无 desktop-file-validate，跳过条目校验"
fi
if command -v update-desktop-database >/dev/null 2>&1; then
  update-desktop-database "$DESKTOP_DIR" 2>/dev/null || true
fi

log ""
log "==> 安装完成"
log "    程序：$DEST_BIN"
log "    图标：$DEST_ICON"
log "    入口：$DEST_DESKTOP"
log "    在应用菜单搜索「$APP_DISPLAY_NAME」即可启动；Steam 游戏模式请手动添加非 Steam 游戏。"
