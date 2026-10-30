#!/usr/bin/env bash
# ==============================================================================
# HeinPlay Linux AppImage 现场诊断脚本（针对 Bazzite / 掌机「打开无反应」）
#
# 用法：
#   ./diagnose_linux_appimage.sh                          # 默认找当前目录下的 AppImage
#   ./diagnose_linux_appimage.sh heinplay-1.4.1-linux-x86_64.AppImage
#
# 只读操作：不安装、不修改系统、不写用户目录（仅 /tmp 解包）。可放心运行。
# ==============================================================================
set -uo pipefail

APP_ARG="${1:-}"
if [ -z "$APP_ARG" ]; then
  APP_ARG="$(ls -1 ./heinplay-*-linux-x86_64.AppImage 2>/dev/null | head -1)"
fi
if [ -z "$APP_ARG" ] || [ ! -f "$APP_ARG" ]; then
  echo "✗ 没找到 AppImage。请这样运行："
  echo "    ./diagnose_linux_appimage.sh /完整路径/heinplay-1.4.1-linux-x86_64.AppImage"
  exit 1
fi
APP="$(readlink -f "$APP_ARG")"
export PATH="$PATH"

hr() { printf '\n\033[1;36m══ %s ══\033[0m\n' "$1"; }

hr "0. 目标文件"
ls -l "$APP"
file "$APP" | cut -c1-160

hr "1. 运行环境"
if [ -r /etc/os-release ]; then . /etc/os-release; echo "系统   : $PRETTY_NAME"; fi
echo "内核   : $(uname -sr)"
echo "架构   : $(uname -m)   ← AppImage 是 x86_64，架构不符会直接无法执行"
echo "会话   : XDG_SESSION_TYPE=${XDG_SESSION_TYPE:-?}  WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-无}  DISPLAY=${DISPLAY:-无}"
echo "桌面   : ${XDG_CURRENT_DESKTOP:-?}   运行中=${XDG_SESSION_DESKTOP:-?}"
echo "显卡   :"
(lspci 2>/dev/null | grep -iE 'vga|3d controller|display' | sed 's/^/         /') || echo "         (lspci 不可用)"
if [ -e /sys/class/drm/card0/device/vendor ]; then
  echo "DRM卡0 : $(cat /sys/class/drm/card0/device/vendor 2>/dev/null) / $(cat /sys/class/drm/card0/device/driver/module 2>/dev/null)"
fi

hr "2. FUSE（AppImage 挂载必需）"
ls -l /dev/fuse 2>&1 | sed 's/^/  /'
if command -v rpm >/dev/null; then rpm -q fuse3 fuse 2>&1 | sed 's/^/  /'; fi
echo "libfuse 实体文件："
(ldconfig -p 2>/dev/null | grep -E 'libfuse\.so' | sed 's/^/  /') || echo "  (无 libfuse —— AppImage 将无法挂载)"

hr "3. 直接运行（默认渲染器，20 秒）"
echo "命令: $APP"
echo "---- stderr/stdout 开始 ----"
timeout 20 "$APP" 2>&1 | head -60
rc=$?
echo "---- 结束（管道退出码 $rc；124=超时仍在运行）----"

hr "4. 关闭 Impeller 再跑（Skia 回退，20 秒）"
echo "命令: $APP --enable-impeller=false"
echo "---- stderr/stdout 开始 ----"
timeout 20 "$APP" --enable-impeller=false 2>&1 | head -60
rc=$?
echo "---- 结束（管道退出码 $rc）----"

hr "5. 解包后运行（绕过 FUSE 与 type-2 runtime）"
TMP="$(mktemp -d /tmp/heinplay-diag.XXXXXX)"
if (cd "$TMP" && "$APP" --appimage-extract >/dev/null 2>&1); then
  echo "解包成功: $TMP/squashfs-root"
  echo "---- 依赖缺失检查（libapp.so / hain_tv）----"
  LD_LIBRARY_PATH="$TMP/squashfs-root/lib" ldd "$TMP/squashfs-root/hain_tv" 2>/dev/null \
    | grep -i "not found" | sed 's/^/  ✗ /' || true
  LD_LIBRARY_PATH="$TMP/squashfs-root/lib" ldd "$TMP/squashfs-root/lib/libapp.so" 2>/dev/null \
    | grep -i "not found" | sed 's/^/  ✗ /' || true
  echo "  （以上若无输出 = 依赖齐全）"
  echo "---- 直接运行解包后的程序（20 秒）----"
  ( cd "$TMP/squashfs-root" && timeout 20 ./hain_tv 2>&1 | head -60 )
  echo "---- 结束 ----"
else
  echo "✗ 解包失败 —— type-2 runtime / FUSE 有问题"
fi

hr "6. 图形栈能力"
echo "GLX/EGL 库："
(ldconfig -p 2>/dev/null | grep -E 'libGL\.so\.1|libEGL\.so\.1|libGLX\.so\.0|libvulkan\.so\.1|libgbm\.so\.1' | sed 's/^/  /')
for t in glxinfo eglinfo vulkaninfo; do
  if command -v "$t" >/dev/null; then echo "--- $t ---"; "$t" 2>&1 | head -15; fi
done

hr "7. 用户目录写入"
for d in "$HOME/.config" "$HOME/.local/share" "$HOME/.cache"; do
  if [ -d "$d" ]; then
    t="$d/.heinplay-write-test.$$"
    if touch "$t" 2>/dev/null; then echo "  ✓ $d 可写"; rm -f "$t"; else echo "  ✗ $d 不可写"; fi
  else
    echo "  · $d 不存在（Flutter 会自行创建）"
  fi
done
[ -d "$HOME/.config/hain_tv" ] && echo "  · 已存在应用配置目录 $HOME/.config/hain_tv" && \
  ls -la "$HOME/.config/hain_tv" 2>/dev/null | head -10

hr "8. 已有安装痕迹"
for p in "$HOME/.local/share/gearlever" "$HOME/Applications" "$HOME/.local/share/applications"; do
  [ -d "$p" ] && { echo "--- $p ---"; ls -l "$p" 2>/dev/null | grep -iE 'hein|hain' | sed 's/^/  /'; }
done

hr "诊断结束"
echo "请把上面全部输出发回来。若第 3 段无任何输出且进程超时仍在跑，"
echo "说明程序启动了但窗口没画出来 —— 多半是渲染后端（Impeller/Vulkan）与显卡驱动不匹配。"
