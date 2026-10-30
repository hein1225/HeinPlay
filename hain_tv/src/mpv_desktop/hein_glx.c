// 桌面 mpv 壳 · Linux 侧 GLX 上下文管理实现。
//
// ⚠️ 本文件是**唯一** include 系统 <GL/glx.h> 的 TU（原因见 hein_glx.h 注释）。
#include "hein_glx.h"

#include <GL/gl.h>
#include <GL/glx.h>
#include <gtk/gtk.h>
#include <gdk/gdkx.h>
#include <stdio.h>
#include <string.h>

// GLX 1.0 的传统 API：share 参数直接就是「要与之共享的已有 context」。
// ⚠️ glXCreateContextAttribsARB 的 share 参数是 GLXFBConfig 而非 context，
//    且在 Xwayland 上用它会报 BadValue ⇒ 一律用传统 API。
static gboolean hein_glx_pick_config(Display *dpy,
                                      GLXFBConfig *out_fbc,
                                      XVisualInfo **out_vi,
                                      char *err,
                                      int errlen) {
  int fb_attribs[] = {GLX_X_RENDERABLE,
                      True,
                      GLX_DRAWABLE_TYPE,
                      GLX_WINDOW_BIT,
                      GLX_RENDER_TYPE,
                      GLX_RGBA_BIT,
                      GLX_RED_SIZE,
                      8,
                      GLX_GREEN_SIZE,
                      8,
                      GLX_BLUE_SIZE,
                      8,
                      GLX_ALPHA_SIZE,
                      8,
                      GLX_DOUBLEBUFFER,
                      True,
                      None};
  int count = 0;
  GLXFBConfig *cfgs =
      glXChooseFBConfig(dpy, DefaultScreen(dpy), fb_attribs, &count);
  if (cfgs == NULL || count < 1) {
    snprintf(err, errlen, "glXChooseFBConfig 失败 count=%d", count);
    return FALSE;
  }
  GLXFBConfig fbc = cfgs[0];
  XVisualInfo *vi = glXGetVisualFromFBConfig(dpy, fbc);
  XFree(cfgs);
  if (vi == NULL) {
    snprintf(err, errlen, "glXGetVisualFromFBConfig 失败");
    return FALSE;
  }
  *out_fbc = fbc;
  *out_vi = vi;
  return TRUE;
}

static gboolean hein_glx_make_pbuffer(Display *dpy,
                                      GLXFBConfig fbc,
                                      GLXPbuffer *out_pbuf,
                                      char *err,
                                      int errlen) {
  int pb_attribs[] = {GLX_PBUFFER_WIDTH,
                      64,
                      GLX_PBUFFER_HEIGHT,
                      64,
                      GLX_LARGEST_PBUFFER,
                      False,
                      GLX_PRESERVED_CONTENTS,
                      True,
                      None};
  GLXPbuffer pbuf = glXCreatePbuffer(dpy, fbc, pb_attribs);
  if (pbuf == 0) {
    snprintf(err, errlen, "glXCreatePbuffer 失败");
    return FALSE;
  }
  *out_pbuf = pbuf;
  return TRUE;
}

gboolean hein_glx_context_create(HeinGLXHandle *h, char *err, int errlen) {
  memset(h, 0, sizeof(*h));
  Display *dpy = (Display *)hein_glx_default_display();
  if (dpy == NULL) {
    snprintf(err, errlen, "没有可用的 X11 连接（GDK 不是 X11 后端？）");
    return FALSE;
  }
  GLXFBConfig fbc = NULL;
  XVisualInfo *vi = NULL;
  if (!hein_glx_pick_config(dpy, &fbc, &vi, err, errlen)) return FALSE;
  GLXContext ctx = glXCreateContext(dpy, vi, NULL, True);
  if (ctx == NULL) {
    snprintf(err, errlen, "glXCreateContext 失败");
    return FALSE;
  }
  GLXPbuffer pbuf = 0;
  if (!hein_glx_make_pbuffer(dpy, fbc, &pbuf, err, errlen)) {
    glXDestroyContext(dpy, ctx);
    return FALSE;
  }
  h->display = dpy;
  h->context = ctx;
  h->pbuffer = (void *)(uintptr_t)pbuf;
  h->fbconfig = (void *)(uintptr_t)fbc;
  h->visual = vi;
  return TRUE;
}

gboolean hein_glx_context_create_shared(HeinGLXHandle *h,
                                         void *share_ctx,
                                         char *err,
                                         int errlen) {
  memset(h, 0, sizeof(*h));
  Display *dpy = (Display *)hein_glx_default_display();
  if (dpy == NULL) {
    snprintf(err, errlen, "没有可用的 X11 连接");
    return FALSE;
  }
  GLXFBConfig fbc = NULL;
  XVisualInfo *vi = NULL;
  if (!hein_glx_pick_config(dpy, &fbc, &vi, err, errlen)) return FALSE;
  // 🔴 关键：share 参数 = Flutter 的 GLXContext ⇒ 纹理/FBO 名字两边共享。
  GLXContext ctx = glXCreateContext(dpy, vi, (GLXContext)share_ctx, True);
  if (ctx == NULL) {
    snprintf(err, errlen, "glXCreateContext(share=Flutter) 失败");
    return FALSE;
  }
  GLXPbuffer pbuf = 0;
  if (!hein_glx_make_pbuffer(dpy, fbc, &pbuf, err, errlen)) {
    glXDestroyContext(dpy, ctx);
    return FALSE;
  }
  h->display = dpy;
  h->context = ctx;
  h->pbuffer = (void *)(uintptr_t)pbuf;
  h->fbconfig = (void *)(uintptr_t)fbc;
  h->visual = vi;
  return TRUE;
}

gboolean hein_glx_make_current(const HeinGLXHandle *h) {
  if (h->display == NULL || h->context == NULL) return FALSE;
  Display *dpy = (Display *)h->display;
  GLXDrawable drawable = (GLXDrawable)(uintptr_t)h->pbuffer;
  return glXMakeCurrent(dpy, drawable, (GLXContext)h->context) ? TRUE : FALSE;
}

void hein_glx_context_destroy(HeinGLXHandle *h) {
  if (h->display == NULL) return;
  Display *dpy = (Display *)h->display;
  if (h->context != NULL) {
    glXDestroyContext(dpy, (GLXContext)h->context);
    h->context = NULL;
  }
  if (h->pbuffer != NULL) {
    glXDestroyPbuffer(dpy, (GLXPbuffer)(uintptr_t)h->pbuffer);
    h->pbuffer = NULL;
  }
}

void hein_glx_clear_current(void *display) {
  if (display == NULL) return;
  glXMakeCurrent((Display *)display, (GLXDrawable)0, NULL);
}

void *hein_glx_current_context(void) {
  return (void *)glXGetCurrentContext();
}

void *hein_glx_current_display(void) {
  return (void *)glXGetCurrentDisplay();
}

void *hein_glx_default_display(void) {
  // 🔴 必须用 GDK 的 X 连接（与 Flutter 同一条）⇒ 纹理命名空间才共享。
  //    自己 XOpenDisplay 会另开一条连接，纹理名字对不上 ⇒ 采样全黑。
  if (gdk_display_get_default() == NULL) return NULL;
  return (void *)gdk_x11_get_default_xdisplay();
}

// 🔴🔴🔴 2026-10-26：容错 X 错误处理器。
//
// 【真机故障】游戏模式（gamescope 的 XWayland，DISPLAY=:1）下自检启动后
//   1 秒内进程直接死亡：
//     Gdk-WARNING: The program 'com.heinplay.hain_tv' received an X Window
//     System error. The error was 'GLXBadDrawable'.
//     (serial 273 error_code 160 request_code 150 (GLX) minor_code 29)
//
// 【为什么要单独处理】GDK 的默认 X 错误处理器是 **abort**（直接终止进程）。
//   播放器进程被一条「别人（mpv）发起的 GLX 请求」引发的 X 错误带走，
//   属于最坏结果：整个应用退出，用户看到的是「游戏模式打不开/闪退」。
//   ⇒ 这里换成**记录 + 忽略**的处理器：X 错误照常写进 native 日志便于
//     事后追查，但不再终止进程。
//
// ⚠️ 仅在本文件（唯一 include <GL/glx.h> 与 X11 头的 TU）实现，避免
//    <X11/Xlib.h> 与 <epoxy/egl.h> 的宏/类型冲突。
extern void hein_log(const char *fmt, ...);

#ifdef __GLIBC__
#include <execinfo.h>
#include <stdlib.h>  // free()
// 🔴 诊断：把**调用方栈**一起打出来。
//   X 错误是异步投递的，回溯只能定位「谁在发 X 请求」的那条线索，
//   但足以区分「GTK3 的 GdkGLContext(X11→GLX)」与「mpv / 我们自己的代码」。
static void hein_x_log_backtrace(void) {
  void *frames[24];
  int n = backtrace(frames, 24);
  char **syms = backtrace_symbols(frames, n);
  if (syms == NULL) return;
  hein_log("X 错误调用栈：");
  for (int i = 0; i < n && i < 12; i++) {
    hein_log("  #%d %s", i, syms[i]);
  }
  free(syms);
}
#else
static void hein_x_log_backtrace(void) {}
#endif

static int hein_x_tolerant_error_handler(Display *dpy, XErrorEvent *ev) {
  char text[256] = {0};
  if (dpy != NULL && ev != NULL) {
    XGetErrorText(dpy, ev->error_code, text, (int)sizeof(text) - 1);
  }
  hein_log("X 错误（已忽略，不终止进程）：%s code=%d request=%d minor=%d "
           "serial=%lu",
           text, ev ? ev->error_code : 0, ev ? ev->request_code : 0,
           ev ? ev->minor_code : 0, ev ? (unsigned long)ev->serial : 0ul);
  hein_x_log_backtrace();
  return 0;  // 0 = 继续运行
}

void hein_x_install_tolerant_error_handler(void) {
  XSetErrorHandler(hein_x_tolerant_error_handler);
}

// 🔴🔴🔴 2026-10-26：崩溃回溯（SIGSEGV / SIGABRT / SIGBUS / SIGILL / SIGFPE）。
//
// 【真机故障】游戏模式（gamescope XWayland）下自检：进程在 START_FILE 后
//   约 1 秒 **SIGSEGV**（退出码 139），且日志里先出现一批 GLX 的 X 错误。
//   没有回溯时无法判断是「mpv 内部」「GTK3」还是「我们自己的代码」崩的。
//   ⇒ 这里装一个信号处理器，把**调用栈**写进 native 日志再交还默认行为
//     （恢复默认处理并重新 raise，保证进程仍以原信号终止、退出码不变）。
//
// ⚠️ 信号处理器里只做「写日志 + 回溯」这类可重入安全的操作；
//    写完立刻恢复 SIG_DFL 并 raise，语义与不装处理器完全一致。
#ifdef __GLIBC__
#include <signal.h>
#include <unistd.h>

static void hein_crash_handler(int sig) {
  const char *name = "SIG?";
  switch (sig) {
    case SIGSEGV: name = "SIGSEGV"; break;
    case SIGABRT: name = "SIGABRT"; break;
    case SIGBUS:  name = "SIGBUS";  break;
    case SIGILL:  name = "SIGILL";  break;
    case SIGFPE:  name = "SIGFPE";  break;
    default: break;
  }
  hein_log("=== 捕获 %s，开始写调用栈 ===", name);
  hein_x_log_backtrace();
  // 恢复默认行为并重新发信号：让进程以原信号终止（退出码与崩溃语义不变）。
  signal(sig, SIG_DFL);
  raise(sig);
}
#endif

void hein_x_install_crash_backtrace_handler(void) {
#ifdef __GLIBC__
  // 🔴 2026-10-26：**默认关闭**，只在排障时开启。
  //   理由：它会接管 SIGSEGV/SIGABRT 等信号的处理（虽然最终仍恢复默认
  //   行为并 re-raise，但多一层风险）。开启方式：HEIN_MPV_CRASH_BT=1。
  //   本次定位游戏模式崩溃点，靠的就是它给出的调用栈。
  if (g_getenv("HEIN_MPV_CRASH_BT") == NULL) return;
  signal(SIGSEGV, hein_crash_handler);
  signal(SIGABRT, hein_crash_handler);
  signal(SIGBUS, hein_crash_handler);
  signal(SIGILL, hein_crash_handler);
  signal(SIGFPE, hein_crash_handler);
#endif
}
