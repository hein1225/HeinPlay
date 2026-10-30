#!/usr/bin/env bash
# HeinPlay Linux AppImage 打包脚本
# 命名规范（与 Android/ohos 一致）：heinplay-<版本>-linux-x86_64.AppImage
# 版本号取自 hain_tv/pubspec.yaml 的 version: 1.4.0+24 中的 1.4.0
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
STAGING="${STAGING:-/workspace/.build-staging}"
BUNDLE="$ROOT/build/linux/x64/release/bundle"

VER="$(grep -m1 '^version:' "$ROOT/pubspec.yaml" | sed 's/^version:[[:space:]]*//' | cut -d+ -f1)"
[ -n "$VER" ] || { echo "无法从 pubspec.yaml 取版本号"; exit 1; }
OUT_NAME="heinplay-${VER}-linux-x86_64.AppImage"
OUT="$ROOT/dist/$OUT_NAME"

echo "==> 版本 $VER，输出 $OUT_NAME"

[ -d "$BUNDLE" ] || { echo "缺少构建产物：$BUNDLE（先跑 flutter build linux --release）"; exit 1; }

# 1. 组装 AppDir
rm -rf "$STAGING/AppDir"
mkdir -p "$STAGING/AppDir"
cp -a "$BUNDLE/." "$STAGING/AppDir/"

OLD="$STAGING/old_ai/squashfs-root"
cp "$OLD/AppRun" "$STAGING/AppDir/AppRun"; chmod +x "$STAGING/AppDir/AppRun"
cp "$OLD/heinplay.desktop" "$OLD/heinplay.png" "$OLD/heinplay.sh" "$STAGING/AppDir/"
chmod +x "$STAGING/AppDir/heinplay.sh"
mkdir -p "$STAGING/AppDir/usr/share/applications" \
         "$STAGING/AppDir/usr/share/icons/hicolor/256x256/apps"
cp "$OLD/heinplay.desktop" "$STAGING/AppDir/usr/share/applications/"
cp "$OLD/heinplay.png" "$STAGING/AppDir/usr/share/icons/hicolor/256x256/apps/"

# 2. 剔除不该打包的系统库（glib/gtk/glvnd/wayland 等）
bash "$HERE/prune_system_libs.sh" "$STAGING/AppDir"

# 3. 依赖闭合校验（打包前，不通过直接中止）
#
# 🔴 2026-10-21 真机教训：libbz2.so.1.0 从未进 bundle，但构建机 Debian 自带它，
#    本机 ldd/自检全绿，直到 Bazzite(Fedora) 才暴露「壳 dlopen 失败」。
#    这里做一次静态 NEEDED 闭合检查：任何 bundle 内库的 NEEDED 若既不在 bundle
#    里、也不在「宿主必然提供」白名单里，即视为打包缺陷。
echo "==> 依赖闭合校验"
python3 - "$STAGING/AppDir/lib" <<'PY'
import os, re, subprocess, sys

libdir = sys.argv[1]
HOST_OK = {
    # glibc 核心（绝不随包）
    "libc.so.6","libm.so.6","libmvec.so.1","libdl.so.2","libpthread.so.0",
    "librt.so.1","libresolv.so.2","libnsl.so.3","libutil.so.1","libanl.so.1",
    "ld-linux-x86-64.so.2","libgcc_s.so.1","libstdc++.so.6",
    # glvnd / Vulkan loader：必须用宿主版本
    "libEGL.so.1","libGL.so.1","libGLdispatch.so.0","libGLX.so.0",
    "libOpenGL.so.0","libGLESv2.so.2","libvulkan.so.1",
    # glib/gtk 全家桶：必须与宿主桌面版本一致
    "libglib-2.0.so.0","libgobject-2.0.so.0","libgio-2.0.so.0",
    "libgmodule-2.0.so.0","libgthread-2.0.so.0","libgtk-3.so.0","libgdk-3.so.0",
    "libatk-1.0.so.0","libatk-bridge-2.0.so.0","libatspi.so.0","libdbus-1.so.3",
    "libpango-1.0.so.0","libpangocairo-1.0.so.0","libpangoft2-1.0.so.0",
    "libcairo.so.2","libcairo-gobject.so.2","libgdk_pixbuf-2.0.so.0",
    "libfontconfig.so.1","libfreetype.so.6","libharfbuzz.so.0",
    "libfribidi.so.0","libthai.so.0","libpng16.so.16","libepoxy.so.0",
    "libxkbcommon.so.0","libselinux.so.1","libpcre2-8.so.0","libexpat.so.1",
    # X11 / Wayland 基础层
    "libX11.so.6","libX11-xcb.so.1","libxcb.so.1","libXau.so.6","libXdmcp.so.6",
    "libwayland-client.so.0","libwayland-cursor.so.0","libwayland-egl.so.1",
}

have = set(os.listdir(libdir))
missing = {}
for f in sorted(have):
    p = os.path.join(libdir, f)
    if not (os.path.isfile(p) or os.path.islink(p)):
        continue
    try:
        out = subprocess.run(["objdump","-p",p], capture_output=True,
                             text=True, timeout=15).stdout
    except Exception:
        continue
    for m in re.finditer(r"NEEDED\s+(\S+)", out):
        n = m.group(1)
        if n not in have and n not in HOST_OK:
            missing.setdefault(n, set()).add(f)

if missing:
    print("❌ 依赖不闭合，以下库既不在 bundle 也不在宿主白名单：")
    for n in sorted(missing):
        print(f"   {n}  ←  {', '.join(sorted(missing[n])[:3])}")
    sys.exit(1)
print("✅ 依赖闭合校验通过")
PY
[ $? -ne 0 ] && { echo "打包中止：依赖不闭合"; exit 1; }

# 4. 打包
mkdir -p "$ROOT/dist"
rm -f "$OUT"
export ARCH=x86_64
/tmp/aitool/squashfs-root/AppRun --no-appstream \
  --runtime-file "$STAGING/runtime-x86_64" \
  "$STAGING/AppDir" "$OUT"

md5sum "$OUT"
ls -l "$OUT"
