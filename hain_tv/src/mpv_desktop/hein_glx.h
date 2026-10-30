// 桌面 mpv 壳 · Linux 侧 GLX 上下文管理（X11 会话 / gamescope 游戏模式）。
//
// 🔴🔴 为什么单独成文件（2026-10-26）
//
//   ① libepoxy 的 <epoxy/glx.h> 里 **glXMakeCurrent 的原型是错的**
//      （4 参、drawable 类型也不对），用它会编译失败或行为异常；
//      而 <GL/glx.h> 与 <epoxy/gl.h> 又会互相冲突
//      （KHRONOS_FALSE / GLXPbufferClobberEvent 重复定义）。
//      ⇒ 只能让**不同 TU 用不同头**：本文件用系统 <GL/glx.h>，
//        其余文件用 epoxy 的头。
//   ② GLX 的上下文/共享必须与 Flutter 用**同一条 X 连接**
//      （纹理命名空间按 X 连接隔离，自己 XOpenDisplay 另开一条连接则不共享），
//      故 Display* 必须取自 GDK（gdk_x11_get_default_xdisplay()），
//      不能自己 XOpenDisplay。
//
// 【已实测的事实】（69 掌机，2026-10-26）
//   · GtkGLArea 在 gamescope 的 X11 下拿到的是 **GLX** 上下文
//     （GL 4.6 Core Profile / Radeon 880M / 硬件加速）；
//   · `glXCreateContext(dpy, vi, share=Flutter的GLXcontext, True)`
//     建出的共享上下文里写 FBO 纹理，回到原上下文 glGetTexImage
//     读回 RGBA=(0,255,0,255) ⇒ **跨 context 纹理共享成立**；
//   · monitor 正确识别为 1920x1080 scale=1 refresh=143.9。

#ifndef HEIN_GLX_H_
#define HEIN_GLX_H_

#include <glib.h>

G_BEGIN_DECLS

// GLX 句柄（类型在此处用 void* 表示，避免把 GL/glx.h 泄到其它 TU）。
typedef struct {
  void *display;   // Display*
  void *context;   // GLXContext
  void *pbuffer;   // GLXPbuffer（离屏 drawable，GLX 必须有 drawable 才能 makeCurrent）
  void *fbconfig;  // GLXFBConfig
  void *visual;    // XVisualInfo*
} HeinGLXHandle;

// 阶段①：建**不共享**的壳上下文（给 mpv render context 提供 current 上下文）。
gboolean hein_glx_context_create(HeinGLXHandle *h, char *err, int errlen);

// 阶段②：建**与 Flutter 共享**的上下文（share_ctx = Flutter 的 GLXContext）。
gboolean hein_glx_context_create_shared(HeinGLXHandle *h,
                                         void *share_ctx,
                                         char *err,
                                         int errlen);

// makeCurrent 到该句柄的 drawable。
gboolean hein_glx_make_current(const HeinGLXHandle *h);

// 销毁（destroy context + pbuffer）。
void hein_glx_context_destroy(HeinGLXHandle *h);

// 取消当前上下文（释放资源前调用）。
void hein_glx_clear_current(void *display);

// 当前线程的 GLX 上下文 / X 连接（未 current 时返回 NULL）。
void *hein_glx_current_context(void);
void *hein_glx_current_display(void);

// GDK 的 X11 连接（必须与 Flutter 同一条 ⇒ 纹理才能共享）。
void *hein_glx_default_display(void);

// 🔴🔴🔴 2026-10-26：安装**容错**的 X 错误处理器（记录并忽略，不 abort）。
//   起因：游戏模式（gamescope XWayland）下 mpv 内部发起的一条 GLX 请求
//   触发 GLXBadDrawable，GDK 默认处理器直接 abort 整个应用。
//   详见 hein_glx.c 中的实现说明。
void hein_x_install_tolerant_error_handler(void);

// 🔴🔴🔴 2026-10-26：安装崩溃回溯处理器（SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE）。
//   捕获时把调用栈写进 native 日志，随后恢复默认行为并重新 raise
//   （进程仍以原信号终止，退出码与崩溃语义不变）。
void hein_x_install_crash_backtrace_handler(void);

G_END_DECLS

#endif  // HEIN_GLX_H_
