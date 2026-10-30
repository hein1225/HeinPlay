cmake_minimum_required(VERSION 3.22.1)
project(heinplay_mpv_jni CXX)

# ═══════════════════════════════════════════════════════════════════════════
# tvLegacy 自写 mpv JNI 壳（libheinplay_mpv_jni.so）
#
# 链接目标 jniLibs/<abi>/libmpv.so —— 该 libmpv 由本工程 `.mpv-android/` 交叉
# 编译（API 21 + OpenGL 路线，不启用 Vulkan，覆盖 Android 5.0 老设备）。
# ═══════════════════════════════════════════════════════════════════════════

# libmpv 头文件：优先用 -DMPV_INCLUDE_DIR 传入（gradle 里指向 .mpv-android/src/mpv）；
# 未传入时回退到仓库内的 mpv 源码树（cpp → main → src → app → android →
# hain_tv_legacy → 仓库根，共 6 级）。
if(NOT DEFINED MPV_INCLUDE_DIR)
  set(MPV_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../../../../../third_party")
endif()
message(STATUS "MPV_INCLUDE_DIR = ${MPV_INCLUDE_DIR}")
# 🔴 防漂移硬断言（2026-10-30 加固）：
#    mpv 内核唯一权威来源 = 独立仓 HeinPlayMPV（固定 tag mpv-v1.4.1），
#    契约见 docs/mpv-dependency-contract.md。
#    .mpv-build 是**鸿蒙**交叉编译树（mpv master），与 Android 的 0.41.0 不同源，禁止使用。
if(MPV_INCLUDE_DIR MATCHES "/\\.mpv-build/")
  message(FATAL_ERROR
    "mpv 头文件来源非法（指向 .mpv-build 鸿蒙源码树，与 Android 0.41.0 不同源）: ${MPV_INCLUDE_DIR}\n"
    "请改用 HeinPlayMPV（tag mpv-v1.4.1）的资产；契约见 docs/mpv-dependency-contract.md")
endif()
if(NOT EXISTS "${MPV_INCLUDE_DIR}/include/mpv/client.h")
  message(FATAL_ERROR
    "找不到 mpv 头文件: ${MPV_INCLUDE_DIR}/include/mpv/client.h\n"
    "本地请先构建 .mpv-android（mpv 0.41.0），或从 HeinPlayMPV Release 资产解包到 third_party/；"
    "契约见 docs/mpv-dependency-contract.md")
endif()

add_library(heinplay_mpv_jni SHARED heinplay_mpv_jni.cpp)

target_include_directories(heinplay_mpv_jni PRIVATE
  ${MPV_INCLUDE_DIR}/include
)

# jniLibs 目录下的预编译库（ANDROID_ABI 由 AGP 注入：armeabi-v7a / arm64-v8a）。
set(JNI_LIBS_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")
set(MPV_LIB_PATH "${JNI_LIBS_DIR}/libmpv.so")
# av_jni_set_java_vm 在 libavcodec.so 里（libmpv.so 本身不导出该符号）。
set(FFMPEG_LIB_PATH "${JNI_LIBS_DIR}/libavcodec.so")

if(NOT EXISTS "${MPV_LIB_PATH}")
  message(FATAL_ERROR "libmpv.so 未找到: ${MPV_LIB_PATH}（请先跑 .mpv-android/build_android_mpv.sh）")
endif()
if(NOT EXISTS "${FFMPEG_LIB_PATH}")
  message(FATAL_ERROR "libavcodec.so 未找到: ${FFMPEG_LIB_PATH}")
endif()

# 链接期解析 libmpv/ffmpeg 符号：指向打包进 apk 的同款 .so。
# 运行期由 MpvLoader 先 System.loadLibrary("mpv") 再加载 heinplay_mpv_jni，
# 同一进程内符号共享（与官方 mpv-android 的 jniLibs 范式一致）。
target_link_libraries(heinplay_mpv_jni
  log
  android
  dl
  ${MPV_LIB_PATH}
  ${FFMPEG_LIB_PATH}
)
