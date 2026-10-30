# 安装期脚本：把官方 libmpv 的传递依赖全量拷入 bundle/lib。
#
# 🔴🔴 v2（2026-10-19 修正）：
#   v1 只按 ldd 右侧路径 file(INSTALL)，结果拷进来的是 **指向构建机绝对路径
#   的符号链接**（如 libacl.so.1 -> /lib/x86_64-linux-gnu/libacl.so.1.1.2302），
#   真实文件从未被拷入——bundle 里 240 个名字中 212 个链接、210 个断链。
#   「ldd 0 not found」在构建机上完全是假阳性（断链 fallback 到系统库）。
#
# v2 逻辑（对每个 ldd 结果）：
#   ① realpath 解析到真实文件（跨多层链接解析到最终目标）；
#   ② 排除 glibc 核心库（libc/libm/libdl/libpthread/librt/ld-linux/resolv/
#      nss/gcc_s/stdc++）——分发绝不能自带 glibc：版本与用户内核强耦合，
#      自带旧版会让用户系统崩溃；用户机器必有且向后兼容；
#   ③ file(COPY) 真实文件进 lib/；
#   ④ 链接名 != 真实名时，按链接名建**相对**符号链接
#      （NEEDED 记的是链接名，必须同名可达）。
#
# 🔴 本脚本由 install(SCRIPT) 调用，cmake_install.cmake 不加载 CMakeCache，
#    故自行推导 libmpv.so.2 路径。

# 本脚本位于 <工程>/src/mpv_desktop/，工程根在其上两级。
get_filename_component(HEIN_PROJECT_ROOT "${CMAKE_CURRENT_LIST_FILE}" DIRECTORY)
get_filename_component(HEIN_PROJECT_ROOT "${HEIN_PROJECT_ROOT}" DIRECTORY)
get_filename_component(HEIN_PROJECT_ROOT "${HEIN_PROJECT_ROOT}" DIRECTORY)

set(HEIN_LIBMPV_BUNDLED
    "${HEIN_PROJECT_ROOT}/third_party/mpv-linux/libmpv.so.2")
set(HEIN_LIBMPV_SYSTEM
    "/usr/local/lib/x86_64-linux-gnu/libmpv.so.2")

set(HEIN_LIBMPV_REAL "${HEIN_LIBMPV_BUNDLED}")
if(NOT EXISTS "${HEIN_LIBMPV_REAL}")
  set(HEIN_LIBMPV_REAL "${HEIN_LIBMPV_SYSTEM}")
endif()

if(NOT EXISTS "${HEIN_LIBMPV_REAL}")
  message(WARNING "桌面 mpv：找不到 libmpv.so.2，跳过依赖收集")
  return()
endif()

execute_process(
    COMMAND ldd "${HEIN_LIBMPV_REAL}"
    OUTPUT_VARIABLE HEIN_LDD_OUT
    RESULT_VARIABLE HEIN_LDD_RC
    OUTPUT_STRIP_TRAILING_WHITESPACE)

if(NOT HEIN_LDD_RC EQUAL 0)
  message(WARNING "桌面 mpv：ldd 执行失败 rc=${HEIN_LDD_RC}")
  return()
endif()

find_program(HEIN_PATCHELF patchelf)

set(HEIN_DEST_DIR "${CMAKE_INSTALL_PREFIX}/lib")
file(MAKE_DIRECTORY "${HEIN_DEST_DIR}")

# ---- 精简 ffmpeg 优先：直接拷贝 third_party/ffmpeg-mini ----
#
# 🔴 2026-10-20 体积优化：系统 Debian ffmpeg 全家桶 126MiB（占 bundle 一半），
#    因为 libavcodec 带全部编解码器。改用**自编译精简 ffmpeg**
#    （只留 h264/hevc/aac/mp3/vp8/vp9/av1 + hls/mp4/ts 容器 + https），
#    12MiB，省 114MiB。
#
#    配套：third_party/mpv-linux/libmpv.so.2 也是**重新编译**的，
#    链接 libavcodec.so.62（精简版），而非系统 .61。
#    SONAME 必须匹配，否则运行期报 undefined symbol。
set(HEIN_FFMPEG_MINI_DIR
    "${HEIN_PROJECT_ROOT}/third_party/ffmpeg-mini/lib")
if(EXISTS "${HEIN_FFMPEG_MINI_DIR}")
  file(GLOB HEIN_FFMPEG_SO "${HEIN_FFMPEG_MINI_DIR}/*.so*")
  foreach(f ${HEIN_FFMPEG_SO})
    file(COPY "${f}" DESTINATION "${HEIN_DEST_DIR}")
  endforeach()
  # 🔴 给精简 ffmpeg 补 $ORIGIN RPATH：
  #    这些库是自编译产物，**本身不带 RPATH**，拷贝后彼此找不到
  #    （libavcodec 找不到 libswresample，libavformat 找不到 libavcodec）。
  #    必须逐个设 DT_RPATH=$ORIGIN（FORCE_RPATH 会传递给依赖）。
  if(HEIN_PATCHELF)
    # file(GLOB) 不支持正则，用多次 GLOB 覆盖各前缀
    file(GLOB HEIN_FFMPEG_DEST
         "${HEIN_DEST_DIR}/libav*.so.*"
         "${HEIN_DEST_DIR}/libsw*.so.*"
         "${HEIN_DEST_DIR}/libpostproc*.so.*")
    foreach(f ${HEIN_FFMPEG_DEST})
      execute_process(
          COMMAND "${HEIN_PATCHELF}" --set-rpath "$ORIGIN" --force-rpath "${f}"
          OUTPUT_QUIET ERROR_QUIET)
    endforeach()
    list(LENGTH HEIN_FFMPEG_DEST HEIN_FFMPEG_PATCHED)
    message(STATUS "桌面 mpv：精简 ffmpeg ${HEIN_FFMPEG_PATCHED} 个库已设 RPATH")

    # 🔴 libmpv 自身的 RUNPATH 是编译期 prefix（/opt/ffmpeg-mini/lib），
  #    在用户机器上是死路径，且会优先于 $ORIGIN → 找不到同目录的 ffmpeg。
  #    必须改成 DT_RPATH=$ORIGIN（会传递给依赖）。
  if(HEIN_PATCHELF AND EXISTS "${HEIN_DEST_DIR}/libmpv.so.2")
    execute_process(
        COMMAND "${HEIN_PATCHELF}" --remove-rpath "${HEIN_DEST_DIR}/libmpv.so.2"
        OUTPUT_QUIET ERROR_QUIET)
    execute_process(
        COMMAND "${HEIN_PATCHELF}" --set-rpath "$ORIGIN" --force-rpath
                "${HEIN_DEST_DIR}/libmpv.so.2"
        RESULT_VARIABLE _mpv_rp_rc OUTPUT_QUIET ERROR_QUIET)
    if(_mpv_rp_rc EQUAL 0)
      message(STATUS "桌面 mpv：libmpv 已设 DT_RPATH=$ORIGIN")
    endif()
  endif()
  endif()
  list(LENGTH HEIN_FFMPEG_SO HEIN_FFMPEG_CNT)
  message(STATUS "桌面 mpv：已随附精简 ffmpeg ${HEIN_FFMPEG_CNT} 个文件")
  # 精简版已覆盖 ffmpeg，后续 ldd 收集会因 SONAME 不同而跳过系统版
  set(HEIN_USE_MINI_FFMPEG TRUE)
else()
  set(HEIN_USE_MINI_FFMPEG FALSE)
endif()

# ---- glibc 核心库排除名单（绝不分发）----
set(HEIN_GLIBC_EXACT
    libc.so.6 libm.so.6 libmvec.so.1 libdl.so.2 libpthread.so.0 librt.so.1
    libresolv.so.2 libnsl.so.3 libutil.so.1 libanl.so.1
    libgcc_s.so.1 libstdc++.so.6)

# 🔴🔴 Vulkan loader 绝不打包（2026-10-19 真机问题定位）：
#   libvulkan.so.1 只是 **loader**，真正的 GPU 驱动是 ICD
#   （/usr/share/vulkan/icd.d/*.json + libvulkan_*.so）。
#   若把构建机的 loader 打进 bundle：
#     1) bundle 的 loader 会盖住系统 loader（$ORIGIN 优先）；
#     2) 构建机 loader 的版本与目标机 ICD 不匹配 → 拒绝加载 ICD；
#     3) 表现为 **mpv 初始化失败、应用打开无反应**（无窗口、无报错）。
#   不可变系统（Bazzite/Fedora Silverblue）必然自带匹配的 loader+ICD，
#   交给系统才是正解。此处排除后 libmpv/libplacebo 仍能依赖它（系统路径解析）。
set(HEIN_VULKAN_EXACT libvulkan.so.1)

# 🔴🔴 与系统图形栈共享的基础库绝不打包（2026-10-19 真机崩溃定位）：
#   fontconfig 被系统 pango/cairo 依赖。bundle 打进 Debian 的 1.12.1 后，
#   $ORIGIN 优先加载 → Fedora(Bazzite) 的 libpangoft2 找不到
#   FcConfigSetDefaultSubstitute（1.16 才有）→ 启动即
#   "symbol lookup error" 崩溃，表现为「打开无反应」。
#   同理适用于所有被**系统级组件**（pango/cairo/gdk-pixbuf/harfbuzz/freetype）
#   依赖的库：它们必须与系统版本一致。
set(HEIN_SYSGRAPHICS_EXACT
    # 🔴🔴 glib 全家桶：系统基础运行时，绝不能打包（2026-10-20 真机崩溃定位）
    #    Bazzite(Fedora 44) 是 glib 2.88，Debian 构建机是 2.84。
    #    bundle 打包旧版后，系统 libgobject 找不到 2.88 新增的
    #    g_string_copy → 启动即：
    #      "symbol lookup error: /usr/lib64/libgobject-2.0.so.0:
    #       undefined symbol: g_string_copy"
    #    表现就是「双击/直接运行无反应」。
    libglib-2.0.so.0
    libgobject-2.0.so.0
    libgio-2.0.so.0
    libgmodule-2.0.so.0
    libgthread-2.0.so.0
    # GTK/GDK 同理（必须与系统 glib 配套）
    libgtk-3.so.0
    libgdk-3.so.0
    libatk-1.0.so.0
    libatk-bridge-2.0.so.0
    libatspi.so.0
    libdbus-1.so.3
    libpangoft2-1.0.so.0
    libfontconfig.so.1
    libfreetype.so.6
    libharfbuzz.so.0
    libpango-1.0.so.0
    libpangocairo-1.0.so.0
    libpangoft2-1.0.so.0
    libcairo.so.2
    libcairo-gobject.so.2
    libgdk_pixbuf-2.0.so.0
    libxkbcommon.so.0
    libthai.so.0
    libfribidi.so.0
    libpng16.so.16
    # 🔴 libbz2.so.1.0 **不得**列入本排除名单（2026-10-21 真机根因定位）：
    #    它曾在此处，导致从未被打进 bundle。
    #    构建机 Debian 13 自带 libbz2.so.1.0，ldd 全绿、本机自检通过；
    #    但目标机 Bazzite(Fedora) 只有 libbz2.so.1（无 .1.0 soname），
    #    于是 libavformat.so.62 / libarchive.so.13 一加载即报
    #      "libbz2.so.1.0: 无法打开共享目标文件"
    #    → libheinplay_mpv_desktop.so dlopen 失败 → 壳完全未注册
    #    → Dart 侧 MissingPluginException，点播/直播全部不可播。
    #    该库是纯解压算法库，与图形栈无关，随包分发安全。
    libselinux.so.1
    libpcre2-8.so.0
    libexpat.so.1)

# 🔴🔴🔴 glvnd / wayland / X11 家族：**绝不打包**（2026-10-24 真机启动崩溃定位）
#
#   真机症状（Bazzite/Fedora 44 掌机 69）：双击桌面图标 **完全无反应**；
#   SSH 直跑输出：
#     "No provider of eglGetPlatformDisplayEXT found.  Requires one of:
#      EGL_EXT_platform_base"
#   并以 **exit=134 (SIGABRT)** 崩溃（与 2026-10-20 的 glib 崩溃同一个症状码）。
#
#   根因：bundle 自带了 **Debian 构建机** 的 **glvnd**（libEGL.so.1 +
#   libGLdispatch.so.0）。主程序 DT_RPATH=$ORIGIN/lib 优先于系统路径 →
#   bundle 的 glvnd 蒙蔽了目标机 Bazzite 自带的 Mesa EGL 栈 →
#   Flutter/Impeller 取不到 EGL display → 启动即 abort。
#   同理：
#     · libwayland-client（Debian 版无 wl_fixes_interface 符号）会与系统
#       libEGL_mesa 的符号解析打架 → "undefined symbol wl_fixes_interface (fatal)"
#     · X11 家族必须与目标机系统版本一致，否则符号版本不匹配启动即崩。
#
#   ⇒ 判据不变：**该库是否由系统级图形栈统一提供** → 是则交给系统。
#   ⇒ 已实测：就地剔除这批库后，同一份 AppImage 在 69 上正常启动
#     （PackageInfo 1.4.0 → 网络 200 → [Display] 启动全屏探测 → 进程存活）。
#
#   本名单按**前缀**匹配（下面 HEIN_SYSGRAPHICS_PREFIX），因为真实文件名带
#   版本后缀（如 libEGL.so.1.1.0），精确匹配会漏。
#
# 🔴🔴 但这张表**不是最终真源** —— 真源是 linux/bundle_lib_policy.txt。
#    cmake 与打包脚本读**同一份**文件（根治「修好又回归」的记忆漂移）。
#    此处仅保留内联兜底，防止策略文件缺失时完全失去过滤。
set(HEIN_SYSGRAPHICS_PREFIX
    # glvnd 转发层（最致命：直接决定 Flutter 能否拿到 EGL display）
    "libEGL.so"
    "libGLdispatch.so"
    "libGLESv2.so"
    "libGL.so"
    "libGLX.so"
    # wayland 客户端栈（与系统 libEGL_mesa 符号解析冲突）
    "libwayland-client.so"
    "libwayland-cursor.so"
    "libwayland-egl.so"
    "libwayland-server.so"
    # X11 家族（含被 libX11 依赖的私有小库）
    "libX11.so"
    "libXext.so"
    "libXrandr.so"
    "libXi.so"
    "libXcursor.so"
    "libXtst.so"
    "libXinerama.so"
    "libXxf86vm.so"
    "libXrender.so"
    "libXfixes.so"
    "libXdamage.so"
    "libXcomposite.so"
    "libXau.so"
    "libXdmcp.so"
    "libXss.so"
    "libXxf86dri.so"
    # Vulkan loader（与 2026-10-19 同因：loader 必须与系统 ICD 配套）
    "libvulkan.so")

# ---- 依赖策略单一真源：linux/bundle_lib_policy.txt ----
#
#   2026-10-19 / 10-20 / 10-24 三次「打开无反应」都是同一类：把构建机的系统
#   图形栈库打进 bundle，到目标机蒙蔽了系统库 → 启动即崩。三次都「修好又回归」，
#   因为约束只存在于工作日志和人的记忆里，构建脚本自己并不知道。
#   ⇒ 现在把约束做成**机器可读**文件：构建期（这里）与打包期
#     （scripts/build_linux_appimage.sh）读**同一份**，并由脚本强制自检。
#   ⇒ 以后新增规则只改那一个文件，不会再漏。
set(HEIN_POLICY_FILE
    "${CMAKE_CURRENT_LIST_DIR}/../../linux/bundle_lib_policy.txt")
if(EXISTS "${HEIN_POLICY_FILE}")
  # 🔴🔴 必须用 file(READ) 而不是 file(STRINGS)：
  #   file(STRINGS) 解析的是 **ASCII** 字符串，非 ASCII 字节（中文注释）
  #   会被当作列表分隔符，把一行拆成碎片（实测：整行被拆成 `**`、
  #   `/ single source of truth**` 等片段 → 前缀正则变成非法的 `^**`）。
  #   ⇒ 这里改成：file(READ) 读全文 → 正则删掉每行的 `#` 注释部分
  #     （策略文件的中文注释因此被整体剔除）→ 再按行切分。
  #     剩下的每一行都是「纯 ASCII 库名前缀」，不含 `;`，列表化安全。
  file(READ "${HEIN_POLICY_FILE}" HEIN_POLICY_RAW)
  string(REGEX REPLACE "#[^\n]*" "" HEIN_POLICY_CLEAN "${HEIN_POLICY_RAW}")
  string(REPLACE "\n" ";" HEIN_POLICY_LINES "${HEIN_POLICY_CLEAN}")
  foreach(_pl ${HEIN_POLICY_LINES})
    string(STRIP "${_pl}" _pl)
    if(_pl STREQUAL "")
      continue()
    endif()
    # 🔴 格式校验：清单行必须是「纯 ASCII 库名前缀」。
    #    任何含 `*` `;` 空格等非法字符的片段一律跳过并告警 ——
    #    否则它会被当成正则前缀使用，产生 "^**" 这类**非法正则**让构建崩掉
    #    （2026-10-24 实测踩过：中文注释被 file(STRINGS) 拆成 `**` 碎片）。
    if(NOT _pl MATCHES "^[A-Za-z0-9_.!+-]+$")
      message(WARNING "桌面 mpv：策略文件中无法识别的行已跳过: ${_pl}")
      continue()
    endif()
    string(SUBSTRING "${_pl}" 0 1 _c0)
    if(_c0 STREQUAL "!")
      # 保护名单：命中前缀也**禁止剔除**（当前只有 libbz2.so.1.0）
      string(SUBSTRING "${_pl}" 1 -1 _keep)
      list(APPEND HEIN_KEEP_EXACT "${_keep}")
    else()
      list(APPEND HEIN_SYSGRAPHICS_PREFIX "${_pl}")
    endif()
  endforeach()
  list(LENGTH HEIN_SYSGRAPHICS_PREFIX _np)
  list(LENGTH HEIN_KEEP_EXACT _nk)
  message(STATUS "桌面 mpv：已加载 bundle 依赖策略 ${_np} 条剔除前缀 + "
                 "${_nk} 条保护（真源 ${HEIN_POLICY_FILE}）")
else()
  message(WARNING "桌面 mpv：找不到依赖策略文件 ${HEIN_POLICY_FILE}！"
                  "将只用内联排除名单，可能漏库导致真机启动崩溃")
endif()

# 判断字符串是否以给定前缀开头。
#
# 🔴🔴 **绝不用正则实现**（2026-10-24 实测连续踩坑）：
#   · 前缀里可能含正则元字符 —— 内联兜底名单的 libstdc++.so.6 含 '+'，
#     拼成 "^libstdc++.so.6" 是**非法正则**（nothing to repeat）→ 构建崩；
#   · 中文策略文件被 file(STRINGS) 拆出的碎片含 '*' → "^**" 同样非法；
#   · '.' 在正则里是「任意字符」，libX11.so 会误配 libX11Xso。
#   ⇒ 一律改用纯字符串比较，零正则风险。
function(hein_starts_with _value _prefix _out)
  string(LENGTH "${_value}" _vlen)
  string(LENGTH "${_prefix}" _plen)
  if(_plen GREATER 0 AND _vlen GREATER_EQUAL _plen)
    string(SUBSTRING "${_value}" 0 ${_plen} _head)
    if(_head STREQUAL "${_prefix}")
      set(${_out} TRUE PARENT_SCOPE)
      return()
    endif()
  endif()
  set(${_out} FALSE PARENT_SCOPE)
endfunction()

# ---- 自动判据：系统桌面栈的**依赖闭包** ----
#
#   黑名单是人肉枚举的 → 新增一个系统库就可能漏一次（已复发三次）。
#   这里补一条**判据式**的自动规则：
#   「凡是**系统桌面栈入口库**的依赖闭包内的库，一律不打包。」
#
#   入口库 = GTK / GDK / EGL / GBM / X11 / Wayland / GLib / Pango / Cairo /
#            gdk-pixbuf / fontconfig / freetype / ALSA
#   这些库在**任何有桌面的发行版**上必然存在，且它们的依赖（fontconfig、
#   freetype、harfbuzz、xcb、drm、wayland、glib…）也必然由系统提供、
#   且必须与系统版本一致 —— 所以闭包内的库全部交给系统。
#
#   效果：以后系统多出新的图形栈依赖，**无需改任何清单**，规则自动覆盖。
#   （黑名单仍保留，作为人工补充与显式意图的记录。）
set(HEIN_SYS_ENTRIES
    libgtk-3.so.0 libgdk-3.so.0 libEGL.so.1 libgbm.so.1 libX11.so.6
    libwayland-client.so.0 libglib-2.0.so.0 libgobject-2.0.so.0
    libpango-1.0.so.0 libcairo.so.2 libgdk_pixbuf-2.0.so.0
    libfontconfig.so.1 libfreetype.so.6 libasound.so.2)

set(HEIN_SYS_CLOSURE "")
foreach(_e ${HEIN_SYS_ENTRIES})
  find_library(_ep NAMES ${_e}
    PATHS /usr/lib/x86_64-linux-gnu /lib/x86_64-linux-gnu /usr/lib64 /usr/lib
    NO_DEFAULT_PATH)
  if(NOT _ep)
    find_library(_ep NAMES ${_e})
  endif()
  if(_ep AND EXISTS "${_ep}")
    execute_process(COMMAND ldd "${_ep}" OUTPUT_VARIABLE _eo
                    ERROR_QUIET RESULT_VARIABLE _erc)
    if(_erc EQUAL 0)
      string(REPLACE "\n" ";" _els "${_eo}")
      foreach(_el ${_els})
        string(STRIP "${_el}" _el)
        if(_el MATCHES "=> */[^ ]+")
          string(REGEX REPLACE "^([^ ]+) =>.*$" "\\1" _son "${_el}")
        elseif(_el MATCHES "^[a-zA-Z0-9_.+-]+ \\(0x")
          string(REGEX REPLACE " \\(0x.*$" "" _son "${_el}")
        else()
          continue()
        endif()
        if(_son MATCHES "^[a-zA-Z0-9_.+-]+$")
          list(APPEND HEIN_SYS_CLOSURE "${_son}")
        endif()
      endforeach()
    endif()
  endif()
endforeach()
if(HEIN_SYS_CLOSURE)
  list(REMOVE_DUPLICATES HEIN_SYS_CLOSURE)
  list(LENGTH HEIN_SYS_CLOSURE _nc)
  message(STATUS "桌面 mpv：系统桌面栈依赖闭包 ${_nc} 个库，闭包内一律不打包")
else()
  message(WARNING "桌面 mpv：未能求出系统桌面栈依赖闭包（入口库缺失？），"
                  "仅依赖黑名单过滤")
endif()

string(REPLACE "\n" ";" HEIN_LDD_LINES "${HEIN_LDD_OUT}")
set(HEIN_COPIED_REALS "")
set(HEIN_LINK_COUNT 0)
set(HEIN_SKIP_COUNT 0)

foreach(line ${HEIN_LDD_LINES})
  # 行形如：\tlibavcodec.so.61 => /lib/x86_64-linux-gnu/libavcodec.so.61 (0x...)
  # 🔴 ldd 行首是 **TAB** 不是空格！"^ *" 捕获组会把 tab 吃进链接名，
  #    之前创建了 200 个名字带前导 tab 的损坏条目（\'\\tlibass.so.9\'），
  #    表面上是「229 个断链」。
  if(NOT line MATCHES "=> */[^ ]+")
    continue()
  endif()
  string(STRIP "${line}" line)
  string(REGEX REPLACE "^([^ ]+) => /([^ ]+)( \\(0x[0-9a-f]+\\))?$" "\\1"
         HEIN_LINK_NAME "${line}")
  string(REGEX REPLACE "^([^ ]+) => /([^ ]+)( \\(0x[0-9a-f]+\\))?$" "/\\2"
         HEIN_ABS_PATH "${line}")
  # 双保险：strip 后再剥一次残留
  string(STRIP "${HEIN_LINK_NAME}" HEIN_LINK_NAME)

  if(NOT EXISTS "${HEIN_ABS_PATH}")
    continue()
  endif()

  # ---- ② 系统级库过滤（按链接名 + 真实名双重判断）----
  # 🔴 真实名也要判：有的库链接名是 libcairo.so.2 而真实文件是
  #    libcairo.so.2.11800，若上游库直接依赖真实名（少见但存在），
  #    只判链接名会漏。
  get_filename_component(HEIN_BN_LINK "${HEIN_LINK_NAME}" NAME)
  set(HEIN_IS_SYS 0)
  # 用了精简 ffmpeg 时，跳过系统 ffmpeg 全家桶（否则又会拷 126MiB 进来）
  if(HEIN_USE_MINI_FFMPEG AND HEIN_BN_LINK MATCHES "^lib(av|sw|postproc)[a-z]*\\.so")
    math(EXPR HEIN_SKIP_COUNT "${HEIN_SKIP_COUNT}+1")
    continue()
  endif()
  foreach(g ${HEIN_GLIBC_EXACT} ${HEIN_VULKAN_EXACT} ${HEIN_SYSGRAPHICS_EXACT})
    if(HEIN_BN_LINK STREQUAL g)
      set(HEIN_IS_SYS 1)
    endif()
  endforeach()
  # 🔴 前缀策略：真源 linux/bundle_lib_policy.txt（+ 内联兜底表）。
  #    按前缀匹配是因为真实文件名带版本后缀（libEGL.so.1.1.0），
  #    精确名匹配会漏 —— 漏一个 glvnd 就是「双击无反应 + exit=134」。
  #    用字符串比较而非正则（libstdc++.so.6 含 '+'，拼正则会非法）。
  foreach(_pfx ${HEIN_SYSGRAPHICS_PREFIX})
    hein_starts_with("${HEIN_BN_LINK}" "${_pfx}" _hit)
    if(_hit)
      set(HEIN_IS_SYS 1)
    endif()
  endforeach()
  if(HEIN_BN_LINK MATCHES "^libnss_" OR HEIN_BN_LINK MATCHES "^ld-linux")
    set(HEIN_IS_SYS 1)
  endif()
  # 🔴 自动判据：系统桌面栈依赖闭包内的库 → 交给系统，不打包。
  #    （前缀黑名单之外的兜底规则，新增系统库无需改清单。）
  #    ⚠️ 顺序要求：闭包判定必须在**保护名单之前**。
  #    保护名单（! 前缀）是「强制自带」的最终裁决，闭包不得覆盖它 ——
  #    否则 X11 全族（libXpresent/libXv/…）会被闭包重新判成系统库，
  #    而纯 Wayland 目标机根本没有它们 → libmpv 硬依赖缺失 →
  #    dlopen 失败 → 插件不注册 → 点播/直播全不可播（2026-10-24 真机事故）。
  if(HEIN_SYS_CLOSURE)
    list(FIND HEIN_SYS_CLOSURE "${HEIN_BN_LINK}" _ci)
    if(NOT _ci EQUAL -1)
      set(HEIN_IS_SYS 1)
    endif()
  endif()
  # 🔴 保护名单撤销：命中即恢复为「随包分发」。
  #    （libbz2.so.1.0 —— Fedora 无此 soname；
  #     libX11/libxcb/libXpresent/… —— 纯 Wayland 目标机不保证有）
  #    ⭐ 必须放在闭包判定**之后**：保护名单是最终裁决，优先级最高。
  foreach(_kp ${HEIN_KEEP_EXACT})
    hein_starts_with("${HEIN_BN_LINK}" "${_kp}" _hit)
    if(_hit)
      set(HEIN_IS_SYS 0)
    endif()
  endforeach()
  if(HEIN_IS_SYS)
    math(EXPR HEIN_SKIP_COUNT "${HEIN_SKIP_COUNT}+1")
    continue()
  endif()

  # ---- ① 解析到真实文件 ----
  execute_process(
      COMMAND realpath "${HEIN_ABS_PATH}"
      OUTPUT_VARIABLE HEIN_REAL_PATH
      OUTPUT_STRIP_TRAILING_WHITESPACE
      RESULT_VARIABLE HEIN_RP_RC)
  if(NOT HEIN_RP_RC EQUAL 0 OR NOT EXISTS "${HEIN_REAL_PATH}")
    message(WARNING "桌面 mpv：realpath 解析失败 ${HEIN_ABS_PATH}")
    continue()
  endif()
  get_filename_component(HEIN_REAL_NAME "${HEIN_REAL_PATH}" NAME)

  # ---- ②b 真实名二次过滤 ----
  set(HEIN_IS_SYS2 0)
  foreach(g ${HEIN_GLIBC_EXACT} ${HEIN_VULKAN_EXACT} ${HEIN_SYSGRAPHICS_EXACT})
    if(HEIN_REAL_NAME STREQUAL g)
      set(HEIN_IS_SYS2 1)
    endif()
  endforeach()
  # 🔴 真实名的前缀策略同样要判（真实名形如 libEGL.so.1.1.0，
  #    只判链接名会漏 —— 漏 glvnd/wayland/X11 就是真机启动崩溃）。
  foreach(_pfx ${HEIN_SYSGRAPHICS_PREFIX})
    hein_starts_with("${HEIN_REAL_NAME}" "${_pfx}" _hit)
    if(_hit)
      set(HEIN_IS_SYS2 1)
    endif()
  endforeach()
  # 🔴 保护名单撤销（libbz2.so.1.0 真实名是 libbz2.so.1.0.4，同样要豁免）
  foreach(_kp ${HEIN_KEEP_EXACT})
    hein_starts_with("${HEIN_REAL_NAME}" "${_kp}" _hit)
    if(_hit)
      set(HEIN_IS_SYS2 0)
    endif()
  endforeach()
  if(HEIN_IS_SYS2)
    math(EXPR HEIN_SKIP_COUNT "${HEIN_SKIP_COUNT}+1")
    continue()
  endif()

  # ---- ③ 拷真实文件（按真实路径去重）----
  list(FIND HEIN_COPIED_REALS "${HEIN_REAL_PATH}" HEIN_IDX)
  if(HEIN_IDX EQUAL -1)
    file(COPY "${HEIN_REAL_PATH}" DESTINATION "${HEIN_DEST_DIR}"
         USE_SOURCE_PERMISSIONS)
    list(APPEND HEIN_COPIED_REALS "${HEIN_REAL_PATH}")

    # 🔴 立刻把 RUNPATH 设为纯 $ORIGIN：
    #    系统库自带各种绝对 RUNPATH（/usr/lib/... 等），在用户机器上是
    #    死路径；不清理的话 ldd 优先级混乱，且泄漏构建机路径。
    #    失败不致命（可执行仍能用系统缓存兜底），仅告警。
    find_program(HEIN_PATCHELF patchelf)
    if(HEIN_PATCHELF)
      execute_process(
          # 🔴 --force-rpath：写 DT_RPATH 而非 DT_RUNPATH。
          #    DT_RUNPATH **不会传递给依赖**——壳被 dlopen 时，它自己的
          #    RUNPATH 只解析直接 NEEDED 里的第一层，更深层（libmpv→libavcodec）
          #    解析不到（真机实测：dlopen 失败 libavcodec.so.61）。
          #    DT_RPATH 会传递，dlopen 场景必须用它。
          COMMAND "${HEIN_PATCHELF}" --set-rpath "$ORIGIN" --force-rpath
                  "${HEIN_DEST_DIR}/${HEIN_REAL_NAME}"
          RESULT_VARIABLE HEIN_PE_RC
          OUTPUT_QUIET ERROR_QUIET)
      if(NOT HEIN_PE_RC EQUAL 0)
        message(STATUS "桌面 mpv：patchelf 失败 ${HEIN_REAL_NAME}（跳过）")
      endif()
    endif()
  endif()

  # ---- ④ 建相对符号链接（链接名 != 真实名时）----
  if(NOT HEIN_BN_LINK STREQUAL HEIN_REAL_NAME)
    if(NOT EXISTS "${HEIN_DEST_DIR}/${HEIN_BN_LINK}")
      execute_process(
          COMMAND ln -s "${HEIN_REAL_NAME}" "${HEIN_DEST_DIR}/${HEIN_BN_LINK}"
          RESULT_VARIABLE HEIN_LN_RC)
      if(HEIN_LN_RC EQUAL 0)
        math(EXPR HEIN_LINK_COUNT "${HEIN_LINK_COUNT}+1")
      endif()
    endif()
  endif()
endforeach()

list(LENGTH HEIN_COPIED_REALS HEIN_REAL_COUNT)
message(STATUS "桌面 mpv：随附 ${HEIN_REAL_COUNT} 个真实依赖文件、"
               "${HEIN_LINK_COUNT} 个符号链接（glibc 核心 ${HEIN_SKIP_COUNT} 个已排除）")

# ---- ③b 强制补齐 libbz2（不依赖 ldd 是否收到）----
#
# 🔴 2026-10-21 真机根因：libavformat.so.62 / libarchive.so.13 的 NEEDED 里有
#    libbz2.so.1.0，但 bundle 里从来没有它。
#    ldd 只对 libmpv.so.2 跑一次，且以**构建机**视角解析——Debian 13 系统
#    自带 libbz2.so.1.0，ldd 输出里这一行会被 SYSGRAPHICS 过滤或干脆未被
#    当作「需要随附」的库，于是静默漏掉。
#    Fedora/Bazzite 只有 libbz2.so.1，没有 .1.0 这个 soname，
#    加载 libavformat 立刻失败 → 壳 dlopen 失败 → 插件未注册。
#    这里**无条件**从构建机拷入真实文件 + 建 .1.0 链接名，双保险。
set(HEIN_BZ2_NEEDED "libbz2.so.1.0")
if(NOT EXISTS "${HEIN_DEST_DIR}/${HEIN_BZ2_NEEDED}")
  set(HEIN_BZ2_FOUND "")
  foreach(_cand
      "/usr/lib/x86_64-linux-gnu/${HEIN_BZ2_NEEDED}"
      "/lib/x86_64-linux-gnu/${HEIN_BZ2_NEEDED}"
      "/usr/lib64/${HEIN_BZ2_NEEDED}"
      "/usr/lib/${HEIN_BZ2_NEEDED}")
    if(EXISTS "${_cand}")
      set(HEIN_BZ2_FOUND "${_cand}")
      break()
    endif()
  endforeach()
  if(HEIN_BZ2_FOUND)
    execute_process(COMMAND realpath "${HEIN_BZ2_FOUND}"
                    OUTPUT_VARIABLE HEIN_BZ2_REAL
                    OUTPUT_STRIP_TRAILING_WHITESPACE)
    if(HEIN_BZ2_REAL AND EXISTS "${HEIN_BZ2_REAL}")
      get_filename_component(HEIN_BZ2_REAL_NAME "${HEIN_BZ2_REAL}" NAME)
      file(COPY "${HEIN_BZ2_REAL}" DESTINATION "${HEIN_DEST_DIR}")
      if(NOT HEIN_BZ2_REAL_NAME STREQUAL HEIN_BZ2_NEEDED)
        execute_process(
            COMMAND ln -sf "${HEIN_BZ2_REAL_NAME}"
                    "${HEIN_DEST_DIR}/${HEIN_BZ2_NEEDED}" OUTPUT_QUIET ERROR_QUIET)
      endif()
      message(STATUS "桌面 mpv：已强制随附 ${HEIN_BZ2_NEEDED}（真实名 ${HEIN_BZ2_REAL_NAME}）")
    endif()
  else()
    message(WARNING "桌面 mpv：构建机上找不到 ${HEIN_BZ2_NEEDED}，"
                    "目标机为 Fedora 系时壳将 dlopen 失败")
  endif()
endif()

# ---- 主程序也改成 DT_RPATH=$ORIGIN/lib ----
#
# 🔴 主程序 dlopen 壳时，壳的**传递依赖**（libmpv.so.2 → libavcodec.so.61）
#    需要被解析。DT_RUNPATH 不传递给依赖，必须给主程序写 DT_RPATH=$ORIGIN/lib。
#    真机 2026-10-19 实测：只用 RUNPATH 时 dlopen 报
#    「libavcodec.so.61: 无法打开共享目标文件」。
set(HEIN_MAIN_BIN "${CMAKE_INSTALL_PREFIX}/hain_tv")
if(EXISTS "${HEIN_MAIN_BIN}" AND HEIN_PATCHELF)
  execute_process(
      COMMAND "${HEIN_PATCHELF}" --remove-rpath "${HEIN_MAIN_BIN}"
      RESULT_VARIABLE _rr OUTPUT_QUIET ERROR_QUIET)
  execute_process(
      COMMAND "${HEIN_PATCHELF}" --set-rpath "$ORIGIN/lib" --force-rpath
              "${HEIN_MAIN_BIN}"
      RESULT_VARIABLE HEIN_MAIN_RPATH_RC
      OUTPUT_QUIET ERROR_QUIET)
  if(HEIN_MAIN_RPATH_RC EQUAL 0)
    message(STATUS "桌面 mpv：主程序已设 DT_RPATH=$ORIGIN/lib")
  endif()
endif()
