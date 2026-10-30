// HeinPlay tvLegacy mpv JNI 封装（自写壳 + 官方 mpv 内核，对齐 mpv-android 范式）。
//
// 【安卓渲染机制】
//   把 Android Surface 的 JNI 全局引用指针直接作为 mpv 的 `wid` 选项（int64）传给
//   libmpv，mpv 的 android gpu-context（video/out/opengl/context_android.c）内部调
//   ANativeWindow_fromSurface(env, surface) 拿到 ANativeWindow 并建 EGL surface 出画。
//   这是官方 libmpv 的安卓渲染路径，也是官方 mpv-android 的 render.cpp 用法。
//
// 【本工程相对主工程的两处关键修正】
//   1. JNI_OnLoad 里必须 av_jni_set_java_vm(g_vm)！
//      mpv 的 vo_android_init() 走 MP_JNI_GET_ENV → mp_jni_get_env()
//      → av_jni_get_java_vm()，而 ffmpeg 的 java_vm 静态变量只有应用自己调用
//      av_jni_set_java_vm() 才会被赋值。官方 mpv-android 在 Java_..._create 的
//      prepare_environment() 里做这件事；我们不依赖应用侧记得调用，直接在
//      JNI_OnLoad 注册，否则 vo_android_init 必然报
//      "Could not attach java VM." → 黑屏。
//   2. setlocale(LC_NUMERIC, "C")：mpv/ffmpeg 解析浮点字符串依赖 C 语言环境，
//      安卓默认 locale 会让 `--speed=1.5` 之类的解析出错（官方同样处理）。
//
// 【每个 PlatformView 一个 mpv 实例】
//   事件线程每实例跑 mpv_wait_event，把 property change 经 Kotlin 实例回调推到
//   Flutter EventChannel。
//
// 编译：见 CMakeLists.txt（NDK 编成 libheinplay_mpv_jni.so）。

#include <jni.h>
#include <pthread.h>
#include <locale.h>
#include <map>
#include <string>
#include <cstdlib>
#include <android/log.h>
#include <mpv/client.h>

// ffmpeg 的 JavaVM 注册入口（libavcodec.so 导出）。
// 不引用 <libavcodec/jni.h> 是为了避免 CMake 里还要带 ffmpeg 头文件路径。
extern "C" int av_jni_set_java_vm(void *vm, void *log_ctx);

#define LOG_TAG "HeinPlayMpvJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM *g_vm = NULL;
// 缓存 Kotlin 实例类与方法（MpvPlayerView.onMpvEvent）
static jclass g_viewClass = NULL;
static jmethodID g_onEventMid = NULL;

struct MpvInstance {
    mpv_handle *ctx = nullptr;
    pthread_t event_thread{};
    volatile bool exit_requested = false;
    bool initialized = false;
    jobject view_ref = nullptr;      // 全局引用，指向 Kotlin MpvPlayerView
    jobject surface_global = nullptr; // 全局引用，wid 对应的 Surface（mpv 内部持有）
    bool attached = false;
};

// handle(int64) -> instance
static std::map<int64_t, MpvInstance*> g_instances;

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    g_vm = vm;

    // 🔴 关键：把 JavaVM 交给 ffmpeg，mpv 的 android gpu-context 才能取到 JNIEnv。
    setlocale(LC_NUMERIC, "C");
    int jvm_err = av_jni_set_java_vm(vm, NULL);
    LOGI("av_jni_set_java_vm 返回 %d", jvm_err);

    JNIEnv *env = NULL;
    if (vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) return JNI_ERR;
    jclass vc = env->FindClass("com/heinplay/hain_tv/MpvPlayerView");
    if (vc) {
        g_viewClass = reinterpret_cast<jclass>(env->NewGlobalRef(vc));
        g_onEventMid = env->GetMethodID(g_viewClass, "onMpvEvent",
            "(Ljava/lang/String;DZ)V");
    } else {
        LOGE("JNI_OnLoad: 未找到 com/heinplay/hain_tv/MpvPlayerView");
    }
    return JNI_VERSION_1_6;
}

static void push_event(JNIEnv *env, MpvInstance *inst, const char *name, jdouble value, jboolean isDouble) {
    if (!inst || !inst->view_ref || !g_onEventMid) return;
    jstring jname = env->NewStringUTF(name);
    env->CallVoidMethod(inst->view_ref, g_onEventMid, jname, value, isDouble);
    env->DeleteLocalRef(jname);
}

static void *event_thread(void *arg) {
    auto *inst = reinterpret_cast<MpvInstance *>(arg);
    JNIEnv *env = NULL;
    if (g_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        g_vm->AttachCurrentThread(&env, NULL);
    }
    while (true) {
        // ⚠️ 2026-10-12 崩溃修复（SIGSEGV / signal 11）：
        //   destroy() 会先 exit_requested=true + mpv_wakeup() 再 pthread_join，
        //   因此把退出检查**提前到 mpv_wait_event 之前**，可以让事件线程在收到
        //   唤醒后立刻返回，不再进入 push_event()，从而消除「事件线程正在
        //   CallVoidMethod 回调 Kotlin，主线程已 DeleteGlobalRef(view_ref)/
        //   delete inst」的并发窗口。
        //   原实现把检查放在 wait 之后：虽然多数情况也能退出，但在
        //   「wait 已返回、尚未走到检查」的间隙里仍会继续下发回调。
        if (inst->exit_requested) break;
        mpv_event *e = mpv_wait_event(inst->ctx, -1.0);
        if (inst->exit_requested) break;
        // 防御：mpv_wait_event 在异常路径下可能返回 NULL，原实现直接解引用
        // e->event_id 会段错误。
        if (e == nullptr || e->event_id == MPV_EVENT_NONE) continue;
        if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            auto *prop = reinterpret_cast<mpv_event_property *>(e->data);
            if (!prop->name) continue;
            if (strcmp(prop->name, "time-pos") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                push_event(env, inst, "time-pos", *(double*)prop->data, JNI_TRUE);
            } else if (strcmp(prop->name, "duration") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                push_event(env, inst, "duration", *(double*)prop->data, JNI_TRUE);
            } else if (strcmp(prop->name, "pause") == 0 && prop->format == MPV_FORMAT_FLAG) {
                push_event(env, inst, "pause", *(int*)prop->data ? 1.0 : 0.0, JNI_FALSE);
            } else if (strcmp(prop->name, "cache-buffering-state") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                push_event(env, inst, "cache-buffering-state", *(double*)prop->data, JNI_TRUE);
            } else if (strcmp(prop->name, "volume") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                push_event(env, inst, "volume", *(double*)prop->data, JNI_TRUE);
            } else if (strcmp(prop->name, "speed") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                push_event(env, inst, "speed", *(double*)prop->data, JNI_TRUE);
            } else if (strcmp(prop->name, "eof-reached") == 0 && prop->format == MPV_FORMAT_FLAG) {
                push_event(env, inst, "eof-reached", *(int*)prop->data ? 1.0 : 0.0, JNI_FALSE);
            } else if (strcmp(prop->name, "demuxer-cache-time") == 0 && prop->format == MPV_FORMAT_DOUBLE) {
                push_event(env, inst, "demuxer-cache-time", *(double*)prop->data, JNI_TRUE);
            } else if (strcmp(prop->name, "hwdec-current") == 0 && prop->format == MPV_FORMAT_STRING) {
                // ⚠️ 2026-10-11：字符串型属性无法经 value(double) 承载，
                //   故只发「变更通知」（value=0），由 Kotlin 侧回读实际字符串
                //   （MpvPlayerView.readStringProperty），避免在此处理 jstring 生命周期。
                //   prop->data 为 NULL 表示属性当前不可用（如未起播），
                //   同样照发通知，由 Kotlin 侧判断是否可信。
                push_event(env, inst, "hwdec-current", 0.0, JNI_FALSE);
            } else if (strcmp(prop->name, "video-params/pixelformat") == 0 && prop->format == MPV_FORMAT_STRING) {
                // 同上：仅作变更通知，供硬解探针附带打印像素格式，辅助判断硬解是否真生效。
                push_event(env, inst, "video-params/pixelformat", 0.0, JNI_FALSE);
            } else if (
                (strcmp(prop->name, "video-params/colormatrix") == 0 ||
                 strcmp(prop->name, "video-params/primaries") == 0 ||
                 strcmp(prop->name, "video-params/colorlevels") == 0) &&
                prop->format == MPV_FORMAT_STRING) {
                // 🔴 2026-10-12 绿屏取证：源色彩参数同样是字符串型，走「只发通知
                //   + Kotlin 回读」的既有模式（见上方 hwdec-current 的说明）。
                //   ✅ 真机实测这三个值是 bt.709/bt.709/limited（**非空、正确**），
                //      故「硬解读不到 VUI 色彩 ⇒ 猜错 ⇒ 绿屏」的旧假设已被证伪，
                //      据此下发的 vf=format 强制转换也已撤除。
                push_event(env, inst, prop->name, 0.0, JNI_FALSE);
            } else if (
                // 🆕🔴 2026-10-12 23:2x 几何/步幅探针白名单 —— 验证「stride/plane 错位」。
                //
                //   ⚠️ 本分支是**必需的**：JNI 此处是白名单分发，未列出的属性名
                //      即使 Kotlin 侧 observeProperty 成功，回调也**不会**被推上来。
                //      （新加探针时最容易漏的一步。）
                //
                //   加入理由：用户实测**模拟器不绿屏、真机绿屏** ⇒ 真因在硬件/驱动层，
                //   最可能是硬解输出 buffer 的 YUV plane 步幅与 GL 采样约定不符。
                //   dw/dh 是解码器输出尺寸（16 对齐后），w/h 是显示尺寸，
                //   二者不等即说明存在对齐填充 → 色度平面错切风险。
                (strcmp(prop->name, "video-params/w") == 0 ||
                 strcmp(prop->name, "video-params/h") == 0 ||
                 strcmp(prop->name, "video-params/dw") == 0 ||
                 strcmp(prop->name, "video-params/dh") == 0) &&
                prop->format == MPV_FORMAT_INT64) {
                // 整型属性：与字符串型同样只发变更通知，由 Kotlin 侧回读。
                push_event(env, inst, prop->name, 0.0, JNI_FALSE);
            } else if (strcmp(prop->name, "video-params/aspect") == 0 &&
                       prop->format == MPV_FORMAT_DOUBLE) {
                // aspect 是 double 型，仍走「只发通知 + Kotlin 回读」的统一模式，
                // 避免在此处处理类型分支（Kotlin 侧 readStringProperty 已够用）。
                push_event(env, inst, prop->name, 0.0, JNI_FALSE);
            }
        }
    }
    if (env) g_vm->DetachCurrentThread();
    return NULL;
}

extern "C" {

// view 参数是 Kotlin 的 MpvPlayerView 实例（不是 MpvCore）：
// 属性回调要打在 MpvPlayerView.onMpvEvent 上，若拿 MpvCore 实例去 CallVoidMethod
// 会因方法所属类不匹配而崩溃。MpvCore 是每视图一个实例，故 create 时传入 view。
JNIEXPORT jlong JNICALL Java_com_heinplay_hain_1tv_MpvCore_create(JNIEnv *env, jobject thiz,
    jobject view) {
    mpv_handle *ctx = mpv_create();
    if (!ctx) { LOGE("mpv_create 失败"); return 0; }
    auto *inst = new MpvInstance();
    inst->ctx = ctx;
    inst->view_ref = env->NewGlobalRef(view);
    jlong id = reinterpret_cast<jlong>(inst);
    g_instances[id] = inst;
    LOGI("mpv_create 成功 inst=%lld", (long long)id);
    return id;
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_initialize(JNIEnv *env, jobject thiz, jlong handle) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    // vo/gpu-context/hwdec/cache/observe 等已在 Kotlin 经 setOptionString/observeProperty
    // 设置；wid 与 android-surface-size 经 attachSurface 在 initialize 之前设置。
    int err = mpv_initialize(inst->ctx);
    inst->initialized = (err >= 0);
    LOGI("mpv_initialize err=%d", err);
    inst->exit_requested = false;
    pthread_create(&inst->event_thread, NULL, event_thread, inst);
    pthread_setname_np(inst->event_thread, "mpv_event");
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_setOptionString(JNIEnv *env, jobject thiz,
    jlong handle, jstring name, jstring value) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    const char *cname = env->GetStringUTFChars(name, NULL);
    const char *cval = env->GetStringUTFChars(value, NULL);
    int err = mpv_set_option_string(inst->ctx, cname, cval);
    if (err < 0) LOGE("setOptionString %s=%s err=%d", cname, cval, err);
    env->ReleaseStringUTFChars(name, cname);
    env->ReleaseStringUTFChars(value, cval);
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_command(JNIEnv *env, jobject thiz,
    jlong handle, jobjectArray args) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    jsize len = env->GetArrayLength(args);
    const char **argv = (const char **)calloc(len + 1, sizeof(char *));
    jstring *jstrs = (jstring *)calloc(len, sizeof(jstring));
    for (jsize i = 0; i < len; i++) {
        jstring s = (jstring)env->GetObjectArrayElement(args, i);
        jstrs[i] = s;
        argv[i] = env->GetStringUTFChars(s, NULL);
    }
    argv[len] = NULL;
    int err = mpv_command(inst->ctx, argv);
    if (err < 0) LOGE("command err=%d (%s)", err, mpv_error_string(err));
    for (jsize i = 0; i < len; i++) {
        env->ReleaseStringUTFChars(jstrs[i], argv[i]);
        env->DeleteLocalRef(jstrs[i]);
    }
    free(jstrs); free(argv);
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_setPropertyString(JNIEnv *env, jobject thiz,
    jlong handle, jstring name, jstring value) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    const char *cname = env->GetStringUTFChars(name, NULL);
    const char *cval = env->GetStringUTFChars(value, NULL);
    int err = mpv_set_property_string(inst->ctx, cname, cval);
    if (err < 0) LOGE("setPropertyString %s=%s err=%d", cname, cval, err);
    env->ReleaseStringUTFChars(name, cname);
    env->ReleaseStringUTFChars(value, cval);
}

JNIEXPORT jstring JNICALL Java_com_heinplay_hain_1tv_MpvCore_getPropertyString(JNIEnv *env, jobject thiz,
    jlong handle, jstring name) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    const char *cname = env->GetStringUTFChars(name, NULL);
    char *val = mpv_get_property_string(inst->ctx, cname);
    env->ReleaseStringUTFChars(name, cname);
    if (!val) return NULL;
    jstring ret = env->NewStringUTF(val);
    mpv_free(val);
    return ret;
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_observeProperty(JNIEnv *env, jobject thiz,
    jlong handle, jint replyId, jstring name, jint format) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    const char *cname = env->GetStringUTFChars(name, NULL);
    int err = mpv_observe_property(inst->ctx, replyId, cname, (mpv_format)format);
    if (err < 0) LOGE("observeProperty %s err=%d", cname, err);
    env->ReleaseStringUTFChars(name, cname);
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_unobserveProperty(JNIEnv *env, jobject thiz,
    jlong handle, jint replyId) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    mpv_unobserve_property(inst->ctx, replyId);
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_requestLogMessages(JNIEnv *env, jobject thiz,
    jlong handle, jstring level) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    const char *clevel = env->GetStringUTFChars(level, NULL);
    mpv_request_log_messages(inst->ctx, clevel);
    env->ReleaseStringUTFChars(level, clevel);
}

// 把 Android Surface 作为 wid 喂给 mpv（安卓渲染核心）。
// 注意：libmpv 内部会持有 wid 指针并自行调 ANativeWindow_fromSurface，
// 所以必须传**全局引用**（NewGlobalRef），否则局部引用被回收后指针悬空导致崩溃。
//
// 【surface 重建路径】纹理路线的 SurfaceProducer 在 resize / 后台回前台时可能换
// 新 Surface。此时实例已 initialize，`wid` 是 UPDATE_VO 选项，只能经 property
// 设置才会触发 VO 重建；未 initialize 时用 option 设置（与官方 mpv-android 一致）。
JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_attachSurface(JNIEnv *env, jobject thiz,
    jlong handle, jobject surface) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    if (inst->surface_global) {
        env->DeleteGlobalRef(inst->surface_global);
        inst->surface_global = NULL;
    }
    inst->surface_global = env->NewGlobalRef(surface);
    int64_t wid = reinterpret_cast<int64_t>(inst->surface_global);
    int result;
    if (inst->initialized) {
        result = mpv_set_property(inst->ctx, "wid", MPV_FORMAT_INT64, &wid);
        LOGI("surface 已 attach 为 wid（运行时 property 路径）");
    } else {
        result = mpv_set_option(inst->ctx, "wid", MPV_FORMAT_INT64, &wid);
        LOGI("surface 已 attach 为 wid（初始化前 option 路径）");
    }
    if (result < 0) LOGE("attachSurface mpv wid err=%s", mpv_error_string(result));
    else inst->attached = true;
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_detachSurface(JNIEnv *env, jobject thiz,
    jlong handle) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    int64_t wid = 0;
    if (inst->initialized) {
        mpv_set_property(inst->ctx, "wid", MPV_FORMAT_INT64, &wid);
    } else {
        mpv_set_option(inst->ctx, "wid", MPV_FORMAT_INT64, &wid);
    }
    inst->attached = false;
    LOGI("surface 已 detach");
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_destroy(JNIEnv *env, jobject thiz, jlong handle) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    if (!inst) return;
    inst->exit_requested = true;
    mpv_wakeup(inst->ctx);
    if (inst->initialized) pthread_join(inst->event_thread, NULL);
    mpv_terminate_destroy(inst->ctx);
    if (inst->view_ref) env->DeleteGlobalRef(inst->view_ref);
    if (inst->surface_global) env->DeleteGlobalRef(inst->surface_global);
    g_instances.erase(handle);
    delete inst;
    LOGI("mpv 实例已销毁 handle=%lld", (long long)handle);
}

} // extern "C"
