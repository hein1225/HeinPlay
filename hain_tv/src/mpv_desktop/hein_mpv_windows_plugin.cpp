// 桌面 mpv 壳 · Windows 插件入口。
//
// 【职责】
//   ① 注册 MethodChannel `hain_tv/mpv_desktop`，暴露 init/open/play/pause/
//      seek/setSpeed/setVolume/setFit/setViewSize/position/duration/buffered/dispose。
//   ② 注册 EventChannel `hain_tv/mpv_desktop_events`，向上推
//      time-pos / duration / demuxer-cache-time / paused / eof / textureId。
//   ③ 帧驱动：**独立渲染线程** + Win32 事件唤醒（见 hein_mpv_core.c 的
//      hein_render_thread_proc）。本文件不、也不应在主线程驱动渲染。
//   ④ 日志不节流（教训⑥）。
//
// 【与 Linux 的差异】
//   · 纹理：D3D11 外部纹理（见 hein_win_texture.cpp）而非 GL。
//   · mpv render API：**D3D11**（步骤0 实测 libmpv-2.dll 支持，见工作日志）。
//     mpv 直接渲染到我们的 ID3D11Texture2D，经 DXGI 共享句柄交给 Flutter 引擎，
//     全程 GPU 内完成，零 CPU 拷贝。
//   · 事件上行：Linux 用 FlEventChannel + fl_event_channel_send；
//     Windows 的 C++ wrapper 用 StreamHandler/EventSink（见下方）。

#include <windows.h>

#include <d3d11.h>
#include <wrl.h>
// 🔴 2026-10-22：见 hein_mpv_core.c 同处说明 —— 发行版 SDK 的头是扁平的，
//    放在 windows/flutter/ephemeral/ 下；「flutter_windows/xxx.h」那种带子目录
//    的写法是 Flutter 2.x 时代的结构，早已扁平化。
//    「flutter_windows_texture_registrar.h」在发行版里叫
//    「flutter_texture_registrar.h」，且不需要单独 include（flutter_windows.h 已带）。
#include "flutter_windows.h"
#include "flutter_texture_registrar.h"
#include <flutter/plugin_registrar.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/binary_messenger.h>

#include <map>
#include <vector>

#include "hein_mpv_core.c"       // 单文件编译，直接包含实现
#include "hein_win_texture.h"

using Microsoft::WRL::ComPtr;
using flutter::EncodableValue;
// ⚠️ EncodableMap 必须显式 using（漏了会报 not declared in this scope）。
using flutter::EncodableMap;
using flutter::BinaryReply;
using flutter::BinaryMessageHandler;

namespace {

// Flutter C API 侧的回调签名与 C++ wrapper 不同，这里用 C API（更稳）。
FlutterDesktopTextureRegistrarRef g_texture_registrar = nullptr;
HeinWinTexture* g_win_texture = nullptr;
std::shared_ptr<flutter::MethodChannel<EncodableValue>> g_channel;

// ---- 事件上行（无节流）----
//
// 🔴🔴 2026-10-21 事件链路重建（P0-5 修复）。
//
//   原实现有**三处**错误叠在一起，导致 Dart 侧一条事件都收不到：
//   ① g_event_channel 从未 SetStreamHandler → Dart 侧 stream.listen 的
//      "listen" 请求无人应答，EventChannel 一直处于未连接状态；
//   ② 直接调 g_event_channel->Success(...) —— EventChannel 类**没有**
//      Success 方法（那是 MethodResult 的），编译期就过不了；
//   ③ 即使编译过，也没有持有 EventSink，无处可发。
//
//   正解（与 flutter/event_channel.h 的接口对齐）：
//     · 自定义 StreamHandler，OnListen 时把 arguments[0] 这个 EventSink
//       存起来，OnCancel 时清空；
//     · 之后要推事件就 sink->Success(EncodableValue(map))。
//     · Dart 侧的 onListen/onCancel 由 EventChannel 自动用 "listen"/"cancel"
//       方法名发过来，无需我们手动配对。
//
//   Dart 侧解包约定（mpv_desktop_backend.dart）：
//     final name = event['name']; final value = event['value'];
//   故推扁平 map {name, value}。
//   另外 textureId 走 int64（Dart 收到 int），不用 double 以免 2^53 精度风险。
// ---- BinaryMessenger 桥 ----
//
// 🔴 为什么自己写一个：
//    官方确实有 flutter::BinaryMessengerImpl（client_wrapper 的标准桥），
//    但它定义在 **内部** 头 common/client_wrapper/binary_messenger_impl.h，
//    Flutter SDK 没有把它装到插件的 include 路径里，插件 include 不到。
//    而 flutter::DesktopMessenger 这个类**根本不存在**（原实现臆造的，
//    编译期直接 not declared）。
//
//    故按 BinaryMessenger 的纯虚接口自己实现最小面：
//      · Send            —— 本插件只收不发，留空（保留以备将来）。
//      · SetMessageHandler —— 注册 channel 名 -> handler，供 MethodChannel
//                            与 EventChannel 接收 Dart 的调用/listen/cancel。
//    底层走 C API FlutterDesktopMessengerSetCallback（flutter_messenger.h
//    公开导出），这是官方支持的方式。
class HeinBinaryMessenger : public flutter::BinaryMessenger {
 public:
  explicit HeinBinaryMessenger(FlutterDesktopMessengerRef core)
      : core_messenger_(core) {}

  void Send(const std::string& channel, const uint8_t* message,
            size_t message_size, BinaryReply reply) const override {
    (void)channel;
    (void)message;
    (void)message_size;
    (void)reply;
  }

  void SetMessageHandler(const std::string& channel,
                         BinaryMessageHandler handler) override {
    if (handler == nullptr) {
      handlers_.erase(channel);
      FlutterDesktopMessengerSetCallback(core_messenger_, channel.c_str(),
                                         nullptr, nullptr);
      return;
    }
    // handler 必须是可拷贝的（std::function 要求）。用 shared_ptr 包一层，
    // 把裸指针交给 C API；本地 map 保活，防止提前析构。
    auto shared = std::make_shared<BinaryMessageHandler>(std::move(handler));
    handlers_[channel] = shared;
    FlutterDesktopMessengerSetCallback(
        core_messenger_, channel.c_str(),
        [](FlutterDesktopMessengerRef messenger,
           const FlutterDesktopMessage* message, void* user_data) {
          auto* h = static_cast<BinaryMessageHandler*>(user_data);
          // BinaryMessenger 的回调签名是
          //   void(const uint8_t* message, size_t message_size, BinaryReply)
          // 其中 BinaryReply = function<void(const uint8_t*, size_t)>。
          // 我们把 reply 转成「调 FlutterDesktopMessengerSendResponse」，
          // 并把响应数据先存到堆上、由 shared_ptr 保活到回调结束。
          auto response_data = std::make_shared<std::vector<uint8_t>>();
          BinaryReply reply =
              [messenger, message, response_data](const uint8_t* data,
                                                  size_t size) {
                if (message->response_handle == nullptr) return;
                if (data != nullptr && size > 0) {
                  response_data->assign(data, data + size);
                  FlutterDesktopMessengerSendResponse(
                      messenger, message->response_handle,
                      response_data->data(), response_data->size());
                } else {
                  FlutterDesktopMessengerSendResponse(
                      messenger, message->response_handle, nullptr, 0);
                }
              };
          (*h)(message->message, message->message_size, std::move(reply));
        },
        shared.get());
  }

 private:
  FlutterDesktopMessengerRef core_messenger_;
  // 保活：C API 回调只拿裸指针，这里必须持有 shared_ptr。
  std::map<std::string, std::shared_ptr<BinaryMessageHandler>> handlers_;
};

// ============================ 事件上行（P0-5 重建） ============================
//
// 🔴🔴 2026-10-21：原实现整条事件链路是坏的， Dart 侧一条事件都收不到。
//    病因有三层：
//      ① g_event_channel 建了却从未 SetStreamHandler → Dart 的
//         stream.listen 请求无人应答，EventChannel 永远未连接；
//      ② 直接调 g_event_channel->Success(...) —— EventChannel 类**没有**
//         Success 方法（那是 MethodResult 的），编译期就该失败；
//      ③ 从未持有 EventSink，无处可发。
//
//    更麻烦的是：即便按官方接口补上 StreamHandler，Flutter 3.47.5 SDK 的
//    flutter/event_channel.h 自身有缺陷 —— 第 95 行
//        std::cerr << ... << (error->error_details);
//    对 std::unique_ptr<EncodableValue> 无 operator<< 重载，
//    mingw/MSVC 模板实例化时直接编译失败。这是 SDK 的 bug，不是我们的。
//
//    故本文件**绕开** EventChannel 模板，直接用 C API 实现 EventChannel 协议：
//      · Dart 侧 EventChannel(name).listen() 会向 name 通道发一个
//        MethodCall{method:"listen", args:[sink_handle]}；
//      · 我们回 EncodeSuccessEnvelope(nullptr) 应答，此后可推事件；
//      · Dart 侧 cancel() 发 MethodCall{method:"cancel"}，同样应答后停止推送。
//      · 推事件 = codec->EncodeSuccessEnvelope(&EncodableValue(map))
//                再 FlutterDesktopMessengerSend(messenger, name, ...)。
//    这条路径只用公开 C API + MethodCodec 的公开 Encode 方法，不碰有缺陷的模板。
class HeinEventChannel {
 public:
  HeinEventChannel(FlutterDesktopMessengerRef messenger, const char* name,
                   const flutter::MethodCodec<EncodableValue>& codec)
      : messenger_(messenger), name_(name), codec_(&codec) {}

  bool Ok() const { return messenger_ != nullptr && codec_ != nullptr; }
  bool Listening() const { return listening_ > 0; }

  // 处理 Dart 的 listen / cancel。返回是否已应答（非本通道消息返回 false）。
  bool HandleMessage(const uint8_t* message, size_t size,
                     const flutter::BinaryReply& reply) {
    auto call = codec_->DecodeMethodCall(message, size);
    if (!call) return false;
    const std::string& method = call->method_name();
    if (method == "listen") {
      // args[0] 是 Dart 侧的 sink handle，我们不需要它的值（直接 Send 到
      // 通道名即可，Dart 会按通道名路由到对应 sink）。
      // 🔴 2026-10-22：改用计数而非布尔。Dart 侧每个 MpvDesktopBackend
      //    实例都会 receiveBroadcastStream() 一次，各自独立向原生 listen；
      //    而 LivePlayer 的延迟销毁会让「旧实例的 cancel」发生在「新实例的
      //    listen」之后。用单个 bool 时旧实例一 cancel 就把 listening_ 置
      //    false，新实例从此收不到任何事件（表现为回放/换台后进度与状态
      //    全无更新）。计数可保证「还有任一订阅者活着就继续投递」。
      listening_++;
      auto result = codec_->EncodeSuccessEnvelope();
      reply(result->data(), result->size());
      hein_log("EventChannel[%s]: Dart 已 listen", name_.c_str());
      return true;
    }
    if (method == "cancel") {
      if (listening_ > 0) listening_--;
      auto result = codec_->EncodeSuccessEnvelope();
      reply(result->data(), result->size());
      hein_log("EventChannel[%s]: Dart 已 cancel", name_.c_str());
      return true;
    }
    return false;
  }

  // 推一条事件。listening_ 为 false 时静默丢弃（Dart 还没 listen，
  // 此时发送 Dart 侧收不到，且无意义）。
  void Send(const char* name, const EncodableValue& value) {
    if (listening_ <= 0 || !Ok()) return;
    EncodableMap map{{EncodableValue("name"), EncodableValue(name)},
                     {EncodableValue("value"), value}};
    EncodableValue event(map);
    auto encoded = codec_->EncodeSuccessEnvelope(&event);
    if (!encoded) return;
    FlutterDesktopMessengerSend(messenger_, name_.c_str(), encoded->data(),
                                encoded->size());
  }

 private:
  FlutterDesktopMessengerRef messenger_;
  std::string name_;
  const flutter::MethodCodec<EncodableValue>* codec_;
  // 订阅者计数（见 listen/cancel 处注释）：>0 表示至少还有一个 Dart
  // 实例在听，可以投递事件。
  int listening_ = 0;
};

HeinEventChannel* g_event_ch = nullptr;

// core.c 的属性推送钩子：mpv 事件线程上被调用。
// ⚠️ FlutterDesktopMessengerSend 是线程安全的（内部会切到 platform 线程），
//    可直接从 mpv 事件线程调用。
void OnCoreProperty(const char* name, double value) {
  if (g_event_ch == nullptr) return;
  g_event_ch->Send(name, EncodableValue(value));
}

// textureId 专用（int64）：Dart 侧按 int 收，避免 double 的 2^53 精度上限。
void PushEventInt64(const char* name, int64_t value) {
  if (g_event_ch == nullptr) return;
  g_event_ch->Send(name, EncodableValue(value));
}

// 🔴🔴🔴 2026-10-22 Windows 黑屏根因（通用陷阱，Linux 版不会踩）：
//
//   MethodChannel 的 **Dart int 到了 C++ 侧只会是 int32_t / int64_t，
//   永远不会是 double**（encodable_value.h 的 variant 里 int 与 double
//   是两个互斥分支，标准 codec 按 Dart 侧实际类型装箱）。
//
//   所以「只判 holds_alternative<double>」的解析代码对 Dart 传 int 的参数
//   **全部静默不命中**，字段保持初值，函数收到 0 —— 不抛异常、不报错，
//   表现为「参数像没传一样」。Windows 版此前所有数值参数都有这个隐患：
//     · setViewSize 的 width/height  → 本次黑屏的直接原因
//     · open 的 startAtMs / cacheSecs
//     · seek 的 positionMs
//     · setVolume 的 volume
//     · setSpeed 的 rate
//   统一用一个容忍三种数值类型的读取器，彻底消除这类静默失败。
static bool ReadDouble(const EncodableValue& v, double* out) {
  if (out == nullptr) return false;
  if (const auto* d = std::get_if<double>(&v)) {
    *out = *d;
    return true;
  }
  if (const auto* i32 = std::get_if<int32_t>(&v)) {
    *out = static_cast<double>(*i32);
    return true;
  }
  if (const auto* i64 = std::get_if<int64_t>(&v)) {
    *out = static_cast<double>(*i64);
    return true;
  }
  return false;
}

// ---- MethodChannel 处理 ----
void HandleMethodCall(
    const flutter::MethodCall<EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
  const std::string& m = call.method_name();
  const auto* args = std::get_if<EncodableMap>(call.arguments());

  if (m == "init") {
    // init 内部已按正确顺序做完全部工作：
    //   ① hein_win_texture_create（D3D11 外部纹理，**主线程**注册）
    //   ② mpv_create + 选项（gpu-api/gpu-context = d3d11）
    //   ③ mpv_render_context_create(D3D11_INIT_PARAMS)，device 取自纹理
    //   ④ 事件线程 + 渲染线程（CreateThread）
    // 因此这里**不要再**调一次 hein_win_texture_create（会重复注册纹理，
    // 且 textureId 与 mpv 实际渲染目标不一致）。改为取出 core 里已建好的。
    bool ok = hein_mpv_init_windows(g_texture_registrar, &g_win_texture);
    if (ok && g_win_texture == nullptr) {
      // 兜底：core 未回填（理论上不会），补一次并交回。
      g_win_texture = hein_win_texture_create(g_texture_registrar);
      hein_mpv_set_win_texture(g_win_texture);
    }
    // 接上属性推送钩子（P0-5）：time-pos/duration/paused/eof 全靠它上行。
    // ⚠️ 必须在 init 成功后设，否则事件线程起来后前几帧事件会丢。
    if (ok) hein_mpv_set_push_hook(OnCoreProperty);

    int64_t tex_id =
        g_win_texture != nullptr ? hein_win_texture_id(g_win_texture) : -1;
    EncodableMap r{{EncodableValue("ok"), EncodableValue(ok)},
                   {EncodableValue("textureId"), EncodableValue(tex_id)}};
    result->Success(EncodableValue(r));

    // textureId 同时经 EventChannel 推一次（Dart 侧的 listener 会捕获）。
    // 双通道下发更稳：即使 Dart 侧 init 返回值处理有遗漏，也能从这里拿到。
    if (ok && tex_id >= 0) PushEventInt64("textureId", tex_id);
  } else if (m == "open") {
    std::string url;
    double start_ms = 0.0;
    bool live = false, hw = true;
    double cache = 30.0;
    if (args) {
      for (const auto& [k, v] : *args) {
        const std::string& key = std::get<std::string>(k);
        if (key == "url" && std::holds_alternative<std::string>(v))
          url = std::get<std::string>(v);
        else if (key == "startAtMs")
          ReadDouble(v, &start_ms);
        else if (key == "isLive" && std::holds_alternative<bool>(v))
          live = std::get<bool>(v);
        else if (key == "hardwareDecoding" && std::holds_alternative<bool>(v))
          hw = std::get<bool>(v);
        else if (key == "cacheSecs")
          ReadDouble(v, &cache);
      }
    }
    int rc = hein_mpv_open(url.c_str(), start_ms / 1000.0, live, hw, (int)cache);
    EncodableMap r{{EncodableValue("rc"), EncodableValue(rc)}};
    result->Success(EncodableValue(r));
  } else if (m == "play") {
    result->Success(EncodableValue(hein_mpv_play()));
  } else if (m == "pause") {
    result->Success(EncodableValue(hein_mpv_pause()));
  } else if (m == "seek") {
    double ms = 0.0;
    if (args) {
      for (const auto& [k, v] : *args) {
        if (std::get<std::string>(k) == "positionMs") ReadDouble(v, &ms);
      }
    }
    result->Success(EncodableValue(hein_mpv_seek(ms / 1000.0)));
  } else if (m == "setSpeed") {
    double r = 1.0;
    if (args) {
      for (const auto& [k, v] : *args) {
        if (std::get<std::string>(k) == "rate") ReadDouble(v, &r);
      }
    }
    result->Success(EncodableValue(hein_mpv_set_speed(r)));
  } else if (m == "setVolume") {
    // Dart 侧已归一化到 0~100（见 mpv_desktop_backend.dart 的 setVolume）。
    double vol = 100.0;
    if (args) {
      for (const auto& kv : *args) {
        if (std::get<std::string>(kv.first) == "volume")
          ReadDouble(kv.second, &vol);
      }
    }
    result->Success(EncodableValue(hein_mpv_set_volume(vol)));
  } else if (m == "setFit") {
    // 🔴 P0-4 修复：Dart 侧 _pushFit() 会调 setFit 传
    //    "contain"/"cover"/"fill" 之一。原实现没有这个分支 →
    //    result->NotImplemented() → Dart 抛 PlatformException（多被 catch
    //    吞掉）→ mpv 的 keepaspect/panscan 永远是默认值 → 画面比例与控件
    //    不符（16:9 片源在 4:3 区域被拉伸，或黑边位置偏移）。
    std::string fit;
    if (args) {
      for (const auto& [k, v] : *args) {
        if (std::get<std::string>(k) == "fit" &&
            std::holds_alternative<std::string>(v))
          fit = std::get<std::string>(v);
      }
    }
    result->Success(EncodableValue(hein_mpv_set_fit(fit.c_str())));
  } else if (m == "setViewSize") {
    // 🔴 P0-6 修复：Dart 侧 updateViewSize() 把视频层控件的**物理像素**
    //    尺寸报上来（Dart 侧已乘过 devicePixelRatio）。
    //
    // 🔴🔴🔴 2026-10-22 黑屏根因（Windows 版，Linux 不会踩）：
    //    Dart 传的是 **int**（`int w = (constraints.maxWidth * dpr).round()`），
    //    而 MethodChannel 的 Dart int 在 C++ 侧只会是 **int32_t / int64_t**，
    //    **永远不会变成 double**。原实现只写 holds_alternative<double> →
    //    两个分支全部不命中 → w/h 保持 0.0 →
    //    hein_mpv_set_view_size(0,0) 内部 `if (w<=0) return` **静默丢弃**
    //    → core 的 view_w/view_h 永远是 0。
    //
    //    后果链（实测日志铁证：56 秒内 1251 条「纹理已重建」）：
    //      ① pump 的尺寸决策退到 video-out-params → 纹理 1920x1080；
    //      ② 引擎回调 populate 按控件尺寸要 1264x681 → 判定不符 → 重建；
    //      ③ 下一帧 pump 又按 1920x1080 重建 …… 两者互相覆盖，
    //         每秒重建 20~50 次，两个尺寸交替出现（1920x1080 ⇄ 1264x681）；
    //      ④ 引擎手里的共享句柄每帧都被换掉，MarkTextureFrameAvailable
    //         刚通知的纹理立刻被下一轮 Reset → 采样的永远是空纹理
    //         → **黑屏且不报任何错**（用户实测：点播/直播都黑屏、无错误）。
    //
    //    修法：数值参数必须容忍 int32_t / int64_t / double（见 ReadDouble）。
    double w = 0.0, h = 0.0;
    if (args) {
      for (const auto& kv : *args) {
        const std::string& key = std::get<std::string>(kv.first);
        if (key == "width")
          ReadDouble(kv.second, &w);
        else if (key == "height")
          ReadDouble(kv.second, &h);
      }
    }
    // ⚠️ 不要再乘 devicePixelRatio：Dart 侧上报的已经是物理像素。
    //    原实现这里乘一次 dpr（且 Dart 根本没传 dpr，恒为 1.0，纯属隐患）。
    hein_log("setViewSize 收到 %.0fx%.0f（物理像素）", w, h);
    hein_mpv_set_view_size((int)(w + 0.5), (int)(h + 0.5));
    // set_view_size 内部已置 has_new_frame 并 request_frame（唤醒渲染线程）。
    result->Success();
  } else if (m == "position") {
    result->Success(EncodableValue(hein_mpv_get_double("time-pos", 0.0)));
  } else if (m == "duration") {
    result->Success(EncodableValue(hein_mpv_get_double("duration", 0.0)));
  } else if (m == "buffered") {
    result->Success(
        EncodableValue(hein_mpv_get_double("demuxer-cache-time", 0.0)));
  } else if (m == "dispose") {
    // 🔴 顺序很关键：先停 mpv（内部会停渲染线程、join 事件线程），
    //    再销毁 D3D11 外部纹理。反过来的话渲染线程可能还在往已销毁的
    //    纹理里 render → 访问已释放的 COM 对象 → 崩。
    hein_mpv_shutdown();
    if (g_win_texture != nullptr) {
      hein_win_texture_destroy(g_win_texture);
      g_win_texture = nullptr;
    }
    result->Success();
  } else {
    result->NotImplemented();
  }
}

}  // namespace

// ---- 插件注册（Flutter Windows C API 约定）----
//
// 🔴 2026-10-21：messenger 的正确取法。
//    原实现写 flutter::DesktopMessenger::From(registrar) —— 这个类在
//    Flutter SDK 里**根本不存在**（编译期直接报 not declared）。
//    正确做法：先用 C API 拿到 FlutterDesktopMessengerRef，再用
//    再经本文件里的 HeinBinaryMessenger 包成 C++ wrapper 的
//    BinaryMessenger（BinaryMessengerImpl 虽是官方标准桥，但它在
//    client_wrapper 的**内部**头 binary_messenger_impl.h 里，
//    Flutter SDK 未导出到插件的 include 路径，不可直接 include）。
// ⚠️ BinaryMessengerImpl 必须比通道活得久，故用 shared_ptr 长期持有。
//
// 🔴🔴 2026-10-22：**导出约定**（Windows 专属，Linux 不会踩这个坑）。
//   runner 的 flutter_window.cpp 用
//     GetProcAddress(handle, "HeinPlayMpvDesktopPluginRegisterWithRegistrar")
//   取本函数，故必须同时满足两个条件，缺一即「插件从未注册」：
//     ① extern "C"  —— 否则 C++ 会把名字修饰成
//        _Z48HeinPlayMpvDesktopPluginRegisterWithRegistrarPFu...，
//        GetProcAddress 按未修饰名永远查不到；
//     ② __declspec(dllexport) —— Windows DLL **默认不导出任何符号**
//        （不像 Linux 的 .so 默认导出全部符号），不显式导出则
//        导出表里根本没有这个函数。
//   症状对照：Linux 能播、Windows 报
//     MissingPluginException(No implementation found for method init
//     on channel hain_tv/mpv_desktop)
//   —— 通道没人注册，正是本函数没被 runner 调到。
extern "C" __declspec(dllexport) void
HeinPlayMpvDesktopPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  // 纹理注册器
  g_texture_registrar =
      FlutterDesktopRegistrarGetTextureRegistrar(registrar);

  // messenger：C API ref → C++ wrapper
  FlutterDesktopMessengerRef core_messenger =
      FlutterDesktopPluginRegistrarGetMessenger(registrar);
  static std::shared_ptr<flutter::BinaryMessenger> messenger =
      std::make_shared<HeinBinaryMessenger>(core_messenger);
  // GetInstance 返回 const&，用引用接收。用 auto 会推导成值类型，
  // 触发已删除的拷贝构造 -> 编译失败（本次预检抓到的真实缺陷）。
  const flutter::StandardMethodCodec& codec =
      flutter::StandardMethodCodec::GetInstance();

  // ⚠️ MethodChannel 构造要 BinaryMessenger*（裸指针）+ MethodCodec*，
  //    不是 shared_ptr / 引用。这是本次预检抓到的又一真实缺陷。
  g_channel = std::make_shared<flutter::MethodChannel<EncodableValue>>(
      messenger.get(), "hain_tv/mpv_desktop", &codec);
  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<EncodableValue>> result) {
        HandleMethodCall(call, std::move(result));
      });

  // EventChannel（P0-5 修复）：原来只建 channel 不设 handler，
  // 导致 Dart 的 listen 永远等不到应答、一条事件都发不出去。
  //
  // 这里不用 flutter::EventChannel 模板（Flutter 3.47.5 SDK 的
  // event_channel.h 第 95 行有编译期缺陷，见 HeinEventChannel 注释），
  // 改为经我们的 HeinBinaryMessenger 直接监听事件通道名。
  g_event_ch = new HeinEventChannel(core_messenger,
                                    "hain_tv/mpv_desktop_events", codec);
  messenger->SetMessageHandler(
      "hain_tv/mpv_desktop_events",
      [](const uint8_t* message, size_t size, BinaryReply reply) {
        if (g_event_ch == nullptr) {
          reply(nullptr, 0);
          return;
        }
        if (!g_event_ch->HandleMessage(message, size, reply)) {
          reply(nullptr, 0);
        }
      });

  OutputDebugStringA("HeinPlayMpvDesktop: Windows 插件已注册\n");
}
