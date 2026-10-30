// 桌面 mpv 壳 · Windows 侧外部纹理（D3D11，零拷贝路线）。
//
// 🔴🔴 2026-10-21 架构重定：**mpv 直接渲染到 D3D11 纹理**，不再经 GL。
//
//    步骤0 实测结论（wine + libmpv-2.dll 探针）：
//      mpv_render_context_create(MPV_RENDER_API_TYPE_D3D11) 返回 **0（成功）**
//      （WARP 与硬件驱动均成功）。头文件 render.h 也带
//      MPV_RENDER_PARAM_D3D11_INIT_PARAMS / MPV_RENDER_PARAM_D3D11_FBO。
//
//    故本版彻底删掉「WGL + GL FBO + glReadPixels + CPU 翻转 + R/B 交换 +
//    UpdateSubresource」整条链路（那是每帧 8MB 的 GPU→CPU→GPU 往返，
//    1920x1080@60fps ≈ 500MB/s PCIe，必然幻灯片）。
//
//    新链路：
//      mpv(d3d11 render API) → 我们的 ID3D11Texture2D → Flutter 引擎
//      （经 EGL_D3D_TEXTURE_ANGLE / 共享句柄，引擎自己转成 GL 纹理采样）
//
//    与 Linux 侧职责对应关系：
//      Linux   : hein_gl_texture.c（GL 纹理名 + FlTextureGL + populate）
//      Windows : 本文件（ID3D11Texture2D + FlutterDesktopGpuSurfaceTexture）
//
// 关键点：
//   ① 纹理必须与 Flutter 引擎**同一个 D3D11 device**，否则引擎无法打开
//      （引擎内部经 ANGLE 的 EGL_D3D_TEXTURE_ANGLE 绑定我们的纹理）。
//      实测正确做法：不自己建 device，而是复用引擎的。引擎的 device 经
//      FlutterDesktopEngineRef 的 engine->GetD3D11Device() 取（内部 API），
//      本文件改用**共享句柄 + IDXGIResource::OpenSharedHandle** 兜底：
//      我们先建纹理（MISC_SHARED），把 handle 交给 Flutter；Flutter 侧
//      引擎用自己的 device OpenSharedHandle 得到等价纹理。
//   ② 尺寸变化必须重建（Flutter 每帧都会问描述符）。
//   ③ 只在有真实帧后才 MarkTextureFrameAvailable，避免黑屏常驻。

#include <windows.h>

#include <d3d11.h>
#include <dxgi.h>
#include <wrl.h>
// 🔴 2026-10-22：发行版 SDK 的扁平 C 头，见 hein_mpv_core.c 同处说明。
#include "flutter_windows.h"
#include "flutter_texture_registrar.h"

#include <algorithm>

#include "hein_win_texture.h"

using Microsoft::WRL::ComPtr;

// hein_log 定义在 hein_mpv_core.c（由插件文件 #include 进来）。
#ifdef __cplusplus
extern "C"
#endif
void hein_log(const char *fmt, ...);

// MinGW 的 dxgi.h 缺这两个宏（Windows SDK 有），值取自 DXGI 规范：
#ifndef DXGI_SHARED_RESOURCE_READ
#define DXGI_SHARED_RESOURCE_READ (0x80000000L | 0x00000001)
#endif
#ifndef DXGI_SHARED_RESOURCE_WRITE
#define DXGI_SHARED_RESOURCE_WRITE (0x80000000L | 0x00000002)
#endif

// ---- 内部状态 ----
struct HeinWinTexture {
  // Flutter 侧
  FlutterDesktopTextureRegistrarRef registrar;
  int64_t texture_id;
  bool destroyed;

  // mpv 渲染目标（D3D11）
  ComPtr<ID3D11Device> d3d_device;
  ComPtr<ID3D11DeviceContext> d3d_context;
  // 🔴🔴 2026-10-22 双缓冲（修 d3d11.dll 崩溃）：
  //   d3d_tex      = **后台**纹理，mpv 的 render target（不共享给引擎）。
  //   front_tex    = **前台**纹理，经共享句柄交给 Flutter 引擎采样。
  //   渲染线程写完后台纹理后 CopyResource 到前台，引擎只读前台。
  //   这样「mpv 写」与「引擎读」永远不落在同一块资源上。
  ComPtr<ID3D11Texture2D> d3d_tex;
  ComPtr<ID3D11Texture2D> front_tex;
  HANDLE shared_handle;  // DXGI 共享句柄（指向前台纹理，交给 Flutter 引擎打开）

  // 诊断用：CPU 可读的 STAGING 纹理（回读前台内容，判断是否真出画）。
  ComPtr<ID3D11Texture2D> probe_tex;

  int width;
  int height;
  bool has_frame;
  // populate 回调返回的描述符（须在 handle 有效期内常驻）。
  FlutterDesktopGpuSurfaceDescriptor desc;
  // 🔴 引擎已打开的次数。引擎每取一次 descriptor 就 +1 并在 release_callback
  //    里 -1。size 变化重建纹理时若此值 >0，说明引擎手里还捏着旧 handle 的
  //    引用，必须先等它放完，否则 CloseHandle(旧) 会让引擎拿到野句柄。
  LONG engine_open_refs;
};

// 引擎打开完 descriptor 后的归还回调（release_callback）。
// 契约见 flutter_texture_registrar.h 对 FlutterDesktopGpuSurfaceDescriptor
// 的注释：「handle needs to stay valid until it has been opened by Flutter.
// Consider incrementing the resource's reference count in the callback and
// registering a release_callback for decrementing」。
static void hein_win_surface_released(void *release_context) {
  auto *self = static_cast<HeinWinTexture *>(release_context);
  if (self == nullptr) return;
  LONG left = InterlockedDecrement(&self->engine_open_refs);
  if (left < 0) {
    hein_log("release_callback 次数多于 populate（refs=%ld），已夹到 0", left);
    InterlockedExchange(&self->engine_open_refs, 0);
  }
}

// Flutter 引擎回调：询问「这块纹理现在长什么样」。
//
// 🔴 契约（flutter_texture_registrar.h）：
//    · 返回 const FlutterDesktopGpuSurfaceDescriptor*，**不是** bool；
//    · handle 为 kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle 时是 HANDLE；
//    · handle 必须保持有效到 Flutter 打开它 → 这里对共享句柄做引用计数：
//      populate 时 InterlockedIncrement + 填 release_callback；
//      引擎打开后调 release_callback 再减回来。这样即使引擎异步打开、
//      而我们在另一线程重建纹理，也不会 CloseHandle 掉它正在用的句柄。
//    · 返回 nullptr 表示「暂无有效帧」，引擎会跳过这块纹理（不崩）。
static const FlutterDesktopGpuSurfaceDescriptor *hein_win_populate(
    size_t width, size_t height, void *user_data) {
  (void)width;
  (void)height;
  auto *self = static_cast<HeinWinTexture *>(user_data);
  if (self == nullptr || self->destroyed) return nullptr;
  if (self->d3d_tex == nullptr || self->shared_handle == nullptr) {
    return nullptr;
  }
  // 🔴🔴🔴 2026-10-22 Windows 黑屏根因之一：**这里绝对不能重建纹理**。
  //
  //   原实现在此判断「引擎要的尺寸 != 当前尺寸」就调 hein_win_ensure_size，
  //   造成两个致命问题：
  //
  //   ① 尺寸乒乓死循环（实测 56 秒 1251 次重建）：
  //      pump（渲染线程）按视频尺寸建 1920x1080；
  //      本回调（引擎线程）按控件尺寸要 1264x681 → 重建；
  //      下一帧 pump 又按 1920x1080 重建 → 再被本回调改回 1264x681 ……
  //      两个尺寸每 10~20ms 交替一次。引擎手里的共享句柄每帧都被换掉，
  //      MarkTextureFrameAvailable 刚通知的纹理立刻被 Reset →
  //      引擎采样的永远是空纹理 → **黑屏，且不报任何错**。
  //
  //   ② 跨线程使用 D3D11 immediate context（更危险）：
  //      本回调跑在 Flutter 引擎线程，而 mpv_render_context_render 跑在
  //      渲染线程。ensure_size 里的 CreateTexture2D / GetSharedHandle
  //      会动 immediate context，违反 render_d3d11.h 的
  //      「其它线程不得在 mpv_render_* 运行期间使用 immediate context」。
  //
  //   正确职责划分：
  //     · 纹理尺寸**只由 pump（渲染线程）决定**，来源是 Dart 上报的
  //       view_w/view_h（物理像素），mpv 在该尺寸内自行 letterbox；
  //     · 本回调**只读**：把当前纹理描述符交给引擎，不创建、不销毁、不重建。
  //   引擎要的 width/height 只是「它打算把纹理画多大」的提示，
  //   与纹理实际尺寸不一致时 Flutter 自己会缩放，不需要我们迁就。
  InterlockedIncrement(&self->engine_open_refs);
  self->desc.struct_size = sizeof(FlutterDesktopGpuSurfaceDescriptor);
  self->desc.handle = self->shared_handle;
  self->desc.width = (size_t)self->width;
  self->desc.height = (size_t)self->height;
  self->desc.visible_width = (size_t)self->width;
  self->desc.visible_height = (size_t)self->height;
  self->desc.format = kFlutterDesktopPixelFormatBGRA8888;
  self->desc.release_callback = hein_win_surface_released;
  self->desc.release_context = self;
  return &self->desc;
}

// ---- 对外接口（见 hein_win_texture.h）----

HeinWinTexture *hein_win_texture_create(
    FlutterDesktopTextureRegistrarRef registrar) {
  auto *t = new HeinWinTexture();
  t->registrar = registrar;
  t->texture_id = -1;
  t->destroyed = false;
  t->shared_handle = nullptr;
  t->width = 0;
  t->height = 0;
  t->has_frame = false;
  t->engine_open_refs = 0;

  // 自建 D3D11 device（mpv 用它做 render context；纹理经共享句柄给引擎）。
  // ⚠️ 必须带 D3D11_CREATE_DEVICE_BGRA_SUPPORT：共享纹理在引擎侧要按
  //    BGRA 打开，不带该 flag 创的设备 OpenSharedHandle 会失败。
  HRESULT hr = D3D11CreateDevice(
      nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
      D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
      &t->d3d_device, nullptr, &t->d3d_context);
  if (FAILED(hr)) {
    hein_log("D3D11CreateDevice 失败 hr=0x%lx，尝试 WARP", (unsigned long)hr);
    hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                           D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                           D3D11_SDK_VERSION, &t->d3d_device, nullptr,
                           &t->d3d_context);
    if (FAILED(hr)) {
      hein_log("D3D11CreateDevice(WARP) 也失败 hr=0x%lx", (unsigned long)hr);
      delete t;
      return nullptr;
    }
  }

  memset(&t->desc, 0, sizeof(t->desc));

  // 🔴 走 DxgiSharedHandle 而非 D3d11Texture2D：
  //    后者要求引擎与我们**同一个** device（引擎的 device 拿不到），
  //    而共享句柄路径是官方为跨 device 设计的：引擎用自己的 device
  //    OpenSharedHandle 得到等价纹理，再经 ANGLE 绑成 GL 纹理采样。
  FlutterDesktopGpuSurfaceTextureConfig cfg = {};
  cfg.struct_size = sizeof(cfg);
  cfg.type = kFlutterDesktopGpuSurfaceTypeDxgiSharedHandle;
  cfg.callback = hein_win_populate;
  cfg.user_data = t;

  FlutterDesktopTextureInfo info = {};
  info.type = kFlutterDesktopGpuSurfaceTexture;
  info.gpu_surface_config = cfg;

  t->texture_id =
      FlutterDesktopTextureRegistrarRegisterExternalTexture(registrar, &info);
  hein_log("Windows 外部纹理已注册 texture_id=%lld device=%p",
           (long long)t->texture_id, (void *)t->d3d_device.Get());
  return t;
}

bool hein_win_ensure_size(HeinWinTexture *t, int width, int height) {
  if (t->d3d_tex != nullptr && t->width == width && t->height == height) {
    return true;
  }
  if (width <= 0 || height <= 0) return false;

  D3D11_TEXTURE2D_DESC desc = {};
  desc.Width = width;
  desc.Height = height;
  desc.MipLevels = 1;
  desc.ArraySize = 1;
  desc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
  desc.SampleDesc.Count = 1;
  desc.SampleDesc.Quality = 0;
  desc.Usage = D3D11_USAGE_DEFAULT;
  // mpv 要渲染进来（RENDER_TARGET），引擎要采样（SHADER_RESOURCE）。
  desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  desc.CPUAccessFlags = 0;
  // 跨 device 交给引擎：必须 SHARED。
  desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED;

  // 先释放旧的（含旧共享句柄），否则 GetSharedHandle 拿到的是旧纹理的。
  // ⚠️ 但若引擎还开着旧 handle（engine_open_refs>0），关掉它会让引擎拿到
  //    野句柄 → 表现为「偶发全屏花屏/一帧撕裂」，极难复现定位。
  //    此处改为：若引擎仍持有引用，则**推迟销毁**——保留旧纹理直到
  //    release_callback 把它减到 0。实现办法是延迟到 release 回调里收尾，
  //    这里只记录「待销毁」并继续用旧纹理（旧纹理仍在 mpv 的渲染目标里，
  //    不影响正确性，只是这一轮尺寸没更新）。
  if (t->shared_handle != nullptr) {
    if (InterlockedOr(&t->engine_open_refs, 0) > 0) {
      static int s_defer = 0;
      if (++s_defer % 60 == 1) {
        hein_log("引擎仍持有旧共享句柄（refs=%ld），本次尺寸重建推迟（第 %d 次）",
                 InterlockedOr(&t->engine_open_refs, 0), s_defer);
      }
      return false;
    }
    CloseHandle(t->shared_handle);
    t->shared_handle = nullptr;
  }
  t->d3d_tex.Reset();
  t->front_tex.Reset();
  t->probe_tex.Reset();  // 尺寸变了，旧 STAGING 纹理作废（下次探针重建）
  HRESULT hr = t->d3d_device->CreateTexture2D(&desc, nullptr, &t->d3d_tex);
  if (FAILED(hr)) {
    hein_log("CreateTexture2D(后台) %dx%d 失败 hr=0x%lx", width, height,
             (unsigned long)hr);
    return false;
  }

  // ---- 前台纹理：交给引擎采样，**共享**。----
  // 与后台同格式/同尺寸，故可直接 CopyResource。
  D3D11_TEXTURE2D_DESC fdesc = desc;
  // 🔴🔴🔴 2026-10-22 Windows「有声音、无画面」根因：
  //
  //   Flutter Windows 引擎拿到共享句柄后，是用 ANGLE 的
  //   `EGL_D3D_TEXTURE_ANGLE`（eglCreatePbufferFromClientBuffer）把这块
  //   D3D11 纹理包成 EGLSurface 再采样的。而 ANGLE 对该路径有硬性要求：
  //   **纹理必须带 D3D11_BIND_RENDER_TARGET**（规范原文：
  //   "The D3D11 texture must have been created with the
  //    D3D11_BIND_RENDER_TARGET bind flag"）。
  //
  //   原实现只给了 D3D11_BIND_SHADER_RESOURCE（想着「引擎只采样」），
  //   结果 eglCreatePbufferFromClientBuffer 失败 → 引擎拿不到 surface
  //   → 纹理永远显示为黑 → **黑屏，且我们的日志里一点错都没有**
  //   （失败发生在引擎内部，不经我们的代码）。
  //
  //   这也是「参数全对、纹理只建一次、就是没画面」的完美解释。
  //   两个 bind flag 同时给：RENDER_TARGET 满足 ANGLE，SHADER_RESOURCE
  //   满足采样。
  fdesc.BindFlags =
      D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
  fdesc.MiscFlags = D3D11_RESOURCE_MISC_SHARED; // 跨 device 交给引擎
  hr = t->d3d_device->CreateTexture2D(&fdesc, nullptr, &t->front_tex);
  if (FAILED(hr)) {
    hein_log("CreateTexture2D(前台) %dx%d 失败 hr=0x%lx", width, height,
             (unsigned long)hr);
    t->d3d_tex.Reset();
    return false;
  }

  ComPtr<IDXGIResource> dxgi_res;
  hr = t->front_tex.As(&dxgi_res);
  if (FAILED(hr)) {
    hein_log("QueryInterface(IDXGIResource) 失败 0x%lx", (unsigned long)hr);
    t->d3d_tex.Reset();
    t->front_tex.Reset();
    return false;
  }
  HANDLE shared = nullptr;
  hr = dxgi_res->GetSharedHandle(&shared);
  if (FAILED(hr) || shared == nullptr) {
    hein_log("GetSharedHandle 失败 0x%lx handle=%p", (unsigned long)hr,
             (void *)shared);
    t->d3d_tex.Reset();
    t->front_tex.Reset();
    return false;
  }
  t->shared_handle = shared;

  t->width = width;
  t->height = height;
  hein_log("D3D11 纹理已重建 %dx%d shared_handle=%p", width, height,
           (void *)shared);
  return true;
}

ID3D11Texture2D *hein_win_texture_d3d(HeinWinTexture *t) {
  return t == nullptr ? nullptr : t->d3d_tex.Get();
}

// 🔴 2026-10-22：把后台纹理（mpv 刚渲染完）拷到前台纹理（引擎采样）。
// 必须在渲染线程、紧接 mpv_render_context_render() 之后调用。
void hein_win_texture_present(HeinWinTexture *t) {
  if (t == nullptr || t->destroyed) return;
  if (t->d3d_context == nullptr || t->d3d_tex == nullptr ||
      t->front_tex == nullptr) {
    return;
  }
  // CopyResource 在 immediate context 上入队，GPU 内完成，无 CPU 往返。
  t->d3d_context->CopyResource(t->front_tex.Get(), t->d3d_tex.Get());
  // 🔴🔴🔴 2026-10-22 Windows「有声音、无画面」根因（对应 Linux 的 fence 坑）：
  //
  //   CopyResource 只是把命令**入队**，并不保证 GPU 已执行。而引擎在
  //   **另一个 D3D11 device** 上通过共享句柄采样同一块前台纹理，
  //   两个 device 之间没有任何隐式同步（Flutter 不支持 keyed mutex）。
  //   不 Flush 的话，引擎很可能在拷贝真正落盘之前就采样 → 永远读到
  //   纹理初始内容（全 0 = 黑）→ **黑屏且无任何错误**。
  //
  //   这正是 Linux 侧 `frame_fence` + glFlush 解决的同一个问题：
  //   Linux 用 GL 围栏让 Flutter 侧 glClientWaitSync 等写完；
  //   D3D11 没有跨 device 的围栏可用，只能由生产侧显式 Flush，
  //   把命令推给 GPU（同步到「已提交」而非「已完成」，实际足够，
  //   因为 DXGI 共享纹理的跨 device 读取有驱动级一致性保证）。
  t->d3d_context->Flush();
}

// 🔴 2026-10-22 诊断：把前台纹理（引擎采样的那块）回读一小块像素，
// 判断 mpv 到底有没有画进去。
//
// 为什么需要：黑屏时日志里「参数全对 + 纹理只建一次」既可能是
// 「mpv 没画」，也可能是「引擎没采」，二者修法完全不同。这个探针
// 直接读 GPU 内容，把二者区分开。
//
// 做法：把前台纹理 CopyResource 到一块 STAGING 纹理（CPU 可读），
// Map 后取若干采样点，统计非零像素比例。STAGING 纹理缓存复用，
// 只在诊断窗口内创建一次。
bool hein_win_texture_probe(HeinWinTexture *t, int *nonzero_out,
                            int *total_out, unsigned *first_pixel_out) {
  if (t == nullptr || t->destroyed) return false;
  if (t->d3d_device == nullptr || t->d3d_context == nullptr ||
      t->front_tex == nullptr || t->width <= 0 || t->height <= 0) {
    return false;
  }
  if (t->probe_tex == nullptr) {
    D3D11_TEXTURE2D_DESC sdesc = {};
    sdesc.Width = (UINT)t->width;
    sdesc.Height = (UINT)t->height;
    sdesc.MipLevels = 1;
    sdesc.ArraySize = 1;
    sdesc.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
    sdesc.SampleDesc.Count = 1;
    sdesc.Usage = D3D11_USAGE_STAGING;
    sdesc.BindFlags = 0;
    sdesc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    if (FAILED(t->d3d_device->CreateTexture2D(&sdesc, nullptr,
                                              &t->probe_tex))) {
      return false;
    }
  }
  t->d3d_context->CopyResource(t->probe_tex.Get(), t->front_tex.Get());
  D3D11_MAPPED_SUBRESOURCE map = {};
  if (FAILED(t->d3d_context->Map(t->probe_tex.Get(), 0, D3D11_MAP_READ, 0,
                                 &map))) {
    return false;
  }
  // 均匀取 8x8 = 64 个采样点，统计非零（任一通道 >8）的比例。
  int total = 0, nonzero = 0;
  unsigned first = 0;
  const int N = 8;
  for (int gy = 0; gy < N; ++gy) {
    for (int gx = 0; gx < N; ++gx) {
      int x = (int)((long long)t->width * (2 * gx + 1) / (2 * N));
      int y = (int)((long long)t->height * (2 * gy + 1) / (2 * N));
      const unsigned char *row =
          (const unsigned char *)map.pData + (size_t)y * map.RowPitch;
      unsigned px = ((const unsigned *)row)[x];
      if (total == 0) first = px;
      ++total;
      unsigned b = px & 0xFF, g = (px >> 8) & 0xFF, r = (px >> 16) & 0xFF;
      if (b > 8 || g > 8 || r > 8) ++nonzero;
    }
  }
  t->d3d_context->Unmap(t->probe_tex.Get(), 0);
  if (nonzero_out) *nonzero_out = nonzero;
  if (total_out) *total_out = total;
  if (first_pixel_out) *first_pixel_out = first;
  return true;
}

ID3D11Device *hein_win_texture_device(HeinWinTexture *t) {
  return t == nullptr ? nullptr : t->d3d_device.Get();
}

bool hein_win_texture_ready(HeinWinTexture *t) {
  return t != nullptr && !t->destroyed && t->d3d_tex != nullptr &&
         t->shared_handle != nullptr;
}

void hein_win_texture_notify_frame(HeinWinTexture *t) {
  if (t == nullptr || t->destroyed) return;
  t->has_frame = true;
  if (t->texture_id >= 0 && t->registrar != nullptr) {
    // 🔴 2026-10-22：**必须检查返回值**。头文件明确
    //   「Returns true on success or false if the specified texture doesn't
    //    exist」。原实现丢弃返回值 —— 若纹理未真正注册成功，
    //   mark 恒返回 false，引擎永远不会重新采样 → 黑屏且零日志。
    bool ok = FlutterDesktopTextureRegistrarMarkExternalTextureFrameAvailable(
        t->registrar, t->texture_id);
    if (!ok) {
      static int s_mark_fail = 0;
      if (++s_mark_fail <= 20) {
        hein_log("mark_frame_available 失败 texture_id=%lld（第 %d 次）",
                 (long long)t->texture_id, s_mark_fail);
      }
    } else {
      static int s_mark_ok = 0;
      if (++s_mark_ok <= 5) {
        hein_log("mark_frame_available 成功 texture_id=%lld（第 %d 次）",
                 (long long)t->texture_id, s_mark_ok);
      }
    }
  }
}

int64_t hein_win_texture_id(HeinWinTexture *t) {
  return t == nullptr ? -1 : t->texture_id;
}

void hein_win_texture_destroy(HeinWinTexture *t) {
  if (t == nullptr) return;
  t->destroyed = true;
  if (t->texture_id >= 0 && t->registrar != nullptr) {
    FlutterDesktopTextureRegistrarUnregisterExternalTexture(t->registrar,
                                                            t->texture_id,
                                                            nullptr, nullptr);
  }
  if (t->shared_handle != nullptr) {
    CloseHandle(t->shared_handle);
    t->shared_handle = nullptr;
  }
  t->d3d_tex.Reset();
  t->front_tex.Reset();
  t->d3d_context.Reset();
  t->d3d_device.Reset();
  delete t;
  hein_log("Windows 外部纹理已销毁");
}

// 诊断用：读「引擎当前持有几个旧共享句柄」。core.c 的日志会用到。
long hein_win_texture_engine_refs(HeinWinTexture *t) {
  return t == nullptr ? 0 : InterlockedOr(&t->engine_open_refs, 0);
}
