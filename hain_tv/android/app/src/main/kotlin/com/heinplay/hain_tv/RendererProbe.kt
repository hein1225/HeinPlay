package com.heinplay.hain_tv

import android.os.Build
import android.util.Log
import java.io.File

/**
 * 渲染后端能力探测：决定 mpv 走 Vulkan 还是 GLES。
 *
 * ## 为什么需要运行时探测，而不是写死
 *
 * 只编一份 libmpv.so 同时带 Vulkan 与 GLES 两个后端（见 buildscripts/mpv.sh），
 * 运行时用 `gpu-api` 二选一。选错的后果：
 *   · 设备无 Vulkan 驱动却强制 `gpu-api=vulkan` → mpv 创建 GPU 上下文失败，
 *     表现为**黑屏只有声音**（比软解回退更糟，用户无从规避）。
 *   · 设备有 Vulkan 却永远走 GLES → 白编了 Vulkan，零收益。
 * 故必须探测。
 *
 * ## 探测两层
 *
 * 1. **系统是否声明 Vulkan 特性**：`PackageManager.hasSystemFeature(FEATURE_VULKAN_HARDWARE_VERSION)`
 *    与 `FEATURE_VULKAN_HARDWARE_LEVEL`。这是 Android 官方途径，反映**厂商声明**。
 * 2. **驱动库是否真的存在且可加载**：`System.loadLibrary("vulkan")` 试探。
 *    仅看 feature 不够——存在厂商声明了特性但驱动 .so 缺失/损坏的情况
 *    （定制 ROM、精简固件）。真实可加载才算数。
 *
 * 只要任一层失败就不启用 Vulkan，回落 GLES，保证能出画。
 *
 * ## ABI（v8a 优先）
 *
 * `Build.SUPPORTED_ABIS` 是**按优先级排序**的数组，首元素即系统首选 ABI。
 * 64 位设备上通常是 `arm64-v8a` 在前。本工程两个 ABI 都打包，安装时由
 * Android 自行按此顺序挑选，无需应用干预；这里探测是为了**日志可观测**
 * 以及在两 ABI 行为有差异时能定位。
 */
object RendererProbe {

    private const val TAG = "RendererProbe"

    /**
     * libplacebo 要求的 Vulkan 最低版本（`PL_VK_MIN_VERSION`）。
     *
     * 取值来源：libplacebo `src/include/libplacebo/vulkan.h`：
     *   `#define PL_VK_MIN_VERSION VK_API_VERSION_1_1`
     * 设备选择时 `pl_vulkan_choose_device`（src/vulkan/context.c）会对每个
     * 候选物理设备做 `if (prop.properties.apiVersion < PL_VK_MIN_VERSION)
     * { PL_DEBUG("-> excluding due to too low API version"); continue; }`，
     * 全部被排除则 `PL_FATAL("Found no suitable device, giving up.")`。
     *
     * ⚠️ `pl_vulkan_params.max_api_version` 是**上限**，无法用它放宽下限。
     * 故应用层只能自己按此门槛决定是否启用 Vulkan。
     *
     * 🔴🔴 2026-10-15 下调：1.2 -> 1.1（与 libplacebo 源码改动**成对**）。
     *
     *   用户硬要求主工程走 Vulkan，而主力真机（荣耀平板 V8 Pro）只支持
     *   Vulkan **1.1.0**。上游门槛 1.2 会把该设备直接排除。
     *
     *   降级不是只改这一个常数 —— libplacebo 侧同步改了四处（见
     *   `.mpv-build/thirdparty/libplacebo` 与
     *   `.mpv-android/.../deps/libplacebo` 的对应注释）：
     *     ① `PL_VK_MIN_VERSION` 宏 1.2 -> 1.1
     *     ② `get_spirv_version()` 对 <1.2 返回 SPIR-V 1.3（1.1 的保证版本）
     *     ③ `check_required_features()` 对 <1.2 改查扩展结构体
     *     ④ `load_vk_fun()` 对 <1.2 加 KHR/EXT 后缀回退
     *   任意一处缺失都会导致「黑屏只有声音」或「设备被放弃」，
     *   故**必须整体生效**，不能只改这一行。
     *
     *   ⚠️ 前提：设备的 Vulkan 1.1 驱动必须提供 `VK_KHR_timeline_semaphore`
     *      与 `VK_EXT_host_query_reset` 扩展（libplacebo 的必需特性）。
     *      缺失时 libplacebo 会在日志里打出「兼容扩展自检 ... 设备支持=否」
     *      并放弃设备，应用层会安全回退到 OpenGL ES。
     */
    private const val PL_VK_MIN_VERSION = 1 shl 22 or (1 shl 12) // VK_MAKE_VERSION(1,1,0)

    /**
     * 把 Vulkan 的 `apiVersion` 整数解成可比较的数值。
     *
     * Vulkan 版本编码：`major << 22 | minor << 12 | patch`
     * （`VK_MAKE_VERSION`）。Android 的 `FEATURE_VULKAN_HARDWARE_VERSION`
     * 返回的正是这个整数，例如 `4198400` → 1.1.0、`4202496` → 1.2.0。
     */
    private fun decodeVulkanVersion(v: Int): Int = v

    /** 把 Vulkan 版本整数格式化成人读字符串，供日志使用。 */
    private fun formatVulkanVersion(v: Int): String {
        if (v <= 0) return "无"
        val major = v ushr 22
        val minor = (v ushr 12) and 0x3ff
        val patch = v and 0xfff
        return "$major.$minor.$patch"
    }

    /** 渲染后端 */
    enum class Backend {
        /** Vulkan（优先） */
        VULKAN,

        /** OpenGL ES（回退） */
        OPENGL,
    }

    /** 探测结果快照，便于日志与一次性计算缓存 */
    data class Capability(
        /** 设备首选 ABI（Build.SUPPORTED_ABIS[0]） */
        val primaryAbi: String,
        /** 是否 64 位 ARM */
        val isArm64: Boolean,
        /** 系统声明了 Vulkan 硬件特性 */
        val hasVulkanFeature: Boolean,
        /** 声明的 Vulkan 硬件等级（0 表示未声明） */
        val vulkanLevel: Int,
        /** 声明的 Vulkan 硬件版本（0 表示未声明） */
        val vulkanVersion: Int,
        /** libvulkan.so 可加载 */
        val vulkanLoadable: Boolean,
        /** 最终选定的后端 */
        val backend: Backend,
    ) {
        /** 设备声明的 Vulkan 版本是否达到 libplacebo 的下限 */
        val vulkanVersionEnough: Boolean
            get() = decodeVulkanVersion(vulkanVersion) >= PL_VK_MIN_VERSION

        /**
         * 是否可用 Vulkan（三层探测都通过）。
         *
         * 🔴 2026-10-14：**必须校验版本**，这是原实现的缺陷。
         *
         * 原实现只判「有特性 + 能 dlopen」，于是把 Vulkan 1.1 的设备也判为
         * 可用，下发 `gpu-context=androidvk` 后 mpv 在 libplacebo 的设备选择
         * 阶段被 `PL_VK_MIN_VERSION` 挡下，报
         * `Found no suitable device, giving up` + `Failed initializing any
         * suitable GPU context`，结果是**黑屏只有声音**（比软解回退更糟）。
         *
         * ⚠️ mpv 侧**不会**自动退回 OpenGL：`create_in_contexts`
         *   （video/out/gpu/context.c）在用户显式指定 `gpu-context` 时只试
         *   该 context 一个，失败即 `Failed initializing any suitable GPU
         *   context`。故回退必须由这里承担。
         */
        val vulkanUsable: Boolean
            get() = hasVulkanFeature && vulkanLoadable && vulkanVersionEnough
    }

    /**
     * 本进程的探测结果。用 @Volatile + 双检锁缓存：
     * 探测涉及 PackageManager 查询与一次 dlopen，没必要每次建 View 都做。
     */
    @Volatile
    private var cached: Capability? = null

    fun capability(): Capability {
        cached?.let { return it }
        synchronized(this) {
            cached?.let { return it }
            val c = doProbe()
            cached = c
            return c
        }
    }

    private fun doProbe(): Capability {
        val abis = Build.SUPPORTED_ABIS
        val primaryAbi = abis.firstOrNull() ?: "unknown"
        val isArm64 = abis.any { it == "arm64-v8a" }

        // ---- 第 1 层：系统特性声明 ----
        var hasFeature = false
        var level = 0
        var version = 0
        try {
            val pm = AppContextHolder.context?.packageManager
            if (pm != null) {
                hasFeature = pm.hasSystemFeature(
                    android.content.pm.PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
                )
                level = pm.systemAvailableFeatures
                    .firstOrNull {
                        it.name ==
                            android.content.pm.PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL
                    }?.version ?: 0
                version = pm.systemAvailableFeatures
                    .firstOrNull {
                        it.name ==
                            android.content.pm.PackageManager.FEATURE_VULKAN_HARDWARE_VERSION
                    }?.version ?: 0
            }
        } catch (e: Exception) {
            Log.w(TAG, "查询 Vulkan 系统特性失败: ${e.message}")
        }

        // ---- 第 2 层：驱动库真实可加载 ----
        // 注意：这里 loadLibrary 成功会**永久**把 libvulkan.so 载入本进程，
        // 之后 libplacebo 自己 dlopen("libvulkan.so.1") 时命中同一 handle，
        // 无副作用；反之若这里失败，说明驱动确实不可用，正好据此回退。
        var loadable = false
        try {
            System.loadLibrary("vulkan")
            loadable = true
        } catch (e: Throwable) {
            Log.w(TAG, "libvulkan.so 不可加载: ${e.message}")
        }

        // 🔴 2026-10-14 修正：backend 判定必须**复用 Capability.vulkanUsable**，
        //   而不能在这里重写裸条件。原实现是 `hasFeature && loadable`，
        //   漏掉了「Vulkan 版本是否达到 libplacebo 下限（PL_VK_MIN_VERSION=1.2）」
        //   这一层，于是把 Vulkan 1.1 的设备也判为可用、下发 androidvk，
        //   最终在 libplacebo 设备选择阶段硬失败：
        //     mpv[vo/gpu-next/libplacebo] fatal: Found no suitable device, giving up.
        //     mpv[vo/gpu-next] error: Failed initializing any suitable GPU context!
        //   表现为黑屏只有声音。此处与 vulkanUsable 保持单一事实来源。
        val probe = Capability(
            primaryAbi = primaryAbi,
            isArm64 = isArm64,
            hasVulkanFeature = hasFeature,
            vulkanLevel = level,
            vulkanVersion = version,
            vulkanLoadable = loadable,
            backend = Backend.OPENGL,
        )
        val c = probe.copy(
            backend = if (probe.vulkanUsable) Backend.VULKAN else Backend.OPENGL,
        )

        Log.i(
            TAG,
            "设备能力探测：ABI 首选=$primaryAbi 含arm64=$isArm64 " +
                "Vulkan特性=$hasFeature(w${version}/l${level} " +
                "版本=${formatVulkanVersion(version)}) " +
                "驱动可加载=$loadable " +
                "版本达标=${c.vulkanVersionEnough}(需≥${formatVulkanVersion(PL_VK_MIN_VERSION)}) " +
                "-> 渲染后端=${c.backend.name}" +
                if (hasFeature && loadable && !c.vulkanVersionEnough)
                    "（设备 Vulkan 版本低于 libplacebo 下限，回落 GLES 以保证出画）"
                else ""
        )
        return c
    }

    /**
     * 生成要下发给 mpv 的渲染选项。
     *
     * @param forceOpenGl 用户强制 GLES（设置页开关），true 时无视探测结果
     */
    fun rendererOptions(forceOpenGl: Boolean): Map<String, String> {
        val cap = capability()
        val opts = mutableMapOf<String, String>()
        // 🔴 2026-10-14 对齐鸿蒙（已验证可用的同源实现）：
        //   鸿蒙真机走 `vo=gpu-next` + **完全不下发 gpu-api / gpu-context 的
        //   Vulkan 指定**，由 mpv 自行协商，libplacebo 直接接管 Vulkan。
        //   证据：MpvBridge.ets L294 明写 "vo=gpu-next(Vulkan)"；
        //        鸿蒙 libmpv.so 含 -Dvulkan=enabled -Dshaderc=enabled；
        //        鸿蒙硬解走 VK_OHOS_external_memory（Vulkan interop）。
        //
        //   我们此前用 `vo=gpu`（mpv 的旧 GPU 输出层）+ 显式钉死
        //   gpu-api=vulkan。这是一条与鸿蒙**不同**的冷门组合，且实测播不了。
        //   既然鸿蒙那条路已被真机证明可用，这里直接对齐，不再另起炉灶。
        opts["vo"] = "gpu-next"
        val useVulkan = !forceOpenGl && cap.vulkanUsable
        if (useVulkan) {
            // 🔴 必须**显式**指定 Vulkan context，不能依赖 mpv 自动协商。
            //
            // 依据（video/out/gpu/context.c 的 contexts[] 数组顺序）：
            //   Vulkan contexts  : win / wayland / xlib / mac   ← 桌面平台
            //   OpenGL contexts  : ra_ctx_android (EGL_ANDROID) ← 第 25 行
            //   ...
            //   Vulkan contexts  : ra_ctx_vulkan_android (androidvk) ← 第 52 行
            // androidvk **排在 ra_ctx_android（OpenGL）之后**，而 gpu-api 默认值
            // 是 "auto"（context_type_list[0] = {"auto"}，匹配任意 type）。
            // 因此不下发任何指定时，mpv 按数组顺序先命中 OpenGL ES，**永远走不到
            // Vulkan** —— 「优先 Vulkan」的硬要求会静默落空。
            //
            // ⚠️ gpu-context 与 gpu-api 必须自洽：context.c 的 create_in_contexts()
            //   先按 name 命中 context，再拿 gpu-api（context_type_list）比对它的
            //   .type，不匹配就 continue 跳过。androidvk → "vulkan"。
            opts["gpu-context"] = "androidvk"
            opts["gpu-api"] = "vulkan"
            // Vulkan 下启用 libplacebo 的硬件解码互操作：mediacodec 解出的
            // AHardwareBuffer 直接作为 VkImage 导入，避免一次 GPU->CPU->GPU 拷贝。
            // 若设备/驱动不支持，mpv 会自行回退（配合 hwdec-software-fallback）。
            opts["hwdec"] = "mediacodec"
        } else {
            // 强制 GLES 路线：显式指定 android context（.type="opengl"）。
            // 这条必须钉死，否则可能又被协商回 Vulkan，用户的回退开关就失效了。
            opts["gpu-context"] = "android"
            opts["gpu-api"] = "opengl"
            // GLES 路线沿用既有的 mediacodec-copy（零拷贝在部分 Amlogic
            // 驱动上会把输出 buffer 上限卡在 14 导致失败，见渲染链历史排障）。
            opts["hwdec"] = "mediacodec-copy"
        }
        return opts
    }

    /** 供日志/诊断页展示的一行摘要 */
    fun summary(): String {
        val c = capability()
        val vk = if (c.vulkanUsable) {
            "Vulkan(w${c.vulkanVersion}/l${c.vulkanLevel})"
        } else {
            "无Vulkan(特性=${c.hasVulkanFeature},驱动=${c.vulkanLoadable})"
        }
        return "ABI=${c.primaryAbi} 后端=${c.backend.name} $vk"
    }
}

/**
 * 持有 Application Context，供 RendererProbe 查询 PackageManager。
 *
 * 不直接在 object 里引用 Context 是为了避免把 Activity 泄漏进静态字段；
 * 这里只存 applicationContext，生命周期与进程一致，安全。
 */
object AppContextHolder {
    @Volatile
    var context: android.content.Context? = null

    fun init(ctx: android.content.Context) {
        context = ctx.applicationContext
    }
}
