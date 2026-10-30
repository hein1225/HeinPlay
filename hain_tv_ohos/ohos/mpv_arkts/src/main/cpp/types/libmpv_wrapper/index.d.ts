/**
 * Copyright (c) 2026 Bao Han <erbws@qq.com>
 */

type MpvNode =
  | string
  | number
  | boolean
  | ArrayBuffer
  | MpvNode[]
  | Map<string, MpvNode>

export declare class NativePlayer {
  constructor()

  create(): void

  initialize(): void

  destroy(): void

  attachSurface(surface: string): void

  detachSurface(): void

  command(commands: Array<string>): void

  commandWithReturn(commands: Array<string>): MpvNode

  loadFile(url: string, options: Map<string, string>): void

  requestLogMessages(level: string): void

  setOptionString(option: string, value: string): void

  getProperty(property: string): number

  /** HeinPlay 2026-10-07：属性不可用时返回 NaN（而非静默 0）。
   *  硬解归因判定依赖「读不到」与「读到 0」的区别，故必须用本方法。 */
  getPropertyOrNaN(property: string): number

  getPropertyBool(property: string): boolean

  getPropertyString(property: string): string

  setPropertyInt(property: string, value: number): void

  setPropertyDouble(property: string, value: number): void

  setPropertyBool(property: string, value: boolean): void

  setPropertyString(property: string, value: string): void

  observeProperty(property: string, format: number): void
}

export class JSBind {
  static bindFunction: (name: string, func: Function) => number;

  static unbindFunction: (name: string) => number;

  static initTaskRunner: (name: string) => void;
}

/**
 * 🔴 2026-10-05：napi 模块缺 default 导出 → ArkTS 默认导入拿到 undefined
 *   → 运行时报 "Cannot read property NativePlayer of undefined"
 *   → PlatformView 创建失败 → Dart 报 "等待 XComponent view 创建超时" → 黑屏。
 *
 *   HarmonyOS 的 napi 模块在运行时返回的是「模块对象」，官方模板
 *   （DevEco 生成的 libentry.so）也配 `import x from 'libentry.so'`（默认导入）。
 *   但本项目的 index.d.ts 只写了具名导出，没有 default，
 *   导致 `import libmpv from 'libmpv_wrapper.so'` 在运行时取不到模块对象。
 *   这里补一个 default 导出，声明默认导出即为模块自身。
 */
declare const mpvWrapper: {
  NativePlayer: typeof NativePlayer;
  JSBind: typeof JSBind;
};

export default mpvWrapper;
