# 安装期脚本：把桌面 mpv 壳转成 DT_RPATH。
#
# 🔴 为什么必须 DT_RPATH 而不是 DT_RUNPATH：
#    CMake 默认写 DT_RUNPATH，而 **DT_RUNPATH 不传递给依赖**。
#    壳由 runner 用 dlopen 加载，壳自己的依赖链
#    （libheinplay_mpv_desktop.so → libmpv.so.2 → libavcodec.so.61）
#    在 dlopen 时解析不到，真机实测报：
#      "HeinPlayMpvDesktop: dlopen 失败: libavcodec.so.61: 无法打开共享目标文件"
#    进而 MethodChannel 全未注册，播放必失败
#    （MissingPluginException: No implementation found for method init）。
#    DT_RPATH 会传递给依赖，dlopen 场景必须用它。
#
# 由 linux/CMakeLists.txt 以 install(SCRIPT) 调用。

# 本脚本位于 <工程>/src/mpv_desktop/，工程根在其上两级。
get_filename_component(HEIN_PROJECT_ROOT "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
get_filename_component(HEIN_PROJECT_ROOT "${HEIN_PROJECT_ROOT}" DIRECTORY)
get_filename_component(HEIN_PROJECT_ROOT "${HEIN_PROJECT_ROOT}" DIRECTORY)

find_program(HEIN_PATCHELF_BIN patchelf)
if(NOT HEIN_PATCHELF_BIN)
  message(WARNING "桌面 mpv：未找到 patchelf，跳过壳 RPATH 转换"
                  "（dlopen 可能找不到 libmpv 的依赖）")
  return()
endif()

set(HEIN_SHELL_SO "${CMAKE_INSTALL_PREFIX}/lib/libheinplay_mpv_desktop.so")
if(NOT EXISTS "${HEIN_SHELL_SO}")
  message(WARNING "桌面 mpv：壳不存在 ${HEIN_SHELL_SO}，跳过")
  return()
endif()

# 先清掉 CMake 写的 RUNPATH，再强制写 RPATH=$ORIGIN
execute_process(
    COMMAND "${HEIN_PATCHELF_BIN}" --remove-rpath "${HEIN_SHELL_SO}"
    OUTPUT_QUIET ERROR_QUIET)
execute_process(
    COMMAND "${HEIN_PATCHELF_BIN}" --set-rpath "$ORIGIN" --force-rpath
            "${HEIN_SHELL_SO}"
    RESULT_VARIABLE HEIN_RPATH_RC
    OUTPUT_QUIET ERROR_QUIET)

if(HEIN_RPATH_RC EQUAL 0)
  message(STATUS "桌面 mpv：壳已转为 DT_RPATH=$ORIGIN")
else()
  message(WARNING "桌面 mpv：壳 RPATH 转换失败 rc=${HEIN_RPATH_RC}")
endif()
