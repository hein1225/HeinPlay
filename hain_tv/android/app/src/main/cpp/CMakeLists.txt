cmake_minimum_required(VERSION 3.22.1)
project(heinplay_mpv_jni)

# libmpv 头文件：必须与 jniLibs 里的 libmpv.so 同源。
# 🔴 曾指向 .mpv-build/src/mpv（鸿蒙源码树），与 Android 版二进制不同源、版本可能漂移。
# 正常路径由 build.gradle.kts 的 -DMPV_INCLUDE_DIR 显式传入，此处仅为独立构建时的回退。
# 回退路径：CI / 干净环境没有本机 mpv-android 源码树，
# 改用 HeinPlayMPV 发布的头文件（third_party/include/mpv/*.h，由 CI 从 Release 资产解出）。
if(NOT DEFINED MPV_INCLUDE_DIR)
  set(MPV_INCLUDE_DIR "${CMAKE_SOURCE_DIR}/../../../../../../third_party" CACHE PATH "mpv include dir")
endif()

add_library(heinplay_mpv_jni SHARED heinplay_mpv_jni.cpp)

target_include_directories(heinplay_mpv_jni PRIVATE
  ${MPV_INCLUDE_DIR}/include
)

# 链接期解析 libmpv 符号：指向打包进 apk 的同款 libmpv.so（jniLibs/<abi>）。
# 运行期由 System.loadLibrary("mpv") 在 heinplay_mpv_jni 之前加载，符号共享。
# ANDROID_ABI 由 Android Gradle Plugin 注入（arm64-v8a 等）。
set(JNI_LIBS_DIR "${CMAKE_SOURCE_DIR}/../jniLibs/${ANDROID_ABI}")
set(MPV_LIB_PATH "${JNI_LIBS_DIR}/libmpv.so")
# av_jni_set_java_vm 在 libavcodec.so 里（libmpv.so 本身不导出该符号）。
# JNI_OnLoad 需要它把 JavaVM 交给 ffmpeg，否则 mpv 的 android gpu-context
# 取不到 JNIEnv → vo_android_init 报 "Could not attach java VM." → 黑屏。
# （与 hain_tv_legacy 的 CMakeLists 一致）
set(FFMPEG_LIB_PATH "${JNI_LIBS_DIR}/libavcodec.so")

if(NOT EXISTS ${MPV_LIB_PATH})
  message(WARNING "libmpv.so 未找到: ${MPV_LIB_PATH}，回退到 -lmpv 搜索")
  set(MPV_LIB_PATH mpv)
endif()
if(NOT EXISTS "${FFMPEG_LIB_PATH}")
  message(WARNING "libavcodec.so 未找到: ${FFMPEG_LIB_PATH}，av_jni_set_java_vm 将无法解析")
  set(FFMPEG_LIB_PATH "")
endif()

target_link_libraries(heinplay_mpv_jni
  log
  android
  dl
  ${MPV_LIB_PATH}
  ${FFMPEG_LIB_PATH}
)
