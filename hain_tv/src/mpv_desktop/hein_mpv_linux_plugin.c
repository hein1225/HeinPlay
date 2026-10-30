// 桌面 mpv 壳 · Linux 插件入口。
//
// 【职责】
//   ① 注册 MethodChannel `hain_tv/mpv_desktop`，暴露 init/open/play/pause/
//      seek/setSpeed/setVolume/position/duration/buffered/dispose 给 Dart 侧。
//   ② 注册 EventChannel `hain_tv/mpv_desktop_events`，向上推
//      time-pos / duration / demuxer-cache-time / paused / eof / textureId。
//   ③ **帧循环接入**：mpv 的 render API 需要 GL 上下文 current 时才能真正
//      把帧画进 FBO。Flutter Linux 的 GL 上下文在帧绘制时才 current，
//      故必须挂在 FlView 的 tick 回调里（gtk_widget_add_tick_callback），
//      每帧调用 hein_mpv_render_to_fbo()。这是 Android 侧纹理路线在 Linux
//      的等价物，缺它则永远只有黑屏。
//   ④ 日志不节流（教训⑥：节流会制造事件稀疏假象）。

// 🔴 必须最先定义：pthread_timedjoin_np 是 GNU 扩展，只在 _GNU_SOURCE 下
//    声明。本文件先 include 了 gtk/flutter 头（内部已包含 pthread.h），
//    若把宏定义放在被 #include 的 hein_mpv_core.c 顶部则为时已晚
//    → 编译报 implicit declaration。故必须在**本文件最顶部**定义。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif

#include <flutter_linux/flutter_linux.h>
#include <flutter_linux/fl_method_channel.h>
#include <flutter_linux/fl_event_channel.h>
#include <flutter_linux/fl_standard_method_codec.h>
#include <flutter_linux/fl_json_message_codec.h>
#include <flutter_linux/fl_plugin_registrar.h>
#include <flutter_linux/fl_texture_registrar.h>
#include <gtk/gtk.h>

#include "hein_mpv_core.c"  // 单文件编译，直接包含实现

static FlMethodChannel *g_channel = NULL;
static FlEventChannel *g_event_channel = NULL;
static FlPluginRegistrar *g_registrar = NULL;
static guint g_tick_id = 0;

// ---- 事件上行（无节流）----
//
// 🔴 无节流（教训⑥）：Android 侧 onMpvEvent 有 10% 日志节流，制造了
//    「time-pos 稀疏」的假象，误导过排查。壳侧所有上行一律不节流。
//
//    但 time-pos 本身变化极频繁（每秒数十次），这里只对**重复值**去重，
//    不是节流：值没变就不发，变了立刻发。
static double g_last_sent_pos = -1.0;
static double g_last_sent_dur = -1.0;
static double g_last_sent_buf = -1.0;

static void push_event(const char *name, double value) {
  if (g_event_channel == NULL) return;
  // 重复值去重（避免无意义刷爆通道）
  if (g_strcmp0(name, "time-pos") == 0) {
    if (value == g_last_sent_pos) return;
    g_last_sent_pos = value;
  } else if (g_strcmp0(name, "duration") == 0) {
    if (value == g_last_sent_dur) return;
    g_last_sent_dur = value;
  } else if (g_strcmp0(name, "demuxer-cache-time") == 0) {
    if (value == g_last_sent_buf) return;
    g_last_sent_buf = value;
  }
  g_autoptr(FlValue) msg = fl_value_new_map();
  fl_value_set_string_take(msg, "name", fl_value_new_string(name));
  fl_value_set_string_take(msg, "value", fl_value_new_float(value));
  fl_event_channel_send(g_event_channel, msg, NULL, NULL);
}

// core.c 的属性转发钩子落地处。
static void on_core_property(const char *name, double value) {
  // paused / eof 在 Dart 侧按 bool 用，这里原样透传 0/1。
  push_event(name, value);
}

// 每帧：把 mpv 的新帧画进 FBO 并通知 Flutter 采样。
static gboolean on_frame_tick(GtkWidget *widget, GdkFrameClock *clock,
                              gpointer user_data) {
  (void)widget;
  (void)clock;
  (void)user_data;
  hein_mpv_render_to_fbo();
  return G_SOURCE_CONTINUE;
}

// 从 FlValue map 里取 double，缺省返回 defval。
static double arg_double(FlValue *args, const gchar *key, double defval) {
  FlValue *v = fl_value_lookup_string(args, key);
  if (v == NULL) return defval;
  // 🔴 Standard codec 下 Dart 的数字可能是 INT32 / INT64 / FLOAT 三种，
  //    必须全覆盖：startAtMs=0 在 Dart 侧是 int（INT32），曾只判 FLOAT
  //    导致「起播定位永远传 0」这类静默失效。
  switch (fl_value_get_type(v)) {
    case FL_VALUE_TYPE_FLOAT:
      return fl_value_get_float(v);
    case FL_VALUE_TYPE_INT:
      return (double)fl_value_get_int(v);
    default:
      return defval;
  }
}

static gboolean arg_bool(FlValue *args, const gchar *key, gboolean defval) {
  FlValue *v = fl_value_lookup_string(args, key);
  if (v == NULL) return defval;
  if (fl_value_get_type(v) != FL_VALUE_TYPE_BOOL) return defval;
  return fl_value_get_bool(v);
}

// ---- MethodChannel 处理 ----
static void method_call_cb(FlMethodChannel *channel, FlMethodCall *call,
                           gpointer user_data) {
  (void)user_data;
  const gchar *m = fl_method_call_get_name(call);
  FlValue *args = fl_method_call_get_args(call);
  g_autoptr(FlMethodResponse) response = NULL;

  if (g_strcmp0(m, "init") == 0) {
    bool ok = hein_mpv_init_linux(g_registrar, channel, g_event_channel);
    g_autoptr(FlValue) r = fl_value_new_map();
    fl_value_set_string_take(r, "ok", fl_value_new_bool(ok));
    fl_value_set_string_take(
        r, "textureId", fl_value_new_int(hein_mpv_texture_id_linux()));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(r));
    // 同时经事件通道推一次 textureId，Dart 侧靠它触发出画重建。
    push_event("textureId", (double)hein_mpv_texture_id_linux());
  } else if (g_strcmp0(m, "open") == 0) {
    const gchar *url = NULL;
    FlValue *u = fl_value_lookup_string(args, "url");
    if (u != NULL && fl_value_get_type(u) == FL_VALUE_TYPE_STRING) {
      url = fl_value_get_string(u);
    }
    if (url == NULL) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "bad-args", "缺少 url", NULL));
      fl_method_call_respond(call, response, NULL);
      return;
    }
    double start_ms = arg_double(args, "startAtMs", 0.0);
    gboolean live = arg_bool(args, "isLive", FALSE);
    gboolean hw = arg_bool(args, "hardwareDecoding", TRUE);
    double cache = arg_double(args, "cacheSecs", 30.0);
    int rc = hein_mpv_open(url, start_ms / 1000.0, live, hw, (int)cache);
    g_autoptr(FlValue) r = fl_value_new_map();
    fl_value_set_string_take(r, "rc", fl_value_new_int(rc));
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(r));
  } else if (g_strcmp0(m, "play") == 0) {
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_int(hein_mpv_play())));
  } else if (g_strcmp0(m, "pause") == 0) {
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_int(hein_mpv_pause())));
  } else if (g_strcmp0(m, "seek") == 0) {
    double ms = arg_double(args, "positionMs", 0.0);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_int(hein_mpv_seek(ms / 1000.0))));
  } else if (g_strcmp0(m, "setSpeed") == 0) {
    double r = arg_double(args, "rate", 1.0);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_int(hein_mpv_set_speed(r))));
  } else if (g_strcmp0(m, "setVolume") == 0) {
    double v = arg_double(args, "volume", 100.0);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_int(hein_mpv_set_volume(v))));
  } else if (g_strcmp0(m, "setFit") == 0) {
    // 画面比例三态（移植自 Android MpvPlayerView 的 setFit 分支）。
    // Dart 侧此前只把 BoxFit 存进字段、从不下发，壳也从未设置过
    // keepaspect/panscan → 点播画面比例失真
    // （16:9 片源在 1080x1920 竖屏掌机上被压扁）。
    const gchar *fit = NULL;
    FlValue *fv = fl_value_lookup_string(args, "fit");
    if (fv != NULL && fl_value_get_type(fv) == FL_VALUE_TYPE_STRING) {
      fit = fl_value_get_string(fv);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_int(hein_mpv_set_fit(fit))));
  } else if (g_strcmp0(m, "setViewSize") == 0) {
    // Dart 上报视频层控件尺寸（逻辑像素 × devicePixelRatio，即物理像素）。
    // 壳据此建 FBO，让 mpv 在该尺寸内按 video-params 做 letterbox ——
    // 这是画面比例正确的唯一路径（FBO 取视频尺寸时 mpv 无从加黑边）。
    int vw = (int)arg_double(args, "width", 0.0);
    int vh = (int)arg_double(args, "height", 0.0);
    hein_mpv_set_view_size(vw, vh);
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_int(0)));
  } else if (g_strcmp0(m, "position") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_float(hein_mpv_get_double("time-pos", 0.0))));
  } else if (g_strcmp0(m, "duration") == 0) {
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_float(hein_mpv_get_double("duration", 0.0))));
  } else if (g_strcmp0(m, "buffered") == 0) {
    // 与 Android 双判据一致：demuxer-cache-time 是 mpv 侧物理缓存末端。
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(
        fl_value_new_float(hein_mpv_get_double("demuxer-cache-time", 0.0))));
  } else if (g_strcmp0(m, "dispose") == 0) {
    hein_mpv_shutdown();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(NULL));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }
  fl_method_call_respond(call, response, NULL);
}

// ---- 插件注册（Flutter Linux 约定）----
void hein_mpv_desktop_plugin_register_with_registrar(
    FlPluginRegistrar *registrar) {
  g_registrar = registrar;
  FlBinaryMessenger *messenger = fl_plugin_registrar_get_messenger(registrar);

g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_channel = fl_method_channel_new(messenger, "hain_tv/mpv_desktop",
                        FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(g_channel, method_call_cb, NULL,
                                            NULL);

  // 🔴 事件通道必须与 Dart 侧 EventChannel 默认 codec 一致，即
  //    **FlStandardMethodCodec**。曾错用 FlJsonMethodCodec，导致 Dart 发来的
  //    二进制消息壳解不了，实测报：
  //      "Failed to decode method call: Message is not valid UTF8"
  //    （Dart 的 MethodChannel/EventChannel 默认 StandardMethodCodec 是二进制
  //     格式，JSON codec 是文本格式，两者不兼容。）
  g_autoptr(FlStandardMethodCodec) ev_codec = fl_standard_method_codec_new();
  g_event_channel = fl_event_channel_new(messenger, "hain_tv/mpv_desktop_events",
                                         FL_METHOD_CODEC(ev_codec));

  // 把 core.c 的属性变化接到本层的 push_event。
  hein_mpv_set_push_hook(on_core_property);

  // 🔴 排障自检：HEIN_MPV_SELFTEST=<媒体> 时，插件注册即初始化 mpv 并加载，
  //    无需 UI 交互即可验证「渲染→FBO→FlTextureGL→populate」整条链路。
  {
    const char *st = g_getenv("HEIN_MPV_SELFTEST");
    if (st != NULL && *st != '\0') {
      hein_mpv_init_linux(registrar, g_channel, g_event_channel);
    }
  }

  // 帧循环：挂到 FlView 的 tick 回调上，每帧驱动 mpv 渲染。
  FlView *view = fl_plugin_registrar_get_view(registrar);
  if (view != NULL) {
    g_tick_id = gtk_widget_add_tick_callback(GTK_WIDGET(view), on_frame_tick,
                                             NULL, NULL);
  }
  g_print("HeinPlayMpvDesktop: Linux 插件已注册（帧循环 id=%u）\n", g_tick_id);
}
