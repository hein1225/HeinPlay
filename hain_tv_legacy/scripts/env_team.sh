#!/usr/bin/env bash
# ==============================================================================
# tvLegacy 构建环境（沙箱 / Linux 侧）
# ==============================================================================
# 用途：为 hain_tv_legacy 提供一套**完全指向 /opt/team/tool-deps** 的构建环境。
#
# 为什么需要它：
#   工程内的 android/gradle.properties 是给 Windows 开发机用的，里面钉死了
#   `org.gradle.java.home=D:/heinplay-legacy/jdk-21.0.2` —— 这是 **刻意的**，
#   注释说明 Gradle 8.12 内置 Kotlin 脚本编译器解析不了 Android Studio 的
#   JBR（OpenJDK 25），必须配 JDK 21。但在 Linux/沙箱侧该 Windows 路径不存在，
#   于是报 "Java home supplied is invalid"。
#
# 处理原则（重要）：
#   ❌ 不改动 android/gradle.properties —— 那是用户的 Windows 配置，改了会破坏
#      用户本机构建。所有覆盖都只在本脚本的环境变量里做，用完即弃。
#   ✅ 用 GRADLE_OPTS="-Dorg.gradle.java.home=..." 覆盖。经实测该方式生效
#      （`./gradlew --version` 的 Daemon JVM 会显示 team 路径），
#      而 flutter 的 --android-project-arg 传不进去（gradle.properties 优先级更高）。
#
# 用法：
#   source scripts/env_team.sh
#   flutter build apk --release --target lib/main_tv.dart --target-platform android-arm64
# ==============================================================================

export TOOL_DEPS=/opt/team/tool-deps

# --- Flutter 3.32.8：最后一个原生支持 Android 5.0 (API 21) 的稳定版 ---
# 🔴 不得换成 3.47.5 / 3.35+：3.35 起引擎按 API 24 构建，引入
#    getifaddrs@LIBC_N，Android 5.0 的 libc 无此符号，一加载即崩。
export FLUTTER_SDK=$TOOL_DEPS/sdks/flutter-3.32.8

# --- JDK 21：Gradle 8.12 的要求（JDK 25 会让 Kotlin 脚本编译器解析失败）---
export JAVA_HOME=$TOOL_DEPS/jdk/jdk-21.0.12.1+1
export GRADLE_OPTS="-Dorg.gradle.java.home=$JAVA_HOME"

# --- Android SDK / NDK ---
export ANDROID_HOME=$TOOL_DEPS/android-sdk
export ANDROID_SDK_ROOT=$TOOL_DEPS/android-sdk

# --- 依赖缓存（全部在 team 目录，勿用默认 ~/.pub-cache）---
# 🔴 默认 ~/.pub-cache 在本沙箱是空的/损坏的，会报
#    'Could not find a file named "pubspec.yaml" in .../archive-4.3.0'。
export PUB_CACHE=$TOOL_DEPS/cache/pub-cache
export GRADLE_USER_HOME=$TOOL_DEPS/cache/gradle-home

# --- 国内镜像 ---
export PUB_HOSTED_URL=https://mirrors.cloud.tencent.com/dart-pub
export FLUTTER_STORAGE_BASE_URL=https://mirrors.cloud.tencent.com/flutter

export PATH=$JAVA_HOME/bin:$FLUTTER_SDK/bin:$PATH

echo "[env_team] FLUTTER_SDK=$FLUTTER_SDK"
echo "[env_team] JAVA_HOME=$JAVA_HOME"
echo "[env_team] PUB_CACHE=$PUB_CACHE"
echo "[env_team] ANDROID_HOME=$ANDROID_HOME"
