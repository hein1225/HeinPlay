#!/usr/bin/env bash
# 海因影视 Linux AppImage 构建脚本
# 需在 Linux / WSL 环境运行（GTK 嵌入同时兼容 X11 与 Wayland）。
set -euo pipefail

# ============================================================================
# 🔴 命名规范（2026-10-23 用户实测三轮后定稿，勿凭记忆改动）
# ============================================================================
# 两条并列的目标，**互不影响**，别再混为一谈：
#   ① 交付文件名**带版本**：heinplay-<版本>-linux-x86_64.AppImage
#      —— 各版本产物可区分；配套的一键安装脚本 install_heinplay_linux.sh
#         正是从文件名里提取版本号（heinplay-<ver>-linux…）写进 desktop 条目。
#   ② 桌面集成器安装后，文件**永远**叫 heinplay.appimage，所有版本一致。
#
# Gear Lever 的真实命名逻辑（上游 src/providers/AppImageProvider.py, install_file()）：
#     appimage_filename = extracted_appimage.desktop_entry.getName()  # ← desktop 条目的 Name=
#     appimage_filename = appimage_filename.lower().replace(' ', '_')
#     appimage_filename = f'{appimage_filename}.appimage'             # → "heinplay.appimage"
#     ...
#     while appimage_filename in files_in_dest_dir:                   # 目标目录已有同名文件
#         if i == 0 and version: → heinplay.appimage_1_4_0.appimage
#         else:                  → heinplay.appimage_0.appimage（i=0 兜底，纯属退化）
#     # 版本来自 desktop_entry.get('X-AppImage-Version','')，缺失则为空串
#
# ⇒ 结论（此坑踩过两次，务必记住）：
#   · 安装后的名字来自 desktop 条目的 Name=，**与交付文件名无关**：
#     交付名带不带版本都无所谓；Name=HeinPlay ⇒ 装出来就是 heinplay.appimage。
#     ⇒ 交付名带版本 ✓ 与 安装后不带版本 ✓ 同时成立，二者不冲突。
#   · X-AppImage-Version **必须保留**：删掉它并不能消除后缀，只会把 _1_4_0
#     退化成毫无意义的 _0（用户实测得到 heinplay.appimage_0.appimage）；
#     且 Gear Lever 安装时把该键写进系统 desktop 文件，其更新检测依赖它。
#   · 后缀只在目标目录（~/.local/share/gearlever/）已有同名文件时才出现，
#     这是 Gear Lever「不覆盖已有安装」的既定策略，**无法由 AppImage 内部消除**。
#     想要"同名覆盖升级"，走覆盖式安装路径即可：
#       - 一键安装脚本：install -m 755 → mv -f 覆盖 ~/Applications/heinplay.appimage；
#       - Gear Lever 内置更新：走 REPLACE 分支，保留旧 basename 不加后缀。
#
# 本项目两条铁律（缺一不可，违反即构建失败）：
#   ① AppImage 内 desktop 条目 Name=HeinPlay —— 决定集成后的基础名；
#   ② X-AppImage-Version 存在且非空。
# 打包后由 verify_appimage_desktop_entry() 强制校验。
# ============================================================================

# ============================================================================
# 🔴 Linux 构建铁律速查（2026-10-24 汇总 —— **脚本自带，不再依赖会话记忆**）
# ============================================================================
# 为什么要有这块：本项目 Linux 版发生过 **3 次「打开完全无反应」**，每次都是
# 「这轮修好、下次重建又复发」。根因不是难，而是**约束只存在于工作日志和
# 人的记忆里**，构建脚本自己不知道 → 换会话 / 隔几天 / 换人就漂移。
#
# ⇒ 对策：把每条约束变成「**脚本能自己检查的硬规则**」，并在构建时打印出来。
#
# 【A. 已由脚本自动强制的 —— 违反即构建失败，不需要人记】
#   1. bundle 依赖策略：系统图形栈库绝不自带
#      → 真源 linux/bundle_lib_policy.txt（唯一真源，cmake 与脚本共用同一份）
#      → 构建期跳过收集 + 打包期清洗 + 交付物解包自检
#      → 症状：双击无反应 / exit=134 / eglGetPlatformDisplayEXT 无 provider
#      → 真机：Bazzite(Fedora 44) 掌机 69
#   2. AppImage 内 desktop 条目 Name=HeinPlay + X-AppImage-Version 非空
#      → 见上方「命名规范」+ verify_appimage_desktop_entry()
#   3. appimage-builder 绝对路径自解析（不靠 export PATH）
#      → 见 resolve_appimage_builder()
#   4. appimage-builder 对 stripped 二进制的架构检测补丁
#      → 见 patch_appimage_builder_elf() + run_appimage_builder.py
#
# 【B. 必须人工保证的 —— 脚本无法替你决定，但别再凭记忆】
#   5. 构建入口铁律：--flavor 只决定 Android 配置，**必须显式 --target**
#        mobile   → --flavor mobile   --target lib/main_mobile.dart
#        tv       → --flavor tv       --target lib/main_tv.dart
#        tvLegacy → --flavor tvlegacy --target lib/main_tv.dart
#      ⚠️ Linux 桌面版固定 --target lib/main_linux.dart（见下方构建命令）。
#   6. 「ldd 0 not found」**不等于**「能跑」：跨发行版符号版本不匹配会让
#      ldd 全过但启动即崩 → **必须在目标发行版真机验证**（Fedora/Bazzite 系）。
#   7. Linux 版在**容器内**构建；只有 Windows 版需要到 server 电脑构建。
#   8. 交付前逐个平台**串行**构建，不要并发。
#
# 【C. 真机验证入口】
#   交付包内附 diagnose_linux_appimage.sh：在目标机跑一次即可拿到启动 stderr /
#   依赖来源 / 图形栈环境。
# ============================================================================

# 🔴 构建开始前自报铁律：让约束在**构建现场可见**，而不是躺在注释里没人看。
echo "=============================================================="
echo " HeinPlay Linux AppImage 构建 · 铁律速查"
echo "=============================================================="
echo " · bundle 依赖策略：系统图形栈库绝不自带"
echo "   （真源 linux/bundle_lib_policy.txt：构建期跳过 + 打包期清洗"
echo "     + 交付物解包自检，违反即构建失败）"
echo " · 交付名带版本 heinplay-<ver>-linux-x86_64.AppImage；"
echo "   集成器安装后一律叫 heinplay.appimage（由内嵌 desktop 的 Name= 决定）"
echo " · --flavor 只决定 Android 配置，Linux 必须显式 --target lib/main_linux.dart"
echo " · 「ldd 0 not found」≠ 能跑：跨发行版必须目标机真验证"
echo "=============================================================="

# 优先使用 Linux 原生文件系统里的 Flutter（~/flutter、/opt/flutter 等），
# 避免在 WSL 中误用 Windows 盘的 /mnt/<盘>/flutter（其 shell 脚本为 CRLF 行尾，
# bash 会报 "$'\r': command not found"）。
#
# 🔴 2026-10-23 固化（用户反馈「Linux 构建总是出现记忆漂移」）：
#   候选清单里**必须**包含团队 SDK 目录。脚本原来只探测 $HOME/flutter/bin、
#   /opt/flutter/bin、/usr/local/flutter/bin —— 三个在本机全都不存在，
#   真实 SDK 在 /opt/team/tool-deps/sdks/flutter-3.47.5/bin。
#   结果就是每次构建都得靠"我记得手动 export PATH"，换会话/换人就断 ——
#   这正是记忆漂移的根源：记忆是软约束，脚本必须自包含。
#   现在：精确候选 → 团队 SDK 目录通配（按版本号排序取最大）→ 报错。
pick_flutter_dir() {
  local CAND
  # 🔴 CI（GitHub Actions）里 flutter 由 subosito/flutter-action 安装，
  #    路径只在 $FLUTTER_ROOT 里（例：/opt/hostedtoolcache/flutter/stable-3.47.5-x64/flutter），
  #    前面几个候选全都不存在 → 脚本直接报「未找到 flutter」而失败。
  #    所以这里把 $FLUTTER_ROOT 放在候选首位。
  for CAND in \
    "${FLUTTER_ROOT:+$FLUTTER_ROOT/bin}" \
    "$HOME/flutter/bin" \
    "/opt/flutter/bin" \
    "/usr/local/flutter/bin" \
    "/opt/team/tool-deps/sdks/flutter-3.47.5/bin"; do
    if [ -x "$CAND/flutter" ]; then
      echo "$CAND"
      return 0
    fi
  done
  # 兜底：团队 SDK 目录下版本号最大的一个（sort -V 保证 3.47.5 > 3.9.0）
  local GLOBS=()
  while IFS= read -r line; do
    [ -n "$line" ] && GLOBS+=("$line")
  done < <(ls -d /opt/team/tool-deps/sdks/flutter-*/bin 2>/dev/null | sort -V)
  local i
  for ((i=${#GLOBS[@]}-1; i>=0; i--)); do
    if [ -x "${GLOBS[$i]}/flutter" ]; then
      echo "${GLOBS[$i]}"
      return 0
    fi
  done
  return 1
}

FLUTTER_DIR="$(pick_flutter_dir || true)"
if [ -z "$FLUTTER_DIR" ]; then
  echo "错误：Linux 上未找到 flutter。" >&2
  echo "请安装 Flutter 并确保以下任一路径存在可执行文件 flutter：" >&2
  echo "  \$FLUTTER_ROOT/bin   （CI / 通用环境，subosito/flutter-action 会设置）" >&2
  echo "  \$HOME/flutter/bin | /opt/flutter/bin | /usr/local/flutter/bin" >&2
  echo "  /opt/team/tool-deps/sdks/flutter-*/bin   （团队 SDK 目录，本机实际位置）" >&2
  exit 1
fi
export PATH="$FLUTTER_DIR:$PATH"

FLUTTER_BIN="$(command -v flutter || true)"
if [ -z "$FLUTTER_BIN" ]; then
  echo "错误：解析出的 flutter 不可用（FLUTTER_DIR=$FLUTTER_DIR）。" >&2
  exit 1
fi
if [[ "$FLUTTER_BIN" == /mnt/* ]]; then
  echo "错误：检测到 flutter 仍来自 Windows 挂载盘 ($FLUTTER_BIN)。" >&2
  echo "请在 WSL 内安装 Linux 版 Flutter 到原生文件系统（如 ~/flutter），" >&2
  echo "或删除/重命名 Windows PATH 中的 flutter，确保 flutter 路径在 PATH 最前。" >&2
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

# 产物统一输出到「仓库根 dist」——所有平台的最终产物（APK / zip / AppImage / HAP）都归在一处。
# 若本工程被单独复制出仓库（父目录无 .git），则回退到工程内 dist，保证脚本仍可独立使用。
if [ -d "$REPO_DIR/.git" ]; then
  DIST_DIR="$REPO_DIR/dist"
else
  echo "警告：未在 $REPO_DIR 检测到仓库根（无 .git），产物将输出到工程内: $PROJECT_DIR/dist" >&2
  DIST_DIR="$PROJECT_DIR/dist"
fi

# PUB_CACHE 统一指向团队工具目录（唯一存放位置），工程内不再保留缓存副本。
# 🔴 2026-10-22：此前指向工程内 .pub-cache，三工程各自一份、约 2.1GB 重复。
TEAM_PUB_CACHE=/opt/team/tool-deps/cache/pub-cache
if [ -d "$TEAM_PUB_CACHE" ]; then
  export PUB_CACHE="$TEAM_PUB_CACHE"
else
  echo "警告：未找到统一 pub 缓存 $TEAM_PUB_CACHE，将使用 Flutter 默认位置" >&2
fi

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
# 同步时需要排除的内容：Linux 构建完全用不到，但体积可观
# （tvlegacy 是独立的 Android 工程副本，约 2.0G；.pub-cache 由 PUB_CACHE 指向
# 源工程目录，构建副本里再存一份纯属浪费）。
SYNC_EXCLUDES=(.git build .dart_tool dist logs tvlegacy .pub-cache)

if command -v rsync >/dev/null 2>&1; then
  rsync_args=(-a --delete)
  for ex in "${SYNC_EXCLUDES[@]}"; do
    rsync_args+=(--exclude="$ex")
  done
  rsync "${rsync_args[@]}" "$PROJECT_DIR/" "$BUILD_HAIN_DIR/"
else
  # 无 rsync 时的降级方案：tar 带排除直接落地。
  #
  # ⚠️ 切勿改回 `cp -r "$PROJECT_DIR/"*` —— 那会先把 tvlegacy(2.0G)/build 等大目录
  # 整份拷进 /tmp（tmpfs 通常只有几 G）之后才删除，实测 cp 阶段可超过 8 分钟，
  # 并且有撑爆 tmpfs 的风险（本机 WSL Debian 没装 rsync，走的正是这条分支）。
  rm -rf "$BUILD_HAIN_DIR"
  mkdir -p "$BUILD_HAIN_DIR"
  tar_args=()
  for ex in "${SYNC_EXCLUDES[@]}"; do
    tar_args+=(--exclude="./$ex")
  done
  tar -C "$PROJECT_DIR" "${tar_args[@]}" -cf - . | tar -C "$BUILD_HAIN_DIR" -xf -
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

# =============================================================================
# 🔴🔴 打包前最终清洗 + 自检：剔除「系统图形栈」库（2026-10-24 真机崩溃固化）
# =============================================================================
#
# 【本段存在的理由 —— 根治「Linux 构建记忆漂移」】
#   2026-10-19 / 10-20 / 10-24 三次「Linux 版双击打开完全无反应」，根因同一类：
#   **把构建机（Debian）的系统图形栈库打进 AppImage**，到目标机
#   （Bazzite/Fedora 44）蒙蔽了系统自带库 → 符号版本不匹配 → 启动即崩。
#   三次都是「这轮修好、下次重建又复发」，因为约束只写在工作日志和人的记忆里，
#   **构建脚本自己并不知道** → 换会话、隔几天、换人就漂移。
#
#   ⇒ 对策不是「再记一次」，而是把约束变成**脚本自带的硬规则**：
#     ① 判据与清单放进机器可读文件 linux/bundle_lib_policy.txt（**唯一真源**）；
#     ② 构建期（hein_mpv_install_deps.cmake）读它 → 收集依赖时根本不拷；
#     ③ 打包期（本段）再读它 → 清洗 bundle/lib（覆盖 Flutter 插件等其他来源）；
#     ④ 清洗后**自检**，有残留立刻 fail-fast —— 坏包出不了构建机。
#
# 【本次真机症状与根因（2026-10-24）】
#   症状：69 掌机（Bazzite/Fedora 44）双击桌面图标完全无反应；SSH 直跑输出
#     "No provider of eglGetPlatformDisplayEXT found.  Requires one of:
#      EGL_EXT_platform_base"  → exit=134 (SIGABRT)
#   根因：bundle 自带 Debian 的 glvnd（libEGL.so.1 + libGLdispatch.so.0），
#         $ORIGIN 优先 → 蒙蔽 Bazzite 的 Mesa EGL 栈 → Impeller 取不到
#         EGL display → 启动即 abort。
#   已实测：就地剔除该批库后，同一份 AppImage 在 69 正常启动（网络 200、
#         [Display] 启动全屏探测、进程存活）。
# =============================================================================

BUNDLE_POLICY_FILE="$PROJECT_DIR/linux/bundle_lib_policy.txt"
BUNDLE_POLICY_PREFIXES=()
BUNDLE_POLICY_KEEPS=()

# 读取唯一真源；文件缺失 = 直接失败（不许静默降级，那是三次回归的共同原因）。
load_bundle_policy() {
  if [ ! -f "$BUNDLE_POLICY_FILE" ]; then
    echo "错误：找不到依赖策略文件 $BUNDLE_POLICY_FILE" >&2
    echo "      它是 bundle 依赖的唯一真源；缺失会导致目标机启动崩溃。" >&2
    echo "      处理：恢复该文件（git 里也有），或按其顶部说明重建。" >&2
    exit 1
  fi
  BUNDLE_POLICY_PREFIXES=()
  BUNDLE_POLICY_KEEPS=()
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%%#*}"
    line="$(printf '%s' "$line" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    # 🔴 格式校验：前缀里绝不能出现 glob 元字符（* ? [）——
    #    否则 case 通配会命中**所有**库，把 bundle 里的库全删光。
    #    （与 cmake 侧 ^[A-Za-z0-9_.!+-]+$ 的校验保持同一套字符集。）
    case "$line" in
      *'*'*|*'?'*|*'['*)
        echo "警告：策略文件中的非法前缀已跳过: $line" >&2
        continue
        ;;
    esac
    case "$line" in
      !*) BUNDLE_POLICY_KEEPS+=("${line:1}") ;;
      *)  BUNDLE_POLICY_PREFIXES+=("$line") ;;
    esac
  done < "$BUNDLE_POLICY_FILE"

  # 🔴🔴 自动判据：系统桌面栈入口库的**依赖闭包**内的库也一并剔除。
  #   入口库（GTK/GDK/EGL/GBM/X11/Wayland/GLib/Pango/Cairo/gdk-pixbuf/
  #   fontconfig/freetype/ALSA）在任何有桌面的发行版上必然存在，其依赖
  #   （fontconfig/freetype/harfbuzz/xcb/drm/wayland/glib…）也必然由系统
  #   提供且必须与系统同版本 → 闭包内一律不打包。
  #   效果：以后系统多出新的图形栈依赖，**无需改任何清单**，
  #   规则自动覆盖 —— 这才是根治「补漏一次回归一次」的地方。
  #   （与 cmake 侧 hein_mpv_install_deps.cmake 的闭包判据完全同源。）
  local closure_file
  closure_file="$(mktemp)"
  local _e _p
  for _e in libgtk-3.so.0 libgdk-3.so.0 libEGL.so.1 libgbm.so.1 libX11.so.6 \
             libwayland-client.so.0 libglib-2.0.so.0 libgobject-2.0.so.0 \
             libpango-1.0.so.0 libcairo.so.2 libgdk_pixbuf-2.0.so.0 \
             libfontconfig.so.1 libfreetype.so.6 libasound.so.2; do
    _p="$(ldconfig -p 2>/dev/null | awk -v n="$_e" '$1==n {print $NF; exit}')"
    [ -z "$_p" ] && continue
    ldd "$_p" 2>/dev/null | awk '{print $1}' | grep -E '^[a-zA-Z0-9_.+-]+$' \
      >> "$closure_file" || true
  done
  if [ -s "$closure_file" ]; then
    sort -u "$closure_file" -o "$closure_file"
    local _n=0 _son
    while IFS= read -r _son; do
      [ -z "$_son" ] && continue
      BUNDLE_POLICY_PREFIXES+=("$_son")
      _n=$((_n + 1))
    done < "$closure_file"
    echo "==> 自动判据：系统桌面栈依赖闭包 ${_n} 个库已纳入剔除范围"
  else
    echo "警告：未能求出系统桌面栈依赖闭包（入口库缺失？），仅依赖黑名单过滤" >&2
  fi
  rm -f "$closure_file"

  echo "==> 依赖策略已加载：${#BUNDLE_POLICY_PREFIXES[@]} 条剔除前缀 + "\
"${#BUNDLE_POLICY_KEEPS[@]} 条保护（真源 linux/bundle_lib_policy.txt）"
}

# 判断某个文件名是否命中剔除前缀；命中保护名单则放行。
_bundle_policy_hit() {
  local base="$1" p k
  for k in "${BUNDLE_POLICY_KEEPS[@]}"; do
    case "$base" in "$k"*) return 1 ;; esac
  done
  for p in "${BUNDLE_POLICY_PREFIXES[@]}"; do
    case "$base" in "$p"*) return 0 ;; esac
  done
  return 1
}

# 清洗 bundle/lib：把命中策略前缀的库删掉（改由目标机系统提供）。
purge_bundle_system_libs() {
  local libdir="$1" removed=0 f base
  for f in "$libdir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="$(basename "$f")"
    _bundle_policy_hit "$base" || continue
    rm -f "$f"
    echo "    [剔除] $base"
    removed=$((removed + 1))
  done
  echo "==> 清洗完成：剔除 $removed 个「系统图形栈」库（改由目标机系统提供）"
  return 0
}

# 自检：清洗后若仍有残留 → 立即失败，不许把坏包流到交付。
verify_bundle_clean() {
  local libdir="$1" f base bad=0
  for f in "$libdir"/*; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    base="$(basename "$f")"
    if _bundle_policy_hit "$base"; then
      echo "  ❌ 残留: $base" >&2
      bad=$((bad + 1))
    fi
  done
  if [ "$bad" -gt 0 ]; then
    echo "错误：bundle 仍含 $bad 个不应自带的系统库 —— 该产物会在目标机启动崩溃！" >&2
    echo "      （症状：双击无反应 / exit=134 / eglGetPlatformDisplayEXT 无 provider）" >&2
    exit 1
  fi
  echo "==> 自检通过：bundle 不含任何应交由系统提供的图形栈库"
}

# 🔴🔴🔴 自检**方向 B**：bundle 里**该有的**库一个都不能少。
#
#   【为什么必须有这一条】
#     方向 A（verify_bundle_clean）只查「不该自带的系统库有没有混进来」。
#     2026-10-24 真机事故恰好**通过了方向 A 却仍然坏掉**：
#       libXpresent.so.1 被当成 X11 系统库剔掉了 → 目标机（Bazzite，
#       纯 Wayland）没有这个库 → dlopen(libmpv) 失败 → Flutter 插件
#       静默不注册 → 界面 MissingPluginException → 应用能打开但
#       **点播/直播/回放全部不可播**。
#
#   【判据：以「bundle ∪ 系统保证集」为唯一解析域】
#     ⚠️ 绝不能拿「构建机 ldd 是否 not found」当判据 ——
#        构建机是 Debian，libXpresent/libXv 等一应俱全，ldd 全绿；
#        目标机 Bazzite 根本没有 → 这正是当时漏判的原因。
#     正确做法：对 bundle 内每个 ELF 读它的 NEEDED 列表，
#     逐个判断该 soname 是否
#        ① bundle 里存在（同名前缀的真实文件），或
#        ② 属于「系统保证集」（剔除前缀 = 系统统一提供的库）。
#     两者都不满足 → 判定缺失 → **立即失败**，不许把坏包流到交付。
#
#   【用法】verify_bundle_required_libs <lib目录> <主程序路径>
verify_bundle_required_libs() {
  local libdir="$1" mainbin="$2"
  local missing=0 checked=0
  local -a targets=()
  local f so dep

  for f in "$libdir"/*.so*; do
    [ -f "$f" ] && targets+=("$f")
  done
  [ -n "$mainbin" ] && [ -f "$mainbin" ] && targets+=("$mainbin")
  [ "${#targets[@]}" -eq 0 ] && return 0

  for so in "${targets[@]}"; do
    while IFS= read -r dep; do
      [ -z "$dep" ] && continue
      checked=$((checked + 1))
      # ① bundle 内是否已有同名（或同前缀的版本文件）库
      if [ -e "$libdir/$dep" ]; then continue; fi
      local hit=0 g
      for g in "$libdir/$dep".*; do
        [ -e "$g" ] && { hit=1; break; }
      done
      [ "$hit" -eq 1 ] && continue
      # ② 是否属于系统保证集（命中剔除前缀 → 由目标机系统提供）
      if _bundle_policy_hit "$dep"; then continue; fi
      echo "  ❌ 缺失: $dep  ← $(basename "$so") 的 NEEDED" >&2
      missing=$((missing + 1))
    done < <(readelf -d "$so" 2>/dev/null \
             | sed -n 's/.*(NEEDED).*\[\([^]]*\)\].*/\1/p')
  done

  if [ "$missing" -gt 0 ]; then
    echo "错误：bundle 缺少 $missing 个必需依赖（共检查 $checked 条 NEEDED）" >&2
    echo "      症状：mpv 壳 dlopen 失败 → Flutter 插件静默不注册 →" >&2
    echo "            应用能打开但点播/直播/回放全部不可播" >&2
    echo "            （MissingPluginException: hain_tv/mpv_desktop）" >&2
    echo "      处理：这些库必须随包分发，或加入 bundle_lib_policy.txt" >&2
    echo "            的「系统保证集」（剔除前缀）——二选一，别放着不管。" >&2
    exit 1
  fi
  echo "==> 自检方向B通过：$checked 条 NEEDED 全部可解析（bundle ∪ 系统保证集）"
}

# 🔴 对**交付物本身**解包自检：appimage-builder 或任何后置步骤都可能把系统库
#    又塞回去，只有解包真正产出的 .AppImage 才能证明它干净。
verify_appimage_payload() {
  local img="$1" tmp
  [ -x "$img" ] || chmod +x "$img"
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/heinplay-appimage-check.XXXXXX")"
  if ! ( cd "$tmp" && "$img" --appimage-extract >/dev/null 2>&1 ); then
    echo "警告：AppImage 解包自检无法执行（跳过，不阻断构建）" >&2
    rm -rf "$tmp"
    return 0
  fi
  if [ -d "$tmp/squashfs-root/lib" ]; then
    echo "==> 交付物解包自检: $img"
    verify_bundle_clean "$tmp/squashfs-root/lib"
    # 🔴 方向 B 同样必须对**交付物**做：解包后的真实内容才是最终结果。
    #    主程序名固定为 hain_tv（desktop 条目 Exec=hain_tv），不能依赖
    #    未定义的变量 —— `set -u` 下会直接报错并**跳过主程序的检查**。
    verify_bundle_required_libs "$tmp/squashfs-root/lib" \
      "$tmp/squashfs-root/hain_tv"
  fi
  rm -rf "$tmp"
  return 0
}

load_bundle_policy
purge_bundle_system_libs "$BUNDLE/lib"
verify_bundle_clean "$BUNDLE/lib"
# 🔴 方向 B：清洗后立刻查「该有的库齐不齐」——纯 Wayland 目标机缺
#    libXpresent 之类的场景，方向 A 是查不出来的。
verify_bundle_required_libs "$BUNDLE/lib" "$BUNDLE/hain_tv"

# 将图标按 freedesktop 标准布局放入 bundle，供 appimage-builder 的 IconBundler 按名检索。
# 必须放在 $BUNDLE 已生成之后；图标名需与 AppImageBuilder.yml 的 app_info.icon 一致（mo_ico）。
if [ -f "$ICON_STAGED" ]; then
  mkdir -p "$BUNDLE/usr/share/icons/hicolor/256x256/apps"
  cp -f "$ICON_STAGED" "$BUNDLE/usr/share/icons/hicolor/256x256/apps/mo_ico.png"
  echo "==> 已放入 AppImage 图标: $BUNDLE/usr/share/icons/hicolor/256x256/apps/mo_ico.png"
fi

# === appimage-builder 定位（自包含解析，不依赖外部记忆或手工 export PATH）===
#
# 背景（2026-10-23 实测踩坑）：appimage-builder 实际装在团队独立 venv
#   /opt/team/tool-deps/aib-venv/bin/appimage-builder
# 该目录不在任何默认 PATH 里。若脚本只探测 ~/.local/bin 与 /usr/local/bin，
# 每次构建都会以"未检测到 appimage-builder"中断，只能靠人临时补 PATH —— 这正是
# 反复出现的「appimage-builder 记忆漂移」根源：记忆是软约束，换会话/换人就丢。
# 因此改为：脚本自己按候选清单解析绝对路径 + 解释器，并把最终结果打印出来自证。
#
# 注意 Python 导入名是 appimagebuilder（无下划线），不是 appimage_builder。
# 用 `python -c "import appimagebuilder"` 校验，避免只看二进制存在却无法导入。
AIB_BIN=""
AIB_PYTHON=""
resolve_appimage_builder() {
  local TOOL_DEPS_DIR="${TOOL_DEPS:-/opt/team/tool-deps}"
  local CAND PY
  for CAND in \
    "$TOOL_DEPS_DIR/aib-venv/bin/appimage-builder" \
    "$HOME/.local/bin/appimage-builder" \
    "/usr/local/bin/appimage-builder" \
    "$(command -v appimage-builder 2>/dev/null || true)"; do
    [ -n "$CAND" ] && [ -x "$CAND" ] || continue
    AIB_BIN="$(readlink -f "$CAND")"
    PY="$(head -n1 "$AIB_BIN" 2>/dev/null | sed 's/^#!//')"
    if [ -z "$PY" ] || [ ! -x "$PY" ]; then
      PY="$(dirname "$AIB_BIN")/python"
    fi
    if [ -x "$PY" ] && "$PY" -c 'import appimagebuilder' >/dev/null 2>&1; then
      AIB_PYTHON="$PY"
      return 0
    fi
  done
  return 1
}

# 检测：你此前明确要求直接产出 AppImage，因此缺失就明确告知安装命令并退出；
# 绝不自动 pip 安装，也不偷偷降级为 tar.gz。
APP_IMAGE_OK=0
if resolve_appimage_builder; then
  echo "==> appimage-builder 已就绪"
  echo "    可执行: $AIB_BIN"
  echo "    解释器: $AIB_PYTHON"
  APP_IMAGE_OK=1
else
  echo "错误：未检测到可用的 appimage-builder，请安装后再运行（你此前要求直接产出 AppImage）：" >&2
  echo "  已尝试的位置：" >&2
  echo "    ${TOOL_DEPS:-/opt/team/tool-deps}/aib-venv/bin/appimage-builder  # 团队 venv（本机实际安装位置）" >&2
  echo "    $HOME/.local/bin/appimage-builder                                # pip --user 安装" >&2
  echo "    /usr/local/bin/appimage-builder                                  # 系统安装" >&2
  echo "  安装命令：" >&2
  echo "    pipx install appimage-builder        # 推荐" >&2
  echo "    或  pip3 install --break-system-packages appimage-builder" >&2
  echo "  注意：若装在自定义 venv，请把该 venv 的 bin 加入 PATH，或直接用绝对路径调用脚本。" >&2
  exit 1
fi

# 将产物统一收集到仓库根 dist 目录（与其它平台产物归在一处），便于 CI 上传 / 本地取用。
mkdir -p "$DIST_DIR"

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
  local ELF_PY
  [ -z "${AIB_PYTHON:-}" ] && return 0
  ELF_PY="$("$AIB_PYTHON" -c 'import appimagebuilder.utils.elf as m; print(m.__file__)' 2>/dev/null || true)"
  [ -z "$ELF_PY" ] && return 0
  if grep -q "_START_SYMBOL_PATCHED_" "$ELF_PY" 2>/dev/null; then
    return 0
  fi
  "$AIB_PYTHON" - "$ELF_PY" <<'PYEOF' || echo "警告：appimage-builder elf.py 自动修补失败，将尝试原样打包（若仍报 arch 错误请手动处理）。" >&2
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
  # AIB_BIN / AIB_PYTHON 已由 resolve_appimage_builder 解析并校验过（绝对路径 +
  # 可导入 appimagebuilder 模块），此处直接复用，不再二次推导。
  if [ ! -x "$AIB_PYTHON" ]; then
    echo "错误：解析出的 appimage-builder 解释器不可执行：$AIB_PYTHON" >&2
    exit 1
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
      # 🔴 交付文件名**带版本**：heinplay-<版本>-linux-x86_64.AppImage
      #    （沿用历来的构建命名方式，各版本产物可区分；
      #     配套的一键安装脚本 install_heinplay_linux.sh 正是从文件名里
      #     提取版本号 heinplay-<ver>-linux… 写进 desktop 条目的。）
      #    注意：**交付名带不带版本，与集成器装出来的名字无关** ——
      #    候选名来自 AppImage 内 desktop 条目的 Name=（=HeinPlay ⇒ heinplay.appimage）。
      DEST="$DIST_DIR/heinplay-${VERSION}-linux-x86_64.AppImage"
      cp -f "$f" "$DEST"
      echo "已生成: $DEST"
      # 🔴 对**交付物本身**做一次解包自检（不信任中间态）：
      #    appimage-builder 或任何后置步骤都可能把系统库又塞回去，
      #    只有解包真正产出的 AppImage 才能证明它是干净的。
      verify_appimage_payload "$DEST"
    done

    # === 🔴 2026-10-23 固化（用户实测三轮后定稿）：桌面集成器命名校验 ===
    #
    # Gear Lever 的真实命名逻辑（上游 src/providers/AppImageProvider.py, install_file()）：
    #   appimage_filename = desktop_entry.getName()          # ← desktop 条目的 Name=
    #   appimage_filename = f'{appimage_filename}.appimage' # → "heinplay.appimage"
    #   若目标目录 ~/.local/share/gearlever/ 已存在同名文件，为避免覆盖而加后缀：
    #       有版本号 → "heinplay.appimage_1_4_0.appimage"
    #       无版本号 → "heinplay.appimage_0.appimage"（i=0 兜底，纯属无意义退化）
    #   走内置更新(REPLACE)时保留旧 basename，不加任何后缀。
    #
    # ⇒ 铁律一：desktop 条目的 Name= 必须存在且等于 HeinPlay
    #    —— 它决定集成后的**基础名**，即 heinplay.appimage。
    #    （与交付文件名无关：交付名带版本，照样装成 heinplay.appimage。）
    # ⇒ 铁律二：X-AppImage-Version **必须保留**。
    #    实测证明：去掉它并不能消除后缀，只会把 _1_4_0 退化成 _0（用户实测
    #    得到 heinplay.appimage_0.appimage）；而且 Gear Lever 安装时会把该键写进
    #    系统 desktop 文件，其更新检测依赖它。缺字段 = 构建失败。
    #
    # 本校验内建于脚本：任何人改配方、换 appimage-builder 版本导致字段回退，
    # 构建当场失败并指出修法，不靠记忆、不靠事后发现。
    verify_appimage_desktop_entry() {
      local appimage="$1" tmp entry name appname ver
      tmp="$(mktemp -d)"
      if ! ( cd "$tmp" && "$appimage" --appimage-extract >/dev/null 2>&1 ); then
        echo "警告：无法解包校验 desktop 条目（AppImage 本身不受影响）。" >&2
        rm -rf "$tmp"; return 0
      fi
      entry="$(find "$tmp/squashfs-root" -maxdepth 1 -name '*.desktop' | head -1)"
      if [ -z "$entry" ]; then
        echo "错误：AppImage 根目录没有 desktop 条目，桌面集成器无法识别该应用。" >&2
        rm -rf "$tmp"; return 1
      fi
      name="$(grep -m1 '^Name=' "$entry" | cut -d= -f2- | tr -d '\r')"
      appname="$(grep -m1 '^X-AppImage-Name=' "$entry" | cut -d= -f2- | tr -d '\r')"
      ver="$(grep -m1 '^X-AppImage-Version=' "$entry" | cut -d= -f2- | tr -d '\r')"
      if [ -z "$name" ]; then
        echo "错误：desktop 条目缺少 Name= —— 集成器的候选文件名会退化。" >&2
        echo "  条目: $entry" >&2
        cat "$entry" >&2
        rm -rf "$tmp"; return 1
      fi
      if [ "${name,,}" != "heinplay" ]; then
        echo "错误：desktop 条目的 Name=$name —— 集成后的基础名会是 ${name,,}.appimage，" >&2
        echo "       而要求集成后叫 heinplay.appimage。" >&2
        echo "  条目: $entry" >&2
        cat "$entry" >&2
        rm -rf "$tmp"; return 1
      fi
      if [ -z "$appname" ]; then
        echo "错误：desktop 条目缺少 X-AppImage-Name —— 集成器无法识别应用标识。" >&2
        echo "  条目: $entry" >&2
        cat "$entry" >&2
        rm -rf "$tmp"; return 1
      fi
      if [ -z "$ver" ]; then
        echo "错误：desktop 条目缺少 X-AppImage-Version —— 集成器在遇到同名文件时会退化成" >&2
        echo "       无意义后缀 _0（实测 heinplay.appimage_0.appimage），且更新检测会失效。" >&2
        echo "  修法：确认 scripts/run_appimage_builder.py 的第 4 个补丁仍在" >&2
        echo "       （_forced_appimage_version 强制写入版本）。" >&2
        echo "  条目: $entry" >&2
        cat "$entry" >&2
        rm -rf "$tmp"; return 1
      fi
      echo "==> desktop 条目校验通过: Name=$name / X-AppImage-Name=$appname / X-AppImage-Version=$ver"
      echo "    → 集成器装出来的名字：${name,,}.appimage（由 Name= 决定，与交付文件名无关）"
      rm -rf "$tmp"
      return 0
    }

    if ! verify_appimage_desktop_entry "$DEST"; then
      echo "错误：AppImage 的 desktop 条目不符合桌面集成器命名规范，构建中止。" >&2
      rm -rf "$BUILD_ROOT"
      exit 1
    fi

    # === 同时产出 tar.xz 便捷包（脚本自动产出，不再靠人工手动补）===
    # 历史问题：脚本只产 AppImage，tar.xz 一直是人工解包后手动打的，
    # 于是「脚本产物」与「交付产物」可能不同步 —— 曾把含旧代码的 tar.xz 交付出去。
    # 现在脚本自动解包 AppImage 并打成 tar.xz，结构保持一致（squashfs-root/ 顶层，252 条目）。
    # 注意：必须用 AppImage 自带的 --appimage-extract；unsquashfs 直接解 AppImage
    # 会报 "Can't find a valid SQUASHFS superblock"。
    #
    # ⚠️ 使用提示（固化，别再当成 bug）：解包出来的 squashfs-root/hain_tv **不能直接执行**——
    #    AppImage 的 AppRun2 把 ELF 解释器改写成相对路径 lib64/ld-linux-x86-64.so.2，
    #    内核按 CWD 解析找不到，于是报「无法执行：找不到需要的文件」。
    #    正确用法：cd squashfs-root && ./AppRun（AppRun 会 chdir 并配好库路径）。
    TARBALL="$DIST_DIR/heinplay-${VERSION}-linux-x64.tar.xz"
    EXTRACT_DIR="$BUILD_ROOT/.aib-extract"
    rm -rf "$EXTRACT_DIR"; mkdir -p "$EXTRACT_DIR"
    if ( cd "$EXTRACT_DIR" && "$DEST" --appimage-extract ) >/dev/null 2>&1 \
       && [ -d "$EXTRACT_DIR/squashfs-root" ]; then
      tar -cJf "$TARBALL" -C "$EXTRACT_DIR" squashfs-root
      echo "已生成: $TARBALL"
    else
      echo "警告：AppImage 解包失败，未生成 tar.xz（AppImage 本体不受影响）。" >&2
      rm -f "$TARBALL"
    fi
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
  TARBALL="$DIST_DIR/heinplay-${VERSION}-linux-x86_64.tar.gz"
  tar -czf "$TARBALL" -C "$BUNDLE" .
  echo "已生成: $TARBALL"
fi

rm -rf "$BUILD_ROOT"
echo "==> Linux 版构建完成"
