#!/usr/bin/env bash
# ==============================================================================
# 主工程 hain_tv 构建环境（沙箱 / Linux 侧）
# ==============================================================================
# 用途：为 hain_tv 提供一套**完全指向 /opt/team/tool-deps** 的构建环境。
#
# 与 hain_tv_legacy/scripts/env_team.sh 的差异（重要，勿照抄）：
#   1. Flutter 用 3.47.5（主工程基线），**不是** 3.32.8。
#      legacy 锁 3.32.8 是为覆盖 Android 5.0(API21)；主工程 minSdk=24，
#      且 3.47.5 才有 Windows/Linux 桌面与新版渲染管线。
#   2. JDK 21 同样是 Gradle 要求；主工程 android/gradle.properties **没有**
#      钉死 org.gradle.java.home，故无需 GRADLE_OPTS 覆盖，仅设 JAVA_HOME。
#
# 用法：
#   source scripts/env_team.sh
#   flutter build apk --release --target lib/main_tv.dart \
#     --flavor tv --target-platform android-arm,android-arm64
# ==============================================================================

export TOOL_DEPS=/opt/team/tool-deps

# --- Flutter 3.47.5：主工程基线（Android/TV/Windows/Linux）---
export FLUTTER_SDK=$TOOL_DEPS/sdks/flutter-3.47.5

# --- JDK 21 ---
export JAVA_HOME=$TOOL_DEPS/jdk/jdk-21.0.12.1+1

# --- Android SDK / NDK ---
export ANDROID_HOME=$TOOL_DEPS/android-sdk
export ANDROID_SDK_ROOT=$TOOL_DEPS/android-sdk

# --- 依赖缓存（全部在 team 目录，勿用默认 ~/.pub-cache）---
export PUB_CACHE=$TOOL_DEPS/cache/pub-cache
export GRADLE_USER_HOME=$TOOL_DEPS/cache/gradle-home

# --- 国内镜像 ---
export PUB_HOSTED_URL=https://mirrors.cloud.tencent.com/dart-pub
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter

export PATH=$JAVA_HOME/bin:$FLUTTER_SDK/bin:$PATH

# --- appimage-builder（Linux AppImage 打包）---
# 装在团队独立 venv，不在默认 PATH。注意 Python 导入名是 appimagebuilder（无下划线）。
# build_linux_appimage.sh 另有自包含探测（绝对路径逐候选 + import 校验），
# 此处加入 PATH 只是为了让交互 shell 里也能直接调用 appimage-builder。
export PATH=$TOOL_DEPS/aib-venv/bin:$PATH

# 绕过 dart/flutter 工具对 SDK 目录的 git 所有权检查（沙箱以 root 运行，
# SDK 属其他属主）。只在本 shell 生效，**不写全局 git 配置**。
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=safe.directory
export GIT_CONFIG_VALUE_0=$FLUTTER_SDK

echo "[env_team] FLUTTER_SDK=$FLUTTER_SDK"
echo "[env_team] JAVA_HOME=$JAVA_HOME"
echo "[env_team] PUB_CACHE=$PUB_CACHE"
echo "[env_team] ANDROID_HOME=$ANDROID_HOME"
