// 见 hein_gl_texture.h 的说明。
#include "hein_gl_texture.h"
#include <epoxy/egl.h>
#include <stdarg.h>
#include <stdio.h>
#include <time.h>
#include <glib.h>
// 🔴 2026-10-26：GLX 真符号探测（populate 里要判定 Flutter 到底用
//    EGL 还是桌面 GL）。该头只用 void* 抽象，不泄 <GL/glx.h>，
//    与本文件已 include 的 epoxy 头不冲突。
#include "hein_glx.h"

// 🔴 2026-10-21：populate 诊断落盘。
//
//    此前用 g_print 只到 stdout，而 AppImage 双击启动**没有终端**，
//    这些行全部丢失 —— 导致「幻灯片」问题看不到 Flutter 侧的真实
//    采样频率，只能靠猜。这里直接写与壳相同的日志文件。
//
//    线程安全：populate 在 raster 线程、壳在主线程，用 GMutex 串行化
//    追加写，避免行交错。
static GMutex g_hein_tex_log_mutex;

void hein_gl_texture_log(const char *fmt, ...) {
  static gboolean s_init = FALSE;
  static char s_path[512];
  g_mutex_lock(&g_hein_tex_log_mutex);
  if (!s_init) {
    const char *home = g_get_home_dir();
    if (home != NULL) {
      g_snprintf(s_path, sizeof(s_path), "%s/文档/app_logs", home);
      g_mkdir_with_parents(s_path, 0755);
      g_strlcat(s_path, "/hein_native.log", sizeof(s_path));
    }
    s_init = TRUE;
  }
  if (s_path[0] != '\0') {
    FILE *f = fopen(s_path, "a");
    if (f != NULL) {
      time_t now = time(NULL);
      struct tm tmv;
      localtime_r(&now, &tmv);
      fprintf(f, "[%04d-%02d-%02d %02d:%02d:%02d] [MPV] ",
              tmv.tm_year + 1900, tmv.tm_mon + 1, tmv.tm_mday, tmv.tm_hour,
              tmv.tm_min, tmv.tm_sec);
      va_list ap;
      va_start(ap, fmt);
      vfprintf(f, fmt, ap);
      va_end(ap);
      fputc('\n', f);
      fclose(f);
    }
  }
  g_mutex_unlock(&g_hein_tex_log_mutex);
}

struct _HeinGLTexture {
  FlTextureGL parent_instance;

  GLuint fbo;
  GLuint tex;
  int width;
  int height;
  gboolean has_frame;
  // 🔴 后端相关：EGL 后端是 EGLContext/EGLDisplay，GLX 后端是
  //    GLXContext/Display*，统一按 void* 存（类型由 hein_gl_backend 决定）。
  void *share_context;
  void *share_display;
  // populate 期捕获到的 Flutter 真实上下文（可能等于 share_context）
  void *flutter_context;
  void *flutter_display;
  gboolean flutter_captured;
  HeinGLShareCallback share_callback;
  void *share_callback_user;
  // 🔴 2026-10-21：采样前等待壳插入的 GPU 围栏（避免闪烁且不阻塞主线程）。
  HeinGLWaitFenceCallback wait_fence_callback;
  void *wait_fence_user;
};

G_DEFINE_TYPE(HeinGLTexture, hein_gl_texture, fl_texture_gl_get_type())

static gboolean hein_gl_texture_populate(FlTextureGL *texture,
                                         uint32_t *target,
                                         uint32_t *name,
                                         uint32_t *width,
                                         uint32_t *height,
                                         GError **error) {
  HeinGLTexture *self = HEIN_GL_TEXTURE(texture);

  // 🔴🔴 首要动作：捕获 Flutter 真实 EGL 上下文。
  //
  //    引擎在 fl_engine_gl_external_texture_frame_callback 里调用
  //    populate 之前已经 eglMakeCurrent(display, NO_SURFACE, NO_SURFACE,
  //    resource_context)，所以**此刻** eglGetCurrentContext() 拿到的
  //    就是 Flutter 的 resource_context —— 这是全流程中唯一可靠的
  //    获取时机（插件注册期它是 EGL_NO_CONTEXT）。
  //
  //    捕获后立即回调给壳，由壳回主线程重建共享上下文与 mpv render
  //    context。回调只记录参数，不做 GL 操作（当前处于 raster 线程）。
  {
    // 🔴🔴🔴 2026-10-26：**双探测**，不再按 GTK3 窗口后端猜。
    //
    //   事实：Flutter Linux 引擎（fl_opengl_manager.cc）恒用 EGL 建
    //   OpenGL ES 2.0 上下文（EGL_CONTEXT_CLIENT_VERSION=2），
    //   **与会话是 Wayland 还是 X11 无关** ⇒ 正常应恒探测到 EGL。
    //
    //   但仍要同时看 GLX：万一将来 Flutter 改用桌面 GL，这里能立刻
    //   看出来（而不是又变成「黑屏查不出原因」）。GLX 用**真符号**
    //   （hein_glx_current_context，走 libGL）探测，不能用 epoxy：
    //   epoxy 的 dispatch 是进程级 EGL 优先，eglGetProcAddress 取不到
    //   真正的 GLX 入口。
    //
    //   优先级：EGL 优先（与既有桌面行为一致）；只有 EGL 为空才用 GLX。
    void *cur = NULL;
    void *cur_d = NULL;
    EGLContext ec = eglGetCurrentContext();
    EGLDisplay ed = eglGetCurrentDisplay();
    void *gx = hein_glx_current_context();
    void *dx = hein_glx_current_display();
    if (ec != EGL_NO_CONTEXT && ed != EGL_NO_DISPLAY) {
      cur = (void *)ec;
      cur_d = (void *)ed;
    } else if (gx != NULL && dx != NULL) {
      cur = gx;
      cur_d = dx;
    }
    if (!self->flutter_captured) {
      // 🔴 取证：无论是否捕获到，都把四种值落盘 —— 一次真机运行即可
      //    判定「Flutter 在本会话到底用的哪个 GL API」。
      hein_gl_texture_log(
          "首次 populate 探测：egl_ctx=%p egl_dpy=%p glx_ctx=%p glx_dpy=%p "
          "⇒ 选中 %s",
          (void *)ec, (void *)ed, gx, dx,
          (cur == NULL) ? "无"
                        : ((ec != EGL_NO_CONTEXT) ? "EGL(GLES2)" : "GLX(桌面GL)"));
    }
    if (cur != NULL) {
      if (!self->flutter_captured) {
        self->flutter_captured = TRUE;
        self->flutter_context = cur;
        self->flutter_display = cur_d;
        g_print("HeinGLTexture: 捕获 Flutter 上下文 %p display=%p"
                "（首次 populate，后端=%s）\n",
                cur, cur_d, hein_gl_backend_name(hein_gl_backend));
        fflush(stdout);
        if (self->share_callback != NULL) {
          self->share_callback(cur, cur_d, self->share_callback_user);
        }
      }
      // 同步更新诊断字段：后续 populate 即可判定「是否已共享」。
      if (self->share_context == NULL) {
        self->share_context = cur;
        self->share_display = cur_d;
      }
    }
  }

  // 🔴🔴 2026-10-21 「点播闪烁 / 幻灯片 / 直播卡死」统一修复。
  //
  //    采样前先等待壳在渲染结束时插入的 GPU 围栏。此时 Flutter 的 GL
  //    上下文已经 current（引擎在调 populate 前做过 makeCurrent），
  //    glWaitSync 作用于**这个**上下文 —— 正是要保护的对象。
  //
  //    与旧方案（壳侧 glFinish）的本质区别：
  //      glFinish   —— 阻塞**壳的 GTK 主线程**直到 GPU 完成 → 主线程饱和
  //                    → Flutter 只剩 6fps（幻灯片）、音频循环停摆（无声）、
  //                      最终挂死。
  //      glWaitSync —— 只在**GPU 命令流**里插一个等待点，CPU 立即返回。
  //                    壳的主线程不受影响（保持 25fps 出帧），
  //                    Flutter 的 GPU 侧仍保证「写完才采样」（不闪烁）。
  if (self->wait_fence_callback != NULL) {
    self->wait_fence_callback(self->wait_fence_user);
  }

  // 🔴🔴🔴 2026-10-26 22:55 **关键修复：首次 populate 绝不能返回失败。**
  //
  //   真机铁证（69，/tmp/fin.log，18:49 那次「推迟 render context」版本）：
  //     `首次 populate` → `WARNING 纹理尚未建立（尚无视频帧）` 返回 FALSE
  //     ⇒ **此后 populate 再也没被调用过**（全日志 populate 仅 1 次），
  //       而 mpv 那边照常渲染了 541 帧、FBO 像素自检亮度最高 113
  //       （说明 FBO 里确实有画面）——但 Flutter 已经放弃这个纹理，
  //       永远不再采样 ⇒ 用户看到的就是**黑屏有声音**。
  //
  //   ⇒ 因此这里必须**当场建一个占位纹理**并返回 TRUE，把 Flutter 的
  //     采样链路保住。此刻 current 的正是 Flutter 的 resource_context，
  //     所以在这里 glGenTextures 得到的名字天然属于 Flutter 的命名空间
  //     （比在壳上下文里建更可靠）。
  //
  //   随后阶段②会在共享上下文 B 里重建真正的纹理并
  //   mark_texture_frame_available 通知 Flutter 重新采样，采样链路不断。
  if (self->tex == 0) {
    GLuint placeholder = 0;
    glGenTextures(1, &placeholder);
    if (placeholder != 0) {
      glBindTexture(GL_TEXTURE_2D, placeholder);
      // 1x1 全黑，避免 Flutter 采样到未初始化显存（花屏/白闪）。
      const unsigned char black[4] = {0, 0, 0, 255};
      glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, 1, 1, 0, GL_RGBA,
                   GL_UNSIGNED_BYTE, black);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
      glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
      glBindTexture(GL_TEXTURE_2D, 0);
      self->tex = placeholder;
      self->width = 1;
      self->height = 1;
      hein_gl_texture_log("首次 populate：纹理未就绪 ⇒ 先交 1x1 占位纹理 "
                          "tex=%u，保住 Flutter 采样链路", placeholder);
      *target = GL_TEXTURE_2D;
      *name = placeholder;
      *width = 1;
      *height = 1;
      return TRUE;
    }
    // 连占位纹理都建不出来（上下文异常）才返回失败。
    g_set_error(error, g_quark_from_static_string("hein"), 1,
                "纹理尚未建立（尚无视频帧）");
    return FALSE;
  }
  // 诊断：确认 populate 真的被调用，且当前上下文与壳的是否同一个。
  // 🔴 2026-10-21：改为走 hein_log 落盘 —— 此前用 g_print 只到 stdout，
  //    而 AppImage 双击启动没有终端，全部丢失，导致「幻灯片」问题
  //    完全看不到 Flutter 侧的真实采样频率。
  {
    void *cur = (hein_gl_backend == HEIN_GL_BACKEND_GLX)
                    ? (void *)glXGetCurrentContext()
                    : (void *)eglGetCurrentContext();
    static int s_pop_log = 0;
    s_pop_log++;
    // 🔴 关键诊断：populate 的**真实频率**。
    //    「幻灯片」的直接判据就是这里的 fps 明显低于视频帧率（25/30）。
    static gint64 s_last_us = 0;
    static int s_since_last = 0;
    gint64 now_us = g_get_monotonic_time();
    s_since_last++;
    if (s_last_us != 0 && now_us - s_last_us >= 1000000) {
      double fps = s_since_last * 1000000.0 / (double)(now_us - s_last_us);
      hein_gl_texture_log("populate 频率 %.1f fps（累计 %d 次）", fps,
                          s_pop_log);
      s_last_us = now_us;
      s_since_last = 0;
    } else if (s_last_us == 0) {
      s_last_us = now_us;
    }
    if (s_pop_log <= 5 || s_pop_log % 60 == 0) {
      hein_gl_texture_log("populate #%d tex=%u %dx%d cur_ctx=%p "
                          "share_ctx=%p share_ok=%s",
                          s_pop_log, self->tex, self->width, self->height,
                          cur, self->share_context,
                          self->share_context != NULL && cur == self->share_context
                              ? "same"
                              : (self->share_context != NULL ? "diff" : "none"));
    }
  }
  // Flutter 的 GL 上下文此时已 current，直接把我们的纹理名交出去。
  *target = GL_TEXTURE_2D;
  *name = self->tex;
  *width = (uint32_t)self->width;
  *height = (uint32_t)self->height;
  return TRUE;
}

static void hein_gl_texture_class_init(HeinGLTextureClass *klass) {
  FL_TEXTURE_GL_CLASS(klass)->populate = hein_gl_texture_populate;
}

static void hein_gl_texture_init(HeinGLTexture *self) {
  self->fbo = 0;
  self->tex = 0;
  self->width = 0;
  self->height = 0;
  self->has_frame = FALSE;
  self->share_context = NULL;
  self->share_display = NULL;
  self->flutter_context = NULL;
  self->flutter_display = NULL;
  self->flutter_captured = FALSE;
  self->share_callback = NULL;
  self->share_callback_user = NULL;
  self->wait_fence_callback = NULL;
  self->wait_fence_user = NULL;
}

void hein_gl_texture_set_share_callback(HeinGLTexture *self,
                                        HeinGLShareCallback cb, void *user) {
  self->share_callback = cb;
  self->share_callback_user = user;
}

void hein_gl_texture_set_wait_fence_callback(HeinGLTexture *self,
                                             HeinGLWaitFenceCallback cb,
                                             void *user) {
  self->wait_fence_callback = cb;
  self->wait_fence_user = user;
}

void hein_gl_texture_forget_objects(HeinGLTexture *self) {
  // 旧名字属于另一个 GL 上下文，不能在新上下文里 glDelete（会误删他人对象）。
  // 这里只把记录清零，让后续 ensure_fbo 重新生成。
  self->fbo = 0;
  self->tex = 0;
  self->width = 0;
  self->height = 0;
  self->has_frame = FALSE;
}

void hein_gl_texture_set_share_context(HeinGLTexture *self,
                                       void *context,
                                       void *display) {
  self->share_context = context;
  self->share_display = display;
}

GLuint hein_gl_texture_ensure_fbo(HeinGLTexture *self, int width, int height) {
  if (self->fbo != 0 && self->width == width && self->height == height) {
    return self->fbo;
  }
  if (width <= 0 || height <= 0) return 0;

  if (self->fbo != 0) {
    glDeleteFramebuffers(1, &self->fbo);
    self->fbo = 0;
  }
  if (self->tex != 0) {
    glDeleteTextures(1, &self->tex);
    self->tex = 0;
  }

  glGenTextures(1, &self->tex);
  glBindTexture(GL_TEXTURE_2D, self->tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_RGBA,
               GL_UNSIGNED_BYTE, NULL);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);

  glGenFramebuffers(1, &self->fbo);
  glBindFramebuffer(GL_FRAMEBUFFER, self->fbo);
  glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                         self->tex, 0);

  // 🔴🔴 2026-10-21 关键 bug 修复：必须在**仍然绑定该 FBO** 时检查完整性。
  //
  //    原实现先 glBindFramebuffer(GL_FRAMEBUFFER, 0) 解绑，再调
  //    glCheckFramebufferStatus —— 此时检查的是**默认 FBO**，恒返回
  //    GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT(0x8219)，于是每个视频尺寸都
  //    被判为「FBO 不完整」，fbo 被删除并返回 0 → 永远出不了画。
  //    真机日志（78）实测正是 0x8219 每帧刷屏。
  GLenum status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  glBindFramebuffer(GL_FRAMEBUFFER, 0);
  glBindTexture(GL_TEXTURE_2D, 0);

  if (status != GL_FRAMEBUFFER_COMPLETE) {
    g_warning("hein_gl_texture_ensure_fbo: FBO 不完整 status=0x%x %dx%d", status,
              width, height);
    glDeleteFramebuffers(1, &self->fbo);
    self->fbo = 0;
    glDeleteTextures(1, &self->tex);
    self->tex = 0;
    return 0;
  }
  self->width = width;
  self->height = height;
  return self->fbo;
}

GLuint hein_gl_texture_get_name(HeinGLTexture *self) { return self->tex; }

int hein_gl_texture_get_width(HeinGLTexture *self) { return self->width; }

int hein_gl_texture_get_height(HeinGLTexture *self) { return self->height; }

void hein_gl_texture_mark_frame(HeinGLTexture *self) {
  self->has_frame = TRUE;
}
