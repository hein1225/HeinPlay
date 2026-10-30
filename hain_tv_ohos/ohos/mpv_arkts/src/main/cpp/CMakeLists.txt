cmake_minimum_required(VERSION 3.5.0)
set(CMAKE_CXX_STANDARD 20)
project(mpv_wrapper)

cmake_minimum_required(VERSION 3.15)

# ------------------------------------------------------------------------------
# 🔴 HeinPlay 2026-10-07：回归「常规模式」——本地编译 mpv_wrapper。
#
# 背景（重要，勿再改回）：
#   2026-10-06 为了排查「`import libmpv from 'libmpv_wrapper.so'` 恒为 undefined」，
#   本文件被临时改为「实验模式」：绕过本地 CMake 编译，直接把 mpv_wrapper / aki
#   指向 libs/prebuilt-official/ 下的【官方预编译 so】。
#
#   该实验的结论其实是否定的：官方预编译 wrapper 的 NEEDED 里多一个 libuv.so，
#   而 HAP 打包时不会带上它（libuv 在 OHOS SDK sysroot 里是系统级库，但真机
#   加载环境解析不到），于是 dlopen 失败：
#       [HeinPlayMpv] 实验模式自检: module=undefined, NativePlayer=模块为 undefined
#       PlatformViewsChannel --> create failed TypeError: Cannot read property NativePlayer of undefined
#   → new Player() 抛异常 → PlatformView 创建失败 → mpv 从未被创建（自身 0 条日志）
#   → 2026-10-07 真机表现为「所有源 + 直播全部播放失败」。
#
#   而【本地编译的 wrapper】在 2026-10-07 20:48 的日志里被证实工作正常：
#       [HeinPlayMpv] 实验模式自检: module=object, NativePlayer=function
#       MpvPlayerView 构造 viewId=0 ×12，create failed ×0
#   故此处回归本地编译，彻底移除 prebuilt-official 分支。
#
# 同时移除了上游原版的 download_and_verify()：
#   上游会从 GitHub 下载 libmpv_aarch64.zip 并解压【覆盖 libs/arm64-v8a/】，
#   这会冲掉我们自行交叉编译的 libmpv.so（含 OHOS Vulkan 扩展补丁）。
#   本工程各平台单独编译 mpv，产物已由 .mpv-build 提供，绝不能下载覆盖。
#   若 libs/arm64-v8a/libmpv.so 缺失，应先在 .mpv-build 里重新编译，而不是联网下载。
# ------------------------------------------------------------------------------

set(LIBMPV_SRC "${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/")

if(NOT EXISTS "${LIBMPV_SRC}/libmpv.so")
    message(FATAL_ERROR
        "缺少 ${LIBMPV_SRC}/libmpv.so。\n"
        "请先在 .mpv-build 中交叉编译 libmpv.so 并部署到该目录，"
        "本工程禁止联网下载官方预编译包覆盖。")
endif()

add_subdirectory(third_party/aki)
include_directories(third_party/mpv/include third_party/simdjson)

add_library(mpv_wrapper SHARED
    napi_init.cpp
    src/log.cpp
    src/log.h
    src/event.cpp
    src/property.cpp
    src/main.cpp
    src/globals.h
    src/node.cpp
    src/node.h
    third_party/simdjson/simdjson.cpp)

set(LIBS
    libace_napi.z.so
    libhilog_ndk.z.so
    ${CMAKE_CURRENT_SOURCE_DIR}/../../../libs/arm64-v8a/libmpv.so)

target_link_libraries(mpv_wrapper PUBLIC ${LIBS} aki_jsbind)
