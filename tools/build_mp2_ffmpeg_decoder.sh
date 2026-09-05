#!/usr/bin/env bash
# =============================================================================
# 构建带 MPEG-1 Layer II (mp2) 音频解码的 media3-ffmpeg 解码 AAR
# -----------------------------------------------------------------------------
# 海因影视 HeinPlay —— 修复 ExoPlayer 播放国内 IPTV 组播源（音频为 mp2）无声问题。
#
# 根因：Android MediaCodec 不能解 MPEG-1 Layer II (mp2)（IPTV 组播音频常用），
#   工程 fork 的 video_player_android 需要带 FFmpeg 软解的 decoder_ffmpeg AAR
#   才能让 ExoPlayer 回退软解出声音。
#
# 关键认知（勿再误判）：mp2 无需单独解码器。media3 的 FfmpegLibrary 把
#   audio/mpeg-L1 / audio/mpeg-L2 / audio/mpeg 全部映射到 ffmpeg 的 "mp3" 解码器，
#   而 FFmpeg 的 mp3(mpegaudiodec) 本身就解 MPEG 音频 Layer 1/2/3。
#   因此 mediax 默认音频解码集里的 "mp3" 已完整覆盖 mp2 —— **不要**再设
#   EXTRA_FFMPEG_DECODERS="mp2 mp2float"（那是早期误判的产物；设了反而会顶掉
#   h264/hevc/vp9/av1/opus 等 MODERN_EXTRA 软解项）。
#
# 本脚本基于 vesaaa/mediax（Jellyfin decoder 的重建仓库）构建 decoder_ffmpeg AAR，
#   并把其 media 子模块对齐到与工程一致的 media3 1.9.2。
#
# ⚠️ 运行环境：Linux / WSL2（需要 git + make + gcc + yasm/nasm + JDK17+）。
#    media3 的 ffmpeg 构建脚本 build_ffmpeg.sh 用 linux-x86_64 工具链，且
#    本脚本最后用 Gradle 打包 AAR，两者都**只能在类 Unix 环境**（WSL/Linux）执行，
#    原生 Windows 命令提示符无法运行。
#
# 关键流程：
#   1) git clone mediax + init 子模块（ffmpeg 源码 + androidx/media）
#   2b) media 子模块 checkout 到 media3 1.9.2（对齐工程 media3 版本）
#   3) bash ./build.sh            —— 仅用 NDK 交叉编译出各 ABI 的 ffmpeg .so（含 mp3 → 覆盖 mp2）
#   4) ./gradlew :media3-ffmpeg-decoder:bundleReleaseAar
#                                  —— 用 Gradle 把 .so + JNI 包装成 release AAR
#      （build.sh 本身**不打包 AAR**，必须这一步）
#   产物：.../media3-ffmpeg-decoder/build/outputs/aar/decoder_ffmpeg-release.aar
#
# 用法（在 WSL 内，从仓库根 E:/code/HeinPlay 跑；Windows 盘符映射为 /mnt/<盘>）：
#   export ANDROID_HOME=/mnt/d/AndroidSDK      # 含 ndk 的 Android SDK
#   export JAVA_HOME=/usr/lib/jvm/java-21-openjdk-amd64
#   export NDK_VER=27.0.12077973               # 改成你已装的 NDK 版本
#   bash tools/build_mp2_ffmpeg_decoder.sh
#
# 产物落到：hain_tv/deps/video_player_android/android/libs/decoder_ffmpeg-release.aar
#   （gradle 已引用该本地 AAR；与 Jellyfin Maven 依赖二选一，不可并存，否则类冲突。）
# =============================================================================
set -euo pipefail

ANDROID_HOME="${ANDROID_HOME:?请先设置 ANDROID_HOME 指向 Android SDK（WSL 中为 /mnt/d/AndroidSDK 之类）}"
NDK_VER="${NDK_VER:-27.0.12077973}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# 克隆/编译放在 WSL 家目录（Linux 原生 FS），避开 /mnt DrvFS 的符号链接/大小写坑；
# AAR 产物仍拷回 Windows 侧 $ROOT/.../libs。可用环境变量 MEDIAX_DIR 覆盖。
MEDIAX_DIR="${MEDIAX_DIR:-$HOME/mediax_build}"
APP_LIBS="$ROOT/hain_tv/deps/video_player_android/android/libs"

# ---- 前置命令检查 ----
need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "!! 缺少命令: $1（请在 WSL 内 apt install 安装，见说明）" >&2; exit 1; }; }
need_cmd git
need_cmd make
need_cmd gcc
command -v yasm >/dev/null 2>&1 || command -v nasm >/dev/null 2>&1 || { echo "!! 缺少 yasm 或 nasm（ffmpeg 编译需要）" >&2; exit 1; }
need_cmd java
: "${JAVA_HOME:?请先设置 JAVA_HOME（如 /usr/lib/jvm/java-21-openjdk-amd64）}"

echo "==> ANDROID_HOME=$ANDROID_HOME  NDK_VER=$NDK_VER  JAVA_HOME=$JAVA_HOME"

# 1) 准备 mediax 仓库（若 tools/mediax 已存在则复用）
if [ ! -d "$MEDIAX_DIR/.git" ]; then
  git clone --depth 1 https://github.com/vesaaa/mediax.git "$MEDIAX_DIR"
fi
cd "$MEDIAX_DIR"
git submodule update --init --recursive

# 2b) 对齐 media3 子模块到工程版本 1.9.2
#     AAR 内 media3 类/JNI 与 ExoPlayer 所在 media3 版本越接近越稳；mediax 父仓库
#     pin 的 media 可能更新，这里强制 checkout 到 1.9.2 确保与工程 (media3 1.9.2) 一致。
MEDIA_TAG="1.9.2"
echo "==> 对齐 media 子模块到 media3 $MEDIA_TAG ..."
cd "$MEDIAX_DIR/media"
if git rev-parse -q --verify "refs/tags/$MEDIA_TAG" >/dev/null 2>&1 || git ls-remote --exit-code --tags origin "$MEDIA_TAG" >/dev/null 2>&1; then
  git fetch --tags origin "$MEDIA_TAG" 2>/dev/null || git fetch --tags origin
  git checkout "$MEDIA_TAG" 2>/dev/null || git checkout "refs/tags/$MEDIA_TAG"
  echo "==> media 已 checkout: $(git describe --tags 2>/dev/null || git rev-parse --short HEAD)"
else
  echo "!! 未找到 media3 tag $MEDIA_TAG，将使用 mediax 默认 media commit。若运行时 FfmpegAudioRenderer 报错请手动对齐。" >&2
fi
cd "$MEDIAX_DIR"

# 2) mediax build.sh 写死 NDK 26.1.10909125；软链成你已装的版本
if [ ! -e "$ANDROID_HOME/ndk/26.1.10909125" ]; then
  if ln -sfn "$ANDROID_HOME/ndk/$NDK_VER" "$ANDROID_HOME/ndk/26.1.10909125" 2>/dev/null; then
    echo "==> 已软链 NDK $NDK_VER -> 26.1.10909125"
  else
    echo "!! 在 $ANDROID_HOME/ndk 创建符号链接失败（WSL 访问 Windows 盘符的 DrvFS 常无权限）。" >&2
    echo "   请改为在 Windows 管理员 CMD/PowerShell 先手动建立目录联接（路径按你的实际 SDK 调整）：" >&2
    echo "     mklink /D \"D:\\AndroidSDK\\ndk\\26.1.10909125\" \"D:\\AndroidSDK\\ndk\\$NDK_VER\"" >&2
    echo "   建好后重跑本脚本即可。" >&2
    exit 1
  fi
fi

# 3) 构建 ffmpeg .so —— 不设 EXTRA_FFMPEG_DECODERS，使用默认解码集（含 mp3 + h264/hevc/vp9/av1/opus）
#    mp2 由默认 mp3 解码器覆盖（见文件头注释），无需追加 mp2/mp2float。
export ANDROID_NDK_PATH="$ANDROID_HOME/ndk/26.1.10909125"
bash ./build.sh

# 4) 用 Gradle 打包 release AAR（build.sh 只编 .so，不打包 AAR）
chmod +x gradlew
# mediax 实际库模块为 :androidx-media-lib-decoder-ffmpeg，产物即 decoder_ffmpeg-release.aar。
# （早期 1.9.x 仓库顶层 :media3-ffmpeg-decoder 无 bundleReleaseAar task，直接用底层路径。）
if ! ./gradlew :androidx-media-lib-decoder-ffmpeg:bundleReleaseAar; then
  echo "!! 底层路径 :androidx-media-lib-decoder-ffmpeg 仍失败，尝试顶层 :media3-ffmpeg-decoder ..." >&2
  ./gradlew :media3-ffmpeg-decoder:bundleReleaseAar
fi

# 5) 拷贝产物到工程
#    注意：Gradle 产出的 AAR 文件名是模块全名 androidx-media-lib-decoder-ffmpeg-release.aar，
#    而 video_player_android 的 build.gradle.kts 引用的是 libs/decoder_ffmpeg-release.aar。
#    这里按通配找到产出 AAR 后，统一拷贝/重命名为消费方期望的名字，避免两者对不上。
mkdir -p "$APP_LIBS"
AAR=$(find "$MEDIAX_DIR" -path '*/build/outputs/aar/*.aar' \( -name 'decoder_ffmpeg*.aar' -o -name '*decoder*ffmpeg*.aar' \) | head -1)
if [ -z "$AAR" ]; then
  echo "!! 未找到 decoder ffmpeg AAR（build/outputs/aar 下），请检查上面的 Gradle 构建日志" >&2
  exit 1
fi
cp -f "$AAR" "$APP_LIBS/decoder_ffmpeg-release.aar"
echo "==> 已输出: $APP_LIBS/decoder_ffmpeg-release.aar  (源: $(basename "$AAR"))"
echo "==> AAR 内解码器自检（可解 mp2 依赖其中的 mp3 解码器）："
unzip -l "$APP_LIBS/decoder_ffmpeg-release.aar" 2>/dev/null | grep -E "\.so$" | awk '{print $4}'

# 若 Gradle 报缺 CMake（如 3.31.1），在 Windows 侧用 sdkmanager 安装：
#   sdkmanager "cmake;3.31.1"
