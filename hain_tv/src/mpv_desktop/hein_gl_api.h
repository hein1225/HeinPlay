// 桌面 mpv 壳 · Linux 侧 GL 后端抽象（EGL / GLX 双后端）。
//
// 🔴🔴🔴 为什么必须做这个抽象（2026-10-26 69 掌机 gamescope 实测得出）
//
//   Linux 上有两种会话，Flutter 用的 **GL API 完全不同**：
//     · Wayland 会话（桌面 GNOME Wayland）
//         → GTK3 的 Wayland 后端**必然**用 EGL；Flutter 的引擎也用 EGL，
//           且建的是 **OpenGL ES 2.0** 上下文。
//     · X11 会话（Steam/Bazzite 游戏模式，Steam 以 X11 启动应用走 XWayland）
//         → GTK3 的 X11 后端用 **GLX**；Flutter 拿到的是 **桌面 OpenGL**
//           上下文（实测 GL 4.6 Core Profile / Radeon 880M）。
//
//   mpv 壳与 Flutter 之间靠**纹理共享**传画面，因此壳的上下文必须与
//   Flutter **同 API 且共享命名空间**：
//     · EGL/GLES2 ↔ EGL/GLES2   ✔（桌面模式现状，可用）
//     · GLX/桌面GL ↔ GLX/桌面GL  ✔（游戏模式，2026-10-26 实测共享成功：
//                                  原上下文 glGetTexImage 读回 RGBA=(0,255,0,255)）
//     · GLX ↔ EGL               ✘（Mesa 不支持跨 API 共享，必然黑屏）
//
//   ⚠️ libepoxy 的 dispatch 是**进程级且 EGL 优先**（只要进程里加载了
//      libEGL，epoxy_glXxx 就走 eglGetProcAddress），因此**不能**指望
//      同一套 epoxy 指针在 GLX 会话里可用：GLX 会话需要的是**桌面 GL**
//      实现（glXGetProcAddressARB），EGL 会话需要的是 **GLES2** 实现
//      （eglGetProcAddress）。
//
//   ⇒ 故此处维护一张**运行时可切换的 GL 函数表**，并用宏把全工程的
//      glXxx 调用重定向到表里：
//        · EGL 后端 → 表里填 epoxy（eglGetProcAddress）实现（行为与改造前
//          **完全一致**，桌面版零影响）；
//        · GLX 后端 → 表里填 glXGetProcAddressARB 实现。
//
//   表必须在任何 GL 调用**之前**初始化（hein_gl_api_init）。

#ifndef HEIN_GL_API_H_
#define HEIN_GL_API_H_

#include <glib.h>
#include <epoxy/gl.h>
#include <epoxy/egl.h>
#include <epoxy/glx.h>

G_BEGIN_DECLS

// GL 后端类型。
typedef enum {
  HEIN_GL_BACKEND_NONE = 0,
  // Wayland 会话：Flutter 用 EGL + OpenGL ES 2.0。
  HEIN_GL_BACKEND_EGL,
  // X11 会话（gamescope 游戏模式）：Flutter 用 GLX + 桌面 OpenGL。
  HEIN_GL_BACKEND_GLX,
} HeinGLBackend;

// GL 函数表（只收录壳真正用到的）。
typedef struct {
  void (*GenTextures)(GLsizei, GLuint *);
  void (*DeleteTextures)(GLsizei, const GLuint *);
  void (*BindTexture)(GLenum, GLuint);
  void (*TexImage2D)(GLenum, GLint, GLint, GLsizei, GLsizei, GLint, GLenum,
                     GLenum, const void *);
  void (*TexParameteri)(GLenum, GLenum, GLint);
  void (*GenFramebuffers)(GLsizei, GLuint *);
  void (*DeleteFramebuffers)(GLsizei, const GLuint *);
  void (*BindFramebuffer)(GLenum, GLuint);
  void (*FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
  GLenum (*CheckFramebufferStatus)(GLenum);
  GLsync (*FenceSync)(GLenum, GLbitfield);
  void (*DeleteSync)(GLsync);
  GLenum (*ClientWaitSync)(GLsync, GLbitfield, GLuint64);
  // ⚠️ GL 规范的 glWaitSync 是 **2 参**（sync, flags）；
  //    libepoxy 头里的 epoxy_glWaitSync 写成了 3 参（多一个 timeout），
  //    那是 glWaitSync64 的签名。填表时统一按规范的 2 参类型，
  //    EGL 侧靠一次显式 cast 对齐（既有代码一直是 2 参调用）。
  void (*WaitSync)(GLsync, GLbitfield);
  void (*Finish)(void);
  const GLubyte *(*GetString)(GLenum);
  void (*ReadPixels)(GLint, GLint, GLsizei, GLsizei, GLenum, GLenum, void *);
} HeinGLApi;

// 全局函数表 + 当前后端。
extern HeinGLApi hein_gl_api;
extern HeinGLBackend hein_gl_backend;

// 按后端填充函数表。必须在任何 GL 调用之前调用。
// EGL 后端填 epoxy（= 改造前的行为）；GLX 后端填 glXGetProcAddressARB。
void hein_gl_api_init(HeinGLBackend backend);

// 当前进程用的是哪种 GL 后端（诊断用）。
const char *hein_gl_backend_name(HeinGLBackend backend);

// 🔴 把全工程的 glXxx 调用重定向到函数表。
//
//   必须放在 epoxy/gl.h 之后（epoxy 自己用 #define glXxx epoxy_glXxx，
//   这里先 #undef 再指向表）。表未初始化时指针为 NULL ⇒ 调用即崩，
//   故 hein_gl_api_init 必须在任何 GL 操作前调用。
#undef glGenTextures
#define glGenTextures (hein_gl_api.GenTextures)
#undef glDeleteTextures
#define glDeleteTextures (hein_gl_api.DeleteTextures)
#undef glBindTexture
#define glBindTexture (hein_gl_api.BindTexture)
#undef glTexImage2D
#define glTexImage2D (hein_gl_api.TexImage2D)
#undef glTexParameteri
#define glTexParameteri (hein_gl_api.TexParameteri)
#undef glGenFramebuffers
#define glGenFramebuffers (hein_gl_api.GenFramebuffers)
#undef glDeleteFramebuffers
#define glDeleteFramebuffers (hein_gl_api.DeleteFramebuffers)
#undef glBindFramebuffer
#define glBindFramebuffer (hein_gl_api.BindFramebuffer)
#undef glFramebufferTexture2D
#define glFramebufferTexture2D (hein_gl_api.FramebufferTexture2D)
#undef glCheckFramebufferStatus
#define glCheckFramebufferStatus (hein_gl_api.CheckFramebufferStatus)
#undef glFenceSync
#define glFenceSync (hein_gl_api.FenceSync)
#undef glDeleteSync
#define glDeleteSync (hein_gl_api.DeleteSync)
#undef glClientWaitSync
#define glClientWaitSync (hein_gl_api.ClientWaitSync)
#undef glWaitSync
#define glWaitSync (hein_gl_api.WaitSync)
#undef glFinish
#define glFinish (hein_gl_api.Finish)
#undef glGetString
#define glGetString (hein_gl_api.GetString)
#undef glReadPixels
#define glReadPixels (hein_gl_api.ReadPixels)

G_END_DECLS

#endif  // HEIN_GL_API_H_
