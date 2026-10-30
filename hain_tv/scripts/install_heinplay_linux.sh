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
# - 若检测到 Gear Lever（~/.local/share/gearlever/）装过本应用，会**同名覆盖**
#   它的 heinplay.appimage 并清掉带版本后缀的旧副本 —— 保证所有版本
#   在集成器里都叫 heinplay.appimage，且升级就是覆盖，不会堆出 _1_4_0 / _0 副本。
# - 版本号从交付文件名提取（heinplay-<ver>-linux…），故 AppImage 交付名须带版本。
set -euo pipefail

BIN_NAME="heinplay.appimage"
DESKTOP_NAME="heinplay.desktop"
ICON_NAME="heinplay"
# 🔴 2026-10-20：**软件菜单名**用英文 heinplay（用户要求：Linux 软件名不能是中文）；
#   **窗口标题栏**用中文「海因影视」（由 main_linux.dart 的 setTitle 设置，
#   GTK runner 的初始标题也已是中文）。两者刻意不同，不要混用。
APP_DISPLAY_NAME="heinplay"

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

# --- 3. 桌面条目（文件名与显示名均为英文）---
cat > "$DEST_DESKTOP" <<EOF
[Desktop Entry]
Type=Application
Name=$APP_DISPLAY_NAME
Name[en]=HeinPlay
GenericName=Media Player
Comment=HeinPlay media player
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

# --- 5. 同步覆盖 Gear Lever（桌面集成器）已安装的同名文件 ---
# 背景（2026-10-23 实测厘清）：
#   Gear Lever 安装后的文件名 = AppImage 内 desktop 条目的 Name= 小写 + ".appimage"
#   （上游 src/providers/AppImageProvider.py, install_file()），与交付文件名无关
#   → 恒为 heinplay.appimage；只有目标目录已有同名文件时才加后缀
#     （heinplay.appimage_1_4_0.appimage / _0.appimage），
#     那是"不覆盖已有安装"的既定策略，AppImage 内部无法消除。
# 本段做同名覆盖 + 清掉带后缀的旧副本与旧桌面条目，
# 保证「所有版本安装后都叫 heinplay.appimage」且升级即覆盖。
GEARLEVER_DIR="$HOME/.local/share/gearlever"
if [ -d "$GEARLEVER_DIR" ]; then
  GL_BIN="$GEARLEVER_DIR/$BIN_NAME"
  if [ -f "$GL_BIN" ]; then
    install -m 755 "$SRC" "$GL_BIN.new"
    mv -f "$GL_BIN.new" "$GL_BIN"
    log "    已覆盖 Gear Lever 安装：$GL_BIN"
  fi
  shopt -s nullglob
  # 清掉带版本后缀的旧副本（如 heinplay.appimage_1_4_0.appimage）
  for f in "$GEARLEVER_DIR"/"$BIN_NAME"_*.appimage; do
    rm -f "$f" && log "    已清理旧副本：$f"
  done
  shopt -u nullglob
  # 清掉对应的旧桌面条目（带后缀的，如 heinplay_1_4_0.desktop）
  for f in "$DESKTOP_DIR"/"$BIN_NAME"_[0-9]*.desktop; do
    rm -f "$f" && log "    已清理旧桌面条目：$f"
  done
  # 刷新主桌面条目里的版本号
  if [ -f "$DESKTOP_DIR/$DESKTOP_NAME" ]; then
    sed -i "s/^X-AppImage-Version=.*/X-AppImage-Version=$VERSION/" "$DESKTOP_DIR/$DESKTOP_NAME"
    log "    已刷新桌面条目版本号：$DESKTOP_DIR/$DESKTOP_NAME"
  fi
fi

# --- 6. 清理桌面集成器（Gear Lever / AppImageLauncher）留下的「带后缀」残留 ---
#
# 🔴 2026-10-24：这是一条**独立于程序本身**的「点了没反应」来源。
#   桌面集成器安装时若目标目录已有同名文件，会生成带后缀的副本与条目：
#     ~/.local/share/applications/heinplay.appimage_0.desktop
#     ~/.local/share/applications/heinplay.appimage_1_4_0.desktop
#     ~/Applications/.icons/heinplay.appimage_0/（图标目录）
#   这些条目的 Exec 指向**并不存在**的 heinplay.appimage_0.appimage ——
#   用户在应用菜单/桌面搜索里点到它们时，依然是「双击完全没反应」，
#   极易被误判成程序坏了。安装时必须清掉，只保留主条目 heinplay.desktop。
shopt -s nullglob
for f in "$DESKTOP_DIR/$BIN_NAME"_*.desktop; do
  rm -f "$f" && log "    已清理集成器残留条目：$f"
done
for d in "$ICONS_DIR/$BIN_NAME"_*/; do
  rm -rf "$d" && log "    已清理集成器残留图标：$d"
done
for f in "$APPLICATIONS_DIR/$BIN_NAME"_*.appimage; do
  rm -f "$f" && log "    已清理集成器残留副本：$f"
done
shopt -u nullglob

# --- 7. 校验 ---
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
