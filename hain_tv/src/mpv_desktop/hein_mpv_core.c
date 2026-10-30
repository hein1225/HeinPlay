// 桌面 mpv 壳 · 播放器核心。
//
// 【定位】官方 libmpv 内核 + 本壳（与 Android/鸿蒙同源的四层外壳思路：
//   mpv_backend.dart → 本壳（Linux: fl_method_channel / Windows: MethodChannel）
//   → libmpv.so/libmpv-2.dll（官方内核）。
//   不依赖 media_kit / fvp / vlc。）
//
// 【必须移植的教训（来自 Android 侧 MpvPlayerView + 本轮 PTS 修复）】
//   ① 音画同步：video-sync=audio + max-video-change=1.0 + profile=fast +
//      interpolation=no + framedrop=yes。鸿蒙已验证，Android 曾因
//      display-resample 出现「先冻住画面→再快放」。
//   ② 渲染路线（vo/gpu-api）必须在 mpv_initialize() **之前** setOption，
//      之后 setProperty 只改属性不重建 VO = 没生效。
//   ③ 起播定位：open 时把 startAt 以 mpv 的 start= 选项传入，在加载时即定位，
//      规避「空 buffer 下丢 seek」。
//   ④ file-loaded 事件 → **立即 seek**（不等 time-pos），否则起播定位被推迟。
//   ⑤ 首帧后才注册纹理；尺寸变化必须重建 FBO。
//   ⑥ 日志节流会制造稀疏假象，本壳所有日志**不加节流**。
//   ⑦ PTS 归一化/三态探测在 Dart 侧（local_m3u8_proxy + ad_filter_engine），
//      跨平台共用，壳无需重复实现；壳只负责如实回传 time-pos/duration。

// 🔴 必须最先定义：pthread_timedjoin_np 是 GNU 扩展，只在 _GNU_SOURCE
//    下声明（否则编译报 implicit function declaration）。必须在任何
//    系统头之前定义，故放在文件最顶部。
// ⚠️ 仅 Linux：Windows 侧没有 pthread，定义 _GNU_SOURCE 无意义且 mingw 的
//    unistd.h 也不存在（会把整个编译搞垮）。
#ifndef _WIN32
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#endif

#include <stdbool.h>
#include <stdarg.h>
#ifndef _WIN32
#include <pthread.h>
#include <unistd.h>   // getpid / fsync；Windows 用 _getpid / _commit
#else
#include <io.h>       // _commit / _fileno（Windows 版 fsync）
#include <process.h>  // _getpid
#endif
#include <time.h>
#include <errno.h>
#include <locale.h>
#include <string.h>
#include <stddef.h>
#include <stdio.h>

#include <mpv/client.h>
#include <mpv/render.h>
// render_gl.h 只有 Linux（GL render API）用；Windows 走 D3D11 render API，
// 且该头在 Windows 上 include 会拉 GL 类型、与「已删光 GL」的架构冲突。
#ifndef _WIN32
#include <mpv/render_gl.h>
#endif

// 平台头统一由「插件文件」经 umbrella 头引入：
//   Linux   → hein_mpv_linux_plugin.c   include <flutter_linux/flutter_linux.h>
//   Windows → hein_mpv_windows_plugin.cpp include <flutter_windows/flutter_windows.h>
// 本文件只依赖 GL/epoxy 与自有的 hein_gl_texture.h。
// ⚠️ Flutter Linux 的各子头（fl_method_channel.h 等）**禁止直接 include**，
//    它们内部有 #error 守卫，只能经 umbrella 头进入。
// 🔴 平台判定用 _WIN32（Windows 上 MSVC/MinGW 必定定义），不用 __linux__：
//    后者在 Linux 上的 g++ 会自动定义，导致「在 Linux 上交叉检查 Windows 代码」
//    时误走 Linux 分支。
#ifndef _WIN32
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <epoxy/glx.h>
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
// 🔴 2026-10-26：需要 gdk_wayland_display_get_wl_display()，
//   让壳按 GDK 后端取对应的 EGL platform（与引擎 fl_opengl_manager.cc 一致）。
//   ⚠️ gdkwayland.h 需要 wayland-client 的类型（struct wl_display），
//      GTK3 的 pkg-config 已经带出 wayland-client 头路径。
#ifdef GDK_WINDOWING_WAYLAND
#include <gdk/gdkwayland.h>
#endif
#include "hein_gl_texture.h"
// 🔴 GLX 上下文管理（X11 会话 / gamescope 游戏模式）。见 hein_glx.h 的说明。
#include "hein_glx.h"
// 🔴🔴 2026-10-27 23:05：SW 软件渲染纹理（X11 / gamescope 游戏模式）。
//   gamescope 未开 --expose-wayland ⇒ GTK 必须留在 X11；GTK3 的 X11 后端
//   只有 GLX，与引擎的 EGL 在同一 X display 上互斥 ⇒ 不能共享 GL 上下文。
//   改用「mpv SW 渲染 → CPU RGBA → FlPixelBufferTexture」，全程零 GL 上下文。
#include "hein_sw_texture.h"
#else
#include <windows.h>
#include <libloaderapi.h>
// 🔴 2026-10-21 Windows 走 D3D11 render API（步骤0 实测 libmpv-2.dll 支持），
//    整条 WGL/GL 函数指针链路已删除。核心差异：
//      Linux   : epoxy/EGL + GL 外部纹理（hein_gl_texture.c）
//      Windows : D3D11 render API + D3D11 外部纹理（hein_win_texture.cpp）
//    本文件在 Windows 下不再需要任何 GL 头。
//
// flutter_windows.h 只带了 messenger / plugin_registrar，纹理注册器在
// flutter_texture_registrar.h，必须显式引。
// ⚠️ 不要 include <flutter_windows/flutter_windows_texture_registrar.h>——
//    那是引擎**内部头**，SDK 里根本没有，会直接编译失败。
// 🔴 2026-10-22：Flutter **发行版 SDK** 的头是「扁平」的 C 头，全部位于
//    windows/flutter/ephemeral/ 下（由 flutter tool 每次构建时铺好）：
//        flutter_windows.h / flutter_texture_registrar.h /
//        flutter_messenger.h / flutter_plugin_registrar.h
//    上面那条「引擎源码树」路径（flutter/shell/platform/.../public/...）
//    只存在于 SDK 的源码 checkout 里，发行版 zip 里根本没有 → MSVC 报
//    C1083: 无法打开包括文件。
//    include 目录由 CMake 的 flutter_wrapper_plugin target 带进来
//    （它 PUBLIC 链了 flutter INTERFACE target，后者带 ${EPHEMERAL_DIR}）。
#include "flutter_windows.h"
#include "flutter_texture_registrar.h"
#include "flutter_messenger.h"
#include "flutter_plugin_registrar.h"

// ---- GLib 兼容层（P0-2 / P0-4：Windows 无 GLib，不能链它）----
//
// core.c 为跨平台共用，历史上有少量 GLib 调用散落在共用代码里
// （g_getenv / g_strcmp0 / g_strdup / g_strstrip / g_free）。
// Windows 侧不引入 pthreads-win32 + GLib 兼容库（徒增依赖、交接文档明确
// 不推荐），改为在此提供**语义等价**的极简实现：
//   · g_getenv      → GetEnvironmentVariableA（长度 0 视为未设置）
//   · g_strcmp0     → strcmp，但 NULL 安全（NULL 与 NULL 相等，NULL 最小）
//   · g_strdup      → strdup（MSVCRT 提供；此处手写以免 _CRT_NONSTDC 告警）
//   · g_strstrip    → 去除首尾空白（原 g_strstrip 就地修改并返回首指针）
//   · g_free        → free
// 只覆盖壳实际用到的这几个，别的一律不要。
// g_getenv 返回「指向静态缓冲的指针」：调用方只读不写、且不跨调用保留，
// 壳里两处用法（HEIN_MPV_LOG）都满足。用环形缓冲避免相邻两次调用
// 互相覆盖（多个 env 交替读取时）。
static char *hein_g_getenv(const char *name) {
  static char ring[4][512];
  static int slot = 0;
  char *out = ring[slot];
  slot = (slot + 1) % 4;
  DWORD n = GetEnvironmentVariableA(name, out, 512);
  if (n == 0 || n >= 512) return NULL;
  return out;
}
#define g_getenv(n) hein_g_getenv(n)

static inline int hein_g_strcmp0(const char *a, const char *b) {
  if (a == b) return 0;      // 同指针或同为 NULL
  if (a == NULL) return -1;  // NULL 小于任何非 NULL（GLib 语义）
  if (b == NULL) return 1;
  return strcmp(a, b);
}
#define g_strcmp0(a, b) hein_g_strcmp0((a), (b))

static inline char *hein_g_strdup(const char *s) {
  if (s == NULL) return NULL;
  size_t n = strlen(s) + 1;
  char *p = (char *)malloc(n);
  if (p != NULL) memcpy(p, s, n);
  return p;
}
#define g_strdup(s) hein_g_strdup(s)

// g_strstrip：就地去除首尾空白（空格/制表/换行），返回新的首指针。
static inline char *hein_g_strstrip(char *s) {
  if (s == NULL) return NULL;
  while (*s == ' ' || *s == '\t' || *s == '\n' || *s == '\r') s++;
  if (*s == '\0') return s;
  char *e = s + strlen(s) - 1;
  while (e > s && (*e == ' ' || *e == '\t' || *e == '\n' || *e == '\r')) {
    *e = '\0';
    e--;
  }
  return s;
}
#define g_strstrip(s) hein_g_strstrip(s)

#define g_free(p) free((void *)(p))

// ---- GLib 基础类型兼容（Windows 无 GLib）----
// 共用代码里用到 gchar / gint / guint / gboolean / gint64 / guint64 / gpointer，
// 全部在这里给出等价 typedef（语义与 GLib 一致，不引入 GLib 运行时）。
typedef char gchar;
typedef int gint;
typedef unsigned int guint;
typedef int gboolean;
typedef long long gint64;
typedef unsigned long long guint64;
typedef void *gpointer;
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif
#endif

// Windows 侧本文件被 hein_mpv_windows_plugin.cpp 以 #include 方式编入
// **C++ 编译单元**。所有对外函数必须 extern "C"：否则 C++ 会修饰名字，
// 插件层虽同为 C++ 能链接，但与我们经 Flutter C API 交互的符号约定不符。
#ifdef __cplusplus
extern "C" {
#endif

// ============================ 前向声明 ============================
//
// 这些函数定义在文件后段，但 Windows 初始化段（hein_mpv_init_windows）
// 与 Linux 段都要用到，故在此前置声明，避免「未声明」错误。
// ⚠️ 全部 extern "C"（本文件在 Windows 下被 .cpp 以 C++ 编入），且
//    **不能用 GLib 类型**（gboolean/gpointer/guint）——Windows 没有 GLib。
#ifndef _WIN32
static void *hein_get_proc_address(void *ctx, const char *name);
// 自检定时器回调定义在「帧渲染」段，但 init_linux 里就要用，故前置声明。
static gboolean hein_selftest_tick(gpointer data);
#endif
static void on_mpv_render(void *ctx);
int hein_mpv_open(const char *url, double start_sec, bool is_live,
                  bool hardware_decoding, int cache_secs);
// 🔴 2026-10-26：延迟 loadfile 的补发入口（定义在 open 之后，阶段②里要用）。
int hein_mpv_open_internal(const char *url, double start_sec, bool is_live,
                           bool hardware_decoding, int cache_secs);
static bool hein_ensure_render_context_locked(void);
// 🔴 2026-10-22：hein_log 必须是**全局**符号（不能 static）。
//   hein_win_texture.cpp 是独立编译单元（CMake 里单列），它要调用 hein_log；
//   static 会让符号变成内部链接，另一个单元解析不到 → 链接期
//   "undefined reference to hein_log"。
//   注意本文件在 Windows 下被 .cpp 以 #include 编入，故本声明落在上面的
//   extern "C" 块内 → C 链接约定；hein_win_texture.cpp 侧也必须用
//   extern "C" 声明，否则 C++ 修饰名对不上，同样链接失败。
void hein_log(const char *fmt, ...);
static void *hein_event_thread(void *arg);
#ifdef _WIN32
static DWORD WINAPI hein_event_thread_proc(LPVOID arg);
#endif
#ifndef _WIN32
// 🔴 2026-10-22：仅 Linux 使用。Windows 走 D3D11 路线，帧驱动是
//    hein_mpv_pump_windows()，本函数在 Windows 下无调用点，
//    保留会让编译器报「defined but not used」。
bool hein_mpv_render_to_fbo(void);
// SW 独立渲染线程（Linux，见定义处注释）。需在 init 之前声明。
static bool hein_mpv_render_sw(void);
static void hein_sw_render_thread_start(void);
static void hein_sw_render_thread_stop(void);
static void hein_sw_render_thread_wake(void);
// 🔴 2026-10-26：像素级出画自检（定义在渲染函数之后）。
static void hein_pixel_check_once(void);
#endif
void hein_mpv_request_frame(void);
double hein_mpv_get_double(const char *name, double defval);
bool hein_mpv_pump_windows(void);

// ============================ 状态 ============================
//
// 属性上推钩子：由平台插件层赋值（Linux/Windows 各自实现），
// core.c 只负责在 mpv 事件里调用它。这样 core.c 不依赖任何平台 API。
static void (*g_push_property_hook)(const char *name, double value) = NULL;

void hein_mpv_set_push_hook(void (*fn)(const char *, double)) {
  g_push_property_hook = fn;
}

static void hein_mpv_push_property(const char *name, double value) {
  if (g_push_property_hook != NULL) g_push_property_hook(name, value);
}


typedef struct {
  mpv_handle *mpv;
  mpv_render_context *mpv_gl;

#ifndef _WIN32
  // 🔴 壳自建的 EGL 上下文（不依赖 Flutter 的，见 hein_create_egl_context）。
  EGLDisplay egl_display;
  EGLContext egl_context;
  EGLSurface egl_surface;
  // 建壳上下文时用的 share 对象（EGL_NO_CONTEXT 表示未共享）。
  // 用于判定「是否已与 Flutter 共享」，以及 populate 捕获到真实上下文后
  // 判断是否需要重建。
  EGLContext egl_share_context;
  // populate 捕获到的 Flutter 真实上下文（raster 线程写入）。
  EGLContext flutter_egl_context;
  EGLDisplay flutter_egl_display;
  // 🔴 2026-10-26：X11 会话下**不做视频**（EGL 会破坏 GTK3 的 GLX ⇒ 引擎崩溃）。
  gboolean x11_no_video;
  // 🔴🔴🔴 2026-10-27 23:05：**SW 软件渲染模式**。
  //   置 TRUE 时完全不建 GL 上下文，改用 mpv MPV_RENDER_API_TYPE_SW 渲染到
  //   CPU 内存，再经 FlPixelBufferTexture 交给 Flutter。
  //   用于「GTK 必须留在 X11（gamescope 未开 --expose-wayland）但又要出画面」
  //   的场景 —— X11 下 EGL/GLX 互斥，共享 GL 上下文这条路走不通。
  gboolean sw_mode;
  struct _HeinSwTexture *sw_texture;
  void *mpv_sw;  // mpv_render_context*（SW 模式专用，避免头文件顺序依赖）
  uint8_t *sw_buf;   // 当前帧 RGBA 缓冲
  size_t sw_buf_size;
  int sw_w;
  int sw_h;
  // 🔴🔴 2026-10-27：SW 渲染必须跑在**独立线程**，不能占 GTK 主线程。
  //   真机实测仅约 18fps 且越播越慢，但基准测试（ffmpeg 全路径模拟
  //   解码+缩放+转 rgb0）证明纯算力有 13.6x 实时余量、带宽仅 0.27GiB/s
  //   ⇒ 瓶颈不是 CPU，而是 mpv_render_context_render() 默认会**阻塞到
  //   该帧应显示的时刻**（render.h 的 BLOCK_FOR_TARGET_TIME 默认行为）。
  //   该阻塞落在主线程上会冻结 UI 与 16ms 定时器 → 请求积压 → 越来越慢。
  //   与 Windows 侧 hein_render_thread_proc 同构：渲染在专用线程做，
  //   主线程只负责唤醒。
  GThread *sw_thread;
  GMutex sw_mutex;
  GCond sw_cond;
  bool sw_thread_quit;
  bool sw_thread_wake;
  bool sw_thread_started;
  volatile gint flutter_ctx_captured;  // 1=已捕获，待主线程处理
  bool share_rebuild_done;             // 主线程已完成共享上下文创建
  // 阶段②创建的共享上下文（与 Flutter 共享纹理命名空间）。
  // 渲染时优先用这一套；为空则回退到阶段①的 egl_*（不共享，仅自检可用）。
  EGLDisplay share_egl_display;
  EGLContext share_egl_context;
  EGLSurface share_egl_surface;
  // 🔴🔴 2026-10-26 GLX 后端（X11 会话 / gamescope 游戏模式）。
  //   Wayland 会话下 Flutter 用 EGL/GLES2（上面那套），
  //   X11 会话下 Flutter 用 GLX/桌面GL ⇒ 必须整套换掉，
  //   因为 Mesa **不支持 GLX 与 EGL 之间的纹理共享**。
  HeinGLXHandle glx_stage1;    // 阶段①：壳自己的 GLX 上下文（不共享）
  HeinGLXHandle glx_stage2;    // 阶段②：与 Flutter 共享的 GLX 上下文
  GLXContext flutter_glx_context;  // populate 捕获到的 Flutter GLX 上下文
  Display *flutter_glx_display;    // Flutter 的 X 连接（GDK 那条）
  FlTextureRegistrar *texture_registrar;
  HeinGLTexture *gl_texture;
  gint64 registered_texture_id;
  FlMethodChannel *channel;
  FlEventChannel *event_channel;
  FlPluginRegistrar *registrar;
#else
  FlutterDesktopEngineRef engine;
  FlutterDesktopTextureRegistrarRef texture_registrar;
  // 纹理 id（与 Linux 侧 FL_TEXTURE id 同义，Windows 由 D3D11 外部纹理持有）
  int64_t registered_texture_id;
  FlutterDesktopTextureRegistrarRef win_texture_registrar;
  void *win_texture;  // HeinWinTexture*（不透明，避免此处依赖 C++ 头）
  FlutterDesktopMessengerRef messenger;
  // Windows 侧渲染驱动（P0-1 修复）：独立渲染线程 + 事件对象。
  // mpv 的 update 回调跑在它自己的线程，GL/D3D 调用必须在**固定线程**
  // 上做（上下文归该线程），故不能复用主线程。
  HANDLE render_thread;      // CreateThread 句柄
  HANDLE render_wake_event;  // mpv 报告新帧时 SetEvent
  volatile LONG render_thread_running;  // 1=运行中（退出时清零）
  // D3D11 render API 的渲染目标尺寸（与纹理同步）。
  int d3d_w;
  int d3d_h;
  // 诊断：渲染帧计数 / 上报帧计数（出画判据用，见交接文档第六节）。
  volatile LONG render_frame_count;
  volatile LONG populate_count;
#endif

  bool initialized;
  bool disposed;
#ifdef _WIN32
  // Windows 用 Win32 线程句柄（不用 pthread，见 P0-4 修复）。
  HANDLE event_thread;
#else
  pthread_t event_thread;
#endif
  bool event_thread_started;
  bool pending_seek_pending;  // 有待执行的起播定位
  double pending_seek_sec;
  // 🔴🔴🔴 2026-10-26「全黑有声音」根治：延迟到共享上下文建好再 loadfile。
  //
  //   mpv 的 render context 一旦创建，就在**创建时的那个 GL 上下文**里
  //   持有 VAO / buffer / shader / 内部 FBO。其中 **VAO 是 OpenGL 唯一
  //   不跨上下文共享的对象**（texture/buffer/shader/FBO 可共享，VAO 不行），
  //   且 mpv 的内部纹理也只在同一 share group 内有效。
  //
  //   旧实现：init 时先用**未共享**的壳上下文 A 建 render context
  //   （为了满足 vo_libmpv 的「loadfile 前必须有 render context」），
  //   等 populate 捕获 Flutter 上下文后再建共享上下文 B 去渲染。
  //   ⇒ A 与 B 不共享 ⇒ 阶段②之后 mpv 所有 GL 资源在 B 中失效
  //   ⇒ draw 全部静默失败 ⇒ **FBO 恒黑、但音频正常**。
  //   真机日志铁证（69，2026-10-26 18:10）：
  //     阶段①：render context 已创建（壳上下文 A，未共享）
  //     像素自检：127.44 ⇒ 画面有效        ← 在 A 里画，正常
  //     阶段②：共享壳上下文创建成功
  //     阶段②完成：纹理已在新上下文中重建
  //     像素自检：0.00 ⇒ 全黑              ← 切到 B，mpv 资源全失效
  //   （同一环境下旧交付包同样全黑，证明与打包/libva/ffmpeg 无关。）
  //
  //   正解：**只在最终要渲染的共享上下文里建一次 render context**。
  //   mpv 在 render context 建好前允许 mpv_initialize 与属性设置，
  //   只是不能 loadfile（vo_libmpv preinit 会报 "No render context set."）。
  //   故把 loadfile 推迟：open 时只暂存参数，等 render context 就绪后补发。
  gchar *deferred_url;      // 待加载的 URL（render context 就绪后补发）
  double deferred_start_sec;
  bool deferred_is_live;
  bool deferred_hwdec;
  int deferred_cache_secs;
  bool first_frame_emitted;
  bool has_new_frame;   // mpv 报告有新帧待渲染
  bool render_pending;  // 已有一个渲染请求排队在主线程
  // 播放失败（END_FILE/ERROR）后暂停渲染驱动，避免空转吃满 CPU 拖垮主线程。
  // 每次 hein_mpv_open 会清零恢复。
  // 播放失败（END_FILE/ERROR）后暂停渲染驱动。
  // ⚠️ Windows 无 GLib，故按平台选类型；访问统一走宏（见下方 HEIN_SUSPEND_*）。
#ifdef _WIN32
  volatile LONG render_suspended;
#else
  volatile gint render_suspended;
#endif

  // 用户最近一次请求的播放位置（用于起播定位与 seek 后的验证）
  double last_requested_sec;

  // 🔴🔴 2026-10-21 画面比例根因（架构层）：
  //    FBO 尺寸原取自 video-out-params（= 视频自身尺寸，如 1920x818），
  //    于是 mpv 渲染出来的画面**刚好就是视频原始比例、没有黑边**；
  //    Flutter 再把这块纹理拉伸铺满 1080x1920 的竖屏 → 比例被压扁。
  //    此时 keepaspect/panscan 在 mpv 内部毫无作用（FBO 就是视频尺寸）。
  //
  //    Android 侧之所以正常：mpv 渲染进**全屏 Surface**，由 mpv 在全屏
  //    尺寸内按 video-params 做 letterbox（黑边），SurfaceView 直出不再缩放。
  //
  //    桌面壳要等价，必须让 FBO 尺寸 = **视频层控件尺寸**（Dart 上报），
  //    mpv 在这个尺寸里自行 letterbox。故新增 view_w/view_h。
  int view_w;
  int view_h;

  // 🔴🔴 2026-10-21 「幻灯片 / 直播卡死」根因修复（69 真机实证）。
  //
  //    上一版为解决点播闪烁，在 GTK 主线程的渲染路径末尾直接调 glFinish()。
  //    实测日志（hein_native.log）：
  //      渲染帧 #1381(21:36:42) → #2041(21:37:08)  660 帧 / 26s ≈ 25fps
  //      populate #480(21:36:45) → #600(21:37:04)  120 次 / 19s ≈ 6fps
  //    壳按 25fps 出帧，Flutter 只以 6fps 来采样 → 用户看到「幻灯片」。
  //
  //    glFinish() 是**同步**等待：它阻塞调用线程直到 GPU 把该上下文所有命令
  //    执行完。而 Linux 上 Flutter 的 **platform 线程就是 GTK 主线程**，
  //    渲染 tick 跑在主线程上 → 每帧都阻塞主线程 30~40ms（2880x1526 的
  //    FBO，AMD 890M）→ 主线程饱和 → 三个连锁症状：
  //      ① Flutter 平台线程得不到调度 → 只有 6fps 采样 → 幻灯片
  //      ② mpv 的音频输出（PulseAudio）主循环跑不动 → 直播无声
  //      ③ 某帧 glFinish 再也不返回 → 整个软件冻死（21:37:09 冻结）
  //
  //    正确做法：用 glFenceSync 在 GPU 上插围栏，**不阻塞 CPU**。
  //    双缓冲：渲染写 buf[write]，Flutter 采 buf[read]，采样前在 Flutter
  //    的上下文里 glWaitSync 等围栏，交换索引。这样 CPU 立即返回，
  //    GPU 侧仍保证「写完才被采样」。
  //
  //    为把改动控制在不破坏现有单纹理链路的范围，这里先采用最小侵入方案：
  //    **异步围栏 + 延迟一帧提交**（见 hein_mpv_render_to_fbo 注释）。
#ifndef _WIN32
  // GL 围栏三件套（Linux 专用）：D3D11 路线不需要，且 GLsync 类型在
  // Windows 上根本不存在（无 GL 头）。
  GLsync frame_fence;      // 上一帧渲染完成后插入的围栏（0 = 无）
  bool fence_pending;      // 有围栏待 Flutter 侧等待/回收
#endif
  int  dropped_frames;     // 因上一帧未被消费而丢弃的帧数（诊断用）
} HeinMpv;

static HeinMpv g_mpv = {0};

// ============================ 日志 ============================

// 🔴🔴 2026-10-21 壳侧日志必须落盘。
//
//    原实现只 g_print 到 stdout。AppImage 由桌面/游戏模式启动时 stdout 被
//    丢弃（无终端），于是壳内部所有关键数据（渲染帧尺寸、populate 是否
//    share_ok、FBO 状态、mpv 属性）**全部不可见**。前几轮排查因此只能靠
//    推断，反复误判。
//
//    这里额外写 $HOME/文档/app_logs/hein_native.log，与 my_application.cc
//    的原生启动日志同一个文件，便于一次抓齐。
//
// 🔴 Windows（P0-8）：双击 exe 启动时无终端、无调试器，
//    OutputDebugStringA 只有挂 DebugView 才看得到，stdout 直接丢。
//    故 Windows 侧写 %LOCALAPPDATA%\HeinPlay\logs\hein_native.log，
//    且**关掉文件缓冲**（进程被强杀也不丢，教训⑥：日志不可丢）。
#ifdef _WIN32
static FILE *hein_log_fp(void) {
  static FILE *fp = NULL;
  static int inited = 0;
  if (inited) return fp;
  inited = 1;
  // 优先 LOCALAPPDATA，取不到退回 TEMP，再取不到用当前目录。
  char base[MAX_PATH] = {0};
  DWORD n = GetEnvironmentVariableA("LOCALAPPDATA", base, MAX_PATH);
  if (n == 0 || n >= MAX_PATH) {
    n = GetEnvironmentVariableA("TEMP", base, MAX_PATH);
  }
  if (n == 0 || n >= MAX_PATH) {
    snprintf(base, sizeof(base), ".");
  }
  char dir[MAX_PATH + 64];
  snprintf(dir, sizeof(dir), "%s\\HeinPlay\\logs", base);
  // 壳只需要两层目录，手写即可（不必链 shell32 引 SHCreateDirectoryExA）。
  CreateDirectoryA(base, NULL);  // 已存在则失败，无所谓
  CreateDirectoryA(dir, NULL);
  char path[MAX_PATH + 96];
  snprintf(path, sizeof(path), "%s\\hein_native.log", dir);
  fp = fopen(path, "a");
  if (fp != NULL) setvbuf(fp, NULL, _IONBF, 0);
  hein_log("日志文件: %s", path);
  return fp;
}
#else
static FILE *hein_log_fp(void) {
  static FILE *fp = NULL;
  static int inited = 0;
  if (inited) return fp;
  inited = 1;
  const char *home = g_get_home_dir();
  if (home == NULL) return NULL;
  char *dir = g_build_filename(home, "文档", "app_logs", NULL);
  g_mkdir_with_parents(dir, 0755);
  char *path = g_build_filename(dir, "hein_native.log", NULL);
  fp = fopen(path, "a");
  g_free(dir);
  g_free(path);
  return fp;
}
#endif

// 🔴 2026-10-22：全局符号（非 static）—— 见上方前置声明处的说明。
void hein_log(const char *fmt, ...) {
  char buf[2048];
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(buf, sizeof(buf), fmt, ap);
  va_end(ap);
#ifdef _WIN32
  // Windows：调试器（OutputDebugStringA）+ stdout + **落盘**。
  char line[2200];
  snprintf(line, sizeof(line), "HeinPlayMpvDesktop: %s\n", buf);
  OutputDebugStringA(line);
  fputs(line, stdout);
  fflush(stdout);
  // 落盘：无终端启动（双击 exe）时唯一可用的排障手段。
  FILE *fp = hein_log_fp();
  if (fp != NULL) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    fprintf(fp, "[%04d-%02d-%02d %02d:%02d:%02d.%03d] [MPV] %s\n",
            st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond,
            st.wMilliseconds, buf);
    fflush(fp);
  }
#else
  g_print("HeinPlayMpvDesktop: %s\n", buf);
  fflush(stdout);
  // 同时落盘（带时间戳），保证无终端启动时也能取到壳内部数据。
  FILE *fp = hein_log_fp();
  if (fp != NULL) {
    GDateTime *now = g_date_time_new_now_local();
    gchar *ts = g_date_time_format(now, "%Y-%m-%d %H:%M:%S");
    fprintf(fp, "[%s] [MPV] %s\n", ts, buf);
    fflush(fp);
    g_free(ts);
    g_date_time_unref(now);
  }
#endif
}

// ============================ 渲染 ============================

// 跨平台的「渲染挂起标志」访问宏。
// Windows 用 InterlockedOr（原子读，配套 volatile LONG）；Linux 用 GLib 的
// g_atomic_int_*（配套 volatile gint）。两边语义完全一致。
#ifdef _WIN32
#define HEIN_SUSPEND_GET() InterlockedOr(&g_mpv.render_suspended, 0)
#define HEIN_SUSPEND_SET(v) InterlockedExchange(&g_mpv.render_suspended, (v))
#else
#define HEIN_SUSPEND_GET() g_atomic_int_get(&g_mpv.render_suspended)
#define HEIN_SUSPEND_SET(v) g_atomic_int_set(&g_mpv.render_suspended, (v))
#endif

#ifndef _WIN32
// GL 函数解析：交给 libepoxy（它内部处理 eglGetProcAddress / glXGetProcAddress）。
static void *hein_get_proc_address(void *ctx, const char *name) {
  (void)ctx;
  // 🔴 2026-10-26：按 GL 后端给 mpv 正确的 proc address。
  //   · EGL 后端 ⇒ eglGetProcAddress（GLES2 实现，改造前的行为）；
  //   · GLX 后端 ⇒ glXGetProcAddressARB（桌面 OpenGL 实现）。
  //   ⚠️ 必须分清：mpv 会在 render context 里缓存这些指针，
  //      用错 API 的实现（GLES2 的拿到桌面 GL 上下文里用）在 GLX 下不合法。
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    return (void *)glXGetProcAddressARB((const GLubyte *)name);
  }
  return (void *)epoxy_eglGetProcAddress(name);
}

// 壳自建 EGL + GL 上下文。
//
// 🔴 为什么必须自建而不是「用 Flutter 的 GL 上下文」：
//   ① mpv 的 render_gl.h 明文要求 Linux 上必须有 EGL context 且 current，
//      否则 `mpv_render_context_create` 直接返回 **-18 (not supported)**
//      （2026-10-19 实测：无 EGL context 时 GL render API 完全不可用）。
//   ② Flutter Linux 的 GL 上下文归 runner 管理，壳的渲染发生在
//      GTK tick 回调里，无法保证 Flutter 的上下文在该时刻 current。
//   ③ 自建上下文与 Flutter 的上下文**互不共享**，纹理经 FBO→FlTextureGL
//      交付（Flutter 在 populate() 时用自己的上下文采样 GL 纹理名），
//      这正是 Linux 外部纹理的标准做法。
//
// 实现要点：用 Pbuffer surface（无窗口），只需离屏渲染，不出画。
// ⚠️ 2026-10-21：本函数当前**不在主流程调用**（EGL 上下文改由
//    hein_create_shared_context_idle 用 Flutter 的上下文创建）。
//    保留作为「拿不到 Flutter 上下文」时的兜底参考实现，故加 unused 标注。
__attribute__((unused))
static bool hein_create_egl_context(void) {
  // 🔴 2026-10-19 真机修复：先试 eglGetPlatformDisplayEXT（EGL 1.5 扩展），
  //    再回退 eglGetDisplay(EGL_DEFAULT_DISPLAY)。
  //
  //    背景：Bazzite(Fedora 44, Mesa 25) 的 Wayland 会话下，
  //    eglGetDisplay(EGL_DEFAULT_DISPLAY) 拿到的是 X11 display（DISPLAY 未设时
  //    为 NULL），后续 libplacebo/mpv 建 surface 时报：
  //      "No provider of eglGetPlatformDisplayEXT found.
  //       Requires one of: EGL_EXT_platform_base"
  //    应用直接 SIGABRT（exit 134）。
  //
  //    解法：显式请求 SURFACELESS / DEVICE 平台的 display，
  //    不依赖任何窗口系统——这正是离屏渲染需要的。
  // 🔴🔴 2026-10-21 黑屏根因修复：**必须与 Flutter 的 GL 上下文共享资源**。
  //
  //    Flutter Linux 引擎（fl_opengl_manager.cc）建了三个 context：
  //      render_context（渲染）、resource_context（与 render 共享）、
  //      platform_context（与 render 共享）。
  //    引擎在 `fl_engine_gl_external_texture_frame_callback` 里调用
  //    `FlTextureGL::populate` 时，current 的是 **resource_context**。
  //    populate 返回的 texture name 会被引擎直接在该 context 里采样。
  //
  //    此前壳用 `eglCreateContext(d, cfg, EGL_NO_CONTEXT, NULL)` 建了
  //    **完全不共享**的独立上下文 → 我们的 FBO 纹理名在 Flutter 的
  //    context 里指向**另一个（不存在的）纹理对象** → 采样全黑。
  //    表现就是：mpv 内核渲染正常（最小复现已验证像素非黑）、音频正常、
  //    进度条正常，**唯独画面全黑**。
  //
  //    修法：优先拿 Flutter 当前 current 的 EGLDisplay + EGLContext，
  //    用同一个 display 建上下文并把 Flutter 的 context 作为 share_context
  //    传入 → 纹理/FBO 名字两边共享 → populate 交出去的 name 有效。
  EGLDisplay d = EGL_NO_DISPLAY;
  EGLContext share_ctx = EGL_NO_CONTEXT;

  {
    EGLContext cur = eglGetCurrentContext();
    EGLDisplay cur_d = eglGetCurrentDisplay();
    if (cur != EGL_NO_CONTEXT && cur_d != EGL_NO_DISPLAY) {
      d = cur_d;
      share_ctx = cur;
      hein_log("检测到 Flutter 的 EGL 上下文，将以共享方式建壳上下文");
    }
  }

  // 🔴 EGL_PLATFORM_SURFACELESS_MESA / EGL_PLATFORM_DEVICE_MESA 是 Mesa 私有
  //    扩展宏，epoxy 头未导出，按规范值硬编码（与 mesa/eglext.h 一致）。
  //    缺失时也不致命：下面有 eglGetDisplay 回退。
  #ifndef EGL_PLATFORM_SURFACELESS_MESA
  #define EGL_PLATFORM_SURFACELESS_MESA 0x31DD
  #endif
  #ifndef EGL_PLATFORM_DEVICE_MESA
  #define EGL_PLATFORM_DEVICE_MESA 0x31DF
  #endif

  // eglGetPlatformDisplayEXT 是扩展，需动态取（epoxy 已封装）
  PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
      (PFNEGLGETPLATFORMDISPLAYEXTPROC)epoxy_eglGetProcAddress(
          "eglGetPlatformDisplayEXT");
  if (d == EGL_NO_DISPLAY && get_platform_display != NULL) {
    // 签名：EGLDisplay (platform, void *native_display, const EGLAttrib *attrib_list)
    //
    // 🔴🔴🔴 2026-10-26：**按 GDK 后端取对应的 EGL platform**，
    //   与 Flutter 引擎（fl_opengl_manager.cc）保持**完全一致**：
    //     · Wayland 会话 → EGL_PLATFORM_WAYLAND_EXT (0x31D8) + wl_display
    //     · X11 会话     → EGL_PLATFORM_X11_EXT     (0x31D5) + xdisplay
    //   引擎的 resource_context 用的就是这个 display，
    //   ⇒ 壳必须用**同一个 display**，阶段②的共享才成立
    //   （跨 display 的上下文不能共享纹理命名空间）。
    //
    //   ⚠️ 为什么必须显式指定 platform：
    //     · 退到 eglGetDisplay(EGL_DEFAULT_DISPLAY) 拿到的 display 在
    //       Wayland 下**不支持 pbuffer**（真机实测 eglChooseConfig
    //       (EGL_PBUFFER_BIT) 返回 n=0）→ 阶段①失败；
    //     · 且那个 display 与引擎的不是同一个 → 阶段②共享必然失败。
    {
      GdkDisplay *gdpy = gdk_display_get_default();
      const char *cls =
          (gdpy != NULL) ? G_OBJECT_TYPE_NAME((GObject *)gdpy) : NULL;
      // 🔴 2026-10-26：gdpy 可能为 **NULL** —— 插件注册发生在 GTK 打开
      //   display 之前（Flutter 引擎尚未创建窗口）。此时不能直接落到
      //   surfaceless 分支：那个 display 与引擎的不是同一个 ⇒
      //   阶段②的共享必然失败。
      //   ⇒ 先 gdk_display_open(NULL)（幂等；已打开则直接返回）。
      if (gdpy == NULL) {
        gdpy = gdk_display_open(NULL);
        cls = (gdpy != NULL) ? G_OBJECT_TYPE_NAME((GObject *)gdpy) : NULL;
        hein_log("gdk_display_get_default() 为空 ⇒ gdk_display_open(NULL) "
                 "得到 %s", cls ? cls : "(null)");
      }
      hein_log("GDK display 类名 = %s（GDK_BACKEND=%s WAYLAND_DISPLAY=%s DISPLAY=%s）",
               cls ? cls : "(null)", g_getenv("GDK_BACKEND") ? g_getenv("GDK_BACKEND") : "-",
               g_getenv("WAYLAND_DISPLAY") ? g_getenv("WAYLAND_DISPLAY") : "-",
               g_getenv("DISPLAY") ? g_getenv("DISPLAY") : "-");
      if (cls != NULL && strstr(cls, "Wayland") != NULL) {
        struct wl_display *wldpy = gdk_wayland_display_get_wl_display(gdpy);
        if (wldpy != NULL) {
          // 🔴🔴🔴 EGL_PLATFORM_WAYLAND_EXT = **0x31D8**
          //   （EGL/eglext.h 与 epoxy/egl_generated.h 均为 0x31D8；
          //     之前误写成 0x31D3 ⇒ eglGetPlatformDisplayEXT 返回
          //     EGL_NO_DISPLAY ⇒ 静默落到 surfaceless 分支，
          //     display 与引擎不一致 ⇒ 阶段②共享必然失败。）
          //   ⚠️ 用头文件常量，避免再写错魔数。
          d = get_platform_display(EGL_PLATFORM_WAYLAND_EXT, (void *)wldpy,
                                   NULL);
          if (d != EGL_NO_DISPLAY) {
            hein_log("eglGetPlatformDisplayEXT(Wayland platform) 成功"
                     "（与引擎一致 ⇒ 共享可用）");
          }
        }
      } else if (cls != NULL && strstr(cls, "X11") != NULL) {
        // 🔴🔴🔴 2026-10-26：**X11 会话下刻意不用 X11 platform**。
        //
        //   原因：GTK3 在 X11 下用 **GLX**，而 **EGL 与 GLX 在同一个 X
        //   display 上互斥**（真机最小复现 /tmp/eglx11b，69 掌机）：
        //     eglMakeCurrent(pbuffer)=1 → 紧接着 glXMakeCurrent 报
        //     BadAccess (X_GLXMakeCurrent)
        //   ⇒ 一旦壳在 X11 display 上 makeCurrent 一个 EGL 上下文，
        //     GTK3 的 GLX 上下文就坏掉 → 引擎的
        //     `gdk_cairo_draw_from_gl`（fl_compositor_opengl.cc 的
        //     shareable=FALSE 分支）拿到失效上下文 → **SIGSEGV**。
        //   真机崩溃回溯（69 掌机桌面 X11 会话）：
        //     gdk_cairo_draw_from_gl ← libflutter_linux_gtk.so
        //
        //   ⇒ X11 下阶段①走 **surfaceless**（不碰 GLX 命名空间），
        //     而**阶段②**用的是 populate 捕获的 **Flutter 的 display**
        //     （与引擎同一个）⇒ 共享照样成立。
        //     这正是桌面模式一直能播的原因（旧代码在 X11 桌面走的就是
        //     surfaceless）。
        //
        //   ⚠️ 游戏模式已改为**整体走 Wayland**（见 runner 的
        //     hein_force_gamescope_wayland）⇒ GTK3 与引擎都是 EGL，
        //     不存在互斥问题，也不走这条分支。
        hein_log("X11 会话：阶段①用 surfaceless EGL（避开与 GTK3 的 GLX "
                 "互斥）；阶段②用 Flutter 的 display 共享");
      }
    }
    if (d == EGL_NO_DISPLAY) {
      // 再试 SURFACELESS：无窗口系统依赖，纯离屏（桌面 Wayland 会话走这里）
      d = get_platform_display(EGL_PLATFORM_SURFACELESS_MESA,
                               (void *)EGL_DEFAULT_DISPLAY, NULL);
      if (d == EGL_NO_DISPLAY) {
        // 再试 DEVICE 平台（GBM/Mesa 软件设备）
        d = get_platform_display(EGL_PLATFORM_DEVICE_MESA,
                                 (void *)EGL_DEFAULT_DISPLAY, NULL);
      }
      if (d != EGL_NO_DISPLAY) {
        hein_log("eglGetPlatformDisplayEXT 成功（surfaceless/device）");
      }
    }
  }

  // 回退：传统方式（有 X11/Wayland 时可用）
  if (d == EGL_NO_DISPLAY) {
    d = eglGetDisplay(EGL_DEFAULT_DISPLAY);
  }
  if (d == EGL_NO_DISPLAY) {
    hein_log("eglGetDisplay 失败 0x%x", eglGetError());
    return false;
  }
  EGLint major = 0, minor = 0;
  if (!eglInitialize(d, &major, &minor)) {
    hein_log("eglInitialize 失败 0x%x", eglGetError());
    return false;
  }
  // 🔴🔴 2026-10-21 真实播放失败根因（阶段① 同样必须支持 surfaceless）。
  //
  //    **真实 UI 播放时**，Dart 侧已在 Flutter raster 线程 current 了
  //    Flutter 的 Wayland EGLDisplay，故上面 `eglGetCurrentDisplay()`
  //    直接命中 → d = Flutter 的 Wayland display。
  //    而 Wayland display **不支持 pbuffer surface**（实测 78 真机
  //    eglChooseConfig(EGL_PBUFFER_BIT) 返回 n=0）→ 原实现直接
  //    「eglChooseConfig 失败」→ hein_create_egl_context 返回 false →
  //    整个 mpv init 失败 → 播放必然失败。
  //
  //    为什么自检能过、真实播放不过：
  //      · 自检（HEIN_MPV_SELFTEST）启动极早，此刻 Flutter 上下文尚未
  //        current → 走 eglGetPlatformDisplayEXT(SURFACELESS_MESA)
  //        → 该 display 支持 pbuffer → 阶段① 成功。
  //      · 真实播放时 Flutter display 已 current → 复用 Wayland display
  //        → pbuffer 不可用 → 阶段① 失败。
  //    这个差异正是上一轮「自检通过但用户实际播放失败」的原因。
  //
  //    修法：与阶段②完全一致的**两级尝试**——
  //      ① 先试带 pbuffer 的 config；
  //      ② 失败则用不带 SURFACE_TYPE 的 config + EGL_NO_SURFACE 做
  //         surfaceless current（我们只离屏渲染到 FBO，本就不需要窗口）。
  EGLint cfg_attribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                          EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  EGLBoolean have_cfg = eglChooseConfig(d, cfg_attribs, &cfg, 1, &n);
  EGLSurface surf = EGL_NO_SURFACE;
  if (have_cfg && n >= 1) {
    const EGLint pb_attribs[] = {EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE};
    surf = eglCreatePbufferSurface(d, cfg, pb_attribs);
  }
  if (surf == EGL_NO_SURFACE) {
    // 回退：不带 SURFACE_TYPE 的 config + EGL_NO_SURFACE（surfaceless）。
    EGLint fb_attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                           EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                           EGL_ALPHA_SIZE, 8, EGL_NONE};
    n = 0;
    if (!eglChooseConfig(d, fb_attribs, &cfg, 1, &n) || n < 1) {
      hein_log("阶段①：eglChooseConfig 失败（pbuffer 与 surfaceless 均不可用）"
               " err=0x%x", eglGetError());
      return false;
    }
    hein_log("阶段①：改用 surfaceless 模式（当前 display 不支持 pbuffer）");
  }
  // 🔴🔴 2026-10-21 黑屏根因①最终修复：壳上下文必须是 **GLES2**。
  //
  //    Flutter Linux 引擎（fl_opengl_manager.cc）建上下文的属性是：
  //        const EGLint context_attributes[] = {
  //            EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
  //    即 **OpenGL ES 2.0**，而非桌面 OpenGL。
  //
  //    EGL 规范禁止跨 client API 共享对象：以桌面 GL 上下文去 share
  //    Flutter 的 GLES2 上下文，eglCreateContext 要么失败、要么建出的
  //    上下文与对方不共享命名空间（本机实测 eglGetError=0x3000）。
  //    /tmp/share_test 实测对照：
  //      · 壳 GLES2 + share=Flutter resource_ctx → 纹理名有效（绑定一致）
  //      · 壳桌面GL + share=Flutter resource_ctx → 0x3000，名字无效
  //
  //    故这里必须 bind EGL_OPENGL_ES_API 并用 CLIENT_VERSION=2 建上下文。
  //    mpv 的 libmpv render API 支持 GLES2，不需要桌面 GL 独有特性。
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint ctx_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  // 🔴 关键：share_ctx 非空时，新上下文与 Flutter 的上下文共享纹理/FBO 名字。
  EGLContext ctx = eglCreateContext(d, cfg, share_ctx, ctx_attribs);
  if (ctx == EGL_NO_CONTEXT) {
    hein_log("eglCreateContext(GLES2) 失败 0x%x", eglGetError());
    return false;
  }
  if (!eglMakeCurrent(d, surf, surf, ctx)) {
    hein_log("eglMakeCurrent 失败 0x%x", eglGetError());
    return false;
  }
  g_mpv.egl_display = d;
  g_mpv.egl_context = ctx;
  g_mpv.egl_surface = surf;
  g_mpv.egl_share_context = share_ctx;
  hein_log("EGL(GLES2) 上下文已建立：EGL %d.%d / %s / renderer=%s / 共享=%s",
           major, minor, (const char *)glGetString(GL_VERSION),
           (const char *)glGetString(GL_RENDERER),
           share_ctx == EGL_NO_CONTEXT ? "否" : "是");
  return true;
}

// 🔴🔴🔴 2026-10-26：GL 后端检测（**已按真机证据推翻原判定**）。
//
// 【原判定（错）】按 GTK3 的窗口后端推断：X11 ⇒ GLX、Wayland ⇒ EGL。
//
// 【为什么错】GTK3 的窗口后端 ≠ Flutter 引擎的 GL 上下文类型。
//   Flutter Linux 引擎（fl_opengl_manager.cc）**自己**用 EGL 建上下文，
//   上下文属性写死为：
//       const EGLint context_attributes[] = {
//           EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };   // OpenGL ES 2.0
//   ⇒ **无论会话是 Wayland 还是 X11（gamescope 的 XWayland），
//      Flutter 的渲染上下文恒为 EGL / OpenGL ES 2.0**。
//   2026-10-21 的 /tmp/share_test 实测也印证了这一点：
//     · 壳 GLES2 + share=Flutter resource_ctx → 纹理名有效（绑定一致）
//     · 壳 桌面GL + share=Flutter resource_ctx → eglGetError=0x3000，名字无效
//
// 【错误判定的代价】游戏模式（X11）被判成 GLX ⇒ 壳建了**桌面 GL** 上下文，
//   与 Flutter 的 **GLES2** 上下文跨 API，EGL 规范禁止跨 client API 共享
//   ⇒ 共享永远建不起来 ⇒ 有声无画（用户实测：游戏模式点播放无画面）。
//   ⚠️ 此前「X11 下 GtkGLArea 拿到 GLX 上下文」那次实测，测的是**自写的
//      GtkGLArea 测试程序**，不能拿来推断 Flutter ⇒ 属于张冠李戴。
//
// 【现判定】恒为 EGL（与改造前的既有行为完全一致 ⇒ 桌面版零风险）。
//   GLX 路线保留在代码里仅作取证与将来兜底，但**不再由会话类型触发**。
static HeinGLBackend hein_detect_gl_backend(void) {
  return HEIN_GL_BACKEND_EGL;
}

// 阶段①的上下文创建：按后端分派。
// GLX 失败时**回退 EGL**（保持既有行为，绝不让游戏模式彻底起不来）。
static bool hein_create_gl_context(void) {
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    char err[256] = {0};
    if (!hein_glx_context_create(&g_mpv.glx_stage1, err, sizeof(err)) ||
        !hein_glx_make_current(&g_mpv.glx_stage1)) {
      hein_log("GLX 阶段①上下文失败：%s ⇒ 回退 EGL 路径", err);
      hein_gl_backend = HEIN_GL_BACKEND_EGL;
      hein_gl_api_init(HEIN_GL_BACKEND_EGL);
      return hein_create_egl_context();
    }
    hein_log("阶段①：GLX 壳上下文已建立（不共享） GL=%s",
             (const char *)glGetString(GL_VERSION));
    return true;
  }
  return hein_create_egl_context();
}

// ==================== 共享上下文延迟重建（黑屏根因①的最终修复）==========
//
// 【问题】
//   插件注册时若就建 EGL 上下文（原实现），那一刻
//   Flutter 的 GL 上下文**尚未 current**（引擎只在 raster 线程开始绘制时
//   才 eglMakeCurrent），所以 eglGetCurrentContext() 恒为 EGL_NO_CONTEXT
//   → 壳上下文以 EGL_NO_CONTEXT 为 share 建立 → 与 Flutter 完全不共享。
//   随后 populate 把纹理名交给 Flutter，Flutter 在自己的 context 里采样
//   这个「别人的」名字 → 全黑（有声无画）。
//
// 【解法】
//   在首次 populate 时捕获 Flutter 真实上下文（此时 current 的正是
//   resource_context），回调到本函数：销毁旧的壳上下文与 mpv render
//   context，用捕获到的 Flutter 上下文作为 share 重建，然后重新
//   mpv_render_context_create。此后 populate 交出的纹理名两边共享有效。
//
// 【为什么必须回主线程】
//   populate 在 Flutter raster 线程执行，而 mpv 的 render context 与
//   GTK 主线程绑定（我们的帧驱动在主线程）。跨线程改 EGL current 会崩。
static gboolean hein_create_shared_context_idle(gpointer data) {
  (void)data;
  if (g_mpv.share_rebuild_done) return G_SOURCE_REMOVE;

  // 🔴🔴🔴 2026-10-26：GLX 后端（X11 会话 / gamescope 游戏模式）的阶段②。
  //
  //   Flutter 在 X11 下用的是 **GLX/桌面 OpenGL** 上下文，而 EGL/GLES2 与
  //   GLX/桌面GL **不能跨 API 共享纹理** ⇒ 这条路必须整套用 GLX：
  //     · 共享上下文 = glXCreateContext(dpy, vi, share=Flutter的GLXContext)
  //     · drawable = GLXPbuffer（GLX 必须有 drawable 才能 makeCurrent）
  //     · 纹理/FBO 在共享上下文里建 ⇒ 名字与 Flutter 侧同一命名空间
  //   69 掌机实测：共享上下文写 FBO 纹理 → 原上下文 glGetTexImage
  //   读回 RGBA=(0,255,0,255) ⇒ 共享成立。
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    GLXContext fl_glx = g_mpv.flutter_glx_context;
    if (fl_glx == NULL) return G_SOURCE_REMOVE;
    hein_log("阶段②：用 Flutter 的 GLX 上下文创建共享壳上下文 ctx=%p",
             (void *)fl_glx);
    char err[256] = {0};
    if (!hein_glx_context_create_shared(&g_mpv.glx_stage2, (void *)fl_glx, err,
                                        sizeof(err))) {
      hein_log("阶段②：GLX 共享上下文创建失败：%s", err);
      return G_SOURCE_REMOVE;
    }
    if (!hein_glx_make_current(&g_mpv.glx_stage2)) {
      hein_log("阶段②：GLX makeCurrent 失败");
      hein_glx_context_destroy(&g_mpv.glx_stage2);
      return G_SOURCE_REMOVE;
    }
    g_mpv.share_rebuild_done = true;
    // 旧围栏属于上下文 A（未共享），对 Flutter 无效，必须丢弃。
    if (g_mpv.frame_fence != 0) {
      glDeleteSync(g_mpv.frame_fence);
      g_mpv.frame_fence = 0;
    }
    g_mpv.fence_pending = false;
    hein_log("阶段②：GLX 共享壳上下文创建成功 GL=%s 共享=是",
             (const char *)glGetString(GL_VERSION));
    // ③ 在共享上下文 B 里建纹理/FBO（旧纹理属于上下文 A，只清记录不 delete）。
    if (g_mpv.gl_texture != NULL) {
      hein_gl_texture_forget_objects(g_mpv.gl_texture);
      hein_gl_texture_set_share_context(g_mpv.gl_texture,
                                        g_mpv.glx_stage2.context,
                                        g_mpv.glx_stage2.display);
      hein_gl_texture_ensure_fbo(g_mpv.gl_texture, 2, 2);
    }
    if (g_mpv.registered_texture_id > 0 && g_mpv.texture_registrar != NULL) {
      fl_texture_registrar_mark_texture_frame_available(
          g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
    }
    g_mpv.has_new_frame = true;
    hein_mpv_request_frame();
    // 🔴🔴 2026-10-26：共享上下文（GLX）已 current ⇒ 在这里**建 mpv 的
    //   render context**，让它的一切 GL 资源都归属于这个共享上下文。
    //   绝不能在 init 用未共享的 A 建（VAO 不可跨上下文共享 ⇒ 全黑）。
    hein_ensure_render_context_locked();
    hein_log("阶段②完成：纹理已在新上下文中重建并通知 Flutter 重新采样");
    return G_SOURCE_REMOVE;
  }

  EGLContext fl_ctx = g_mpv.flutter_egl_context;
  EGLDisplay fl_dpy = g_mpv.flutter_egl_display;
  if (fl_ctx == EGL_NO_CONTEXT || fl_dpy == EGL_NO_DISPLAY) return G_SOURCE_REMOVE;

  // 🔴🔴🔴 2026-10-26：**X11 会话守卫**。
  //
  //   在 X11 会话下，Flutter 引擎的 resource_context 用的 display 是
  //   **X11 platform**（fl_opengl_manager.cc），而 GTK3 的 GdkGLContext
  //   在 X11 下是 **GLX**。二者在**同一个 X display 上互斥**：
  //   真机最小复现（69 掌机，/tmp/eglx11b）：
  //     eglMakeCurrent(pbuffer)=1 → 紧接着 glXMakeCurrent 报
  //     BadAccess (X_GLXMakeCurrent)
  //   ⇒ 若阶段②在这个 display 上 makeCurrent，GTK3 的 GLX 上下文就坏掉，
  //     引擎下一帧的 `gdk_cairo_draw_from_gl` 拿到失效上下文 → **SIGSEGV**
  //     （真机回溯：gdk_cairo_draw_from_gl ← libflutter_linux_gtk.so）。
  //
  //   ⇒ X11 会话下**不在这个 display 上 makeCurrent**：改用阶段①的
  //     surfaceless display 建独立上下文。
  //     代价：纹理命名空间不共享 ⇒ Flutter 侧采样到的可能是黑图；
  //     收益：**绝不崩溃**（应用可继续用，UI/声音正常）。
  //     这是 X11 会话下的**降级**而非修复。
  //
  //   正解是**整个应用跑在 Wayland**（GTK3 与引擎都是 EGL，
  //   shareable=TRUE ⇒ 纹理共享路径，全程不碰 GLX）——
  //   游戏模式已在 runner 的 hein_force_gamescope_wayland() 里做到；
  //   桌面若也是 Wayland（69 的真实桌面就是 gamescope 的 Wayland），
  //   则天然走这条路。
  {
    GdkDisplay *gdpy = gdk_display_get_default();
    const char *cls =
        (gdpy != NULL) ? G_OBJECT_TYPE_NAME((GObject *)gdpy) : NULL;
    const gboolean is_x11 =
        (cls != NULL && strstr(cls, "X11") != NULL) ? TRUE : FALSE;
    if (is_x11) {
      hein_log("阶段②：**X11 会话守卫** —— 引擎的 resource_context 在 X11 "
               "platform display 上，与 GTK3 的 GLX 互斥（真机实测 "
               "glXMakeCurrent → BadAccess ⇒ 引擎绘制崩溃）。"
               "改为在 surfaceless display 上建独立上下文："
               "画面可能为黑，但**不崩溃**。"
               "正解是让应用整体跑在 Wayland（桌面/游戏模式均已具备）。");
      // 用阶段①的 display 建一个**不共享**的上下文（不碰 X11 platform）。
      if (g_mpv.egl_display == EGL_NO_DISPLAY) {
        hein_log("阶段②：X11 守卫但阶段①的 display 不可用 ⇒ 放弃阶段②");
        return G_SOURCE_REMOVE;
      }
      EGLint maj2 = 0, min2 = 0;
      if (!eglInitialize(g_mpv.egl_display, &maj2, &min2)) {
        hein_log("阶段②：X11 守卫 eglInitialize 失败 0x%x", eglGetError());
        return G_SOURCE_REMOVE;
      }
      EGLint ca2[] = {EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                      EGL_ALPHA_SIZE, 8, EGL_NONE};
      EGLConfig cfg2 = NULL;
      EGLint cn2 = 0;
      if (!eglChooseConfig(g_mpv.egl_display, ca2, &cfg2, 1, &cn2) || cn2 < 1) {
        // 🔴 surfaceless display 上可能拿不到 ES2 可渲染的 config
        //   （该 display 的 config 集合有限）⇒ 守卫建不出独立上下文。
        //   此时**放弃共享**（回到阶段①的上下文 A，不共享），
        //   宁可画面全黑也**绝不**在 X11 platform display 上 makeCurrent
        //   （那会破坏 GTK3 的 GLX ⇒ 引擎绘制崩溃）。
        hein_log("阶段②：X11 守卫 eglChooseConfig 失败（err=0x%x）"
                 " ⇒ 放弃共享，保留阶段①上下文（画面可能为黑，但不崩溃）",
                 eglGetError());
        g_mpv.share_rebuild_done = true;  // 不再重试
        return G_SOURCE_REMOVE;
      }
      eglBindAPI(EGL_OPENGL_ES_API);
      const EGLint cx2[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
      // 关键：share context 传 EGL_NO_CONTEXT ⇒ **不与 Flutter 共享**。
      EGLContext ctx2 = eglCreateContext(g_mpv.egl_display, cfg2,
                                         EGL_NO_CONTEXT, cx2);
      if (ctx2 == EGL_NO_CONTEXT) {
        hein_log("阶段②：X11 守卫 eglCreateContext 失败 0x%x", eglGetError());
        return G_SOURCE_REMOVE;
      }
      if (!eglMakeCurrent(g_mpv.egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                          ctx2)) {
        hein_log("阶段②：X11 守卫 eglMakeCurrent 失败 0x%x", eglGetError());
        eglDestroyContext(g_mpv.egl_display, ctx2);
        return G_SOURCE_REMOVE;
      }
      g_mpv.share_egl_display = g_mpv.egl_display;
      g_mpv.share_egl_context = ctx2;
      g_mpv.share_egl_surface = EGL_NO_SURFACE;
      g_mpv.share_rebuild_done = true;
      hein_log("阶段②：X11 守卫上下文已建立（**不共享**，画面可能为黑）");
      return G_SOURCE_REMOVE;
    }
  }

  hein_log("阶段②：用 Flutter 上下文创建共享壳上下文 ctx=%p display=%p",
           (void *)fl_ctx, (void *)fl_dpy);

  // ① 复用 Flutter 的 EGLDisplay（同一个 display 才能共享命名空间）。
  EGLDisplay d = fl_dpy;
  EGLint major = 0, minor = 0;
  if (!eglInitialize(d, &major, &minor)) {
    hein_log("阶段②：eglInitialize 失败 0x%x", eglGetError());
    return G_SOURCE_REMOVE;
  }
  // 🔴 关键：Flutter 的 EGLDisplay 在 **Wayland 会话**下是
  //    eglGetPlatformDisplayEXT(EGL_PLATFORM_WAYLAND_EXT, wl_display)，
  //    该 display **不支持 pbuffer surface**（实测 78 真机
  //    eglChooseConfig(EGL_PBUFFER_BIT) 返回 n=0 → 阶段②直接失败）。
  //
  //    故这里分两级尝试：
  //      ① 先试带 pbuffer 的 config（surfaceless display 下可用）；
  //      ② 失败则用不带 SURFACE_TYPE 的 config + EGL_NO_SURFACE 做
  //         surfaceless current（Wayland display 下可行，我们只需离屏
  //         渲染到 FBO，本来就不需要窗口 surface）。
  EGLint cfg_attribs[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
                          EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                          EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                          EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg;
  EGLint n = 0;
  EGLBoolean have_cfg = eglChooseConfig(d, cfg_attribs, &cfg, 1, &n);
  EGLSurface surf = EGL_NO_SURFACE;
  if (have_cfg && n >= 1) {
    const EGLint pb_attribs[] = {EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE};
    surf = eglCreatePbufferSurface(d, cfg, pb_attribs);
  }
  if (surf == EGL_NO_SURFACE) {
    // 回退：不带 SURFACE_TYPE 的 config，用 EGL_NO_SURFACE 做 surfaceless。
    EGLint fb_attribs[] = {EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                           EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
                           EGL_ALPHA_SIZE, 8, EGL_NONE};
    n = 0;
    if (!eglChooseConfig(d, fb_attribs, &cfg, 1, &n) || n < 1) {
      hein_log("阶段②：eglChooseConfig 失败（pbuffer 与 surfaceless 均不可用）"
               " err=0x%x", eglGetError());
      return G_SOURCE_REMOVE;
    }
    hein_log("阶段②：改用 surfaceless 模式（Wayland display 不支持 pbuffer）");
  }
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint ctx_attribs[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  // 🔴🔴🔴 2026-10-26：**必须与 Flutter 用同一个 EGLConfig**。
  //
  //    EGL 规范（EGL 1.4 §3.7.1）：`eglCreateContext` 的 share context
  //    必须与新建上下文**基于兼容的 config**，否则返回 EGL_BAD_MATCH；
  //    而「兼容」要求 config 的 buffer 尺寸等属性**一致**。
  //    此前这里用自己 eglChooseConfig 选出的 config（带 pbuffer /
  //    ES2 过滤），与 Flutter 引擎侧的 config（fl_opengl_manager.cc：
  //    仅 RED/GREEN/BLUE/ALPHA/DEPTH/STENCIL=8）**不同** ⇒
  //    共享在规范上就不成立 ⇒ 纹理名两边对不上 ⇒ 全黑。
  //
  //    修法：直接复用 Flutter 那个 context 的 config
  //    （eglQueryContext(EGL_CONFIG_ID) → 在 config 列表里按 ID 精确匹配）。
  {
    EGLint fl_cfg_id = 0;
    if (eglQueryContext(d, fl_ctx, EGL_CONFIG_ID, &fl_cfg_id) &&
        fl_cfg_id != 0) {
      EGLConfig candidates[64];
      EGLint cn = 0;
      if (eglGetConfigs(d, candidates, 64, &cn)) {
        for (EGLint i = 0; i < cn; i++) {
          EGLint id = 0;
          if (eglGetConfigAttrib(d, candidates[i], EGL_CONFIG_ID, &id) &&
              id == fl_cfg_id) {
            const gboolean same_cfg = (cfg == candidates[i]);
            cfg = candidates[i];
            have_cfg = TRUE;
            n = 1;
            // 🔴 surface 必须与最终 config 匹配 ⇒ config 变了就重建。
            if (!same_cfg && surf != EGL_NO_SURFACE) {
              eglDestroySurface(d, surf);
              surf = EGL_NO_SURFACE;
              const EGLint pb_attribs[] = {EGL_WIDTH, 64, EGL_HEIGHT, 64,
                                          EGL_NONE};
              surf = eglCreatePbufferSurface(d, cfg, pb_attribs);
            }
            break;
          }
        }
      }
      if (have_cfg) {
        hein_log("阶段②：改用 Flutter 的同一 EGLConfig（id=%d）"
                 " ⇒ 跨 config 共享的规范问题消除", fl_cfg_id);
      } else {
        hein_log("阶段②：未在候选中找到 EGLConfig id=%d，沿用自选 config"
                 "（共享可能不成立）", fl_cfg_id);
      }
    } else {
      hein_log("阶段②：未能取到 Flutter 的 EGLConfig（id 查询失败）"
               "，沿用自选 config（共享可能不成立）");
    }
  }
  // 🔴 以 Flutter 的 resource_context 为 share → 纹理/FBO 名字两边共享。
  EGLContext ctx = eglCreateContext(d, cfg, fl_ctx, ctx_attribs);
  if (ctx == EGL_NO_CONTEXT) {
    hein_log("阶段②：eglCreateContext 失败 0x%x", eglGetError());
    return G_SOURCE_REMOVE;
  }
  // surf 可能为 EGL_NO_SURFACE（Wayland display 的 surfaceless 模式），
  // 此时必须显式传 EGL_NO_SURFACE 而非 surf（surf 本身就是它，语义一致）。
  if (!eglMakeCurrent(d, surf, surf, ctx)) {
    hein_log("阶段②：eglMakeCurrent 失败 0x%x（surf=%s）", eglGetError(),
             surf == EGL_NO_SURFACE ? "NO_SURFACE" : "pbuffer");
    return G_SOURCE_REMOVE;
  }

  // ② 记住共享上下文；**不销毁**阶段①的 render context（实测它可以在
  //    与创建上下文共享的另一上下文中正常渲染，/tmp/ctx_test 已验证）。
  g_mpv.share_egl_display = d;
  g_mpv.share_egl_context = ctx;
  g_mpv.share_egl_surface = surf;
  g_mpv.egl_share_context = fl_ctx;
  g_mpv.share_rebuild_done = true;
  // 🔴 旧围栏属于上下文 A（未共享），对 Flutter 无效，必须丢弃。
  if (g_mpv.frame_fence != 0) {
    glDeleteSync(g_mpv.frame_fence);
    g_mpv.frame_fence = 0;
  }
  g_mpv.fence_pending = false;
  hein_log("阶段②：共享壳上下文创建成功 GL=%s 共享=是",
           (const char *)glGetString(GL_VERSION));

  // ③ 在共享上下文 B 里建纹理/FBO（旧纹理属于上下文 A，只清记录不 delete）。
  if (g_mpv.gl_texture != NULL) {
    hein_gl_texture_forget_objects(g_mpv.gl_texture);
    hein_gl_texture_set_share_context(g_mpv.gl_texture, ctx, d);
    hein_gl_texture_ensure_fbo(g_mpv.gl_texture, 2, 2);
  }
  // 🔴 关键：阶段②换掉了纹理对象（旧名字属于上下文 A，已作废），
  //    必须让 Flutter **立刻重新采样一次**，否则它会一直沿用旧的、
  //    在新上下文里无效的纹理名 → 画面全黑，且 populate 不再被调用。
  //    做法：标记新帧 + 请求一次渲染，渲染完成后壳会再调
  //    fl_texture_registrar_mark_texture_frame_available。
  if (g_mpv.registered_texture_id > 0 && g_mpv.texture_registrar != NULL) {
    fl_texture_registrar_mark_texture_frame_available(
        g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
  }
  g_mpv.has_new_frame = true;
  hein_mpv_request_frame();
  // 🔴🔴 2026-10-26：共享上下文（EGL）已 current ⇒ 在这里建 mpv 的
  //   render context。见 hein_ensure_render_context_locked 注释。
  hein_ensure_render_context_locked();
  hein_log("阶段②完成：纹理已在新上下文中重建并通知 Flutter 重新采样");
  return G_SOURCE_REMOVE;
}

// 🔴🔴🔴 2026-10-26：在**共享上下文 B 已 current** 的前提下创建 mpv 的
//   render context，并补发此前被延迟的 loadfile。
//
//   必须在 B 里建（而不是 init 时用未共享的 A）：mpv 在
//   mpv_render_context_create 期间通过 ra_gl_ctx_init 创建 VAO / buffer /
//   内部 FBO / shader，**VAO 是 OpenGL 唯一不能跨上下文共享的对象**，
//   且其余资源也只在同一 share group 内有效。建在 A 而渲染在 B
//   ⇒ 全部 draw 静默失效 ⇒ FBO 恒黑、音频正常（真机实测症状）。
//
//   调用约定：调用方已 eglMakeCurrent / glXMakeCurrent 到共享上下文。
//   返回 true 表示 render context 已就绪（首次或早已就绪）。
static bool hein_ensure_render_context_locked(void) {
  if (g_mpv.mpv == NULL) return false;
  if (g_mpv.mpv_gl != NULL) return true;  // 已建好，幂等

  // 🔴🔴🔴 2026-10-27 23:05：SW 模式 → 建软件 render context，完全不碰 GL。
  if (g_mpv.sw_mode) {
    if (g_mpv.mpv_sw != NULL) return true;
    mpv_render_param sparams[] = {
        {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_SW},
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    int src = mpv_render_context_create(
        (mpv_render_context **)&g_mpv.mpv_sw, g_mpv.mpv, sparams);
    if (src < 0) {
      hein_log("SW render context 创建失败 rc=%d (%s)", src,
               mpv_error_string(src));
      return false;
    }
    mpv_render_context_set_update_callback(
        (mpv_render_context *)g_mpv.mpv_sw, on_mpv_render, NULL);
    hein_log("SW render context 已创建（MPV_RENDER_API_TYPE_SW，零 GL 上下文）");
    // 补发被延迟的 loadfile。
    if (g_mpv.deferred_url != NULL) {
      char *url = g_mpv.deferred_url;
      g_mpv.deferred_url = NULL;
      hein_log("补发延迟的 loadfile：%s", url);
      hein_mpv_open_internal(url, g_mpv.deferred_start_sec,
                             g_mpv.deferred_is_live, g_mpv.deferred_hwdec,
                             g_mpv.deferred_cache_secs);
      g_free(url);
    }
    return true;
  }

  mpv_opengl_init_params gl_init = {
      .get_proc_address = hein_get_proc_address,
      // GLX 后端下 mpv 用 Display* 解析 GL 符号；EGL 下为 EGLDisplay（传 NULL
      // 走 epoxy 当前上下文）。
      .get_proc_address_ctx =
          (hein_gl_backend == HEIN_GL_BACKEND_GLX)
              ? (void *)gdk_x11_get_default_xdisplay()
              : NULL,
  };
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_OPENGL},
      {MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, &gl_init},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  int rc = mpv_render_context_create(&g_mpv.mpv_gl, g_mpv.mpv, params);
  if (rc < 0) {
    hein_log("render context 创建失败 rc=%d (%s)（共享上下文中）", rc,
             mpv_error_string(rc));
    return false;
  }
  mpv_render_context_set_update_callback(g_mpv.mpv_gl, on_mpv_render, NULL);
  hein_log("render context 已在**共享上下文**中创建（与 Flutter 同一命名空间）");

  // 补发被延迟的 loadfile（open 早于 render context 就绪的情况）。
  if (g_mpv.deferred_url != NULL) {
    char *url = g_mpv.deferred_url;
    g_mpv.deferred_url = NULL;
    hein_log("补发延迟的 loadfile：%s", url);
    hein_mpv_open_internal(url, g_mpv.deferred_start_sec,
                           g_mpv.deferred_is_live, g_mpv.deferred_hwdec,
                           g_mpv.deferred_cache_secs);
    g_free(url);
  }
  return true;
}

// 🔴🔴 2026-10-21 「幻灯片 / 直播卡死」修复：populate 期的围栏等待。
//
//    **运行在 Flutter raster 线程**，此时 Flutter 的 GL 上下文 current。
//    glWaitSync 只在该上下文的 GPU 命令流里插等待点，**CPU 立即返回**。
//
//    为什么不能像上一版那样在壳的渲染路径里 glFinish()：
//      渲染 tick 跑在 GTK 主线程，而 Linux 上 Flutter 的 platform 线程
//      就是 GTK 主线程。glFinish 每帧阻塞主线程 30~40ms（2880x1526 FBO），
//      主线程饱和 → Flutter 只有 6fps 采样（幻灯片）、PulseAudio 主循环
//      停摆（无声）、最终整进程挂死（69 真机 21:37:09 冻结）。
//
//    用 glWaitSync 则：壳主线程保持 25fps 不被阻塞，Flutter 的 GPU 侧
//    仍严格等到「帧写完」才采样 → 既不闪烁，也不掉帧、不卡死。
static void hein_wait_frame_fence(void *user) {
  (void)user;
  if (g_mpv.frame_fence == 0) return;

  // 🔴🔴🔴 2026-10-21 「幻灯片」真根因（必须记住）：
  //
  //    上一版这里用 100ms 超时。而围栏建在**未共享的上下文 A** 里，
  //    Flutter 侧 glClientWaitSync 恒返回 GL_WAIT_FAILED(0x911d)。
  //    于是**每一帧 populate 都空转满 100ms 才返回** ——
  //    100ms 超时 = 采样上限 10fps，实测正好 6fps，画面就是幻灯片。
  //
  //    与 GPU 算力毫无关系：890M 渲染 2880x1526 只需 2~3ms。
  //    这个「幻灯片」100% 是等待超时打出来的，不是渲染慢。
  //
  //    因此这里的策略必须改成「**绝不空转**」：
  //      · 正常路径：围栏已 signaled → 立即返回（零等待）
  //      · 围栏无效（WAIT_FAILED / 上下文不匹配）→ **立即丢弃围栏返回**，
  //        宁可这一帧不做同步，也绝不阻塞 raster 线程
  //      · 真超时 → 上限压到 4ms（≈240fps 的一帧），只兜底不惩罚
  GLenum r = glClientWaitSync(g_mpv.frame_fence, GL_SYNC_FLUSH_COMMANDS_BIT,
                              4000000ULL /* 4ms，ns */);
  if (r == GL_ALREADY_SIGNALED || r == GL_CONDITION_SATISFIED) {
    glDeleteSync(g_mpv.frame_fence);
    g_mpv.frame_fence = 0;
    g_mpv.fence_pending = false;
    return;
  }
  if (r == GL_WAIT_FAILED) {
    // 围栏与当前上下文不匹配（例如建在未共享的上下文 A）。
    // 立即丢弃并返回 —— 绝不能让一帧空转 100ms。
    static int s_wf = 0;
    if (++s_wf % 120 == 1) {
      hein_log("围栏无效(GL_WAIT_FAILED)，已丢弃并立即返回（第 %d 次）", s_wf);
    }
    glDeleteSync(g_mpv.frame_fence);
    g_mpv.frame_fence = 0;
    g_mpv.fence_pending = false;
    return;
  }
  // 真超时（GL_TIMEOUT_EXPIRED）：GPU 还没画完。保留围栏，
  // 下一帧渲染时会删除重建；本次采样可能拿到旧内容，但不阻塞。
  static int s_to = 0;
  if (++s_to % 120 == 1) {
    hein_log("围栏等待超时 r=0x%x（第 %d 次，将沿用旧帧）", r, s_to);
  }
}

// populate 的回调（**运行在 Flutter raster 线程**）：只记录参数并投递主线程。
static void hein_on_flutter_context_captured(void *context, void *display,
                                            void *user) {
  (void)user;
  if (g_mpv.share_rebuild_done) return;
  // 🔴 后端相关：EGL 后端存 EGLContext/EGLDisplay，GLX 后端存 GLXContext/Display*。
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    g_mpv.flutter_glx_context = (GLXContext)context;
    g_mpv.flutter_glx_display = (Display *)display;
  } else {
    g_mpv.flutter_egl_context = (EGLContext)context;
    g_mpv.flutter_egl_display = (EGLDisplay)display;
  }
  g_atomic_int_set(&g_mpv.flutter_ctx_captured, 1);
  g_idle_add(hein_create_shared_context_idle, NULL);
}
#endif

// 两平台共用：mpv 报告有新帧待渲染。真正画进 FBO 需要 GL 上下文 current，
// 由各平台的帧驱动函数执行（Linux: hein_mpv_render_to_fbo / Windows:
// hein_mpv_pump_windows），这里只置位。
static void on_mpv_render(void *ctx) {
  (void)ctx;
  // 播放失败后不再驱动渲染：避免空转占满 CPU、抢占 GTK 主线程
  // （这正是「播放失败 → 点关闭卡死」的诱因）。
  if (HEIN_SUSPEND_GET()) return;
  g_mpv.has_new_frame = true;
  // 🔴 2026-10-20：直接由 mpv 的 render update 回调驱动渲染。
  //    此前渲染靠 GTK 的 gtk_widget_add_tick_callback，而 **Impeller**
  //    （Flutter 3.47 Linux 强制后端，日志 "Using the Impeller rendering
  //    backend (OpenGLESSDF)"）自己管理帧，GTK 的 GdkFrameClock 不再被驱动
  //    → tick 回调不触发 → FBO 永远不画 → **进度条正常但画面全黑**。
  //    mpv 的 update 回调在其渲染线程触发，是官方推荐的帧驱动方式。
  hein_mpv_request_frame();
}
// mpv 事件处理：只保留与壳职责相关的，其余转发到 Dart。
// 🔴🔴 事件线程主循环（2026-10-20 根治）：
//    此前把它挂在 mpv_set_wakeup_callback 上，而该回调在 **mpv 内部线程**
//    被调用，在回调里调 mpv_wait_event() 是非线程安全的，实测**从未生效**
//    （file-loaded 一次都没触发 → 起播定位/续播 seek 全部失效）。
//    正解：起一个**独立线程**，在里面阻塞式 mpv_wait_event(-1) 消费事件。
static void *hein_event_thread(void *arg) {
  (void)arg;
  while (g_mpv.mpv != NULL && !g_mpv.disposed) {
    // 🔴🔴 2026-10-21 关闭卡死根因：此处原为 mpv_wait_event(mpv, -1)
    //    即**无限等待**。正常退出时 mpv_terminate_destroy 会投递
    //    MPV_EVENT_SHUTDOWN 打破它，看似没问题；但真实故障路径是
    //    「播放失败/网络源连不上」——此时 mpv 内部 demuxer 线程可能正
    //    卡在 socket 超时里，terminate_destroy 要等 core 线程退出而阻塞，
    //    事件线程也迟迟拿不到 SHUTDOWN，而 shutdown 流程又要 pthread_join
    //    它 → **主线程 join 无限等待 → 用户看到「点关闭后软件无响应」**。
    //    这与 Android 侧 2026-10-14 定位的「destroy 里 pthread_join 无超时」
    //    是同一类缺陷（见 HeinPlay 记忆）。
    //
    //    修法：改成 0.05s 短超时轮询，每轮检查 disposed/mpv 是否已置空，
    //    使事件线程能在 mpv 真正卡死时也**自行退出**，join 不再无限阻塞。
    //    注意：mpv_wait_event 返回 MPV_EVENT_NONE 表示「本轮无事件」，
    //    不是错误，continue 即可。
    mpv_event *ev = mpv_wait_event(g_mpv.mpv, 0.05);
    if (ev == NULL) continue;
    if (ev->event_id == MPV_EVENT_NONE) continue;
    if (ev->event_id == MPV_EVENT_SHUTDOWN) break;

    // 🔴 属性变化转发：time-pos / duration / demuxer-cache-time / paused
    //    全靠这条上来。此前壳从未 push 过事件（push_event 定义后无人调用），
    //    Dart 侧 EventChannel 收到 0 条，表现为「进度条不动」。
    // 🔴🔴 2026-10-27：`demuxer-cache-state`（NODE）里的 `cache-end`
    //   = demuxer 已缓冲到的**文件位置（秒）**⇒ 进度条缓冲条的右端。
    //   节点还含 cache-duration / fw-bytes 等诊断字段，这里只取需要的。
    if (ev->event_id == MPV_EVENT_PROPERTY_CHANGE) {
      mpv_event_property *prop = (mpv_event_property *)ev->data;
      if (prop != NULL && prop->name != NULL &&
          strcmp(prop->name, "demuxer-cache-state") == 0 &&
          prop->format == MPV_FORMAT_NODE && prop->data != NULL) {
        mpv_node *node = (mpv_node *)prop->data;
        if (node->format == MPV_FORMAT_NODE_MAP && node->u.list != NULL) {
          // 注：自建 mpv 发行包未安装 <mpv/node.h>（mpv_node_get 不可用），
          //     而 mpv_node / mpv_node_list 结构在 <mpv/client.h> 里是完整的
          //     ⇒ 直接遍历 MAP（MAP 与 ARRAY 共用 mpv_node_list：keys/values）。
          struct mpv_node_list *map = node->u.list;
          for (int i = 0; i < map->num; i++) {
            if (map->keys == NULL || map->keys[i] == NULL) continue;
            if (strcmp(map->keys[i], "cache-end") != 0) continue;
            mpv_node *v = &map->values[i];
            double cache_end = 0.0;
            if (v->format == MPV_FORMAT_DOUBLE) {
              cache_end = v->u.double_;
            } else if (v->format == MPV_FORMAT_INT64) {
              cache_end = (double)v->u.int64;
            }
            if (cache_end == cache_end && cache_end > 0.0) {
              hein_mpv_push_property("demuxer-cache-end", cache_end);
            }
            break;
          }
        }
      }
      // ⚠️⚠️ 2026-10-27 重大修正：**这里绝不能 `continue`**。
      //   本分支最初写成「名字不是 demuxer-cache-state 就 continue」，
      //   结果把 time-pos / duration / paused 等**所有其它属性事件全部吞掉**
      //   → Dart 侧收不到任何时间更新 → 进度条与 00:00/00:00 全废
      //   （画面照播，因为渲染走另一条链路，故障表现为「只有进度条坏」）。
      //   正确做法：cache-state 只做「额外处理」，随后**继续往下**走
      //   下面那个通用的 DOUBLE 属性分支（NODE 格式在那里不会命中任何分支）。
    }
    if (ev->event_id == MPV_EVENT_PROPERTY_CHANGE) {
      mpv_event_property *prop = (mpv_event_property *)ev->data;
      if (prop == NULL || prop->name == NULL) continue;
      double v = 0.0;
      int is_double = 0;
      if (prop->format == MPV_FORMAT_DOUBLE && prop->data != NULL) {
        v = *(double *)prop->data;
        is_double = 1;
      } else if (prop->format == MPV_FORMAT_INT64 && prop->data != NULL) {
        v = (double)*(int64_t *)prop->data;
        is_double = 1;
      } else if (prop->format == MPV_FORMAT_FLAG && prop->data != NULL) {
        v = *(int *)prop->data ? 1.0 : 0.0;
        is_double = 1;
      }
      if (is_double) hein_mpv_push_property(prop->name, v);
      continue;
    }
    if (ev->event_id == MPV_EVENT_END_FILE) {
      mpv_event_end_file *ef = (mpv_event_end_file *)ev->data;
      if (ef != NULL) {
        if (ef->reason == MPV_END_FILE_REASON_EOF) {
          hein_mpv_push_property("eof", 1.0);
        } else if (ef->reason == MPV_END_FILE_REASON_ERROR) {
          // 🔴🔴 2026-10-21「播放失败后 CPU 空转 + 关闭卡死」修复。
          //
          //    源不可达（如 CDN 拒绝 TLS、断网）时 mpv 报 END_FILE/ERROR。
          //    原实现只置 eof 标志，渲染循环照旧被 update 回调高频驱动：
          //    实测失败态下进程 CPU 长期 50%~104%，GTK 主线程被抢占，
          //    用户点「关闭」时 windowManager.destroy() 的消息迟迟得不到
          //    处理 → 表现为**软件卡死**。
          //
          //    故失败后主动停掉渲染驱动（置 suspended），不再向 Flutter
          //    提交帧；新一次 open 会清除该标志恢复正常渲染。
          HEIN_SUSPEND_SET(1);
          g_mpv.has_new_frame = false;
          hein_log("END_FILE(ERROR) code=%d → 暂停渲染驱动（避免空转）",
                   ef->error);
        }
      }
      continue;
    }
    if (ev->event_id == MPV_EVENT_LOG_MESSAGE) {
      mpv_event_log_message *lm = (mpv_event_log_message *)ev->data;
      if (lm != NULL && lm->text != NULL) {
        char *dup = g_strdup(lm->text);
        g_strstrip(dup);
        if (*dup) hein_log("mpv[%s] %s", lm->level ? lm->level : "?", dup);
        g_free(dup);
      }
      continue;
    }
    if (ev->event_id == MPV_EVENT_START_FILE) {
      hein_log("事件: START_FILE");
      continue;
    }
    if (ev->event_id == MPV_EVENT_FILE_LOADED) {
      hein_log("事件: FILE_LOADED");
      // 继续走下方 seek 逻辑
    }
    if (ev->event_id == MPV_EVENT_SHUTDOWN) {
      hein_log("收到 SHUTDOWN，结束事件线程");
      return NULL;
    }
    // file-loaded 后立即执行起播定位（教训④：不等 time-pos）。
    if (ev->event_id == MPV_EVENT_FILE_LOADED && g_mpv.pending_seek_pending) {
      const char *cmd[] = {"seek", NULL, "absolute+exact", NULL};
      char buf[32];
      snprintf(buf, sizeof(buf), "%.3f", g_mpv.pending_seek_sec);
      cmd[1] = buf;
      int rc = mpv_command(g_mpv.mpv, cmd);
      hein_log("file-loaded → 立即 seek target=%.3fs rc=%d",
               g_mpv.pending_seek_sec, rc);
      if (rc == 0) {
        g_mpv.pending_seek_pending = false;
        g_mpv.last_requested_sec = g_mpv.pending_seek_sec;
      }
    }
  }
  return NULL;
}

// ============================ 对外初始化 ============================

#ifndef _WIN32
// Linux：由插件 registrar 驱动。GL 上下文由 runner 的 GtkGLArea 提供，
// 这里只负责建 mpv/render context 并注册纹理。
bool hein_mpv_init_linux(FlPluginRegistrar *registrar,
                         FlMethodChannel *channel,
                         FlEventChannel *event_channel) {
  if (g_mpv.initialized) return true;
  // 🔴 2026-10-26：先装容错 X 错误处理器（X11 会话才有意义）。
  //    否则任何第三方（mpv/GTK）发起的 X 错误都会让 GDK 直接 abort 整个应用。
  hein_x_install_tolerant_error_handler();
  // 🔴 2026-10-26：装崩溃回溯处理器，把段错误调用栈写进 native 日志。
  hein_x_install_crash_backtrace_handler();
  g_mpv.registrar = registrar;
  g_mpv.channel = channel;
  g_mpv.event_channel = event_channel;
  g_mpv.texture_registrar =
      fl_plugin_registrar_get_texture_registrar(registrar);

  // 🔴🔴🔴 2026-10-26：**X11 会话下完全不做 mpv 视频初始化**。
  //
  // 【为什么】在 X11 会话下，只要我们（mpv 壳）在进程里 makeCurrent 一个
  //   EGL 上下文，GTK3 的 **GLX** 上下文就会坏掉 —— 即使我们的 display 是
  //   **surfaceless**（不碰任何 X drawable）也一样，因为 Mesa 的 EGL 与
  //   GLX 共享同一 X display 的内部状态。
  //   真机证据（69 掌机，桌面 X11 会话 DISPLAY=:0）：
  //     · 崩溃回溯：gdk_cairo_draw_from_gl ← libflutter_linux_gtk.so
  //       （引擎的合成路径 fl_compositor_opengl.cc，shareable=FALSE 分支）；
  //     · X 错误：BadAccess (X_GLXMakeCurrent) —— GTK3 的 GLX 上下文已失效；
  //     · 最小复现 /tmp/eglx11b：eglMakeCurrent(pbuffer)=1 之后
  //       紧接着的 glXMakeCurrent 报 BadAccess。
  //
  // 【为什么不能只「不共享」】不共享只是画面黑，但**崩溃来自 EGL 上下文的
  //   存在本身**（makeCurrent 就会污染 GLX 状态），与是否共享无关。
  //
  // 【正解】让**整个应用跑在 Wayland**：
  //   · GTK3 的 GdkGLContext 在 Wayland 下用 **EGL**（与引擎同 API）；
  //   · 引擎的 shareable=TRUE ⇒ 走纹理共享路径，**完全不碰 GLX**；
  //   · 桌面与游戏模式都已具备该条件（桌面本就是 Wayland；
  //     游戏模式由 runner 的 hein_force_gamescope_wayland() 切到
  //     gamescope 的 Wayland）。
  //
  // 【X11 下怎么办】🔴🔴🔴 2026-10-27 23:05 改为 **SW 软件渲染**（不再跳过视频）：
  //   X11 下不能共享 GL 上下文（EGL/GLX 互斥），但可以**完全不建 GL 上下文** ——
  //   用 mpv 的 MPV_RENDER_API_TYPE_SW 渲染到 CPU 内存，再经
  //   FlPixelBufferTexture 交给 Flutter 上传。零 GL 接触 ⇒ 绝不破坏 GLX。
  //   这条路径让「GTK 留在 X11（gamescope 才能合成上屏）」与「视频有画面」
  //   同时成立，正是游戏模式的解。
  {
    GdkDisplay *gdpy = gdk_display_get_default();
    const char *cls =
        (gdpy != NULL) ? G_OBJECT_TYPE_NAME((GObject *)gdpy) : NULL;
    const gboolean is_x11 =
        (cls != NULL && strstr(cls, "X11") != NULL) ? TRUE : FALSE;
    if (is_x11) {
      hein_log("X11 会话：走 **SW 软件渲染**（不建任何 GL 上下文，"
               "改用 mpv MPV_RENDER_API_TYPE_SW + FlPixelBufferTexture）。"
               "原因：X11 下 GTK3 用 GLX，进程内任何 EGL makeCurrent 都会"
               "破坏 GLX ⇒ 引擎崩溃；而 gamescope 未开 --expose-wayland，"
               "只合成 X11 客户端，GTK 不能切 Wayland。"
               "SW 路径零 GL 接触，两条约束同时满足。");
      g_mpv.sw_mode = TRUE;
      // 继续往下走：仍要 mpv_create / loadfile / 音频，
      // 只是 render context 换成 SW 类型（见下方分派）。
    }
  }

  // ① 🔴🔴 必须先设 LC_NUMERIC="C"，否则 mpv_create 直接返回 NULL！
  //
  //    mpv 的 mp_create() 第一件事就是 check_locale()（player/main.c:262），
  //    非 C locale 时打印
  //      "Non-C locale detected. This is not supported."
  //    并 return NULL —— 且**不设 errno**，所以壳侧看到的 errno 是
  //    残留值（本次实测 errno=11 EAGAIN，极具误导性）。
  //
  //    触发条件：Flutter 进程继承了用户 locale（中文环境 zh_CN.UTF-8）。
  //    独立进程里跑 mpv 无此问题（那些进程 locale 为 C/POSIX）。
  //
  //    ⚠️ 只改 LC_NUMERIC，不动 LC_CTYPE/LC_MESSAGES 等，
  //       不影响中文显示与路径处理。
  const char *prev_numeric = setlocale(LC_NUMERIC, NULL);
  if (prev_numeric != NULL && strcmp(prev_numeric, "C") != 0) {
    setlocale(LC_NUMERIC, "C");
    hein_log("LC_NUMERIC 由 %s 改为 C（mpv 硬性要求）", prev_numeric);
  }

  // ② mpv 实例（mpv_create 只分配内存，不依赖 GL）
  g_mpv.mpv = mpv_create();
  if (!g_mpv.mpv) {
    hein_log("mpv_create 失败（errno=%d %s）；mp_create/mp_new_client/"
             "mp_thread_create 三者之一返回失败",
             errno, strerror(errno));
    return false;
  }
  hein_log("mpv_create OK => %p", (void *)g_mpv.mpv);

  // ② EGL + GL 上下文：必须在 mpv_render_context_create **之前**建好并
  //    current，否则 render context 创建直接返回 -18 (not supported)。
  //    ⚠️ 不能先于 mpv_create：实测在 Flutter 进程内（已加载 Impeller /
  //       libflutter_linux_gtk）先建 EGL 再 mpv_create 会让 mpv_create
  //       返回 NULL；顺序反过来才正常。
  //
  // 🔴🔴 2026-10-21 关键架构结论（本机 /tmp/ctx_test 实测验证）：
  //
  //    · mpv **要求** render context 在 loadfile 前就存在，否则报
  //      `mpv[fatal] No render context set.`（把 render context 推迟
  //      到 populate 之后的做法因此不可行）。
  //    · 但 mpv 的 render context **可以在「与创建它的上下文共享」的
  //      另一个上下文里渲染**（实测：在 A 创建，切到共享的 B 后
  //      mpv_render_context_render 返回 0，成功）。
  //
  //    故正确架构是「两阶段、不销毁」：
  //      阶段①（此处，插件注册期）：建壳上下文 A（不共享）+ render context，
  //              让 mpv 立刻能 loadfile/解码/出声，播放不被打断。
  //      阶段②（首次 populate）：捕获 Flutter 真实上下文，建共享上下文 B，
  //              在 B 里新建纹理/FBO；mpv 直接在 B 中渲染出画。
  //    全程**不销毁** render context → 不会出现「播放中断/报播放失败」。
  // 🔴 2026-10-26：先按会话选好 GL 后端并填好 GL 函数表，再建上下文。
  //   （函数表必须在任何 GL 调用之前就绪）
  hein_gl_backend = hein_detect_gl_backend();
  hein_gl_api_init(hein_gl_backend);
  hein_log("GL 后端判定：%s", hein_gl_backend_name(hein_gl_backend));

  // 🔴🔴🔴 2026-10-27 23:05：SW 模式**不建任何 GL 上下文**。
  //   这是本路径的核心：不建 EGL/GLX ⇒ 不可能破坏 GTK3 的 GLX。
  if (g_mpv.sw_mode) {
    hein_log("SW 模式：跳过 GL 上下文创建（全程零 GL 接触）");
  } else if (!hein_create_gl_context()) {
    mpv_terminate_destroy(g_mpv.mpv);
    g_mpv.mpv = NULL;
    return false;
  }

  // ---- 教训②：渲染/同步选项必须在 initialize 之前 ----
  // 桌面默认走 Vulkan（用户硬要求「必须要用 vulkan」），失败时回退 GL。
  mpv_set_option_string(g_mpv.mpv, "vo", "libmpv");
  // 🔴🔴 2026-10-26：GPU API 必须与本进程的 GL 后端配套。
  //   · EGL/GLES2 后端（桌面 Wayland）⇒ 保持既有的 **vulkan**
  //     （mpv 内部把 Vulkan 画面导入 GL 纹理；这一路已验证可用）。
  //   · GLX/桌面GL 后端（游戏模式 X11）⇒ 必须改用 **opengl**：
  //     Vulkan → GLX 的跨 API 纹理导入在 GLX 下不可用，
  //     而 opengl 让 mpv 直接用**同一个 GL 命名空间**渲染到 FBO，
  //     纹理共享天然成立。
  // 🔴🔴🔴 2026-10-26：gpu-api 保持 **vulkan**（用户硬要求「必须用 vulkan」）。
  //
  //   mpv 源码 video/out/gpu/libmpv_gpu.c：render API（vo=libmpv）只有
  //   **一个**上下文后端 `libmpv_gpu_context_gl`，它调
  //   `ra_gl_ctx_init()` → `ra_create_gl()` ⇒ mpv **直接用我们提供的
  //   GL 上下文**把画面渲染到我们的纹理上。
  //   整个 mpv 源码树里**不存在** `MPV_RENDER_API_TYPE_VULKAN`
  //   （render.h 只定义了 OpenGL 与 Software 两种）。
  //   ⇒ `gpu-api` 在这条路径上只是**类型过滤器**（给 gpu-context 用的），
  //     并不选择「渲染引擎」；出画始终是 OpenGL/GLES。
  //   ⇒ 保持 vulkan 不变（Vulkan 仍由硬解与驱动内部使用），不因类型
  //     过滤误伤 gpu-context 的选择。
  mpv_set_option_string(g_mpv.mpv, "gpu-api", "vulkan");
  // 🔴🔴🔴 2026-10-26：gpu-context **不下发**（此前下发了 auto/x11egl）。
  //
  //   mpv 源码 video/out/gpu/context.c：`ra_ctx_create()`（唯一使用
  //   `--gpu-context` 的地方）**只被 `vo_gpu.c` 与 `gpu_next/context.c`
  //   调用**；而我们走的是 `vo=libmpv` → `render_backend_gpu`
  //   → `libmpv_gpu.c` → `libmpv_gpu_context_gl` → `ra_gl_ctx_init()`，
  //   这条路径**只使用我们提供的 GL 上下文**，完全不读 gpu-context。
  //   ⇒ 之前下发 `auto`（X11 会话会选 GLX）与 `x11egl` 都是**无效设置**，
  //     徒增误解；这里改为只把会话环境打进日志供排查。
  //
  //   【那 GLX 的 X 错误从哪来？】不是 mpv 的 gpu-context，而是
  //   **GTK3 的 GdkGLContext**：Flutter 引擎 fl_view_renderer.cc 用
  //   `gdk_window_create_gl_context()` 建渲染上下文，GTK3 在 X11 下
  //   用 GLX 实现（Wayland 下用 EGL）。见本次真机日志的调用栈取证。
  {
    const char *sess = g_getenv("XDG_SESSION_TYPE");
    const char *desk = g_getenv("XDG_CURRENT_DESKTOP");
    const char *gpu = g_getenv("SteamGamepadUI");
    hein_log("会话环境：XDG_SESSION_TYPE=%s XDG_CURRENT_DESKTOP=%s "
             "SteamGamepadUI=%s（gpu-context 对 vo=libmpv 不生效，不下发）",
             sess ? sess : "-", desk ? desk : "-", gpu ? gpu : "-");
  }
  mpv_set_option_string(g_mpv.mpv, "hwdec", "auto-safe");
  // 🔴 init-only：运行期设会返回 -7，必须在这里设。
  //    允许硬解失败时回退软解，否则部分设备（如 Bazzite/AMD）会黑屏。
  mpv_set_option_string(g_mpv.mpv, "hwdec-software-fallback", "yes");

  // 教训①：音画同步（照搬鸿蒙已验证配置）
  mpv_set_option_string(g_mpv.mpv, "video-sync", "audio");
  // 🔴 2026-10-21：配合 MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME=0 使用。
  //    mpv 官方文档明确建议：关闭 render 内部阻塞等待时，应把
  //    video-timing-offset 也设为 0，否则 mpv 仍会预留「提前量」导致
  //    A/V 有轻微偏差。设为 0 表示不做提前渲染，帧准备好就交。
  mpv_set_option_string(g_mpv.mpv, "video-timing-offset", "0");
  mpv_set_option_string(g_mpv.mpv, "video-sync-max-video-change", "1.0");
  mpv_set_option_string(g_mpv.mpv, "profile", "fast");
  mpv_set_option_string(g_mpv.mpv, "interpolation", "no");
  mpv_set_option_string(g_mpv.mpv, "framedrop", "yes");

  // 网络/缓冲：对齐 Android 侧的 tls-verify=no 与大 demux 缓存
  mpv_set_option_string(g_mpv.mpv, "tls-verify", "no");
  mpv_set_option_string(g_mpv.mpv, "demuxer-max-bytes", "1024MiB");
  mpv_set_option_string(g_mpv.mpv, "demuxer-max-back-bytes", "512MiB");
  mpv_set_option_string(g_mpv.mpv, "cache", "yes");

  // 教训⑥：不静默回退软解之外，也不开启 osc（无 OSD）
  mpv_set_option_string(g_mpv.mpv, "osc", "no");
  mpv_set_option_string(g_mpv.mpv, "idle", "yes");
  mpv_set_option_string(g_mpv.mpv, "keep-open", "yes");

  if (mpv_initialize(g_mpv.mpv) < 0) {
    hein_log("mpv_initialize 失败");
    return false;
  }
  // 🔴 2026-10-26：把 mpv **实际**选中的上下文/渲染后端打出来。
  //   这是「是否真的绕开了 GLX」的唯一权威证据（选项值只是我们的意图，
  //   mpv 仍可能因环境不支持而回退到别的后端）。
  {
    // ⚠️ mpv_get_property_string 返回的是**非 const** 指针（需 mpv_free 释放），
    //   用 const char* 接会触发 -Wincompatible-pointer-types 警告（构建按 Werror 失败）。
    char *ctx = mpv_get_property_string(g_mpv.mpv, "current-gpu-context");
    char *api = mpv_get_property_string(g_mpv.mpv, "current-gpu-api");
    hein_log("mpv 实际后端：current-gpu-context=%s current-gpu-api=%s",
             ctx ? ctx : "(null)", api ? api : "(null)");
    if (ctx) mpv_free(ctx);
    if (api) mpv_free(api);
  }

  // ---- 属性观察：进度/时长/缓存/暂停态全靠这些事件上推 ----
  //    ⚠️ 必须在 initialize 之后（observe_property 需要已初始化的实例）。
  mpv_observe_property(g_mpv.mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
  mpv_observe_property(g_mpv.mpv, 0, "duration", MPV_FORMAT_DOUBLE);
  mpv_observe_property(g_mpv.mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
  // 🔴🔴 2026-10-27：Linux 端缓冲条需要「已缓冲到的文件位置」。
  //    `demuxer-cache-time` 是**已缓冲总时长**（随播放堆积，可达数百秒），
  //    直接当位置用会让缓冲条撑出一大截（真机截图：46% 处画到 65%）。
  //    正确值在 `demuxer-cache-state` 节点里的 `cache-end`（文件内秒数）。
  //    仅新增观察，Windows 侧忽略该事件名 ⇒ Windows 行为不变。
  mpv_observe_property(g_mpv.mpv, 0, "demuxer-cache-state", MPV_FORMAT_NODE);
  mpv_observe_property(g_mpv.mpv, 0, "paused", MPV_FORMAT_FLAG);
  mpv_observe_property(g_mpv.mpv, 0, "eof-reached", MPV_FORMAT_FLAG);

  // ---- 🔴🔴 2026-10-21 架构调整：**不在这里创建 render context** ----
  //
  //    原实现：init 时用「不共享的壳上下文」建 render context，等首次
  //    populate 捕获到 Flutter 上下文后再**销毁重建**成共享版本。
  //
  //    这个「先建再销毁重建」正是回归的根源：populate 首次触发时播放
  //    已经开始，销毁 render context 会把 mpv 的 vo 打断 → mpv 报
  //    END_FILE(ERROR) → Dart 侧判定「播放失败」（用户实测：同样的源，
  //    原来黑屏有声，现在直接报播放失败）。
  //
  //    正确做法：**推迟到拿到 Flutter 上下文之后再建，只建一次**。
  //    mpv 在 render context 创建前可以正常 loadfile/解码（idle=yes），
  //    音频照常输出；等 populate 捕获到 Flutter 上下文 → 主线程用共享
  //    上下文建 render context → 开始出画。全程无销毁、不打断播放。
  //
  //    ⚠️ 因此 hein_create_egl_context() 也不再在 init 阶段调用：
  //       它的唯一用途就是给 render context 提供 current 的 GL 上下文。
  // ---- 创建 GL render context：**推迟到共享上下文建好之后**（2026-10-26）----
  //
  //   🔴🔴 这里**故意不建** render context。原因见结构体 deferred_url 处
  //   的长注释：mpv 的 GL 资源（含不可跨上下文共享的 VAO）会绑定在
  //   「创建 render context 时 current 的那个上下文」上。若此刻用未共享
  //   的壳上下文 A 建，之后阶段②切到共享上下文 B 渲染，mpv 的全部
  //   GL 资源在 B 中失效 ⇒ draw 静默失败 ⇒ **全黑但有声音**。
  //
  //   新时序：
  //     ① init：mpv_initialize + 属性 + 注册 FlTexture（此阶段无 GL 需求）
  //     ② 首次 populate 捕获 Flutter 上下文 → 建共享上下文 B
  //     ③ **在 B 里**建 render context（只建一次）
  //     ④ 若 open 早于 ③ 到达，URL 先暂存，这里补发 loadfile
  //
  //   mpv 允许在 render context 之前 mpv_initialize / set_option；
  //   唯一硬约束是 loadfile 时 vo_libmpv preinit 需要 render context
  //   （否则 "No render context set."）—— 已由延迟 loadfile 覆盖。
  hein_log("render context 推迟创建：等 Flutter 上下文就绪后在共享上下文里建一次");

  // 事件：启动独立事件线程（不用 wakeup 回调，见 hein_event_thread 注释）
  {
    const char *mlv = g_getenv("HEIN_MPV_LOG");
    mpv_request_log_messages(g_mpv.mpv, (mlv && *mlv) ? mlv : "no");
  }
  // 🔴 必须记录启动成功，shutdown 才会 join 它（否则退出时线程仍在跑）。
  g_mpv.event_thread_started =
      (pthread_create(&g_mpv.event_thread, NULL, hein_event_thread, NULL) == 0);
  hein_log("事件线程已启动（started=%d）", (int)g_mpv.event_thread_started);

  // 纹理对象：**此处只创建对象并注册，不建 GL 资源**。
  //
  // 🔴🔴🔴 2026-10-27 23:05：SW 模式用 FlPixelBufferTexture（CPU 像素上传），
  //   完全不涉及 GL；GL 模式才用 FlTextureGL（外部纹理）。
  if (g_mpv.sw_mode) {
    g_mpv.sw_texture = hein_sw_texture_new();
    gboolean ok = fl_texture_registrar_register_texture(
        g_mpv.texture_registrar, FL_TEXTURE(g_mpv.sw_texture));
    if (!ok) {
      hein_log("SW 纹理注册失败");
      return false;
    }
    g_mpv.registered_texture_id =
        fl_texture_get_id(FL_TEXTURE(g_mpv.sw_texture));
    hein_log("SW 纹理已注册 id=%" G_GINT64_FORMAT "（FlPixelBufferTexture）",
             g_mpv.registered_texture_id);
    // SW 模式不需要 populate/共享上下文/围栏：直接建 render context 并放行。
    hein_ensure_render_context_locked();
    // 启动独立渲染线程（脱离 GTK 主线程，见 hein_sw_render_thread 注释）。
    hein_sw_render_thread_start();
    g_mpv.initialized = true;
    // 补发延迟的 loadfile（render context 已就绪）。
    if (g_mpv.deferred_url != NULL) {
      char *url = g_mpv.deferred_url;
      g_mpv.deferred_url = NULL;
      hein_log("SW 模式补发 loadfile：%s", url);
      hein_mpv_open_internal(url, g_mpv.deferred_start_sec,
                             g_mpv.deferred_is_live, g_mpv.deferred_hwdec,
                             g_mpv.deferred_cache_secs);
      g_free(url);
    }
    hein_log("SW 模式初始化完成（textureId=%" G_GINT64_FORMAT "）",
             g_mpv.registered_texture_id);
    return true;
  }

  g_mpv.gl_texture =
      g_object_new(HEIN_TYPE_GL_TEXTURE, NULL);
  hein_gl_texture_set_share_context(g_mpv.gl_texture, g_mpv.egl_context,
                                    g_mpv.egl_display);
  // 🔴 关键：把「首次 populate 捕获 Flutter 上下文」的回调挂上。
  //    插件注册期拿不到 Flutter 的 context（尚未 current），只有 populate
  //    时引擎已 eglMakeCurrent(resource_context)，才能捕获真实上下文并
  //    据此创建共享上下文（见 hein_create_shared_context_idle）。
  hein_gl_texture_set_share_callback(g_mpv.gl_texture,
                                     hein_on_flutter_context_captured, NULL);
  // 🔴 采样前等待 GPU 围栏（替代壳侧阻塞式 glFinish，见 hein_wait_frame_fence）
  hein_gl_texture_set_wait_fence_callback(g_mpv.gl_texture,
                                          hein_wait_frame_fence, NULL);
  gboolean registered = fl_texture_registrar_register_texture(
      g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
  if (registered) {
    g_mpv.registered_texture_id =
        fl_texture_get_id(FL_TEXTURE(g_mpv.gl_texture));
    hein_log("纹理已注册 id=%" G_GINT64_FORMAT, g_mpv.registered_texture_id);
  } else {
    hein_log("纹理注册失败");
    return false;
  }

  // 🔴🔴🔴 2026-10-26 23:05 **起播慢 15 秒的根治：注册后立刻催 Flutter 采样一次。**
  //
  //   真机铁证（69，桌面 Wayland，22:59 那次）：
  //     22:59:22  open → 已暂存（等 render context）
  //     22:59:22 → 22:59:37  **Dart 侧无任何播放日志**（只有 HB-UI 心跳）
  //     22:59:37  首次 populate 才到来 → 阶段② → 补发 loadfile
  //     ⇒ 点击播放到真正开始拉流，白等 **15 秒**。
  //
  //   机制：populate 只在 **Flutter 重绘** 时被引擎调用。
  //   而本版本 render context 推迟到首次 populate 之后才建，
  //   ⇒ mpv 还没 loadfile、没有新帧 ⇒ 画面静止 ⇒ Flutter 不重绘
  //   ⇒ populate 不来 ⇒ render context 建不起来 ⇒ 互相干等，
  //   直到某个无关动画（心跳/加载指示器）恰好触发一次重绘才解开。
  //
  //   修法：注册完纹理就**主动 mark 一帧可用**，让引擎立刻安排一次
  //   采样（raster 线程）→ populate 立即到来 → 阶段② → 补发 loadfile。
  //   mark_texture_frame_available 是线程安全的，可在主线程调用。
  if (g_mpv.registered_texture_id > 0 && g_mpv.texture_registrar != NULL) {
    fl_texture_registrar_mark_texture_frame_available(
        g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
    hein_log("已主动通知 Flutter 采样一次（催促首次 populate，避免起播干等）");
  }

  g_mpv.initialized = true;

  // 🔴 自检开关（默认关闭，仅供排障）：HEIN_MPV_SELFTEST=<文件或URL>
  //    设置后立即加载该媒体并驱动渲染，用于在无 UI 交互的环境下验证
  //    「mpv 渲染 → FBO → FlTextureGL → populate」整条链路。
  const char *selftest = g_getenv("HEIN_MPV_SELFTEST");
  if (selftest != NULL && *selftest != '\0') {
    // 2026-10-26：自检默认软解；HEIN_MPV_SELFTEST_HWDEC=1 时走硬解，
    //   用于在无 UI 的环境下验证 VAAPI 链路（正常播放由 Dart 侧传参）。
    const char *selftest_hw = g_getenv("HEIN_MPV_SELFTEST_HWDEC");
    const bool st_hwdec = (selftest_hw != NULL && *selftest_hw != '\0');
    hein_log("自检模式：加载 %s（hwdec=%d）", selftest, (int)st_hwdec);
    hein_mpv_open(selftest, 0.0, false, st_hwdec, 30);
    // 起一个定时器周期性尝试渲染（不依赖 Flutter 帧回调）
    g_timeout_add(16, hein_selftest_tick, NULL);
  }
  return true;
}

gint64 hein_mpv_texture_id_linux(void) {
  return g_mpv.registered_texture_id;
}

#endif  // !_WIN32 (Linux)

// ============================ Windows 初始化 ============================
//
// 🔴🔴 2026-10-21 架构重定：**D3D11 render API**（步骤0 实测 libmpv-2.dll 的
//     mpv_render_context_create(MPV_RENDER_API_TYPE_D3D11) 返回 0，见
//     /tmp/dll_probe2.c 在 wine+Xvfb 下的输出）。
//
//     旧实现（已删除）：WGL 上下文 + mpv GL render API → GL FBO
//       → glReadPixels 同步读回 → CPU 逐行翻转 + R/B 交换 → UpdateSubresource
//       上传 D3D11。1920x1080 每帧 8.3MB，60fps ≈ 500MB/s PCIe 往返，必然幻灯片。
//
//     新实现：mpv(D3D11 render API) → 我们的 ID3D11Texture2D → DXGI 共享句柄
//       → Flutter 引擎 OpenSharedHandle + ANGLE 绑成 GL 纹理采样。
//       全程 GPU 内完成，**零 CPU 拷贝**。
//
//     与 Linux 的对应关系：
//       Linux   : epoxy/EGL + GL 外部纹理(hein_gl_texture.c) + GTK 定时器驱动
//       Windows : D3D11 render API + D3D11 外部纹理(hein_win_texture.cpp)
//                 + **独立渲染线程**驱动（见下）
#ifdef _WIN32
#include <d3d11.h>

// 不 include hein_win_texture.h：它是 C++ 头（含 WRL/ComPtr）。
// 此处只做 extern "C" 前向声明；实现在 hein_win_texture.cpp（同一 DLL）。
#ifdef __cplusplus
extern "C" {
#endif
typedef struct HeinWinTexture HeinWinTexture;
HeinWinTexture *hein_win_texture_create(
    FlutterDesktopTextureRegistrarRef registrar);
bool hein_win_ensure_size(HeinWinTexture *t, int width, int height);
ID3D11Texture2D *hein_win_texture_d3d(HeinWinTexture *t);
ID3D11Device *hein_win_texture_device(HeinWinTexture *t);
bool hein_win_texture_ready(HeinWinTexture *t);
void hein_win_texture_notify_frame(HeinWinTexture *t);
void hein_win_texture_present(HeinWinTexture *t);
bool hein_win_texture_probe(HeinWinTexture *t, int *nonzero_out,
                            int *total_out, unsigned *first_pixel_out);
int64_t hein_win_texture_id(HeinWinTexture *t);
void hein_win_texture_destroy(HeinWinTexture *t);
#ifdef __cplusplus
}
#endif

// mpv 的 D3D11 结构体。⚠️ 预编译包 third_party/mpv-windows/include 里
// **没有** render_d3d11.h（只发了 render.h），故按 mpv 官方源码
// （include/mpv/render_d3d11.h）字段逐一硬编码，并在下面做编译期断言防护。
// 字段极少且是 ABI 稳定的 POD，硬编码风险可控。
typedef struct hein_mpv_d3d11_init_params {
  void *device;  // ID3D11Device*
} hein_mpv_d3d11_init_params;

typedef struct hein_mpv_d3d11_fbo {
  void *tex;  // ID3D11Texture2D*
} hein_mpv_d3d11_fbo;

// ---------------- 渲染线程（P0-1 帧驱动修复）----------------
//
// 🔴🔴 为什么必须是独立线程：
//   1) mpv 的 update 回调（on_mpv_render）跑在 **mpv 自己的线程**上。
//      D3D11 render context 与 device 是在哪个线程创建的，官方要求之后
//      仍在同一线程调用 mpv_render_context_render。
//   2) 若把渲染塞进主线程（Flutter platform 线程），video-sync=audio 下
//      render 内部会阻塞 sleep 到目标显示时刻（25fps ≈ 40ms/帧）→ 饿死
//      Flutter → 幻灯片。
//   3) render_d3d11.h 明确：mpv 渲染时不恢复 D3D11 状态，且「其它线程不得
//      在 mpv_render_* 运行期间使用 immediate context」。固定单线程渲染
//      才能自然满足这条。
// 故：固定一个渲染线程 + Win32 事件唤醒，主线程完全不参与渲染。
static DWORD WINAPI hein_render_thread_proc(LPVOID unused) {
  (void)unused;
  hein_log("渲染线程已启动 tid=%lu", (unsigned long)GetCurrentThreadId());
  while (g_mpv.render_thread_running) {
    // 等 mpv 报告新帧；100ms 超时兜底（检查退出标志，也防永久挂起）。
    DWORD wr = WaitForSingleObject(g_mpv.render_wake_event, 100);
    if (!g_mpv.render_thread_running) break;
    if (wr == WAIT_FAILED) {
      hein_log("渲染线程 WaitForSingleObject 失败 err=%lu",
               (unsigned long)GetLastError());
      break;
    }
    hein_mpv_pump_windows();
  }
  hein_log("渲染线程退出");
  return 0;
}

// 帧驱动入口（渲染线程内调用）：mpv → D3D11 纹理 → 通知 Flutter。
bool hein_mpv_pump_windows(void) {
  if (g_mpv.mpv_gl == NULL || g_mpv.win_texture == NULL) return false;
  if (!g_mpv.has_new_frame) return false;
  // 失败态/暂停态：不再出帧（避免无谓 GPU 操作空转）。
  if (HEIN_SUSPEND_GET()) return false;
  g_mpv.has_new_frame = false;

  // ---- 尺寸决策（照搬 Linux 已验证逻辑，P0-6 修复）----
  // ① view_w/view_h —— Dart 上报的视频层控件尺寸，**优先**。
  //    这是唯一能让 mpv 做 letterbox 的路径：FBO = 控件尺寸，mpv 在该尺寸内
  //    按视频自身宽高比绘制，多出的部分由 Flutter 层填黑边。
  // ② video-out-params/w,h —— 兜底：无控件尺寸时用视频自身尺寸。
  // ③ width,height          —— 解码后的视频尺寸（首帧 out-params 可能为 0）。
  int w = 0, h = 0;
  const char *size_src = "none";
  if (g_mpv.view_w > 4 && g_mpv.view_h > 4) {
    w = g_mpv.view_w;
    h = g_mpv.view_h;
    size_src = "view";
  }
  if (w <= 0 || h <= 0) {
    double out_w = hein_mpv_get_double("video-out-params/w", 0);
    double out_h = hein_mpv_get_double("video-out-params/h", 0);
    if (out_w > 0 && out_h > 0) {
      w = (int)out_w;
      h = (int)out_h;
      size_src = "video-out-params";
    }
  }
  if (w <= 0 || h <= 0) {
    double vw = hein_mpv_get_double("width", 0);
    double vh = hein_mpv_get_double("height", 0);
    if (vw > 0 && vh > 0) {
      w = (int)vw;
      h = (int)vh;
      size_src = "video-params";
    }
  }
  // 尺寸未就绪：保留请求下次再试（绝不能退到 2x2 占位，否则黑屏）。
  if (w <= 4 || h <= 4) {
    g_mpv.has_new_frame = true;
    return false;
  }
  // 🔴 2026-10-22：把「这一帧用哪个尺寸来源」打出来（只在变化时打一次）。
  //    排查黑屏时最需要确认的就是 view_w 到底有没有生效 ——
  //    若这里长期显示 video-out-params，说明 Dart 的 setViewSize 又没送到。
  {
    static int s_last_w = -1, s_last_h = -1;
    static const char *s_last_src = NULL;
    if (w != s_last_w || h != s_last_h || size_src != s_last_src) {
      hein_log("渲染尺寸 %dx%d（来源 %s）", w, h, size_src);
      s_last_w = w;
      s_last_h = h;
      s_last_src = size_src;
    }
  }
  // ---- FBO/纹理尺寸等比收敛（照搬 Linux，避免无效超采样）----
  {
    double src_w = hein_mpv_get_double("video-params/w", 0);
    double src_h = hein_mpv_get_double("video-params/h", 0);
    if (src_w > 0 && src_h > 0 && w > 4 && h > 4) {
      double sx = src_w / (double)w;
      double sy = src_h / (double)h;
      double sc = sx < sy ? sx : sy;
      if (sc < 1.0) {
        int nw = (int)(w * sc + 0.5);
        int nh = (int)(h * sc + 0.5);
        if (nw >= 320 && nh >= 180) {
          w = nw;
          h = nh;
        }
      }
    }
  }

  HeinWinTexture *tex = (HeinWinTexture *)g_mpv.win_texture;
  if (!hein_win_ensure_size(tex, w, h)) {
    // 🔴 2026-10-22：重建失败/推迟时**必须保留 has_new_frame**，否则
    //    这一帧请求就丢了，渲染线程要等 mpv 下一次 update 回调才再被唤醒
    //    —— 若恰好 mpv 已停止发帧（暂停/首帧前），就永久黑屏。
    g_mpv.has_new_frame = true;
    return false;
  }
  ID3D11Texture2D *rt = hein_win_texture_d3d(tex);
  if (rt == nullptr) {
    g_mpv.has_new_frame = true;
    return false;
  }

  // ---- 渲染（mpv → 我们的 D3D11 纹理）----
  // ⚠️ C++ 编译单元不支持 C99 指定初始化，逐字段赋值。
  // mpv_d3d11_fbo 只有一个字段 tex（见上）。
#ifdef __cplusplus
  hein_mpv_d3d11_fbo mpv_fbo;
  mpv_fbo.tex = (void *)rt;
#else
  hein_mpv_d3d11_fbo mpv_fbo = {.tex = (void *)rt};
#endif
  // 🔴🔴🔴 2026-10-22 闪退根因（0xC0000005 @ libmpv-2.dll+0x1061b25）：
  //
  //   BLOCK_FOR_TARGET_TIME 的参数类型是 **int\***（官方 render.h 原文
  //   「Type: int*: 0 for disable, 1 for enable (default)」），mpv 内部会
  //   **解引用** 这个指针去读那个 int。原实现写的是
  //       {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, (void *)0}
  //   即传了 **NULL** —— mpv 一解引用就空指针崩溃（异常 0xC0000005，
  //   故障模块 libmpv-2.dll，偏移恒定 0x1061b25）。
  //
  //   症状特征：mpv 初始化、open、FILE_LOADED、纹理重建全部正常，
  //   日志断在「D3D11 纹理已重建」之后 —— 正是第一次 render 的那一行；
  //   点播与直播都崩（两者共用同一个 pump）。
  //
  //   真机二分验证（探针 probe.exe / probe2.exe）：
  //     传 &block  → exit 0，正常出帧；
  //     传 NULL    → 0xC0000005 @ libmpv-2.dll+0x1061b25（与产品一致）。
  //
  //   修法：必须传一个**有效 int 的地址**，其值为 0 表示不阻塞。
  //   ⚠️ 不能改成「直接不传这个参数」——不传时 mpv 走默认值 1（启用阻塞），
  //      会把渲染线程阻塞到目标显示时刻，反而退回「幻灯片」老问题。
  int block_for_target_time = 0;
  mpv_render_param rparams[] = {
      // FBO 用控件收敛后的尺寸（mpv 会按视频宽高比在内部 letterbox）
      {MPV_RENDER_PARAM_D3D11_FBO, (void *)&mpv_fbo},
      // BLOCK_FOR_TARGET_TIME=0：不阻塞等待目标显示时刻（值 0 = 禁用阻塞）。
      // 理由：阻塞会饿死渲染线程/主线程；帧率由 update 回调自然节流，
      // 且 video-timing-offset=0 已配套设置（见 init）。
      {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, (void *)&block_for_target_time},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  int rc = mpv_render_context_render(g_mpv.mpv_gl, rparams);
  // render 失败**不清除** has_new_frame：下一轮仍尝试（D3D11 设备丢失时
  // 常见，恢复后可自愈）。成功则报告 swap + 通知 Flutter。
  if (rc < 0) {
    // 🔴 2026-10-22：render 失败原本完全静默 —— 黑屏时日志里一点线索都没有。
    //    只在前 20 次打印，避免刷屏，但足以定位。
    static int s_render_fail = 0;
    if (++s_render_fail <= 20) {
      hein_log("mpv_render_context_render 失败 rc=%d (%s)，第 %d 次",
               rc, mpv_error_string(rc), s_render_fail);
    }
    g_mpv.has_new_frame = true;
    return false;
  }
  mpv_render_context_report_swap(g_mpv.mpv_gl);
  // 🔴 2026-10-22 双缓冲：mpv 已把这一帧画进**后台**纹理，这里在同一个
  //    渲染线程上立刻拷到**前台**纹理（引擎采样的那块）。两步都在
  //    immediate context 上入队，GPU 内完成，无 CPU 往返。
  //    为什么必须双缓冲：mpv 用我们的 device、引擎用它自己的 device 打开
  //    同一块共享纹理；若前后台是同一块，引擎读与 mpv 写会并发落在同一
  //    资源上 → 崩在 d3d11.dll（0xC0000005）。真机验证：单缓冲必崩，
  //    双缓冲不崩。
  hein_win_texture_present(tex);
  hein_win_texture_notify_frame(tex);
  InterlockedIncrement(&g_mpv.render_frame_count);

  // 🔴 2026-10-22 黑屏诊断：前若干帧回读前台纹理，判断 mpv 到底有没有
  //    把内容画进纹理。这段是**决定性证据**：
  //      · 若 nonzero 比例高 → 纹理里有画面，问题在 Flutter 采样侧
  //        （共享句柄/格式/引擎未刷新），与 mpv 无关；
  //      · 若 nonzero=0 → mpv 没画进去（render 参数、FBO、色彩转换问题）。
  //    只在第 1、2、3、5、10、30、60、120 帧打印，避免刷屏。
  {
    LONG n = InterlockedCompareExchange(&g_mpv.render_frame_count, 0, 0);
    if (n == 1 || n == 2 || n == 3 || n == 5 || n == 10 || n == 30 ||
        n == 60 || n == 120) {
      int nz = 0, total = 0;
      unsigned first = 0;
      if (hein_win_texture_probe(tex, &nz, &total, &first)) {
        hein_log("出画探针 第 %ld 帧：非零像素 %d/%d（%.0f%%）首点 BGRA=0x%08X",
                 n, nz, total, total > 0 ? 100.0 * nz / total : 0.0, first);
      } else {
        hein_log("出画探针 第 %ld 帧：回读失败（探针纹理不可用）", n);
      }
    }
  }
  return true;
}

bool hein_mpv_init_windows(FlutterDesktopTextureRegistrarRef registrar,
                           HeinWinTexture **out_texture) {
  // 🔴🔴🔴 2026-10-22 第二次进入播放「进度条为 0 / 无法点选 / 再切回 mpv
  //         无法播放」+ 直播闪退的**共同根因**：
  //
  //   `g_mpv.disposed` 在 hein_mpv_shutdown() 里被置 true，但**全项目没有
  //   任何一处把它复位**。它是进程级静态变量，一旦第一次播放结束就永久
  //   为 true。后果是「第二次及以后」的所有会话都带着一个已死亡的标志启动：
  //
  //   ① 事件线程的循环条件是
  //          while (g_mpv.mpv != NULL && !g_mpv.disposed)
  //      disposed 已是 true → 线程**启动后立刻退出**，一条事件都收不到。
  //      而 time-pos / duration / paused / eof-reached 全靠这条线程上行
  //      → Dart 侧 duration 恒为 0 → **进度条为 0、无法点选/拖动**
  //      → 也没有 FILE_LOADED → pending_seek 永不执行 → 表现为「重新播放」。
  //
  //   ② 更致命的是 shutdown 的第一行就是
  //          if (g_mpv.disposed) return;
  //      disposed 仍为 true → **第二次 shutdown 直接空转返回**，
  //      `initialized = false` 那句永远执行不到 → initialized 卡在 true。
  //      于是**第三次 init 在 `if (g_mpv.initialized) return true;` 处
  //      假成功返回**，插件层拿到 ok=true 但 mpv/mpv_gl 全是上一轮的
  //      悬空指针 → render 恒返回 -18 (MPV_ERROR_UNSUPPORTED)
  //      → 黑屏无画面（正是 12:25:47 那 20 条日志）。
  //
  //   ③ 直播路径要等 FILE_LOADED / 首帧事件才建立状态，事件线程死掉后
  //      这些永远不会到达；同时 mpv_terminate_destroy 与仍在跑的渲染线程
  //      形成竞态 → 崩在 heinplay_mpv_desktop.dll+0x8e68 (0xC0000005)。
  //
  //   修法：init 入口必须把 disposed 复位（它描述的是「当前实例是否已
  //   销毁」，属于每次 init/shutdown 成对的生命周期状态，不是进程级状态）。
  //   这与 shutdown 里重置 has_new_frame / view_w / suspended 是同一类
  //   修复 —— 只重置一半状态，剩下的一半就会在第二次启动时咬人。
  g_mpv.disposed = false;

  // 状态一致性兜底：`initialized` 为 true 但底层对象已空，说明上一次
  // shutdown 半途返回（历史 bug 的残留形态）。此时若仍走下面的
  // `if (g_mpv.initialized) return true;` 会「假成功」——插件层以为 mpv
  // 已就绪，实际 mpv_gl/mpv 都是野指针 → open 能返回 rc=0 但 render
  // 恒失败（-18），甚至 UAF 崩溃。这里把不一致的状态判为「未初始化」，
  // 强制走完整重建。
  // 🔴 2026-10-26：注意 mpv_gl 现在**允许**为 NULL（render context 推迟到
  //    共享上下文就绪后才建），故这里只把「mpv 为空」判为半途状态。
  //    旧逻辑 `mpv_gl == NULL` 会把「刚 init 完、还没建 render context」
  //    这个合法中间态误判成坏状态，导致反复重建。
  if (g_mpv.initialized && g_mpv.mpv == NULL) {
    hein_log("init 检测到半途状态（initialized=1 但 mpv=NULL），强制重建");
    g_mpv.initialized = false;
  }
  hein_log("init 进入（initialized=%d disposed=%d）", (int)g_mpv.initialized,
           (int)g_mpv.disposed);
  if (g_mpv.initialized) return true;

  // ① 🔴 LC_NUMERIC 必须为 "C"（mpv 的 mp_create 里 check_locale 硬性要求，
  //    否则返回 NULL 且不设 errno）。Windows 默认 C locale 就是 "C"，
  //    但显式设置一次以防有人改过。
  setlocale(LC_NUMERIC, "C");

  // ② D3D11 外部纹理（壳与 Flutter 引擎之间的桥）。
  //    ⚠️ 必须在 mpv_render_context_create **之前**建：mpv 的
  //    MPV_RENDER_PARAM_D3D11_INIT_PARAMS 要的 device 就从它这儿取。
  //    ⚠️ 必须在**主线程**建并注册：FlutterDesktopTextureRegistrar 的
  //    线程亲和性要求（register/mark 都从主线程调用）。
  HeinWinTexture *tex = hein_win_texture_create(registrar);
  if (tex == NULL) {
    hein_log("hein_win_texture_create 失败");
    return false;
  }
  g_mpv.win_texture = tex;
  if (out_texture != NULL) *out_texture = tex;

  // ③ mpv 实例 + 选项（与 Linux 完全一致的教训集）
  g_mpv.mpv = mpv_create();
  if (!g_mpv.mpv) {
    hein_log("mpv_create 失败");
    return false;
  }
  mpv_set_option_string(g_mpv.mpv, "vo", "libmpv");
  // 🔴 gpu-api/gpu-context 必须显式 d3d11（Linux 是 opengl/auto）。
  //    "auto" 在 Windows 上可能挑到不存在或不合意的上下文。
  mpv_set_option_string(g_mpv.mpv, "gpu-api", "d3d11");
  mpv_set_option_string(g_mpv.mpv, "gpu-context", "d3d11");
  mpv_set_option_string(g_mpv.mpv, "hwdec", "auto-safe");
  mpv_set_option_string(g_mpv.mpv, "video-sync", "audio");
  // 🔴 2026-10-21：配合 MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME=0 使用。
  //    mpv 官方文档明确建议：关闭 render 内部阻塞等待时，应把
  //    video-timing-offset 也设为 0，否则 mpv 仍会预留「提前量」导致
  //    A/V 有轻微偏差。设为 0 表示不做提前渲染，帧准备好就交。
  mpv_set_option_string(g_mpv.mpv, "video-timing-offset", "0");
  mpv_set_option_string(g_mpv.mpv, "video-sync-max-video-change", "1.0");
  mpv_set_option_string(g_mpv.mpv, "profile", "fast");
  mpv_set_option_string(g_mpv.mpv, "interpolation", "no");
  mpv_set_option_string(g_mpv.mpv, "framedrop", "yes");
  mpv_set_option_string(g_mpv.mpv, "tls-verify", "no");
  mpv_set_option_string(g_mpv.mpv, "demuxer-max-bytes", "1024MiB");
  mpv_set_option_string(g_mpv.mpv, "demuxer-max-back-bytes", "512MiB");
  mpv_set_option_string(g_mpv.mpv, "cache", "yes");
  mpv_set_option_string(g_mpv.mpv, "osc", "no");
  mpv_set_option_string(g_mpv.mpv, "idle", "yes");
  mpv_set_option_string(g_mpv.mpv, "keep-open", "yes");

  if (mpv_initialize(g_mpv.mpv) < 0) {
    hein_log("mpv_initialize 失败");
    return false;
  }

  // ④ 属性观察（同 Linux）
  mpv_observe_property(g_mpv.mpv, 0, "time-pos", MPV_FORMAT_DOUBLE);
  mpv_observe_property(g_mpv.mpv, 0, "duration", MPV_FORMAT_DOUBLE);
  mpv_observe_property(g_mpv.mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE);
  // 🔴🔴 2026-10-27：Linux 端缓冲条需要「已缓冲到的文件位置」。
  //    `demuxer-cache-time` 是**已缓冲总时长**（随播放堆积，可达数百秒），
  //    直接当位置用会让缓冲条撑出一大截（真机截图：46% 处画到 65%）。
  //    正确值在 `demuxer-cache-state` 节点里的 `cache-end`（文件内秒数）。
  //    仅新增观察，Windows 侧忽略该事件名 ⇒ Windows 行为不变。
  mpv_observe_property(g_mpv.mpv, 0, "demuxer-cache-state", MPV_FORMAT_NODE);
  mpv_observe_property(g_mpv.mpv, 0, "paused", MPV_FORMAT_FLAG);
  mpv_observe_property(g_mpv.mpv, 0, "eof-reached", MPV_FORMAT_FLAG);

  // ⑤ D3D11 render context（mpv 渲染到我们的纹理）
  //    ⚠️ C++ 不支持 C99 指定初始化，逐字段赋值；
  //    ⚠️ libmpv 会 AddRef 这个 device，之后我们释放自己的引用也安全。
  hein_mpv_d3d11_init_params dip;
  dip.device = (void *)hein_win_texture_device(tex);
  if (dip.device == NULL) {
    hein_log("hein_win_texture_device 返回 NULL");
    return false;
  }
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_API_TYPE, (void *)MPV_RENDER_API_TYPE_D3D11},
      {MPV_RENDER_PARAM_D3D11_INIT_PARAMS, (void *)&dip},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  int rc = mpv_render_context_create(&g_mpv.mpv_gl, g_mpv.mpv, params);
  if (rc < 0) {
    hein_log("mpv_render_context_create(d3d11) 失败 rc=%d (%s)", rc,
             mpv_error_string(rc));
    return false;
  }
  mpv_render_context_set_update_callback(g_mpv.mpv_gl, on_mpv_render, NULL);
  {
    const char *mlv = g_getenv("HEIN_MPV_LOG");
    mpv_request_log_messages(g_mpv.mpv, (mlv && *mlv) ? mlv : "no");
  }

  // ⑥ 事件线程 + 渲染线程（Windows 用 CreateThread，非 pthread）
  g_mpv.event_thread = CreateThread(NULL, 0, hein_event_thread_proc, NULL, 0,
                                    NULL);
  g_mpv.event_thread_started = (g_mpv.event_thread != NULL);
  if (!g_mpv.event_thread_started) {
    hein_log("CreateThread(事件) 失败 err=%lu",
             (unsigned long)GetLastError());
    return false;
  }
  hein_log("事件线程已启动（Windows, tid=%lu）",
           (unsigned long)GetThreadId(g_mpv.event_thread));

  g_mpv.render_wake_event = CreateEventA(NULL, FALSE, FALSE, NULL);
  if (g_mpv.render_wake_event == NULL) {
    hein_log("CreateEvent(render_wake) 失败 err=%lu",
             (unsigned long)GetLastError());
    return false;
  }
  g_mpv.render_thread_running = 1;
  g_mpv.render_thread = CreateThread(NULL, 0, hein_render_thread_proc, NULL, 0,
                                     NULL);
  if (g_mpv.render_thread == NULL) {
    hein_log("CreateThread(渲染) 失败 err=%lu", (unsigned long)GetLastError());
    g_mpv.render_thread_running = 0;
    return false;
  }
  hein_log("渲染线程已启动（Windows, tid=%lu）",
           (unsigned long)GetThreadId(g_mpv.render_thread));

  // ⑦ 记录 registrar（纹理已在上面建好并注册）
  g_mpv.win_texture_registrar = registrar;

  g_mpv.initialized = true;
  hein_log("Windows mpv 初始化完成（D3D11 render API，零 CPU 拷贝）");
  return true;
}

// 插件层把 D3D11 外部纹理句柄交给壳（init 里已自动做，这里保留接口
// 供将来「纹理延迟创建」场景使用）。
void hein_mpv_set_win_texture(void *tex) { g_mpv.win_texture = tex; }

// 帧 pump：由插件层在「Flutter 问纹理描述符」时顺带调用（主线程）。
// 真正的渲染在渲染线程里做；这里只是兜底，不阻塞主线程。
bool hein_mpv_pump_frame_windows(void) {
  // 只做唤醒：渲染线程自己会 pump。这样主线程绝不被 render 阻塞。
  if (g_mpv.render_wake_event != NULL) SetEvent(g_mpv.render_wake_event);
  return true;
}
#endif  // _WIN32

// ============================ open / 控制 ============================

// 教训③：startAt 用 mpv 的 start 选项在加载时即定位；同时记 pending_seek，
// 由 file-loaded 事件补一次立即 seek（教训④）双保险。
int hein_mpv_open(const char *url, double start_sec, bool is_live,
                  bool hardware_decoding, int cache_secs) {
  if (!g_mpv.mpv) return -1;

  // 🔴🔴🔴 2026-10-26：render context 尚未就绪时**不能** loadfile
  //   （vo_libmpv preinit 会 fatal "No render context set." 并让播放失败）。
  //   此刻只暂存参数，等共享上下文建好、render context 建好后由
  //   hein_ensure_render_context_locked() 补发。
  //   这条路径在真机上是常态：用户点播放早于首帧 populate。
  //
  //   🔴🔴🔴 2026-10-27 23:15 SW 模式修复（「能进不能播」真因）：
  //   原判定只看 `mpv_gl == NULL`，而 **SW 模式下 mpv_gl 永远是 NULL**
  //   （真正句柄是 mpv_sw）。于是 SW 模式哪怕 render context 已经建好，
  //   这里也会误判成「尚未就绪」→ 暂存 URL 后直接 return 0 →
  //   而补发只发生在「创建 render context 那一刻」，时机早已过去 →
  //   **URL 永远留在 deferred_url，文件从未 loadfile**。
  //   真机日志实证：只有 "已暂存"，之后既无 "补发延迟的 loadfile"，
  //   也无 "事件: START_FILE" / "事件: FILE_LOADED"。
  //   ⇒ 就绪判定必须同时认 SW 句柄。
#ifdef _WIN32
  // Windows 走 D3D11 路线：唯一 render context 是 mpv_gl；
  // 纹理就绪由渲染线程 hein_win_texture_notify_frame 驱动（无 SW/GL 之分）。
  if (g_mpv.mpv_gl == NULL) {
#else
  if (g_mpv.mpv_gl == NULL && g_mpv.mpv_sw == NULL) {
#endif
    g_free(g_mpv.deferred_url);
    g_mpv.deferred_url = g_strdup(url);
    g_mpv.deferred_start_sec = start_sec;
    g_mpv.deferred_is_live = is_live;
    g_mpv.deferred_hwdec = hardware_decoding;
    g_mpv.deferred_cache_secs = cache_secs;
    hein_log("open 早于 render context：已暂存 %s（共享上下文就绪后补发）", url);
    // 仍先把渲染驱动复位，避免上次失败态残留。
    HEIN_SUSPEND_SET(0);
    // 🔴🔴🔴 2026-10-26 23:05 起播加速兜底：主动催 Flutter 采样。
    //   见 init 里同名逻辑的注释 —— populate 只在 Flutter 重绘时才来，
    //   而此刻画面是静止的（还没 loadfile），不催就要干等到某次无关重绘。
    //   这里再催一次（幂等，多催无害），把首次 populate 的等待压到最短。
#ifdef _WIN32
    // Windows：D3D11 外部纹理，由渲染线程在出帧后通知引擎，无需在此催采样。
#else
    if (g_mpv.registered_texture_id > 0 && g_mpv.texture_registrar != NULL) {
      // SW 模式下 gl_texture 为 NULL，必须用 sw_texture 催，否则空指针崩溃。
      if (g_mpv.sw_mode) {
        if (g_mpv.sw_texture != NULL) {
          hein_sw_texture_mark_available(g_mpv.sw_texture,
                                         g_mpv.texture_registrar);
          hein_log("已催促 Flutter 采样（SW 纹理，避免起播干等）");
        }
      } else {
        fl_texture_registrar_mark_texture_frame_available(
            g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
        hein_log("已催促 Flutter 采样（加速首次 populate，避免起播干等）");
      }
    }
#endif  // _WIN32
    return 0;
  }

  return hein_mpv_open_internal(url, start_sec, is_live, hardware_decoding,
                                cache_secs);
}

int hein_mpv_open_internal(const char *url, double start_sec, bool is_live,
                           bool hardware_decoding, int cache_secs) {
  if (!g_mpv.mpv) return -1;

  // 换源前清掉旧的定位态
  g_mpv.pending_seek_pending = false;
  g_mpv.first_frame_emitted = false;
  // 新一次 open 恢复渲染驱动（上次失败可能把它挂起了）。
  HEIN_SUSPEND_SET(0);
  g_mpv.has_new_frame = false;

  // 🔴 hwdec-software-fallback 是 **init-only** 选项，运行期设置返回 -7
  //    （在 init 时已按「允许回退」设好），此处不要再设。
  //
  // 🔴🔴 2026-10-26 真机修正：hwdec 在 mpv_initialize() 之后**必须**用
  //   mpv_set_property_string（运行期属性），不能再用 mpv_set_option_string。
  //   证据：69 真机 HEIN_MPV_SELFTEST_HWDEC=1 时日志仍打出
  //     `open url=... hwdec=0` 与 `Using software decoding.`
  //   —— 说明 set_option 在 initialize 后静默无效（option 只在 pre-init
  //   生效），硬解开关实际上是**恒为 init 时的 auto-safe**，Dart 侧
  //   用户关掉硬解也不生效。
  //   init 阶段（L1594）已设过 auto-safe 作为默认；这里按调用方意图覆盖。
  {
    const char *want = hardware_decoding ? "auto-safe" : "no";
    int hrc = mpv_set_property_string(g_mpv.mpv, "hwdec", want);
    if (hrc < 0) {
      hein_log("设置 hwdec=%s 失败 rc=%d (%s)", want, hrc,
               mpv_error_string(hrc));
    } else {
      hein_log("hwdec 运行期已设为 %s", want);
    }
  }
  // 🔴 不能传 NULL 给 mpv_set_option_string（未定义行为，可能损坏内部状态）。
  //    直接写目标值即可，无需先「清空」。
  char cache_buf[16];
  snprintf(cache_buf, sizeof(cache_buf), "%d", cache_secs);
  mpv_set_option_string(g_mpv.mpv, "cache-secs", cache_buf);

  if (start_sec > 0) {
    char start_buf[32];
    snprintf(start_buf, sizeof(start_buf), "%.3f", start_sec);
    mpv_set_option_string(g_mpv.mpv, "start", start_buf);
    g_mpv.pending_seek_sec = start_sec;
    g_mpv.pending_seek_pending = true;
    g_mpv.last_requested_sec = start_sec;
  } else {
    mpv_set_option_string(g_mpv.mpv, "start", "0");
  }

  mpv_set_option_string(g_mpv.mpv, "pause", is_live ? "no" : "no");

  // 🔴🔴 2026-10-21 直播无法播放根因之一：is_live 参数此前**只用于日志**，
  //    直播该有的选项一个都没设。
  //
  //    直播流（HTTP 裸 TS、不断追加）与点播的最大区别是**没有终点**：
  //    - cache-secs=30 会让 mpv 先攒满 30 秒才起播。直播源是持续推流、
  //      永远不会「读满」，于是 mpv 长期处于 buffering 态 → 一直黑屏，
  //      直到缓存策略偶然放行才闪一下画面（正是用户说的「间歇有画面」）。
  //    - keep-open=yes 对直播无意义且会让 EOF 后卡住。
  //    - demuxer-max-bytes=1024MiB 对直播过大，内存压力也会拖慢起播。
  //
  //    修法（与 Android MpvPlayerView 的直播分支对齐）：
  //      cache=yes 但 cache-secs 取小值（2s），并显式 demuxer-readahead-secs；
  //      关掉 keep-open；降低 demuxer 缓存上限。
  if (is_live) {
    mpv_set_option_string(g_mpv.mpv, "cache-secs", "2");
    mpv_set_option_string(g_mpv.mpv, "demuxer-readahead-secs", "2");
    mpv_set_option_string(g_mpv.mpv, "demuxer-max-bytes", "64MiB");
    mpv_set_option_string(g_mpv.mpv, "demuxer-max-back-bytes", "16MiB");
    mpv_set_option_string(g_mpv.mpv, "keep-open", "no");
    // 直播无需精确 seek，关掉能减少起播等待
    mpv_set_option_string(g_mpv.mpv, "hr-seek", "no");
    hein_log("直播模式：已设置低延迟缓存策略（cache-secs=2, keep-open=no）");
  } else {
    mpv_set_option_string(g_mpv.mpv, "keep-open", "yes");
    // 🔴 2026-10-27：把**实际生效**的缓冲参数读回来打日志。
    //   背景：上面 `mpv_set_option_string(mpv, "cache-secs", ...)` 是在
    //   mpv_initialize() **之后**执行的 —— 与 hwdec 同类问题（option 只在
    //   pre-init 生效，set_option 在 initialize 后静默失效）。若 cache-secs
    //   根本没生效，则 mpv 用的是默认档，「攒 30 秒才起播」不成立，
    //   起播慢的原因就只剩死锁与分片下载。此日志用于一锤定音，
    //   避免再凭猜测改参数。
    {
      // ⚠️ option 只能用 `options/<name>` 读回，且要按**正确类型**取：
      //   上一版用 MPV_FORMAT_STRING 读 option → 拿到的是垃圾字节（真机日志乱码）。
      //   正确：cache-secs 是 double，cache-pause-initial 是 flag。
      double cs = -1.0;
      int cpi = -1;
      if (mpv_get_property(g_mpv.mpv, "options/cache-secs", MPV_FORMAT_DOUBLE, &cs) < 0) {
        cs = -1.0;
      }
      if (mpv_get_property(g_mpv.mpv, "options/cache-pause-initial", MPV_FORMAT_FLAG,
                           &cpi) < 0) {
        cpi = -1;
      }
      hein_log("点播缓存实况：cache-secs=%.1f cache-pause-initial=%s（请求 %ds）",
               cs, cpi > 0 ? "yes" : (cpi == 0 ? "no" : "?"), cache_secs);
    }
  }

  const char *cmd[] = {"loadfile", url, "replace", NULL};
  int rc = mpv_command(g_mpv.mpv, cmd);
  // 🔴🔴 2026-10-23：loadfile **不会**复位 mpv 的持久 pause 属性。
  //   mpv 的 pause 是全局属性，一旦被 set pause yes 置位，后续任何 loadfile
  //   都会以「暂停态」载入 —— 表现为换源后画面停在首帧不动（看着像黑屏/卡死）。
  //   open 的语义就是「播放这个 URL」，这里显式解除暂停。
  //   （Dart 侧桌面复用路径已同步去掉 pause()，这里是 native 层的兜底。）
  {
    const char *unpause[] = {"set", "pause", "no", NULL};
    mpv_command(g_mpv.mpv, unpause);
  }
  hein_log("open url=%s start=%.3f live=%d hwdec=%d cache=%ds rc=%d", url,
           start_sec, is_live, hardware_decoding, cache_secs, rc);
  return rc;
}

int hein_mpv_play(void) {
  if (!g_mpv.mpv) return -1;
  const char *cmd[] = {"set", "pause", "no", NULL};
  return mpv_command(g_mpv.mpv, cmd);
}

int hein_mpv_pause(void) {
  if (!g_mpv.mpv) return -1;
  const char *cmd[] = {"set", "pause", "yes", NULL};
  return mpv_command(g_mpv.mpv, cmd);
}

int hein_mpv_seek(double sec) {
  if (!g_mpv.mpv) return -1;
  g_mpv.last_requested_sec = sec;
  char buf[32];
  snprintf(buf, sizeof(buf), "%.3f", sec);
  const char *cmd[] = {"seek", buf, "absolute+exact", NULL};
  return mpv_command(g_mpv.mpv, cmd);
}

int hein_mpv_set_speed(double speed) {
  if (!g_mpv.mpv) return -1;
  char buf[32];
  snprintf(buf, sizeof(buf), "%.3f", speed);
  const char *cmd[] = {"set", "speed", buf, NULL};
  return mpv_command(g_mpv.mpv, cmd);
}

int hein_mpv_set_volume(double volume) {
  if (!g_mpv.mpv) return -1;
  char buf[32];
  snprintf(buf, sizeof(buf), "%.3f", volume);
  const char *cmd[] = {"set", "volume", buf, NULL};
  return mpv_command(g_mpv.mpv, cmd);
}

// 画面比例控制（2026-10-21 移植自 Android MpvPlayerView 的 setFit 分支）。
//
// 🔴 这是「安卓版踩过的老坑」在桌面壳上的完整复刻：
//    主工程移植时**整条缩放控制链路丢失** —— 壳没有 setFit 分支、
//    Dart 的 MpvDesktopBackend.fit 是空实现（只存字段不下发）、
//    mpv 侧从未设置 keepaspect/panscan。
//    结果 mpv 用默认行为把视频**拉伸铺满**整个 FBO（FBO 尺寸 = 视频
//    video-out-params，但 mpv 的 vo 默认会按窗口/目标尺寸做缩放），
//    而 Flutter 又把这块纹理拉伸铺满全屏 → 比例失真（16:9 片源在
//    1080x1920 竖屏掌机上被压扁/拉宽）。
//
//    正确做法（与 Android 逐行对齐）：比例交由 mpv 依据自身 video-params
//    计算，前端三态映射为 keepaspect/panscan 组合：
//      contain（原始比例，默认）：keepaspect=yes + panscan=0   → 留黑边不裁剪
//      cover  （填充，裁边）    ：keepaspect=yes + panscan=1.0 → 保持比例填满
//      fill   （拉伸，变形）    ：keepaspect=no  + panscan=0   → 直接铺满
int hein_mpv_set_fit(const char *fit) {
  if (!g_mpv.mpv) return -1;
  const char *keepaspect = "yes";
  const char *panscan = "0";
  if (fit != NULL && g_strcmp0(fit, "cover") == 0) {
    keepaspect = "yes";
    panscan = "1.0";
  } else if (fit != NULL && g_strcmp0(fit, "fill") == 0) {
    keepaspect = "no";
    panscan = "0";
  }
  int rc1 = mpv_set_property_string(g_mpv.mpv, "keepaspect", keepaspect);
  int rc2 = mpv_set_property_string(g_mpv.mpv, "panscan", panscan);
  hein_log("setFit fit=%s keepaspect=%s panscan=%s rc=%d/%d",
           fit ? fit : "(null)", keepaspect, panscan, rc1, rc2);
  return (rc1 < 0) ? rc1 : rc2;
}

// 视频层控件尺寸（Dart 上报）。壳据此建 FBO，让 mpv 在该尺寸内自行
// letterbox —— 这是画面比例正确的**唯一**路径（详见 HeinMpv.view_w 注释）。
void hein_mpv_set_view_size(int w, int h) {
  if (w <= 0 || h <= 0) return;
  if (g_mpv.view_w == w && g_mpv.view_h == h) return;
  g_mpv.view_w = w;
  g_mpv.view_h = h;
  hein_log("视频层尺寸更新 %dx%d（FBO 将按此重建，mpv 负责 letterbox）", w, h);
  // 尺寸变了要立刻重出一帧，否则要等下一次 mpv 有新帧才生效（表现为
  // 「改窗口大小后画面比例不对，过一会儿才对」）。
  g_mpv.has_new_frame = true;
  hein_mpv_request_frame();
}

double hein_mpv_get_double(const char *name, double defval) {
  if (!g_mpv.mpv) return defval;
  double v = defval;
  mpv_get_property(g_mpv.mpv, name, MPV_FORMAT_DOUBLE, &v);
  return v;
}

const char *hein_mpv_get_string(const char *name) {
  if (!g_mpv.mpv) return NULL;
  char *v = mpv_get_property_string(g_mpv.mpv, name);
  return v;  // 调用方负责 mpv_free
}

void hein_mpv_free(void *p) { mpv_free(p); }

// 尺寸变化时重建 FBO（教训⑤），返回当前纹理是否可用。
bool hein_mpv_ensure_texture_size(int w, int h) {
#ifndef _WIN32
  if (g_mpv.gl_texture == NULL) return false;
  GLuint fbo = hein_gl_texture_ensure_fbo(g_mpv.gl_texture, w, h);
  return fbo != 0;
#else
  (void)w;
  (void)h;
  return true;
#endif
}

bool hein_mpv_first_frame_emitted(void) {
  return g_mpv.first_frame_emitted;
}

// ============================ 帧渲染（由 Flutter 帧循环调用） ============================
//
// 必须在调用方持有 GL 上下文 current 时执行（Linux 由 runner 的帧回调保证）。
// 返回是否向 Flutter 提交了新帧。
// 把「渲染一帧」的请求投递到 GTK 主线程。
//
// mpv 的 update 回调运行在**它自己的渲染线程**，而 OpenGL 上下文归 GTK 主线程，
// 直接在回调里画会崩（上下文不 current）。故用 g_idle_add 投递到主线程。
// 若同一帧已排队则跳过（合并请求，避免队列爆炸）。
#ifndef _WIN32
// 自检用：不依赖 Flutter 帧回调，定时驱动渲染。
static gboolean hein_selftest_tick(gpointer data) {
  (void)data;
  hein_mpv_render_to_fbo();
  return G_SOURCE_CONTINUE;
}

// 🔴🔴🔴 2026-10-26：**像素级出画自检**（游戏模式排障）。
//
// 【为什么需要】日志能证明「mpv 在渲染」「populate 被调用」，
//   但这些都**不能证明用户真的看到了画面**：
//   · mpv 渲染进 FBO ≠ 纹理名在 Flutter 侧有效；
//   · populate 被调用 ≠ 采样到的像素非黑。
//   真正能一锤定音的是：**从当前共享上下文把 FBO 读回来，看是否非黑**。
//
// 【怎么读】在**共享上下文**（阶段②的 B，与 Flutter 同一命名空间）里
//   glReadPixels 读 FBO 的 9 个采样点：
//   · 全部为 0 ⇒ 纹理在 Flutter 侧无效/全黑（共享没成立）；
//   · 有非零像素 ⇒ 画面链路真的通了。
//
// 【成本】每 2 秒读 9 个点（不是整帧），开销可忽略。
static gint64 s_pixel_check_last_us = 0;
static void hein_pixel_check_once(void) {
  // 🔴 2026-10-26：**默认关闭**，只在排障时开启。
  //   理由：整帧抽样读回每 2 秒一次（约 1.6MB/次），
  //   在正常播放时属于无谓开销。开启方式：HEIN_MPV_PIXEL_CHECK=1。
  //   （本次游戏模式出画验证就是靠它拿到「平均亮度 13.49 ⇒ 有像素」的硬证据。）
  if (g_getenv("HEIN_MPV_PIXEL_CHECK") == NULL) return;
  gint64 now_us = g_get_monotonic_time();
  if (s_pixel_check_last_us != 0 &&
      now_us - s_pixel_check_last_us < 2000000) {
    return;
  }
  s_pixel_check_last_us = now_us;

  if (g_mpv.gl_texture == NULL) return;
  int w = hein_gl_texture_get_width(g_mpv.gl_texture);
  int h = hein_gl_texture_get_height(g_mpv.gl_texture);
  if (w <= 2 || h <= 2) return;

  // 🔴 2026-10-26：像素自检改为**整帧抽样统计**（每 4 个像素取 1 个），
  //   而不是 9 个点。
  //   原因：9 个点会因视频明暗（暗场景/黑场/letterbox）而抖动，
  //   无法区分「真全黑」与「恰好采样到暗部」。
  //   整帧抽样能稳定反映「这一帧整体是不是黑的」。
  //   代价：一次读整帧（854x480x4 ≈ 1.6MB）每 2 秒一次，可接受。
  GLuint fbo = hein_gl_texture_ensure_fbo(g_mpv.gl_texture, w, h);
  if (fbo == 0) return;
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  // 分块读，避免一次分配过大：每次读 64 行。
  const int step = 4;  // 每 4 像素取 1 个
  long long sum = 0;
  long long count = 0;
  unsigned char *row = (unsigned char *)g_malloc((size_t)w * 4);
  if (row == NULL) {
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return;
  }
  for (int y = 0; y < h; y += step) {
    glReadPixels(0, y, w, 1, GL_RGBA, GL_UNSIGNED_BYTE, row);
    for (int x = 0; x < w; x += step) {
      const unsigned char *p = row + (size_t)x * 4;
      sum += (long long)p[0] + p[1] + p[2];
      count++;
    }
  }
  g_free(row);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  const double avg = count > 0 ? (double)sum / (double)(count * 3) : 0.0;
  // 判据：平均亮度 > 2 视为「有画面」（纯黑时恒为 0）。
  hein_log("像素自检：FBO %dx%d，抽样 %lld 点，平均亮度 %.2f ⇒ %s", w, h, count,
           avg, avg > 2.0 ? "画面有效（有像素）" : "全黑（共享未成立）");
}

static gboolean hein_render_idle(gpointer data) {
  (void)data;
  g_mpv.render_pending = false;
  hein_mpv_render_to_fbo();
  return G_SOURCE_REMOVE;
}

// 🔴🔴 2026-10-21 点播/直播「间歇出画、声音正常」根因（69 真机复现）。
//
//    原实现用 g_idle_add(hein_render_idle) 投递渲染。g_idle_add 的优先级是
//    G_PRIORITY_DEFAULT_IDLE = 200，**低于所有常规主循环源**（默认 0）。
//    Flutter 的 UI 绘制、动画、setState 重建全都在主线程以默认优先级跑，
//    主线程只要一直有活干，idle 源就**永远轮不到执行** → 该帧的
//    mpv_render_context_render 被跳过 → 画面间歇性不出（音频由 mpv
//    自己的音频线程输出，完全不受影响，故「有声无画、隔一阵闪一下」）。
//
//    这也解释了为什么自检模式一直是好的：hein_selftest_tick 用
//    g_timeout_add(16, ...)，定时器源优先级是 G_PRIORITY_DEFAULT(0)，
//    不会被饿死 —— 自检路径与真实 UI 路径的驱动机制**根本不同**，
//    所以「自检通过」从未能证明真实播放页会出画（教训①的又一次重演）。
//
//    修法：改为**固定节奏定时器**（16ms ≈ 60fps），与自检一致。
//    - 用 G_PRIORITY_HIGH_IDLE(100) 保证排在 UI 绘制之前、不被饿死；
//    - 用固定间隔而非一次性 idle，天然与 mpv 的帧节奏对齐，不再依赖
//      「mpv 每次 update 回调恰好被主线程及时消费」这个脆弱假设；
//    - 定时器常驻（首次请求时创建），无新帧时 render_to_fbo 会立即返回，
//      开销可忽略。
//    - render_pending 仅用于「定时器未建立时的首帧兜底」。
static guint g_render_timer_id = 0;

static gboolean hein_render_tick(gpointer data) {
  (void)data;
  hein_mpv_render_to_fbo();
  return G_SOURCE_CONTINUE;
}
// 🔴 Windows 侧无 GLib 主循环：帧驱动改为「独立渲染线程 + Win32
//    事件唤醒」（见 hein_render_thread_proc）。上面这组 GTK 专用件
//    在 Windows 上整体不编译，故用 #ifndef _WIN32 整段包住。
#endif


void hein_mpv_request_frame(void) {
#ifndef _WIN32
  // 常驻渲染定时器：首次请求时创建，之后一直以 16ms 节奏驱动。
  if (g_render_timer_id == 0) {
    // 🔴🔴 2026-10-21 修正优先级方向搞反的错误：
    //    GLib 里**数值越小优先级越高**：
    //      G_PRIORITY_HIGH      = -100
    //      G_PRIORITY_DEFAULT   =    0   ← Flutter 的 UI 绘制/动画在这档
    //      G_PRIORITY_HIGH_IDLE =  100   ← 原实现用的这档，**低于** UI！
    //      G_PRIORITY_DEFAULT_IDLE = 200
    //    原注释写「G_PRIORITY_HIGH_IDLE 保证排在 UI 绘制之前」是错的，
    //    实际是排在 UI 之后 → 主线程只要有 UI 活，渲染就被饿着。
    //    改用 G_PRIORITY_DEFAULT(0) 与 UI 公平竞争（不用 HIGH 以免饿死 UI）。
    g_render_timer_id =
        g_timeout_add_full(G_PRIORITY_DEFAULT, 16, hein_render_tick, NULL,
                           NULL);
    hein_log("渲染定时器已启动 id=%u（16ms，G_PRIORITY_DEFAULT 与 UI 公平竞争）",
             g_render_timer_id);
  }
  // 兜底：定时器建立瞬间可能错过一帧，用一次性 idle 补一次。
  if (!g_mpv.render_pending) {
    g_mpv.render_pending = true;
    g_idle_add(hein_render_idle, NULL);
  }
#else
  // Windows：没有 GLib 主循环，也没有「主线程渲染」。
  // 渲染固定在**独立渲染线程**里做（见 hein_render_thread_proc），
  // 这里只负责唤醒它 —— 绝不能在主线程直接 render，否则
  // video-sync=audio 下 render 内部阻塞 sleep 会饿死 Flutter。
  if (g_mpv.render_wake_event != NULL) SetEvent(g_mpv.render_wake_event);
#endif
}

#ifndef _WIN32
// 🔴🔴🔴 2026-10-27 23:05：**SW 软件渲染**（X11 / gamescope 游戏模式专用）。
//
// 【为什么存在】
//   本机 gamescope 3.16.31 启动参数里没有 `--expose-wayland`
//   （其帮助文本："support wayland clients using xdg-shell"），
//   焦点/合成走 XWM，只认 X11 客户端。真机实测 stats.pipe 恒为
//   `focus=steam` —— 我们的 Wayland 窗口建成了、首帧也画了，
//   但永远不被合成上屏（用户报「软件根本没有显示画面」）。
//   ⇒ GTK 必须留在 X11。
//   而 GTK3 的 X11 后端只有 GLX（nm -D 无任何 x11-egl 符号），
//   与引擎的 EGL 在同一 X display 上互斥（真机 eglMakeCurrent 后
//   glXMakeCurrent 报 BadAccess ⇒ gdk_cairo_draw_from_gl SIGSEGV）
//   ⇒ 共享 GL 上下文这条路在 X11 下**必然崩溃**。
//
// 【做法】mpv 用 MPV_RENDER_API_TYPE_SW 渲染到 CPU 内存（RGBA），
//   再交给 FlPixelBufferTexture 由 Flutter 上传。零 GL 上下文，
//   与 GTK 的 GLX 完全不接触。
// 🔴🔴🔴 2026-10-27 独立 SW 渲染线程。
//
//   【为什么必须独立线程】真机实测约 18fps 且越播越慢。基准测试
//   （ffmpeg 模拟 mpv SW 全路径：解码 + 缩放 1454x818 + 转 rgb0）
//   跑出 13.6x 实时（≈816fps），单帧上传仅 4.54MiB、60fps 需
//   0.27GiB/s ⇒ **算力与带宽都远未饱和**。
//   真正的瓶颈是 mpv_render_context_render() 的**阻塞语义**：
//   render.h 明确它默认会阻塞到该帧应显示的时刻（BLOCK_FOR_TARGET_TIME
//   的默认行为，由 video-timing-offset 决定）。把这种阻塞放在 GTK
//   主线程上，等于每帧都让主线程睡一会儿 → UI 掉帧、16ms 定时器追不上
//   → 请求积压 → 表现为「帧率低且越来越低」。
//
//   SW 渲染是纯 CPU 且**不碰任何 GL 上下文**，因此放独立线程完全安全
//   （这正是它相对 GL 路径的优势：没有上下文归属问题）。
//   与 Windows 侧 hein_render_thread_proc 同构。
static gpointer hein_sw_render_thread(gpointer arg) {
  (void)arg;
  hein_log("SW 渲染线程已启动（脱离 GTK 主线程，避免 render 阻塞冻结 UI）");
  g_mutex_lock(&g_mpv.sw_mutex);
  while (!g_mpv.sw_thread_quit) {
    if (!g_mpv.sw_thread_wake) {
      // 最多等 20ms：既避免空转，又保证有帧时能及时醒（约 50Hz 轮询上限）。
      gint64 deadline = g_get_monotonic_time() + 20 * G_TIME_SPAN_MILLISECOND;
      while (!g_mpv.sw_thread_wake && !g_mpv.sw_thread_quit) {
        if (!g_cond_wait_until(&g_mpv.sw_cond, &g_mpv.sw_mutex, deadline)) break;
      }
    }
    g_mpv.sw_thread_wake = false;
    g_mutex_unlock(&g_mpv.sw_mutex);
    // 渲染在锁外进行：hein_mpv_render_sw 内部通过 hein_sw_texture 的
    // 自有互斥与双缓冲保证与 Flutter raster 线程的安全。
    hein_mpv_render_sw();
    g_mutex_lock(&g_mpv.sw_mutex);
  }
  g_mutex_unlock(&g_mpv.sw_mutex);
  hein_log("SW 渲染线程已退出");
  return NULL;
}

static void hein_sw_render_thread_start(void) {
  if (g_mpv.sw_thread_started) return;
  g_mutex_init(&g_mpv.sw_mutex);
  g_cond_init(&g_mpv.sw_cond);
  g_mpv.sw_thread_quit = false;
  g_mpv.sw_thread_wake = false;
  g_mpv.sw_thread = g_thread_new("hein-sw-render", hein_sw_render_thread, NULL);
  g_mpv.sw_thread_started = true;
}

static void hein_sw_render_thread_stop(void) {
  if (!g_mpv.sw_thread_started) return;
  g_mutex_lock(&g_mpv.sw_mutex);
  g_mpv.sw_thread_quit = true;
  g_cond_signal(&g_mpv.sw_cond);
  g_mutex_unlock(&g_mpv.sw_mutex);
  if (g_mpv.sw_thread != NULL) {
    g_thread_join(g_mpv.sw_thread);
    g_mpv.sw_thread = NULL;
  }
  g_mutex_clear(&g_mpv.sw_mutex);
  g_cond_clear(&g_mpv.sw_cond);
  g_mpv.sw_thread_started = false;
}

static void hein_sw_render_thread_wake(void) {
  if (!g_mpv.sw_thread_started) return;
  g_mutex_lock(&g_mpv.sw_mutex);
  g_mpv.sw_thread_wake = true;
  g_cond_signal(&g_mpv.sw_cond);
  g_mutex_unlock(&g_mpv.sw_mutex);
}

static bool hein_mpv_render_sw(void) {
  if (g_mpv.mpv_sw == NULL || g_mpv.sw_texture == NULL) return false;
  if (HEIN_SUSPEND_GET()) return false;
  if (!g_mpv.has_new_frame) return false;

  // 尺寸：优先 Dart 上报的控件尺寸（可 letterbox），否则视频自身尺寸。
  int w = 0, h = 0;
  if (g_mpv.view_w > 4 && g_mpv.view_h > 4) {
    w = g_mpv.view_w;
    h = g_mpv.view_h;
  }
  if (w <= 0 || h <= 0) {
    double ow = hein_mpv_get_double("video-out-params/w", 0);
    double oh = hein_mpv_get_double("video-out-params/h", 0);
    if (ow > 0 && oh > 0) {
      w = (int)ow;
      h = (int)oh;
    }
  }
  if (w <= 4 || h <= 4) {
    g_mpv.has_new_frame = true;  // 保留请求，等尺寸就绪
    return false;
  }

  // 软件渲染很吃 CPU：把尺寸限制在合理范围（不超过视频源，也不超过 1080p）。
  // 1080p 在 Radeon 880M 上 SW 渲染约 8~15ms/帧，可接受；
  // 再高会明显掉帧，而画质收益有限（视频源本身通常 ≤1080p）。
  {
    double src_w = hein_mpv_get_double("video-params/w", 0);
    double src_h = hein_mpv_get_double("video-params/h", 0);
    if (src_w > 0 && src_h > 0 && w > 4 && h > 4) {
      double sx = src_w / (double)w;
      double sy = src_h / (double)h;
      double sc = sx < sy ? sx : sy;
      if (sc < 1.0) {
        int nw = (int)(w * sc + 0.5);
        int nh = (int)(h * sc + 0.5);
        if (nw >= 320 && nh >= 180) {
          w = nw;
          h = nh;
        }
      }
    }
  }

  // 🔴 mpv render.h 要求 SW_STRIDE 与 SW_POINTER 都是 **64 的倍数**
  //   （否则触发慢速路径，甚至整帧拷贝；未对齐在部分平台还会崩）。
  //   ⇒ stride 向上对齐到 64，缓冲按对齐后的 stride 分配。
  const size_t stride_raw = (size_t)w * 4;
  const size_t stride = (stride_raw + 63u) & ~(size_t)63u;
  const size_t need = stride * (size_t)h + 64;  // +64 供指针对齐余量
  if (g_mpv.sw_buf == NULL || g_mpv.sw_buf_size < need) {
    g_free(g_mpv.sw_buf);
    // GLib 2.72+ 的 g_aligned_alloc(n_blocks, n_block_bytes, alignment)。
    // 64 字节对齐是 mpv SW_POINTER 的硬要求。
    g_mpv.sw_buf = g_aligned_alloc(1, need, 64);
    g_mpv.sw_buf_size = need;
    hein_log("SW 渲染缓冲已分配 %dx%d stride=%zu (%zu 字节, 64 对齐)", w, h,
             stride, need);
  }
  if (w != g_mpv.sw_w || h != g_mpv.sw_h) {
    static int s_sz = 0;
    if (s_sz++ < 5) hein_log("SW 渲染尺寸 %dx%d", w, h);
    g_mpv.sw_w = w;
    g_mpv.sw_h = h;
  }

  // mpv render.h 明确要求：
  //   · SW_SIZE  类型 int[2]（param.data = &s[0]）
  //   · SW_FORMAT 类型 char*，有效值只有 "rgb0"/"bgr0"/"0bgr"/"0rgb"（4字节 RGB，
  //     第 4 字节为未初始化垃圾）或 "rgb24"。**没有 "rgba"** —— 传 "rgba"
  //     会被当成 "other" 走 mpv 内部格式名解析，大概率失败。
  //   · SW_STRIDE 类型 **size_t\***（不是 int*）—— 传 int* 会读到高位垃圾。
  //   · SW_POINTER 类型 void*。
  //   选 "rgb0"：4 字节/像素，第 4 字节是 alpha 位（内容未定义）。
  //   FlPixelBufferTexture 要求 RGBA，但 Flutter 的 copy_pixels 只按
  //   RGBA 顺序解读前 3 字节 + alpha。mpv 不保证第 4 字节为 255，
  //   若为 0 会导致视频区域全透明（黑屏/看不见）。因此渲染后统一把
  //   每像素第 4 字节填 255（见下方 fill alpha）。
  int size_param[2] = {w, h};
  size_t stride_param = stride;
  char format_param[] = "rgb0";
  void *ptr_param = g_mpv.sw_buf;

  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_SW_SIZE, size_param},
      {MPV_RENDER_PARAM_SW_FORMAT, format_param},
      {MPV_RENDER_PARAM_SW_STRIDE, &stride_param},
      {MPV_RENDER_PARAM_SW_POINTER, ptr_param},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  const gint64 t0 = g_get_monotonic_time();
  g_mpv.has_new_frame = false;
  int rc = mpv_render_context_render((mpv_render_context *)g_mpv.mpv_sw, params);
  const gint64 t1 = g_get_monotonic_time();
  if (rc < 0) {
    static int s_fail = 0;
    if (++s_fail <= 10) {
      hein_log("SW render 失败 rc=%d (%s)，第 %d 次", rc,
               mpv_error_string(rc), s_fail);
    }
    g_mpv.has_new_frame = true;
    return false;
  }
  mpv_render_context_report_swap((mpv_render_context *)g_mpv.mpv_sw);
  const gint64 t2 = g_get_monotonic_time();

  // "rgb0" 的第 4 字节是未定义垃圾 ⇒ 统一填 255，避免 Flutter 侧
  // 把它当 alpha 解读成透明（那会表现为「视频区域看不见」）。
  // ⚠️ 必须按 stride 逐行填充：行间可能有对齐填充字节，不能按 w*h 线性算。
  // 2026-10-27：改为 32 位字 OR 写（每次 4 字节对齐读改写），
  //   比逐字节 row[x*4+3]=255 的跨步访问缓存更友好。
  {
    for (int y = 0; y < h; ++y) {
      uint32_t *row = (uint32_t *)(g_mpv.sw_buf + (size_t)y * stride);
      for (int x = 0; x < w; ++x) row[x] |= 0xFF000000u;
    }
  }
  const gint64 t3 = g_get_monotonic_time();

  if (!hein_sw_texture_set_frame(g_mpv.sw_texture, g_mpv.sw_buf, (uint32_t)w,
                                 (uint32_t)h, stride)) {
    return false;
  }
  const gint64 t4 = g_get_monotonic_time();
  if (g_mpv.texture_registrar != NULL) {
    hein_sw_texture_mark_available(g_mpv.sw_texture, g_mpv.texture_registrar);
  }
  // 帧计数 + 分阶段耗时诊断（Linux 侧结构体无 render_frame_count 字段）。
  // 2026-10-27：真机实测仅约 18fps，需先量化瓶颈再改，
  //   故分别累计 mpv 渲染 / alpha 填充 / 纹理拷贝三段耗时。
  {
    static gint s_sw_frames = 0;
    static gint64 s_render_us = 0, s_alpha_us = 0, s_copy_us = 0;
    static gint64 s_t_prev = 0;
    s_render_us += (t1 - t0);
    s_alpha_us += (t3 - t2);
    s_copy_us += (t4 - t3);
    gint n = g_atomic_int_add(&s_sw_frames, 1) + 1;
    if (n == 1 || n == 2 || n == 5) {
      hein_log("SW 已出帧 %d（%dx%d）", n, w, h);
    }
    if (n % 60 == 0) {
      const gint64 now = g_get_monotonic_time();
      double fps = (s_t_prev > 0) ? 60.0 / ((now - s_t_prev) / 1000000.0) : 0.0;
      s_t_prev = now;
      hein_log(
          "SW 性能：近60帧 fps=%.1f render=%.2fms alpha=%.2fms copy=%.2fms "
          "（%dx%d）",
          fps, s_render_us / 60000.0, s_alpha_us / 60000.0,
          s_copy_us / 60000.0, w, h);
      s_render_us = s_alpha_us = s_copy_us = 0;
      char *hd = mpv_get_property_string(g_mpv.mpv, "hwdec-current");
      char *vf = mpv_get_property_string(g_mpv.mpv, "video-format");
      char *vc = mpv_get_property_string(g_mpv.mpv, "video-codec");
      char *vs = mpv_get_property_string(g_mpv.mpv, "video-sync");
      hein_log(
          "SW 诊断：hwdec=%s fmt=%s codec=%s sync=%s container-fps=%.2f "
          "vf-fps=%.2f drop=%d mistimed=%d",
          hd ? hd : "(null)", vf ? vf : "(null)", vc ? vc : "(null)",
          vs ? vs : "(null)", hein_mpv_get_double("container-fps", 0),
          hein_mpv_get_double("estimated-vf-fps", 0),
          (int)hein_mpv_get_double("decoder-frame-drop-count", 0),
          (int)hein_mpv_get_double("mistimed-frame-count", 0));
      mpv_free(hd);
      mpv_free(vf);
      mpv_free(vc);
      mpv_free(vs);
    }
  }
  return true;
}

#endif  // _WIN32：SW 软件渲染路径仅 Linux 使用（Windows 走 D3D11）
bool hein_mpv_render_to_fbo(void) {
#ifndef _WIN32
  // 🔴🔴🔴 2026-10-27 23:05：**SW 软件渲染分支（X11 / gamescope 游戏模式）**。
  //
  //   本机 gamescope 未开 `--expose-wayland`，只合成 X11 客户端 ⇒ GTK 必须
  //   留在 X11；而 GTK3 的 X11 后端只有 GLX，与 Flutter 引擎的 EGL 在同一
  //   X display 上互斥（真机 BadAccess ⇒ SIGSEGV）⇒ 不能走共享 GL 上下文。
  //   故改用 mpv 的 SW 渲染 + FlPixelBufferTexture：全程不建、不共享任何
  //   GL 上下文，与 GTK 的 GLX 零冲突。
  if (g_mpv.sw_mode) {
    // 🔴 2026-10-27：SW 模式**不在主线程渲染**，只唤醒渲染线程。
    //   原因见 hein_sw_render_thread 注释：mpv_render_context_render()
    //   会阻塞到该帧显示时刻，放在主线程会冻结 UI 并拖垮帧率。
    hein_sw_render_thread_wake();
    return true;
  }
  if (g_mpv.mpv_gl == NULL || g_mpv.gl_texture == NULL) return false;
  // 失败态/暂停态：不再出帧（避免无谓的 GL 操作占用主线程）。
  if (HEIN_SUSPEND_GET()) return false;
  if (!g_mpv.has_new_frame) return false;

  // 🔴 GTK tick 回调里，GL 上下文未必是我们的（Flutter runner 可能在帧间
  //    切换过）。渲染前必须重新 makeCurrent，否则 GL 调用会打到别人的
  //    上下文上（表现为画面不出 / FBO 操作无效 / 偶发段错误）。
  //
  // 🔴🔴 优先用阶段②的**共享上下文 B**：纹理/FBO 都建在 B 里，且 mpv 的
  //    render context 已验证能在与创建上下文共享的 B 中正常渲染
  //    （/tmp/ctx_test）。只有 B 还没建好时才回退到阶段①的 A
  //    （不共享，此时 populate 出去的纹理名对 Flutter 无效，属过渡态）。
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    // 🔴 GLX 后端：优先切到阶段②的**共享上下文 B**（纹理/FBO 建在 B 里）。
    if (g_mpv.glx_stage2.context != NULL) {
      hein_glx_make_current(&g_mpv.glx_stage2);
    } else if (g_mpv.glx_stage1.context != NULL) {
      hein_glx_make_current(&g_mpv.glx_stage1);
    }
  } else if (g_mpv.share_egl_display != EGL_NO_DISPLAY &&
             g_mpv.share_egl_context != EGL_NO_CONTEXT) {
    eglMakeCurrent(g_mpv.share_egl_display, g_mpv.share_egl_surface,
                   g_mpv.share_egl_surface, g_mpv.share_egl_context);
  } else if (g_mpv.egl_display != EGL_NO_DISPLAY) {
    eglMakeCurrent(g_mpv.egl_display, g_mpv.egl_surface, g_mpv.egl_surface,
                   g_mpv.egl_context);
  }
  g_mpv.has_new_frame = false;

  int w = 0, h = 0;
  // 🔴🔴 尺寸来源（2026-10-21 重定，修「比例失真」）：
  //   ① view_w/view_h —— **Dart 上报的视频层控件尺寸**，优先。
  //      这是唯一能让 mpv 做 letterbox 的路径：FBO = 控件尺寸，mpv 在
  //      该尺寸内按 video-params 保持宽高比绘制，多出的部分填黑边。
  //      等价于 Android 侧「mpv 渲染进全屏 Surface」。
  //   ② video-out-params/w,h —— 兜底：无控件尺寸时用视频自身尺寸
  //      （此时无黑边，比例由 Flutter 拉伸决定，仅保证能出画）。
  //   ③ width,height          —— 解码后的视频尺寸（首帧 out-params 可能为 0）。
  //   ④ 纹理已有尺寸          —— 最后兜底（**绝不能退到 2x2 占位**，否则黑屏）。
  if (g_mpv.view_w > 4 && g_mpv.view_h > 4) {
    w = g_mpv.view_w;
    h = g_mpv.view_h;
  }
  if (w <= 0 || h <= 0) {
    double out_w = hein_mpv_get_double("video-out-params/w", 0);
    double out_h = hein_mpv_get_double("video-out-params/h", 0);
    if (out_w > 0 && out_h > 0) {
      w = (int)out_w;
      h = (int)out_h;
    }
  }
  if (w <= 0 || h <= 0) {
    double vw = hein_mpv_get_double("width", 0);
    double vh = hein_mpv_get_double("height", 0);
    if (vw > 0 && vh > 0) {
      w = (int)vw;
      h = (int)vh;
    }
  }
  if (w <= 0 || h <= 0) {
    w = hein_gl_texture_get_width(g_mpv.gl_texture);
    h = hein_gl_texture_get_height(g_mpv.gl_texture);
  }
  // 占位尺寸（2x2）下不要出帧：等拿到真实尺寸再渲染，避免把 2x2 提交给 Flutter。
  if (w <= 4 || h <= 4) {
    static int s_sz_log = 0;
    if (++s_sz_log % 60 == 1) {
      hein_log("尺寸未就绪 w=%d h=%d（第 %d 次重试，等 video-out-params）", w, h,
               s_sz_log);
    }
    g_mpv.has_new_frame = true;  // 保留请求，下次再试
    return false;
  }
  // 🔴🔴 2026-10-21 像素浪费修复：
  //    69 掌机物理屏 1080x1920（约 207 万像素），但 Dart 上报的逻辑尺寸是
  //    1440x763 且 dpr=2.0 → FBO 被算成 **2880x1526（440 万像素）**，
  //    是屏幕的 2.2 倍、视频源（1920x1080）的 1.5 倍。
  //    FBO 超出视频源分辨率没有任何画质收益，只是让 mpv 多采样/多输出，
  //    纯属浪费（890M 也要多花一倍时间）。
  //
  //    策略：FBO 尺寸上限 = 视频源显示尺寸（video-params/w,h），
  //    但**不改变宽高比**——按同一比例整体缩放，保证 letterbox 计算不变。
  //    下限保护：不低于 320 宽，避免小窗播放时过度降采样。
  {
    double src_w = hein_mpv_get_double("video-params/w", 0);
    double src_h = hein_mpv_get_double("video-params/h", 0);
    if (src_w > 0 && src_h > 0 && w > 4 && h > 4) {
      // 用「宽高分别不超源」判断，取较小的缩放系数，保证等比。
      double sx = src_w / (double)w;
      double sy = src_h / (double)h;
      double sc = sx < sy ? sx : sy;
      if (sc < 1.0) {
        int nw = (int)(w * sc + 0.5);
        int nh = (int)(h * sc + 0.5);
        if (nw >= 320 && nh >= 180) {
          static int s_clamp_log = 0;
          if (s_clamp_log++ < 3) {
            hein_log("FBO 尺寸收敛: %dx%d → %dx%d（视频源 %.0fx%.0f，"
                     "等比缩放 %.3f，避免无效超采样）",
                     w, h, nw, nh, src_w, src_h, sc);
          }
          w = nw;
          h = nh;
        }
      }
    }
  }
  GLuint fbo = hein_gl_texture_ensure_fbo(g_mpv.gl_texture, w, h);
  if (fbo == 0) return false;

  // 🔴 2026-10-21 比例诊断：把 mpv 眼中的真实几何打出来，用于判断
  //    letterbox 是否真的生效。关键三项：
  //      video-params/w,h       —— 视频编码尺寸
  //      video-params/aspect    —— 视频显示宽高比（含 SAR）
  //      osd-dimensions/*       —— mpv 在给定 FBO 内算出的实际显示矩形
  //    若 osd-dimensions/w,h 恒等于 FBO 尺寸，说明 mpv 认为「铺满」，
  //    letterbox 没发生（keepaspect 未生效或被 video-unscaled 覆盖）。
  {
    static int s_geo_log = 0;
    if (++s_geo_log <= 3 || s_geo_log % 300 == 0) {
      char *ka = mpv_get_property_string(g_mpv.mpv, "keepaspect");
      hein_log("几何: FBO=%dx%d video-params=%dx%d aspect=%.4f "
               "osd=%dx%d osd-margin=%.0f,%.0f keepaspect=%s panscan=%.2f",
               w, h,
               (int)hein_mpv_get_double("video-params/w", 0),
               (int)hein_mpv_get_double("video-params/h", 0),
               hein_mpv_get_double("video-params/aspect", 0),
               (int)hein_mpv_get_double("osd-dimensions/w", 0),
               (int)hein_mpv_get_double("osd-dimensions/h", 0),
               hein_mpv_get_double("osd-dimensions/ml", 0),
               hein_mpv_get_double("osd-dimensions/mt", 0),
               ka != NULL ? ka : "?",
               hein_mpv_get_double("panscan", -1));
      if (ka != NULL) mpv_free(ka);
    }
  }

  // 🔴 2026-10-21 直播「有画面无声音」诊断：把音频链路的关键状态打出来。
  //    判据：
  //      aid=none / audio-codec-name 空 → 该流根本没有音轨（或没选中）
  //      ao=null                        → 音频输出设备未打开
  //      mute=yes / volume=0            → 被静音
  //      audio-params 全 0              → 解码器未产出音频帧
  //    只在有变化时打印，避免刷屏。
  {
    static char s_last_audio[256] = {0};
    char *aid = mpv_get_property_string(g_mpv.mpv, "aid");
    char *acodec = mpv_get_property_string(g_mpv.mpv, "audio-codec-name");
    char *ao = mpv_get_property_string(g_mpv.mpv, "current-ao");
    char *mute = mpv_get_property_string(g_mpv.mpv, "mute");
    double vol = hein_mpv_get_double("volume", -1);
    double ach = hein_mpv_get_double("audio-params/channel-count", 0);
    double asr = hein_mpv_get_double("audio-params/samplerate", 0);
    char buf[256];
    snprintf(buf, sizeof(buf),
             "aid=%s codec=%s ao=%s mute=%s vol=%.0f ch=%.0f sr=%.0f",
             aid ? aid : "(null)", acodec ? acodec : "(null)",
             ao ? ao : "(null)", mute ? mute : "(null)", vol, ach, asr);
    if (strcmp(buf, s_last_audio) != 0) {
      hein_log("音频: %s", buf);
      snprintf(s_last_audio, sizeof(s_last_audio), "%s", buf);
    }
    if (aid) mpv_free(aid);
    if (acodec) mpv_free(acodec);
    if (ao) mpv_free(ao);
    if (mute) mpv_free(mute);
  }

#ifdef __cplusplus
  mpv_opengl_fbo mpv_fbo;
  mpv_fbo.fbo = (int)fbo;
  mpv_fbo.w = w;
  mpv_fbo.h = h;
  mpv_fbo.internal_format = 0;
#else
  mpv_opengl_fbo mpv_fbo = {
      .fbo = (int)fbo,
      .w = w,
      .h = h,
      .internal_format = 0,
  };
#endif
  // 🔴🔴🔴 2026-10-21 「幻灯片」决定性根因（第三次修正，前两次都没抓到）：
  //
  //    mpv 的 `video-sync=audio` 模式下，`mpv_render_context_render()`
  //    **内部会阻塞 sleep**，一直等到这一帧该显示的时刻才返回。
  //    官方文档 render.h 原文（MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME）：
  //      "the player attempts to render video a bit ahead, and then do a
  //       blocking wait until the target display time is reached. This
  //       blocks mpv_render_context_render() for up to the amount
  //       specified with the video-timing-offset global option."
  //
  //    而我们的渲染跑在 **GTK 主线程**，Linux 上 Flutter 的 platform
  //    线程 = GTK 主线程 = 帧时钟驱动线程。于是：
  //      每帧 40ms 阻塞（25fps 视频）→ 主线程 100% 被占满
  //      → Flutter 的 vsync 回调被饿死 → raster 线程拿不到帧
  //      → populate 只剩 4fps → **幻灯片**
  //
  //    这就是「渲染帧 25fps 正常、populate 只有 4fps」的全部原因。
  //    与 GPU 算力完全无关（890M 画 2880x1526 只要 2~3ms）。
  //
  //    修法：显式传 BLOCK_FOR_TARGET_TIME=0，让 render **立刻返回**，
  //    A/V 同步改由 mpv 自身的显示队列 + 我们的 16ms 定时器驱动。
  //    官方文档同时建议这种用法应配合 video-timing-offset=0。
  int block_for_target = 0;
  mpv_render_param params[] = {
      {MPV_RENDER_PARAM_OPENGL_FBO, &mpv_fbo},
      {MPV_RENDER_PARAM_BLOCK_FOR_TARGET_TIME, &block_for_target},
      {MPV_RENDER_PARAM_INVALID, NULL},
  };
  int rc = mpv_render_context_render(g_mpv.mpv_gl, params);
  if (rc < 0) {
    hein_log("mpv_render_context_render 失败 rc=%d (%s)", rc,
             mpv_error_string(rc));
    return false;
  }
  // 🔴🔴 2026-10-21 黑屏根因②：渲染完必须报告 swap。
  //    mpv 的 render API 用 report_swap 作为「这一帧已经显示给用户」的信号，
  //    内部据此推进帧队列与 A/V 同步。**不调用它，mpv 会认为帧一直没被消费，
  //    于是不再触发 update 回调** → 画面停在首帧（2x2 占位）→ 全黑有声，
  //    同时 time-pos 也不推进。最小复现程序里同样观察到该行为。
  {
    mpv_render_param swap_params[] = {
        {MPV_RENDER_PARAM_INVALID, NULL},
    };
    mpv_render_context_report_swap(g_mpv.mpv_gl);
    (void)swap_params;
  }

  // 🔴🔴 2026-10-21 点播「闪烁」→ 已改为**异步围栏**（见下方修复说明）。
  //
  //    历史：上一版此处直接 glFinish()，确实治好了闪烁，但引入了新问题
  //    （69 真机实测）：
  //      渲染帧 25fps 正常，populate 只有 6fps → 幻灯片；
  //      直播则无声 + 最终整个软件冻死。
  //    根因：glFinish() 是**同步阻塞**，而渲染跑在 GTK 主线程，Linux 上
  //    Flutter 的 platform 线程就是 GTK 主线程 → 主线程被每帧阻塞 30~40ms
  //    → 平台线程调度不足（6fps）+ 音频主循环停摆（无声）+ 最终挂死。
  //
  //    修法：glFenceSync 只在 GPU 上插一个围栏标记，**CPU 立即返回**。
  //    围栏由 Flutter 侧在采样前 glWaitSync 等待（见 hein_gl_texture_populate），
  //    从而既保证「写完才被采样」（不闪烁），又不阻塞主线程（不掉帧/不卡死）。
  //
  //    注意：glFenceSync 要求当前上下文 current —— 此处刚做完 render，
  //    上下文仍是壳的共享上下文 B，满足条件。
  // 🔴🔴 2026-10-21 修 GL_WAIT_FAILED（r=0x911d）：
  //    围栏必须在**与 Flutter 共享的上下文 B** 里创建。若在阶段①的
  //    上下文 A（未共享）里创建，Flutter 侧 glClientWaitSync 会直接
  //    返回 GL_WAIT_FAILED —— 同步完全失效，等于没做（画面会撕裂）。
  //    真机日志第 1 帧就是这种情况：围栏 #1 建于 A，随后阶段②切到 B。
  // 🔴 2026-10-26：共享上下文是否就绪，按后端分别判断。
  //   GLX 后端的共享上下文是 g_mpv.glx_stage2（EGL 那套永远是 NO_CONTEXT）。
  const gboolean shared_ready =
      (hein_gl_backend == HEIN_GL_BACKEND_GLX)
          ? (g_mpv.glx_stage2.context != NULL)
          : (g_mpv.share_egl_context != EGL_NO_CONTEXT);
  if (!shared_ready) {
    // B 还没建好：不建围栏（此时纹理对 Flutter 也还无效，无需同步）。
    g_mpv.frame_fence = 0;
    g_mpv.fence_pending = false;
  } else {
    if (g_mpv.frame_fence != 0) {
      // 上一帧的围栏还没被消费：说明 Flutter 尚未采样到它。
      glDeleteSync(g_mpv.frame_fence);
      g_mpv.frame_fence = 0;
    }
    g_mpv.frame_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    g_mpv.fence_pending = true;
  }

  // 翻转 Y：mpv 的 FBO 输出与 Flutter 纹理采样方向相反，必须翻一次，
  // 否则画面上下颠倒（Flutter 的 GL 纹理原点在左上，GL 在左下）。
  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  // 注：mpv 内部已按 GL 约定绘制，此处交由 Flutter 侧统一处理翻转，
  // 见 Dart 层的 flipY 标记说明。
  glBindFramebuffer(GL_FRAMEBUFFER, 0);

  hein_gl_texture_mark_frame(g_mpv.gl_texture);
  if (g_mpv.registered_texture_id > 0) {
    fl_texture_registrar_mark_texture_frame_available(
        g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
  }
  g_mpv.first_frame_emitted = true;
  // 诊断：每 60 帧打一次，确认渲染循环真的在跑（Wayland/Impeller 下排查用）
  static int s_frame_log = 0;
  if (++s_frame_log % 60 == 1) {
    hein_log("渲染帧 #%d %dx%d fbo=%u（纹理已提交 Flutter）", s_frame_log, w, h,
             fbo);
  }
  // 🔴 2026-10-26：像素级出画自检（每 2 秒一次，读 FBO 的 9 个采样点）。
  //   必须在**当前上下文已 current** 的状态下调用 ⇒ 紧跟渲染之后。
  hein_pixel_check_once();
  return true;
#else
  (void)0;
  return false;
#endif
}

void hein_mpv_shutdown(void) {
  // 🔴 2026-10-22：原实现 `if (g_mpv.disposed) return;` 有两个问题：
  //   ① 它把 disposed 当成「shutdown 已做过」的幂等标记，但 disposed 的
  //      真正语义是「当前实例已销毁」，init 会复位它（见 init 入口）。
  //      两者混用导致 shutdown 在第二次及以后**永远空转返回**，
  //      `initialized = false` 执行不到 → initialized 卡 true →
  //      下一次 init 假成功 → render 恒 -18 / 直播 UAF 崩溃。
  //   ② 即使幂等，也应基于「是否还有资源需要清理」判断，而不是单看标志。
  //   修法：只有「标志已置 + 确实没有任何残留资源」才提前返回。
  // ⚠️ render_thread 只在 Windows 分支存在（见 HeinMpv 结构体 _WIN32 段），
  //    Linux 用 EGL/GTK 那套、无独立渲染线程句柄，故此处必须按平台取字段，
  //    否则 Linux 编译期直接报 "no member named 'render_thread'"。
#ifdef _WIN32
  if (g_mpv.disposed && g_mpv.mpv == NULL && g_mpv.mpv_gl == NULL &&
      g_mpv.render_thread == NULL && g_mpv.event_thread == NULL) {
    return;
  }
#else
  if (g_mpv.disposed && g_mpv.mpv == NULL && g_mpv.mpv_gl == NULL &&
      !g_mpv.event_thread_started) {
    return;
  }
#endif
  g_mpv.disposed = true;

  // 🔴🔴 2026-10-21 关闭卡死修复。原实现有三处致命顺序问题：
  //
  //   ① EGL 上下文在 mpv_render_context_free **之前**就被销毁。
  //      mpv 释放 render context 时需要 GL 上下文 current（它要销毁
  //      内部的 GL 对象、libplacebo 资源）。上下文已没了 → mpv 卡在
  //      等待/未定义行为 → 关闭时整个进程挂死。
  //      注释里写「放在最后」，代码却把它放在最前面，属于实现与注释不符。
  //
  //   ② 事件线程阻塞在 mpv_wait_event(mpv, -1)（无限等待），而这里
  //      从未 pthread_join 它，也从未先唤醒。销毁 mpv 句柄时该线程
  //      可能仍在 mpv 内部 → 竞态挂死。
  //
  //   ③ 整个销毁在 **Flutter 平台线程**同步执行。mpv_terminate_destroy
  //      要等 core 线程退出，网络流（尤其连不上的源）会等很久 → UI 冻结，
  //      用户看到的就是「点关闭后软件卡死」。
  //
  //   正确顺序：先断更新回调 → 释放 render context（EGL 仍 current）
  //   → 销毁 EGL → 唤醒并 join 事件线程 → 最后 terminate_destroy mpv。

  // ① 先摘掉 update 回调，避免销毁过程中 mpv 线程再回调进来。
  if (g_mpv.mpv_gl != NULL) {
    mpv_render_context_set_update_callback(g_mpv.mpv_gl, NULL, NULL);
  }

  // ①b 🔴🔴🔴 2026-10-22 直播「直接播放闪退」根因（0xC0000005 @
  //      heinplay_mpv_desktop.dll+0x8e68）：
  //
  //   原实现把「停渲染线程」放在 **⑤**，即在 ② mpv_render_context_free
  //   **之后**。而渲染线程的循环体是：
  //       WaitForSingleObject(render_wake_event, 100) → hein_mpv_pump_windows()
  //   它随时可能正卡在 mpv_render_context_render() 里面。此时主线程把
  //   render context free 掉 → 渲染线程手里那个 g_mpv.mpv_gl 立刻变成
  //   悬空指针，它下一次解引用就是 use-after-free。
  //
  //   为什么点播不易复现、直播必崩：点播起播慢、帧稀疏，撞上的概率低；
  //   直播是一收到流就**持续高频出帧**，渲染线程几乎总在 render 里，
  //   shutdown 一执行就必撞。
  //
  //   修法：**先停线程，再释放它正在用的资源**。顺序必须是
  //     停渲染线程 → 释放 render context → terminate_destroy → join 事件线程。
  //   这也是 Linux 侧同样的顺序要求（那边 ⑤ 在 ② 之前是因为 GL 上下文
  //   必须 current，Windows 无此约束，可以彻底按「先停线程」来）。
#ifdef _WIN32
  if (g_mpv.render_thread != NULL) {
    InterlockedExchange(&g_mpv.render_thread_running, 0);
    if (g_mpv.render_wake_event != NULL) SetEvent(g_mpv.render_wake_event);
    // 限时等待：渲染线程每轮最多睡 100ms，2 秒足够。
    // 超时不强杀（TerminateThread 会导致 D3D11/mpv 内部状态不一致，
    // 可能引起退出期崩溃），改为交内核收尾。
    DWORD wrc = WaitForSingleObject(g_mpv.render_thread, 2000);
    if (wrc == WAIT_OBJECT_0) {
      hein_log("渲染线程已 join");
    } else {
      hein_log("渲染线程 join 超时（wrc=%lu），已 detach", (unsigned long)wrc);
    }
    CloseHandle(g_mpv.render_thread);
    g_mpv.render_thread = NULL;
  }
  if (g_mpv.render_wake_event != NULL) {
    CloseHandle(g_mpv.render_wake_event);
    g_mpv.render_wake_event = NULL;
  }
#endif

  // ② 释放 render context：此时渲染线程已停，不会再有并发 render。
#ifndef _WIN32
  // 🔴 2026-10-26：GLX 后端下要先把 GLX 上下文 current 住再释放 render
  //   context（GL 资源必须在自己的上下文里释放）。
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    if (g_mpv.glx_stage2.context != NULL) {
      hein_glx_make_current(&g_mpv.glx_stage2);
    } else if (g_mpv.glx_stage1.context != NULL) {
      hein_glx_make_current(&g_mpv.glx_stage1);
    }
  } else if (g_mpv.egl_display != EGL_NO_DISPLAY &&
             g_mpv.egl_context != EGL_NO_CONTEXT) {
    eglMakeCurrent(g_mpv.egl_display,
                   g_mpv.egl_surface != EGL_NO_SURFACE ? g_mpv.egl_surface
                                                       : EGL_NO_SURFACE,
                   g_mpv.egl_surface != EGL_NO_SURFACE ? g_mpv.egl_surface
                                                       : EGL_NO_SURFACE,
                   g_mpv.egl_context);
  }
#endif
  if (g_mpv.mpv_gl) {
    mpv_render_context_free(g_mpv.mpv_gl);
    g_mpv.mpv_gl = NULL;
  }
#ifndef _WIN32
  // 2026-10-27：SW 模式句柄与纹理同样必须释放，否则重进播放页会泄漏
  // （且旧 sw_texture 残留会让下一次注册拿到已失效对象）。
  // 先停渲染线程，再释放它可能正在使用的 render context。
  hein_sw_render_thread_stop();
  if (g_mpv.mpv_sw) {
    mpv_render_context_free((mpv_render_context *)g_mpv.mpv_sw);
    g_mpv.mpv_sw = NULL;
  }
  if (g_mpv.sw_buf != NULL) {
    g_free(g_mpv.sw_buf);
    g_mpv.sw_buf = NULL;
    g_mpv.sw_buf_size = 0;
  }
  g_mpv.sw_w = 0;
  g_mpv.sw_h = 0;
#endif  // _WIN32：SW 句柄释放仅 Linux 使用
  // 2026-10-26：清掉可能还挂着的延迟 loadfile（否则下次 init 会误加载）。
  if (g_mpv.deferred_url != NULL) {
    g_free(g_mpv.deferred_url);
    g_mpv.deferred_url = NULL;
  }

#ifndef _WIN32
  // ③ 注销纹理（必须在 EGL 还活着时做：Flutter 可能还要取一次纹理名）。
  if (g_mpv.registered_texture_id > 0 && g_mpv.texture_registrar != NULL) {
    if (g_mpv.sw_mode && g_mpv.sw_texture != NULL) {
      fl_texture_registrar_unregister_texture(
          g_mpv.texture_registrar, FL_TEXTURE(g_mpv.sw_texture));
    } else if (g_mpv.gl_texture != NULL) {
      fl_texture_registrar_unregister_texture(
          g_mpv.texture_registrar, FL_TEXTURE(g_mpv.gl_texture));
    }
    g_mpv.registered_texture_id = 0;
  }
  if (g_mpv.sw_texture != NULL) {
    g_clear_object(&g_mpv.sw_texture);
  }
  g_clear_object(&g_mpv.gl_texture);

  // ④ 现在才销毁 EGL（render context 已释放，GL 对象不再被引用）。
  if (g_mpv.egl_display != EGL_NO_DISPLAY) {
    eglMakeCurrent(g_mpv.egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
    if (g_mpv.egl_context != EGL_NO_CONTEXT) {
      eglDestroyContext(g_mpv.egl_display, g_mpv.egl_context);
      g_mpv.egl_context = EGL_NO_CONTEXT;
    }
    if (g_mpv.egl_surface != EGL_NO_SURFACE) {
      eglDestroySurface(g_mpv.egl_display, g_mpv.egl_surface);
      g_mpv.egl_surface = EGL_NO_SURFACE;
    }
    // ⚠️ 不调 eglTerminate：该 EGLDisplay 可能来自 Flutter 引擎
    //    （共享上下文重建后我们用 Flutter 的 display），terminate 会把
    //    Flutter 自己的 EGL 一起干掉 → 退出期崩溃。
    g_mpv.egl_display = EGL_NO_DISPLAY;
  }

  // ④b 销毁阶段②的共享上下文。⚠️ 同样**不** eglTerminate：
  //     该 display 就是 Flutter 的 display，terminate 会连带干掉 Flutter。
  if (g_mpv.share_egl_display != EGL_NO_DISPLAY) {
    eglMakeCurrent(g_mpv.share_egl_display, EGL_NO_SURFACE, EGL_NO_SURFACE,
                   EGL_NO_CONTEXT);
    if (g_mpv.share_egl_context != EGL_NO_CONTEXT) {
      eglDestroyContext(g_mpv.share_egl_display, g_mpv.share_egl_context);
      g_mpv.share_egl_context = EGL_NO_CONTEXT;
    }
    if (g_mpv.share_egl_surface != EGL_NO_SURFACE) {
      eglDestroySurface(g_mpv.share_egl_display, g_mpv.share_egl_surface);
      g_mpv.share_egl_surface = EGL_NO_SURFACE;
    }
    g_mpv.share_egl_display = EGL_NO_DISPLAY;
  }

  // ④c 销毁 GLX 后端的两个上下文（阶段②共享 + 阶段①自有）。
  //     ⚠️ 销毁前要把上下文设为非 current，否则 Mesa 可能留下野指针。
  if (hein_gl_backend == HEIN_GL_BACKEND_GLX) {
    if (g_mpv.glx_stage2.display != NULL) {
      hein_glx_clear_current(g_mpv.glx_stage2.display);
    }
    hein_glx_context_destroy(&g_mpv.glx_stage2);
    hein_glx_context_destroy(&g_mpv.glx_stage1);
  }
#endif

  // ⑤ 渲染线程已在 ①b 提前停掉（必须先于 mpv_render_context_free）。
  //    此处保留标记位说明，不再重复停线程。

  // ⑥ 销毁 mpv 实例：mpv_terminate_destroy 会投递 MPV_EVENT_SHUTDOWN，
  //    使阻塞在 mpv_wait_event 的事件线程得以返回。
  if (g_mpv.mpv) {
    mpv_terminate_destroy(g_mpv.mpv);
    g_mpv.mpv = NULL;
  }

  // ⑦ join 事件线程，确保它真的退出后再返回（否则进程退出时线程
  //    仍可能在跑，导致 atexit/析构阶段挂死）。
  if (g_mpv.event_thread_started) {
    // 🔴 关闭卡死根治（同 Android 侧 2026-10-14 经验）：不能无限期 join。
    //    事件线程已改 0.05s 短超时轮询并在 disposed 后自行退出，正常情况
    //    下 join 立即返回；但若 mpv 内部仍卡在网络超时里，join 可能长时间
    //    阻塞主线程 → 用户看到「软件无响应」。
    //    故限时等待：超时则不阻塞 UI，让线程自己收尾。
#ifdef _WIN32
    DWORD wrc = WaitForSingleObject(g_mpv.event_thread, 2000);
    if (wrc == WAIT_OBJECT_0) {
      hein_log("事件线程已 join");
      CloseHandle(g_mpv.event_thread);
      g_mpv.event_thread = NULL;
    } else {
      hein_log("事件线程 join 超时（wrc=%lu），不阻塞 UI", (unsigned long)wrc);
      // 句柄交内核：线程退出时自动释放，避免泄漏。
      CloseHandle(g_mpv.event_thread);
      g_mpv.event_thread = NULL;
    }
#else
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 2;  // 最多等 2 秒
    int jrc = pthread_timedjoin_np(g_mpv.event_thread, NULL, &ts);
    if (jrc == 0) {
      hein_log("事件线程已 join");
    } else {
      // ETIMEDOUT：线程仍卡在 mpv 内部，detach 后不阻塞退出。
      hein_log("事件线程 join 超时（rc=%d），已 detach 避免阻塞 UI", jrc);
      pthread_detach(g_mpv.event_thread);
    }
#endif
    g_mpv.event_thread_started = false;
  }

  g_mpv.initialized = false;

  // 🔴🔴 2026-10-21 直播/第二次播放全黑根因（69 真机日志实证）。
  //
  //    shutdown 销毁了 share_egl_context（阶段②的共享上下文 B），但**没有**
  //    重置 share_rebuild_done。而 hein_on_flutter_context_captured() 的第一行是
  //        if (g_mpv.share_rebuild_done) return;
  //    于是**第二次及以后的 mpv 实例永远不会再执行阶段②**。
  //
  //    实测序列（hein_native.log）：
  //      #1 点播：有「阶段②完成」→ 纹理在 B 中重建 → 能出画
  //      #2 直播：**没有**「阶段②完成」→ 纹理仍是上下文 A 里的旧名字
  //               （A 已被销毁）→ Flutter 在 B 中采样到无效纹理名 → 全黑，
  //               且不产生任何错误（纹理名非 0，GL 不报错，只是采样到空内容）。
  //
  //    修复：shutdown 必须把共享上下文相关的所有状态清零，让下一个实例
  //    重新走完整的两阶段初始化。这些字段与 share_egl_context 是同一组
  //    生命周期，销毁上下文却留下「已建好」的标记是自相矛盾的。
  //
  // ⚠️ Windows 无 EGL，这段只在 Linux 编译（D3D11 路线下不存在
  //    「纹理建在 A、Flutter 在 B 里采样」的问题：纹理由我们自己建并
  //    经 DXGI 共享句柄交给引擎，与 mpv 的设备是同一个）。
#ifndef _WIN32
  g_mpv.share_rebuild_done = false;
  g_atomic_int_set(&g_mpv.flutter_ctx_captured, 0);
  g_mpv.flutter_egl_context = EGL_NO_CONTEXT;
  g_mpv.flutter_egl_display = EGL_NO_DISPLAY;
  // 🔴 2026-10-26：GLX 后端同样要重置捕获到的 Flutter GLX 上下文。
  g_mpv.flutter_glx_context = NULL;
  g_mpv.flutter_glx_display = NULL;
#endif

  // Windows 侧同样要清零「已初始化」之外的运行期状态，保证第二次
  // init 能完整重来（尤其是 suspended 标志：播放失败后置过 1，
  // 不清则第二次播放永远不出帧）。
#ifdef _WIN32
  HEIN_SUSPEND_SET(0);
  g_mpv.has_new_frame = false;
  g_mpv.view_w = 0;
  g_mpv.view_h = 0;
  g_mpv.render_frame_count = 0;
  g_mpv.populate_count = 0;
  g_mpv.win_texture = NULL;
#endif

  hein_log("mpv 已完全关闭（运行期状态已重置，下次播放将完整重来）");
  // 🔴 退出路径诊断：把标记写进文件并同步落盘。
  //    原因：进程退出时 stdout 缓冲可能来不及刷新，导致「清理日志看不到」
  //    被误判成「清理没执行」。写文件 + fsync 才能确认 shutdown 真的跑了。
  {
    const char *marker = g_getenv("HEIN_MPV_SHUTDOWN_MARKER");
    if (marker != NULL && *marker != '\0') {
#ifdef _WIN32
      FILE *f = fopen(marker, "w");
      if (f != NULL) {
        fprintf(f, "shutdown-ok pid=%lu\n",
                (unsigned long)GetCurrentProcessId());
        fflush(f);
        // Windows 的 _commit 等价于 POSIX fsync。
        _commit(_fileno(f));
        fclose(f);
      }
#else
      FILE *f = fopen(marker, "w");
      if (f != NULL) {
        fprintf(f, "shutdown-ok pid=%d\n", (int)getpid());
        fflush(f);
        fsync(fileno(f));
        fclose(f);
      }
#endif
    }
  }
}

#ifdef _WIN32
// Windows 侧 CreateThread 适配壳：CreateThread 要求 DWORD WINAPI f(LPVOID)，
// 与上面的 void* f(void*) 不兼容。包一层转发，复用同一实现。
static DWORD WINAPI hein_event_thread_proc(LPVOID arg) {
  hein_event_thread(arg);
  return 0;
}
#endif

#ifdef __cplusplus
}  // extern "C"
#endif
