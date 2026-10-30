package com.heinplay.hain_tv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import android.view.View
import android.widget.FrameLayout
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

/**
 * HeinPlay mpv 安卓原生绑定（对齐官方 mpv-android 的 wid 范式）。
 *
 * 三层结构（与鸿蒙一致）：
 *  1. 内核：官方 mpv 源码交叉编译的 libmpv.so（含 mediacodec 硬解、android[vk] gpu-context）。
 *  2. 壳（本文件）：Kotlin 原生层，经 JNI 直接调 libmpv C API，把 Android Surface
 *     作为 mpv 的 `wid` 交给 mpv 的 gpu-context 渲染（mpv-android 官方范式）。
 *  3. Dart 层：lib/player/mpv_backend.dart，经同一契约与这里通信。
 *
 * 🔴🔴 渲染路线：仅纹理（SurfaceProducer → Flutter 外部纹理）。
 *
 *  `TextureRegistry.createSurfaceProducer()` 申请 Flutter 外部纹理，mpv 把画面渲染
 *  到该纹理的 Surface，Dart 侧 `Texture(textureId)` 显示。本视图本体只是一个零尺寸
 *  占位（挂载锚点），不出画。
 *
 *  ⚠️ 2026-10-15：**从 SurfaceView 路线改回纹理路线**。
 *
 *  这是「点播/直播都播不出画」的决定性根因。主工程移植时用了 `SurfaceView`
 *  自带 Surface 直画 ANativeWindow，而 hain_tv_legacy 早在 2026-10-07 就用真机实测
 *  证明该路线在 Flutter 下**无法实现**（两条合成路径都是黑屏）：
 *
 *   1. `AndroidView` → 引擎硬编码 `VIEW_TYPES_REQUIRE_VIRTUAL_DISPLAY = {SurfaceView}`
 *      （`hasChildViewOfType` 递归判定，包进 ViewGroup 也躲不开），强制 Virtual Display；
 *   2. Hybrid Composition → logcat 中 `flutter-vd` 已归零（Hybrid 确已生效）但**仍黑屏**：
 *      Hybrid 用 ImageReader 把平台视图「画」成纹理，而 `SurfaceView` 内容不走
 *      `View.draw()`，捕获到空帧。
 *   唯一可行解 `setZOrderMediaOverlay(true)` 会让 SurfaceView 浮到 Flutter 表面之上、
 *   永久盖住控制条等全部 Flutter UI，与「Flutter 渲染 UI」架构根本冲突。
 *
 *  真机日志（小米 12S Pro，2026-10-14）铁证：
 *    · 强制 GL 路线：`VO: [gpu-next] 1920x818 yuv420p` 已出，但
 *      `h264_mediacodec: Both surface and native_window are NULL` +
 *      `AHardwareBuffer: GraphicBuffer(w=4, h=4, lc=1) failed (Unknown error -3)`
 *      —— 硬解拿不到 ANativeWindow，画面到不了屏幕。
 *    · Vulkan 路线：`● Video`/`● Audio` 都解出来了，却**没有 `VO:` 行**
 *      —— libplacebo 建 swapchain 时 surface 无效，VO 未完成。
 *  两条路线同一根因：**Surface 没被正确交给 mpv**。
 *
 * 契约（与鸿蒙 MpvBridge.ets 对齐）：
 *  - MethodChannel `hain_tv/mpv`：open/play/pause/seek/setVolume/setSpeed/dispose（按 viewId 路由）。
 *  - EventChannel `hain_tv/mpv_events_<viewId>`：首条为 `{type:'texture', textureId}`，
 *    其后推送 {positionSec,durationSec,playing,buffering,volume,speed,eof,buffer}。
 */

private const val TAG = "HeinPlayMpv"
private const val VIEW_TYPE = "heinplay_mpv"
private const val CHANNEL_CONTROL = "hain_tv/mpv"

/** 懒加载 libmpv（及其 C++ 运行时依赖）。 */
private object MpvLoader {
    private val loaded = AtomicBoolean(false)
    fun ensureLoaded() {
        if (loaded.compareAndSet(false, true)) {
            try {
                System.loadLibrary("c++_shared")
            } catch (e: UnsatisfiedLinkError) {
                Log.w(TAG, "libc++_shared 已随其它库加载（忽略）: ${e.message}")
            }
            System.loadLibrary("mpv")
            Log.i(TAG, "libmpv.so 加载完成")
        }
    }
}

/** libmpv C API 的 JNI 封装（wid 机制最小子集，对齐 mpv-android 范式）。 */
class MpvCore {
    init {
        MpvLoader.ensureLoaded()
    }

    // 🔴🔴 必须显式传入 view 对象（对齐 legacy）：JNI 侧要用它做 NewGlobalRef，
    //   事件线程靠这个引用回调 onMpvEvent。若 JNI 侧误用 thiz（即 MpvCore 实例），
    //   CallVoidMethod 会把 MpvPlayerView 的方法 ID 用在 MpvCore 对象上，
    //   触发 JNI 异常且被静默吞掉 —— 表现为「事件一个都到不了 Dart，进度条恒 00:00」。
    external fun create(view: Any): Long // 返回 mpv_handle*
    external fun initialize(handle: Long)
    external fun setOptionString(handle: Long, name: String, value: String)
    external fun command(handle: Long, args: Array<String>): Int
    external fun setPropertyString(handle: Long, name: String, value: String)
    external fun getPropertyString(handle: Long, name: String): String?
    external fun observeProperty(handle: Long, replyId: Int, name: String, format: Int)
    external fun unobserveProperty(handle: Long, replyId: Int)
    external fun requestLogMessages(handle: Long, level: String)
    // 🔴 2026-10-16 起播精确定位：登记期望起播毫秒，FILE_LOADED 时回传。
    external fun setPendingSeekMs(handle: Long, ms: Long)
    // 渲染：把 Android Surface 作为 wid 交给 mpv 的 android gpu-context。
    external fun attachSurface(handle: Long, surface: Surface)
    external fun detachSurface(handle: Long)
    external fun destroy(handle: Long)

    companion object {
        init {
            MpvLoader.ensureLoaded()
            try {
                System.loadLibrary("heinplay_mpv_jni")
            } catch (e: UnsatisfiedLinkError) {
                Log.i(TAG, "heinplay_mpv_jni 未单独提供（忽略）: ${e.message}")
            }
        }
    }
}

/**
 * 单视图桥接：持有 mpv 实例 + 状态推送 sink。
 *
 * 渲染路线固定纹理：产出一个 [Surface]（来自 SurfaceProducer）交给 mpv 的 `wid`。
 */
class MpvPlayerView(
    private val context: Context,
    private val viewId: Int,
    textureRegistry: TextureRegistry?,
    /**
     * 用户是否在「软件设置→其他」里开启强制 OpenGL ES。
     *
     * 🔴 必须从构造参数进来：渲染路线在 [init] → [setupTextureSurface] →
     *    [onSurfaceReady] → [applyRendererOptions] 里就定死了，而这条链在构造期
     *    就跑完。若走「工厂构造后再 setForceOpenGl」，注入必然晚于使用，
     *    开关恒为默认 false —— 这正是历史 bug「打开强制 OpenGL 也无法播放」。
     */
    private val forceOpenGl: Boolean = false
) : PlatformView, TextureRegistry.SurfaceProducer.Callback {

    /** 外部纹理生产者；纹理路线唯一出画来源。 */
    private val surfaceProducer: TextureRegistry.SurfaceProducer? =
        textureRegistry?.createSurfaceProducer()?.also { it.setCallback(this) }

    /** 纹理路线下的根视图：零尺寸占位，只为触发原生 create（不出画）。 */
    private val placeholderView: View = FrameLayout(context)

    private var core: MpvCore? = null
    private var handle: Long = 0
    private var eventSink: EventChannel.EventSink? = null

    // ⚠️ 加 @Volatile：dispose() 在主线程写 true，而 pushState()/pushTextureId() 由
    //   **mpv 事件线程**经 JNI CallVoidMethod 回调读取。普通 Boolean 在此跨线程场景下
    //   无可见性保证，事件线程可能长期读到陈旧的 false，从而在销毁后仍操作已释放的
    //   对象 → SIGSEGV。
    @Volatile
    private var disposed = false
    // 🔴 mpv 是否已 initialize。open(loadfile) 必须在其之后下发，否则
    //    mpv_command 返回 -3（core not initialized），播放永远起不来。
    private var initialized = false
    // initialize 之前到达的 open 请求，暂存待补发（与 hain_tv_legacy 同机制）。
    private var pendingOpen: Map<String, Any?>? = null

    // 🔴 诊断埋点（2026-10-15）：硬解探针定时器。
    //   mpv 要等解码器真正打开后才填 hwdec-current，open 后立刻回读会得到空字符串
    //   （鸿蒙版实测），故延迟 1.5s 再读。每次 open 都要先取消上一次，避免
    //   连续换源时多个探针叠在一起、打出误导性的中间态。
    private var hwdecProbeTimer: Runnable? = null
    private val probeHandler = android.os.Handler(android.os.Looper.getMainLooper())

    // 🔴 诊断埋点（2026-10-15）：画面心跳监测。
    //
    //   问题：「播放一阵子后画面卡死，只有声音」。此时 time-pos 仍在推进
    //   （已由日志证实：卡死时 time-pos=984.04 还在变），所以**光看 time-pos
    //   无法判断画面死活**。
    //
    //   本心跳每 3s 打一行，同时记录：
    //     · time-pos / demuxer-cache-time —— 解码与缓冲是否在动
    //     · 音频时钟（audio-pts）—— 音频是否在动
    //     · 主线程是否响应 —— 若本心跳本身停止打印，说明主线程被堵死
    //   三者合起来即可判定卡死发生在「解码」「音频」「渲染」「主线程」哪一环。
    //   这是**唯一**能在真机上区分「mpv 停画」与「Flutter 停刷新」的手段。
    private var heartbeatTimer: Runnable? = null
    private var lastHeartbeatPos = 0.0

    /**
     * 启动画面心跳。每次 open 重启一次，避免连续换源时的计数串台。
     */
    private fun startHeartbeat() {
        heartbeatTimer?.let { probeHandler.removeCallbacks(it) }
        lastHeartbeatPos = 0.0
        val hb = object : Runnable {
            override fun run() {
                if (disposed || !initialized) return
                try {
                    val pos = core?.getPropertyString(handle, "time-pos") ?: ""
                    val cache = core?.getPropertyString(handle, "demuxer-cache-time") ?: ""
                    val apts = core?.getPropertyString(handle, "audio-pts") ?: ""
                    val paused = core?.getPropertyString(handle, "pause") ?: ""
                    val posD = pos.toDoubleOrNull() ?: -1.0
                    val stalled = posD >= 0.0 && lastHeartbeatPos > 0.0 &&
                        kotlin.math.abs(posD - lastHeartbeatPos) < 0.05
                    lastHeartbeatPos = posD
                    // 🔴 A-V 偏差与丢帧：音画不同步的**量化**证据。
                    //     `avsync` = 音频时钟 - 视频时钟（正=音频领先，即「声音先」）。
                    //     `frame-drop-count` 增长 = 视频被丢帧追赶（「卡顿后快放」）。
                    //     `speed` 偏离 1.0 = video-sync 正在变速追赶。
                    val avsync = core?.getPropertyString(handle, "avsync") ?: ""
                    val drop = core?.getPropertyString(handle, "frame-drop-count") ?: ""
                    val spd = core?.getPropertyString(handle, "speed") ?: ""
                    // 🔴🔴 2026-10-15 新增：音画不同步的「链路侧」量化探针。
                    //
                    //   背景：真机反馈「全程声音一直领先画面」，但 mpv 的
                    //   `avsync` 只有 16 微秒 —— 说明偏差**不在 mpv 的时钟模型里**。
                    //   mpv 的 avsync 是「音频时钟 − 视频时钟」，两者都取自
                    //   **解码器输出的 PTS**，不包含声卡缓冲的实际排队量。
                    //
                    //   要定位偏差落在哪一段，需同时看四个值：
                    //     · `audio-pts`        mpv 认为的当前音频 PTS
                    //     · `audio-delay`      用户级 A-V 偏移（默认 0，我们没设过）
                    //     · `audio-out-params` 音频输出侧的实际参数（采样率/格式），
                    //                          与 `audio_hw_hal: sampleRate=` 对照可
                    //                          发现「mpv 44100 但声卡 48000」这类
                    //                          二次重采样引入的额外延迟
                    //     · `total-avsync-change` 累计同步修正量，非 0 说明
                    //                          mpv 一直在做速度微调（这就是
                    //                          「点播卡顿然后快放」的来源）
                    //
                    //   ⚠️ 关键：`audio-pts` 与 `avsync` 都**不含**声卡硬件缓冲。
                    //      若真机上这四个值都正常但用户仍听到声音领先，则偏差
                    //      在 `ao=audiotrack` 的 HAL 缓冲，属设备/驱动层，mpv
                    //      侧无法修正（只能靠 `--audio-delay` 反向补偿）。
                    val adelay = core?.getPropertyString(handle, "audio-delay") ?: ""
                    val aout = core?.getPropertyString(handle, "audio-out-params") ?: ""
                    val avchange =
                        core?.getPropertyString(handle, "total-avsync-change") ?: ""
                    // 🔴🔴 2026-10-16 新增跳帧量化探针（诊断「播放时跳帧 / 卡一下快放」）。
                    //
                    //   `frame-drop-count` 只是**结果**，看不出丢帧发生在哪一环。
                    //   补下面两个属性把链路拆开：
                    //     · `mistimed-frame-count` —— 该帧「到得太早或太晚」的次数。
                    //       它增长 = 帧率/时钟不匹配（或 framedrop 正在介入），
                    //       是「跳帧」最直接的数值化指标。
                    //     · `vo-delayed-frame-count` —— 因渲染未就绪而**被迫推迟**
                    //       上屏的帧数。它增长 = 丢帧发生在 VO/渲染侧（GPU 忙），
                    //       而非解码侧。
                    //   两者配合 `frame-drop-count` 即可判定：
                    //     只涨 mistimed        → 时钟速率问题（avsync 链）
                    //     delayed 同步上涨     → 渲染阻塞（GPU/滤镜负载）
                    //     drop 上涨而前两者平稳 → framedrop 正常工作，属预期丢弃
                    val mistimed =
                        core?.getPropertyString(handle, "mistimed-frame-count") ?: ""
                    val vodelay =
                        core?.getPropertyString(handle, "vo-delayed-frame-count") ?: ""
                    Log.i(
                        TAG,
                        "心跳 viewId=$viewId time-pos=$pos audio-pts=$apts " +
                            "demuxer-cache-time=$cache pause=$paused " +
                            "avsync=$avsync 丢帧=$drop 迟到=$mistimed " +
                            "渲染推迟=$vodelay speed=$spd " +
                            "audio-delay=$adelay audio-out=$aout " +
                            "avsync累计修正=$avchange " +
                            "surfaceValid=${currentSurface?.isValid} " +
                            "sink=${eventSink != null}" +
                            if (stalled) " ⚠️ time-pos 3s 内未推进" else ""
                    )
                } catch (e: Exception) {
                    Log.e(TAG, "心跳异常 viewId=$viewId: ${e.message}")
                }
                probeHandler.postDelayed(this, 3000)
            }
        }
        heartbeatTimer = hb
        probeHandler.postDelayed(hb, 3000)
    }

    /** 纹理缓冲尺寸（= 屏幕物理分辨率），mpv 的 android-surface-size 同值。 */
    private var surfaceWidth = 0
    private var surfaceHeight = 0

    private var currentSurface: Surface? = null

    // 最新状态快照（pause/eof 用 0/1 整型表达）
    private var positionSec = 0.0
    private var durationSec = 0.0
    private var playing = false
    private var buffering = false
    private var volume = 1.0
    private var speed = 1.0
    private var eof = false
    private var bufferSec = 0.0
    // 🔴 2026-10-16 起播精确定位（见 onMpvEvent 的 "file-loaded"/"time-pos" 分支）：
    //   pendingSeekTargetMs 由 file-loaded 登记，time-pos 有效后消费；
    //   pendingSeekDone 保证「只补一次」；userSeeked 保证「用户手动 seek 后不再补」，
    //   避免把用户拖回起播点。三者都在 open() 时复位。
    private var pendingSeekTargetMs = 0L
    // 🔴 2026-10-17：起播 seek 的「落地校验」。
    //   目标值 + 截止时间 + 是否已重试。见 time-pos 补 seek 处注释。
    private var pendingSeekVerifyTargetMs = 0L
    private var pendingSeekVerifyDeadlineMs = 0L
    private var pendingSeekRetried = false
    // 🔴🔴 2026-10-17：移除 `start=` 后不再有回显，但首个 time-pos 仍可能是
    //   暂态值（demuxer 刚就绪）。定位只做一次且要钉死，故要求「首个有效值之后
    //   至少隔一次回调」再下发 seek，避免打在尚未稳定的时间轴上。
    private var firstValidTimePosSeen = false
    // 首个有效 time-pos 的时刻；用于给稳定期加硬性上限（见 "time-pos" 分支）
    private var firstValidTimePosAtMs = 0L
    // 🔴🔴🔴 2026-10-17 起播 seek 落地校验的**物理判据**：`demuxer-cache-time`。
    //
    //   背景：此前判据只有 `time-pos`，但 `time-pos` 是 mpv 的**自报量** ——
    //   它可能是 `start=` 的回显，也可能是 seek 请求的暂态值，并不代表
    //   解码器真的把数据读到了那里。用自报量校验自报量，等于没有校验。
    //
    //   `demuxer-cache-time` 是**已下载并缓存到的位置**（物理量，无法伪造）。
    //   它正是 exo 侧 `buffered.last.end` 的 mpv 对应物 —— MediaKit 的
    //   `PlayerStream.buffer` 流就是它（见 media_kit real.dart:1628）。
    //
    //   新判据 = 二者同时成立：
    //     ① `demuxer-cache-time` 已越过目标（数据真的到位了）
    //     ② `time-pos` 进入目标 ±1.5s（播放头真的停在目标处）
    //   只满足 ② 不满足 ① ⇒ 是回显/暂态，不算落地。
    //
    //   注意这两个值来自**不同的回调事件**，因此每次任一事件到达都要
    //   重新尝试判定，故抽成 tryResolveSeekVerify()。
    private var latestCacheSec = -1.0
    private var pendingSeekDone = false
    private var userSeeked = false

    private val mainHandler = Handler(Looper.getMainLooper())

    init {
        Log.i(TAG, "MpvPlayerView 构造 viewId=$viewId")
        initMpv()
        // 纹理路线不需要等 Flutter 的 surface 回调：createSurfaceProducer 之后
        // Surface 即已可用，直接设定尺寸并启动。
        setupTextureSurface()
    }

    private fun resolveDisplaySize() {
        val metrics: DisplayMetrics = context.resources.displayMetrics
        surfaceWidth = if (metrics.widthPixels > 0) metrics.widthPixels else 1920
        surfaceHeight = if (metrics.heightPixels > 0) metrics.heightPixels else 1080
        Log.i(TAG, "显示尺寸 ${surfaceWidth}x${surfaceHeight} viewId=$viewId")
    }

    private fun setupTextureSurface() {
        val producer = surfaceProducer ?: run {
            Log.e(TAG, "surfaceProducer 为 null，纹理路线无法出画 viewId=$viewId")
            return
        }
        resolveDisplaySize()
        try {
            producer.setSize(surfaceWidth, surfaceHeight)
        } catch (e: Exception) {
            Log.e(TAG, "setSize 失败 viewId=$viewId: ${e.message}")
        }
        val surface = try {
            producer.surface
        } catch (e: Exception) {
            Log.e(TAG, "取 Surface 失败 viewId=$viewId: ${e.message}")
            null
        }
        if (surface != null && surface.isValid) {
            onSurfaceReady(surface)
        } else {
            Log.w(TAG, "纹理 Surface 暂不可用 viewId=$viewId，等待 onSurfaceAvailable")
        }
    }

    private fun initMpv() {
        try {
            core = MpvCore()
            handle = core!!.create(this)
            // 渲染路线（vo / gpu-context / gpu-api）不在这里定死：最终值由
            // applyRendererOptions() 在 mpv_initialize 之前写入，因为它依赖用户
            // 在「软件设置→其他」里的强制 GLES 开关。
            // hwdec 不在此写死：由设置页「硬件解码」开关在 open() 时下发。
            //
            // ⚠️ 编码表对齐官方 MPVView 的 "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1"。
            //   本工程主要播 IPTV m3u8（h264/hevc），但部分老源含 mpeg2/mpeg4，
            //   缺失时硬解会静默不生效，故与官方保持一致。
            core!!.setOptionString(handle, "hwdec-codecs", "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
            // ⚠️ 2026-10-11（对齐官方）：**必须显式声明 OpenGL ES 上下文**。
            //   官方 MPVView.initOptions 里 gpu-context=android 的下一行恒为 opengl-es=yes。
            //   不写时 mpv 按桌面 GL 语义挑 EGL config，在老设备（尤其 API 21 的
            //   Amlogic / 低端 v7）上更容易挑到不可用 config 而黑屏。
            core!!.setOptionString(handle, "opengl-es", "yes")
            // ⚠️ 音频输出对齐官方。API 21 老设备上 AudioTrack 最稳，
            //   OpenSL ES 在部分 Amlogic ROM 上初始化失败会直接无声；
            //   官方用逗号链给出优先级，让 mpv 自行降级。
            core!!.setOptionString(handle, "ao", "audiotrack,opensles")
            // ⚠️ demuxer 缓存对齐鸿蒙版（1024MiB / 512MiB），续播定位明显更快。
            core!!.setOptionString(handle, "demuxer-max-bytes", "1024MiB")
            core!!.setOptionString(handle, "demuxer-max-back-bytes", "512MiB")
            // ⚠️ hwdec-software-fallback 不在此写死：它必须跟随「硬件解码」开关，
            // 且直播必须始终允许回退。见 executeOpen 的说明（写死 no 会让纯软解
            // 也被 mpv 判成「回退被禁用」而 force_eof，表现为只有声音没有画面）。
            //
            // 🔴🔴 2026-10-16 删除 `cache=yes` / `cache-secs=30` /
            //   `demuxer-readahead-secs=30` 三条 —— 它们是真机「音画不同步 +
            //   进度跳 + 画面卡一下快放」的直接成因，且鸿蒙版从来没有这三条。
            //
            //   证据链（荣耀平板 V8 Pro 日志 2026101516）：
            //     16:25:50 mpv 起播（URL 127.0.0.1:40707）
            //     16:26:04 Invalid audio PTS: 1111.236288 -> 1081.956900 (−29.28s)
            //     16:26:06 Invalid audio PTS: 1083.953812 -> 1113.233200 (+29.28s)
            //     16:26:08 Invalid audio PTS: 1115.230110 -> 1085.950322 (−29.28s)
            //     16:26:46 exo 起播（**同一个 URL 40707**）→ 此后 0 次报错
            //
            //   三点结论：
            //   ① 幅度完全相等(+29.28/−29.28)、方向来回翻转 ⇒ 不是随机损坏，
            //      是「同一批音频帧在两个 PTS 基准间震荡」。
            //   ② exo 播同一份代理字节流 0 次报错 ⇒ **字节流无罪**，问题在
            //      mpv 侧。曾据此怀疑代理层 PTS 平移误伤音频，**该假设已证伪**。
            //   ③ 差异在缓存模式：mpv 的 `cache` 默认 `auto`，对 HTTP 流走
            //      **分片感知**路径，能正确处理 HLS 分片边界的时间轴重置；
            //      显式写 `yes` 会强制走**通用流缓存**，分片边界的音频/视频
            //      PTS 恒定偏移被当成「流内时间轴跳变」，于是反复来回修正。
            //
            //   鸿蒙版 Player.ets 全程未设这三条（`grep '"cache"'` = 0 次），
            //   故鸿蒙 mpv 从未出现音画不同步 —— 与用户「鸿蒙版 mpv 没有音画
            //   不同步的问题」的观察完全一致。这是铁律 ⅩⅪ 的又一实例。
            //
            //   `demuxer-max-bytes` / `demuxer-max-back-bytes` 保留上限，
            //   但**上限本身不够**：1024MiB 对本工程的码率等于无上限。
            //
            // 🔴🔴🔴 2026-10-16 二次修正（本轮）：上一条注释只解决了「缓存**模式**」，
            //   却把「缓存**限流**」一起删掉了，属过度删除。实测证据：
            //
            //   模拟器 Xiaomi 12S Pro.2026101621 与真机 BA001.2026101621 的
            //   `demuxer-cache-time − time-pos`（缓存领先量）**两台设备都在无限暴涨**：
            //     心跳1  领先 78.9s（模拟器） / 38.0s（真机）
            //     心跳6  领先 351.6s           / 319.2s
            //     心跳10 领先 **578.2s**       / **426.7s**
            //   增速恒定 ≈ **59 秒/3 秒心跳**，即 **约 20 倍实时**。
            //   分片请求日志佐证：21:15:03.690→21:15:04.864 的 **1.2 秒内拉完 14 个分片**
            //   （每分片约 5 秒时长）⇒ demuxer 以远超播放的速度空转预读。
            //
            //   这直接解释了用户本轮的三项症状：
            //     ·「缓冲条会一直缓冲」= 缓存领先 578s，进度条永远显示在缓冲
            //     ·「偶尔跳过一段视频」= 心跳间的 time-pos 跳变 +26.7s
            //     ·「音画不同步 / 卡死只有声音」= 缓存膨胀后 demuxer 与 VO 失步
            //
            //   🔴 关键：`demuxer-max-bytes=1024MiB` 是**容量**上限而非**时长**上限，
            //      对本工程 ~1066kb/s 的源，1024MiB ≈ 8000 秒，等于没有约束。
            //      真正的限流参数是 `cache-secs`（目标缓存时长）与
            //      `demuxer-readahead-secs`（预读时长），二者**必须补回**。
            //
            //   🔴 但**不在此处写死限流值** —— `cache-secs` /
            //      `demuxer-readahead-secs` 改由用户「缓冲模式」档位驱动，
            //      在 `executeOpen` 中按档位下发（与 exo/fvp/VLC/鸿蒙 四后端对齐）。
            //      在此写死会覆盖档位，回到「mpv 无视软件设置」的老问题。
            core!!.setOptionString(handle, "tls-verify", "no") // 兼容非标准/自签 IPTV 源
            // 🔴 安卓 gpu-context 的窗口尺寸，必须显式给定：
            //   纹理路线不会触发 onSurfaceChanged，若不设则 ANativeWindow_getWidth
            //   仍为 0 → vo_android_surface_size() 返回 0 → EGL surface 非法 → 黑屏。
            //   这正是「有解码无画面」的第二个必要条件。
            resolveDisplaySize()
            core!!.setOptionString(handle, "android-surface-size", "${surfaceWidth}x${surfaceHeight}")
            // 🔴🔴 2026-10-15 「真机有声音没画面」根因已确认并修复，日志级别回落到 info。
            //
            //   现象：armeabi-v7a 机顶盒（XiaoPaiTech BA001，Vulkan 1.1.0）播放时
            //     `mpv[vo/gpu-next] error: Failed initializing any suitable GPU context!`
            //     `mpv[cplayer] fatal: Error opening/initializing the selected video_out (--vo) device.`
            //     `mpv[cplayer] info: Video: no video`
            //   音频正常（`AO: [audiotrack] ...`），即「有声音没画面」。点播与直播**同一行失败**。
            //
            //   根因有**两层**，缺一不可：
            //     ① libplacebo 要求 Vulkan ≥ 1.2，而该机顶盒只有 1.1.0
            //        ⇒ `pl_vulkan_choose_device()` 阶段就把设备排除，无 context 可用。
            //        修法见 libplacebo 侧 `PL_VK_MIN_VERSION` 等五处成对改动（降至 1.1）。
            //     ② 🔴 更隐蔽：上面这些 .so 改动**根本没进过包**。
            //        打包读取的是 `android/app/src/main/jniLibs/<abi>/libmpv.so`，
            //        而构建产物落在 `buildscripts/prefix/<abi>/lib/libmpv.so` —— 两个位置
            //        **从未同步**，jniLibs 里那份停留在 10月13日。
            //        ⇒ 必须 `cp prefix/<abi>/lib/libmpv.so jniLibs/<abi>/libmpv.so`。
            //
            //   验证：修复后真机三次播放全部 `[诊断] androidvk 初始化完全成功`，
            //        `Failed initializing any suitable GPU context` 出现 0 次，画面正常。
            //
            //   排障提示：mpv 在 `probing` 阶段会把 `MSGL_ERR` 降级为 `MSGL_V`
            //   （见 `video/out/gpu/context.c` 的 `vo->probing = opts.probing`），
            //   libplacebo 侧 `placebo/utils.c` 的 `probing_map()` 也会把
            //   `PL_LOG_FATAL/ERR/WARN` 一并映射成 `PL_LOG_INFO`。
            //   ⇒ **GPU context 创建失败的真实原因默认是完全静默的**。
            //     日后若再遇同类问题，需临时把此处级别提到 `"v"` 并旁路 `probing_map()`。
            core!!.requestLogMessages(handle, "info")

            // 监听属性。
            //
            // 🔴🔴 2026-10-15 进度条恒 00:00 的真正根因：这里此前写的是**一套自定义
            //   编号**（注释「0=FLAG,1=STRING,2=INT64,3=DOUBLE」），与 mpv 的
            //   `mpv_format` 枚举**完全对不上**。真实枚举（client.h / mpv.def.h）：
            //       MPV_FORMAT_NONE=0, STRING=1, OSD_STRING=2, FLAG=3,
            //       INT64=4, DOUBLE=5, NODE=6, NODE_ARRAY=7, NODE_MAP=8, BYTE_ARRAY=9
            //   于是 time-pos 被注册成 INT64(3)，mpv 回调时 `prop->format` 是 4；
            //   而 JNI 侧 event_thread 判断的是 `prop->format == MPV_FORMAT_DOUBLE`(5)
            //   → 全部不命中 → 每个 PROPERTY_CHANGE 都静默穿过 if-else 链。
            //   现象：push_event 一次都不执行（连守卫日志都没有）→ onMpvEvent 0 次
            //   → Dart 收不到 position/duration → 进度条恒 00:00，且播放页因等不到
            //   「就绪」事件而误报「播放失败，即将进行自动换源」。
            //   legacy 工程一直写的是 5 / 3（正确值），本次移植时被改错。
            //   ⚠️ 改这里必须与 JNI event_thread 里的 format 判断严格对应：
            //      DOUBLE 属性 → 5，FLAG 属性 → 3，STRING 属性 → 1。
            core!!.observeProperty(handle, 1, "time-pos", 5)
            core!!.observeProperty(handle, 2, "duration", 5)
            core!!.observeProperty(handle, 3, "pause", 3)
            core!!.observeProperty(handle, 4, "cache-buffering-state", 5)
            core!!.observeProperty(handle, 5, "volume", 5)
            core!!.observeProperty(handle, 6, "speed", 5)
            core!!.observeProperty(handle, 7, "eof-reached", 3)
            core!!.observeProperty(handle, 8, "demuxer-cache-time", 5)
            core!!.observeProperty(handle, 9, "hwdec-current", 1)
            Log.i(TAG, "mpv 选项就绪 viewId=$viewId（等待纹理 surface 后 initialize）")
        } catch (e: Exception) {
            Log.e(TAG, "mpv 初始化失败 viewId=$viewId: ${e.message}")
        }
    }

    /**
     * 把最终渲染路线写进 mpv 选项。
     *
     * 🔴 必须在 mpv_initialize **之前**调用。mpv 的 VO / GPU 上下文在 initialize 时
     *    创建并按当时的选项定死；initialize 之后再 setPropertyString("gpu-api", ...)
     *    只改属性、不重建 VO，等于没生效。Vulkan 是硬要求，故必须前移。
     *
     * forceOpenGl 来自用户设置（软件设置→其他→强制 OpenGL ES），默认 false；
     * 为 true 时跳过 Vulkan 一律 GLES，作为驱动异常时的兜底。
     */
    private fun applyRendererOptions(forceOpenGl: Boolean) {
        val opts = RendererProbe.rendererOptions(forceOpenGl)
        for ((k, v) in opts) {
            core?.setOptionString(handle, k, v)
        }

        // 🔴🔴 2026-10-15：音画同步配置（必须在 initialize 之前 setOptionString）。
        //
        //   【本段的依据已从「猜测」改为「鸿蒙已验证实现」】
        //
        //   现象：mpv 播放「声音比画面先」，点播出现「调整 → 卡顿 → 快放」。
        //   ⚠️ 注意 `exo` 无此问题，**鸿蒙版 mpv 也无此问题** —— 这条对照
        //      极其关键：同一个 mpv、同一个 bug，鸿蒙版已修好，Android 没修。
        //      故本段**照搬鸿蒙 `Player.ets` 的已验证配置**，不再自行推断。
        //
        //   鸿蒙真机日志判据（当时也是这套报错）：
        //     `mpv[ad] warn: Invalid audio PTS: 1009.812607 -> 1010.300222`
        //     `mpv[cplayer] warn: Audio/Video desynchronisation detected!`
        //     `mpv[cplayer] warn: ... position will not match to the video`
        //
        //   鸿蒙的根因结论（Player.ets L245-266 注释原文）：
        //     原配置 `video-sync=display-resample` 会**把视频时钟锁到显示器
        //     刷新率**，并靠微调音频重采样率去适配。这要求片源帧率与屏幕刷新率
        //     有整齐倍率关系。而移动设备屏幕刷新率固定（60Hz/120Hz），片源帧率
        //     五花八门（电影 24、PAL 25、NTSC 29.97）——倍率不整齐时 mpv 必须
        //     持续微调音频去凑，只要音频 PTS 稍有跳变，重采样器就跟不上，
        //     判定失去同步，表现即「先冻住画面 → 再快放把落后帧追回来」。
        //     `video-sync=audio` 直接以音频时钟为基准放视频、不锁刷新率，
        //     这是 mpv 默认值，也是移动端通行做法。
        //
        //   三处调整（★ = 鸿蒙有、Android 此前缺失）：
        //   ① `video-sync=audio`：以音频为唯一主时钟。显式写出避免被 profile 覆盖。
        //   ② `video-sync-max-video-change` 收紧：默认 5.0 秒允许的「视频时钟
        //      追赶量」过大，等于放任视频先严重落后再一次性快放。收到 1.0 秒，
        //      让 mpv 更早开始用**轻微变速**平滑追赶，而不是攒到必须丢帧的地步。
        //      ⚠️ 这一项是 Android 特有的收紧，鸿蒙未设（鸿蒙靠 ① 已足够）；
        //         保留它不冲突，且对「视频落后」的异常路径更稳。
        //   ③ ★ `profile=fast`：🔴 补齐鸿蒙 L200 的配置。
        //      上一版以为它管同步 —— **错了**。查 `etc/builtin.conf` 的
        //      `[fast]` 段可见它只关昂贵的 GPU 缩放滤镜：
        //        scale=bilinear / dscale=bilinear / dither=no /
        //        correct-downscaling=no / linear-downscaling=no /
        //        sigmoid-upscaling=no / hdr-compute-peak=no
        //      作用是把 GPU 负载降下来，让**视频帧不被渲染阻塞**，
        //      从而有时间被按时上屏 —— 这才是它对同步的间接贡献。
        //      ⚠️ 同时它还会设 `framedrop=no` 与 `osc=no`（见该文件 L40-42）。
        //
        //   ⚠️ 这三项对「本来就正常」的设备基本无副作用：
        //      ① 是 mpv 默认值；② 只在视频落后时介入；③ 只降画质滤镜档位。
        core?.setOptionString(handle, "video-sync", "audio")
        core?.setOptionString(handle, "video-sync-max-video-change", "1.0")
        // ③ 对齐鸿蒙（Player.ets L200 `setOptionString("profile", "fast")`）。
        core?.setOptionString(handle, "profile", "fast")
        // ④ 对齐鸿蒙（Player.ets L272 `interpolation=no`）。
        //    interpolation 原本是配 display-resample 用的（靠插帧把重采样后的帧
        //    补回刷新节奏）。既然已改用 video-sync=audio、不锁刷新率，
        //    插帧既无意义又徒增 GPU 负载 —— 必须关掉，否则等于把 ③ 省下的
        //    GPU 开销又花回去。
        core?.setOptionString(handle, "interpolation", "no")

        // 🔴🔴 2026-10-16 修复「播放时跳帧 / 卡一下快放一下」：显式开启 framedrop。
        //
        //   根因：mpv `etc/builtin.conf` 的 **`[default]` 段 L42** 写着
        //     `framedrop=no`
        //   —— 注意它在 `[default]` 而非 `[fast]`，即**全局默认值**。
        //   也就是说本工程从未开启过 framedrop，播放器一直处在
        //   「宁可让迟到的帧照样上屏，也绝不丢帧」的模式。
        //
        //   对**实时流**（IPTV 直播 + 被本地代理重写的点播）这是最差组合：
        //   数据源源不断、时钟只进不退，某帧解码/渲染一慢就必然迟到，
        //   迟到即堆积，堆积到阈值就触发 video-sync 一次性快放追帧。
        //   用户观感 = 「跳帧」+「卡一下快放一下」，与描述逐字对应。
        //
        //   官方 DOCS/man/options.rst:1205-1222 给出定性与解法：
        //     <no>  "Disable any frame dropping. **Not recommended, for
        //            testing only.**"
        //     <vo>  "Drop late frames on video output (default). ...
        //            **In audio sync. mode, this drops frames that are
        //            outdated at the time of display.**"
        //   我们用的正是 `video-sync=audio`（L500），故 `vo` 就是为它设计的
        //   配对档位：精确丢弃「显示时刻已过期」的帧，而非让其迟到堆积。
        //   且该档位有兜底 —— 解码器过慢时持续丢帧，但**有效帧率跌破
        //   10 FPS 即停止丢帧**，不会把画面丢成幻灯片。
        //
        //   ⚠️ 必须写在 `profile=fast`（L503）**之后**：mpv 同名选项后者生效，
        //      这样既保留 fast 的降负载收益，又覆盖掉它带来的 framedrop=no。
        //   ⚠️ 不可用 `decoder`/`decoder+vo` 档位：那会连**解码**都跳过，
        //      在丢帧时可能破坏参考帧链，导致花屏。
        core?.setOptionString(handle, "framedrop", "vo")

        // 🔴🔴 2026-10-15 回滚：曾设 `audio-buffer=0.5`，**已删除**。
        //
        //   删除理由（mpv 官方 DOCS/man/options.rst 原文）：
        //     「Set the audio output minimum buffer. ... Making this larger may
        //       make soft-volume and other filters react slower, **introduce
        //       additional issues on playback speed change**, and block the
        //       player on audio format changes. A smaller buffer might lead to
        //       audio dropouts.
        //       ⚠️ This option should be used for testing only. If a
        //       non-default value helps significantly, the mpv developers
        //       should be contacted.」
        //   默认值是 **0.2 秒**（audio/out/ao.c:158 `.audio_buffer = 0.2`），
        //   上游明确标注「仅用于测试」，且**默认值就是调优过的值**。
        //
        //   实测后果（⚠️ 数据来自**雷电模拟器**，非真机）：
        //     VO 就绪 21:53:38.979 → 声卡真正出声 21:53:40.942（+1.96s）
        //   而与此同时 mpv 内部 `avsync` 恒为 16 微秒、`speed` 恒为 1.0、
        //   丢帧 0 —— 即「mpv 认为同步良好，但用户听到声音滞后」。
        //
        //   ⚠️ 但模拟器的 `audio_hw_hal` 是虚拟声卡，其输出延迟本身就不可信，
        //      所以上述 1.96 秒**不能**单独归因于 audio-buffer。删除该参数的
        //      真正理由是下面这条铁律，而不是「它被证明是元凶」。
        //
        //   ⚠️ 铁律：**不为「预防」引入上游没有的机制**（见 worklog）。
        //      上一轮加这个参数是为了预防软解抢 CPU 导致 underrun，
        //      但日志里**从未出现过 underrun**，属于无证据的预防性改动。
        //      且上游明确标注「仅用于测试」，故直接删除、回到默认，
        //      不做「改成 0.3」这类折中。

        Log.i(TAG, "渲染路线已定 viewId=$viewId forceOpenGl=$forceOpenGl 选项=$opts 设备=${RendererProbe.summary()}")
    }

    /**
     * Surface 就绪：attach 为 wid（必须在 initialize 之前），随后 initialize。
     */
    private fun onSurfaceReady(surface: Surface) {
        if (disposed) return
        currentSurface = surface
        try {
            core?.attachSurface(handle, surface)
            if (!initialized) {
                // 🔴 渲染路线必须在 initialize 之前落地（否则 gpu-api 改了也不生效）。
                applyRendererOptions(forceOpenGl)
                core?.initialize(handle)
                initialized = true
                Log.i(TAG, "surface 已 attach 为 wid + mpv 已 initialize viewId=$viewId")
                flushPendingOpen()
            } else {
                Log.i(TAG, "surface 已更新（运行时重挂）viewId=$viewId")
            }
        } catch (e: Exception) {
            Log.e(TAG, "attachSurface 失败 viewId=$viewId: ${e.message}")
        }
    }

    // ── TextureRegistry.SurfaceProducer.Callback ────────────────────────────
    override fun onSurfaceCreated() {
        Log.i(TAG, "SurfaceProducer.onSurfaceCreated viewId=$viewId")
    }

    override fun onSurfaceAvailable() {
        Log.i(TAG, "SurfaceProducer.onSurfaceAvailable viewId=$viewId")
        val producer = surfaceProducer ?: return
        if (surfaceWidth <= 0 || surfaceHeight <= 0) resolveDisplaySize()
        try {
            producer.setSize(surfaceWidth, surfaceHeight)
        } catch (_: Exception) {
        }
        val s = try {
            producer.surface
        } catch (_: Exception) {
            null
        }
        if (s != null && s.isValid) onSurfaceReady(s)
    }

    override fun onSurfaceDestroyed() {
        Log.i(TAG, "SurfaceProducer.onSurfaceDestroyed viewId=$viewId")
        currentSurface = null
        try {
            core?.detachSurface(handle)
        } catch (_: Exception) {
        }
    }

    override fun onSurfaceCleanup() {
        Log.i(TAG, "SurfaceProducer.onSurfaceCleanup viewId=$viewId")
    }

    /** 由 JNI 事件线程回调（C 侧 property change）。isDouble=false 表示 0/1 整型值。 */
    @Suppress("unused")
    fun onMpvEvent(name: String, value: Double, isDouble: Boolean) {
        // 🔴 诊断（2026-10-15）：点播进度条恒为 00:00，必须确认属性回调是否真的到达。
        //    viewId 一并打出，用于排查「事件打到别的 view」。
        if (name != "time-pos" || (System.currentTimeMillis() % 2000 < 100)) {
            Log.i(TAG, "onMpvEvent viewId=$viewId name=$name value=$value sink=${eventSink != null} disposed=$disposed")
        }
        when (name) {
            "time-pos" -> {
                positionSec = value
                // 🔴🔴 2026-10-16 起播精确定位（二次修复）：**必须等 time-pos 有效后才补 seek**。
                //
                //   首版把补 seek 直接放在 file-loaded 分支里，实测（模拟器 22:31:59）：
                //     22:31:59.119 起播精确定位 目标=1180000ms 当前=0.000s → 补 seek absolute
                //     22:31:59.322 心跳 time-pos=1180.000   ← 看似生效
                //     22:32:02.322 心跳 time-pos=1207.400   ← 仍前跳 ~27s ❌
                //   原因：file-loaded 到达时 `time-pos` 属性**还不存在**（读出 0.0），
                //   seek 打在一个尚未建立的时间轴上，mpv 随后仍按自己的节奏重新定位，
                //   起播暂态照旧出现。positionSec 也是 0，日志里的「偏差 -1180s」是假值。
                //
                //   故改为：file-loaded 只**登记**目标，真正的 seek 推迟到首个有效
                //   time-pos（>0）到达时执行 —— 此时 demuxer 时间轴已就绪，能钉死位置。
                // 记录「已见到首个有效值」，供下一次回调起算稳定期
                val wasFirstValid = !firstValidTimePosSeen
                if (value > 0.0 && wasFirstValid) {
                    firstValidTimePosSeen = true
                    firstValidTimePosAtMs = System.currentTimeMillis()
                }
                // 🔴 稳定期 = 「首个有效值之后又收到了一次回调」或「距首个有效值已超 150ms」。
                //   time-pos 订阅间隔是 5ms（observeProperty(handle, 1, "time-pos", 5)），
                //   正常情况 10ms 内就满足；150ms 上限是兜底，防止某些源推送稀疏时
                //   迟迟不下发 seek 而从头播放。
                val stableEnough = firstValidTimePosSeen &&
                    (!wasFirstValid || System.currentTimeMillis() - firstValidTimePosAtMs >= 150L)
                if (value > 0.0 && !pendingSeekDone && !userSeeked && pendingSeekTargetMs > 0 && stableEnough) {
                    pendingSeekDone = true
                    val target = pendingSeekTargetMs
                    val drift = value - target / 1000.0
                    // 🔴🔴 2026-10-17：首个 time-pos **可能就是 `start=` 的回显**，
                    //   不是真实解码位置，绝不能据此判断"已经到位、无需补 seek"。
                    //
                    //   真机证据（XiaoPaiTech BA001 2026101719，源2，目标 243.796s）：
                    //     19:55:20.375 file-loaded value=243796.0
                    //     19:55:20.395 目标=243796ms 当前=243.796s 偏差=0.000s
                    //                  → 判"无需 seek"（此处旧代码若加 skip 判断会跳过）
                    //     19:55:21.476 心跳 time-pos=105.579   ← mpv 实际落到了片头边界
                    //   即 243.796 只是 start= 的回显；mpv 随后按自己的 HLS 逻辑
                    //   落在了最近分片边界（105.579 = 片头段结束处）才真正开始解码。
                    //
                    //   故：**无条件**下发 seek（幂等地钉死位置），只在日志里记录偏差
                    //   供取证。重复 seek 到同一位置是安全的 —— mpv 会做 seek
                    //   去重/快速返回，不会造成黑屏或额外抖动。
                    Log.i(
                        TAG,
                        "起播精确定位 viewId=$viewId 目标=${target}ms 当前=${"%.3f".format(value)}s " +
                            "偏差=${"%.3f".format(drift)}s → 补 seek absolute" +
                            (if (kotlin.math.abs(drift) < 0.5) "（当前值疑似 start= 回显，仍强制 seek）" else "")
                    )
                    // 🔴 command 现在返回 mpv 错误码（0=成功）。必须记下来：
                    //   这是区分「seek 没打进去」与「打进去了但 mpv 没执行」的唯一手段。
                    //   真机 19:55:20.395 补 seek 后心跳仍是 105.579，当时无法判断是哪一种。
                    val seekRc = core?.command(
                        handle, arrayOf("seek", "${target / 1000.0}", "absolute")
                    ) ?: -1
                    if (seekRc != 0) {
                        Log.w(TAG, "起播精确定位 seek 失败 viewId=$viewId rc=$seekRc target=${target}ms")
                    }
                    // 🔴🔴 seek 下发 ≠ seek 生效。mpv 对 HLS 的绝对 seek 会先落到
                    //   最近分片边界，若该边界不对，实际播放位置会与目标差出整整一段
                    //   （真机源2：目标 243.796s，实际落在 105.579s = 片头段结束边界）。
                    //   这里登记「待校验」，由 time-pos 回调在后续若干帧里核对；
                    //   未命中则**重试一次** seek，并留下明确日志。
                    pendingSeekVerifyTargetMs = target
                    pendingSeekVerifyDeadlineMs = System.currentTimeMillis() + 2500
                    pendingSeekRetried = false
                    pendingSeekTargetMs = 0L
                }
                // 🔴🔴 2026-10-17 起播 seek 落地校验（**必须**在本分支内，不能另起
                //   一个 "time-pos" -> 分支：when 里重复的 key 只会执行第一个）。
                //   判定逻辑已抽到 tryResolveSeekVerify()：因判据需要
                //   `demuxer-cache-time`（另一个事件）与 `time-pos` 同时成立，
                //   两个事件到达时都要调用一次。
                tryResolveSeekVerify(value)
            }
            "duration" -> durationSec = value

            "pause" -> {
                val paused = (value != 0.0)
                playing = !paused
                buffering = false
            }
            "cache-buffering-state" -> {
                buffering = value > 0.0
            }
            "volume" -> volume = value / 100.0
            "speed" -> speed = value
            "eof-reached" -> eof = (value != 0.0)
            "demuxer-cache-time" -> {
                bufferSec = value
                // 🔴🔴 这是起播 seek 落地校验的**物理判据**来源。
                //   本事件与 "time-pos" 是两条独立的回调流，谁先到不一定，
                //   因此两侧都要触发一次判定。详见 tryResolveSeekVerify()。
                latestCacheSec = value
                tryResolveSeekVerify(positionSec)
            }
            // 🔴🔴 2026-10-16 起播精确定位：FILE_LOADED 时**只登记目标**，不在此 seek。
            //   JNI 侧把 pending_seek_ms（期望起播毫秒）作为 value 传进来。
            //   真正的 seek 交由 "time-pos" 分支在首个有效位置到达时执行
            //   （file-loaded 时 time-pos 尚未建立，此处 seek 会打在空时间轴上，实测无效）。
            "file-loaded" -> {
                val target = value.toLong()
                if (target > 0 && !pendingSeekDone && !userSeeked) {
                    // 🔴🔴🔴 2026-10-18：**立即下发** seek，不再等首个 time-pos。
                    //
                    //   原设计（10-16）是「file-loaded 只登记，等首个有效
                    //   time-pos 再 seek」，理由是「file-loaded 时 time-pos
                    //   尚未建立，seek 会打在空时间轴上」。
                    //
                    //   真机反证（XiaoPaiTech BA001 2026101816）：
                    //     16:27:40.588 file-loaded value=317000.0
                    //     16:27:40.589 已登记目标=317000ms，等待 time-pos 有效后补 seek
                    //     16:27:41.790 心跳 time-pos=105.579  ← 卡在片头段结束处
                    //     16:27:44.791 心跳 time-pos=317.000  ← 3 秒后才到位
                    //   mpv 起播阶段长时间不推 time-pos（首个可见事件晚了 5.4s），
                    //   于是「等 time-pos」= 让用户先看 5 秒片头 —— 这正是
                    //   用户说的「先跳开头，再到播放记录」。
                    //
                    //   改为：file-loaded 立即 seek 一次，随后由
                    //   tryResolveSeekVerify() 用双判据校验并重试兜底。
                    //   即使这一次因未初始化失败（-12），校验的 deadline
                    //   到期也会重试；最坏情况不比原方案差。
                    pendingSeekTargetMs = target
                    val rc = core?.command(
                        handle, arrayOf("seek", "${target / 1000.0}", "absolute")
                    ) ?: -1
                    Log.i(
                        TAG,
                        "起播精确定位 viewId=$viewId 已登记目标=${target}ms " +
                            "→ file-loaded 立即 seek rc=$rc（不再等 time-pos）"
                    )
                    // 无论 rc 如何都登记校验：成功则确认落地，失败则重试。
                    if (rc == 0) {
                        pendingSeekDone = true
                        pendingSeekVerifyTargetMs = target
                        pendingSeekVerifyDeadlineMs =
                            System.currentTimeMillis() + 2500
                        pendingSeekRetried = false
                    }
                } else {
                    Log.i(
                        TAG,
                        "起播精确定位跳过 viewId=$viewId target=$target " +
                            "pendingSeekDone=$pendingSeekDone userSeeked=$userSeeked"
                    )
                }
            }
            // 🔴 诊断埋点（2026-10-15）：hwdec-current 的**实时变更**。
            //   这是硬解在运行途中掉链子的唯一直接证据 —— 启动时探针（open 后
            //   1.5s 回读）只能证明「起步那一刻」的状态，而「播放一阵子后卡死」
            //   要看的恰恰是**中途**有没有从硬解掉回软解。
            //   属性是 STRING 型（observeProperty 传的 format=1），JNI 侧把它
            //   按值回调进来，故这里 value 是 Double、需要靠 isDouble=false 区分
            //   （STRING 型走的是另一条 push 路径，见 JNI event_thread）。
            "hwdec-current" -> {
                Log.i(
                    TAG,
                    "hwdec-current 变更 viewId=$viewId value=$value isDouble=$isDouble"
                )
            }
        }
        // 🔴🔴 2026-10-15 点播进度条恒为 00:00 的根因修复：
        //   本方法由 **mpv 事件线程**（native pthread）经 JNI CallVoidMethod 调用，
        //   而 pushState() 最终走 Flutter 的 EventChannel.EventSink.success()。
        //   Flutter 的 PlatformChannel 序列化 / BinaryMessenger 必须跑在**平台主线程**上，
        //   在非主线程调用 sink.success() 不会抛错也不会送达 —— 事件被静默丢弃。
        //   这正好解释了现象：纹理能出画（pushTextureId 是主线程调的），
        //   但 position/duration 永远不更新（onMpvEvent 是事件线程调的）。
        //   故此处统一切回主线程推送；已在主线程时直接推送，避免无谓的 post 延迟。
        if (Looper.myLooper() == Looper.getMainLooper()) {
            pushState()
        } else {
            mainHandler.post { pushState() }
        }
    }

    /**
     * 起播 seek 落地校验 —— 双判据（物理量 + 播放头）。
     *
     * 🔴🔴🔴 为什么必须是双判据：
     *   - `time-pos` 是 mpv 的**自报量**：`start=` 回显、seek 请求的暂态值、
     *     以及「数据还没下到那儿就先报告到了」都会让它看起来像已落地。
     *     真机证据（XiaoPaiTech BA001 2026101719 源2）：目标 243.796s，
     *     `time-pos` 首帧就报 243.796，但随后心跳跌到 105.579s ——
     *     243.796 只是回显，播放头其实卡在片头段边界。
     *   - `demuxer-cache-time` 是**已下载并缓存到的位置**，物理量，无法伪造。
     *     它与 exo 的 `buffered.last.end` 同义（MediaKit 的 buffer 流就是它）。
     *
     *   只满足 time-pos ⇒ 可能是回显/暂态 ⇒ 不算落地。
     *   两者同时满足 ⇒ 数据真到位 + 播放头真在目标处 ⇒ 才算落地。
     *
     * 由于两值来自不同事件回调，本方法在两个分支里都会被调用，
     * 内部依靠 pendingSeekVerifyTargetMs == 0 做幂等，重复调用安全。
     *
     * @param timePosSec 最新 time-pos（秒）；<= 0 视为尚无有效播放头
     */
    private fun tryResolveSeekVerify(timePosSec: Double) {
        if (pendingSeekVerifyTargetMs <= 0) return
        val t = pendingSeekVerifyTargetMs
        val targetSec = t / 1000.0
        val posOk = timePosSec > 0.0 && kotlin.math.abs(timePosSec - targetSec) <= 1.5
        // 🔴 cacheOk 的语义是「**不否定**」而非「必须证明」：
        //   ① cache 从未推送（latestCacheSec < 0）⇒ 无力证伪，退回原单判据，
        //      绝不能因为拿不到数据就把一次成功定位误判成失败。
        //      真机实测：第三次 open 的首个 demuxer-cache-time 晚了 17 秒，
        //      若硬性要求必然全部超时重试，反而制造新的假阴性。
        //   ② cache 有值 ⇒ 严格要求它已越过目标（容 1.5s）。
        //      真机实测（换到 mpv）：目标 279.469s，time-pos 自报已到位，
        //      而 demuxer-cache-time 只有 91.8s ⇒ 判否，抓的正是回显假阳性。
        //   二者不对称是有意的：**宁可放过，不可错杀**。
        val cacheSeen = latestCacheSec >= 0.0
        val cacheOk = !cacheSeen || latestCacheSec >= targetSec - 1.5
        val now = System.currentTimeMillis()

        if (posOk && cacheOk) {
            Log.i(
                TAG,
                "起播 seek 已落地 viewId=$viewId target=${t}ms " +
                    "pos=${"%.3f".format(timePosSec)}s cache=${"%.3f".format(latestCacheSec)}s（双判据通过）"
            )
            pendingSeekVerifyTargetMs = 0L
            return
        }
        if (now <= pendingSeekVerifyDeadlineMs) return

        if (!pendingSeekRetried) {
            pendingSeekRetried = true
            Log.w(
                TAG,
                "⚠️ 起播 seek 未落地 viewId=$viewId target=${t}ms " +
                    "pos=${"%.3f".format(timePosSec)}s " +
                    "cache=${"%.3f".format(latestCacheSec)}s " +
                    "偏差=${"%.1f".format(timePosSec - targetSec)}s " +
                    "posOk=$posOk cacheOk=$cacheOk cacheSeen=$cacheSeen → 重试 seek"
            )
            core?.command(handle, arrayOf("seek", targetSec.toString(), "absolute"))
            pendingSeekVerifyDeadlineMs = System.currentTimeMillis() + 2500
        } else {
            Log.e(
                TAG,
                "❌ 起播 seek 重试后仍未落地 viewId=$viewId target=${t}ms " +
                    "pos=${"%.3f".format(timePosSec)}s " +
                    "cache=${"%.3f".format(latestCacheSec)}s " +
                    "posOk=$posOk cacheOk=$cacheOk cacheSeen=$cacheSeen（mpv 对该源无法精确定位）"
            )
            pendingSeekVerifyTargetMs = 0L
        }
    }

    /** 纹理路线：把 textureId 作为事件通道首条消息推回 Dart。 */
    private fun pushTextureId() {
        val producer = surfaceProducer ?: return
        val tid = try {
            producer.id()
        } catch (_: Exception) {
            -1L
        }
        if (tid < 0) return
        Log.i(TAG, "推送 textureId=$tid viewId=$viewId 尺寸=${surfaceWidth}x${surfaceHeight}")
        eventSink?.success(mapOf("type" to "texture", "textureId" to tid))
    }

    fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        if (disposed) {
            result.error("DISPOSED", "mpv view disposed", null)
            return
        }
        try {
            when (call.method) {
                "open" -> {
                    val args = mapOf(
                        "url" to (call.argument<String>("url") ?: ""),
                        // Dart 侧 startAtMs 是 int（StandardMessageCodec 编成 Integer/Long），
                        // 用 Number 收再转 Long；按 Double 收会拿到 null，
                        // 导致续播定位的 start= 被静默丢弃。
                        "startAtMs" to (call.argument<Number>("startAtMs")?.toLong() ?: 0L),
                        "headers" to call.argument<Map<String, String>>("headers"),
                        "hardwareDecoding" to (call.argument<Boolean>("hardwareDecoding") ?: true),
                        "isLive" to (call.argument<Boolean>("isLive") ?: false),
                        // 缓冲档位（秒）。由 Dart 侧从 BufferProfileConfig.exoMaxBufferMs
                        // 换算下发，见 executeOpen 中的档位映射说明。
                        "cacheSecs" to (call.argument<Number>("cacheSecs")?.toInt() ?: 0)
                    )
                    if (!initialized) {
                        // 🔴 surface 尚未就绪、mpv 未 initialize：此时下发 loadfile
                        //    会被 mpv 以 -3（core not initialized）拒绝，播放静默失败。
                        //    暂存，等 onSurfaceReady → initialize 后由 flushPendingOpen 补发。
                        Log.i(TAG, "open 早于 surface 就绪，暂存 viewId=$viewId url=${args["url"]}")
                        pendingOpen = args
                    } else {
                        executeOpen(args)
                    }
                    result.success(null)
                }
                "play" -> {
                    core?.setPropertyString(handle, "pause", "no")
                    result.success(null)
                }
                "pause" -> {
                    core?.setPropertyString(handle, "pause", "yes")
                    result.success(null)
                }
                "seek" -> {
                    val posSec = call.argument<Double>("positionSec") ?: 0.0
                    // 🔴🔴 2026-10-17：只有**命令成功**才置 userSeeked。
                    //
                    //   现场证据（真机 XiaoPaiTech BA001 2026101713）：
                    //     13:08:43.097  HeinPlayMpvJni: command err=-12 (error running command)
                    //     13:08:48.180  起播精确定位跳过 viewId=1 target=319146
                    //                   pendingSeekDone=false userSeeked=true
                    //   此时 mpv 还在加载中（未 file-loaded），seek 命令失败（err=-12），
                    //   但旧代码**在发命令之前**就把 userSeeked 置成了 true。
                    //   于是换源时 startAt=0:05:19.146 的精确定位被整个跳过 ⇒
                    //   播放器停在 0s 从头播 ⇒ 用户看到「换源读到播放记录又跳回从头」。
                    //
                    //   修法：先发命令、看返回值，成功才置位。命令失败时保持
                    //   userSeeked=false，起播精确定位仍能在 time-pos 有效后补 seek。
                    val rc = core?.command(handle, arrayOf("seek", "$posSec", "absolute")) ?: -1
                    if (rc == 0) {
                        // 用户已手动 seek，起播精确定位不再补 seek，
                        // 否则会把用户拖回起播点（见 onMpvEvent 的 "file-loaded"）。
                        userSeeked = true
                    } else {
                        android.util.Log.w(
                            "HeinPlayMpv",
                            "seek 命令失败 err=$rc pos=${posSec}s，不置 userSeeked（保留起播精确定位）"
                        )
                    }
                    result.success(null)
                }
                "setVolume" -> {
                    val v = call.argument<Double>("volume") ?: 1.0
                    core?.setPropertyString(handle, "volume", "${v * 100.0}")
                    result.success(null)
                }
                "setSpeed" -> {
                    val sp = call.argument<Double>("rate") ?: 1.0
                    core?.setPropertyString(handle, "speed", "$sp")
                    result.success(null)
                }
                "setFit" -> {
                    // BoxFit → mpv 显示比例（与 legacy 工程逐行对齐）：
                    //   contain（原始比例）：保持宽高比 + 不裁剪 —— 默认
                    //   cover（填充）      ：保持宽高比 + panscan 拉满（裁边）
                    //   fill（拉伸）       ：不保持宽高比，直接铺满
                    //
                    // 🔴 2026-10-15 点播画面左右拉伸的根因：主工程移植时**整条
                    //    缩放控制链路丢失** —— Kotlin 没有 setFit 分支、Dart
                    //    MpvBackend 没有 setFit 方法，而摆放纹理的 FittedBox 又用
                    //    一个写死且从未更新的 1920x1080 去二次缩放。
                    //    两条错误叠加：mpv 把视频铺满 2560x1600 的 Surface（拉伸
                    //    第一次），Dart 再按 16:9 贴合（缩放第二次）。
                    //    exo 之所以比例正确，是因为它走 SurfaceView 直出，由
                    //    SurfaceFlinger/HWC 按视频真实宽高比合成，根本不经过
                    //    Flutter 这一层。
                    //    修法：Dart 侧去掉 FittedBox 与写死尺寸（裸 Texture 铺满，
                    //    与 legacy 一致），比例交由 mpv 按自身 video-params 计算；
                    //    本分支承接前端 _videoFit 的三态切换。
                    when (call.argument<String>("fit")) {
                        "cover" -> {
                            core?.setPropertyString(handle, "keepaspect", "yes")
                            core?.setPropertyString(handle, "panscan", "1.0")
                        }
                        "fill" -> {
                            core?.setPropertyString(handle, "keepaspect", "no")
                            core?.setPropertyString(handle, "panscan", "0")
                        }
                        else -> {
                            core?.setPropertyString(handle, "keepaspect", "yes")
                            core?.setPropertyString(handle, "panscan", "0")
                        }
                    }
                    result.success(null)
                }
                "dispose" -> {
                    dispose()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("MPV_ERROR", "${e.message}", null)
        }
    }

    /** 状态推送：由 JNI 属性回调触发。 */
    fun pushState() {
        if (eventSink == null || disposed) return
        val payload = mapOf(
            "positionSec" to positionSec,
            "durationSec" to durationSec,
            "playing" to playing,
            "buffering" to buffering,
            "volume" to volume,
            "speed" to speed,
            "eof" to eof,
            "buffer" to bufferSec
        )
        eventSink?.success(payload)
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        // 🔴 事件通道就绪后立刻补推 textureId：Dart 侧靠它拿到 Flutter 纹理 id
        //    才能构建 Texture(textureId)。纹理在这一刻早已就绪（构造期就建好了），
        //    若不在 onListen 时补推，Dart 将永远等不到首条消息 → 黑屏。
        pushTextureId()
        pushState()
    }

    /** 补发 initialize 之前暂存的 open 请求。 */
    private fun flushPendingOpen() {
        val pending = pendingOpen ?: return
        pendingOpen = null
        Log.i(TAG, "补发暂存的 open viewId=$viewId url=${pending["url"]}")
        executeOpen(pending)
    }

    /**
     * 真正下发 loadfile。
     * 🔴 必须在 mpv_initialize 之后调用：mpv 未 initialize 时 mpv_command 直接
     *    返回 -3（core not initialized），不报错也不播放，表现为「点了没反应」。
     *    故 handleMethod 的 open 分支只在 initialized 时直调，否则暂存、
     *    等 onSurfaceReady → initialize 后由 flushPendingOpen 补发。
     */
    private fun executeOpen(args: Map<String, Any?>) {
        val url = args["url"] as? String ?: ""
        val startAtMs = (args["startAtMs"] as? Number)?.toLong() ?: 0L
        @Suppress("UNCHECKED_CAST")
        val headers = args["headers"] as? Map<String, String>
        val hardwareDecoding = args["hardwareDecoding"] as? Boolean ?: true
        val isLive = args["isLive"] as? Boolean ?: false

        // 🔴 2026-10-16：每次 open 复位起播定位的三个状态（见 "file-loaded"/"time-pos" 分支）。
        pendingSeekTargetMs = 0L
        pendingSeekDone = false
        firstValidTimePosSeen = false
        firstValidTimePosAtMs = 0L
        // 🔴 2026-10-17：落地校验的双判据状态也要复位。
        //   latestCacheSec 置 -1 表示「尚无有效缓存位置」，避免上一次 open
        //   残留的大值让本轮 cacheOk 立刻成立（跨源误判）。
        pendingSeekVerifyTargetMs = 0L
        pendingSeekVerifyDeadlineMs = 0L
        pendingSeekRetried = false
        latestCacheSec = -1.0
        userSeeked = false

        // ⚠️ 软解回退必须与 hwdec 一起下发，不能全局写死 no。
        // mpv 源码 vd_lavc.c：只要 hwdec=no（用户显式要软解），use_hwdec
        // 恒为 false，同样落入 else 分支；此时若 software_fallback == INT_MAX
        // （即 no），mpv 判定「软解回退被禁用」并置 ctx->force_eof = true，
        // 结果是**纯软解也出不了画，只有声音**。
        //
        // 🔴 2026-10-15：真机日志实证了这个陷阱 ——
        //   `mpv[vd] warn: Software decoding fallback is disabled.`
        //   本轮直接导致「有解码、无画面」。故一律允许回退。
        //
        // 🔴 2026-10-07 修正：**直播固定软解**。
        //   曾让直播也走 mediacodec-copy 硬解，真机实测直播画面全绿
        //   （点播同参数正常）。直播软解一直正常出画，且直播没有
        //   「硬件解码」开关，用户无从规避，故直播一律 hwdec=no。
        //
        // ⚠️ 必须用 **mediacodec-copy**（而不是 mediacodec）：零拷贝模式会把
        //   解码器输出直接绑到解码器自建的 Surface，Amlogic 驱动判定该
        //   Surface 的 consumer 是 GL 且不用 HWC，于是走「Use OSD layer」分支，
        //   把输出 buffer 上限硬卡在 14；而 ACodec 最小只退到 16，永远降不到 14
        //   → `4kosd set output error, newBufferCount 16 > 14`
        //   → OMX_ErrorInsufficientResources(-1010) → 硬解 100% 失败。
        //   mediacodec-copy 走 ffmpeg 拷贝变体：创建**不带 Surface** 的 mediacodec
        //   device（mc_device_init 无 surface 时直接返回 0），解码器改用 ByteBuffer
        //   输出，根本不进 OSD 分支 → 绕开上限 14。代价是多一次拷帧，
        //   但解码仍是硬件解码器，**不是软解回退**。
        val useHardware = !isLive && hardwareDecoding
        val allowSoftwareFallback = true

        // 🔴🔴 2026-10-16 新增：把软件的「缓冲模式」档位下发到 mpv 的运行期缓存。
        //
        //   背景：`BufferProfileConfig` 里 exo / fvp / VLC / 鸿蒙 AVPlayer **四个后端
        //   全部由用户档位推导参数**，唯独 mpv 一路写死常量 —— 用户在设置里
        //   切「标准/增强/强力/低延迟」时，mpv 完全无感。这既是行为不一致，
        //   也是本轮「缓冲条一直缓冲」的直接成因：
        //     实测两台设备的 `demuxer-cache-time − time-pos` 无限暴涨
        //       （模拟器 578s / 真机 426s，约 20 倍实时），
        //     根因是 `demuxer-max-bytes=1024MiB` **只是容量上限不是时长上限**
        //       —— 对本工程 ~1066kb/s 的源，1024MiB ≈ 8000 秒，等于没有约束。
        //   真正的时长约束是 `cache-secs` / `demuxer-readahead-secs`，必须由
        //   档位驱动，与其它后端对齐。
        //
        //   档位映射：直接取 `exoMaxBufferMs`（与 avpBufferMb 的换算依据同源，
        //   即「1 秒 ≈ 1MB」的设计基线），保持各档位在 mpv 上语义一致：
        //     标准 30s / 增强 60s / 强力 120s / 低延迟 5s
        //   `cacheSecs <= 0` 视为「不限制」，此时不下发、交由 mpv 默认。
        //
        //   ⚠️ 必须在 `loadfile` **之前**下发：这两条是 demuxer 尺寸类选项，
        //      mpv 对同源后续请求才会重读；开播后再设只影响下一段。
        //   ⚠️ 直播单独收紧（见下方 isLive 分支）：直播的价值在「跟手」，
        //      大缓冲会直接把画面推到几十秒后，故直播固定取低延迟档。
        val cacheSecsFromProfile = (args["cacheSecs"] as? Number)?.toInt() ?: 0
        val effectiveCacheSecs = if (isLive) {
            5 // 直播固定低延迟，忽略档位（与 exo 直播路径一致）
        } else {
            cacheSecsFromProfile
        }
        if (effectiveCacheSecs > 0) {
            core?.setOptionString(handle, "cache-secs", "$effectiveCacheSecs")
            core?.setOptionString(handle, "demuxer-readahead-secs", "$effectiveCacheSecs")
            Log.i(
                TAG,
                "缓冲档位下发 cache-secs=$effectiveCacheSecs " +
                    "(档位值=$cacheSecsFromProfile isLive=$isLive)"
            )
        }

        // 🔴 Vulkan 优先（用户硬要求）。
        // 内核同时带 Vulkan 与 GLES 两个后端，运行时用 gpu-api 二选一。
        //
        // ⚠️ 渲染路线（vo/gpu-context/gpu-api）不在这里设 —— mpv 的 VO 在
        //    mpv_initialize 时就按当时的选项创建好了，此处再改属性不会重建 VO，
        //    纯属无效操作。真正的设定点是 onSurfaceReady → applyRendererOptions()，
        //    即 initialize 之前。这里只读探测结果用于日志与 hwdec 取值。
        val useVulkan = !forceOpenGl && RendererProbe.capability().vulkanUsable
        val gpuApi = if (useVulkan) "vulkan" else "opengl"

        // hwdec 的取值与渲染后端相关：
        //  · Vulkan：官方 mpv-android 走 mediacodec 零拷贝（AHardwareBuffer 作为
        //    VkImage 导入，libplacebo 直接消费，省一次拷贝）。
        //  · GLES  ：用 mediacodec-copy 绕开 Amlogic 的 OSD buffer 上限 14。
        //
        // ⚠️ 给出逗号链让 mpv 自行降级（对齐官方 MPVView 的候选列表写法）：
        //    某条硬解在特定驱动上失败时，mpv 会自动退到下一条，最终退软解，
        //    而不是整条路直接死掉。software-fallback 同步放开。
        //
        // 🔴🔴 2026-10-15 修正（音画不同步根因）：
        //   设备日志实证 —— mpv 打出 `Using hardware decoding (mediacodec-copy)`
        //   **但实际创建的是软解组件**：`LDDec: createSoftOMXComponent` +
        //   `SoftVideoDecoderOMXComponent: Color Aspects preference: 1`。
        //   也就是说 mediacodec-copy 在这台设备上**静默退化成了 CPU 软解**，
        //   而 mpv 自己以为硬解成功了。后果链条：
        //     视频软解慢 → 视频帧积压追不上音频 → 音频时钟领先
        //     → `mpv[ad] warn: Invalid audio PTS: ... -> ...`（音频被迫跳变追赶）
        //     → `Audio/Video desynchronisation detected!`（mpv 自己判定失步）
        //     → video-sync 丢帧追音频 = 用户看到的「卡顿、然后快放」。
        //
        //   故不再把 mediacodec-copy 当作 Vulkan 路线的主力。改为：
        //     · 首选 `mediacodec`（真零拷贝，官方 mpv-android 的 Vulkan 路径）
        //     · 再退 `mediacodec-copy`（无 Surface 的 ffmpeg 拷贝变体）
        //     · 最后才由 mpv 自行退软解（software-fallback=yes）
        //   即对齐 mpv 自己给出的建议 `--hwdec=auto` 的候选顺序。
        val hwdecValue = if (!useHardware) {
            "no"
        } else if (useVulkan) {
            "mediacodec,mediacodec-copy"
        } else {
            "mediacodec-copy"
        }
        core?.setPropertyString(
            handle,
            "hwdec-software-fallback",
            if (allowSoftwareFallback) "yes" else "no"
        )
        core?.setPropertyString(handle, "hwdec", hwdecValue)
        val cmd = mutableListOf("loadfile", url, "replace")
        // 🔴🔴 2026-10-17 **不再设置 `start=` 属性**（用户指定的流程改造）。
        //
        //   真机日志 XiaoPaiTech BA001 2026101720（exo→mpv 切换）实证了双重危害：
        //     open startAt=279.469s → file-loaded value=279469.0
        //     → 首个 time-pos = 279.469（这是 `start=` 的**回显**，不是真实解码位置）
        //     → 随后真实心跳 time-pos=91.023（= 片头段 end 90.723 + 0.3）
        //   即 `start=` 对**带广告裁剪的 HLS** 会落到片头段的分片边界，把起播点
        //   拉到 91s；而紧接着的「补 seek」读到的是回显 279.469，误判为已到位，
        //   反而不去纠正 —— 校验被自己骗过。
        //
        //   用户明确给出的正确链路是：
        //     **保存播放记录 → 停止播放 → 切换 → 读取播放记录 → 恢复播放**
        //   因此定位只由下方 pendingSeek 在 FILE_LOADED 之后做**一次显式 seek**
        //   完成（一次性钉死，不经过 `start=` 的分片边界语义）。
        // 🔴🔴 2026-10-16 起播精确定位（修复「起播进度条前跳两段 ~+28s/次」）：
        //   仅设 `start=` 时，mpv 对 HLS 会落在**最近分片边界**，再靠内部时钟慢慢
        //   收敛到精确位置。日志实证（模拟器 22:04:35）：
        //     open start=1145000ms → 首个心跳 tp=1145.000000（吻合）
        //     → #1 tp=1174.40 (Δ+29.4) → #2 tp=1202.76 (Δ+28.36) → #3 起恒定 +3.00
        //   且 audio-pts 与 time-pos **同步跳**（差 +0.003 / +2.232）⇒ 是 demuxer
        //   层真实 PTS 位移，不是元数据轴漂移。用户观感 = 进度条往前跳两段。
        //   修法：登记目标值，等 FILE_LOADED（demuxer 就绪、可精确 seek）后补一次
        //   `seek <目标> absolute`，把定位一次性钉死。
        //   ⚠️ 直播不适用：直播 startAtMs<=0 且 seek 到绝对位置无意义，故置 0 跳过。
        val pendingSeek = if (!isLive && startAtMs > 0) startAtMs else 0L
        if (pendingSeek > 0) {
            core?.setPendingSeekMs(handle, pendingSeek)
        }
        if (!headers.isNullOrEmpty()) {
            val headerStr = headers.entries.joinToString("\r\n") { "${it.key}: ${it.value}" }
            core?.setOptionString(handle, "http-header-fields", headerStr)
        }
        Log.i(
            TAG,
            "open url=$url start=${startAtMs}ms " +
                "gpu-api=$gpuApi hwdec=$hwdecValue " +
                "fallback=${if (allowSoftwareFallback) "yes" else "no"} isLive=$isLive " +
                "forceOpenGl=$forceOpenGl 尺寸=${surfaceWidth}x${surfaceHeight} " +
                "设备=${RendererProbe.summary()} headers=${headers?.size ?: 0}"
        )
        core?.command(handle, cmd.toTypedArray())

        // 🔴 诊断埋点（2026-10-15）：硬解真实生效状态回读。
        //
        // 背景：安卓「播放一阵子后画面卡死、只有声音」的定位需要区分两种可能 ——
        //   ① hwdec 启动即失败并静默退软解，软解后来跟不上（表现为音视频分离）；
        //   ② hwdec 正常，是渲染输出停住。
        // 二者在 `hwdec` 这个**请求值**上完全一样（都是 "mediacodec,..."），
        // 只有 `hwdec-current`（**实际生效值**）能区分。
        //
        // ⚠️ 属性不是立刻可用的：mpv 要等解码器真正打开后才会填 hwdec-current。
        //    鸿蒙版实测「open 后立刻回读得到空字符串」，故此处延迟 1.5s 再读。
        //    与 MpvBridge.ets 的 hwdecProbeTimer（L155-157, L286-372）同策略。
        hwdecProbeTimer?.let { probeHandler.removeCallbacks(it) }
        val probe = Runnable {
            if (!disposed && initialized) {
                val cur = core?.getPropertyString(handle, "hwdec-current") ?: ""
                val vf = core?.getPropertyString(handle, "video-format") ?: ""
                val pf = core?.getPropertyString(handle, "pixelformat") ?: ""
                val hwActive = cur.isNotEmpty() && cur != "no"
                // 🔴 decoder-desc = 实际解码器的实现名（如 "h264 (H.264 / AVC ...)"）。
                //    这是判断「mpv 声称硬解、实际跑软解」的**唯一可靠手段** ——
                //    hwdec-current 只是 mpv 的**意图**，decoder-desc 才是**实际**。
                //    设备日志中 `hwdec-current=mediacodec-copy` 与
                //    `LDDec: createSoftOMXComponent` 同时出现，证明二者可以不一致。
                val desc = core?.getPropertyString(handle, "decoder-desc") ?: ""
                // 丢帧数：视频跟不上时 video-sync 会丢帧，数值持续增长即为
                // 「卡顿后快放」的直接量化证据。
                val dropFrames = core?.getPropertyString(handle, "frame-drop-count") ?: ""
                val dropDec = core?.getPropertyString(handle, "decoder-frame-drop-count") ?: ""
                // 实际播放速率：video-sync 变速追赶时 speed 会偏离 1.0。
                val spd = core?.getPropertyString(handle, "speed") ?: ""
                Log.i(
                    TAG,
                    "硬解探针 viewId=$viewId hwdec请求=$hwdecValue hwdec实际='$cur' " +
                        "decoder-desc='$desc' video-format='$vf' pixelformat='$pf' " +
                        "丢帧=$dropFrames 解码丢帧=$dropDec speed=$spd " +
                        "→ " + if (hwActive) "✅ 硬解已生效" else "⚠️ 硬解未生效（软解在跑）"
                )
            }
        }
        hwdecProbeTimer = probe
        // 🔴 2026-10-15 修正：1.5s 太早。
        //   真机日志实证 —— open 于 21:24:47.878，探针于 21:24:49.379 读回
        //   `hwdec实际=''`（空字符串），而 `hwdec-current 变更: 'mediacodec-copy'`
        //   直到 **21:24:51.855** 才出现，即解码器在 open 后约 **4 秒**才真正打开。
        //   1.5s 落在「解码器还没开」的窗口里，读到的空串会被误判成「硬解未生效」。
        //   改为 4.5s，并配合 JNI 侧的实时变更日志交叉验证。
        probeHandler.postDelayed(probe, 4500)

        // 画面心跳：open 后开始，用于定位「画面卡死但声音继续」发生在哪一环。
        startHeartbeat()
    }

    override fun getView(): View = placeholderView

    override fun dispose() {
        // 🔴 幂等守卫（2026-10-29 真机复盘新增）：
        //   本方法有**两条**调用路径 ——
        //     ① Flutter 引擎在 PlatformView 从 widget 树移除时调用；
        //     ② Dart 侧 backend.dispose() 经方法通道 'dispose' 调用。
        //   两条路径在「退出播放页」时会**先后**到达（引擎侧通常晚几百毫秒）。
        //   此前没有守卫时，第二次进入会**再 release 一次同一个 SurfaceProducer**
        //   → BufferQueue 处于不一致状态（历史症状：`detachBuffer: slot N is not
        //   owned by the producer`，slot 涨到上限 63）→ 后续 SurfaceSyncGroup
        //   收不到 transaction → **整窗不再出帧，用户表现为「退出播放页后卡死」**。
        //   现在第二次调用直接返回，保证 producer 只被释放一次。
        if (disposed) {
            Log.i(TAG, "dispose 重复调用已忽略 viewId=$viewId")
            return
        }
        Log.i(TAG, "dispose viewId=$viewId")
        disposed = true
        // 先断开事件通道，避免 JNI 线程继续往已销毁的 sink 推数据。
        eventSink = null
        try {
            if (handle != 0L && core != null) {
                core!!.destroy(handle)
            }
        } catch (e: Exception) {
            Log.e(TAG, "destroy 异常 viewId=$viewId: ${e.message}")
        }
        // 🔴 2026-10-15：销毁后必须把 core 与 handle **一并**归零（对齐
        //    hain_tv_legacy L1013-1026 的 SIGSEGV 修复；主工程移植时漏了 `core = null`）。
        //
        //    只把 handle 置 0 而保留 core 非空，会留下「core != null 且 handle == 0」
        //    的不一致状态。此后任何一条控制指令（pause/seek/setVolume/setSpeed/setFit
        //    /attachSurface/...）只要在 handleMethod 的 disposed 判断窗口之外到达，
        //    就会走 `core?.setPropertyString(handle, ...)` → 把 0 传给 C++
        //    → `reinterpret_cast<MpvInstance*>(0)` 解引用 → SIGSEGV(signal 11)。
        //    legacy 实测：`mpv 实例已销毁` 之后 4ms 仍有控制指令到达，该窗口真实存在。
        //    一并归零后所有 `core?.xxx(handle, ...)` 天然短路。
        handle = 0
        core = null
        // 🔴 诊断埋点：销毁后必须停掉探针与心跳，否则 handler 会一直手持
        //    已销毁的实例引用往下跑（内存泄漏 + 日志噪声）。
        hwdecProbeTimer?.let { probeHandler.removeCallbacks(it) }
        heartbeatTimer?.let { probeHandler.removeCallbacks(it) }
        probeHandler.removeCallbacksAndMessages(null)
        hwdecProbeTimer = null
        heartbeatTimer = null
        // 🔴 SurfaceProducer 的释放**延后**（2026-10-29 真机复盘新增）：
        //   SurfaceProducer 由引擎的 TextureRegistry 创建并持有，引擎在
        //   PlatformView 销毁时自己也会注销该条目。此处若「立刻」release，
        //   就可能与引擎的注销、以及 mpv 销毁后**仍在飞行中**的 buffer 撞车 ——
        //   这正是历史 `detachBuffer: slot N is not owned by the producer`
        //   （slot 单调涨到 63 → 黑屏/掉帧）的成因。
        //   现在改为：先摘回调（立刻）→ 再延后 1.5s 释放，让引擎注销与
        //   in-flight buffer 全部落定后再释放，避免拖垮后续的 SurfaceSyncGroup。
        try {
            surfaceProducer?.setCallback(null)
        } catch (e: Exception) {
            Log.e(TAG, "surfaceProducer.setCallback(null) 异常: ${e.message}")
        }
        probeHandler.postDelayed({
            try {
                surfaceProducer?.release()
                Log.i(TAG, "surfaceProducer 已释放 viewId=$viewId（延后 1.5s）")
            } catch (e: Exception) {
                Log.w(TAG, "surfaceProducer.release 异常（引擎可能已释放）: ${e.message}")
            }
        }, 1500)
        // 🔴 通知工厂把本实例从 views 表摘除，否则 map 只增不减。
        //    实测日志（2026-10-15）：viewId 0→1→3 每次重开都新建，旧实例连同其
        //    SurfaceProducer 永久滞留，表现为 BufferQueueProducer 报
        //    `detachBuffer: slot N is not owned by the producer` —— 10 秒内 189 次、
        //    slot 从 3 单调涨到 63（Android BufferQueue 上限），最终耗尽 → 黑屏/掉帧。
        onDisposed?.invoke(viewId)
    }

    /**
     * 由工厂注入的销毁回调：dispose 后把本 viewId 从 `views` 表中摘除。
     *
     * ⚠️ 必须挂在 dispose() 里回调而非等外部主动调用：Flutter 的 PlatformView
     *    销毁由引擎驱动，应用层拿不到可靠时机，只有 dispose() 本身是确定的。
     */
    internal var onDisposed: ((Int) -> Unit)? = null
}

/** PlatformView 工厂。 */
class MpvViewFactory(
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry?
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    private val views = mutableMapOf<Int, MpvPlayerView>()

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        Log.i(TAG, "MpvViewFactory.create viewId=$viewId args=$args")
        // 🔴 强制 GL 开关经 creationParams 传入并作为**构造参数**，
        //    保证在构造期 setupTextureSurface → applyRendererOptions 之前就生效。
        //    历史 bug：该开关原本由 open 命令下发，而纹理 surface 早于 open 到达，
        //    导致「打开强制 OpenGL 也无法播放」。
        val force = (args as? Map<*, *>)?.get("forceOpenGl") as? Boolean ?: false
        val view = MpvPlayerView(context, viewId, textureRegistry, force)
        views[viewId] = view
        // 🔴 2026-10-15：注册销毁回调，dispose 时把本 viewId 从 views 表摘除。
        //    此前 `removeView()` 虽已定义但**全局无调用点**（grep 仅命中定义处），
        //    导致 views 只增不减：每次换集/重开都新建 view（日志实证 viewId 0→1→3），
        //    旧实例与其 SurfaceProducer 一起滞留 → BufferQueue slot 泄漏（实测
        //    189 次 detachBuffer、slot 涨至上限 63）。
        view.onDisposed = { id ->
            if (views.remove(id) != null) {
                Log.i(TAG, "views 已摘除 viewId=$id 剩余=${views.size}")
            }
        }

        // 🔴 关键（与 hain_tv_legacy 同源）：每个视图一条独立事件通道，
        //    Dart 侧按 viewId 监听 `hain_tv/mpv_events_<viewId>`。
        //    漏了这段的话 Dart 的 EventChannel.receiveBroadcastStream() 会抛
        //    MissingPluginException(No implementation found for method listen ...)，
        //    收不到任何播放状态（position/duration/playing/eof），
        //    表现为「不闪退但播不了」。
        EventChannel(messenger, "hain_tv/mpv_events_$viewId").setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
                    Log.i(TAG, "事件通道 onListen viewId=$viewId")
                    view.setEventSink(sink)
                }

                override fun onCancel(arguments: Any?) {
                    Log.i(TAG, "事件通道 onCancel viewId=$viewId")
                    view.setEventSink(null)
                }
            }
        )
        return view
    }

    fun getView(viewId: Int): MpvPlayerView? = views[viewId]
    fun removeView(viewId: Int) = views.remove(viewId)
}

/** mpv Flutter 插件入口：注册 PlatformView 工厂 + 控制/事件通道。 */
class MpvPlugin : FlutterPlugin {
    private var factory: MpvViewFactory? = null

    override fun onAttachedToEngine(binding: FlutterPluginBinding) {
        val messenger = binding.binaryMessenger
        val viewFactory = MpvViewFactory(messenger, binding.textureRegistry)
        factory = viewFactory
        binding.platformViewRegistry.registerViewFactory(VIEW_TYPE, viewFactory)

        MethodChannel(messenger, CHANNEL_CONTROL).setMethodCallHandler { call, result ->
            val viewId = (call.argument<Int>("viewId") ?: -1)
            val view = factory?.getView(viewId)
            if (view == null) {
                // 🔴 2026-10-24：`pause` 在 view 已销毁后调用时**降级为成功**。
                //
                //   背景：Flutter 卸载 PlatformView 的时机**早于** Dart 侧
                //   dispose() 被调用（销毁由引擎驱动，应用层拿不到可靠时机，
                //   见 MpvViewContainer.dispose() 的注释）。于是
                //   LivePlayer.dispose() 里的 pause 必然打在已从 views 表摘除的
                //   view 上 → PlatformException(NO_VIEW)。
                //
                //   而「停止播放」这个语义**已经达成**：MpvViewContainer.dispose()
                //   里先执行了 core!!.destroy(handle)（mpv 实例已销毁，音频与
                //   画面随之停止），之后才把 view 从 views 表摘除。故此处报
                //   NO_VIEW 等于把正常的生命周期竞态暴露成故障，在日志里表现为
                //   每次退直播/换台都有一条「pause 失败」。
                //
                //   ⚠️ 只豁免 pause：其余命令（open/seek/setVolume/dispose…）
                //      仍必须报 NO_VIEW，调用方据此走各自的降级分支。
                if (call.method == "pause") {
                    Log.i(TAG, "pause 命中已销毁 view(viewId=$viewId)，按已停止处理")
                    result.success(null)
                    return@setMethodCallHandler
                }
                result.error("NO_VIEW", "no mpv view for id $viewId", null)
                return@setMethodCallHandler
            }
            view.handleMethod(call, result)
        }

        Log.i(TAG, "MpvPlugin 已注册（viewType=$VIEW_TYPE, channel=$CHANNEL_CONTROL）")
    }

    override fun onDetachedFromEngine(binding: FlutterPluginBinding) {
        factory = null
    }
}
