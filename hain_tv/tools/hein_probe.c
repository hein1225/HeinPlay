// hein_probe.c —— HeinPlay Linux 显示/GL 后端探针
// 编译：gcc hein_probe.c -o hein_probe $(pkg-config --cflags --libs gtk+-3.0) -lGL -lEGL -lX11
// 用法：./hein_probe [x11|wayland]
#include <gtk/gtk.h>
#include <GL/gl.h>
#include <GL/glx.h>
#include <EGL/egl.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

typedef void(APIENTRY *PFN_GenFramebuffers)(GLsizei, GLuint *);
typedef void(APIENTRY *PFN_BindFramebuffer)(GLenum, GLuint);
typedef void(APIENTRY *PFN_FramebufferTexture2D)(GLenum, GLenum, GLenum, GLuint, GLint);
typedef GLenum(APIENTRY *PFN_CheckFramebufferStatus)(GLenum);
static PFN_GenFramebuffers pGenFramebuffers;
static PFN_BindFramebuffer pBindFramebuffer;
static PFN_FramebufferTexture2D pFramebufferTexture2D;
static PFN_CheckFramebufferStatus pCheckFramebufferStatus;

static void load_fbo_funcs(void) {
  pGenFramebuffers = (PFN_GenFramebuffers)dlsym(RTLD_DEFAULT, "glGenFramebuffers");
  pBindFramebuffer = (PFN_BindFramebuffer)dlsym(RTLD_DEFAULT, "glBindFramebuffer");
  pFramebufferTexture2D = (PFN_FramebufferTexture2D)dlsym(RTLD_DEFAULT, "glFramebufferTexture2D");
  pCheckFramebufferStatus = (PFN_CheckFramebufferStatus)dlsym(RTLD_DEFAULT, "glCheckFramebufferStatus");
  printf("[GL] FBO 函数: gen=%p bind=%p tex2d=%p status=%p\n",
         (void *)pGenFramebuffers, (void *)pBindFramebuffer,
         (void *)pFramebufferTexture2D, (void *)pCheckFramebufferStatus);
}

static void probe_monitor(GdkDisplay *dpy) {
  int n = gdk_display_get_n_monitors(dpy);
  printf("[MONITOR] 个数=%d\n", n);
  for (int i = 0; i < n; i++) {
    GdkMonitor *m = gdk_display_get_monitor(dpy, i);
    if (!m) continue;
    GdkRectangle geo;
    gdk_monitor_get_geometry(m, &geo);
    printf("[MONITOR] #%d 名称=%s 几何=%dx%d+%d+%d scale=%d refresh=%.1f\n", i,
           gdk_monitor_get_model(m), geo.width, geo.height, geo.x, geo.y,
           gdk_monitor_get_scale_factor(m), gdk_monitor_get_refresh_rate(m) / 1000.0);
    gdk_monitor_get_workarea(m, &geo);
    printf("[MONITOR] #%d 工作区=%dx%d+%d+%d\n", i, geo.width, geo.height, geo.x, geo.y);
  }
}

// 在当前 context 里建 FBO+纹理并写入纯绿
static void write_fbo_texture(GLuint *out_tex) {
  GLuint tex = 0, fbo = 0;
  glGenTextures(1, &tex);
  glBindTexture(GL_TEXTURE_2D, tex);
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, 16, 16, 0, GL_RGBA, GL_UNSIGNED_BYTE, NULL);
  pGenFramebuffers(1, &fbo);
  pBindFramebuffer(GL_FRAMEBUFFER, fbo);
  pFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, tex, 0);
  glViewport(0, 0, 16, 16);
  glClearColor(0.0f, 1.0f, 0.0f, 1.0f);
  glClear(GL_COLOR_BUFFER_BIT);
  printf("   -> 已在当前上下文写入 FBO 纹理 id=%u status=0x%x\n", tex,
         pCheckFramebufferStatus(GL_FRAMEBUFFER));
  *out_tex = tex;
}

static void read_back(GLuint tex, const char *tag) {
  unsigned char px[4] = {0, 0, 0, 0};
  glBindTexture(GL_TEXTURE_2D, tex);
  glGetTexImage(GL_TEXTURE_2D, 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
  printf("   >> %s 采样共享纹理 RGBA=(%d,%d,%d,%d) => %s\n", tag, px[0], px[1],
         px[2], px[3],
         (px[1] > 200 && px[0] < 50) ? "共享成功 [OK]" : "共享失败 [FAIL]");
}

static void test_egl_share(EGLDisplay ed, EGLContext share) {
  printf("[EGL] ==== EGL 共享实验 ====\n");
  EGLint major = 0, minor = 0;
  if (!eglInitialize(ed, &major, &minor)) { printf("[EGL] eglInitialize 失败 0x%x\n", eglGetError()); return; }
  const EGLint cfg_attr[] = {EGL_SURFACE_TYPE, EGL_PBUFFER_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                             EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8, EGL_NONE};
  EGLConfig cfg; EGLint n = 0;
  if (!eglChooseConfig(ed, cfg_attr, &cfg, 1, &n) || n < 1) { printf("[EGL] eglChooseConfig 失败 0x%x\n", eglGetError()); return; }
  const EGLint pb[] = {EGL_WIDTH, 64, EGL_HEIGHT, 64, EGL_NONE};
  EGLSurface surf = eglCreatePbufferSurface(ed, cfg, pb);
  if (surf == EGL_NO_SURFACE) { printf("[EGL] eglCreatePbufferSurface 失败 0x%x\n", eglGetError()); return; }
  eglBindAPI(EGL_OPENGL_ES_API);
  const EGLint ctx_attr[] = {EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE};
  EGLContext c2 = eglCreateContext(ed, cfg, share, ctx_attr);
  if (c2 == EGL_NO_CONTEXT) { printf("[EGL] eglCreateContext(share) 失败 0x%x\n", eglGetError()); return; }
  if (!eglMakeCurrent(ed, surf, surf, c2)) { printf("[EGL] eglMakeCurrent(共享) 失败 0x%x\n", eglGetError()); return; }
  printf("[EGL] 共享上下文已建 GL=%s\n", (const char *)glGetString(GL_VERSION));
  GLuint tex = 0;
  write_fbo_texture(&tex);
  if (!eglMakeCurrent(ed, surf, surf, share)) { printf("[EGL] 切回原上下文失败 0x%x\n", eglGetError()); return; }
  read_back(tex, "原上下文");
  eglMakeCurrent(ed, surf, surf, c2);
  eglMakeCurrent(ed, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
  eglDestroyContext(ed, c2);
}

static void test_glx_share(void) {
  printf("[GLX] ==== GLX 共享实验 ====\n");
  Display *dpy = glXGetCurrentDisplay();
  GLXContext share = glXGetCurrentContext();
  if (!dpy || !share) { printf("[GLX] 当前没有 GLX 上下文，无法测试\n"); return; }
  int major = 0, minor = 0;
  glXQueryVersion(dpy, &major, &minor);
  printf("[GLX] GLX 版本=%d.%d\n", major, minor);

  int smaj = 0, smin = 0, sflags = 0, sprof = 0;
  glXQueryContext(dpy, share, GLX_CONTEXT_MAJOR_VERSION_ARB, &smaj);
  glXQueryContext(dpy, share, GLX_CONTEXT_MINOR_VERSION_ARB, &smin);
  glXQueryContext(dpy, share, GLX_CONTEXT_FLAGS_ARB, &sflags);
  glXQueryContext(dpy, share, GLX_CONTEXT_PROFILE_MASK_ARB, &sprof);
  printf("[GLX] share context 版本=%d.%d flags=0x%x profile=0x%x\n", smaj, smin, sflags, sprof);

  int fb_attribs[] = {GLX_X_RENDERABLE, True, GLX_DRAWABLE_TYPE, GLX_WINDOW_BIT,
                      GLX_RENDER_TYPE, GLX_RGBA_BIT, GLX_RED_SIZE, 8,
                      GLX_GREEN_SIZE, 8, GLX_BLUE_SIZE, 8, GLX_ALPHA_SIZE, 8,
                      GLX_DOUBLEBUFFER, True, None};
  int count = 0;
  GLXFBConfig *cfgs = glXChooseFBConfig(dpy, DefaultScreen(dpy), fb_attribs, &count);
  if (!cfgs || count < 1) { printf("[GLX] glXChooseFBConfig 失败 count=%d\n", count); return; }
  GLXFBConfig fbc = cfgs[0];

  // 路线①：GLX 1.0 传统 glXCreateContext —— share 参数直接就是已有 context
  XVisualInfo *vi = glXGetVisualFromFBConfig(dpy, fbc);
  GLXContext c2 = NULL;
  if (vi) {
    c2 = glXCreateContext(dpy, vi, share, True);
    printf("[GLX] glXCreateContext(传统,share=原上下文) -> %p\n", (void *)c2);
  } else {
    printf("[GLX] glXGetVisualFromFBConfig 失败\n");
  }
  if (!c2) {
    typedef GLXContext(*PFNCCA)(Display *, GLXFBConfig, Bool, const int *);
    PFNCCA cca = (PFNCCA)glXGetProcAddressARB((const GLubyte *)"glXCreateContextAttribsARB");
    if (cca) {
      int ctx_attribs[] = {GLX_CONTEXT_MAJOR_VERSION_ARB, smaj,
                           GLX_CONTEXT_MINOR_VERSION_ARB, smin,
                           GLX_CONTEXT_PROFILE_MASK_ARB, sprof, None};
      c2 = cca(dpy, fbc, True, ctx_attribs);
      printf("[GLX] glXCreateContextAttribsARB(版本同 share) -> %p\n", (void *)c2);
    }
  }
  if (!c2) { printf("[GLX] 两种建上下文方式都失败\n"); XFree(cfgs); return; }

  int pb_attribs[] = {GLX_PBUFFER_WIDTH, 64, GLX_PBUFFER_HEIGHT, 64,
                      GLX_LARGEST_PBUFFER, False, GLX_PRESERVED_CONTENTS, True, None};
  GLXPbuffer pbuf = glXCreatePbuffer(dpy, fbc, pb_attribs);
  if (!pbuf) { printf("[GLX] glXCreatePbuffer 失败\n"); XFree(cfgs); return; }
  glXMakeCurrent(dpy, (GLXDrawable)pbuf, c2);
  printf("[GLX] 共享上下文已 current，GL=%s renderer=%s\n",
         (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_RENDERER));
  GLuint tex = 0;
  write_fbo_texture(&tex);

  glXMakeCurrent(dpy, (GLXDrawable)0, share);
  read_back(tex, "原上下文");
  glXMakeCurrent(dpy, (GLXDrawable)0, NULL);
  XFree(cfgs);
}

static gboolean on_realize(GtkWidget *w, gpointer data) {
  (void)data;
  GtkGLArea *area = GTK_GL_AREA(w);
  GdkGLContext *ctx = gtk_gl_area_get_context(area);
  gdk_gl_context_make_current(ctx);
  if (gdk_gl_context_get_current() != ctx) {
    printf("[GL] make_current 失败（current != ctx）\n");
    g_timeout_add(300, (GSourceFunc)gtk_main_quit, NULL);
    return G_SOURCE_REMOVE;
  }
  printf("[GL] ==== GL 上下文 ====\n");
  GLXContext gx = glXGetCurrentContext();
  EGLContext ec = eglGetCurrentContext();
  printf("[GL] glXGetCurrentContext=%p  eglGetCurrentContext=%p\n", (void *)gx, (void *)ec);
  if (gx) {
    printf("[GL] => 当前是 **GLX** 上下文，GL=%s renderer=%s\n",
           (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_RENDERER));
    test_glx_share();
  } else if (ec) {
    EGLDisplay ed = eglGetCurrentDisplay();
    printf("[GL] => 当前是 **EGL** 上下文，GL=%s renderer=%s\n",
           (const char *)glGetString(GL_VERSION), (const char *)glGetString(GL_RENDERER));
    test_egl_share(ed, ec);
  } else {
    printf("[GL] => 既无 GLX 也无 EGL 上下文\n");
  }
  printf("[GL] ==== 探针结束 ====\n");
  g_timeout_add(400, (GSourceFunc)gtk_main_quit, NULL);
  return G_SOURCE_REMOVE;
}

int main(int argc, char **argv) {
  const char *backend = (argc > 1) ? argv[1] : "auto";
  if (strcmp(backend, "x11") == 0) g_setenv("GDK_BACKEND", "x11", TRUE);
  else if (strcmp(backend, "wayland") == 0) g_setenv("GDK_BACKEND", "wayland", TRUE);
  gtk_init(&argc, &argv);
  load_fbo_funcs();
  GdkDisplay *dpy = gdk_display_get_default();
  const char *cls = G_OBJECT_TYPE_NAME(dpy);
  printf("[GDK] display=%s 类=%s 类型=%s\n", gdk_display_get_name(dpy), cls,
         strstr(cls, "Wayland") ? "WAYLAND" : (strstr(cls, "X11") ? "X11" : "其它"));
  probe_monitor(dpy);
  GtkWidget *win = gtk_window_new(GTK_WINDOW_TOPLEVEL);
  gtk_window_set_default_size(GTK_WINDOW(win), 800, 600);
  GtkWidget *area = gtk_gl_area_new();
  gtk_container_add(GTK_CONTAINER(win), area);
  g_signal_connect(area, "realize", G_CALLBACK(on_realize), NULL);
  gtk_widget_show_all(win);
  gtk_main();
  return 0;
}
