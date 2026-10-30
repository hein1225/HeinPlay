#!/usr/bin/env bash
# =============================================================
# env_ohos_linux.sh — 容器内(Linux)构建鸿蒙 HAP 的环境准备
#
# 为什么需要它：
#   1) flutter 启动时必须回写 bin/cache/*.stamp、ohpm/hvigor 也要写 HOME 下的
#      缓存，因此需要一个**确定可写**的 HOME 与 pub 缓存目录。
#   2) flutter 工具链硬编码查找 <工程>/ohos，本工程实体已叫 ohos/，无需 junction。
#
# 🔴 2026-10-22 统一目录：**所有工具与依赖一律放 `/opt/team/tool-deps`**，
#   工程内不再保留任何缓存副本（此前 `.deps-staging/home` 曾占 4.6GB，其中
#   pub-cache 2.1GB 与 team 目录的那份完全重复）。现在：
#     · HOME      → $TEAM_TOOLS/cache/ohos-home（ohpm / hvigor / node 的缓存）
#     · PUB_CACHE → $TEAM_TOOLS/cache/pub-cache（三工程共用同一份）
#   历史上「/opt/team 只读」的结论只在 `workspace-write` 沙箱下成立，
#   `danger-full-access` 下该目录可写（2026-10-22 实测），故不再需要工程内镜像。
#
# 用法:  source scripts/env_ohos_linux.sh
# =============================================================

# ---- 团队工具根目录（唯一存放位置）----
export TEAM_TOOLS=/opt/team/tool-deps
export TEAM_OHOS=$TEAM_TOOLS/ohos
export HEINPLAY_WS=/workspace/code/HeinPlay

# ---- 鸿蒙工具链 ----
export FLUTTER_OHOS_HOME=$TEAM_OHOS/flutter_flutter-oh-3.41.10
export OHOS_CLT=$TEAM_OHOS/command-line-tools

# ---- HOME / 各类缓存统一到 team 目录 ----
# ohpm / hvigor / node 都要写 HOME；统一指向 team 目录，避免工程内堆积副本。
export HOME=$TEAM_TOOLS/cache/ohos-home
export OHPM_HOME=$HOME/.ohpm
export HVIGOR_HOME=$HOME/.hvigor
# pub 缓存三工程共用 team 目录里的那一份（勿再指回工程内）。
export PUB_CACHE=$TEAM_TOOLS/cache/pub-cache

# ---- SDK 路径（指向镜像后的 CLT）----
export DEVECO_SDK_HOME=$OHOS_CLT/sdk
export HOS_SDK_HOME=$TEAM_OHOS
export OHOS_SDK_HOME=$TEAM_OHOS/ohos-sdk-6.1.0
export OHOS_SDK_26_HOME=$TEAM_OHOS/ohos-sdk-26.0.0

# ---- JDK / node ----
export JAVA_HOME=/opt/team/tool-deps/jdk/jdk-17.0.20.1+1
export DEVECO_NODE_HOME=$OHOS_CLT/tool/node

# ---- PATH：flutter + ohpm + hvigor + node ----
export PATH="$JAVA_HOME/bin:$FLUTTER_OHOS_HOME/bin:$OHOS_CLT/bin:$DEVECO_NODE_HOME/bin:$PATH"

# ---- 国内镜像 ----
export PUB_HOSTED_URL=https://pub.flutter-io.cn
export FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn

# ---- hvigor 插件模块解析（Linux 下的必要补丁）----
# hvigorw 在 Windows 上靠 junction 把 @ohos/hvigor(-ohos-plugin) 链进
# <HOME>/.hvigor/project_caches/<hash>/workspace/node_modules，随后**依赖 Node 的
# 默认向上查找**解析工程 hvigorfile.ts 里的 `@ohos/hvigor-ohos-plugin`。
# 该查找链从工程目录出发，永远走不到 workspace 那层，于是 Linux 下报
# 00302039 `Cannot find module '@ohos/hvigor-ohos-plugin'`。
# 解法：建一个固定目录放这两个包的软链，并用 NODE_PATH 挂上（NODE_PATH 是
# require 的最终兜底，对「工程侧 require 插件」和「插件侧 require hvigor」都生效）。
export HVIGOR_NODE_PATH=$TEAM_TOOLS/cache/hvigor-node-modules
mkdir -p "$HVIGOR_NODE_PATH/@ohos" 2>/dev/null || true
for p in hvigor hvigor-ohos-plugin; do
  ln -sfn "$OHOS_CLT/hvigor/$p" "$HVIGOR_NODE_PATH/@ohos/$p"
done
export NODE_PATH="$HVIGOR_NODE_PATH${NODE_PATH:+:$NODE_PATH}"

# ---- fvp 插件 release 构建补丁（幂等）----
# fvp 的 ohos/build-profile.json5 在 buildOptionSet[release] 里引用了
# ./obfuscation-rules.txt，但插件包内并未附带该文件，而 hvigor **即使
# enable:false 也会校验文件存在性**，导致 `flutter build hap --release` 直接失败：
#   Error Message: The obfuscation rule file './obfuscation-rules.txt' cannot be found
# 这里在每次 source 时补上（内容 -disable-obfuscation，避免 libmdk 通过反射
# 按名字查找的符号被改名）。之所以放在 env 脚本而非一次性手工修复：该文件位于
# pub-cache 内，`flutter pub get` / 清缓存后会丢失，脚本化才能保证 release 构建可复现。
for _fvp_bp in "$PUB_CACHE"/hosted/pub.flutter-io.cn/fvp-*/ohos; do
  [ -d "$_fvp_bp" ] || continue
  if [ ! -f "$_fvp_bp/obfuscation-rules.txt" ]; then
    printf '%s\n' \
      '# fvp 插件 release 构建所需（hvigor 即使 enable=false 也校验文件存在）。' \
      '# 保持不混淆，避免 libmdk 通过 JNI/反射按名字查找的符号被改名。' \
      '-disable-obfuscation' > "$_fvp_bp/obfuscation-rules.txt" 2>/dev/null || true
  fi
done
unset _fvp_bp

# ---- screen_brightness_ohos 的 @ohos/flutter_ohos 依赖补丁（幂等）----
# 2026-10-22：screen_brightness_ohos 2.1.4 的 oh-package.json5 里 dependencies 是
# 空 {}，且 ohos/ 下无 oh_modules，ArkTS 编译直接失败：
#   ERROR 10505001 Cannot find module '@ohos/flutter_ohos' or its corresponding
#   type declarations.
#   At File: .../screen_brightness_ohos-2.1.4/ohos/src/main/ets/.../BaseStreamHandler.ets:1:21
#   → hvigor ERROR: Failed :screen_brightness_ohos:default@HarCompileArkTS
# 该插件源码 import 了 @ohos/flutter_ohos 的 EventChannel，却没声明依赖。
# 解法：从工程侧 oh_modules 把 @ohos/flutter_ohos 软链进插件的 oh_modules/，
# 并在 oh-package.json5 声明 file: 依赖。同理 fvp 补丁，必须脚本化 ——
# pub-cache 内的改动会因 `flutter pub get` / 清缓存而丢失。
SB_PLUGIN="$PUB_CACHE/hosted/pub.flutter-io.cn/screen_brightness_ohos-2.1.4/ohos"
if [ -d "$SB_PLUGIN" ]; then
  # flutter_ohos 的 HAR 源：用工程 oh_modules 里 ohpm 已装好的那份。
  _fo_src=""
  for _d in "$HEINPLAY_WS"/hain_tv_ohos/ohos/oh_modules/.ohpm/@ohos+flutter_ohos@*/oh_modules/@ohos/flutter_ohos; do
    [ -f "$_d/index.ets" ] && { _fo_src="$_d"; break; }
  done
  if [ -n "$_fo_src" ]; then
    mkdir -p "$SB_PLUGIN/oh_modules/@ohos" 2>/dev/null || true
    ln -sfn "$_fo_src" "$SB_PLUGIN/oh_modules/@ohos/flutter_ohos" 2>/dev/null || true
    # 声明依赖（若尚未声明）
    if ! grep -q '@ohos/flutter_ohos' "$SB_PLUGIN/oh-package.json5" 2>/dev/null; then
      sed -i 's#"dependencies": {}#"dependencies": {\n    "@ohos/flutter_ohos": "file:./oh_modules/@ohos/flutter_ohos"\n  }#' \
        "$SB_PLUGIN/oh-package.json5" 2>/dev/null || true
    fi
  fi
fi
unset SB_PLUGIN _fo_src _d

mkdir -p "$HOME" "$OHPM_HOME" "$HVIGOR_HOME" 2>/dev/null || true