// 桌面 mpv 壳 · Windows 侧 D3D11 外部纹理（见 hein_win_texture.cpp 的说明）。
//
// 🔴 2026-10-21：mpv 走 D3D11 render API（步骤0 实测 libmpv-2.dll 支持），
//    纹理由 mpv 直接渲染，本文件只负责「建 D3D11 纹理 + 注册给 Flutter」。
//    原 GL→D3D11 CPU 拷贝链路（hein_win_copy_from_gl）已整体删除。
#pragma once

#include <windows.h>
#include <cstdint>

// 🔴 2026-10-22：全部对外声明必须带 extern "C"。
//   hein_mpv_core.c 在自己的 extern "C" 前向声明块里调用本文件的函数
//   （它不 include 本头 —— 本头含 WRL/C++ 依赖，core.c 是 C 语义），
//   而本文件的实现在 hein_win_texture.cpp 里是普通 C++ 定义（默认带名字修饰）。
//   两侧链接约定不一致 → 链接期报
//     undefined reference to `hein_win_texture_create'(不带修饰名)
//   即「core.c 找的是 C 名字，cpp 提供的是 _Zxxx 修饰名」，永远对不上。
//   修法：声明侧统一 extern "C"；C++ 规则下，若函数先被声明为 extern "C"，
//   其后续定义自动继承 C 链接约定，故 .cpp 里的定义无需再改。
#ifdef __cplusplus
extern "C" {
#endif

struct ID3D11Device;
struct ID3D11DeviceContext;
struct FlutterDesktopTextureRegistrar;

// 不透明句柄：内部持 Flutter 纹理 id + D3D11 纹理 + DXGI 共享句柄。
typedef struct HeinWinTexture HeinWinTexture;

// 创建并注册外部纹理（壳自建 D3D11 device 供 mpv 用；纹理经 DXGI 共享句柄
// 交给 Flutter 引擎——这是官方为跨 device 设计的路径，引擎用自己的 device
// OpenSharedHandle 得到等价纹理）。
HeinWinTexture* hein_win_texture_create(
    FlutterDesktopTextureRegistrar* registrar);

// 按尺寸（重）建 D3D11 纹理。Flutter 每帧都会问描述符，尺寸变化时调用。
bool hein_win_ensure_size(HeinWinTexture* t, int width, int height);

// 取底层 D3D11 纹理（供 mpv 的 MPV_RENDER_PARAM_D3D11_FBO 使用）。
// 未就绪返回 nullptr。
ID3D11Texture2D* hein_win_texture_d3d(HeinWinTexture* t);

// 取底层 D3D11 device（供 mpv 的 MPV_RENDER_PARAM_D3D11_INIT_PARAMS 使用）。
// ⚠️ mpv 会 AddRef 它，调用方仍可安全 Release 自己的引用（官方文档明示）。
ID3D11Device* hein_win_texture_device(HeinWinTexture* t);

// 纹理是否已就绪（有 device + 纹理 + 共享句柄）。
bool hein_win_texture_ready(HeinWinTexture* t);

// 🔴 2026-10-22 双缓冲：把后台纹理（mpv 的 render target）拷到前台纹理
// （引擎采样的那块）。必须在渲染线程、紧接 mpv_render_context_render()
// 之后调用；不调则引擎永远看到上一帧（或首帧）。
void hein_win_texture_present(HeinWinTexture* t);

// 通知 Flutter「有新帧可采样」（对应 Linux 的 mark_texture_frame_available）。
void hein_win_texture_notify_frame(HeinWinTexture* t);

// 🔴 2026-10-22 诊断：回读前台纹理（引擎采样的那块）像素，判断 mpv 是否
// 真的画进去了。黑屏时用来区分「mpv 没画」与「引擎没采」。
// 返回 true 表示回读成功；nonzero/total 为非零像素比例，first_pixel 为
// 首个采样点的 BGRA 原始值。内部 STAGING 纹理会缓存复用。
bool hein_win_texture_probe(HeinWinTexture* t, int* nonzero_out,
                            int* total_out, unsigned* first_pixel_out);

int64_t hein_win_texture_id(HeinWinTexture* t);

void hein_win_texture_destroy(HeinWinTexture* t);

// 诊断用：引擎当前持有几个旧共享句柄（尺寸重建被推迟时为 >0）。
long hein_win_texture_engine_refs(HeinWinTexture* t);

#ifdef __cplusplus
}  // extern "C"
#endif
