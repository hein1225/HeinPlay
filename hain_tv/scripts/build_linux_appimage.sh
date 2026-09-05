#!/usr/bin/env bash
# 海因影视 Linux AppImage 构建脚本
# 需在 Linux / WSL 环境运行（GTK 嵌入同时兼容 X11 与 Wayland）。
set -euo pipefail

# 优先使用 Linux 原生文件系统里的 Flutter（~/flutter、/opt/flutter 等），
# 避免在 WSL 中误用 Windows 盘的 /mnt/<盘>/flutter（其 shell 脚本为 CRLF 行尾，
# bash 会报 "$'\r': command not found"）。
for CANDIDATE in "$HOME/flutter/bin" "/opt/flutter/bin" "/usr/local/flutter/bin"; do
  if [ -x "$CANDIDATE/flutter" ]; then
    export PATH="$CANDIDATE:$PATH"
    break
  fi
done

FLUTTER_BIN="$(command -v flutter || true)"
if [ -z "$FLUTTER_BIN" ]; then
  echo "错误：WSL/Linux 中未找到 flutter，请先安装 Flutter 并加入 PATH。" >&2
  echo "推荐安装到 Linux 原生文件系统（如 ~/flutter），脚本会自动优先使用。" >&2
  exit 1
fi
if [[ "$FLUTTER_BIN" == /mnt/* ]]; then
  echo "错误：检测到 flutter 仍来自 Windows 挂载盘 ($FLUTTER_BIN)。" >&2
  echo "请在 WSL 内安装 Linux 版 Flutter 到原生文件系统（如 ~/flutter），" >&2
  echo "或删除/重命名 Windows PATH 中的 flutter，确保 ~/flutter/bin 在 PATH 最前。" >&2
  exit 1
fi

echo "==> 使用 Flutter: $FLUTTER_BIN"

# 系统依赖自检：flutter build linux 需要 GTK3 开发库 + clang/cmake/ninja/pkg-config；
# volume_controller 插件在 Linux 上需要 ALSA 开发库（find_package(ALSA)）。
# 用 pkg-config 精确检测（避免头文件路径误判），缺失时尝试自动安装，否则给出清晰提示。
ensure_system_deps() {
  local MISSING=()
  command -v pkg-config >/dev/null 2>&1 || MISSING+=(pkg-config)
  pkg-config --exists gtk+-3.0 2>/dev/null || MISSING+=(libgtk-3-dev)
  # ALSA：volume_controller 插件 Linux 端 require ALSA
  pkg-config --exists alsa 2>/dev/null || MISSING+=(libasound2-dev)
  # ninja/cmake/clang：Flutter Linux 工具链（CI 自带，本地可能需装）
  command -v ninja >/dev/null 2>&1 || MISSING+=(ninja-build)
  command -v cmake >/dev/null 2>&1 || MISSING+=(cmake)
  command -v clang >/dev/null 2>&1 || MISSING+=(clang)
  # appimage-builder 运行依赖（打包 AppImage 时需要）：patchelf / file / mksquashfs
  command -v patchelf >/dev/null 2>&1 || MISSING+=(patchelf)
  command -v file >/dev/null 2>&1 || MISSING+=(file)
  command -v mksquashfs >/dev/null 2>&1 || MISSING+=(squashfs-tools)
  # zsyncmake：appimage-builder 在 AppImage 收尾阶段生成 .zsync 增量更新文件需要它。
  command -v zsyncmake >/dev/null 2>&1 || MISSING+=(zsync)

  if [ ${#MISSING[@]} -eq 0 ]; then
    echo "==> 系统构建依赖已满足"
    return 0
  fi

  # 按用户约定：缺什么依赖由用户自行安装，脚本只明确告知命令并退出，绝不自动 sudo 安装。
  echo "错误：缺少以下系统构建依赖，请手动安装后重跑 build_all.bat：" >&2
  echo "  sudo apt-get update && sudo apt-get install -y ${MISSING[*]}" >&2
  echo "" >&2
  echo "说明（${MISSING[*]} 各自用途）：" >&2
  echo "  pkg-config / libgtk-3-dev / libasound2-dev —— flutter build linux 与 ALSA（音量插件）必须" >&2
  echo "  ninja-build / cmake / clang —— Flutter Linux 工具链" >&2
  echo "  patchelf / file / squashfs-tools(mksquashfs) —— appimage-builder 打包 AppImage 必须" >&2
  echo "  zsync(zsyncmake) —— 生成 .zsync 增量更新（若不装也可，但需我移除 recipe 的 update-information）" >&2
  exit 1
}
ensure_system_deps

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$PROJECT_DIR/.." && pwd)"

# PUB_CACHE 指向项目本地缓存（与 Windows 构建约定一致，避免 fvp 的 mdk-sdk 重新下载）。
export PUB_CACHE="$PROJECT_DIR/.pub-cache"

# 解析 pubspec.yaml 中的版本号（去掉 +buildNumber 后缀）。
VERSION_FULL="$(grep -m1 '^version:' "$PROJECT_DIR/pubspec.yaml" | sed 's/version:[[:space:]]*//')"
VERSION="${VERSION_FULL%%+*}"

echo "==> 构建版本: $VERSION"

# 在 WSL 原生文件系统（/tmp，ext4）中创建构建目录，避免 DrvFS（/mnt/<盘>）上
# flutter build linux 的 CMake install/bundle 步骤因 9P 挂载限制而 silently fail，
# 导致"✓ Built"后却没有 bundle 目录。
BUILD_ROOT="$(mktemp -d -t heinplay-linux-build-XXXXXX)"
BUILD_HAIN_DIR="$BUILD_ROOT/hain_tv"
echo "==> 使用 WSL 原生构建目录: $BUILD_ROOT"

echo "==> 同步项目文件到构建目录"
if command -v rsync >/dev/null 2>&1; then
  rsync -a --delete \
    --exclude='.git' \
    --exclude='build' \
    --exclude='.dart_tool' \
    --exclude='dist' \
    --exclude='logs' \
    "$PROJECT_DIR/" "$BUILD_HAIN_DIR/"
else
  # 无 rsync 时的降级方案：先清空再复制。
  rm -rf "$BUILD_HAIN_DIR"
  mkdir -p "$BUILD_HAIN_DIR"
  cp -r "$PROJECT_DIR/"* "$BUILD_HAIN_DIR/" 2>/dev/null || true
  rm -rf "$BUILD_HAIN_DIR/build" "$BUILD_HAIN_DIR/.dart_tool" "$BUILD_HAIN_DIR/dist" "$BUILD_HAIN_DIR/logs"
fi

# AppImageBuilder.yml 的 app_info.icon 为纯图标名 mo_ico（不带路径/扩展名），
# appimage-builder 的 IconBundler 只在 AppDir 的 usr/share/icons、usr/share/pixmaps 等
# 标准 freedesktop 目录按名搜索，不会把 icon 值当文件路径解析。因此这里需要把图标文件
# 按标准布局拷进 bundle：usr/share/icons/hicolor/256x256/apps/mo_ico.png。
# 图标来源优先级（跨平台品牌一致，优先用 Windows 端图标）：
#   1) windows/runner/resources/app_icon.ico —— 已提交仓库，抽取其内嵌 256x256 PNG；
#   2) 仓库根 plan/mo_ico.png（本地）；
#   3) android banner.png（CI 无 plan/ 时兜底）。
# 抽取 ico 内嵌 PNG 用 Python 标准库即可（Flutter 生成的 ico 大尺寸通常为 PNG 内嵌），
# 不依赖 ImageMagick / PIL，windows/ 目录为已提交资源，本地与 CI 均可取。
ICON_STAGED="$BUILD_ROOT/plan_mo_ico_staged.png"
WIN_ICO="$PROJECT_DIR/windows/runner/resources/app_icon.ico"
ICON_SRC=""
if [ -f "$WIN_ICO" ]; then
  if python3 - "$WIN_ICO" "$ICON_STAGED" <<'PYEOF'
import struct, sys
ico, out = sys.argv[1], sys.argv[2]
with open(ico, "rb") as f:
    d = f.read()
if d[:4] != b"\x00\x00\x01\x00":
    sys.exit("not-ico")
n = struct.unpack("<H", d[4:6])[0]
best = None
best_score = -1
for i in range(n):
    o = 6 + 16 * i
    w = d[o]
    h = d[o + 1]
    bw = 256 if w == 0 else w
    bh = 256 if h == 0 else h
    size = struct.unpack("<I", d[o + 8 : o + 12])[0]
    ioff = struct.unpack("<I", d[o + 12 : o + 16])[0]
    is_png = d[ioff : ioff + 4] == b"\x89PNG"
    # 优先选内嵌 PNG（更保真），同类型取尺寸最大
    score = bw * bh + (10 ** 7 if is_png else 0)
    if score > best_score:
        best_score = score
        best = (ioff, size, is_png)
ioff, size, is_png = best
img = d[ioff : ioff + size]
if img[:4] != b"\x89PNG":
    sys.exit("chosen-icon-not-png")
with open(out, "wb") as f:
    f.write(img)
print("已抽取 Windows 图标内嵌 PNG (%d 字节)" % size)
PYEOF
  then
    ICON_SRC="$WIN_ICO"
    echo "==> AppImage 图标来源：Windows 端 app_icon.ico（已抽取内嵌 PNG）"
  fi
fi
if [ -z "$ICON_SRC" ] && [ -f "$REPO_DIR/plan/mo_ico.png" ]; then
  cp -f "$REPO_DIR/plan/mo_ico.png" "$ICON_STAGED"
  ICON_SRC="$REPO_DIR/plan/mo_ico.png"
fi
if [ -z "$ICON_SRC" ] && [ -f "$PROJECT_DIR/android/app/src/main/res/drawable/banner.png" ]; then
  cp -f "$PROJECT_DIR/android/app/src/main/res/drawable/banner.png" "$ICON_STAGED"
  ICON_SRC="$PROJECT_DIR/android/app/src/main/res/drawable/banner.png"
  echo "==> 提示：已回退用 android banner.png 作为 AppImage 图标"
fi
if [ -z "$ICON_SRC" ]; then
  echo "警告：未找到任何可用图标源（Windows app_icon.ico / plan/mo_ico.png / android banner.png 均不可用），" >&2
  echo "        AppImage 将使用无图标打包。" >&2
fi

cd "$BUILD_HAIN_DIR"

# 首次需要生成 linux 平台目录（Flutter 默认模板）。
if [ ! -d linux ]; then
  echo "==> 生成 linux 平台目录"
  flutter create --platforms=linux .
fi

# 获取依赖并构建 Linux 版（复用 TV 布局 + 桌面全屏，fvp 后端）。
echo "==> flutter pub get"
flutter pub get
echo "==> flutter build linux --target lib/main_linux.dart --release"
flutter build linux --target lib/main_linux.dart --release

BUNDLE="$BUILD_HAIN_DIR/build/linux/x64/release/bundle"
if [ ! -d "$BUNDLE" ]; then
  echo "错误：未找到构建产物: $BUNDLE" >&2
  echo "诊断：build/linux 目录结构：" >&2
  ls -laR "$BUILD_HAIN_DIR/build/linux" 2>&1 | head -n 60 || true
  rm -rf "$BUILD_ROOT"
  exit 1
fi

# 将图标按 freedesktop 标准布局放入 bundle，供 appimage-builder 的 IconBundler 按名检索。
# 必须放在 $BUNDLE 已生成之后；图标名需与 AppImageBuilder.yml 的 app_info.icon 一致（mo_ico）。
if [ -f "$ICON_STAGED" ]; then
  mkdir -p "$BUNDLE/usr/share/icons/hicolor/256x256/apps"
  cp -f "$ICON_STAGED" "$BUNDLE/usr/share/icons/hicolor/256x256/apps/mo_ico.png"
  echo "==> 已放入 AppImage 图标: $BUNDLE/usr/share/icons/hicolor/256x256/apps/mo_ico.png"
fi

# AppImage 打包：优先使用 appimage-builder；若不可用则降级为打包可运行 bundle（tar.gz）。
# 确保常见安装位置在 PATH 中：pip --user 安装的 appimage-builder 位于 ~/.local/bin，
# 而通过 `wsl -e bash` 调起的非登录式 shell 默认不会加载 ~/.bashrc，可能漏掉该目录。
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
case ":$PATH:" in
  *":/usr/local/bin:"*) ;;
  *) export PATH="/usr/local/bin:$PATH" ;;
esac

# appimage-builder 检测：你此前明确要求直接产出 AppImage，并已自行安装 appimage-builder。
# 因此这里只检测、缺失就明确告知安装命令并退出；绝不自动 pip 安装，也不偷偷降级为 tar.gz。
APP_IMAGE_OK=0
if command -v appimage-builder >/dev/null 2>&1; then
  echo "==> appimage-builder 已就绪"
  APP_IMAGE_OK=1
else
  echo "错误：未检测到 appimage-builder，请安装后再运行（你此前要求直接产出 AppImage）：" >&2
  echo "  pipx install appimage-builder        # 推荐" >&2
  echo "  或  pip3 install --break-system-packages appimage-builder" >&2
  exit 1
fi

# 将产物统一收集到原项目的 dist 目录，便于 CI 上传 / 本地取用。
mkdir -p "$PROJECT_DIR/dist"

# === 修正 appimage-builder 对 stripped 二进制的架构检测（关键坑）===
# appimage-builder 的 AppRun2 运行时在 _find_embed_archs 阶段扫描 AppDir 里的可执行
# ELF，并用 `readelf -s` 查找 `_start` 符号来判定"这是可执行文件"。但 Flutter release
# 构建默认 strip 二进制，`.symtab` 被移除，`_start` 只存在于该表（不在 `.dynsym`），于是
# `hain_tv` 不被认作 BinaryExecutable，集合为空 → "Unable to determine the bundle
# architecture"。修正：给 has_start_symbol 增加回退——读不到 `_start` 时用 `readelf -h`
# 的 ELF Type（ET_EXEC / ET_DYN）判定可执行性；对未 strip 的二进制同样安全。
# 该修补幂等：已打过补丁（源码含 _START_SYMBOL_PATCHED_ 标记）则跳过；版本差异导致锚点
# 不匹配时优雅跳过（不破坏打包，仅可能在极少数新版下仍需手动处理）。
patch_appimage_builder_elf() {
  local AIB_BIN AIB_PY ELF_PY
  AIB_BIN="$(command -v appimage-builder || true)"
  [ -z "$AIB_BIN" ] && return 0
  AIB_PY="$(head -n1 "$(readlink -f "$AIB_BIN" 2>/dev/null || echo "$AIB_BIN")" 2>/dev/null | sed 's/^#!//')"
  [ -z "$AIB_PY" ] && AIB_PY="python3"
  ELF_PY="$("$AIB_PY" -c 'import appimagebuilder.utils.elf as m; print(m.__file__)' 2>/dev/null || true)"
  [ -z "$ELF_PY" ] && return 0
  if grep -q "_START_SYMBOL_PATCHED_" "$ELF_PY" 2>/dev/null; then
    return 0
  fi
  "$AIB_PY" - "$ELF_PY" <<'PYEOF' || echo "警告：appimage-builder elf.py 自动修补失败，将尝试原样打包（若仍报 arch 错误请手动处理）。" >&2
import sys
p = sys.argv[1]
s = open(p).read()
if "_START_SYMBOL_PATCHED_" in s:
    sys.exit(0)
old = '''def has_start_symbol(path):
    """
    Determine if an elf is executable

    The `_start` symbol must be present in every runnable elf file.
    http://www.dbp-consulting.com/tutorials/debugging/linuxProgramStartup.html
    """
    readelf_path = shell.require_executable("readelf")
    # note: don't use `shell=True` as it forces the usage of the system shell which cases a failure if readelf is embed.
    _proc = subprocess.run(
        [readelf_path, "-s", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )

    has_main_method = False
    if _proc.returncode == 0:
        output = _proc.stdout.decode("utf-8")
        has_main_method = "_start" in output
    return has_main_method'''
if old not in s:
    # 版本差异，锚点不匹配——不强行改，避免破坏
    print("skip: anchor not found in", p)
    sys.exit(0)
new = '''def has_start_symbol(path):
    """
    Determine if an elf is executable

    The `_start` symbol must be present in every runnable elf file.
    http://www.dbp-consulting.com/tutorials/debugging/linuxProgramStartup.html

    NOTE(patched by heinplay build): Flutter release strips the binary, removing
    `.symtab` (and thus `_start`). Fall back to the ELF type (ET_EXEC / ET_DYN)
    reported by `readelf -h`, which survives stripping.
    """
    readelf_path = shell.require_executable("readelf")
    # note: don't use `shell=True` as it forces the usage of the system shell which cases a failure if readelf is embed.
    _proc = subprocess.run(
        [readelf_path, "-s", path],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    has_main_method = False
    if _proc.returncode == 0:
        output = _proc.stdout.decode("utf-8")
        has_main_method = "_start" in output
    if not has_main_method:
        _h = subprocess.run(
            [readelf_path, "-h", path],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        if _h.returncode == 0:
            for line in _h.stdout.decode("utf-8").splitlines():
                if "Type:" in line:
                    val = line.split(":", 1)[1].strip()
                    if "EXEC" in val or "DYN" in val:
                        has_main_method = True
                    break
    return has_main_method'''
s = s.replace(old, new, 1)
open(p, "w").write(s)
print("patched", p)
PYEOF
}
patch_appimage_builder_elf

if [ "$APP_IMAGE_OK" -eq 1 ]; then
  export APP_VERSION="$VERSION"
  # 经 run_appimage_builder.py 垫片运行：该垫片在运行时 monkeypatch appimage-builder，
  # 修复其对 Flutter release（已 strip）二进制缺失 _start 符号导致的
  # "Unable to determine the bundle architecture" 架构检测失败。垫片用构建脚本依赖的
  # 同一份 appimage-builder 解释器执行，保证补丁对其生效。
  AIB_BIN="$(readlink -f "$(command -v appimage-builder)")"
  AIB_PYTHON="$(head -n1 "$AIB_BIN" 2>/dev/null | sed 's/^#!//')"
  if [ ! -x "$AIB_PYTHON" ]; then
    AIB_PYTHON="$(dirname "$AIB_BIN")/python"
  fi
  echo "==> 使用 appimage-builder (含 arch 检测补丁): $AIB_PYTHON"
  echo "==> $AIB_PYTHON $SCRIPT_DIR/run_appimage_builder.py --recipe AppImageBuilder.yml --appdir $BUNDLE"
  # 关键修正：部分 appimage-builder 版本（pipx 安装版）的 recipe schema 不识别
  # AppDir.path 键，会回退到空的默认 AppDir 目录，导致打包时找不到可执行文件
  # hain_tv（FileNotFoundError: .../AppDir/hain_tv）。这里直接把构建好的 bundle
  # 绝对路径通过 --appdir 传给 appimage-builder，使其以 bundle 为 AppDir 直接打包。
  # 注意：临时关闭 set -e，以便捕获 appimage-builder 的真实退出码并给出清晰提示，
  # 而不是因 set -e 直接整体 abort（此前日志里只看到 traceback 而无后续诊断）。
  set +e
  "$AIB_PYTHON" "$SCRIPT_DIR/run_appimage_builder.py" --recipe AppImageBuilder.yml --appdir "$BUNDLE"
  AIB_RC=$?
  set -e

  shopt -s nullglob
  GENERATED=( *.AppImage appimage-build/*.AppImage )
  shopt -u nullglob

  if [ "$AIB_RC" -eq 0 ] && [ ${#GENERATED[@]} -gt 0 ]; then
    for f in "${GENERATED[@]}"; do
      DEST="$PROJECT_DIR/dist/heinplay-${VERSION}-linux-x86_64.AppImage"
      cp -f "$f" "$DEST"
      echo "已生成: $DEST"
    done
  else
    echo "错误：appimage-builder 未成功产出 .AppImage（退出码 $AIB_RC）。" >&2
    echo "诊断：当前目录 .AppImage 文件：" >&2
    ls -la *.AppImage 2>/dev/null || echo "  （无）" >&2
    echo "" >&2
    echo "请查看上方 appimage-builder 的实际错误输出。常见原因：" >&2
    echo "  1) recipe 校验失败（schema 错误）——对照 AppImageBuilder.yml 与当前版本语法；" >&2
    echo "  2) AppDir.apt 段需要 Docker + apt-key（新版 Ubuntu/WSL 默认无 apt-key）——" >&2
    echo "     已默认移除该段；若日后要完全可移植的 AppImage，需在具备 Docker 与" >&2
    echo "     apt-key 的环境（如 CI）再加回；" >&2
    echo "  3) 图标缺失——脚本会把 Windows app_icon.ico（抽取内嵌 PNG）优先拷入 bundle 的" >&2
    echo "     usr/share/icons/hicolor/256x256/apps/mo_ico.png，与 AppImageBuilder.yml 的" >&2
    echo "     app_info.icon: mo_ico 对应；回退源为 plan/mo_ico.png / android banner.png。" >&2
    rm -rf "$BUILD_ROOT"
    exit 1
  fi
fi

if [ "$APP_IMAGE_OK" -ne 1 ]; then
  # 降级方案：直接打包 flutter 产出的 bundle 为 tar.gz。该目录本身即可运行
  # （解压后执行 ./hain_tv），与 AppImage 等价的可运行产物，仅少了 AppImage 的
  # 单文件便捷性，但无需 appimage-builder / FUSE。
  echo "==> 降级打包：将 bundle 打包为 tar.gz（解压后运行 ./hain_tv 即可）"
  chmod +x "$BUNDLE/hain_tv" 2>/dev/null || true
  TARBALL="$PROJECT_DIR/dist/heinplay-${VERSION}-linux-x86_64.tar.gz"
  tar -czf "$TARBALL" -C "$BUNDLE" .
  echo "已生成: $TARBALL"
fi

rm -rf "$BUILD_ROOT"
echo "==> Linux 版构建完成"
