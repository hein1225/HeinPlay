// 桌面 mpv 壳 · Linux 侧 GL 外部纹理。
//
// 与 Android 侧同构：mpv（官方 libmpv render API）把画面渲染到一块自建 FBO，
// 该 FBO 的颜色附件是我们的 GL 纹理；这里把它实现成 FlTextureGL，
// Flutter 每次采样时通过 populate() 拿到该纹理名，Dart 侧 Texture(textureId)
// 即可出画。Flutter 的 GL 上下文已由壳维护（与渲染上下文共享）。
//
// 关键点（源自 Android 侧 MpvPlayerView 的教训）：
//   ① 纹理尺寸随视频分辨率变化时**必须重建** FBO（populate 内按需处理）。
//   ② 只在有真实帧后才第一次注册/标记，避免黑屏常驻。
//   ③ 只接受 GL_RGBA8（Flutter 明文要求，见 fl_texture_gl.h 注释）。

#include <epoxy/gl.h>
// 🔴 GL 后端抽象（EGL/GLES2 与 GLX/桌面GL 双后端 + 运行时函数表）。
//    必须在本头之后 include，才能把全工程的 glXxx 调用重定向到函数表。
#include "hein_gl_api.h"
// 经 umbrella 头引入（Flutter Linux 子头禁止直接 include）。
#include <flutter_linux/flutter_linux.h>

// 诊断日志（落盘到 $HOME/文档/app_logs/hein_native.log，与壳共用同一文件）
void hein_gl_texture_log(const char *fmt, ...);

G_BEGIN_DECLS

#define HEIN_TYPE_GL_TEXTURE (hein_gl_texture_get_type())
G_DECLARE_FINAL_TYPE(HeinGLTexture, hein_gl_texture, HEIN, GL_TEXTURE,
                     FlTextureGL)

// 供 C++ 壳调用：按 [width,height]（重）建 FBO + 纹理，返回 FBO 名（0=失败）。
GLuint hein_gl_texture_ensure_fbo(HeinGLTexture *self, int width, int height);

// 当前纹理名（供 populate 之外的地方查询）。
GLuint hein_gl_texture_get_name(HeinGLTexture *self);

int hein_gl_texture_get_width(HeinGLTexture *self);
int hein_gl_texture_get_height(HeinGLTexture *self);

// 标记「有新帧」，壳在 mpv 渲染完成后调用（随后壳再调
// fl_texture_registrar_mark_texture_frame_available）。
void hein_gl_texture_mark_frame(HeinGLTexture *self);

// 记录 Flutter 侧用于采样外部纹理的 GL 上下文（诊断用，判断是否共享）。
//
// ⚠️ 上下文是**后端相关**的：EGL 后端是 EGLContext，GLX 后端是 GLXContext。
//    这里统一按 void* 存，具体类型由 [hein_gl_backend] 决定。
void hein_gl_texture_set_share_context(HeinGLTexture *self,
                                       void *context,
                                       void *display);

// 🔴🔴 首次 populate 时捕获 Flutter 真实 EGL 上下文并回调给壳。
//
//   背景：壳在插件注册时建 EGL 上下文，那一刻 Flutter 的 GL 上下文
//   **尚未 current**（引擎 fl_opengl_manager 只是建好 render/resource/
//   platform 三个 context，要等 raster 线程开始绘制才 makeCurrent）。
//   故插件注册期 eglGetCurrentContext() 恒为 EGL_NO_CONTEXT
//   → 共享永远失败 → populate 交出的纹理名在 Flutter 的 context 里
//   指向不存在的对象 → 采样全黑（有声无画）。
//
//   唯一可靠的捕获点是 populate：引擎在
//   fl_engine_gl_external_texture_frame_callback 里调用它，此时 current
//   的正是 Flutter 的 resource_context（与 render_context 共享）。
//
//   ⚠️ 回调在 Flutter **raster 线程**触发，实现方只能记录参数并投递
//      到主线程，绝不可在回调里做 GL 操作。
typedef void (*HeinGLShareCallback)(void *context, void *display, void *user);

void hein_gl_texture_set_share_callback(HeinGLTexture *self,
                                        HeinGLShareCallback cb, void *user);

// 丢弃纹理/FBO 名字但**不**调用 glDelete*：旧名字属于另一个 GL 上下文，
// 在新上下文里 delete 会误删他人的 GL 对象。仅用于共享上下文重建后重置。
void hein_gl_texture_forget_objects(HeinGLTexture *self);

// 🔴🔴 2026-10-21 「幻灯片 / 直播卡死」修复：GPU 围栏等待。
//
//   壳在渲染完成后用 glFenceSync 插入围栏（CPU 立即返回，不阻塞主线程），
//   populate 在把纹理名交给 Flutter **之前**调用本函数等待该围栏完成，
//   从而保证 Flutter 采样时帧内容已写完（不闪烁），同时壳侧完全不阻塞
//   GTK 主线程（不掉帧、不卡死、音频主循环正常）。
//
//   实现方（壳）需提供：获取当前待等待的围栏并执行 glWaitSync。
//   回调在 Flutter raster 线程触发，此时 Flutter 的 GL 上下文 current，
//   glWaitSync 作用于**该**上下文 —— 正是我们要保护的采样上下文。
typedef void (*HeinGLWaitFenceCallback)(void *user);

void hein_gl_texture_set_wait_fence_callback(HeinGLTexture *self,
                                             HeinGLWaitFenceCallback cb,
                                             void *user);

G_END_DECLS
