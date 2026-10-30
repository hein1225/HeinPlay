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

  /**
   * Player configurations.
   *
   * @param configDir     Directory of mpv configuration files, optional.
   * @param vo            Video output backend, optional.
   * @param osc           Whether to load the on-screen-controller, optional.
   * @param osd           Whether to load the on-screen-display, optional.
   * @param gpuContext    Graphics APIs, can be "ohos" (OpenGL) or "ohosvk" (Vulkan), optional.
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
    this.gpuContext = options.gpuContext ?? "ohos";
    this.alang = options.alang ?? "chi";
    this.slang = options.slang ?? "chi";
    this.hwdec = options.hwdec ?? true;
    this.deinterlace = options.deinterlace ?? false;
    this.logLevel = options.logLevel ?? MpvLogLevel.None;
    this.onReady = options.onReady ?? (() => {});
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
