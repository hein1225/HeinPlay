# Project-level configuration.
cmake_minimum_required(VERSION 3.13)
# 🔴 LANGUAGES 必须含 C：桌面 mpv 壳（src/mpv_desktop/）是纯 C 源码。
#    仅 CXX 时 CMake 不生成 CMAKE_C_COMPILE_OBJECT，生成阶段报
#    「required internal CMake variable not set」。
project(runner LANGUAGES C CXX)

# The name of the executable created for the application. Change this to change
# the on-disk name of your application.
set(BINARY_NAME "hain_tv")
# The unique GTK application identifier for this application. See:
# https://wiki.gnome.org/HowDoI/ChooseApplicationID
set(APPLICATION_ID "com.heinplay.hain_tv")

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(SET CMP0063 NEW)

# Load bundled libraries from the lib/ directory relative to the binary.
set(CMAKE_INSTALL_RPATH "$ORIGIN/lib")

# Root filesystem for cross-building.
if(FLUTTER_TARGET_PLATFORM_SYSROOT)
  set(CMAKE_SYSROOT ${FLUTTER_TARGET_PLATFORM_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH ${CMAKE_SYSROOT})
  set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
  set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
  set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
endif()

# Define build configuration options.
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE "Debug" CACHE
    STRING "Flutter build mode" FORCE)
  set_property(CACHE CMAKE_BUILD_TYPE PROPERTY STRINGS
    "Debug" "Profile" "Release")
endif()

# Compilation settings that should be applied to most targets.
#
# Be cautious about adding new options here, as plugins use this function by
# default. In most cases, you should add new options to specific targets instead
# of modifying this function.
function(APPLY_STANDARD_SETTINGS TARGET)
  target_compile_features(${TARGET} PUBLIC cxx_std_14)
  target_compile_options(${TARGET} PRIVATE -Wall -Werror)
  target_compile_options(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:-O3>")
  target_compile_definitions(${TARGET} PRIVATE "$<$<NOT:$<CONFIG:Debug>>:NDEBUG>")
endfunction()

# Flutter library and tool build rules.
set(FLUTTER_MANAGED_DIR "${CMAKE_CURRENT_SOURCE_DIR}/flutter")
add_subdirectory(${FLUTTER_MANAGED_DIR})

# System-level dependencies.
find_package(PkgConfig REQUIRED)
pkg_check_modules(GTK REQUIRED IMPORTED_TARGET gtk+-3.0)

# 🔴 桌面 mpv 壳：官方 libmpv 内核 + 自写 C 壳（src/mpv_desktop/）。
#   产物 libheinplay_mpv_desktop.so 由下方安装规则放进 bundle 的 lib/，
#   runner 的 my_application.cc 再 dlopen 它并调注册函数。
include(${CMAKE_CURRENT_SOURCE_DIR}/../src/mpv_desktop/CMakeLists.txt)

# Application build; see runner/CMakeLists.txt.
add_subdirectory("runner")

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)

# Only the install-generated bundle's copy of the executable will launch
# correctly, since the resources must in the right relative locations. To avoid
# people trying to run the unbundled copy, put it in a subdirectory instead of
# the default top-level location.
set_target_properties(${BINARY_NAME}
  PROPERTIES
  RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/intermediates_do_not_run"
)


# Generated plugin build rules, which manage building the plugins and adding
# them to the application.
include(flutter/generated_plugins.cmake)


# === Installation ===
# By default, "installing" just makes a relocatable bundle in the build
# directory.
set(BUILD_BUNDLE_DIR "${PROJECT_BINARY_DIR}/bundle")
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${BUILD_BUNDLE_DIR}" CACHE PATH "..." FORCE)
endif()

# Start with a clean build bundle directory every time.
install(CODE "
  file(REMOVE_RECURSE \"${BUILD_BUNDLE_DIR}/\")
  " COMPONENT Runtime)

set(INSTALL_BUNDLE_DATA_DIR "${CMAKE_INSTALL_PREFIX}/data")
set(INSTALL_BUNDLE_LIB_DIR "${CMAKE_INSTALL_PREFIX}/lib")

install(TARGETS ${BINARY_NAME} RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# 🔴 桌面 mpv 壳 + 官方内核，一并装进 bundle 的 lib/。
#   壳在 runner 里被 dlopen，内核 libmpv.so.2 被壳依赖，两者必须同在
#   rpath 可达目录（可执行文件已设 $ORIGIN/lib）。
install(FILES "$<TARGET_FILE:heinplay_mpv_desktop>"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 🔴 把壳转成 DT_RPATH（默认 CMake 写 DT_RUNPATH，不传递给依赖）。
#    壳由 runner dlopen，RUNPATH 导致 libmpv→libavcodec 解析不到。
#    用独立 .cmake 脚本（install(CODE) 里 "$ORIGIN" 会被 CMake 提前展开，
#    极易出语法错误）。
install(SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../src/mpv_desktop/hein_shell_rpath.cmake")


install(FILES "${FLUTTER_ICU_DATA_FILE}" DESTINATION "${INSTALL_BUNDLE_DATA_DIR}"
  COMPONENT Runtime)

install(FILES "${FLUTTER_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

foreach(bundled_library ${PLUGIN_BUNDLED_LIBRARIES})
  install(FILES "${bundled_library}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endforeach(bundled_library)

# 🔴 桌面 mpv 壳 + 官方内核，一并装进 bundle 的 lib/。
#   壳在 runner 里被 dlopen，内核 libmpv.so.2 被壳依赖，两者必须同在
#   rpath 可达目录（可执行文件已设 $ORIGIN/lib）。
install(FILES "$<TARGET_FILE:heinplay_mpv_desktop>"
  DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
  COMPONENT Runtime)

# 官方 libmpv 内核：优先用工程 third_party 里随包分发的那份，
# 缺失时回落到系统 /usr/local（开发机自编译安装）。
# 🔴 必须用 set(... CACHE INTERNAL)：install(SCRIPT) 里的独立 .cmake
#    运行在全新的变量作用域，普通 set() 变量读不到，只有 cache 变量可继承。
set(HEIN_LIBMPV_BUNDLED
    "${CMAKE_CURRENT_SOURCE_DIR}/../third_party/mpv-linux/libmpv.so.2"
    CACHE INTERNAL "随包分发的官方 libmpv.so.2 路径")
if(EXISTS "${HEIN_LIBMPV_BUNDLED}")
  install(FILES "${HEIN_LIBMPV_BUNDLED}"
    DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
  # 开发版符号链接（.so 也装一份，便于 ldd 诊断）
  get_filename_component(HEIN_LIBMPV_SO_DIR "${HEIN_LIBMPV_BUNDLED}" DIRECTORY)
  if(EXISTS "${HEIN_LIBMPV_SO_DIR}/libmpv.so")
    install(FILES "${HEIN_LIBMPV_SO_DIR}/libmpv.so"
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      COMPONENT Runtime)
  endif()
else()
  # 未随包分发时，找系统里的 libmpv.so.2 一并装入，保证用户机器无需自装 mpv。
  find_library(HEIN_LIBMPV_SYSTEM NAMES mpv libmpv
    PATHS /usr/local/lib/x86_64-linux-gnu /usr/local/lib /usr/lib/x86_64-linux-gnu
    NO_DEFAULT_PATH)
  if(HEIN_LIBMPV_SYSTEM)
    install(FILES "${HEIN_LIBMPV_SYSTEM}"
      DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
      COMPONENT Runtime)
  else()
    message(WARNING "未找到 libmpv.so.2，桌面 mpv 后端将无法运行。"
                    "请放置到 third_party/mpv-linux/ 或安装系统 mpv。")
  endif()
endif()

# ---- libmpv 传递依赖全量随附 ----
#
# 官方 libmpv 依赖约 230 个库（ffmpeg / libplacebo / blas / x11 / drm ...）。
# 用户机器未必装有 mpv，故在**安装阶段**用 ldd 实时收集并拷入 bundle/lib，
# 保证「解压即用」。$ORIGIN RUNPATH 已由 src/mpv_desktop/CMakeLists.txt 设好。
#
# ---- libmpv 传递依赖全量随附 ----
#
# 官方 libmpv 依赖约 230 个库（ffmpeg / libplacebo / blas / x11 / drm ...）。
# 用户机器未必装有 mpv，故在**安装阶段**用 ldd 实时收集并拷入 bundle/lib，
# 保证「解压即用」。$ORIGIN RUNPATH 已由 src/mpv_desktop/CMakeLists.txt 设好。
#
# 🔴 用 install(SCRIPT) 调独立 .cmake 文件，不用 install(CODE)：
#    后者嵌 foreach/if/regex 时引号要转义两层，极易出语法错误。
# 🔴 依赖的 libmpv 路径变量已设为 CACHE INTERNAL，
#    install(SCRIPT) 的独立作用域才能读到。
install(SCRIPT "${CMAKE_CURRENT_SOURCE_DIR}/../src/mpv_desktop/hein_mpv_install_deps.cmake")

# Copy the native assets provided by the build.dart from all packages.
set(NATIVE_ASSETS_DIR "${PROJECT_BUILD_DIR}native_assets/linux/")
install(DIRECTORY "${NATIVE_ASSETS_DIR}"
   DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
   COMPONENT Runtime)

# Fully re-copy the assets directory on each build to avoid having stale files
# from a previous install.
set(FLUTTER_ASSET_DIR_NAME "flutter_assets")
install(CODE "
  file(REMOVE_RECURSE \"${INSTALL_BUNDLE_DATA_DIR}/${FLUTTER_ASSET_DIR_NAME}\")
  " COMPONENT Runtime)
install(DIRECTORY "${PROJECT_BUILD_DIR}/${FLUTTER_ASSET_DIR_NAME}"
  DESTINATION "${INSTALL_BUNDLE_DATA_DIR}" COMPONENT Runtime)

# Install the AOT library on non-Debug builds only.
if(NOT CMAKE_BUILD_TYPE MATCHES "Debug")
  install(FILES "${AOT_LIBRARY}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}"
    COMPONENT Runtime)
endif()
