# 桌面 mpv 壳构建规则（被 linux/CMakeLists.txt 与 windows/CMakeLists.txt include）。
#
# 产物：libheinplay_mpv_desktop.so / .dll
#   · 内核：官方 libmpv（Linux: libmpv.so，Windows: libmpv-2.dll），动态链接
#   · 壳  ：本目录下的 C 源码
#
# 说明：内核用 pkg-config 查找（Linux）。Windows 侧的头文件与 import 库
# 由 third_party/mpv-windows/ 提供（官方预编译包解出），见下方 if(WIN32) 分支。

# ---- 公共源 ----
# ⚠️ hein_mpv_core.c **不**列入源列表：它被各平台插件文件
#    （hein_mpv_linux_plugin.c / hein_mpv_windows_plugin.cpp）
#    以 #include 形式编入同一编译单元。若同时列入，链接期会报
#    multiple definition of 'hein_mpv_*'。
# ⚠️ 源文件按平台划分，**不要**在这里无条件加入 Linux 专属文件。
#   hein_gl_texture.c 依赖 <epoxy/egl.h> / <glib.h> / FlTextureGL，
#   三者在 Windows 工具链下都不存在（Flutter Windows 侧没有 GLib，也没有 EGL），
#   编译期直接报「找不到头文件」并中断整个配置阶段。
#   Windows 走 D3D11 路线，外部纹理由 hein_win_texture.cpp 实现，与本文件无关。
set(HEIN_MPV_DESKTOP_SRC "")

if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  list(APPEND HEIN_MPV_DESKTOP_SRC
      "${CMAKE_CURRENT_LIST_DIR}/hein_gl_texture.c"
      # 🔴 2026-10-26：GL 后端抽象（EGL/GLX 双后端的运行时函数表）。
      "${CMAKE_CURRENT_LIST_DIR}/hein_gl_api.c"
      # 🔴 2026-10-26：GLX 上下文管理（X11 会话 / gamescope 游戏模式）。
      #   单独成文件是因为 <epoxy/glx.h> 的 glXMakeCurrent 原型有错，
      #   而 <GL/glx.h> 与 <epoxy/gl.h> 头文件互斥（KHRONOS 等重复定义）。
      "${CMAKE_CURRENT_LIST_DIR}/hein_glx.c"
      # 🔴 2026-10-27：SW 软件渲染纹理（FlPixelBufferTexture）。
      #   gamescope 未开 --expose-wayland ⇒ GTK 必须留在 X11；X11 下
      #   EGL/GLX 互斥 ⇒ 不能共享 GL 上下文。改用 mpv SW 渲染 + CPU 像素
      #   上传，全程零 GL 上下文。仅 Linux（依赖 FlPixelBufferTexture）。
      "${CMAKE_CURRENT_LIST_DIR}/hein_sw_texture.c"
      "${CMAKE_CURRENT_LIST_DIR}/hein_mpv_linux_plugin.c"
  )
endif()

if(WIN32)
  list(APPEND HEIN_MPV_DESKTOP_SRC
      "${CMAKE_CURRENT_LIST_DIR}/hein_mpv_windows_plugin.cpp"
      "${CMAKE_CURRENT_LIST_DIR}/hein_win_texture.cpp"
  )
endif()

# ---- Linux：官方 libmpv 经 pkg-config ----
if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
  find_package(PkgConfig REQUIRED)
  # 官方源码编译安装到 /usr/local，需要显式把它加进搜索路径。
  set(ENV{PKG_CONFIG_PATH}
      "/usr/local/lib/pkgconfig:/usr/local/lib/x86_64-linux-gnu/pkgconfig:/usr/local/share/pkgconfig:$ENV{PKG_CONFIG_PATH}")
  pkg_check_modules(MPV REQUIRED IMPORTED_TARGET mpv)
  pkg_check_modules(EPOXY REQUIRED IMPORTED_TARGET epoxy)
  pkg_check_modules(GTK3 REQUIRED IMPORTED_TARGET gtk+-3.0)
  # 🔴 2026-10-26：GLX 后端需要 X11 头（gdk/gdkx.h → X11/Xlib.h）与 libGL
  #   （glXCreateContext / glXChooseFBConfig / glXCreatePbuffer 等）。
  find_package(X11 REQUIRED)
  find_package(OpenGL REQUIRED)

  add_library(heinplay_mpv_desktop SHARED ${HEIN_MPV_DESKTOP_SRC})
  target_include_directories(heinplay_mpv_desktop PRIVATE
      ${CMAKE_CURRENT_LIST_DIR}
  )
  # `flutter` 是 linux/flutter/CMakeLists.txt 建的 INTERFACE 库，
  # 已带 libflutter_linux_gtk.so 的链接路径与 flutter_linux/ 头文件搜索路径。
  # 壳只依赖其头（fl_texture_gl.h / fl_texture_registrar.h 等），
  # 运行时符号由 runner 进程里的 libflutter_linux_gtk.so 提供。
  target_link_libraries(heinplay_mpv_desktop PRIVATE
      flutter
      PkgConfig::MPV
      PkgConfig::EPOXY
      PkgConfig::GTK3
      X11::X11
      OpenGL::GL
  )
  # RUNPATH 必须用 $ORIGIN 相对定位：
  #   · 壳由 runner dlopen，壳自身要找到 libmpv.so.2；
  #   · 壳与内核被 CMake 安装规则放进同一 bundle/lib 目录，
  #     故 $ORIGIN 即「壳所在目录」= 内核所在目录；
  #   · 不能用绝对路径 /usr/local/...，那台是构建机路径，
  #     用户机器上不存在该目录会直接 dlopen 失败。
  # INSTALL_RPATH 让安装后的副本也带上该相对路径。
  set_target_properties(heinplay_mpv_desktop PROPERTIES
      BUILD_RPATH "$ORIGIN"
      INSTALL_RPATH "$ORIGIN"
  )
  # 🔴 强制 DT_RPATH（不用默认的 DT_RUNPATH）：
  #    壳由 runner dlopen，RUNPATH 不传递给它的依赖（libmpv→libavcodec
  #    解析不到），RPATH 会传递。真机 2026-10-19 实测踩坑。
  set_target_properties(heinplay_mpv_desktop PROPERTIES
      BUILD_WITH_INSTALL_RPATH TRUE)
endif()

# ---- Windows：官方预编译 libmpv-2.dll ----
if(WIN32)
  set(HEIN_MPV_WIN_DIR
      "${CMAKE_CURRENT_LIST_DIR}/../../third_party/mpv-windows")

  add_library(heinplay_mpv_desktop SHARED ${HEIN_MPV_DESKTOP_SRC})
  target_include_directories(heinplay_mpv_desktop PRIVATE
      ${CMAKE_CURRENT_LIST_DIR}
      "${HEIN_MPV_WIN_DIR}/include"
      # mpv 头文件用 <mpv/client.h> 形式 include，需指向 include/ 的上级
      "${HEIN_MPV_WIN_DIR}"
  )
  target_link_libraries(heinplay_mpv_desktop PRIVATE
      "${HEIN_MPV_WIN_DIR}/lib/mpv.lib"
      d3d11
      dxgi
      opengl32
      # 🔴 2026-10-22：必须链 flutter_wrapper_plugin（而不是 flutter）。
      #   · flutter_wrapper_plugin PUBLIC 链了 flutter INTERFACE target，
      #     后者带 include 目录 ${EPHEMERAL_DIR}（windows/flutter/ephemeral），
      #     扁平 C 头 flutter_windows.h / flutter_texture_registrar.h 等在那里；
      #   · 本壳用了 C++ wrapper（flutter::MethodChannel / StandardMethodCodec /
      #     BinaryMessenger），其头在 ${EPHEMERAL_DIR}/cpp_client_wrapper/include，
      #     由 flutter_wrapper_plugin 的 PUBLIC include 目录带进来；
      #   · 链接它同时解决 MethodChannel/EngineMethodResult 等符号
      #     （core_implementations.cc / standard_codec.cc）。
      #   仅链 flutter 的话：C1083 找不到 flutter_windows.h，
      #   且链接期缺 flutter::internal::ReplyManager 等符号。
      flutter_wrapper_plugin
  )
  # C++17：mpv 头 + WRL + Flutter C++ wrapper 都要求。
  target_compile_features(heinplay_mpv_desktop PRIVATE cxx_std_17)

  # ---- 官方内核 libmpv-2.dll 随应用分发 ----
  #   Windows 无 rpath 机制，DLL 必须与可执行文件同目录（或在 PATH）。
  #   Flutter 桌面 bundle 的结构是 <bundle>/<exe> + <bundle>/<dll>，
  #   故装到 CMAKE_INSTALL_PREFIX 根（与 hain_tv.exe 同级）。
  set(HEIN_MPV_DLL "${HEIN_MPV_WIN_DIR}/bin/libmpv-2.dll")
  if(EXISTS "${HEIN_MPV_DLL}")
    install(FILES "${HEIN_MPV_DLL}"
        DESTINATION "${CMAKE_INSTALL_PREFIX}"
        COMPONENT Runtime)
  else()
    message(WARNING "未找到 ${HEIN_MPV_DLL}，桌面 mpv 后端将无法运行")
  endif()

  # 🔴🔴 2026-10-22：**壳 DLL 本身也必须 install**（此前 Windows 完全漏了）。
  #   runner 的 flutter_window.cpp 用 LoadLibraryA("heinplay_mpv_desktop.dll")
  #   加载壳，再 GetProcAddress 取注册函数。Linux 侧 linux/CMakeLists.txt 有
  #   install(FILES $<TARGET_FILE:heinplay_mpv_desktop> ...)，Windows 侧没有 →
  #   Release 目录里根本没有这个 DLL → LoadLibrary 失败 → 插件从未注册 →
  #   Dart 侧报 MissingPluginException（method init on channel
  #   hain_tv/mpv_desktop）→ 点播与直播全部无法播放。
  #   症状与 Linux「能正常播放」完全相反，根因就是这条缺失的安装规则。
  install(FILES "$<TARGET_FILE:heinplay_mpv_desktop>"
      DESTINATION "${CMAKE_INSTALL_PREFIX}"
      COMPONENT Runtime)

  # 明确不导出全部符号：注册函数已用 __declspec(dllexport) 精确导出。
  # 若打开 WINDOWS_EXPORT_ALL_SYMBOLS，会把静态库带进来的 flutter:: 符号
  # 一并导出，与 flutter_windows.dll 的导出表重叠。
  set_target_properties(heinplay_mpv_desktop PROPERTIES
      WINDOWS_EXPORT_ALL_SYMBOLS OFF)
endif()
