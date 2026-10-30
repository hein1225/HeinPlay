#!/bin/bash
# 桌面 mpv 壳 · Linux bundle 系统基础库剔除脚本。
#
# 【为什么必须剔除一部分】
#   Flutter Linux 构建会把所有被链接到的 .so 一并拷进 bundle/lib/。
#   其中 glib/gtk/glvnd 这类库与宿主 GPU 驱动、桌面会话强绑定：
#   一旦被应用自带，就会覆盖系统版本 → GPU 驱动与新库不匹配 →
#   用户侧表现为「双击 AppImage 毫无反应 / 启动即崩」。
#   历史事故（2026-10-2x）：用户自行安装 AppImage 启动无反应，
#   而开发机 ssh 安装却能启动，根因正是 glib/glvnd/wayland 被误打包。
#
# 【为什么不能剔太多】
#   2026-10-21 实测教训：按「图形栈」泛泛剔除，把 libXpresent.so.1 也删了，
#   而它是 libmpv.so.2 的**直接依赖**，且 Debian 13 系统默认**不安装**它
#   （需 xorg-server 相关包才有）→ 壳 dlopen 直接失败：
#     "libXpresent.so.1: 无法打开共享目标文件"
#   整个 mpv 后端不可用。
#
#   结论：黑名单必须**收窄到确定由宿主提供**的核心库，其余一律保留。
#   宁可包体大一点，也不能让目标机缺库起不来。
#
# 【判据】
#   只剔除下面 BLACKLIST 里显式列出的库（glib/gtk/gdk/pango/cairo/glvnd/
#   X11 基础/xcb 基础）。凡是 mpv / FFmpeg / Flutter 的直接或传递依赖
#   （libXpresent、libva*、libsndio、libpulsecommon、libplacebo、
#   libav*、libass、libfontconfig 等）**一律保留**。
#
# 用法：./prune_system_libs.sh <bundle 目录>

set -u

BUNDLE="${1:-}"
if [ -z "$BUNDLE" ] || [ ! -d "$BUNDLE/lib" ]; then
  echo "用法: $0 <bundle 目录>（需包含 lib/ 子目录）" >&2
  exit 2
fi

LIBDIR="$BUNDLE/lib"

# ⚠️ 收窄后的黑名单：只含「宿主必然自带、且与图形栈强绑定」的核心库。
#    不要把 libXpresent / libXss / libXv / libva* / libsndio / libpulsecommon
#    / libfontconfig / libharfbuzz / libfribidi / libdrm 放进来 ——
#    它们或是 mpv 直接依赖，或目标机未必预装。
BLACKLIST=(
  # GLib / GTK / GDK / Pango / Cairo 核心（宿主桌面必备，且与 GPU/主题强绑定）
  "libglib-2.0" "libgio-2.0" "libgobject-2.0" "libgmodule-2.0"
  "libgtk-3" "libgdk-3"
  "libpango-1.0" "libpangocairo-1.0" "libpangoft2-1.0"
  "libcairo.so" "libcairo-gobject"
  "libatk-1.0" "libatk-bridge-2.0" "libatspi"
  # glvnd：与 GPU 驱动强绑定，**绝不能**自带（自带必崩）
  "libEGL.so" "libGLdispatch" "libGLX.so" "libOpenGL.so" "libGLESv2"
  # Wayland 协议库（与合成器/驱动强绑定）
  "libwayland-client" "libwayland-cursor" "libwayland-egl"
  # X11 / xcb 最基础层（宿主桌面必备）
  "libX11.so" "libX11-xcb" "libXau.so" "libXdmcp" "libxcb.so"
)

# 明确**必须保留**的例外（即使命中前缀也不删）。
KEEP=(
  "libbz2.so.1.0"    # 目标系统未必有此 soname，必须自带（历史踩坑）
  "libXpresent.so.1" # mpv 直接依赖，Debian 13 默认不装
)

removed=0
kept_exception=0

is_kept_exception() {
  local name="$1"
  for k in "${KEEP[@]}"; do
    [ "$name" = "$k" ] && return 0
  done
  return 1
}

echo "剔除系统基础库：$LIBDIR"
for prefix in "${BLACKLIST[@]}"; do
  for f in "$LIBDIR/$prefix"*; do
    [ -e "$f" ] || continue
    [ -d "$f" ] && continue
    name="$(basename "$f")"
    if is_kept_exception "$name"; then
      kept_exception=$((kept_exception + 1))
      continue
    fi
    rm -f "$f"
    echo "  剔除 $name"
    removed=$((removed + 1))
  done
done

total=$(ls -1 "$LIBDIR" 2>/dev/null | wc -l)
echo "完成：剔除 $removed 个条目（保留例外 $kept_exception 个），lib/ 现有 $total 个文件"
