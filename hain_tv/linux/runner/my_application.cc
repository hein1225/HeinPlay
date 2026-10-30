#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <limits.h>
#include <unistd.h>
#include <glib/gstdio.h>
#include <string.h>

// 🔴 桌面 mpv 壳（Linux）：官方 libmpv 内核 + 自写 C 壳。
//    Flutter 的 generated_plugin_registrant.cc 只认 pubspec 里声明的 Dart
//    插件，我们这个纯 C 壳不在其中，故在此手动 dlopen + 调注册函数。
extern "C" void hein_mpv_desktop_plugin_register_with_registrar(
    FlPluginRegistrar* registrar);


// 🔴🔴 2026-10-21 真机（bazzite 掌机）诊断：
//   包内壳与 libmpv 都在、78(Debian) 上 ldd 零缺失，但在 bazzite(Fedora)
//   上壳**完全没注册**——Dart 侧报
//     MissingPluginException(No implementation found for method init
//                             on channel hain_tv/mpv_desktop)
//   本函数原先只用 g_warning/g_print 输出到 stderr，而从桌面图标启动时
//   stderr 直接丢弃，导致「看不到任何失败原因」。
//   这里把注册结果与失败原因落到与 Dart 侧同一个日志目录，便于真机取证。
static void hein_log_to_file(const char* level, const char* fmt, ...) {
  const char* home = g_get_home_dir();
  if (home == nullptr) return;
  g_autofree gchar* dir = g_build_filename(home, "文档", "app_logs", NULL);
  g_mkdir_with_parents(dir, 0755);
  g_autofree gchar* path =
      g_build_filename(dir, "hein_native.log", NULL);
  FILE* f = fopen(path, "a");
  if (f == nullptr) return;
  g_autoptr(GDateTime) now = g_date_time_new_now_local();
  g_autofree gchar* ts = g_date_time_format(now, "%Y-%m-%d %H:%M:%S");
  fprintf(f, "[%s] [%s] ", ts, level);
  va_list ap;
  va_start(ap, fmt);
  vfprintf(f, fmt, ap);
  va_end(ap);
  fprintf(f, "\n");
  fclose(f);
}

static void register_hein_mpv_plugin(FlPluginRegistrar* registrar) {
  static void* handle = nullptr;
  if (handle == nullptr) {
    // 🔴 必须用**绝对路径** dlopen（2026-10-19 真机问题定位）：
    //    按名 dlopen 时，壳的传递依赖（libmpv.so.2 → libavcodec.so.61）也要
    //    被解析，而 dlopen 的搜索路径是「RPATH + LD_LIBRARY_PATH + 系统缓存」，
    //    **不含** bundle/lib（rpath 只对直接链接的可执行文件生效）。
    //    实测按名加载会报：dlopen 失败: libavcodec.so.61: 没有那个文件。
    //
    // 壳由 linux/CMakeLists.txt 装进 <可执行文件目录>/lib/，
    // 故用 /proc/self/exe 定位可执行文件，再拼 lib/libheinplay_mpv_desktop.so。
    gchar exe_path[PATH_MAX] = {0};
    ssize_t n = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);
    if (n <= 0) {
      g_warning("HeinPlayMpvDesktop: readlink /proc/self/exe 失败");
      hein_log_to_file("ERROR", "readlink /proc/self/exe 失败");
      return;
    }
    exe_path[n] = '\0';
    g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
    g_autofree gchar* so_path =
        g_build_filename(exe_dir, "lib", "libheinplay_mpv_desktop.so", NULL);

    // 记录实际解析到的可执行文件路径与壳路径，便于判断 AppImage 挂载点
    hein_log_to_file("INFO", "exe_path=%s so_path=%s 存在=%d", exe_path, so_path,
                     g_file_test(so_path, G_FILE_TEST_EXISTS) ? 1 : 0);
    handle = dlopen(so_path, RTLD_NOW | RTLD_GLOBAL);
    if (handle == nullptr) {
      // 兜底：按名加载（开发机上壳与可执行文件同目录时可用）
      handle = dlopen("libheinplay_mpv_desktop.so", RTLD_NOW | RTLD_GLOBAL);
    }
    if (handle == nullptr) {
      const char* dlerr = dlerror();
      g_warning("HeinPlayMpvDesktop: dlopen 失败（试过 %s 与按名）: %s", so_path,
                dlerr);
      hein_log_to_file("ERROR", "dlopen 失败 so_path=%s err=%s", so_path,
                       dlerr ? dlerr : "(null)");
      return;
    }
  }
  auto fn = reinterpret_cast<void (*)(FlPluginRegistrar*)>(
      dlsym(handle, "hein_mpv_desktop_plugin_register_with_registrar"));
  if (fn == nullptr) {
    g_warning("HeinPlayMpvDesktop: dlsym 失败: %s", dlerror());
    return;
  }
  fn(registrar);
  g_print("HeinPlayMpvDesktop: Linux 壳已注册\n");
  hein_log_to_file("INFO", "Linux 壳已注册 so_path 加载成功");
}

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};
G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  GtkWidget* toplevel = gtk_widget_get_toplevel(GTK_WIDGET(view));
  hein_boot_log("stage: 收到 first-frame（Flutter 已绘制首帧，窗口即将显示）");
  gtk_widget_show(toplevel);

  // 🔴 2026-10-27 22:30：**首帧后再请求一次全屏**。
  //
  // 为什么要在 realize 之前那次之外再补一次：GTK4 之前 gtk_window_fullscreen()
  // 在窗口**尚未 map**（未 show）时，请求会挂在 GtkWindow 上等 map 时才提交；
  // 而 gamescope 的 xdg_toplevel 在 map 那一刻就已按 initial commit 定好
  // 尺寸，后续 fullscreen 请求可能被合成为「已全屏」而不重排 ⇒ 真机实测
  // 窗口停在 1280x720 且 bounds=(26,23,...) 带偏移。
  // 首帧后窗口已 map 且已提交过 initial commit，此时再发一次 fullscreen
  // 会被 gamescope 当作状态变更真正执行，铺满 1920x1080。
  //
  // 判据与 activate() 里一致：仅游戏模式补发，桌面模式不动。
  {
    const gchar* gs_wl = g_getenv("GAMESCOPE_WAYLAND_DISPLAY");
    const gchar* dt = g_getenv("XDG_CURRENT_DESKTOP");
    const gchar* gamepad_ui = g_getenv("SteamGamepadUI");
    const gboolean is_game_mode =
        (gs_wl != nullptr && gs_wl[0] != '\0') ||
        (dt != nullptr && g_strrstr(dt, "gamescope") != nullptr) ||
        (gamepad_ui != nullptr && g_strcmp0(gamepad_ui, "1") == 0);
    if (is_game_mode && GTK_IS_WINDOW(toplevel)) {
      gtk_window_set_decorated(GTK_WINDOW(toplevel), FALSE);
      gtk_window_fullscreen(GTK_WINDOW(toplevel));
      hein_boot_log("stage: 首帧后 → gtk_window_fullscreen() 补发完成");
    }
  }
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  hein_boot_log("stage: activate() 进入");
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  hein_boot_log("stage: GtkWindow 已创建");

  // 🔴 取证（2026-10-27）：记录 GDK 后端的**真实**类型。
  //    游戏模式（gamescope）下 `XDG_SESSION_TYPE` 报的是 `x11`，
  //    但实际合成器是 Wayland —— 环境变量不可信，必须以 GDK 实际
  //    选中的 display 类型为准。这条日志是判定「走 Wayland 还是 X11」
  //    的唯一可靠依据。
  //
  //    ⚠️ 只用类型名字符串判断，不引用 GDK_IS_WAYLAND_DISPLAY：
  //       该宏需要 <gdk/gdkwayland.h>，且若构建时未启用 Wayland 后端
  //       会直接编译失败。类型名恒为 "GdkWaylandDisplay"/"GdkX11Display"。
  {
    GdkDisplay* dpy = gdk_display_get_default();
    if (dpy != nullptr) {
      const char* tn = G_OBJECT_TYPE_NAME(dpy);
      hein_boot_log("diag: GDK display=%s (wayland=%d x11=%d)", tn,
                    (tn != nullptr && strstr(tn, "Wayland") != nullptr) ? 1 : 0,
                    (tn != nullptr && strstr(tn, "X11") != nullptr) ? 1 : 0);
    } else {
      hein_boot_log("diag: gdk_display_get_default() == nullptr（无 display！）");
    }
  }

  // 🔴🔴 2026-10-27 22:30：**游戏模式判据提前到窗口装饰之前**。
  //
  // 为什么要在这里就判定：gamescope 是「单窗口全屏」合成器，它只呈现
  //   一个全屏 surface。任何窗口装饰（header bar / 标题栏）都会让 GTK
  //   计算 client-side decoration 的尺寸，导致实际内容区被压缩、且
  //   窗口不是纯全屏 surface ⇒ gamescope 下表现为**屏幕上什么都看不到**
  //   （真机：用户反馈「软件根本没有显示画面」，而日志里 tick/网络全正常，
  //   说明进程活着、只是没被合成出来）。
  //
  // 判据与 runner 的 hein_force_gamescope_wayland() 保持一致：
  //   ① GAMESCOPE_WAYLAND_DISPLAY 非空；或
  //   ② XDG_CURRENT_DESKTOP 含 "gamescope"；或
  //   ③ SteamGamepadUI=1。
  //   三条任一成立即视为游戏模式（这三个变量在桌面模式下都不会出现）。
  const gchar* hein_gs_wl = g_getenv("GAMESCOPE_WAYLAND_DISPLAY");
  const gchar* hein_desktop = g_getenv("XDG_CURRENT_DESKTOP");
  const gchar* hein_gamepad_ui = g_getenv("SteamGamepadUI");
  const gboolean hein_is_game_mode =
      (hein_gs_wl != nullptr && hein_gs_wl[0] != '\0') ||
      (hein_desktop != nullptr && g_strrstr(hein_desktop, "gamescope") != nullptr) ||
      (hein_gamepad_ui != nullptr && g_strcmp0(hein_gamepad_ui, "1") == 0);
  hein_boot_log("diag: is_game_mode=%d (gs_wl=%s desktop=%s gamepad_ui=%s)",
                hein_is_game_mode ? 1 : 0,
                hein_gs_wl != nullptr ? hein_gs_wl : "(null)",
                hein_desktop != nullptr ? hein_desktop : "(null)",
                hein_gamepad_ui != nullptr ? hein_gamepad_ui : "(null)");

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  //
  // 🔴 游戏模式强制不用 header bar：gamescope 下标题栏无意义，且会破坏
  //    全屏 surface（见上）。
  gboolean use_header_bar = TRUE;
  if (hein_is_game_mode) {
    use_header_bar = FALSE;
  }
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "\u6D77\u56E0\u5F71\u89C6");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "\u6D77\u56E0\u5F71\u89C6");
  }

  gtk_window_set_default_size(window, 1280, 720);

  // 🔴 游戏模式：默认尺寸直接取显示器几何尺寸，并立即 map 窗口。
  //
  // 为什么默认尺寸也要改：gtk_window_fullscreen() 只是「请求」，gamescope
  //   在窗口首次 map 时会用 initial commit 里的尺寸先建 surface。若初始
  //   尺寸是 1280x720，surface 就按 1280x720 建，之后 fullscreen 请求即使
  //   生效，中间也会出现一次「小窗 → 全屏」的跳变，甚至在某些 gamescope
  //   版本里被合成为「已全屏」而不再重排（真机实测停在 1280x720 带偏移）。
  //   直接把默认尺寸设成屏幕尺寸，可让 initial commit 就是全屏大小。
  if (hein_is_game_mode) {
    GdkDisplay* dpy = gdk_display_get_default();
    GdkMonitor* mon =
        (dpy != nullptr) ? gdk_display_get_primary_monitor(dpy) : nullptr;
    if (mon == nullptr && dpy != nullptr) {
      mon = gdk_display_get_monitor(dpy, 0);
    }
    if (mon != nullptr) {
      GdkRectangle geo;
      gdk_monitor_get_geometry(mon, &geo);
      hein_boot_log("stage: 游戏模式 → 显示器几何 %dx%d", geo.width, geo.height);
      if (geo.width > 0 && geo.height > 0) {
        gtk_window_set_default_size(window, geo.width, geo.height);
      }
    } else {
      hein_boot_log("diag: 游戏模式但拿不到 GdkMonitor 几何，沿用 1280x720");
    }
  }

  // 🔴🔴 2026-10-27 22:30：**游戏模式必须在 GTK 层直接全屏**。
  //
  // 【为什么不能靠 Dart 侧 setBounds 兜底】切到 Wayland 后，Dart 的
  //   LinuxDisplay.setBounds 在 Wayland 下无对应能力（Wayland 客户端
  //   不能自定位窗口），代码里直接走「环境即全屏，跳过 setBounds」分支
  //   ⇒ 窗口永远停在 gtk_window_set_default_size(1280,720) 的浮动窗口，
  //   真机实测：`窗口: 1280.0x720.0 bounds=(26.0,23.0,1280.0,720.0)`，
  //   而 View 的 display=1920x1080 ⇒ 画面只占屏幕一块，四周有缝。
  //   （切 Wayland 之前走 X11 时 setBounds 可用，所以那时是满屏的
  //     `1920x1080 bounds=(0,0,...)`，这正是本轮回归的直接原因。）
  //
  // 【为什么用 gtk_window_fullscreen 而不是 resize/move】
  //   Wayland 下 resize/move 都被合成器忽略（只有全屏/最大化这类
  //   状态请求会被 gamescope 采纳）。gtk_window_fullscreen() 发的是
  //   xdg_toplevel.set_fullscreen，gamescope 会真正铺满面板。
  if (hein_is_game_mode) {
    gtk_window_set_decorated(window, FALSE);
    gtk_window_fullscreen(window);
    hein_boot_log("stage: 游戏模式 → gtk_window_fullscreen() 已调用");
  }

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  hein_boot_log("stage: fl_dart_project_new 完成，即将 fl_view_new（引擎启动）");
  FlView* view = fl_view_new(project);
  hein_boot_log("stage: fl_view_new 返回 %p", (void*)view);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);

  // 🔴🔴 2026-10-27 22:32：**游戏模式必须立刻 map 窗口，不能等首帧**。
  //
  // 原逻辑只在 first-frame 回调里 show。桌面模式下这没问题（有 WM 会
  //   先给窗口分配 surface）。但 gamescope 是「合成器只呈现已 map 的
  //   surface」：窗口不 map ⇒ 屏幕上什么都没有；而 Flutter 引擎在窗口
  //   未 map 时又可能不产首帧（无可见 surface 就不排帧）⇒ 互相等待。
  //   真机表现正是用户说的「软件根本没有显示画面」——进程活着、日志
  //   里 tick 与网络都正常，就是没有可见窗口。
  //
  // 游戏模式下先 show 再靠 first_frame_cb 补发全屏，是安全顺序：
  //   show 只让 surface 存在，不改变尺寸；fullscreen 在首帧后补发。
  if (hein_is_game_mode) {
    gtk_widget_show(GTK_WIDGET(window));
    hein_boot_log("stage: 游戏模式 → 窗口已提前 show（不等首帧）");
  }
  hein_boot_log("stage: 即将 gtk_widget_realize（建立 GL 上下文）");
  gtk_widget_realize(GTK_WIDGET(view));
  hein_boot_log("stage: gtk_widget_realize 完成");

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));
  hein_boot_log("stage: fl_register_plugins 完成");

  // 🔴 桌面 mpv 壳（非 pubspec 插件，须手动注册）。
  //
  //   🔴🔴 FlView 实现的是 **FlPluginRegistry**（接口 A），
  //        FlPluginRegistrar 是**另一个**接口（接口 B），两者不可混用：
  //        FL_PLUGIN_REGISTRAR(view) 会把 view 强转成接口 B，
  //        GLib 断言当场失败（实测报一串
  //        `assertion 'FL_IS_PLUGIN_REGISTRAR(self)' failed`，
  //        导致壳的 MethodChannel/EventChannel 全部建不起来）。
  //        正确路径：registry -> get_registrar_for_plugin(name) 拿接口 B。
  FlPluginRegistry* registry = FL_PLUGIN_REGISTRY(view);
  FlPluginRegistrar* mpv_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "HeinPlayMpvDesktop");
  register_hein_mpv_plugin(mpv_registrar);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // 🔴 2026-10-21：**此处刻意不调用 hein_mpv_shutdown()**。
  //
  //    实测（78 真机）：在 GApplication::shutdown 阶段销毁 EGL 上下文与
  //    mpv 实例会**段错误** —— 此时 Flutter Linux 引擎
  //    （libflutter_linux_gtk）仍在拆除自己的 GTK/GL 资源，两边的 GL
  //    销毁过程交叉，必崩。
  //
  //    mpv 壳的清理改由 runner/main.cc 的信号处理路径完成：
  //    收到 SIGTERM/SIGINT → 主循环里 hein_mpv_shutdown() → _exit(0)。
  //    这样清理真实发生，且不与引擎拆除交叉。
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

// 🔴🔴🔴 2026-10-26 游戏模式（gamescope）下**完全无法播放** —— 根因修复。
//
// 【现象】Bazzite 掌机游戏模式里点播放无画面（桌面模式正常）。
//   日志：init 返回 {ok:false, textureId:0}；native 侧
//         「eglGetPlatformDisplayEXT 未取到 surface/device 平台」
//         「eglMakeCurrent 失败 0x3002」⇒ mpv 壳的 EGL 上下文建不起来。
//
// 【根因】mpv 壳走**纹理共享**路线：它用 `eglGetCurrentContext()` 取
//   「当前线程上 current 的 EGL 上下文」当作 Flutter 的渲染上下文来共享。
//   · 桌面模式（GNOME **Wayland**）⇒ GTK3 的 Wayland 后端**必然**用 EGL
//     ⇒ `eglGetCurrentContext()` 有效 ⇒ 共享成功 ⇒ 能出画。
//   · 游戏模式 ⇒ 合成器同样是 gamescope（**Wayland**），但**启动器没有把
//     `WAYLAND_DISPLAY` 注入进程环境**（2026-10-27 实测 Steam 主进程环境里
//     该变量不存在，只有 `GAMESCOPE_WAYLAND_DISPLAY=gamescope-0` 和
//     `DISPLAY=:0`）⇒ GTK3 只能走 X11 后端（boot.log 实测
//     `GDK display=GdkX11Display`）⇒ X11 后端默认用 **GLX**
//     ⇒ `eglGetCurrentContext()` 返回 **EGL_NO_CONTEXT** ⇒ 拿不到可共享的
//     上下文 ⇒ 壳上下文创建失败 ⇒ textureId=0 ⇒ 无画面。
//
//   ⚠️ 关键区分：「游戏模式不是 X11」——它的合成器是 Wayland；
//     是**我们的进程被 GTK 用 X11 后端接管了**。这两件事完全不同。
//
// 【真机实测】（69 掌机，2026-10-26，GTK3 3.24.52 + Mesa 26.2.4）
//   环境                          eglGetCurrentContext()
//   X11 后端（游戏模式默认走这条）  NULL   ← 故障态
//   X11 + GDK_GL=egl              NULL   ← Fedora 的 GTK3 未编入 X11-EGL，无效
//   Wayland gamescope-0           非 NULL ← 唯一可行
//
// 【2026-10-26 16:20 补充：为什么 X11 一定是坏的（用回溯 + 最小复现查实）】
//   ⚠️ 上面「eglGetCurrentContext()=NULL ⇒ 拿不到可共享上下文」只是**表象**。
//   真正的机理是 **EGL 与 GLX 在同一 X display 上互斥**：
//     · 引擎的资源/采样上下文恒为 **EGL**（fl_opengl_manager.cc）；
//     · 引擎的**画面合成**用 GTK3 的 GdkGLContext ⇒ X11 下是 **GLX**
//       （fl_view_renderer.cc，且 shareable=GDK_IS_WAYLAND_DISPLAY ⇒ X11 为 FALSE，
//         于是走 CPU 拷贝分支 glReadPixels → gdk_cairo_draw_from_gl）；
//     · 真机最小复现（/tmp/eglx11b，69 掌机 gamescope :1）：
//         eglMakeCurrent(pbuffer)=1 → 紧接着 glXMakeCurrent 报
//         **BadAccess (X_GLXMakeCurrent)**；同样代码在桌面 :0 完全正常。
//   ⇒ 一旦我们（mpv 壳）在 X11 会话里 makeCurrent 一个 EGL 上下文，
//     GTK3 的 GLX 上下文就被破坏 → gdk_cairo_draw_from_gl 拿到失效上下文
//     → **SIGSEGV**（真机回溯：gdk_cairo_draw_from_gl ← libflutter_linux_gtk.so）。
//
// 【修法】游戏模式且尚未设置 WAYLAND_DISPLAY 时，主动切到 gamescope 的
//   Wayland（`GAMESCOPE_WAYLAND_DISPLAY` 指向的 socket）⇒ GTK3 走 Wayland
//   后端 ⇒ 必然用 EGL ⇒ 与桌面模式**同一条**可用的纹理共享路径。
//
//   · 设 `WAYLAND_DISPLAY` + `GDK_BACKEND=wayland`（并清掉 `DISPLAY`），
//     确保 GTK3 真的走 Wayland/EGL（否则它可能仍选 X11 ⇒ 等于没切）。
//   · 非游戏模式（桌面/Windows/其他 Linux 发行）**完全不动**。
//   · 必须确认 socket 真实存在才切，避免把应用推向打不开的 Wayland。
//   · 本函数在 `my_application_new()` 里调用，早于 `g_application_run`
//     ⇒ 早于 GTK 打开 display ⇒ 环境变量一定生效。
static void hein_force_gamescope_wayland() {
  // ================= 2026-10-27 22:55 最终定论（真机实测，推翻上一版）=====
  //
  // 🔴🔴🔴 **不再切 Wayland。游戏模式必须留在 X11。**
  //
  // 【上一版的错误】上一版让游戏模式默认强制切到 gamescope 的 Wayland，
  //   依据是「X11 后端只有 GLX ⇒ mpv 建不了 EGL ⇒ 能进不能播」。
  //   这一步确实让 mpv 的 EGL 上下文建起来了（native 日志不再跳过初始化），
  //   但**代价是画面彻底上不了屏**——用户报「软件根本没有显示画面」。
  //
  // 【为什么切 Wayland 一定没画面（本次真机取证，证据确凿）】
  //   1) 本机 gamescope 是 3.16.31-ogc6+，启动参数里**没有 `--expose-wayland`**：
  //        /usr/bin/gamescope --touch-gestures --prefer-output *,eDP-1
  //          --xwayland-count 2 --default-touch-mode 4 ... --steam
  //      而 `--expose-wayland` 的帮助文本就是
  //        "support wayland clients using xdg-shell"
  //      ⇒ **Wayland 原生客户端支持是关闭的**。
  //      二进制里还留着 "Closing Wayland windows not supported yet."
  //      ⇒ 对 Wayland 窗口的管理本就不完整。
  //   2) gamescope 的焦点/合成体系走 XWM（X11 window manager），
  //      实测 `stats.pipe` 连续采样恒为 `focus=steam`：
  //        · 我们的窗口确实建成了（boot.log: 1920x1080 bounds=(0,0,1920,1080)）
  //        · 首帧确实画出来了（boot.log: `stage: 收到 first-frame`）
  //        · UI 确实在跑（tick=1..8）、网络 200
  //        · `ss -x` 确认已连上 /run/user/1000/gamescope-0
  //      但 **focus 永远是 steam**，我们的 Wayland surface 永远不被合成上屏。
  //   3) 佐证：同一会话里 Steam 界面本身走的是 Xwayland :1
  //      （/tmp/.X11-unix/X1 存在，25 个 X 客户端连接）——
  //      gamescope 上能显示的窗口**都是 X11 客户端**。
  //
  // 【结论】在「gamescope 未开 --expose-wayland」的机器上，
  //   「GTK 走 Wayland（才能共享 EGL 出画）」与「窗口能被 gamescope 合成
  //   上屏」是**互斥**的。必须回到 X11，改用**不需要 GL 共享**的视频路径：
  //     mpv `MPV_RENDER_API_TYPE_SW` 软件渲染 → CPU RGBA 缓冲
  //     → Flutter `FlPixelBufferTexture`（copy_pixels 回调）→ 上屏。
  //   这条路径完全不碰 EGL/GLX 共享，因此在 X11 下安全，
  //   也解释了为什么必须放弃「切 Wayland」这个方案。
  //
  // 【保留本函数】仅作诊断开关：设 `HEIN_GAMESCOPE_WAYLAND=1` 可强行切回
  //   Wayland（用于验证上述结论 / 将来 gamescope 开启 --expose-wayland 后复测）。
  //   默认**不做任何切换**。
  const gchar* optin = g_getenv("HEIN_GAMESCOPE_WAYLAND");
  if (optin == nullptr || g_strcmp0(optin, "1") != 0) {
    hein_log_to_file("INFO",
                     "游戏模式保持 X11 后端（gamescope 未开 --expose-wayland，"
                     "Wayland 窗口不会被合成上屏）；视频走 SW 渲染 + "
                     "FlPixelBufferTexture");
    return;
  }
  g_print("HeinPlayRunner: HEIN_GAMESCOPE_WAYLAND=1，强制切 Wayland（仅诊断用）\n");

  // ⚠️ 判据必须**收紧**：桌面模式下 Steam 常驻时 gamescope 的 socket 也会存在，
  //   若只看 socket 就切换，会把**普通桌面**下的应用也拽进 gamescope 里
  //   （桌面模式若是 X11 且 WAYLAND_DISPLAY 为空，就会被误切）。
  //   ⇒ 必须同时满足「确实是游戏模式会话」+「有 gamescope 的 Wayland 名」+
  //     「当前还没在用 Wayland」+「socket 真实存在」。
  //   判据与 Dart 侧 [DeviceUtils.isSteamGameMode] 保持一致
  //   （XDG_CURRENT_DESKTOP 含 gamescope，或 SteamGamepadUI=1）。
  const gchar* gs = g_getenv("GAMESCOPE_WAYLAND_DISPLAY");
  if (gs == nullptr || *gs == '\0') return;  // 没有 gamescope 的 Wayland ⇒ 不动
  const gchar* desktop = g_getenv("XDG_CURRENT_DESKTOP");
  const gchar* gamepad_ui = g_getenv("SteamGamepadUI");
  gboolean desktop_is_gamescope = FALSE;
  if (desktop != nullptr && *desktop != '\0') {
    g_autofree gchar* lower = g_ascii_strdown(desktop, -1);
    desktop_is_gamescope = (strstr(lower, "gamescope") != nullptr);
  }
  const gboolean in_game_session =
      desktop_is_gamescope ||
      (gamepad_ui != nullptr && g_strcmp0(gamepad_ui, "1") == 0);
  if (!in_game_session) return;  // 不是游戏模式会话 ⇒ 桌面模式完全不动
  const gchar* wd = g_getenv("WAYLAND_DISPLAY");
  if (wd != nullptr && *wd != '\0') return;  // 已在用 Wayland ⇒ 不动
  const gchar* rt = g_getenv("XDG_RUNTIME_DIR");
  if (rt == nullptr || *rt == '\0') return;

  g_autofree gchar* sock = g_build_filename(rt, gs, nullptr);
  if (g_file_test(sock, G_FILE_TEST_EXISTS) == FALSE) {
    g_print("HeinPlayRunner: gamescope Wayland socket 不存在，跳过切换: %s\n",
            sock);
    return;
  }

  g_setenv("WAYLAND_DISPLAY", gs, TRUE);
  // 🔴🔴🔴 2026-10-26：必须同时**清掉 DISPLAY**。
  //   否则 GTK3 在 Wayland 与 X11 两个 display 都可用时，可能仍选 X11
  //   （GDK 选后端的顺序受 GDK_BACKEND / DISPLAY / WAYLAND_DISPLAY 共同影响），
  //   那样就等于没切换。
  //   ⚠️ 但 DISPLAY 是 Steam/gamescope 用来做 XWayland 的环境变量，
  //     清掉它会影响「同一会话里还能否访问 X11 客户端」——
  //     对本应用无影响（我们只用 Wayland）。
  g_unsetenv("DISPLAY");
  // 🔴 明确指定 GDK_BACKEND=wayland，确保 GTK3 走 Wayland 后端（⇒ EGL）。
  //   这一步是**必需**的：GTK3 的 X11 后端只有 GLX 实现，
  //   而 GLX 与 EGL 在同一个 X display 上会互相破坏（见下方说明）。
  g_setenv("GDK_BACKEND", "wayland", TRUE);
  g_print("HeinPlayRunner: 检测到 gamescope，已切换到 Wayland "
          "(WAYLAND_DISPLAY=%s, GDK_BACKEND=wayland)\n",
          gs);
  hein_log_to_file("INFO",
                   "检测到 gamescope，已切换到 Wayland (WAYLAND_DISPLAY=%s, "
                   "socket=%s, GDK_BACKEND=wayland)",
                   gs, sock);
}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  // 🔴 必须在 GTK 打开 display 之前完成（Wayland/X11 后端与 GL 实现由此决定）。
  //
  // ============ 现状（2026-10-27 修订，覆盖此前所有相反结论）============
  //
  // 【用户明确纠正的事实】Bazzite 掌机**桌面模式与游戏模式都是 Wayland**。
  //   游戏模式 = gamescope 会话，其内部虽跑 Xwayland，但**合成器本身是
  //   Wayland**。桌面模式能正常出画，走的正是 GTK Wayland + EGL。
  //   ⇒ 因此「回退到 X11 路线」是**错误方向**，此前基于该假设的改动已废弃。
  //
  // 【历史根因（仍然成立）】Flutter 引擎在 Linux 恒用 EGL；而引擎的画面
  //   合成走 GTK3 的 GdkGLContext —— GTK3 在 X11 下是 **GLX**、Wayland 下是
  //   **EGL**。若应用被 X11 后端接管，就变成「EGL 资源 + GLX 视图」混用：
  //     · shareable = GDK_IS_WAYLAND_DISPLAY(...) ⇒ X11 下为 FALSE；
  //     · 引擎走 CPU 拷贝分支，调用 gdk_cairo_draw_from_gl()（GLX）；
  //     · EGL 与 GLX 在同一 X display 上互相破坏 ⇒ glXMakeCurrent 报
  //       BadAccess ⇒ gdk_cairo_draw_from_gl SIGSEGV。
  //
  // 【当前策略】`hein_force_gamescope_wayland()` **默认不做任何切换**
  //   （需 `HEIN_GAMESCOPE_WAYLAND=1` 才启用）。原因：
  //     · 游戏模式实测 `WAYLAND_DISPLAY=gamescope-0` **本来就有效**，
  //       原函数里「WAYLAND_DISPLAY 为空才切」的守卫在游戏模式下**命不中**
  //       ⇒ 那次强制切换其实是**冗余**的，并非「进不了软件」的真正引入点；
  //     · 在未查清真正根因前，贸然改动后端选择只会引入新的不确定性。
  hein_force_gamescope_wayland();
  hein_boot_log("stage: hein_force_gamescope_wayland() 返回");

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
