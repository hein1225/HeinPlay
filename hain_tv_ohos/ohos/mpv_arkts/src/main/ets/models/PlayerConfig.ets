/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

interface PlayerConfigOptions {
  /**
   * Directory of mpv configuration files, optional.
   */
  configDir?: string;
  /**
   * Video output backend, optional.
   */
  vo?: string;
  /**
   * Whether to load the on-screen-controller, optional.
   */
  osc?: boolean;
  /**
   * Whether to load the on-screen-display, optional.
   */
  osd?: boolean;
  /**
   * Graphics APIs, can be "ohos" (OpenGL) or "ohosvk" (Vulkan), optional.
   */
  gpuContext?: string;
  /**
   * A prioritized list of audio languages to use, as IETF language tags, optional.
   */
  alang?: string;
  /**
   * A prioritized list of subtitle languages to use, as IETF language tags, optional.
   */
  slang?: string;
  /**
   * Whether to enable hardware acceleration, optional.
   */
  hwdec?: boolean;
  /**
   * Whether to enable deinterlace, optional.
   */
  deinterlace?: boolean;
  /**
   * Log level of mpv, optional.
   */
  logLevel?: MpvLogLevel;
  /**
   * Callback invoked when mpv player is initialized and ready for playback, optional.
   */
  onReady?: () => void;
  /**
   * 🔴 HeinPlay 扩展（2026-09-30）：追加/覆盖任意 mpv 选项。
   *
   * 动机：上游把常用选项全部写死在 Player.init() 里，宿主无法调整
   * `cache-secs`（预读窗口）、`demuxer-readahead-secs` 等与起播速度、
   * 预缓冲条直接相关的参数（上游只设了 demuxer-max-bytes=1024MiB，
   * 那是**容量上限**而非预读窗口，起播慢且看不到缓冲条）。
   *
   * 语义：这些键值对在 Player.init() 内置选项**之后**、
   * native.initialize() **之前**逐个 setOptionString 下发，因此可覆盖同名内置项。
   */
  extraOptions?: Map<string, string>;
  /**
   * 🔴 HeinPlay 路线 B（2026-09-30）：Flutter 纹理的 surfaceId。
   *
   * 必须在 native.initialize() **之前**作为 wid 注入 mpv，否则 vo=gpu-next
   * 的 openharmony GPU 上下文拿不到原生窗口 → 报 Missing surface pointer → 黑屏。
   * 路线 B 不走 XComponent（其在 flutter-ohos 纹理合成路径下永不回调 surface），
   * 故在此直接显式注入 surfaceId；为空时退回 onSurfaceCreated 注入路径。
   */
  surfaceId?: string;
}

export class PlayerConfig {
  readonly configDir: string;
  readonly vo: string;
  readonly osc: boolean;
  readonly osd: boolean;
  readonly gpuContext: string;
  readonly alang: string;
  readonly slang: string;
  readonly hwdec: boolean;
  readonly deinterlace: boolean;
  readonly logLevel: MpvLogLevel;
  readonly onReady: () => void;
  /** 见 PlayerConfigOptions.extraOptions。 */
  readonly extraOptions: Map<string, string>;
  /** 🔴 路线 B：Flutter 纹理 surfaceId（initialize 前作为 wid 注入）。 */
  readonly surfaceId?: string;

  /**
   * Player configurations.
   *
   * @param configDir     Directory of mpv configuration files, optional.
   * @param vo            Video output backend, optional.
   * @param osc           Whether to load the on-screen-controller, optional.
   * @param osd           Whether to load the on-screen-display, optional.
   * @param gpuContext    Graphics APIs, optional.
   *                      🔴 2026-10-01 修正：mpv 的 ra_ctx 注册名是 "openharmony"
   *                      （见 video/out/opengl/context_openharmony.c 的 .name 字段），
   *                      不是 "ohos" / "ohosvk"。传错名字 mpv 会报
   *                      "Unknown GPU context" 并拒绝初始化视频输出。
   * @param alang         A prioritized list of audio languages to use, as IETF language tags, optional.
   * @param slang         A prioritized list of subtitle languages to use, as IETF language tags, optional.
   * @param hwdec         Whether to enable hardware acceleration, optional.
   * @param deinterlace   Whether to enable deinterlace, optional.
   * @param logLevel      Log level of mpv, optional.
   * @param onReady       Callback invoked when mpv player is initialized and ready for playback, optional.
   */
  constructor(options: PlayerConfigOptions = {}) {
    this.configDir = options.configDir ?? "";
    this.vo = options.vo ?? "gpu-next";
    this.osc = options.osc ?? false;
    this.osd = options.osd ?? true;
    // 🔴🔴 2026-10-28 第六次修正：改用 Vulkan（"ohosvk"），不再默认 OpenGL。
    //   方针：除 legacy 版本外，全平台尽可能走 Vulkan。
    //
    //   本工程有**两条独立的 OHOS GPU 后端**，注册名只差三个字母，极易混淆：
    //     · "ohos"   → video/out/opengl/context_ohos.c  （OpenGL/EGL）
    //     · "ohosvk" → video/out/vulkan/context_ohos.c  （Vulkan，现默认）
    //   两者各有各的 ra_ctx_params 与 init()，改错一个等于没改，而且
    //   编译、链接、符号、字符串检查全都查不出来（只有反汇编或真机日志能发现）。
    //
    //   Vulkan 路径已确认完整可用：
    //     · context_ohos.c 完整实现，VK_PRESENT_MODE_FIFO_KHR
    //     · libvulkan.so 导出 vkCreateSurfaceOHOS（已在 DT_NEEDED 中）
    //     · hwdec_ohcodec_pl.c 提供 Vulkan 零拷贝硬解 interop
    //     · libplacebo 已打补丁启用 VK_OHOS_native_buffer / VK_OHOS_external_memory
    //     · 设备实测：Maleoon 910，ohosNativeBufferInteropCapable=true
    //
    //   ⚠️ 故意**不**配回退列表（不写 "ohosvk,ohos"）：单值才能让初始化失败在
    //      日志里明确报 "Failed initializing any suitable GPU context!"，
    //      而不是静默回退到 GL 却让人以为在用 Vulkan。
    this.gpuContext = options.gpuContext ?? "ohosvk";
    this.alang = options.alang ?? "chi";
    this.slang = options.slang ?? "chi";
    this.hwdec = options.hwdec ?? true;
    this.deinterlace = options.deinterlace ?? false;
    this.logLevel = options.logLevel ?? MpvLogLevel.None;
    this.onReady = options.onReady ?? (() => {});
    this.extraOptions = options.extraOptions ?? new Map<string, string>();
    this.surfaceId = options.surfaceId;
  }
}

export enum MpvLogLevel {
  /**
   * Disable absolutely all messages.
   */
  None = 0,
  /**
   * Critical/aborting errors.
   */
  Fatal = 10,
  /**
   * Simple errors.
   */
  Error = 20,
  /**
   * Possible problems.
   */
  Warn = 30,
  /**
   * Informational message.
   */
  Info = 40,
  /**
   * Noisy informational message.
   */
  V = 50,
  /**
   * Very noisy technical information.
   */
  Debug = 60,
  /**
   * Extremely noisy.
   */
  Trace = 70,
}
