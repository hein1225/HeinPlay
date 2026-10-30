// HeinPlay mpv 安卓 JNI 封装（自写壳，对齐鸿蒙 libmpv_wrapper + mpv-android 范式）。
//
// 安卓渲染机制：把 Android Surface 的 JNI 指针直接作为 mpv 的 `wid` 选项
// （int64）传给 libmpv，mpv 的 android gpu-context 自动把画面渲染到该 Surface。
// 这是 libmpv 官方安卓渲染路径（无需 MPV_RENDER_PARAM_ANDROID_SURFACE 宏，
// 官方 libmpv 不含该宏，那是 mpv-android 的 wid 范式）。
//
// 每个 PlatformView 一个 mpv 实例，事件线程每实例跑 mpv_wait_event，
// 把 property change 经 Kotlin 实例推到 Flutter EventChannel。
//
// 编译：见 CMakeLists.txt（Android NDK 编成 libheinplay_mpv_jni.so）。

#include <jni.h>
#include <pthread.h>
#include <semaphore.h>
#include <time.h>
#include <errno.h>
#include <locale.h>
#include <map>
#include <string>
#include <android/log.h>
#include <mpv/client.h>

// ffmpeg 的 JavaVM 注册入口（libavcodec.so 导出；libmpv.so 本身不导出该符号）。
// 不引用 <libavcodec/jni.h> 是为了避免 CMake 里还要带 ffmpeg 头文件路径。
extern "C" int av_jni_set_java_vm(void *vm, void *log_ctx);

#define LOG_TAG "HeinPlayMpvJni"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN, LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

static JavaVM *g_vm = NULL;
// 缓存 Kotlin 实例类与方法（MpvPlayerView.onMpvEvent）
static jclass g_viewClass = NULL;
static jmethodID g_onEventMid = NULL;

struct MpvInstance {
    mpv_handle *ctx = nullptr;
    pthread_t event_thread{};
    volatile bool exit_requested = false;
    // 🔴 2026-10-14 卡死根因修复：事件线程退出信号量。
    //   bionic（Android libc）**不提供** pthread_timedjoin_np / pthread_tryjoin_np，
    //   pthread_join 也没有超时版本。而 destroy() 跑在 Android 主线程上，一旦
    //   无限等待就会 ANR（实测 23:19:51 卡 7.9 秒后被 SIGKILL）。
    //   故改为：事件线程退出前 sem_post(&exited)，destory() 用 sem_timedwait
    //   等最多 2 秒；等到才 pthread_join（此时必然立即返回，不阻塞），
    //   等不到就直接 detach，绝不阻塞 UI 线程。
    sem_t exited{};
    jobject view_ref = nullptr;  // 全局引用，指向 Kotlin MpvPlayerView
    jobject surface_global = nullptr;  // 全局引用，wid 对应的 Surface（mpv 内部持有）
    bool attached = false;
    // 🔴 2026-10-16 起播精确定位：Kotlin 侧 open 时写入的「期望起播毫秒」。
    //   FILE_LOADED 到达时随事件回传，Kotlin 据此决定是否补一次精确 seek。
    //   只被事件线程读、主线程写，volatile 足够（值本身是松散语义的提示）。
    volatile long long pending_seek_ms = 0;
};

// handle(int64) -> instance
static std::map<int64_t, MpvInstance*> g_instances;

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM *vm, void *reserved) {
    g_vm = vm;

    // 🔴 关键（与 hain_tv_legacy 同源修正）：
    //   1) av_jni_set_java_vm()：mpv 的 vo_android_init() 走 MP_JNI_GET_ENV →
    //      mp_jni_get_env() → av_jni_get_java_vm()，而 ffmpeg 的 java_vm 静态变量
    //      只有应用自己调 av_jni_set_java_vm() 才会被赋值。官方 mpv-android 在
    //      Java_..._create 的 prepare_environment() 里做这件事；我们在 JNI_OnLoad
    //      直接注册，否则 vo_android_init 必然报 "Could not attach java VM." → 黑屏。
    //   2) setlocale(LC_NUMERIC, "C")：mpv/ffmpeg 解析浮点字符串依赖 C 语言环境，
    //      安卓默认 locale 会让 `--speed=1.5` 之类的解析出错（官方同样处理）。
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
    if (!inst || !inst->view_ref || !g_onEventMid) {
        // 🔴 此前这里静默 return。一旦 view_ref/methodID 缺失，事件会永久丢失且
        //   日志一片干净 —— 「进度条不动」排查时完全无从下手。改为打一次日志。
        static bool warned = false;
        if (!warned) {
            warned = true;
            LOGE("push_event 跳过：view_ref=%p methodID=%p（事件回调不可用）",
                 (void *) inst->view_ref, (void *) g_onEventMid);
        }
        return;
    }
    // 🔴 事件线程必须处于「无挂起异常」的干净状态，否则后续 JNI 调用全会失败。
    if (env->ExceptionCheck()) {
        LOGE("push_event: 进入时已有挂起异常，清除后继续");
        env->ExceptionDescribe();
        env->ExceptionClear();
    }
    jstring jname = env->NewStringUTF(name);
    env->CallVoidMethod(inst->view_ref, g_onEventMid, jname, value, isDouble);
    // 🔴🔴 关键：CallVoidMethod 抛出的异常若不清除，会一直挂在事件线程上，
    //   之后每一次 JNI 调用都直接失败，症状是「所有属性回调同时消失」。
    //   这里必须检查并清除，且首次报出来，避免再次静默失效。
    if (env->ExceptionCheck()) {
        static bool reported = false;
        if (!reported) {
            reported = true;
            LOGE("push_event: onMpvEvent 调用抛异常（name=%s）—— 事件回调链路断裂", name);
            env->ExceptionDescribe();
        }
        env->ExceptionClear();
    }
    env->DeleteLocalRef(jname);
}

static void *event_thread(void *arg) {
    auto *inst = reinterpret_cast<MpvInstance *>(arg);
    JNIEnv *env = NULL;
    if (g_vm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6) != JNI_OK) {
        g_vm->AttachCurrentThread(&env, NULL);
    }
    while (true) {
        // 🔴🔴 2026-10-14 卡死根因修复：超时由 -1.0（无限阻塞）改为 0.05s 轮询。
        //
        //   原实现 `mpv_wait_event(ctx, -1.0)` + destroy() 里 `pthread_join`，
        //   构成一个会**永久阻塞 Android 主线程**的死锁：
        //     destroy() 先 exit_requested=true → mpv_wakeup() → pthread_join()。
        //   mpv_wakeup 的官方保证是「无人在等时，下一次 mpv_wait_event 立即返回」，
        //   但这条保证只覆盖「事件线程不在 mpv 内部」的情形。真实日志（23:19:51
        //   点返回后卡 7.9s）显示事件线程当时正阻塞在 mpv 内部的 VO/Vulkan 上下文
        //   创建上，既不在 wait 状态也无从唤醒；主线程在 join 上干等到
        //   Activity pause timeout → ANR → 系统 SIGKILL。
        //
        //   改成短超时轮询后，线程最多 50ms 就回到循环顶部检查 exit_requested，
        //   join 必然能在有界时间内返回。MPV_EVENT_NONE 由超时返回，直接 continue。
        //
        //   ⚠️ 注意：这只能解决「线程在 wait_event 中」的退出。若线程正卡在 mpv
        //   内部的长时间调用上，仍需 destroy() 侧的超时兜底（见 destroy）。
        mpv_event *e = mpv_wait_event(inst->ctx, 0.05);
        if (inst->exit_requested) break;
        if (e->event_id == MPV_EVENT_NONE) continue;
        // 🔴 mpv 的报错/警告只走 log-message 事件（Kotlin 已 requestLogMessages("info")）。
        //    此前这里只处理 PROPERTY_CHANGE，mpv 内部所有错误（打不开流、协议不支持、
        //    解码器初始化失败…）全部被静默丢弃，表现为「点了没反应、日志一片干净」。
        //    转发到 logcat，让「播不了」有据可查。
        if (e->event_id == MPV_EVENT_LOG_MESSAGE) {
            auto *msg = reinterpret_cast<mpv_event_log_message *>(e->data);
            if (msg && msg->text) {
                LOGI("mpv[%s] %s: %s", msg->prefix ? msg->prefix : "-",
                     msg->level ? msg->level : "-", msg->text);
            }
            continue;
        }
        // 文件加载失败 / 播放结束等终态事件：同样必须打出来。
        if (e->event_id == MPV_EVENT_END_FILE) {
            auto *ef = reinterpret_cast<mpv_event_end_file *>(e->data);
            if (ef) {
                LOGE("mpv END_FILE reason=%d error=%d (%s)", ef->reason, ef->error,
                     mpv_error_string(ef->error));
            }
            continue;
        }
        // 🔴 2026-10-16 起播精确定位：把 FILE_LOADED 转成 Kotlin 可消费的事件。
        //   背景：此前 loadfile 只设 `start=` 属性，mpv 对 HLS 会在**最近分片边界**
        //   落地，再靠内部时钟慢慢收敛到精确位置。日志实证（模拟器 22:04:35）：
        //     open start=1145000ms → 首个心跳 tp=1145.000000（完全吻合）
        //     → #1 tp=1174.40（Δ+29.4）→ #2 tp=1202.76（Δ+28.36）
        //     → #3 起恒定 Δ+3.00
        //   且 audio-pts 与 time-pos **同步跳**（差 +0.003 / +2.232），证明是
        //   demuxer 层真实 PTS 位移，而非元数据轴漂移。用户观感即「进度条往前跳两段」。
        //   修法：等 FILE_LOADED（此时 demuxer 就绪、可精确 seek）后主动
        //   `seek <目标> absolute` 一次，把定位一次性钉死，不再依赖暂态收敛。
        //   用 push_event 通道复用既有回调（name="file-loaded"，isDouble=false），
        //   value 携带目标毫秒，Kotlin 侧据此决定是否需要补 seek。
        if (e->event_id == MPV_EVENT_FILE_LOADED) {
            LOGI("mpv FILE_LOADED");
            push_event(env, inst, "file-loaded", (jdouble) inst->pending_seek_ms, JNI_FALSE);
            continue;
        }
        if (e->event_id == MPV_EVENT_PROPERTY_CHANGE) {
            auto *prop = reinterpret_cast<mpv_event_property *>(e->data);
            if (!prop->name) continue;
            // 🔴🔴 2026-10-15 可观测性修复（进度条恒 00:00 事故的教训）：
            //   此前若 Kotlin 侧 observeProperty 传的 format 与这里的判断不一致，
            //   事件会**静默穿过整条 if-else 链**，不打任何日志 —— 外部只能看到
            //   「push_event 一次都没执行」「onMpvEvent 0 次」，完全无从定位。
            //   现在对每个已知属性名，一旦 format 不匹配就打印告警（同名只报一次），
            //   让「注册格式写错」这类问题立刻暴露在日志里。
            //   对应的正确枚举：FLAG=3, INT64=4, DOUBLE=5, STRING=1。
            bool handled = false;
            if (strcmp(prop->name, "time-pos") == 0) {
                if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
                    push_event(env, inst, "time-pos", *(double*)prop->data, JNI_TRUE);
                }
                handled = true;
            } else if (strcmp(prop->name, "duration") == 0) {
                if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
                    push_event(env, inst, "duration", *(double*)prop->data, JNI_TRUE);
                }
                handled = true;
            } else if (strcmp(prop->name, "pause") == 0) {
                if (prop->format == MPV_FORMAT_FLAG && prop->data) {
                    push_event(env, inst, "pause", *(int*)prop->data ? 1.0 : 0.0, JNI_FALSE);
                }
                handled = true;
            } else if (strcmp(prop->name, "cache-buffering-state") == 0) {
                if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
                    push_event(env, inst, "cache-buffering-state", *(double*)prop->data, JNI_TRUE);
                }
                handled = true;
            } else if (strcmp(prop->name, "volume") == 0) {
                if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
                    push_event(env, inst, "volume", *(double*)prop->data, JNI_TRUE);
                }
                handled = true;
            } else if (strcmp(prop->name, "speed") == 0) {
                if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
                    push_event(env, inst, "speed", *(double*)prop->data, JNI_TRUE);
                }
                handled = true;
            } else if (strcmp(prop->name, "eof-reached") == 0) {
                if (prop->format == MPV_FORMAT_FLAG && prop->data) {
                    push_event(env, inst, "eof-reached", *(int*)prop->data ? 1.0 : 0.0, JNI_FALSE);
                }
                handled = true;
            } else if (strcmp(prop->name, "demuxer-cache-time") == 0) {
                if (prop->format == MPV_FORMAT_DOUBLE && prop->data) {
                    push_event(env, inst, "demuxer-cache-time", *(double*)prop->data, JNI_TRUE);
                }
                handled = true;
            } else if (strcmp(prop->name, "hwdec-current") == 0) {
                // 🔴 诊断埋点（2026-10-15）：硬解**实际生效值**的实时变更。
                //
                //   背景：安卓「播放一阵子后画面卡死、只有声音」。要区分
                //   ① 硬解中途掉链子退回软解  ② 硬解正常但渲染停止，
                //   唯一直接证据就是 hwdec-current 的变化。
                //
                //   ⚠️ 该属性是 STRING 型（format=1），而 push_event 的签名是
                //      (name, jdouble, jboolean) —— **承载不了字符串**。故此处
                //      不走 Kotlin 回调，直接打 logcat（本通道同样进 logcat，无观测损失）。
                //      Kotlin 侧 observeProperty(9, "hwdec-current", 1) 的注册值
                //      必须保持 format=1，否则 mpv 不会按 STRING 回发。
                if (prop->format == MPV_FORMAT_STRING && prop->data) {
                    const char *v = *(const char **)prop->data;
                    LOGI("hwdec-current 变更: '%s'", v ? v : "(null)");
                } else if (prop->format != MPV_FORMAT_NONE) {
                    LOGW("hwdec-current format=%d 非 STRING(1)，值被丢弃",
                         (int) prop->format);
                }
                handled = true;
            }
            // 🔴 2026-10-24：`hwdec-current` 是 **STRING 型**（format=1），它的值
            //   已在上面的专用分支里直接打进 logcat（push_event 承载不了字符串，
            //   见该分支注释），**不走 Kotlin 回调通道**。
            //
            //   但本兜底分支原只把 DOUBLE/FLAG 当合法格式，STRING 命中后会误报
            //   E 级「属性 … 与 JNI 期望不符 —— 事件被丢弃」。而事实上事件
            //   **并未被丢弃**：值已经取到并打印了（`hwdec-current 变更:
            //   'mediacodec-copy'`），紧跟着的 `Using hardware decoding
            //   (mediacodec-copy)` 也证明硬解正常工作。真机日志里这条误报
            //   在每次硬解生效时刷一条，足以干扰排障。
            //
            //   故此处按属性名显式豁免 STRING 型，其余属性仍严格校验格式 ——
            //   保留「注册值写错」这类真实故障的即时暴露能力。
            bool isStringProp = (strcmp(prop->name, "hwdec-current") == 0);
            if (handled && !isStringProp
                && prop->format != MPV_FORMAT_DOUBLE
                && prop->format != MPV_FORMAT_FLAG
                && prop->format != MPV_FORMAT_NONE) {
                // 走到这里说明该属性的 format 既不是 DOUBLE 也不是 FLAG ——
                // 几乎必然是 Kotlin 侧 observeProperty 传错了 mpv_format 枚举值。
                //
                // 🔴 2026-10-15：必须排除 MPV_FORMAT_NONE(0)。mpv 在
                //    unobserve / 属性失效时会以 format=NONE 回发一次
                //    PROPERTY_CHANGE，这是**正常收尾**而非错配。真机日志里
                //    time-pos/duration/cache-buffering-state/eof-reached/
                //    demuxer-cache-time 五个属性曾在同一毫秒各报 1 次，
                //    正是这条误报（注册值已由 dexdump 证实全部正确）。
                static char warned_names[8][32] = {{0}};
                static int warned_count = 0;
                bool seen = false;
                for (int i = 0; i < warned_count; i++) {
                    if (strcmp(warned_names[i], prop->name) == 0) { seen = true; break; }
                }
                if (!seen && warned_count < 8) {
                    snprintf(warned_names[warned_count], sizeof(warned_names[0]), "%s", prop->name);
                    warned_count++;
                    LOGE("属性 %s 的 format=%d 与 JNI 期望不符（DOUBLE=5/FLAG=3）——"
                         "事件被丢弃，请检查 Kotlin observeProperty 传入的 format",
                         prop->name, (int) prop->format);
                }
            }
        }
    }
    // 🔴 2026-10-14：必须先 sem_post 再 DetachCurrentThread —— destroy() 侧用
    //   sem_timedwait 等这个信号，等到后才 pthread_join（此时立即返回）。
    //   若先 detach 再 post，destroy 仍能等到，但若有异常路径跳过 post，
    //   destroy 就会白等满 2 秒。放在最前面最稳妥。
    sem_post(&inst->exited);
    if (env) g_vm->DetachCurrentThread();
    return NULL;
}

extern "C" {

JNIEXPORT jlong JNICALL Java_com_heinplay_hain_1tv_MpvCore_create(JNIEnv *env, jobject thiz,
    jobject view) {
    mpv_handle *ctx = mpv_create();
    if (!ctx) { LOGE("mpv_create 失败"); return 0; }
    auto *inst = new MpvInstance();
    inst->ctx = ctx;
    // 🔴 退出信号量：初值 0，事件线程退出时 sem_post，destroy() 用 sem_timedwait 等。
    //   pshared=0 表示进程内线程间共享。初始化失败会导致 destroy 无法有界等待，
    //   故失败时直接放弃本次 create（返回 0），避免留下一个必然会卡死 UI 的实例。
    if (sem_init(&inst->exited, 0, 0) != 0) {
        LOGE("sem_init 失败 errno=%d", errno);
        delete inst;
        mpv_terminate_destroy(ctx);
        return 0;
    }
    // 🔴🔴 必须用参数 view（Kotlin 侧传 this，即 MpvPlayerView），不能用 thiz。
    //   thiz 是 MpvCore 实例 —— 把 MpvPlayerView.onMpvEvent 的方法 ID 用在 MpvCore
    //   对象上调用，JNI 会抛异常；由于 push_event 既不检查返回值也不清异常，
    //   事件线程此后一直带挂起异常运行，所有属性回调静默失效。
    //   真机表现：事件通道 onListen 正常、纹理正常出画、但 onMpvEvent 零调用，
    //   进度条恒 00:00 且误报「播放就绪超时」。
    if (!view) { LOGE("create: view 参数为 null，事件回调将不可用"); }
    inst->view_ref = view ? env->NewGlobalRef(view) : nullptr;
    jlong id = reinterpret_cast<jlong>(inst);
    g_instances[id] = inst;
    LOGI("mpv_create 成功 inst=%lld", (long long)id);
    return id;
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_initialize(JNIEnv *env, jobject thiz, jlong handle) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    // 注意：vo/gpu-context/hwdec/cache/observe 等已在 Kotlin 经 setOptionString/observeProperty
    // 设置；wid 经 attachSurface 在 initialize 之前设置。此处仅做 initialize + 事件线程。
    int err = mpv_initialize(inst->ctx);
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

// 🔴 2026-10-17：改为返回 int（mpv 错误码），调用方据此判断命令是否真的执行成功。
//   背景：`seek` 在 mpv 尚未 file-loaded 时会返回 -12(MPV_ERROR_UNINITIALIZED)，
//   而旧实现恒返回 void，Kotlin 侧无从得知失败，于是在换源时错误地跳过起播精确定位
//   （真机日志：command err=-12 → 起播精确定位跳过 userSeeked=true → 从头播放）。
JNIEXPORT jint JNICALL Java_com_heinplay_hain_1tv_MpvCore_command(JNIEnv *env, jobject thiz,
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
    return (jint)err;
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

// 🔴 2026-10-16 起播精确定位：登记「期望起播毫秒」，FILE_LOADED 时回传给 Kotlin。
//   Kotlin 在 loadfile 之前调用；置 0 表示无需补 seek（如 startAtMs<=0 或直播）。
JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_setPendingSeekMs(JNIEnv *env, jobject thiz,
    jlong handle, jlong ms) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    if (!inst) return;
    inst->pending_seek_ms = (long long) ms;
}

// 把 Android Surface 作为 wid 喂给 mpv（安卓 rendering 核心）。
// 注意：libmpv 内部会持有 wid 指针并自行调 ANativeWindow_fromSurface，
// 所以必须传**全局引用**（NewGlobalRef），否则局部引用被回收后指针悬空导致崩溃。
JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_attachSurface(JNIEnv *env, jobject thiz,
    jlong handle, jobject surface) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    if (inst->surface_global) {
        env->DeleteGlobalRef(inst->surface_global);
        inst->surface_global = NULL;
    }
    inst->surface_global = env->NewGlobalRef(surface);
    int64_t wid = reinterpret_cast<int64_t>(inst->surface_global);
    int result = mpv_set_option(inst->ctx, "wid", MPV_FORMAT_INT64, &wid);
    if (result < 0) LOGE("attachSurface mpv_set_option(wid) err=%s", mpv_error_string(result));
    else { inst->attached = true; LOGI("surface 已 attach 为 wid"); }
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_detachSurface(JNIEnv *env, jobject thiz,
    jlong handle) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    int64_t wid = 0;
    mpv_set_option(inst->ctx, "wid", MPV_FORMAT_INT64, &wid);
    inst->attached = false;
    LOGI("surface 已 detach");
}

JNIEXPORT void JNICALL Java_com_heinplay_hain_1tv_MpvCore_destroy(JNIEnv *env, jobject thiz, jlong handle) {
    auto *inst = reinterpret_cast<MpvInstance *>(handle);
    if (!inst) return;
    inst->exit_requested = true;
    mpv_wakeup(inst->ctx);

    // 🔴🔴 2026-10-14 卡死根因修复：等待必须有界，绝不能无限阻塞调用线程。
    //
    //   destroy() 由 Kotlin dispose() 调用，而 dispose() 跑在 **Android 主线程**
    //   （PlatformView 销毁路径）。原实现直接 `pthread_join` 无超时，一旦事件线程
    //   卡在 mpv 内部调用里（实测：VO/Vulkan 上下文创建失败时的阻塞），主线程就
    //   永久挂起 → Activity pause timeout → ANR → SIGKILL（日志实证 23:19:51
    //   点返回后卡 7.9 秒）。
    //
    //   bionic 不提供 pthread_timedjoin_np，故用信号量：
    //     事件线程退出前 sem_post(&inst->exited)；
    //     这里 sem_timedwait 最多 2 秒（线程已改成 50ms 轮询，正常几十毫秒即退出，
    //     2 秒是极充裕的兜底）。
    //     等到 → pthread_join 立即返回（不阻塞）；
    //     等不到 → detach，宁可泄漏一个线程也不卡死 UI。
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += 2;
    int wait_err = sem_timedwait(&inst->exited, &ts);
    if (wait_err == 0) {
        pthread_join(inst->event_thread, NULL);
        LOGI("mpv 事件线程已正常退出");
    } else {
        pthread_detach(inst->event_thread);
        LOGW("mpv 事件线程 2 秒未退出（errno=%d），已 detach 以免阻塞主线程", errno);
    }

    mpv_terminate_destroy(inst->ctx);
    if (inst->view_ref) env->DeleteGlobalRef(inst->view_ref);
    if (inst->surface_global) env->DeleteGlobalRef(inst->surface_global);
    g_instances.erase(handle);
    sem_destroy(&inst->exited);
    delete inst;
    LOGI("mpv 实例已销毁 handle=%lld", (long long)handle);
}

} // extern "C"
