package com.heinplay.hain_tv

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.DisplayMetrics
import android.util.Log
import android.view.Surface
import android.view.View
import android.view.ViewGroup
import android.widget.FrameLayout
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import io.flutter.view.TextureRegistry
import java.util.concurrent.atomic.AtomicBoolean

/**
 * HeinPlay tvLegacy 的 mpv 安卓原生绑定（自写壳，对齐官方 mpv-android 的 wid 范式）。
 *
 * 三层结构：
 *  1. 内核：本工程 `.mpv-android/` 交叉编译的官方 mpv `libmpv.so`（API 21，
 *     OpenGL 路线 `vo=gpu` + `gpu-context=android`，不启用 Vulkan 以覆盖 Android 5.0）。
 *  2. 壳（本文件）：Kotlin 原生层，经 JNI 调 libmpv C API，把 Android Surface 作为
 *     mpv 的 `wid` 交给 android gpu-context 渲染。
 *  3. Dart 层：lib/player/mpv_backend.dart，经同一契约与这里通信。
 *
 * **渲染路线：仅纹理（TextureView）**。
 *  `TextureRegistry.createSurfaceProducer()` 申请 Flutter 外部纹理，mpv 把画面渲染
 *  到该纹理的 Surface，Dart 侧 `Texture(textureId)` 显示。本视图本体只是一个零尺寸
 *  占位（挂载锚点），不出画。
 *
 *  ⚠️ 2026-10-07：原 `surface` 路线（`SurfaceView` 自带 Surface，mpv 直接画到
 *  ANativeWindow）在安卓上**无法实现**，已实测两条合成路径都是黑屏并移除：
 *  1. `AndroidView` → 引擎硬编码 `VIEW_TYPES_REQUIRE_VIRTUAL_DISPLAY = {SurfaceView}`
 *     （`hasChildViewOfType` 递归判定，包进 ViewGroup 也躲不开），强制 Virtual Display；
 *  2. Hybrid Composition → logcat 中 `flutter-vd` 已归零（Hybrid 确已生效）但**仍黑屏**：
 *     Hybrid 用 ImageReader 把平台视图「画」成纹理，而 `SurfaceView` 内容不走
 *     `View.draw()`，捕获到空帧。
 *  唯一可行解 `setZOrderMediaOverlay(true)` 会让 SurfaceView 浮到 Flutter 表面之上、
 *  永久盖住控制条等全部 Flutter UI，与「Flutter 渲染 UI」架构根本冲突。
 *
 * 契约：
 *  - MethodChannel `hain_tv/mpv`：open/play/pause/seek/setVolume/setSpeed/setFit/dispose
 *    （按 viewId 路由）。
 *  - EventChannel `hain_tv/mpv_events_<viewId>`：首条为 `{type:'texture', textureId}`，
 *    其后推送 `{positionSec,durationSec,playing,buffering,volume,speed,eof,buffer}`。
 */

private const val TAG = "HeinPlayMpv"

/**
 * 🔴 2026-10-12 23:10 【已废弃，保留仅为回溯】硬解绿屏的「强制色彩修正」开关。
 *
 * ⚠️ 该方案已被真机日志推翻并**撤除**，此常量不再被任何代码引用。
 *    撤除理由见 executeOpen 里 `vf remove` 处的长注释，摘要：
 *      真机日志证明绿屏源本来就是 colormatrix='bt.709' / primaries='bt.709' /
 *      colorlevels='limited'，即色彩元数据**并未缺失**；
 *      而 `vf=format` 是**覆写**语义，对已正确的源等于恒等（无用）、
 *      对 BT.601 源则主动制造色偏（有害），故整体撤除。
 *
 * 🆕 2026-10-12 23:2x 新证据（用户实测）：**模拟器不绿屏，只有真机绿屏。**
 *    ⇒ 绿屏**不是**「码流/色彩参数播放器理解错误」这一类**内容层**问题，
 *      因为同一码流在模拟器上是被正确渲染的。
 *    ⇒ 它必然是**真机硬件/驱动/平台层**的差异，候选方向（按可能性排序）：
 *      1. MediaCodec 硬解器输出的 GraphicBuffer 在 Amlogic 上的
 *         格式/色彩空间（如 10bit / 非标准 YUV 排列）与 GL 纹理采样约定不符；
 *      2. Amlogic OSD 输出上限（代码注释里的 `4kosd newBufferCount > 14`）导致
 *         buffer 分配降级后格式协商错误；
 *      3. 真机走 `mediacodec-copy` 拷贝路径时，`av_image_copy` 的
 *         linesize/plane 处理在特定步幅下错位（模拟器 stride 不同，故不复现）。
 *    ⇒ 下一步排查必须**以真机为准**，且要抓 **hwdec 初始化返回码 + 实际
 *      pixelformat/linesize**，而不是继续在色彩参数上打转。
 */
@Deprecated("已被真机日志推翻，见 executeOpen 注释；勿再启用")
private const val colorFixEnabled = false

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
            // libmpv 必须早于 libheinplay_mpv_jni 加载：后者链接期引用了 libmpv 与
            // libavcodec 的符号，同进程内按加载顺序解析。
            System.loadLibrary("mpv")
            Log.i(TAG, "libmpv.so 加载完成")
        }
    }
}

/** libmpv C API 的 JNI 封装（wid 机制最小子集，对齐官方 mpv-android 范式）。 */
class MpvCore {
    init {
        MpvLoader.ensureLoaded()
    }

    // 返回 mpv_handle*。必须传入 MpvPlayerView 实例：C 侧把属性回调打在
    // MpvPlayerView.onMpvEvent 上，若绑定到 MpvCore 实例会因方法所属类不匹配而崩溃。
    external fun create(view: Any): Long
    external fun initialize(handle: Long)
    external fun setOptionString(handle: Long, name: String, value: String)
    external fun command(handle: Long, args: Array<String>)
    external fun setPropertyString(handle: Long, name: String, value: String)
    external fun getPropertyString(handle: Long, name: String): String?
    external fun observeProperty(handle: Long, replyId: Int, name: String, format: Int)
    external fun unobserveProperty(handle: Long, replyId: Int)
    external fun requestLogMessages(handle: Long, level: String)
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
                Log.e(TAG, "heinplay_mpv_jni 加载失败: ${e.message}")
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
    textureRegistry: TextureRegistry?
) : PlatformView, TextureRegistry.SurfaceProducer.Callback {

    /** 外部纹理生产者；纹理路线唯一出画来源。 */
    private val surfaceProducer: TextureRegistry.SurfaceProducer? =
        textureRegistry?.createSurfaceProducer()?.also { it.setCallback(this) }

    /** 纹理路线下的根视图：零尺寸占位，只为触发原生 create（不出画）。 */
    private val placeholderView: View = FrameLayout(context)

    private var core: MpvCore? = null
    private var handle: Long = 0
    private var eventSink: EventChannel.EventSink? = null
    // ⚠️ 2026-10-12 崩溃修复：加 @Volatile。
    //   dispose() 在主线程写 true，而 pushState()/pushTextureId() 由 **mpv 事件线程**
    //   经 JNI CallVoidMethod 回调读取。普通 Boolean 在此跨线程场景下无可见性保证，
    //   事件线程可能长期读到陈旧的 false，从而在销毁后仍操作已释放的对象 → SIGSEGV。
    @Volatile
    private var disposed = false
    private var initialized = false
    private var currentSurface: Surface? = null

    /** 纹理缓冲尺寸（= 屏幕物理分辨率），mpv 的 android-surface-size 同值。 */
    private var surfaceWidth = 0
    private var surfaceHeight = 0

    // 最新状态快照（pause/eof 用 0/1 整型表达）
    private var positionSec = 0.0
    private var durationSec = 0.0
    private var playing = false
    private var buffering = false
    private var volume = 1.0
    private var speed = 1.0
    private var eof = false
    private var bufferSec = 0.0

    // ⚠️ 2026-10-11 硬解探针状态。
    //   hwdec-current 在**首帧渲染出来之前**可能是空串或不稳定值
    //   （鸿蒙侧已踩过这个坑：首帧前读会把「硬解正常」误报成「硬解未生效」，
    //   于是日志刷屏但实际硬解已生效）。故本探针必须等首帧之后才判定。
    //   判定「首帧已出」的依据：time-pos 首次 > 0 且 duration > 0，
    //   即解复用+解码已真正跑起来（比 vo 的 frame 事件更容易在 JNI 回调里拿到）。
    private var hwdecProbeVideoStarted = false
    private var hwdecProbeLogged = false
    /** 最近一次 hwdec-current 原始值（空串表示 mpv 未填，尚不可信）。 */
    private var hwdecCurrentRaw = ""
    /** 最近一次 open 请求的硬解开关状态，供探针日志复述「请求了什么」。 */
    private var useHardwareRequested = false
    /** 最近一次 open 是否为直播。executeOpen 的 isLive 是局部变量，
     *  探针在属性回调里运行、取不到该作用域，故用成员字段承载。 */
    private var isLiveStream = false

    // ⚠️ 2026-10-12：**硬解降级链诊断**（只观测，不改行为）。
    //
    // 【为什么加】2026-10-11 真机日志中，直播两次都在 3.7 秒内死于
    //   「4kosd set output error, newBufferCount 19 > 14」→ -1010，
    //   且 [硬解探针] 一行都没输出 —— 因为探针要求 positionSec >= 3.0 才触发，
    //   而直播在 0.x 秒就死了，永远到不了那个阈值。
    //   结果就是：直播失败时日志里「看不到它失败在哪一级」，只能靠猜。
    //
    //   本组字段记录 hwdec-current 的**每一次变化**（含降级中间态），
    //   以及首个 time-pos 事件的时间戳，用于回答：
    //     ① 直播到底有没有走到降级？
    //     ② 它在哪一级停住？
    //     ③ 从 open 到首个解码事件隔了多久（起播耗时归因）？
    /** hwdec-current 的完整变化轨迹，形如 "mediacodec→mediacodec-copy"。 */
    private var hwdecTrace = StringBuilder()
    /** 上一次记录的 hwdec-current，用于去重（同一值不重复记）。 */
    private var hwdecTraceLast = ""
    /** open 时刻（ms），用于计算首个解码事件 / 首帧的耗时。 */
    private var openAtMs = 0L
    /** 是否已记录「首个 time-pos」——只记一次。 */
    private var firstPosLogged = false

    /**
     * 🔴 2026-10-12 绿屏取证：上一次打印过的「源色彩参数」指纹（值变化才打印）。
     *   硬解下这些值若为 unknown/auto，即「ffmpeg 硬解路径不解析 SPS VUI」的直接证据。
     */
    private var colorParamsLogged = ""
    /** 最近一次打印过的几何探针指纹，避免同一组值重复刷屏。 */
    private var geometryLogged = ""

    // open 请求可能早于 surface 就绪（mpv_command 在未 initialize 时会失败），
    // 故先暂存，等 initialize 完成后再补发。
    private var pendingOpen: Map<String, Any?>? = null

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
        val producer = surfaceProducer ?: return
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
            // 硬解优先：mediacodec（安卓 MediaCodec 硬解）。
            core!!.setOptionString(handle, "vo", "gpu")
            core!!.setOptionString(handle, "gpu-context", "android")
            // ⚠️ 2026-10-11：**必须显式声明 OpenGL ES 上下文**（对齐官方 mpv-android 基线）。
            //   官方 MPVView.initOptions 里 gpu-context=android 的下一行恒为 opengl-es=yes。
            //   不写时 mpv 按桌面 GL 语义挑 EGL config，在老设备（尤其 API 21 的
            //   Amlogic / 低端 v7）上更容易挑到不可用 config 而黑屏。
            core!!.setOptionString(handle, "opengl-es", "yes")
            // hwdec 不在此写死：由设置页「硬件解码」开关在 open() 时下发（见 executeOpen），
            // 这里只固定可硬解的编码表。
            //
            // ⚠️ 2026-10-11：编码表对齐官方 MPVView 的
            //   "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1"。
            //   本工程主要播 IPTV m3u8（h264/hevc），但部分老源含 mpeg2/mpeg4，
            //   缺失时硬解会静默不生效，故与官方保持一致。
            core!!.setOptionString(handle, "hwdec-codecs", "h264,hevc,mpeg4,mpeg2video,vp8,vp9,av1")
            // ⚠️ 2026-10-11：音频输出对齐官方。API 21 老设备上 AudioTrack 最稳，
            //   OpenSL ES 在部分 Amlogic ROM 上初始化失败会直接无声；
            //   官方用逗号链给出优先级，让 mpv 自行降级。
            core!!.setOptionString(handle, "ao", "audiotrack,opensles")
            // ⚠️ 2026-10-12：demuxer 缓存对齐**鸿蒙版**（1024MiB / 512MiB）。
            //
            // 【为什么改】2026-10-11 真机日志（XiaoPaiTech BA001）实测：
            //   点播 open 于 22:20:28.301（startAt=17分40秒），
            //   续播定位闸门到 22:20:36.558 才开启 —— **8.276 秒卡在续播定位**，
            //   而定位期间没有任何解码动作。同源同设备，鸿蒙版明显更快。
            //   对照两者选项，唯一量级差异就在这里：
            //     鸿蒙  demuxer-max-bytes = 1024MiB, demuxer-max-back-bytes = 512MiB
            //     本工程 64MiB / 64MiB（API>=27）或 32MiB（更低）
            //   即 16~32 倍的差距。定位到长片中段时 mpv 需重新填充解复用缓冲，
            //   64MiB 很快触顶 → 反复回退/重读 → 拖动进度条同样要等很久。
            //
            // 【为什么敢放开】原先照抄官方 mpv-android 的保守值（防手机/盒子 OOM），
            //   但本工程实际播的是 1080P IPTV 长片，且真机为 arm64-v8a 设备，
            //   内存充足。保守值在这里只换来卡顿，没有换到收益。
            //   这两个选项都是 **demuxer 软上限**（超出即停止预读，非硬性预分配），
            //   不会一次性吃掉 1GB 物理内存，故对低内存设备风险可控。
            core!!.setOptionString(handle, "demuxer-max-bytes", "1024MiB")
            core!!.setOptionString(handle, "demuxer-max-back-bytes", "512MiB")
            // ⚠️ hwdec-software-fallback 不在此写死：它必须跟随「硬件解码」开关，
            // 且直播必须始终允许回退。见 executeOpen 的说明（写死 no 会让纯软解
            // 也被 mpv 判成「回退被禁用」而 force_eof，表现为只有声音没有画面）。
            core!!.setOptionString(handle, "cache", "yes")
            core!!.setOptionString(handle, "cache-secs", "30")
            core!!.setOptionString(handle, "demuxer-readahead-secs", "30")
            core!!.setOptionString(handle, "tls-verify", "no") // 兼容非标准/自签 IPTV 源
            // 安卓 gpu-context 的窗口尺寸，必须显式给定：
            // 纹理路线不会触发 onSurfaceChanged，若不设则 ANativeWindow_getWidth
            // 仍为 0 → vo_android_surface_size() 返回 0 → EGL surface 非法。
            resolveDisplaySize()
            core!!.setOptionString(handle, "android-surface-size", "${surfaceWidth}x${surfaceHeight}")
            core!!.requestLogMessages(handle, "info")
            // 监听属性（format: 1=STRING,3=FLAG,4=INT64,5=DOUBLE）
            core!!.observeProperty(handle, 1, "time-pos", 5)
            core!!.observeProperty(handle, 2, "duration", 5)
            core!!.observeProperty(handle, 3, "pause", 3)
            core!!.observeProperty(handle, 4, "cache-buffering-state", 5)
            core!!.observeProperty(handle, 5, "volume", 5)
            core!!.observeProperty(handle, 6, "speed", 5)
            core!!.observeProperty(handle, 7, "eof-reached", 3)
            core!!.observeProperty(handle, 8, "demuxer-cache-time", 5)
            // ⚠️ 2026-10-11：**新增硬解探针**（format 1=STRING）。
            //   恢复官方 "mediacodec,mediacodec-copy" 列表后，mpv 会在运行时逐级降级，
            //   必须能看见最终落在哪一级，否则「硬解到底有没有生效」无从判断。
            //   取值语义：'mediacodec' 零拷贝 / 'mediacodec-copy' 拷贝变体 / 'no' 软解。
            //   🔴 探针读取时机见 onHwdecProbeTick：**首帧之后**才可信，
            //      首帧前 hwdec-current 可能为空串，此时判「硬解未生效」是误报。
            core!!.observeProperty(handle, 9, "hwdec-current", 1)
            core!!.observeProperty(handle, 10, "video-params/pixelformat", 1)
            // 🔴 2026-10-12 绿屏取证：观察解码器输出的**源色彩参数**（只观察，不干预）。
            //
            //   ✅ 真机实测结果（XiaoPaiTech BA001.2026101220）：
            //       colormatrix='bt.709' / primaries='bt.709' / colorlevels='limited'
            //       三条绿屏源（viewId=0/1/2）读数完全一致。
            //
            //   ⇒ 此处原先的「预期现象」写的是「硬解这三个值会是 unknown/auto/unspecified」，
            //     真机数据**与之完全相反**：硬解路径**正确读出了** BT.709/limited。
            //
            //   ⇒ 因此「硬解不读 VUI → 色彩为空 → mpv 猜错 → 深橄榄绿」这条根因链
            //     **已被证伪**，据此下发的 `vf=format` 强制色彩转换也已撤除
            //     （理由见 executeOpen 里 `vf remove` 处的长注释）。
            //     这段观察本身仍有价值 —— 它正是推翻旧假设的证据来源，故保留。
            //
            //   🆕 决定性事实：**模拟器不绿屏，只有真机绿屏** ⇒ 真因在硬件/驱动层
            //     （最可能是硬解输出 buffer 的 stride/plane 与 GL 采样约定不符），
            //     与色彩语义无关。故新增下列 stride 相关探针。
            core!!.observeProperty(handle, 11, "video-params/colormatrix", 1)
            core!!.observeProperty(handle, 12, "video-params/primaries", 1)
            core!!.observeProperty(handle, 13, "video-params/colorlevels", 1)
            // 🔴 2026-10-12 23:2x 新增：验证「stride/plane 错位」假设所需的量。
            //   假设：Amlogic 硬解输出的 GraphicBuffer 其 YUV plane 步幅（stride）
            //   与 GL 纹理采样约定不一致；mediacodec-copy 用 av_image_copy 逐行拷贝时
            //   若 stride 非标准，色度平面会整体错切 → 肉眼深橄榄绿。
            //   判别方法：比较 `video-params/w`（显示宽，可能含裁剪）与
            //   `video-params/dw`（解码宽）以及 aspect 相关项是否自洽；
            //   若 w < dw 或出现非对齐值，即命中该假设。
            core!!.observeProperty(handle, 14, "video-params/w", 4)
            core!!.observeProperty(handle, 15, "video-params/h", 4)
            core!!.observeProperty(handle, 16, "video-params/dw", 4)
            core!!.observeProperty(handle, 17, "video-params/dh", 4)
            core!!.observeProperty(handle, 18, "video-params/aspect", 5)
            Log.i(TAG, "mpv 选项就绪 viewId=$viewId（等待 surface 后 initialize）")
        } catch (e: Exception) {
            Log.e(TAG, "mpv 初始化失败 viewId=$viewId: ${e.message}")
        }
    }

    /** Surface 就绪：attach 为 wid（必须在 initialize 之前），随后 initialize。 */
    private fun onSurfaceReady(surface: Surface) {
        if (disposed) return
        currentSurface = surface
        try {
            core?.attachSurface(handle, surface)
            if (!initialized) {
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
        when (name) {
            "time-pos" -> {
                positionSec = value
                // ⚠️ 2026-10-12：记录首个 time-pos 的到达时刻。
                //   这是判定「解码链是否真正跑起来」的最早可靠信号：
                //   直播此前在 positionSec>=3.0 才触发探针，但往往 0.x 秒就崩，
                //   导致探针永不触发、日志全黑。记首帧时刻即可区分
                //   「根本没解码」与「解码了但探针阈值没到」。
                if (value > 0.0 && !firstPosLogged) {
                    firstPosLogged = true
                    val cost = if (openAtMs > 0) System.currentTimeMillis() - openAtMs else -1
                    Log.i(
                        TAG,
                        "[硬解诊断] 首个 time-pos=${"%.3f".format(value)}s，" +
                            "距 open ${cost}ms（isLive=$isLiveStream，viewId=$viewId）"
                    )
                }
                if (value > 0.0) maybeRunHwdecProbe()
            }
            "duration" -> {
                durationSec = value
                if (value > 0.0) maybeRunHwdecProbe()
            }
            "pause" -> {
                playing = (value == 0.0)
                buffering = false
            }
            "cache-buffering-state" -> buffering = value > 0.0
            "volume" -> volume = value / 100.0
            "speed" -> speed = value
            "eof-reached" -> eof = (value != 0.0)
            "demuxer-cache-time" -> bufferSec = value
            // ⚠️ 2026-10-11：hwdec-current 是字符串属性，C 侧 value 无法承载，
            //   故此处仅在收到"已变更"通知时主动回读（见 maybeRunHwdecProbe）。
            "hwdec-current" -> {
                hwdecCurrentRaw = readStringProperty("hwdec-current")
                // ⚠️ 2026-10-12：记录每一次变化（含降级中间态）。
                //   直播失败时最有价值的就是这条轨迹 —— 能看出它走到了哪一级。
                if (hwdecCurrentRaw.isNotEmpty() && hwdecCurrentRaw != hwdecTraceLast) {
                    if (hwdecTrace.isNotEmpty()) hwdecTrace.append("→")
                    hwdecTrace.append(hwdecCurrentRaw)
                    hwdecTraceLast = hwdecCurrentRaw
                    val cost = if (openAtMs > 0) System.currentTimeMillis() - openAtMs else -1
                    Log.i(
                        TAG,
                        "[硬解诊断] hwdec-current 变为 '$hwdecCurrentRaw'（距 open ${cost}ms，" +
                            "isLive=$isLiveStream，viewId=$viewId）"
                    )
                }
                if (hwdecProbeVideoStarted) logHwdecProbe(reason = "hwdec-current 变更")
            }
            // pixelformat 同样只作变更通知，探针打印时回读即可，此处无需处理。
            "video-params/pixelformat" -> { /* no-op：由探针回读 */ }
            // 🔴 2026-10-12 绿屏取证：源色彩参数变更时回读并打印一次（只观察，不干预）。
            //   ✅ 真机实测：硬解下读到的是 bt.709/bt.709/limited（非空的正确值），
            //      故「硬解读不到 VUI 色彩」的旧假设已被证伪，据它下发的
            //      vf=format 强制转换亦已撤除（见 executeOpen 注释）。
            "video-params/colormatrix",
            "video-params/primaries",
            "video-params/colorlevels" -> {
                // 字符串型属性只收到「变更通知」（value 无意义），须显式回读。
                val actual = readStringProperty(name)
                val key = "$name=$actual"
                if (colorParamsLogged != key) {
                    colorParamsLogged = key
                    Log.i(
                        TAG,
                        "[绿屏取证] 源色彩参数 $name='$actual'（hwdec=${hwdecCurrentRaw.ifEmpty { "空" }}，" +
                            "isLive=$isLiveStream，viewId=$viewId）"
                    )
                }
            }
            // 🆕🔴 2026-10-12 23:2x 几何/步幅探针 —— 验证「stride/plane 错位」假设。
            //   事实：模拟器不绿、真机绿 ⇒ 真因在硬件/驱动层，最可能是硬解输出
            //   buffer 的 YUV plane 步幅与 GL 纹理采样约定不符。
            //   本组探针把「解码几何」一次性打全，供判定：
            //     dw/dh = 解码器实际输出尺寸（对齐后的）
            //     w/h   = 显示尺寸（可能小于 dw/dh，说明有裁剪/对齐填充）
            //     aspect= 宽高比
            //   若出现 w != dw 或 w 非 16 对齐值，即命中假设。
            "video-params/w",
            "video-params/h",
            "video-params/dw",
            "video-params/dh",
            "video-params/aspect" -> {
                val signal = "$name=${readStringProperty(name)}"
                if (geometryLogged != signal) {
                    geometryLogged = signal
                    logGeometry()
                }
            }
        }
        // 属性回调在 JNI 线程，切回主线程推送，避免 EventSink 跨线程使用。
        mainHandler.post { pushState() }
    }

    /**
     * 硬解探针：**必须在首帧之后**才判定。
     *
     * 🔴 为什么不能早读：mpv 在解码器真正建立之前，hwdec-current 可能：
     *   - 返回空串（属性尚未被 vo/vd 赋值）；
     *   - 或因 hwdec 列表正在逐级降级而短暂显示中间值。
     *   此时若直接判「硬解未生效」并回退软解，就会把**本来正常的硬解**打断，
     *   这正是鸿蒙侧「硬解探针误报」的根因，必须避免重犯。
     *
     * 判定时机：time-pos > 0 **且** duration > 0（点播），或直播下 time-pos > 0
     * 且已持续增长。两者都满足才算「解码链已跑起来」，此时读取才可信。
     *
     * 只记一次日志，避免属性高频变更导致刷屏（刷屏会淹没真正的错误）。
     */
    private fun maybeRunHwdecProbe() {
        if (hwdecProbeVideoStarted) return
        // 判定「解码链已跑起来」的时机：
        //   点播：duration 到位（此前 duration=0，解码器可能尚未建立）；
        //   直播：没有 duration，改用 time-pos 推进作为判据。
        // 🔴 两者都必须**在首帧之后**，绝不能更早读 hwdec-current（会误报）。
        //
        // ⚠️ 2026-10-12：直播阈值由 3.0s 下调到 0.5s。
        //   原因：2026-10-11 日志中直播在 0.x 秒就被 Amlogic OSD 上限打死后
        //   dispose（两次各只活 3.7s），positionSec 从未到过 3.0，
        //   于是 [硬解探针] 一行都没输出 —— 失败现场完全不可见。
        //   0.5s 仍满足「首帧之后」这一铁律（time-pos>0 即已出帧），
        //   但能让短命会话也留下判定记录。
        //   「首帧前读会误报」的坑不受影响：time-pos>0 本身就等价于已出帧。
        if (isLiveStream) {
            if (positionSec < 0.5) return
        } else {
            if (durationSec <= 0.0) return
        }
        hwdecProbeVideoStarted = true
        // 稍等一下再读：首帧刚出时 hwdec-current 可能还在最后一次降级中。
        mainHandler.postDelayed(
            { logHwdecProbe(reason = if (isLiveStream) "直播起播后" else "首帧后") },
            1500L
        )
    }

    /**
     * 🆕🔴 2026-10-12 23:2x 几何/步幅探针 —— 验证「stride/plane 错位」假设。
     *
     * 背景事实：**模拟器不绿屏，真机（Amlogic XiaoPaiTech BA001）绿屏**。
     * 这否定了「色彩语义/码流理解错误」整类假设（色彩矩阵是平台无关的纯计算，
     * 模拟器若真因在此必然同样绿），把方向锁定到**硬件/驱动层**。
     *
     * 最可能的机制：硬解输出的 GraphicBuffer 其 YUV plane 的**行步幅(stride)**
     * 与 GL 纹理采样约定不一致；`mediacodec-copy` 用 `av_image_copy` 逐行拷贝时，
     * 若源 stride 非标准（未对齐、或含额外填充），色度平面会被整体「错切」，
     * 肉眼呈现为深橄榄绿。模拟器的解码器 stride 规整，故不复现。
     *
     * 判别依据（本次要拿到的数据）：
     *   - `dw`/`dh`：解码器输出尺寸（通常为 16 对齐后的值）
     *   - `w`/`h`  ：显示尺寸（可小于 dw/dh，差值即为对齐填充）
     *   - `aspect` ：宽高比
     *   - `pixelformat`：yuv420p / nv12 / yuv420p10 等，决定 plane 布局
     * 若 `w != dw`（存在填充）或 pixelformat 为 10bit/非标准排列，即命中假设。
     *
     * 本探针**只读不写**，不做任何格式干预。
     */
    private fun logGeometry() {
        try {
            val w = readStringProperty("video-params/w")
            val h = readStringProperty("video-params/h")
            val dw = readStringProperty("video-params/dw")
            val dh = readStringProperty("video-params/dh")
            val aspect = readStringProperty("video-params/aspect")
            val pixelFormat = readStringProperty("video-params/pixelformat")
            Log.i(
                TAG,
                "[绿屏取证] 几何/步幅 w=$w h=$h dw=$dw dh=$dh aspect=$aspect " +
                    "pixelformat='$pixelFormat' hwdec=${hwdecCurrentRaw.ifEmpty { "空" }} " +
                    "isLive=$isLiveStream viewId=$viewId " +
                    "对齐填充=${if (w != dw || h != dh) "有(w≠dw 或 h≠dh ⇒ 色度错切风险)" else "无"}"
            )
        } catch (e: Exception) {
            Log.w(TAG, "[绿屏取证] 几何探针读取失败 viewId=$viewId: ${e.message}")
        }
    }

    /** 回读一个字符串型 mpv 属性；失败返回空串。 */
    private fun readStringProperty(name: String): String {
        return try {
            core?.getPropertyString(handle, name) ?: ""
        } catch (e: Exception) {
            Log.w(TAG, "读取属性 $name 失败: ${e.message}")
            ""
        }
    }

    /**
     * 打印硬解最终落点。语义：
     *   'mediacodec'      → 零拷贝硬解（最优）
     *   'mediacodec-copy' → 拷贝变体硬解（Amlogic OSD 上限 14 场景的正常落点）
     *   'no' / 空串        → 软解（或尚未就绪）
     *
     * 🔴 判据（对齐用户规则）：硬解**真失败** = hwdec-current 为空/‘no’
     *   **且**日志有明确解码错误；源加载慢 = cache/demuxer 指标异常但解码器正常。
     *   不要一遇卡顿就回退软解。
     */
    private fun logHwdecProbe(reason: String) {
        if (hwdecProbeLogged) return
        val cur = readStringProperty("hwdec-current")
        if (cur.isEmpty()) {
            // 空串说明 mpv 尚未填该属性，不是「软解」，继续等下一次事件。
            Log.i(TAG, "[硬解探针] $reason hwdec-current 仍为空，等待后续事件再判定")
            return
        }
        hwdecProbeLogged = true
        val pixelFormat = readStringProperty("video-params/pixelformat")
        val level = when {
            cur.startsWith("mediacodec-copy") -> "拷贝变体硬解（mediacodec-copy）"
            cur.startsWith("mediacodec") -> "零拷贝硬解（mediacodec）"
            cur == "no" -> "软解"
            else -> "其他：$cur"
        }
        // ⚠️ 2026-10-12：附上降级链完整轨迹。
        //   若轨迹形如 "mediacodec→mediacodec-copy"，说明发生了降级且成功，
        //   日志里那串 4kosd/-1010 就是**预期噪音**；
        //   若轨迹只有 "mediacodec" 且期间有 -1010，则是**真的没降级成功**。
        val trace = if (hwdecTrace.isEmpty()) "(无变化记录)" else hwdecTrace.toString()
        Log.i(
            TAG,
            "[硬解探针] $reason hwdec-current='$cur' → $level；" +
                "pixelformat='$pixelFormat'；hwdec 请求=${if (useHardwareRequested) "mediacodec,mediacodec-copy" else "no"}；" +
                "降级链=$trace；" +
                "注：日志中若出现 4kosd / OMX_ErrorInsufficientResources(-1010) 属**预期降级噪音**，" +
                "不代表硬解失效，以本行 hwdec-current 为准。"
        )
    }

    private fun executeOpen(args: Map<String, Any?>) {
        val url = args["url"] as? String ?: ""
        // startAtMs 由 Dart int 传入（StandardMessageCodec 编成 Integer/Long），
        // 统一按 Number 收，避免类型不匹配导致续播定位被静默丢弃。
        val startAtMs = (args["startAtMs"] as? Number)?.toLong() ?: 0L
        @Suppress("UNCHECKED_CAST")
        val headers = args["headers"] as? Map<String, String>
        // 设置页「硬件解码」开关：true=mediacodec 硬解，false=纯软解。
        // 缺省（旧调用方/未传）时按开启处理，与设置默认值一致。
        val hardwareDecoding = args["hardwareDecoding"] as? Boolean ?: true
        // ⚠️ 2026-10-11：「硬件解码」开关对**直播与点播一视同仁**（原先直播被强制软解）。
        //   该开关是全局设置（UserDataService.getHardwareDecoding，默认 true）。
        val isLive = args["isLive"] as? Boolean ?: false

        // ⚠️ 软解回退开关必须与 hwdec 一起下发，不能全局写死 no。
        // mpv 源码 vd_lavc.c：只要 `hwdec=no`（用户显式要软解），use_hwdec 恒为 false，
        // 代码同样落入 `else` 分支；此时若 software_fallback == INT_MAX（即 no），
        // mpv 会判定「软解回退被禁用」并置 ctx->force_eof = true —— 结果是**纯软解
        // 也出不了画，只有声音**。
        // 🔴 2026-10-07 修正（**已被 2026-10-11 推翻，保留备查**）：曾「直播固定软解」。
        //   当时证据：让直播走 mediacodec-copy，真机实测直播画面全绿（点播同参数正常）。
        //   当时的结论是直播一律 hwdec=no，不再尝试硬解。
        //   ⚠️ 但那次的参数是**写死的单个 mediacodec-copy**，与官方列表写法
        //   "mediacodec,mediacodec-copy" 并非同一条解码路径；且「全绿」真正的归因
        //   从未被确证是硬解本身，还是当时 hwdec 写法/降级缺失导致的副产物。
        // 🔴 2026-10-07 二次修正：**恢复始终允许软解回退**（仍然有效，保留）。
        //   真机证据：关闭软解回退这一步本身就把播放打破了 —— 打开该开关后，
        //   硬解一旦失败就 force_eof，表现为「只有声音没画面 / 播放失败」。
        //   故回退一律 yes，硬解失败自动转软解，保证永远能出画。
        //
        // ✅ 2026-10-11：**直播放开硬解，与点播统一为「优先硬解 + 自动回退软解」**。
        //   依据：① 官方 mpv-android 对直播/点播不区分，统一用 HWDECS 列表，
        //         说明「直播不能硬解」并非官方限制；
        //         ② hwdec-software-fallback 恒为 yes（下方），硬解一旦失败会自动
        //         转软解，因此放开直播**不会**造成「播不了」，最坏情况等价于原先的软解；
        //         ③ 原先直播全绿的归因不明（见上），需在列表写线下重新验证，
        //         不能把一条未确证归因的旧结论当作永久禁令。
        //   ⚠️ 仍保留「硬件解码」总开关的作用：用户关闭时直播点播一起转软解。
        //   若真机复现直播全绿，回退方式：把本行改回 `!isLive && hardwareDecoding` 即可。
        val useHardware = hardwareDecoding
        val allowSoftwareFallback = true
        core?.setPropertyString(handle, "hwdec-software-fallback", "yes")
        // hwdec 是 UPDATE_HWDEC 选项，mpv 把所有选项同时注册为同名属性，
        // 故此处经 setPropertyString 运行时下发即可（loadfile 之前生效）。
        //
        // ✅ 2026-10-11：**恢复官方 mpv-android 的列表写法**（原先写死单个 mediacodec-copy）。
        //   官方 MPVView 常量：HWDECS = "mediacodec,mediacodec-copy"，语义是
        //   「先试零拷贝 mediacodec；不可用则自动降级到拷贝变体；再不行才软解」。
        //
        //   为什么之前写死 copy（历史真相，保留备查）：
        //     `mediacodec`（零拷贝）把解码器输出直接绑到 Flutter 外部纹理的 Surface 上，
        //     Amlogic 驱动判定该 Surface 的 consumer 是 GL（GRALLOC_USAGE_HW_TEXTURE）
        //     且不用 HWC，于是走「Use OSD layer」分支，把输出 buffer 上限硬卡在 14；
        //     而 ACodec 从 19 起步、最小只退到 16，永远降不到 14 →
        //     `4kosd set output error, newBufferCount 16 > 14` → OMX_ErrorInsufficientResources(-1010)
        //     → 在**该台 Amlogic 设备**上 mediacodec 100% 失败。
        //     `mediacodec-copy` 走 ffmpeg 的拷贝变体：mpv 创建**不带 Surface** 的
        //     mediacodec device（hwcontext_mediacodec.c 的 mc_device_init 在无 surface 时
        //     直接返回 0），改用 ByteBuffer 输出 → 不进 OSD 分支 → 上限 14 失效。
        //
        //   为什么现在改回列表（本轮决策）：
        //     写死 copy 虽能出画，但等于**永久关闭零拷贝路径**——在非 Amlogic
        //     或 OSD 上限更高的设备上，本可零拷贝却仍多走一次「显存→内存」拷帧，
        //     徒增带宽与功耗。列表写法让 mpv 自己在运行时逐级降级，
        //     既保住 Amlogic 的可用性（最终仍会落到 copy），又让其他设备拿到最优路径。
        //     官方把 mediacodec 放首位、copy 作兜底，正是这个意图。
        //     降级过程会打印 -1010 报错，属**预期噪音**，不代表硬解失效；
        //     真伪以 hwdec-current 的最终取值为准（见 onHwdecProbeTick）。
        core?.setPropertyString(
            handle,
            "hwdec",
            if (useHardware) "mediacodec,mediacodec-copy" else "no"
        )
        // 🔴🔴 2026-10-12 23:10 【撤除强制色彩转换】—— 推翻上一版的整条推理链。
        //
        // 【上一版做了什么】在此处无条件下发：
        //     core.command("vf", "add",
        //         "format=colormatrix=bt709:colorlevels=tv:primaries=bt709")
        //   其前提是：「硬解走 mediacodecdec.c，不读 SPS 的 VUI 色彩 →
        //   frame->colorspace = AVCOL_SPC_UNSPECIFIED(0) → mpv 只能猜 →
        //   猜成 BT.601 → 色度错 → 深橄榄绿 #0d2b0d」。
        //
        // 【真机日志如何推翻它】XiaoPaiTech BA001.2026101220（24.7 MB 真机日志）：
        //     [绿屏取证] colormatrix='bt.709'  (hwdec=mediacodec-copy, isLive=true, viewId=0)
        //     [绿屏取证] primaries='bt.709'
        //     [绿屏取证] colorlevels='limited'
        //   三条绿屏源（viewId=0/1/2）读数完全一致。
        //   ⇒ 源色彩参数**非空、非 0、且就是 BT.709 / limited**，
        //     即「硬解读不到 VUI」这一前提在该源上**不成立**（至少对 mpv 暴露出的
        //     video-params 不成立）。绿屏时色彩参数是对的，所以绿屏不是色彩元数据缺失导致的。
        //
        // 【为什么必须撤】`vf=format` 的语义是**强制转换**，不是「补齐缺失元数据」：
        //     - 源本就是 BT.709 → 强制 BT.709 = 恒等操作，**对绿屏毫无作用**
        //     - 源是 BT.601     → 强制 BT.709 = **把正确的转成错误的**，主动制造色偏
        //   （依据 video/filter/vf_format.c L74-79：colormatrix 覆写 repr.sys、
        //     colorlevels 覆写 repr.levels、primaries 覆写 color.primaries。）
        //   故上一版注释「不劣于修复前，属严格改进」的结论**是错的**，
        //   真实情况是「对绿屏源无用、对其他源有害」，现予推翻并撤除。
        //
        // 【本段留下的教训，务必记住】
        //   1. 加任何「修正」型滤镜前，**先打印并核对源的实际参数**，再决定下发什么。
        //      本次是「先下发 → 才在日志里看到真相」，顺序完全颠倒。
        //   2. `vf=format` 与 `--video-params` 类选项都是**覆写**语义，不区分
        //      「源缺失」与「源已有」，因此不能用来做「兜底补默认值」——
        //      兜底必须**先读后判**（读到空串才补）。
        //   3. 绿屏真因**仍未锁定**，但已可排除「色彩元数据缺失」这一方向。
        //      下一步应聚焦直播与点播的真实差异（源特性 / FCC 网关 / 编码细节），
        //      而不是继续在色彩参数上打转。
        //
        // 🔴🔴 2026-10-12 23:2x 【决定性新证据：模拟器不绿，真机绿】
        //   用户实测：同一份代码、同一条绿屏源，在 **Android 模拟器上完全不绿屏**，
        //   只有 **XiaoPaiTech BA001 真机（Amlogic 方案）** 绿屏。
        //
        //   这一个事实就**整段否定了「色彩参数/码流理解错误」这一大类假设**：
        //   若真因是「播放器把 BT.709 当 BT.601 解」或「色彩元数据为空导致猜错」，
        //   那么模拟器（同样跑 libmpv + mediacodec 软硬解栈）**必然同样绿屏** ——
        //   因为色彩矩阵变换是**平台无关**的纯计算。
        //   模拟器不绿 ⇒ 真因在**平台/硬件/驱动层**，不在色彩语义层。
        //
        //   因此绿屏的候选方向（按可能性排序，待验证）：
        //     ① MediaCodec 硬解输出的 GraphicBuffer 在 Amlogic 上的**实际 YUV 排列
        //        或 plane 步幅（stride）**与 GL 纹理采样约定不一致；
        //        `mediacodec-copy` 用 av_image_copy 拷到软件帧时，
        //        若源 stride 非标准（如未对齐的奇数值），逐行拷贝会整体错位 →
        //        表现为色度平面被「斜切」，肉眼即深橄榄绿。
        //        模拟器解码器 stride 规整，故不复现。
        //     ② Amlogic OSD 输出上限（本文件 L185/L622 注释里的
        //        `4kosd newBufferCount 16 > 14` → -1010）使 buffer 分配降级，
        //        降级后的格式协商与预期不符。
        //     ③ 真机 GPU（Mali）对特定色彩空间/量化范围的纹理采样默认值
        //        与模拟器（宿主 GPU，如 SwiftShader/Intel）不同。
        //
        //   ⇒ 下一步排查必须以**真机**为准，且要抓的是：
        //        · hwdec 初始化的真实返回码（而非 hwdec-current 的最终值）
        //        · 实际 pixelformat（yuv420p / nv12 / …）
        //        · 每行的 linesize/stride，与宽度比较是否对齐
        //     而**不是**继续调 colormatrix / primaries / colorlevels。
        //
        // 🔴🔴 2026-10-24 【撤除 vf 清理命令 —— 这才是 err=-4 的真凶】
        //
        // 【原写法】core?.command(handle, arrayOf("vf", "remove"))
        //
        // 【根因】mpv 0.37+ 把 `vf` 改成了 sub-command 风格：
        //     vf add <filter> [<filter-options>]
        //     vf remove <filter>          ← 必须带 filter 名
        //     vf toggle <filter>
        //   无参的 `vf remove` 缺少必填的 filter 名，mpv 直接返回
        //   MPV_ERROR_INVALID_PARAMETER(-4)。本工程预编译的 libmpv.so 是
        //   mpv 0.41（其 flags 表含 insert-at / insert-at-play，仅 0.39+ 才有），
        //   正落在这个版本区间。
        //
        // 【铁证：归因唯一】真机日志 XiaoPaiTech BA001.2026102409（legacy）：
        //     E HeinPlayMpvJni: command err=-4 (invalid parameter)   × 8
        //   与 8 次 open 严格一一对应，且每次的时间戳**早于**同一次 open 的
        //   `open url=` 日志仅 1ms —— 即它发生在 loadfile **之前**，
        //   与 loadfile 的参数元数无关。
        //   对照组：主工程 hain_tv 的 executeOpen **根本没有这一行**，
        //   同批真机日志 err=-4 = 0；而两边的 loadfile 写法在本次修复后
        //   已完全一致（都是 loadfile <url> replace），
        //   唯一残留差异就是本行 ⇒ 差异归因唯一。
        //
        // 【为什么可以安全删掉，而不是改成 vf remove @xxx】
        //   ① 每次 open 都会 **销毁并重建 mpv 实例**（日志实测：
        //      mpv_create → mpv_destroy → mpv_create），而 vf 是**实例级**全局
        //      选项 ⇒ 新实例的滤镜链本来就是空的，**根本不存在残留可清**；
        //   ② 2026-10-12 起本工程**已不再添加任何 vf**（强制色彩转换已撤除），
        //      本命令从建立起就是一个无效动作；
        //   ③ 主工程 hain_tv 同样没有这一步 ⇒ 行为对齐。
        //   直接删除是最稳、且与主工程一致的做法。
        //
        // 【若将来确实需要清空滤镜链】正确写法是下发空 property：
        //   core?.setPropertyString(handle, "vf", "")
        //   （mpv 的 vf 是 option-list property，置空串即清空整条滤镜链），
        //   **不要**再写无参的 `vf remove`。
        if (!headers.isNullOrEmpty()) {
            // http-header-fields 是 file-local option：在 loadfile 之前经 property
            // 设置，会成为下一个文件的默认值。
            val headerStr = headers.entries.joinToString("\r\n") { "${it.key}: ${it.value}" }
            core?.setPropertyString(handle, "http-header-fields", headerStr)
        }
        // 🔴 2026-10-24 **修 mpv `command err=-4 (invalid parameter)`**。
        //
        //   原写法：`loadfile <url> replace -1 start=<秒>`
        //   mpv 0.38+ 的签名是 `loadfile <url> [<flags> [<index> [<options>]]]`，
        //   `-1` 落到 **index** 位置；而 index 必须是合法的播放列表下标（>=0），
        //   于是整条命令以 MPV_ERROR_INVALID_PARAMETER(-4) 失败。
        //   （libmpv.so 内 flags 表含 insert-at / insert-at-play → 该库是 mpv 0.41。）
        //
        //   真机实测（Xiaomi 12S Pro，2026-10-24 09:41，legacy）：
        //   `E HeinPlayMpvJni: command err=-4 (invalid parameter)` 与 9 次 open 一一对应；
        //   同批 hain_tv 手机版 / TV 版日志 err=-4 均为 0 —— 唯一差异就是 legacy 多传的 "-1"。
        //
        //   改法：start 从 loadfile 的 **options** 挪到 **property**（file-local option），
        //   在 loadfile 之前下发。mpv 官方即支持「loadfile 前设 start 属性」，
        //   语义与原 options 写法等价；loadfile 只剩 2 个参数，永不越界。
        val cmd = mutableListOf("loadfile", url, "replace")
        if (startAtMs > 0) {
            core?.setPropertyString(handle, "start", "${startAtMs / 1000.0}")
        }
        // ⚠️ 2026-10-11：新一轮 open 重置探针状态（首帧前 hwdec-current 不可信）。
        hwdecProbeVideoStarted = false
        hwdecProbeLogged = false
        useHardwareRequested = useHardware
        isLiveStream = isLive
        // ⚠️ 2026-10-12：同步重置降级链诊断状态，避免上一轮的轨迹串进本轮。
        hwdecTrace = StringBuilder()
        hwdecTraceLast = ""
        firstPosLogged = false
        openAtMs = System.currentTimeMillis()
        Log.i(
            TAG,
            "open url=$url start=${startAtMs}ms " +
                "hwdec=${if (useHardware) "mediacodec,mediacodec-copy" else "no"} " +
                "fallback=${if (allowSoftwareFallback) "yes" else "no"} isLive=$isLive " +
                "headers=${headers?.size ?: 0} viewId=$viewId"
        )
        core?.command(handle, cmd.toTypedArray())
    }

    private fun flushPendingOpen() {
        val pending = pendingOpen ?: return
        pendingOpen = null
        executeOpen(pending)
    }

    fun handleMethod(call: MethodCall, result: MethodChannel.Result) {
        // 🔴 2026-10-24：pause 撞上「view 已销毁」时**降级为成功**。
        //
        //   背景与 MpvPlugin 层对 NO_VIEW 的降级同源，只是**竞态落在不同的一侧**：
        //     · view 已从 views 表摘除 → MethodChannel 拿到 view==null → PlatformException(NO_VIEW)
        //     · view 还在 views 表、但内部已 dispose → PlatformException(DISPOSED, "mpv view disposed")
        //   legacy 的实际时序是**后者**：Flutter 卸载 PlatformView 之前，
        //   MpvViewContainer.dispose() 先跑（core!!.destroy(handle) 已执行、handle/core 已归零），
        //   removeView 发生在更晚。故只豁免 NO_VIEW 覆盖不到 legacy —— 真机日志里
        //   `MpvBackend pause error: mpv view disposed` 仍会刷（I 级，非故障，
        //   但语义仍被报成"失败"，与实际已达成的「停止播放」不符）。
        //
        //   「停止播放」的语义此时**已经达成**（mpv 实例已销毁，音频画面随之停止），
        //   故与 NO_VIEW 同等处理：pause 返回成功；其余命令仍报 DISPOSED。
        if (disposed) {
            if (call.method == "pause") {
                Log.i(TAG, "pause 命中已销毁 view(viewId=$viewId)，按已停止处理")
                result.success(null)
                return
            }
            result.error("DISPOSED", "mpv view disposed", null)
            return
        }
        // ⚠️ 2026-10-12 崩溃修复：`disposed` 是普通 Boolean，由主线程在 dispose() 写入、
        //   却由未定义线程在此读取，JVM 允许读到陈旧值（非 volatile）。
        //   故除 disposed 外，再以 handle/core 的实际可用性做二次把关——
        //   dispose() 已把两者一并归零，这里的判空就是最后一道防线。
        if (handle == 0L || core == null) {
            if (call.method == "pause") {
                Log.i(TAG, "pause 命中已销毁 view(viewId=$viewId)，按已停止处理")
                result.success(null)
                return
            }
            result.error("DISPOSED", "mpv view disposed", null)
            return
        }
        try {
            when (call.method) {
                "open" -> {
                    val args = mapOf(
                        "url" to call.argument<String>("url"),
                        // Dart 侧 startAtMs 是 int（StandardMessageCodec 编成 Integer/Long），
                        // 用 Number 收再转 Long；原先按 Double 收会拿到 null，
                        // 导致续播定位的 start= 被静默丢弃。
                        "startAtMs" to (call.argument<Number>("startAtMs")?.toLong() ?: 0L),
                        "headers" to call.argument<Map<String, String>>("headers"),
                        "hardwareDecoding" to (call.argument<Boolean>("hardwareDecoding") ?: true),
                        // 直播标记：直播无硬解开关，需始终允许软解回退（见 executeOpen）。
                        "isLive" to (call.argument<Boolean>("isLive") ?: false)
                    )
                    if (!initialized) {
                        // surface 尚未就绪，mpv 未 initialize：暂存，initialize 后补发。
                        Log.i(TAG, "open 早于 surface 就绪，暂存 viewId=$viewId")
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
                    core?.command(handle, arrayOf("seek", "$posSec", "absolute"))
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
                    // BoxFit → mpv 显示比例：
                    //   contain（原始比例）：保持宽高比 + 不裁剪
                    //   cover（填充）      ：保持宽高比 + panscan 拉满（裁边）
                    //   fill（拉伸）       ：不保持宽高比，直接铺满
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
        if (disposed) return
        val payload = mapOf(
            "viewId" to viewId,
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

    /** 纹理路线：把 textureId 作为事件通道首条消息推回 Dart。 */
    private fun pushTextureId() {
        val producer = surfaceProducer ?: return
        val tid = producer.id()
        // ⚠️ 2026-10-12 直播绿屏诊断（只增加日志，不改行为）：
        //   实测现象「直播一直绿屏但有声音、点播正常」。绿屏 = Texture 参与了
        //   合成但内容未初始化。本行把「纹理自身状态」与「Surface 状态」一并
        //   打出来，用于区分三种可能：
        //     ① producer.surface 无效      → 纹理根本没生产端
        //     ② surface 有效但未 attach 给mpv → mpv 渲染到了别处
        //     ③ 都正常但仍绿                → 问题在 Flutter 消费端（合成/尺寸）
        val s = try {
            producer.surface
        } catch (_: Exception) {
            null
        }
        Log.i(
            TAG,
            "推送 textureId=$tid viewId=$viewId " +
                "纹理尺寸=${surfaceWidth}x${surfaceHeight} " +
                "surface有效=${s?.isValid} " +
                "mpv已attach=${currentSurface === s} " +
                "mpv已initialized=$initialized"
        )
        eventSink?.success(mapOf("type" to "texture", "textureId" to tid))
    }

    fun setEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
        if (sink != null) {
            pushTextureId()
            pushState()
        }
    }

    override fun getView(): View = placeholderView

    override fun dispose() {
        // 🔴 幂等守卫（2026-10-29 真机复盘新增）：本方法有**两条**调用路径 ——
        //   ① Flutter 引擎在 PlatformView 从 widget 树移除时调用；
        //   ② Dart 侧 backend.dispose() 经方法通道 'dispose' 调用。
        //   「退出播放页」时两条路径会先后到达，此前没有守卫时第二个视图会
        //   **再 release 一次同一个 SurfaceProducer** → BufferQueue 状态不一致
        //   （历史症状 `detachBuffer: slot N is not owned by the producer`，
        //   slot 涨到上限 63）→ 黑屏/掉帧/整窗不再出帧。
        if (disposed) {
            Log.i(TAG, "dispose 重复调用已忽略 viewId=$viewId")
            return
        }
        // ⚠️ 2026-10-12：**会话小结**——在销毁前把这一轮的关键事实一次性打出来。
        //   直播短命失败（如 2026-10-11 的 3.7s 就 dispose）时，
        //   探针可能因阈值/时序原因没能输出，本行是最后的兜底证据：
        //   能回答「到底有没有解码过」「降级链走到哪一级」。
        val sessionMs = if (openAtMs > 0) System.currentTimeMillis() - openAtMs else -1
        Log.i(
            TAG,
            "[硬解诊断] 会话小结 viewId=$viewId isLive=$isLiveStream 存活=${sessionMs}ms " +
                "最后position=${"%.3f".format(positionSec)}s duration=${"%.3f".format(durationSec)}s " +
                "已出过首帧=$firstPosLogged 探针已触发=$hwdecProbeVideoStarted 探针已输出=$hwdecProbeLogged " +
                "hwdec轨迹=${if (hwdecTrace.isEmpty()) "(无)" else hwdecTrace.toString()} " +
                "末次hwdec='$hwdecCurrentRaw'"
        )
        Log.i(TAG, "dispose viewId=$viewId")
        disposed = true
        try {
            if (handle != 0L && core != null) {
                core!!.destroy(handle)
            }
        } catch (e: Exception) {
            Log.e(TAG, "destroy 异常 viewId=$viewId: ${e.message}")
        }
        // ⚠️ 2026-10-12 崩溃修复（SIGSEGV / signal 11）：
        //   原实现只把 handle 置 0、**没有把 core 置 null**，于是销毁后留下
        //   「core != null 且 handle == 0」的不一致状态。此后任何一条控制指令
        //   （pause/seek/setVolume/setSpeed/setFit/attachSurface/...）若在
        //   handleMethod 的 disposed 判断窗口之外到达，就会走
        //   `core?.setPropertyString(handle, ...)` → 把 0 传给 C++
        //   → `reinterpret_cast<MpvInstance*>(0)` 解引用 → SIGSEGV。
        //   实测（2026-10-11 日志）：`mpv 实例已销毁` 之后 4ms 仍有
        //   `MpvBackend pause error: mpv view disposed` 到达，即该窗口真实存在。
        //   同时播放直播时「open 后立刻 dispose」高频交错（实测间隔仅 242ms），
        //   而 mediacodec 初始化窗口宽达 1~3s，命中概率被放大到必现。
        //   修法：销毁后把两者一并归零，让所有 `core?.xxx(handle, ...)` 天然短路。
        handle = 0
        core = null
        // 🔴 SurfaceProducer 延后释放（2026-10-29 真机复盘新增）：
        //   它由引擎的 TextureRegistry 持有，引擎注销条目时自己也会释放；
        //   立刻释放还可能撞上 mpv 销毁后仍在飞行中的 buffer ——
        //   这正是历史 slot 泄漏的成因。改为延后 1.5s 释放，让引擎注销与
        //   in-flight buffer 落定后再放，避免拖垮后续的 SurfaceSyncGroup。
        mainHandler.postDelayed({
            try {
                surfaceProducer?.release()
                Log.i(TAG, "surfaceProducer 已释放 viewId=$viewId（延后 1.5s）")
            } catch (e: Exception) {
                Log.w(TAG, "surfaceProducer.release 异常（引擎可能已释放）: ${e.message}")
            }
        }, 1500)
        eventSink = null
    }
}

/** PlatformView 工厂。 */
class MpvViewFactory(
    private val messenger: BinaryMessenger,
    private val textureRegistry: TextureRegistry?
) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
    private val views = mutableMapOf<Int, MpvPlayerView>()

    override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
        Log.i(TAG, "MpvViewFactory.create viewId=$viewId args=$args")
        val view = MpvPlayerView(context, viewId, textureRegistry)
        views[viewId] = view

        // 每个视图一条独立事件通道，Dart 侧按 viewId 监听。
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

/** mpv Flutter 插件入口：注册 PlatformView 工厂 + 控制通道。 */
class MpvPlugin : io.flutter.embedding.engine.plugins.FlutterPlugin {
    private var factory: MpvViewFactory? = null

    override fun onAttachedToEngine(binding: io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding) {
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
                //   dispose() 被调用（销毁由引擎驱动，应用层拿不到可靠时机）。
                //   于是 LivePlayer.dispose() 里的 pause 必然打在已从 views 表
                //   摘除的 view 上 → PlatformException(NO_VIEW)。
                //
                //   而「停止播放」这个语义**已经达成**：view 的 dispose() 里先执行
                //   了 core!!.destroy(handle)（mpv 实例已销毁，音频与画面随之
                //   停止），之后才把 view 从 views 表摘除。故此处报 NO_VIEW 等于
                //   把正常的生命周期竞态暴露成故障。
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

    override fun onDetachedFromEngine(binding: io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding) {
        factory = null
    }
}
