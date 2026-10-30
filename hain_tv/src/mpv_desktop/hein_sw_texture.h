// HeinPlay 软件渲染纹理（FlPixelBufferTexture）
//
// 🔴🔴🔴 2026-10-27 23:00 新增，用于解开 gamescope 游戏模式的架构死锁。
//
// 【为什么需要它】
//   本机 gamescope 3.16.31 **未开 `--expose-wayland`**（帮助文本：
//   "support wayland clients using xdg-shell"），其焦点/合成走 XWM，
//   只认 X11 客户端。真机实测 `stats.pipe` 恒为 `focus=steam`，
//   我们的 Wayland 窗口建成了、首帧也画了，但**永远不被合成上屏**。
//   ⇒ GTK 必须留在 X11 后端。
//
//   但 GTK3 的 X11 后端只有 GLX（`nm -D libgtk-3.so.0` 无任何 x11-egl
//   符号），而 Flutter 引擎的 resource_context 恒为 EGL ⇒ 两者在同一
//   X display 上互斥：`eglMakeCurrent` 后 `glXMakeCurrent` 报
//   BadAccess，引擎 `gdk_cairo_draw_from_gl` SIGSEGV。
//   ⇒ X11 下**不能**走「共享 GL 上下文 + FlTextureGL」那条路。
//
// 【本模块的做法】
//   mpv 用 `MPV_RENDER_API_TYPE_SW`（软件渲染）把每一帧渲染成
//   CPU 内存里的 RGBA 像素，再由 Flutter 的 `FlPixelBufferTexture`
//   （`copy_pixels` 回调）直接上传成纹理。
//   全程**不创建、不共享任何 GL 上下文** ⇒ 与 GTK 的 GLX 零冲突
//   ⇒ X11 下安全，且画面能上屏。
//
// 【代价】
//   软件渲染 + 每帧 CPU→GPU 上传，1080p 下开销明显高于 GPU 路径。
//   对 69 掌机（Radeon 880M）播 1080p 视频通常仍可接受；
//   若实测掉帧，后续可改为「GPU 渲染到 FBO → glReadPixels → 上传」
//   或等 gamescope 开启 --expose-wayland 后回到 EGL 共享路径。
#ifndef HEIN_SW_TEXTURE_H_
#define HEIN_SW_TEXTURE_H_

#include <flutter_linux/flutter_linux.h>
#include <glib.h>
#include <stdint.h>

G_BEGIN_DECLS

#define HEIN_TYPE_SW_TEXTURE (hein_sw_texture_get_type())
G_DECLARE_FINAL_TYPE(HeinSwTexture, hein_sw_texture, HEIN, SW_TEXTURE,
                     FlPixelBufferTexture)

// 创建实例（引用计数为 1，注册后由 registrar 持有）。
HeinSwTexture* hein_sw_texture_new(void);

// 写入一帧 RGBA 像素。
// src 的每行跨度由 stride 指定（字节），允许 > width*4（mpv SW 渲染要求
// stride 与指针 64 字节对齐，行尾会有填充字节）。
// 会拷贝到内部缓冲（按紧凑 width*4 存），调用方可立即释放 src。
// 线程安全：由 mpv 渲染线程调用，copy_pixels 在 Flutter raster 线程读。
// 返回 TRUE 表示已更新；若尺寸为 0 或 src 为空返回 FALSE。
gboolean hein_sw_texture_set_frame(HeinSwTexture* self, const uint8_t* src,
                                   uint32_t width, uint32_t height,
                                   size_t stride);

// 通知 Flutter「有新帧可采样」。
void hein_sw_texture_mark_available(HeinSwTexture* self,
                                    FlTextureRegistrar* registrar);

// 当前是否有过有效帧。
gboolean hein_sw_texture_has_frame(HeinSwTexture* self);

G_END_DECLS

#endif  // HEIN_SW_TEXTURE_H_
