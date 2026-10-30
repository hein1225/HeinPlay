/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

import { hilog } from '@kit.PerformanceAnalysisKit';
// HeinPlay 2026-10-07：NAPI 模块加载的统一入口。
//
// 【加载方式】静态 import 优先，动态 import() 兜底（两者都做 { default: ... } 解包）。
//   ets-loader 会把 `import x from 'libxxx.so'` 编译成
//   globalThis.requireNapi("xxx", true, "<bundle>/<module>")。
//
// 【历史弯路，勿重复】本次排查在此文件上反复横跳过，记录以免重蹈：
//   · 曾判定「静态 import 恒为 undefined（真机探针已证）」→ 改成纯动态 import()
//   · 又判定「动态 import 恒拿不到 NAPI 导出」→ 改回静态 import
//   两次观测都真实，但两次归因都错了。真因始终在 so 本身：
//   dlopen 失败时，静态 import 与动态 import() 都会拿到 undefined，
//   所以「哪种 import 写法」从来不是变量 —— 修好 so 之后两种写法都能用。
//   现在的写法（静态优先 + 动态兜底）对两种失败模式都免疫。
//
// 【判据】不要靠这里的日志推断 so 是否加载成功，看 aki 自己的注册日志：
//   AKI: register AKI addon: mpv_wrapper
//   有这条 = so 装载成功；没有 = dlopen 失败。鸿蒙对 NAPI 加载失败既不抛异常
//   也不打 dlopen 报错，这条是唯一可信信号。
import libmpv from 'libmpv_wrapper.so';


const TAG: string = 'HeinPlayMpv';
const DOMAIN: number = 0x03D00;

/** 动态 import 得到的 NAPI 模块（含 NativePlayer 类与 JSBind 对象） */
let mpvModule: ESObject = undefined;
/** 正在进行的加载 Promise，避免并发重复加载 */
let loadPromise: Promise<void> | null = null;

/**
 * 加载 libmpv_wrapper.so NAPI 模块。
 *
 * 2026-10-07 已修复两批未定义符号（同一个病，分两轮才查全）：
 *   ① OpenSSL：cross-file 曾指向 openssl_1_0_2u，而 FFmpeg 用 1.1.1u，
 *      残留 12 个 BIO_* / DTLS_* 未定义符号。
 *   ② OHOS NDK：mpv 静态链入 FFmpeg 的 libavcodec.a 后，
 *      ohaudiodec.c / ohvideodec.c 里的 OH_AudioCodec_*（10 个）、
 *      OH_VideoEncoder_*（13 个）被搬进 libmpv.so，而链接命令漏了
 *      -lnative_media_acodec / -lnative_media_venc。
 *      （若走 FFmpeg 的 .so，它自带 NEEDED 就没这问题；走 .a 必须自己补。）
 *
 * 【校验方法·勿退回单点 grep】交付前必须做「全部未定义符号 ↔ NEEDED 链提供者」
 * 的完整对账，而不是只查自己刚修的那一类符号 —— 只查一类正是本次返工的原因。
 * 见 plan/worklogs/2026-10-07-鸿蒙mpv加载失败真因2-libmpv漏链OHOS-NDK库.md。
 *
 * 加载顺序：静态 import（ets-loader 编译期已生成 requireNapi 调用）优先，
 * 失败再退回动态 import()；两者都可能拿到 { default: ... } 包装，需解包。
 * 动态 import 是异步的，而 new Player() 是同步的，故在插件挂载阶段就调用本函数预热，
 * 真正的等待由 MpvViewFactory.create() 之前的轮询窗口覆盖（见 MpvBridge.ets）。
 */
export async function ensureMpvModuleLoaded(): Promise<void> {
  if (mpvModule !== undefined && mpvModule !== null) {
    return;
  }
  if (loadPromise !== null) {
    return loadPromise;
  }
  loadPromise = (async (): Promise<void> => {
    // 从候选对象里取 NativePlayer，兼容 NAPI 直接导出与 { default: ... } 两种形态
    // （鸿蒙的 ESM 互操作会把 CommonJS 风格导出包一层 default）
    const unwrap = (c: ESObject): ESObject => {
      if (c === undefined || c === null) {
        return undefined;
      }
      if (c.NativePlayer !== undefined && c.NativePlayer !== null) {
        return c;
      }
      const d: ESObject = c.default;
      if (d !== undefined && d !== null
        && d.NativePlayer !== undefined && d.NativePlayer !== null) {
        return d;
      }
      return undefined;
    };

    let picked: ESObject = undefined;
    let pickedBy: string = '';

    // 路径 1：静态 import
    try {
      picked = unwrap(libmpv as ESObject);
      if (picked !== undefined) {
        pickedBy = '静态 import';
      }
    } catch (e1) {
      hilog.warn(DOMAIN, TAG, '静态 import libmpv 抛出: ' + e1);
    }

    // 路径 2：动态 import
    if (picked === undefined) {
      let dynVal: ESObject = undefined;
      try {
        dynVal = await import('libmpv_wrapper.so');
      } catch (e2) {
        hilog.warn(DOMAIN, TAG, '动态 import libmpv_wrapper.so 抛出: ' + e2);
      }
      picked = unwrap(dynVal);
      if (picked !== undefined) {
        pickedBy = '动态 import';
      }
    }

    try {
      if (picked === undefined) {
        throw new Error('静态 import 与动态 import 均未取得 NativePlayer'
          + '（通常是 libmpv.so 的未定义符号导致 dlopen 失败，请查 hilog 中的 dlopen 报错）');
      }
      mpvModule = picked;
      hilog.warn(DOMAIN, TAG, 'libmpv_wrapper.so 加载成功（经 ' + pickedBy
        + '）: NativePlayer=' + typeof picked.NativePlayer);
    } catch (e) {
      loadPromise = null;
      const msg: string = (e && e.message) ? e.message : String(e);
      hilog.error(DOMAIN, TAG, 'libmpv_wrapper.so 加载失败: ' + msg);
      throw new Error('libmpv_wrapper.so 加载失败: ' + msg);
    }
  })();
  return loadPromise;
}

/** 同步取模块；未加载完成时抛出明确错误，而不是让 undefined 崩溃 */
function requireModule(): ESObject {
  if (mpvModule === undefined || mpvModule === null) {
    throw new Error('libmpv_wrapper.so 尚未加载完成，请先 await ensureMpvModuleLoaded()');
  }
  return mpvModule;
}

export type MpvNode =
  | string
  | number
  | boolean
  | ArrayBuffer
  | MpvNode[]
  | Map<string, MpvNode>

export interface EventObserver {
  onPropertyChanged(property: string, value?: number | boolean | string): void;

  onEvent(id: number, name: string): void;
}

export interface LogObserver {
  onLogMessage(prefix: string, level: string, msg: string): void;
}

export enum MpvFormat {
  MPV_FORMAT_NONE = 0,
  MPV_FORMAT_STRING = 1,
  MPV_FORMAT_OSD_STRING = 2,
  MPV_FORMAT_FLAG = 3,
  MPV_FORMAT_INT64 = 4,
  MPV_FORMAT_DOUBLE = 5,
  MPV_FORMAT_NODE = 6,
  MPV_FORMAT_NODE_ARRAY = 7,
  MPV_FORMAT_NODE_MAP = 8,
  MPV_FORMAT_BYTE_ARRAY = 9,
}

export enum MpvEvent {
  MPV_EVENT_NONE = 0,
  MPV_EVENT_SHUTDOWN = 1,
  MPV_EVENT_LOG_MESSAGE = 2,
  MPV_EVENT_GET_PROPERTY_REPLY = 3,
  MPV_EVENT_SET_PROPERTY_REPLY = 4,
  MPV_EVENT_COMMAND_REPLY = 5,
  MPV_EVENT_START_FILE = 6,
  MPV_EVENT_END_FILE = 7,
  MPV_EVENT_FILE_LOADED = 8,
  /** @deprecated */
  MPV_EVENT_IDLE = 11,
  /** @deprecated */
  MPV_EVENT_TICK = 14,
  MPV_EVENT_CLIENT_MESSAGE = 16,
  MPV_EVENT_VIDEO_RECONFIG = 17,
  MPV_EVENT_AUDIO_RECONFIG = 18,
  MPV_EVENT_SEEK = 20,
  MPV_EVENT_PLAYBACK_RESTART = 21,
  MPV_EVENT_PROPERTY_CHANGE = 22,
  MPV_EVENT_QUEUE_OVERFLOW = 24,
  MPV_EVENT_HOOK = 25,
}

export class MpvLib {
  private observers: EventObserver[] = [];
  private logObservers: LogObserver[] = [];
  /** NativePlayer 实例。构造时从已加载的模块取得（须先 await ensureMpvModuleLoaded()）。 */
  private ctx: ESObject;

  constructor() {
    const mod: ESObject = requireModule();
    this.ctx = new mod.NativePlayer();
  }

  create(): void {
    this.ctx.create();
  }

  initialize(): void {
    this.ctx.initialize();
  }

  destroy(): void {
    this.ctx.destroy();
  }

  attachSurface(surfaceId: string): void {
    this.ctx.attachSurface(surfaceId);
  }

  detachSurface(): void {
    this.ctx.detachSurface();
  }

  command(cmds: Array<string>): void {
    this.ctx.command(cmds);
  }

  commandWithReturn(cmds: Array<string>): MpvNode {
    return this.ctx.commandWithReturn(cmds);
  }

  loadFile(url: string, options: Map<string, string>): void {
    this.ctx.loadFile(url, options);
  }

  requestLogMessages(level: string): void {
    this.ctx.requestLogMessages(level);
  }

  setOptionString(option: string, value: string): void {
    this.ctx.setOptionString(option, value);
  }

  getProperty(property: string): number {
    return this.ctx.getProperty(property);
  }

  /**
   * HeinPlay 2026-10-07：属性读取的**可失败版本**，不可用时返回 NaN。
   *
   * 与 getProperty 的区别只有一个，但很关键：
   *   getProperty       属性不可用时**静默返回 0**（C++ 侧丢弃了 mpv_get_property 的返回值）；
   *   getPropertyOrNaN  属性不可用时返回 **NaN**，真实读数保持原样（含 0）。
   *
   * 为什么需要它：硬解归因判定必须分清「读不到」与「读到 0」。
   *   demuxer-cache-time 读不到 → demuxer 还没建，数据还没到（源慢）
   *   demuxer-cache-time == 0  → demuxer 已建但缓存为空（另一种情形）
   * 若用 getProperty，两者都返回 0，就会把「源慢」误判成「硬解失败」，
   * 进而触发无谓的软解降级 —— 这正是真机 22:43/22:44/22:45 三次误判的机制。
   */
  getPropertyOrNaN(property: string): number {
    return this.ctx.getPropertyOrNaN(property);
  }

  getPropertyBool(property: string): boolean {
    return this.ctx.getPropertyBool(property);
  }

  getPropertyString(property: string): string {
    return this.ctx.getPropertyString(property);
  }

  setProperty(property: string, value: number | boolean | string): void {
    if (typeof value === "number") {
      if (Number.isInteger(value)) {
        this.ctx.setPropertyInt(property, value);
      } else {
        this.ctx.setPropertyDouble(property, value);
      }
    } else if (typeof value === "boolean") {
      this.ctx.setPropertyBool(property, value);
    } else {
      this.ctx.setPropertyString(property, value);
    }
  }

  observeProperty(property: string, format: MpvFormat): void {
    this.ctx.observeProperty(property, format);
  }

  addEventObserver(o: EventObserver) {
    this.observers.push(o);
  }

  removeEventObserver(o: EventObserver) {
    let index = this.observers.indexOf(o);
    if (index != -1) {
      this.observers.splice(index, 1);
    }
  }

  addLogObserver(o: LogObserver) {
    this.logObservers.push(o);
  }

  removeLogObserver(o: LogObserver) {
    let index = this.logObservers.indexOf(o);
    if (index != -1) {
      this.logObservers.splice(index, 1);
    }
  }

  registerEventCallback(): void {
    requireModule().JSBind.initTaskRunner("main");
    requireModule().JSBind.bindFunction("property", this.eventProperty);
    requireModule().JSBind.bindFunction("event", this.event);
  }

  registerLogCallback(): void {
    requireModule().JSBind.initTaskRunner("main");
    requireModule().JSBind.bindFunction("log", this.log);
  }

  removeEventCallbacks(): void {
    requireModule().JSBind.unbindFunction("property");
    requireModule().JSBind.unbindFunction("event");
  }

  removeLogCallback(): void {
    requireModule().JSBind.unbindFunction("log");
  }

  private eventProperty = (property: string, value?: number | boolean | string): void => {
    this.observers.forEach((o) => {
      o.onPropertyChanged(property, value);
    })
  }

  private event = (id: number, name: string): void => {
    this.observers.forEach((o) => {
      o.onEvent(id, name);
    })
  }

  private log = (prefix: string, level: string, msg: string): void => {
    this.logObservers.forEach((o) => {
      o.onLogMessage(prefix, level, msg);
    })
  }
}
