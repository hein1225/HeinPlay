// 桌面 mpv 壳 · Linux 侧 GL 后端抽象实现。
#include "hein_gl_api.h"

#include <string.h>

HeinGLApi hein_gl_api;
HeinGLBackend hein_gl_backend = HEIN_GL_BACKEND_NONE;

// EGL 后端：直接用 epoxy（= 改造前的行为，逐字等价）。
static void fill_egl_api(void) {
  hein_gl_api.GenTextures = epoxy_glGenTextures;
  hein_gl_api.DeleteTextures = epoxy_glDeleteTextures;
  hein_gl_api.BindTexture = epoxy_glBindTexture;
  hein_gl_api.TexImage2D = epoxy_glTexImage2D;
  hein_gl_api.TexParameteri = epoxy_glTexParameteri;
  hein_gl_api.GenFramebuffers = epoxy_glGenFramebuffers;
  hein_gl_api.DeleteFramebuffers = epoxy_glDeleteFramebuffers;
  hein_gl_api.BindFramebuffer = epoxy_glBindFramebuffer;
  hein_gl_api.FramebufferTexture2D = epoxy_glFramebufferTexture2D;
  hein_gl_api.CheckFramebufferStatus = epoxy_glCheckFramebufferStatus;
  hein_gl_api.FenceSync = epoxy_glFenceSync;
  hein_gl_api.DeleteSync = epoxy_glDeleteSync;
  hein_gl_api.ClientWaitSync = epoxy_glClientWaitSync;
  hein_gl_api.WaitSync = (void (*)(GLsync, GLbitfield))epoxy_glWaitSync;
  hein_gl_api.Finish = epoxy_glFinish;
  hein_gl_api.GetString = epoxy_glGetString;
  hein_gl_api.ReadPixels = epoxy_glReadPixels;
}

// GLX 后端：用 glXGetProcAddressARB 取**桌面 OpenGL** 实现。
// ⚠️ 不能用 epoxy：libepoxy 的 dispatch 是进程级 EGL 优先，在 X11 会话里
//    epoxy_glXxx 会走 eglGetProcAddress，返回的是 GLES2 实现，在 GLX 上下文
//    中调用不合法。
static void fill_glx_api(void) {
#define HEIN_GLX_SYM(field, name)                                     \
  do {                                                                \
    hein_gl_api.field =                                              \
        (void *)glXGetProcAddressARB((const GLubyte *)(name));        \
    if (hein_gl_api.field == NULL) {                                 \
      g_warning("hein_gl_api: GLX 符号缺失 %s", (name));             \
    }                                                                 \
  } while (0)

  HEIN_GLX_SYM(GenTextures, "glGenTextures");
  HEIN_GLX_SYM(DeleteTextures, "glDeleteTextures");
  HEIN_GLX_SYM(BindTexture, "glBindTexture");
  HEIN_GLX_SYM(TexImage2D, "glTexImage2D");
  HEIN_GLX_SYM(TexParameteri, "glTexParameteri");
  HEIN_GLX_SYM(GenFramebuffers, "glGenFramebuffers");
  HEIN_GLX_SYM(DeleteFramebuffers, "glDeleteFramebuffers");
  HEIN_GLX_SYM(BindFramebuffer, "glBindFramebuffer");
  HEIN_GLX_SYM(FramebufferTexture2D, "glFramebufferTexture2D");
  HEIN_GLX_SYM(CheckFramebufferStatus, "glCheckFramebufferStatus");
  HEIN_GLX_SYM(FenceSync, "glFenceSync");
  HEIN_GLX_SYM(DeleteSync, "glDeleteSync");
  HEIN_GLX_SYM(ClientWaitSync, "glClientWaitSync");
  HEIN_GLX_SYM(WaitSync, "glWaitSync");
  HEIN_GLX_SYM(Finish, "glFinish");
  HEIN_GLX_SYM(GetString, "glGetString");
  HEIN_GLX_SYM(ReadPixels, "glReadPixels");
#undef HEIN_GLX_SYM
}

void hein_gl_api_init(HeinGLBackend backend) {
  memset(&hein_gl_api, 0, sizeof(hein_gl_api));
  hein_gl_backend = backend;
  switch (backend) {
    case HEIN_GL_BACKEND_EGL:
      fill_egl_api();
      break;
    case HEIN_GL_BACKEND_GLX:
      fill_glx_api();
      break;
    default:
      break;
  }
}

const char *hein_gl_backend_name(HeinGLBackend backend) {
  switch (backend) {
    case HEIN_GL_BACKEND_EGL:
      return "EGL(GLES2)";
    case HEIN_GL_BACKEND_GLX:
      return "GLX(桌面GL)";
    default:
      return "未初始化";
  }
}
