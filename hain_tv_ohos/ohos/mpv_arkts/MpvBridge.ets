/**
 * HeinPlay mpv 桥接层（ArkTS 侧，按 mpv-arkts 自身架构，不照搬 fvp）
 *
 * 架构：
 *   - MpvPlugin         : FlutterPlugin，注册 PlatformViewFactory + MethodChannel
 *   - MpvViewFactory    : 为每个 Flutter 挂载锚点创建独立 MpvPlayerView
 *   - MpvPlayerView     : extends PlatformView，持有独立 Player 实例；
 *                         create 时注册 Flutter 纹理拿 surfaceId+textureId，
 *                         surfaceId 直接喂给 mpv（替代 XComponent onSurfaceCreated），
 *                         textureId 经事件通道回传 Dart。
 *   - MethodChannel hain_tv/mpv        : Flutter 按 viewId 发送 open/play/pause/seek/...
 *   - EventChannel  hain_tv/mpv_events_<viewId> : 原生按 viewId 推送状态；
 *                         首条消息为 {type:'texture', textureId} 供 Dart 显示。
 *
 * 🔴 渲染路径（2026-09-30 路线 B）：不再走 XComponent/PlatformView 的原生 surface，
 *   而是走 Flutter 纹理（Dart 侧 Texture(textureId)）。原因：flutter-ohos 的
 *   PlatformView 走 RENDER_TYPE_TEXTURE 合成时，节点内 XComponent 拿不到原生 surface，
 *   导致 mpv 的 wid 为空、vo=gpu-next 报 Missing surface pointer、黑屏（有声无画）。
 *   改为注册 Flutter 纹理拿合法 surfaceId 注入 mpv 即可出画（video_player_ohos 同范式）。
 */

import PlatformView, { Params } from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformView';
import PlatformViewFactory from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformViewFactory';
import PlatformViewRegistry from '@ohos/flutter_ohos/src/main/ets/plugin/platform/PlatformViewRegistry';
import { TextureRegistry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';
import common from '@ohos.app.ability.common';
// 🔴 与 flutter-ohos 官方一致：默认导入 @ohos.display（@kit.ArkUI 不导出 display）
import display from '@ohos.display';
import {
  FlutterPlugin, FlutterPluginBinding, MethodCall, MethodCallHandler, MethodChannel,
  MethodResult, EventChannel, EventSink, BinaryMessenger, StandardMessageCodec, StreamHandler
} from '@ohos/flutter_ohos';
import { Player, Media, MediaOptions, PlayerConfig, MpvLogLevel, ensureMpvModuleLoaded } from './Index';
import { LogRedactor } from './src/main/ets/utils/LogRedactor';

const VIEW_TYPE = 'heinplay_mpv';
const CHANNEL_CONTROL = 'hain_tv/mpv';

/**
 * 诊断日志。
 *
 * ⚠️ 2026-09-30 实测：arkts 的 console.log 映射到 INFO 级，真机 hilog 抓取
 *    默认只保留 W/E（整份日志零条 I），故诊断一律用 console.warn（W 级）。
 *    原生侧 C++ 的 OH_LOG_Print(LOG_ERROR, "mpv") 走 E 级，能正常出现。
 */
const LOG_TAG = 'HeinPlayMpv';

/**
 * 🔴 2026-10-07：硬解无帧看门狗超时（毫秒）。
 *   硬解正常时 open 后 position 会很快前进；给 8 秒容忍首帧与缓冲时间，
 *   超时且进度仍为 0 才判定硬解黑屏。
 *
 *   🔴 2026-10-07 三次修正：缩短为 3000ms。
 *   依据（mpv 源码 + 真机日志）：
 *     · hwdec=ohcodec 在本工程的「Flutter 纹理 surfaceId 注入」路线下，
 *       init() 拿不到可用 NativeWindow（hwdec_ohcodec.c:127
 *       "OHCodec Surface hwdec requires compatible GL or Vulkan" 分支），
 *       硬解**必然失败**并静默退回软解 —— 真机日志：7 次 hwdec=ohcodec，
 *       VO 却恒为 yuv420p（软解格式），另有 40601000 取帧失败 1463 次。
 *     · 软解出画正常（VO 成功），故「进度仍为 0」只需 3 秒即可确认，
 *       无需白等 8 秒。每次换集省 5 秒，直接改善起播体感。
 *   注：保留看门狗而非直接禁用硬解 —— 若后续修复 NativeWindow 供给，
 *       硬解生效后本看门狗不会误报（进度会前进）。
 *
 * 🔴 2026-10-07 最终值 4000ms（曾一度改为 9000，属矫枉过正）：
 *   关键认识 —— **阈值不该用来补偿归因缺失**。
 *   之前把 3s 拉到 9s，是因为旧逻辑只看「进度是否为 0」，慢源必然误判；
 *   现在看门狗已经能区分「源加载中」与「硬解真失败」（见下面的归因判定），
 *   慢源会被正确识别为「源加载中」并延期复查，**不会**被误判成硬解失败。
 *   所以这里只需覆盖「数据已到但解码器出帧慢」的正常抖动：
 *     实测硬解生效时 open→首帧 ≈ 1.5s（直播 22:42:47→22:42:48）
 *   4s 给了 2.6 倍余量；真硬解坏掉时，能比 9s 早 5 秒让用户看到画面。
 *   误判风险由归因判定兜底，不再依赖把窗口开大。
 */
const FRAME_WATCHDOG_MS = 4000;

function logI(msg: string): void {
  console.warn(`${LOG_TAG}: ${msg}`);
}

function logW(msg: string): void {
  console.warn(`${LOG_TAG}: ${msg}`);
}

function logE(msg: string): void {
  console.error(`${LOG_TAG}: ${msg}`);
}

/** 每个视图独立的状态事件通道名（Dart 侧用同一规则拼接）。 */
export function mpvEventsChannel(viewId: number): string {
  return `hain_tv/mpv_events_${viewId}`;
}

/** 纹理缓冲 / mpv 窗口尺寸（物理像素）。 */
export interface DisplaySize {
  width: number;
  height: number;
}

/**
 * 全局 @Builder：ArkTS 要求 @Builder 只能出现在全局作用域或 struct 内。
 * 通过 Params.platformView 反查回具体的 MpvPlayerView，取得其 Player 实例。
 */
@Builder
function MpvSurfaceBuilder(params: Params) {
  MpvSurfaceHost({ host: params.platformView as MpvPlayerView })
}

/** 仅用于承载 PlayerSurface 的轻量 struct。 */
@Component
struct MpvSurfaceHost {
  host: MpvPlayerView | null = null;

  // ⚠️ ArkTS 的 build() 体内只能是 UI 组件语法，不能直接写语句/函数调用
  //    （否则报 10905204 does not meet UI component syntax）。
  //    故诊断日志放在生命周期回调里。
  aboutToAppear(): void {
    logI(`MpvSurfaceHost.aboutToAppear host=${this.host != null} —— 路线B：占位，不渲染 XComponent`);
  }

  build() {
    // 🔴 HeinPlay 路线 B：画面走 Flutter 纹理（Dart 侧 Texture widget），
    //    此处返回透明占位，不再构建 XComponent（避免 onSurfaceCreated 不回调的黑屏陷阱）。
    Column() {
      // 空占位：PlatformView 仅作创建锚点，真实画面由纹理通道渲染。
    }
    .width('100%')
    .height('100%')
  }
}

/** 单视图桥接：持有 Player 实例 + 状态推送 sink。 */
export class MpvPlayerView extends PlatformView {
  private player: Player;
  private eventSink: EventSink | null = null;
  private viewId: number;
  private disposed: boolean = false;
  // 🔴 HeinPlay 路线 B：Flutter 纹理的 textureId（回传 Dart 显示用）
  private textureId: number = -1;
  private surfaceId: string = '';
  // 🔴 2026-10-06：纹理注册表，旋转时重设纹理缓冲尺寸用
  private textureRegistry: TextureRegistry;
  // 🔴 2026-10-06 修复：持有工厂引用，dispose 时同步从工厂视图表移除，
  //   避免 views map 残留已销毁视图导致后续指令误命中（textureId 复用冲突）。
  private factory: MpvViewFactory | null = null;

  // 🔴 2026-10-07：硬解「无帧看门狗」。
  //   背景：鸿蒙 mpv 硬解（ohcodec[nv12]）对部分源会「解码成功、VO 出画成功，
  //   但帧进不了 Flutter 纹理」——Flutter 侧取帧恒失败（ret=40601000），画面全黑。
  //   mpv 自身的 hwdec-software-fallback 只统计 avcodec_send_packet 解码错误，
  //   这种「出画了但纹理取不到」的情况计数器恒为 0，回退永不触发。
  //   故由本看门狗直接观测硬解会话的运行状态并上报 Dart，由 Dart 重建软解会话。
  private frameWatchdogArmed: boolean = false;
  private frameWatchdogTimer: number = -1;
  private frameWatchdogReported: boolean = false;
  // 🔴 2026-10-07：硬解生效探针定时器（open 后 1.2s 回读 hwdec-current）。
  //   与看门狗分开持有，dispose 时一并清理，避免视图销毁后回调仍触发。
  private hwdecProbeTimer: number = -1;
  // 🔴🔴 2026-10-27 新增：播放帧统计定时器（每 2 秒打一行）。
  //
  //   【为什么必须加】本轮排查「一卡一卡」时，日志里**没有任何 mpv 帧统计**，
  //   只能拿外部纹理取帧失败的行数去反推 Flutter 绘制节奏 —— 而那条路已证明
  //   不可靠（3 次/秒既可解释成 27Hz 绘制，也可能只是普通空取）。
  //   缺的那个数是 display-fps：它直接决定「24fps 片源是否落在整数倍刷新率上」。
  //   24fps × 60Hz = 2.5（非整数 ⇒ 必有 3:2 judder）
  //   24fps × 120Hz = 5.0（整数 ⇒ 无 judder）
  //   没有这个数，一切关于卡顿的推断都是猜。
  private frameStatTimer: number = -1;

  // 由 player.stream.* 订阅维护的最新快照（mpv-arkts 的响应式流，非轮询）。
  private positionSec: number = 0;
  // 🔴 HeinPlay 新增（2026-10-08）：seek 状态 + 请求目标值。
  //   语义对标 AVP 插件的 isSeeking / seekPosition
  //   （video_player_ohos/ohos/.../VideoPlayer.ets L133/L137、getPosition L663-670）。
  //   用途：seek 期间 position 上报改用 seekTargetSec，屏蔽 mpv 的残留 time-pos。
  private seeking: boolean = false;
  private seekTargetSec: number = 0;
  // 🔴 2026-10-08 新增：**mpv 侧最近一次观测到的真实位置**（秒）。
  //
  //   【为什么必须与 positionSec 分开】positionSec 在 seek 期间会被**乐观置位**
  //     成 seekTargetSec（请求值），因为 mpv 在 seek 期间会先吐上次播放位置的
  //     残留 time-pos，直接上报会让进度条往后跳。但这样一来 positionSec 就
  //     不再是「mpv 正在播到哪里」，而变成「我们请求播到哪里」——
  //     一旦 seek 被 mpv 忽略（空 seek、落点无关键帧、分片未就绪），
  //     这个假值就会永久留在 Dart 侧当作续播/快进基准，造成
  //     「显示时间大于真实进度、且越往后偏差越大」（真机实证）。
  //
  //   【用途】随每次 _pushState 一起上报真实位置，让 Dart 侧能在**观测到
  //     mpv 实际落点**时立刻证伪并清除那个乐观锚点，而不是无条件信任它。
  private realPositionSec: number = 0;
  private durationSec: number = 0;
  private playing: boolean = false;
  private buffering: boolean = false;
  private volume: number = 100;
  private speed: number = 1;
  private eof: boolean = false;
  private bufferSec: number = 0;

  /**
   * 🔴 2026-10-01：mpv 窗口尺寸，必须在 Player 构造（内部会 initialize）之前确定，
   *   故由工厂解析后经构造函数传入。
   */
  private surfaceSize: DisplaySize;

  /**
   * 🔴 2026-10-28：屏幕刷新率（Hz），由工厂在 create 时注入。
   *   0 表示取不到 —— 此时不下发 display-fps-override，让 mpv 走原路径，
   *   宁可维持现状也不要喂一个错的刷新率（错值会引入新的失配）。
   */
  private refreshRate: number = 0;

  constructor(context: common.Context, viewId: number, args: Object,
              textureId: number, surfaceId: string, surfaceSize: DisplaySize,
              textureRegistry: TextureRegistry, factory: MpvViewFactory | null = null,
              refreshRate: number = 0) {
    super();
    this.viewId = viewId;
    this.textureId = textureId;
    this.surfaceId = surfaceId;
    this.surfaceSize = surfaceSize;
    this.textureRegistry = textureRegistry;
    this.factory = factory;
    this.refreshRate = refreshRate;
    logI(`MpvPlayerView 构造 viewId=${viewId}，即将 new Player()（refreshRate=${refreshRate}Hz）`);
    // 🔴 2026-09-30 起播慢 / 无缓冲条 / 黑屏三件事的配置侧处理：
    //
    //  ① logLevel: Info —— 上游默认 MpvLogLevel.None，**mpv 内部日志被完全关闭**，
    //     这才是真机 hilog 里一条 mpv 输出都没有的原因（并非 hilog 被系统过滤）。
    //     打开后才能看到 vo / gpu-context / hwdec 初始化究竟成功还是失败 ——
    //     这是判定「黑屏是渲染管线不兼容还是别的」的唯一确定性证据。
    //
    //  ② cache=yes + cache-secs —— 上游只设了 demuxer-max-bytes=1024MiB，
    //     那是**缓存容量上限**而非**预读窗口**（与 avplayer 的
    //     preferredBufferDuration 误区同源）。不设 cache-secs 时 mpv 按
    //     默认的较小值预读，表现为「起播慢、且进度条几乎没有已缓冲段」。
    //     这里显式给 30 秒预读窗口，让预缓冲条可见、起播更快。
    //
    //  ③ demuxer-readahead-secs —— 解复用层的向前预读时长，与 cache-secs
    //     共同决定缓冲条长度；显式设为 30 秒，避免默认值过小。
    //
    //  ④ 关掉 interpolation（上游默认 yes）—— 插帧对点播起播首帧延迟影响明显，
    //     且本项目其它后端都不做插帧，保持一致。
    const extra = new Map<string, string>();
    extra.set('cache', 'yes');
    extra.set('cache-secs', '30');
    extra.set('demuxer-readahead-secs', '30');
    // 🔴🔴 2026-10-28：本行由 'no' 改为 'yes'，与 video-sync=display-resample 配套。
    //
    //   历史上下文：10-07 曾把 interpolation 关掉，理由是「不再锁刷新率，
    //   插帧无意义且增 GPU 负载」。那个理由**只在不锁刷新率时成立**。
    //   现在改为 display-resample（锁刷新率），插帧就是消除 3:2 judder 的
    //   唯一手段：mpv 会把每帧按 vsync 位置混合出中间画面，把 24fps
    //   在 60Hz 上的 2/3 交替间隔抹平成等距。
    extra.set('interpolation', 'yes');
    // 插帧在 vsync 边界做混合，tscale 决定混合核；oversample 是 mpv 默认，
    // 开销最低且对 24→60 这种整数附近倍率足够。显式写出便于后续调参。
    extra.set('tscale', 'oversample');
    // 插帧必须与 display-resample 同时启用才有效（vo_gpu_next.c:1045 的
    // can_interpolate 要求 frame->display_synced，而该标志只在
    // video-sync=display-* 下由 player/video.c:929 置位）。
    extra.set('video-sync', 'display-resample');
    // display-resample 会微调音频速度来贴合 vsync；开启音高校正避免变调。
    extra.set('audio-pitch-correction', 'yes');
    // 🔴🔴 2026-10-28 第二次修正：override 必须用「实际合成率」，不是硬件面板率。
    //
    //   【上一版错在哪】上一版把 display.getDefaultDisplaySync().refreshRate
    //   读到的 120 直接下发给 mpv。真机日志证明这是错的：
    //     display-fps=120.00      ← override 确实生效
    //     mistimed 每秒 +24.00    ← 等于帧率 ⇒ 每一帧都被判错位
    //     vsync-ratio ≈ 20        ← 120Hz/24fps 本应是 5.0
    //     desynchronisation 告警  ← 起播 6 秒后 A/V 差 > 0.5s
    //   vsync-ratio 从 5 涨到 20，说明 num_vsyncs 被 drop_repeat 抬高，而
    //   drop_repeat 源于持续为负的 av_diff（约 -125ms）⇒ 视频跑在音频前面，
    //   mpv 靠重复帧硬拉，形成不收敛的振荡。
    //
    //   【为什么 120 是错的】display.refreshRate 是**硬件面板能力**，不是
    //   Flutter 合成器实际的出帧率。查引擎源码 ohos_vsync_voting_mgr.cpp:302
    //   VoteFinalFrameRateByPriority() 的优先级：
    //     1. is_touch_down_                  → FPS_120
    //     2. touch_voting_ == FPS_NO_VOTING  → FPS_60  ← 命中即 break
    //     3. touch 在超时内                   → FPS_120
    //     4. is_platformview_exist_          → FPS_120（外部纹理投 120 的分支）
    //   播放时没有触摸，第 2 条恒成立并 break ⇒ 合成器稳定锁 **60Hz**，
    //   第 4 条的 120 永远轮不到。告诉 mpv 120Hz，等于让它以为每帧能占
    //   5×8.33ms，而屏幕 16.67ms 才推进一次 ⇒ 模型与现实错位 ⇒ 闭环发散。
    //
    //   【为什么必须仍是 display-* 而不是退回 audio】
    //   退回 video-sync=audio 就是 24fps 硬塞进 60Hz，2.5 倍率失配 ⇒
    //   3:2 judder，正是用户最初抱怨的现象。display-resample + interpolation
    //   是 24p 在 60Hz 上的标准解法：vsync=16.67ms 时 ratio=2.5，num_vsyncs
    //   在 2/3 间交替，插帧按小数相位混合出中间画面，把不均匀抹平。
    //
    //   【为什么 60 还能自洽】override=60 ⇒ nominal=16.67ms；只要后端
    //   present 真的按 FIFO 阻塞，estimated_vsync_interval 也会测到 ≈16.67ms，
    //   与 nominal 一致 ⇒ check_estimated_display_fps() 不会接管，闭环稳定。
    //   反之若喂 120，estimated 实测 16.67ms 与 nominal 8.33ms 冲突，
    //   正是本轮抖动的来源。
    //
    //   硬件率仍保留在 this.refreshRate 里仅用于日志对照，不再下发给 mpv。
    const EFFECTIVE_REFRESH_RATE = 60;
    extra.set('display-fps-override', `${EFFECTIVE_REFRESH_RATE}`);
    logI(`display-fps-override 下发 ${EFFECTIVE_REFRESH_RATE}Hz`
      + `（实际合成率；硬件面板率=${this.refreshRate > 0 ? this.refreshRate : '未知'}Hz 不下发）`);

    // 🔴🔴🔴 2026-10-28 第三次修正（真凶已定位，改在 C 侧）
    //
    //   【结论演进】
    //     第一轮：display-sync 没生效。
    //     第二轮：生效了，但喂了硬件面板率 120（应为合成率 60）→ 已改 60。
    //     第三轮（本次）：60 也生效了，问题依旧 —— 标称值被 est 夺权。
    //
    //   【12:05 版日志的决定性证据】
    //     display-fps=60.00                                    ← 标称值正确
    //     est-fps = 143 → 292 → 415 → 508 → 683 → **791**      ← 一路飙升
    //     vsync-ratio = 5.94 → 15.61 → 19.28 → **27.50**
    //     delayed = 0 → 127 → 346 → 1890 → **2622**            ← 单调增长不回落
    //     mistimed 每秒 +24（等于帧率，每帧都判错位）
    //
    //   【为什么上一轮试的 swapchain-depth=1 无效（已试，实测失败）】
    //     该值确实传到了 libplacebo（options.c:254 → vo->opts->swapchain_depth
    //     → pl_vulkan_swapchain_params.swapchain_depth，链路已核对），但
    //     libplacebo 自己的头文件（src/include/libplacebo/vulkan.h:352-355）写明：
    //       "we are only able to wait until the GPU has finished rendering a
    //        frame - we are unable to wait until the display has actually
    //        finished displaying it. So this only provides a rough guideline."
    //     而且 present_cb 挂在一个 pl_vk_steal_cmd 拿到的空命令上，
    //     在 QueuePresentKHR **之前**就完成，frames_in_flight 根本不累积。
    //     ⇒ 压到 1 也挡不住空转，实测 est 反而涨到 791。
    //
    //   【真正缺的是 get_vsync】
    //     vo.c:1022-1024 在 flip_page() 之后**紧接着**调 get_vsync()，
    //     而 OHOS 后端的 ra_ctx_params 从来没填过这个回调
    //     （context_ohos.c 原来只有 preferred_csp / set_color）
    //     ⇒ vo.c:1027 用 mp_time_ns() 伪造 last_queue_display_time
    //     ⇒ display-sync 帧 target 恒为 0（vo.c:951），wait_until 立即返回
    //     ⇒ render_frame 完全没有时间约束地空转，est 被实测成 300~800
    //     ⇒ 落在 vo.c:418 的合法区间 [2.5ms, 50ms] 内被采纳
    //     ⇒ vsync_interval 从 16.67ms 被覆盖成 2~7ms
    //     ⇒ num_vsyncs = 41.667/vsync 涨到 20+
    //     ⇒ 同一帧重复渲染 20 次 ⇒ flip 更密 ⇒ 正反馈闭环。
    //
    //   【本次修法（C 侧，已重编 libmpv.so）】
    //     ohos_common.c 新增 vo_ohos_get_vsync()：按 display-fps-override
    //     （本平台=60）算出 vsync 周期，在 get_vsync 里做栅格阻塞，
    //     并如实上报 last_queue_display_time。
    //     context_ohos.c 把它挂到 ra_ctx_params.get_vsync。
    //     ⇒ VO 线程被钉在 60Hz，est 测得 ≈16.67ms 与 nominal 一致
    //     ⇒ check_estimated_display_fps 不再夺权（vo.c:427 要求
    //        mjitter*1.01 < njitter，两者相等则不采纳）
    //     ⇒ vsync_interval 稳在 16.67ms ⇒ num_vsyncs 在 2/3 交替
    //     ⇒ 插帧抹平 3:2 judder。
    //
    //   验证点：下次日志应看到 est-fps≈60、vsync-ratio≈2.5、
    //   delayed 不再单调增长、mistimed 停止每秒 +24。

    // 🔴 2026-10-06：选项名改为 "ohos-surface-size"，对齐 ErBWs/mpv feat-ohos 分支
    //    （该分支 options.c:249 是 OPT_SIZE_BOX(ohos_surface_size)）。
    //    路线B 下没有 XComponent，Player.onSurfaceChanged 永不触发，尺寸通道失效，
    //    所以必须在这里（initialize 之前）以 extraOptions 显式下发确定值，
    //    否则会走到 vo_ohos_surface_size() 的未初始化输出分支 → EGL surface 尺寸非法 → 黑屏。
    extra.set('ohos-surface-size', `${this.surfaceSize.width}x${this.surfaceSize.height}`);
    this.player = new Player(new PlayerConfig({
      logLevel: MpvLogLevel.Info,
      extraOptions: extra,
      // 🔴 路线 B：surfaceId 在 Player 构造内 initialize 之前注入 wid（时序正确）。
      surfaceId: this.surfaceId,
    }));
    logI(`MpvPlayerView 构造完成 viewId=${viewId}，Player 已创建`
      + `（logLevel=Info, cache-secs=30, readahead=30s,`
      + ` interpolation=yes, video-sync=display-resample,`
      + ` display-fps-override=60(合成率),`
      + ` surfaceId=${this.surfaceId}, size=${this.surfaceSize.width}x${this.surfaceSize.height}）`);
    this._bindStreams();
  }

  /** 供全局 @Builder 取用。 */
  getPlayer(): Player {
    return this.player;
  }

  getType(): string {
    return VIEW_TYPE;
  }

  /**
   * 🔴 HeinPlay 路线 B：返回透明占位组件。
   * 画面不再走 XComponent/PlatformView 的原生 surface，而是走 Flutter 纹理
   * （Dart 侧用 Texture(textureId) 显示）。PlatformView 仅作为创建锚点 +
   * 生命周期 + 事件通道的载体，getView 返回空占位即可。
   */
  getView(): WrappedBuilder<[Params]> {
    logI(`MpvPlayerView.getView() 被调用 viewId=${this.viewId} —— 路线B：返回占位（画面走纹理）`);
    return new WrappedBuilder(MpvSurfaceBuilder);
  }

  /**
   * 🔴 2026-10-07：硬解无帧看门狗。
   *
   * 判据（三条同时满足才判定硬解黑屏，避免误报）：
   *   ① 会话是硬解（软件回退会话不监视）；
   *   ② 距 open 已过 FRAME_WATCHDOG_MS；
   *   ③ 期间**播放进度从未前进过**（positionSec 仍为 0）——这是关键。
   *      硬解正常出画时 position 会迅速增长；黑屏时 mpv 其实在「跑」但
   *      Demuxer/解码链路对这类源会停住，position 恒为 0。
   *
   * 只在会话内上报一次（frameWatchdogReported 去重），Dart 侧收到后重建软解会话。
   */
  private resetFrameWatchdog(arm: boolean): void {
    this.clearFrameWatchdog();
    this.frameWatchdogReported = false;
    this.frameWatchdogArmed = arm;
    if (!arm) {
      return;
    }
    // 🔴 2026-10-07 三次修正：硬解生效探针（**主判据**）。
    //    本轮排障最大的盲点：hwdec=ohcodec 已下发，但「mpv 是否真的用上了硬解」
    //    完全不可见 —— 真机日志 7 次下发 ohcodec，VO 却恒为 yuv420p（软解格式）。
    //
    //    ✅ 2026-10-07 根因已定并修复（勿再沿用旧的「纹理路线必然失败」结论）：
    //    ohcodec 的 Vulkan interop 入口用 has_extension() 检查
    //    VK_OHOS_external_memory / VK_OHOS_native_buffer（hwdec_ohcodec_pl.c:436/L656），
    //    而 libplacebo 的 vk_device_extensions 表从不列这两个扩展 → 设备创建时未启用
    //    → has_extension 恒 false → Vulkan interop return false；
    //    GL interop 在 vo=gpu-next(Vulkan) 下 ra_is_gl 亦 false → 两条路径全失败
    //    → init 返回 -1（"requires compatible GL or Vulkan"）→ 静默退软解。
    //    修复：在 libplacebo 追加这两个设备扩展（见 patches-heinplay/），
    //    并加入 PL_INFO 级自检日志「OHOS 硬解扩展自检」便于一眼判定。
    //
    //    本探针的作用：回读 hwdec-current，确认硬解是否真的生效。
    //
    //    🔴 2026-10-07 真机复测暴露的严重缺陷（换源必然失败的真因）：
    //    open 后固定 1.2s 就去读属性，但**点播源此时还在拉 HLS playlist、解码器尚未创建**，
    //    hwdec-current / video-format / pixelformat 三个属性全部读回**空字符串**。
    //    旧代码把「空」直接当作「硬解未生效」→ 立即上报回退 → Dart 用 hwdec=no 重开一次。
    //    真机对比（同一台设备、同一份代码）：
    //      直播 22:42:47 open → 22:42:48 探针读到 hwdec-current=ohcodec  ✅（1.5s 时已就绪）
    //      点播 22:44:52 open → 22:44:53 探针读到 hwdec-current=（空）    ❌（1.2s 时还没就绪）
    //    仅差 0.3 秒，结论完全相反。**空值只代表「还没准备好」，不代表「硬解失败」。**
    //
    //    🔴🔴 关键设计原则（用户 2026-10-07 明确要求）：
    //    **必须区分「源加载慢」与「硬解真的失败」，不能靠拉长等待时间来掩盖。**
    //    只把 1.2s 改成 9s 是错的 —— 慢源照样误判，真失败又要白等 9 秒。
    //    两者的本质区别在于**数据有没有在流动**：
    //
    //      硬解真失败：数据早已到达（demuxer 缓存有内容），解码器已开（hwdec-current=ohcodec），
    //                  但 VO 出不了帧（pixelformat 仍是软解格式），cache 不再增长。
    //      源加载慢　：数据还没到，解码器根本没建（video-format 空），
    //                  cache 在增长 / buffering-state 在变化 / 有下载速率。
    //
    //    判据（全部来自 mpv 自带属性，已核对 player/command.c 的定义与类型）：
    //      · hwdec-current             string  ── 'ohcodec' 表示解码器确实开了
    //      · video-format              string  ── 空 = 还没解析出视频轨
    //      · video-params/pixelformat  string  ── 软解时恒为 yuv420p，硬解应为 ohcodec 系
    //      · cache-buffering-state     int 0-100（-1/不可读 = 不可用）
    //      · demuxer-cache-time        double 秒（不可读 = demuxer 还没建）
    //      · paused-for-cache          bool
    //      · cache-speed               int  byte/s
    //
    //    判定流程（每轮都重新采集，任一轮可得出结论）：
    //      ① 出帧了（realPositionSec > 0 或 pixelformat 已是硬解格式）→ 成功，收工。
    //         ⚠️ 必须用 realPositionSec 而非 positionSec：后者在 seek 期间会被
    //         乐观置位成请求值，**未出帧时也 > 0**，会让本判定必然误报
    //         （详见下方分支 ① 的注释与真机证据）。
    //      ② 解码器已就绪（hwdec-current=ohcodec）且**数据已到**（demuxer-cache-time>0）
    //         但 pixelformat 仍是软解格式 → 这才是**硬解真失败**，上报回退。
    //      ③ 数据还没到（demuxer-cache-time 不可读或 <=0）→ 判定为**源加载慢**，
    //         继续等，绝不上报回退；并在日志里打出速率/buffering 供人核对。
    //      ④ 超出预算仍读不到任何数据 → 判定为**源本身有问题**，交给看门狗，
    //         同样不降级软解（降级也救不了拿不到数据的源）。
    const HWPROBE_RETRY_MS = 1000;
    const HWPROBE_MAX_ROUNDS = 10;   // 约 10s，覆盖最慢点播源的起播
    let probeRound = 0;
    const runHwdecProbe = (): void => {
      if (this.disposed || !this.frameWatchdogArmed || this.frameWatchdogReported) {
        return;
      }
      try {
        const cur: string = this.player.native.getPropertyString('hwdec-current');
        const vf: string = this.player.native.getPropertyString('video-format');
        let voFmt: string = '';
        try {
          voFmt = this.player.native.getPropertyString('video-params/pixelformat');
        } catch (e2) {
          voFmt = '';
        }
        // 采集「数据有没有在流动」的证据。
        // 🔴 必须用 getPropertyOrNaN：普通 getProperty 在属性不可用时静默返回 0，
        //    会把「demuxer 还没建」误读成「缓存为 0」，从而把「源慢」判成「硬解失败」。
        //    这里 NaN = 读不到，用它明确区分「读不到」与「读到 0」。
        const cacheTime: number = this.player.native.getPropertyOrNaN('demuxer-cache-time');
        const bufState: number = this.player.native.getPropertyOrNaN('cache-buffering-state');
        const speed: number = this.player.native.getPropertyOrNaN('cache-speed');
        let pausedForCache: boolean = false;
        try {
          pausedForCache = this.player.native.getPropertyBool('paused-for-cache');
        } catch (e6) {
          pausedForCache = false;
        }

        const hasCur: boolean = cur != null && cur.length > 0;
        const decoderReady: boolean = vf != null && vf.length > 0;
        const hwdecOn: boolean = hasCur && cur !== 'no' && cur !== 'unknown';
        // 「数据已到」：demuxer 缓存里有内容，或 buffering 进度可读且 >0。
        // NaN 参与比较恒为 false，正好表达「读不到 ⇒ 不算已到」。
        const dataArrived: boolean = cacheTime > 0 || bufState > 0;
        // 「像素格式已是硬解格式」：ohcodec 系格式名，最硬的出帧证据。
        const pixelIsHw: boolean = voFmt.length > 0
          && voFmt.indexOf('yuv420p') < 0 && voFmt.indexOf('yuv422p') < 0
          && voFmt.indexOf('yuv444p') < 0 && voFmt.indexOf('nv12') < 0;
        probeRound++;

        const diag: string = `hwdec-current='${cur}' video-format='${vf}' 像素格式='${voFmt}' `
          + `demuxer缓存=${Number.isNaN(cacheTime) ? 'N/A' : cacheTime.toFixed(2) + 's'} `
          + `buffering=${Number.isNaN(bufState) ? 'N/A' : bufState} `
          + `速率=${Number.isNaN(speed) ? 'N/A' : Math.round(speed / 1024) + 'KB/s'} `
          + `pausedForCache=${pausedForCache}`;

        // ① 已经出帧 / 硬解已确认生效 → 收工。
        //
        // 🔴 2026-10-08 修正：判据从 `positionSec > 0` 改为 `realPositionSec > 0`。
        //
        //   【原来的 bug】positionSec 在 seek 期间会被**乐观置位**成 seekTargetSec，
        //     于是「起播续播点定位」一发生（open start=1823s → 立刻 seek 到 1823s），
        //     positionSec 在**尚未解出任何一帧**时就已 > 0。
        //     → 分支 ① 立刻命中 → 探针只跑第 1 次就退出，而此刻
        //       hwdec-current 必然还是空字符串（mpv 连解码器都还没开）
        //     → 打出 `⚠️ 已在播放但硬解未生效` 的**必然误报**。
        //
        //   【真机证据】hilog 2026-10-08 23:03：
        //       23:03:26.068  handleMethod open start=1823s
        //       23:03:27.272  硬解探针 hwdec-current='' → ⚠️ 已在播放但硬解未生效（第 1 次）
        //       23:03:30.069  硬解看门狗：进度已前进 position=1823s，硬解正常，不触发回退
        //     相隔 2.8 秒，探针说「未生效」、看门狗说「正常」—— 自相矛盾，
        //     证明该误报是判据错误而非硬解真失败。
        //
        //   【为什么用 realPositionSec 就对了】它是 mpv 的 `state.position` 原话，
        //     不受乐观置位影响：**只有真正解出帧、播放时钟前进后才会 > 0**。
        //     这才是「已出帧」的可靠证据。positionSec 仍然用于 UI 上报（保持进度条
        //     停在目标点），但不再参与硬解判定。
        if (this.realPositionSec > 0.0 || pixelIsHw) {
          this.hwdecProbeTimer = -1;
          const ok: boolean = hwdecOn || pixelIsHw;
          logI(`硬解探针：${diag}（第 ${probeRound} 次）→ ${ok ? '✅ 硬解已生效' : '⚠️ 已在播放但硬解未生效'}`);
          this._pushEvent({
            'type': 'hwdecProbe',
            'viewId': this.viewId,
            'hwdecCurrent': cur != null ? cur : '',
            'videoFormat': vf != null ? vf : '',
            'voPixelFormat': voFmt,
            'hardwareActive': ok,
          });
          return;
        }

        // ② 硬解真失败：解码器开着、数据也到了，可就是出不了硬解帧。
        //    这是唯一允许降级软解的情形。
        if (hwdecOn && dataArrived && decoderReady) {
          this.hwdecProbeTimer = -1;
          this.frameWatchdogReported = true;
          this.clearFrameWatchdog();
          logI(`硬解探针：${diag}（第 ${probeRound} 次）`
            + ' → ❌ 判定硬解真失败（解码器已开 + 数据已到 + 仍无硬解帧），上报回退软解');
          this._pushEvent({
            'type': 'hwdecNoFrame',
            'viewId': this.viewId,
            'positionSec': this.positionSec,
            'reason': 'hwdec_not_applied',
          });
          return;
        }

        // ③ 源加载慢：数据还没到 → 继续等，绝不上报回退。
        if (!dataArrived && probeRound < HWPROBE_MAX_ROUNDS) {
          logI(`硬解探针（第 ${probeRound}/${HWPROBE_MAX_ROUNDS} 次）：判定「源加载中，数据未到」，`
            + `继续等待，不上报回退。${diag}`);
          this.hwdecProbeTimer = setTimeout(runHwdecProbe, HWPROBE_RETRY_MS);
          return;
        }

        // ④ 预算用尽仍无数据 → 源本身有问题，交给看门狗，不降级软解。
        this.hwdecProbeTimer = -1;
        logI(`硬解探针：${diag}（第 ${probeRound} 次）`
          + ' → ⚠️ 超出等待预算仍无数据，判定为「源侧问题」，'
          + '交由看门狗处理，不做硬解降级（降级也拿不到数据）');
        this._pushEvent({
          'type': 'hwdecProbe',
          'viewId': this.viewId,
          'hwdecCurrent': cur != null ? cur : '',
          'videoFormat': vf != null ? vf : '',
          'voPixelFormat': voFmt,
          'hardwareActive': false,
        });
      } catch (e) {
        logI(`硬解探针读取失败: ${e}`);
      }
    };
    this.hwdecProbeTimer = setTimeout(runHwdecProbe, 1200);
    this.frameWatchdogTimer = setTimeout(() => {
      this.frameWatchdogTimer = -1;
      if (this.disposed || !this.frameWatchdogArmed || this.frameWatchdogReported) {
        return;
      }
      // 进度已前进 → 硬解其实在工作（可能只是首帧慢），不判定失败。
      //
      // 🔴 2026-10-08 修正：判据从 `positionSec` 改为 `realPositionSec`。
      //   positionSec 会被 seek 的乐观置位在**未出帧时**就设成 > 0，
      //   使看门狗误判「硬解正常」而跳过真正的归因分支 —— 掩盖真实故障。
      //   realPositionSec 是 mpv 播放时钟原话，> 0 才确凿代表已出帧。
      if (this.realPositionSec > 0.0) {
        logI(`硬解看门狗：进度已前进 position=${this.realPositionSec}s，硬解正常，不触发回退`);
        return;
      }
      // 🔴🔴 2026-10-07：这里也必须做归因，不能只判「进度为 0」。
      //
      //   旧逻辑：到点进度为 0 → 直接判硬解黑屏 → 上报回退。
      //   问题是「进度为 0」有两种完全不同的成因：
      //     (a) 硬解真的坏了：数据早到了、解码器开着，就是出不了帧；
      //     (b) 源还在加载：数据压根没到，进度自然是 0 —— 这时候降级软解毫无用处，
      //         而降级会触发一次重建，重建的二次 open 又可能撞上未完成的代理请求，
      //         把一次「本来再等两秒就好」变成「整集播放失败」。
      //   真机 22:43:10 / 22:44:53 / 22:45:32 三次误判全是 (b)。
      //
      //   故这里要求：必须是 (a) 才上报回退 —— 即解码器已就绪且数据已到达。
      //   若属于 (b)，则不上报、继续等待，并说明原因。
      const vfW: string = this.player.native.getPropertyString('video-format');
      const curW: string = this.player.native.getPropertyString('hwdec-current');
      const cacheW: number = this.player.native.getPropertyOrNaN('demuxer-cache-time');
      const bufW: number = this.player.native.getPropertyOrNaN('cache-buffering-state');
      const decoderReadyW: boolean = vfW != null && vfW.length > 0;
      const dataArrivedW: boolean = cacheW > 0 || bufW > 0;

      if (!decoderReadyW || !dataArrivedW) {
        // 归因：源侧还没供上数据 → 不是硬解的问题。
        logI(`硬解看门狗：open 后 ${FRAME_WATCHDOG_MS}ms 进度为 0，但归因为「源加载中」`
          + `（video-format='${vfW}' hwdec-current='${curW}' `
          + `demuxer缓存=${Number.isNaN(cacheW) ? 'N/A' : cacheW.toFixed(2) + 's'} `
          + `buffering=${Number.isNaN(bufW) ? 'N/A' : bufW}）`
          + ' → 不上报回退（降级软解解决不了数据未到），继续等待');
        // 再挂一段：源慢时给它更多时间，且仍按同一套归因判据复查。
        this.frameWatchdogTimer = setTimeout(() => {
          this.frameWatchdogTimer = -1;
          if (this.disposed || !this.frameWatchdogArmed || this.frameWatchdogReported) {
            return;
          }
          if (this.realPositionSec > 0.0) {
            logI(`硬解看门狗（延期复查）：进度已前进 position=${this.realPositionSec}s，正常`);
            return;
          }
          const vf2: string = this.player.native.getPropertyString('video-format');
          const c2: number = this.player.native.getPropertyOrNaN('demuxer-cache-time');
          const b2: number = this.player.native.getPropertyOrNaN('cache-buffering-state');
          const ready2: boolean = vf2 != null && vf2.length > 0;
          const data2: boolean = c2 > 0 || b2 > 0;
          if (!ready2 || !data2) {
            logI('硬解看门狗（延期复查）：源侧仍无数据，判定为「源不可用」，'
              + '不降级硬解（降级也拿不到数据）');
            return;
          }
          this.frameWatchdogReported = true;
          logI('硬解看门狗（延期复查）：解码器已就绪 + 数据已到但进度仍为 0，'
            + '判定硬解黑屏，上报 Dart 回退软解');
          this._pushEvent({
            'type': 'hwdecNoFrame',
            'viewId': this.viewId,
            'positionSec': this.positionSec,
            'reason': 'hwdec_not_applied_watchdog',
          });
        }, FRAME_WATCHDOG_MS);
        return;
      }

      this.frameWatchdogReported = true;
      logI(`硬解看门狗：open 后 ${FRAME_WATCHDOG_MS}ms 进度仍为 0，`
        + `且已确认「解码器就绪 + 数据已到」→ 判定硬解黑屏，上报 Dart 回退软解`);
      this._pushEvent({
        'type': 'hwdecNoFrame',
        'viewId': this.viewId,
        'positionSec': this.positionSec,
        'reason': 'hwdec_not_applied_watchdog',
      });
    }, FRAME_WATCHDOG_MS);
  }

  private clearFrameWatchdog(): void {
    if (this.frameWatchdogTimer >= 0) {
      clearTimeout(this.frameWatchdogTimer);
      this.frameWatchdogTimer = -1;
    }
    if (this.hwdecProbeTimer >= 0) {
      clearTimeout(this.hwdecProbeTimer);
      this.hwdecProbeTimer = -1;
    }
    this.frameWatchdogArmed = false;
  }

  private _pushEvent(payload: Record<string, Object>): void {
    if (this.eventSink == null || this.disposed) {
      return;
    }
    try {
      this.eventSink.success(payload);
    } catch (e) {
      logI(`_pushEvent 失败: ${e}`);
    }
  }

  /** onListen 时把 textureId 推回 Dart，供 Texture(textureId) 显示。 */
  pushTextureId(): void {
    if (this.eventSink == null || this.disposed) {
      return;
    }
    this.eventSink.success({
      'viewId': this.viewId,
      'textureId': this.textureId,
      'type': 'texture',
    });
  }

  dispose(): void {
    // 🔴 2026-10-07 幂等保护：Flutter 侧在「换源换代 / 页面重建」场景下，
    //   会对同一个 PlatformView 触发两次 dispose（真机实证：23:35:28.313
    //   出现第二条 `MpvPlayerView.dispose() viewId=4`，而它已在 23:35:28.009
    //   被销毁过一次）。第二次执行会打到已释放的 native handle 上，产生
    //   `[napi:command] mpv is not initialized` 与
    //   `[napi:destroy] mpv is already destroyed` 两条错误日志；
    //   更危险的是此时若引擎已把该 handle 复用给新 view，就会把新 view 的
    //   player 一并销毁 —— 直接表现为「换源后只有声音没有画面」。
    //   故此处必须先判重：已 dispose 过就直接返回，保证幂等。
    if (this.disposed) {
      logI(`MpvPlayerView.dispose() viewId=${this.viewId} 跳过（已销毁过，幂等保护）`);
      return;
    }
    logI(`MpvPlayerView.dispose() viewId=${this.viewId}`);
    this.disposed = true;
    // 🔴 2026-10-07 换源修复：销毁前先向 Dart 广播「本 view 已失效」。
    //
    //   为什么必须显式通知：Dart 侧 MpvBackend 需要准确知道「我手里的 viewId 还能不能收命令」。
    //   此前没有任何通知，Dart 只能靠「open() 时 _viewId 是否为 null」来推断 —— 而换源不重建
    //   后端实例，_viewId 一直留着已销毁的旧 id（非 null），推断必然出错：
    //   等待被跳过 → loadfile 发往死 view → 画面永远出不来。
    //   Dart 侧曾尝试用「自增期望世代号」来绕过，结果因点播是「先建 view、后 open」
    //   而直播是「先 open、后建 view」，时序不可预测，把点播 100% 改成了超时（实测事故）。
    //   改为由原生如实上报后，Dart 只需判 `_viewId == null` 这一个真实事实，无需猜时序。
    //
    //   必须放在 `this.eventSink = null` 之前，否则通知发不出去。
    //   事件名与 Dart 侧 _onNativeEvent 的分支保持一致。
    try {
      const sink = this.eventSink;
      if (sink != null) {
        sink.success({ 'type': 'viewDisposed', 'viewId': this.viewId });
      }
    } catch (e) {
      // 通道已关闭等异常一律忽略：这是尽力而为的通知，不能影响 dispose 本身。
    }
    this.eventSink = null;
    // 🔴 2026-10-07：清理硬解看门狗定时器，避免已销毁视图仍触发上报。
    this.clearFrameWatchdog();
    // 🔴 2026-10-27：停止帧统计采样，避免已销毁视图继续读属性。
    this.stopFrameStat();
    // 🔴 2026-10-06 修复：切换/退出时纹理未解注册导致合成层持续掉帧（40601000）。
    //
    // 根因：路线 B 走 Flutter 纹理，本视图通过 textureRegistry.registerTexture
    // 独占一个 surfaceId/NativeImage。dispose 时若只销毁 player 而不 unregister
    // 纹理，引擎侧的 OHOSExternalTexture 仍持有该 NativeImage，每帧去取缓冲都
    // 拿不到新帧（生产方已死）→ OH_NativeImage_AcquireNativeWindowBuffer 返回
    // 40601000，引擎日志密集刷屏，观感即「切走后还卡一下 / 退出瞬间的掉帧」。
    //
    // AVP 后端（video_player_ohos）的 dispose 已正确调用 unregisterTexture，
    // 故该现象仅 mpv 后端存在。这里在销毁 player 前先解注册纹理，让引擎侧
    // OnTextureUnregistered 释放 GPU 资源、停止合成该纹理。
    //
    // 注意：依据 flutter-ohos TextureRegistry 契约，unregisterTexture 时
    // OHNativeWindow* 不需（也不应）由我们 release，引擎会自行回收。
    try {
      if (this.textureRegistry != null && this.textureId != null && this.textureId >= 0) {
        this.textureRegistry.unregisterTexture(this.textureId);
        logI(`MpvPlayerView.dispose() 已解注册 Flutter 纹理 textureId=${this.textureId}`);
      }
    } catch (e) {
      logE(`MpvPlayerView.dispose() unregisterTexture 异常: ${e}`);
    }
    try {
      this.player.destroy();
    } catch (e) {
    }
    // 同步从工厂视图表移除，避免 views map 残留已销毁视图（textureId 复用冲突）。
    try {
      this.factory?.removeView(this.viewId);
    } catch (e) {
    }
  }

  /** 订阅 mpv-arkts 的 PlayerStream，任一字段变化即推送最新快照。 */
  private _bindStreams(): void {
    const s = this.player.stream;
    s.position.listen((v: number) => {
      // 🔴 HeinPlay 修订（2026-10-08）：seek 期间**丢弃** mpv 的原始 time-pos，
      //   改报「请求值」——这正是 AVP 的做法，语义逐字对齐：
      //
      //     AVP (video_player_ohos/VideoPlayer.ets):
      //       getPosition(): if (this.isSeeking) return this.seekPosition;
      //
      //   【为什么必须丢弃】mpv 的 time-pos 在 seek 期间返回的是**播放时钟目标值**，
      //     且会先吐上一次播放位置的残留值再收敛。真机证据（h11）：
      //       请求 857556ms → seek 后 8ms 采到 931596ms（残留上一位置）
      //       → 偏差 +74040ms = 用户感知的「往前跳 1 分钟」
      //     把这个值上报给 Flutter，就会被写进 _position，成为下一次 seek 的基准，
      //     逐次累加。
      //
      //   【为什么改报请求值而不是干脆不报】与 AVP 完全一致：定位期间进度条应停在
      //     目标点（用户拖到哪就显示哪），而不是回退到旧位置。若完全不报，
      //     Flutter 侧 _position 会停在上一帧旧值，进度条同样错。
      //   【2026-10-08 修补】即使进入守卫也只改 positionSec，**realPositionSec
      //     恒记录 mpv 的原话**（v）。两者分开后，Dart 侧既能让进度条停在目标点，
      //     又能在 mpv 真正落定后拿到未被污染的落点去证伪锚点。
      //   【🔴 2026-10-08 二次修正·关键】`realPositionSec` **绝不能在守卫期间更新**。
      //
      //     初版把它写在 `if (this.seeking)` **之前**，理由是「恒记录 mpv 原话」。
      //     这是错的 —— 上面第 671-676 行已经说明：守卫期间 mpv 吐出的 `v`
      //     恰恰是**上一次播放位置的残留值**（真机 h11：请求 857556ms，
      //     seek 后 8ms 采到 931596ms）。也就是说，**要丢弃的就是这个 v**。
      //
      //     【后果】Dart 侧用 realPositionSec 证伪锚点（判据
      //     `realPos >= anchor - 1500ms`）。用户**往回拖**时，残留的旧位置
      //     本就大于新锚点 → 判据瞬间成立 → 锚点在 seek 刚下发时就被错误释放，
      //     进度条立刻跳回旧位置。这正是 mpv_backend.dart:266-270 记录过的
      //     历史 bug（当时只删了 Dart 层的平移逻辑，未修本处语义）。
      //
      //     【正确语义】realPositionSec 表示「**已确认收敛**的真实播放位置」，
      //     只应在**非守卫期间**（mpv 时钟自由前进、未受 seek 干扰）更新；
      //     守卫期间它保持上一次可信值不变，等 seek 落定后由退出分支刷新。
      //     这样才能保证「它 > 0」确实等价于「已出帧且未在跳转中」。
      //
      //   【🔴🔴 2026-10-08 三次修正·根治·真机证实】上面第 684-700 行的论证
      //   在**方向上是错的**，必须推翻重写。真机 hilog 2026-10-08 23:24–23:27
      //   实测（已 sort -u 去重）暴露了致命后果：
      //
      //     · 7 次「守卫进入」vs 9 次「守卫退出」—— 守卫**几乎总是**由
      //       3 秒看门狗超时退出的（4/4 次 `seek 收敛` 全是超时）。
      //     · 每次 open 内建 seek（--start）mpv **从不**发 PLAYBACK_RESTART：
      //       3 次 open→看门狗时间差精确为 3.001/3.003/3.001s。
      //     · 于是 MpvBridge 退出分支「不采信 state.position」+ 守卫期间
      //       「不更新 realPositionSec」**两条叠加** →
      //       **realPositionSec 永远停在 0 或某个 seek 落点值，从不随时间前进**。
      //
      //   实测证据（本次日志去重后）：
      //     realPositionSec 仅出现过 6 个值：0 / 1399 / 996.116 / 1491.076 /
      //     1039.15 / 1116 —— **全部是 seek 落点或 0**，没有任何一个中间值。
      //     即该字段是「落点快照」，不是「当前播放位置」。
      //
      //   连锁后果（这就是用户报的「每次退出播放记录越来越往后」）：
      //     realPositionSec 恒为 0 → `mpv_backend.dart` 的
      //     `if (realPositionSec > 0)` 从不发流 → Dart `_realPositionMs` 恒为 0
      //     → `_trustedPositionMs` 的锚点释放判据 `_realPositionMs > 0` 恒假
      //     → 锚点**永不释放** → `return pos > anchor ? pos : anchor` 恒取 max
      //     → 播放记录写进被钉死的虚高值 → 下次续播从那里开始 → 越来越往后。
      //
      //   【根治方案】把「进度上报」与「seek 守卫」**彻底解耦**：
      //
      //     关键洞察 —— 守卫的目的是「不要让 mpv 在 seek 未落定时的**残留旧位置**
      //     污染进度条」，而不是「冻结所有位置更新」。而 mpv 的 `time-pos`
      //     在 seek **落定之后**就是真实位置，完全可信。
      //
      //     所以正确的判据不是「是否正在守卫」，而是「这个值是否在合理范围内」：
      //       · 守卫期间：把 v 与 seekTargetSec 比较。
      //         若 |v - target| 很大，说明还是残留旧位置 → 丢弃（只报请求值）；
      //         若 |v - target| 已接近，说明 seek 已落定 → **accepted，
      //         从此按真实值前进**（并顺带解除守卫）。
      //       · 非守卫期间：直接采信 v。
      //
      //     这样 realPositionSec 就能在 seek 落定后**持续前进**，
      //     Dart 侧的锚点释放判据才能真正生效，闭环被打断。
      //
      //   【为什么用 3 秒容差】HLS 的 #EXT-X-TARGETDURATION 为 10 秒，mpv
      //   会把落点量化到最近可解码分片边界。真机实测量化误差可达 54.055s
      //   （请求 942.061 → 实际 996.116）。容差取 3 秒是为了只放行
      //   「明显已落定」的情况；量化误差由退出分支的落点核对单独处理。
      //   宁可保守（多保留一段乐观值），也不要把未落定的残留值放进来 ——
      //   后者正是第 684-695 行记录的历史 bug。
      if (this.seeking) {
        const target = this.seekTargetSec;
        const nearTarget: boolean = target > 0 && Math.abs(v - target) <= 3.0;
        // 🔴 2026-10-08 关键补充：`nearTarget` 单独使用存在**回退型误判**。
        //
        //   【场景】用户从 1491s **往回拖**到 942s。
        //   seek 提交后，mpv 在真正跳过去之前，`time-pos` 会有一段时间
        //   **仍停留在 1491s 附近**（1~3 秒的残留）。此时：
        //     · v           = 1491.0
        //     · target      = 942.0
        //     · |v - target| = 549.0  → 远超 3.0 → 正确地被判为残留 ✅
        //   但如果用户往回拖的**幅度很小**（例如 1491 → 1489），
        //   残留值 1491 与 target 1489 的差只有 2.0s ≤ 3.0s →
        //   **nearTarget 恒真 → 残留被当成落点放行 → 进度条短暂回跳**
        //   → 更糟的是 realPositionSec 被写成残留值。
        //
        //   【堵法】对「往回 seek」额外要求 v **不能高于** target 太多。
        //   因为 seek 落定的标志是「位置到达 target 附近」，若 v 仍显著
        //   大于 target，说明 mpv 还没跳回去。正向 seek（往前拖）则不受影响，
        //   因为此时 v < target，v 大于 target 的情形不存在。
        //
        //   注意：v < target - 3.0（还没追上）→ 由 nearTarget 的绝对值拦住；
        //         v > target + 3.0（还没退下来）→ 由这里拦住。两侧对称。
        const overshoot: boolean = v > target + 3.0;
        if (!nearTarget || overshoot) {
          // 仍是残留旧位置 → 丢弃，进度条停在请求值。
          this.positionSec = target;
          this._pushState();
          return;
        }
        // 🔴 seek 已落定：放行。realPositionSec 从此按 mpv 真实时钟前进。
        //   注意这里**不**主动清 seeking —— 守卫状态由 seekingCount 驱动，
        //   这里只负责让位置上报恢复真实。
        logI(`seek 守卫: 位置已落定（v=${v}s ≈ 请求=${target}s）→ 恢复真实位置上报`);
        this.realPositionSec = v;
        this.positionSec = v;
        this._pushState();
        return;
      }
      // 非守卫期间：mpv 的 time-pos 可靠，同时更新两个字段。
      this.realPositionSec = v;
      this.positionSec = v;
      this._pushState();
    });
    // 🔴 HeinPlay 新增（2026-10-08）：跟踪在途 seek 计数（等价 AVP 的 isSeeking）。
    //
    //   【为何用计数而非布尔】`Stream.add()` 对相同值去重且不通知监听者，
    //   而 seek 可重入 —— 连按快进时上一次 seek 未完成，布尔值 add(true)
    //   会被去重丢弃，该次定位期失去守卫，残留 time-pos 直接污染 Dart `_position`，
    //   表现为「定位完成后又往后跳约 1 分钟」。计数每次自增、永不重复，必然送达。
    s.seekingCount.listen((v: number) => {
      this.seeking = v > 0;
      // 🔴 必须留日志：上一轮守卫没有任何输出，导致「日志里搜不到」被误判成
      //   「代码没生效」，白花一轮排查。这条日志让守卫的置位/复位在真机
      //   hilog 中可见、可核对。
      logI(`seek 守卫: 在途=${v} `
        + (v > 0 ? '进入（屏蔽 mpv 残留 time-pos）' : '退出'));
      if (v > 0) {
        // 进入守卫：立刻把请求值上报，让 Flutter 进度条停在目标点，
        // 而不是显示 mpv 尚未收敛的残留位置。
        this.positionSec = this.seekTargetSec;
        this._pushState();
        return;
      }
      // 🔴 2026-10-08 二次修正·关键：必须先区分「正常收敛」与「看门狗超时收敛」。
      //
      //   【为什么】本分支**几乎总是**由超时触发的。真机 hilog 2026-10-08 23:15–23:17
      //   实证：5 次 seek 的守卫退出与 Player.ets 的 5 次
      //   `看门狗触发：3s 内未收到 playback-restart` **一一对应**，
      //   差值精确为 3.001~3.003s —— **mpv 从未发出 PLAYBACK_RESTART**。
      //
      //   超时意味着 mpv **尚未完成**这次 seek（本次实测：请求 906.150s，
      //   而 `state.position` 读到 1949.356s，差 1043 秒，是上一位置的残留值）。
      //   此刻采信它，就会把一个残留值写进 positionSec 与 realPositionSec，
      //   进而被 Dart 当成落点 → 进度条阶跃／倒跳。这正是用户报的
      //   「显示时间与真实进度不符」在上一轮修复后**换了形式继续存在**的原因。
      //
      //   【修法】超时收敛时**不采信** `state.position`：
      //     · positionSec 保持乐观值（请求值）—— 让进度条停在用户目标点，
      //       与 AVP 语义一致，且不会把残留值暴露给 Dart；
      //     · realPositionSec **保持不变** —— 它是「已确认收敛的真实位置」，
      //       未收敛就不该更新（其权威性由 position 流在非守卫期间维护）。
      //   正常收敛（收到 PLAYBACK_RESTART）时才用 mpv 落点刷新两者。
      const convergedByTimeout: boolean =
        this.player.consumeSeekTimeoutFlag();
      const real = this.player.state.position;
      if (convergedByTimeout) {
        logI(`seek 收敛: **超时**（mpv 未发 playback-restart）→ 不采信 state.position`
          + `=${real}s，positionSec 保持请求值 ${this.seekTargetSec}s，`
          + `realPositionSec 保持 ${this.realPositionSec}s`);
      } else if (real > 0) {
        this.positionSec = real;
        this.realPositionSec = real;
      }
      // 🔴 2026-10-08 新增：把「请求目标」与「实际落点」的差额落盘。
      //
      //   【为什么必须留这条】本轮之前的日志只能看到乐观置位后的 position，
      //   **看不出 seek 到底有没有成功**（请求 1717.156s、实际落在 1589.0s
      //   这种 128s 的落空，在旧日志里完全不可见），导致「mpv 没跳过去」
      //   这件事被误判成「PTS 轴算错」，白查一轮。
      //
      //   【🔴 2026-10-08 二次修正：改为无条件打印】原实现有两层过滤
      //   （`seekTargetSec > 0` 且 `|gap| >= 0.5`），导致真机上**一次都没输出**
      //   （grep `落点`/`核对`/`差额` 计数均为 0），整轮诊断等于瞎跑。
      //   这与本文件 seek 守卫日志曾经的教训完全相同（见上方注释）。
      //   故此处**每次守卫退出都打印**，并附三值（请求/落点/是否超时），
      //   让「seek 到底跳没跳、跳偏多少」在日志里始终可见。
      //
      //   【🔴🔴 2026-10-08 三次修正：超时分支的「差额」是**自证式假零差**，
      //   必须换掉判据】真机日志（23:25:02.958 vs 23:25:03.424）暴露：
      //
      //     超时退出时 `real = player.state.position` 读到的**就是 request 值**
      //     —— 因为守卫期间 `_pushState()` 把 positionSec 覆盖成了 seekTargetSec，
      //     而这个值经 Flutter 侧回灌、又可能被 Player 的 state 反映。于是
      //     `gap = request - real` **恒为 0.000**，打印出来是：
      //       `落点核对: 请求=942.061 实际=942.061 差额=0.000 ⚠️超时`
      //     这条**看起来像「seek 成功了」**，但完全是自证 —— 拿被覆盖的值
      //     去核对请求值，等于自己证明自己。子智能体本轮差点据此误判成功。
      //
      //   【修法】超时分支的「实际落点」改用 `this.realPositionSec`
      //   （由 position 流在非守卫期维护的真实时钟），而不是
      //   `player.state.position`。若非守卫期采样尚未发生，realPositionSec
      //   会是上一次的可信值或 0 —— 两者都能如实表达「本次没有可信落点」，
      //   不会伪造出 0.000 的假象。
      const trustedReal: number = convergedByTimeout
        ? this.realPositionSec   // 超时：state.position 不可信，用真实时钟采样
        : real;                  // 正常收敛：state.position 就是落点
      if (this.seekTargetSec > 0) {
        const gap: number = this.seekTargetSec - trustedReal;
        logI(`seek 落点核对: 请求=${this.seekTargetSec}s `
          + `落点=${trustedReal}s 差额=${gap.toFixed(3)}s `
          + `state.position=${real}s `
          + `${convergedByTimeout ? '⚠️ 超时未收敛，落点取自 realPositionSec（可信）；state.position 与请求值同源，不可作落点判据' : '（已正常收敛）'}`);
      }
      // ── 🔍 2026-10-09 轴对齐埋点：position 与 duration 是否同轴 ──────────
      //
      // 【为什么加】用户报「进度显示的时间有偏移」。已确认 seek 落点精确
      //   （after == target），故偏移必在**显示层**。最可能的机制是：
      //   mpv 的 time-pos（position 来源）与 duration（时长来源）来自
      //   ffmpeg HLS demuxer 的不同计算路径 —— position 基于分片重排后的
      //   PTS 时间线，duration 基于 playlist 里 EXTINF 的累加。
      //   若分片真实 PTS 与 EXTINF 不一致（源含 DISCONTINUITY），两者就分叉。
      //
      // 【判读】
      //   · durationSec 应 ≈ 1302 × 2.0 = 2603.28s（名义轴，已真机确认 43:23）
      //   · 若播放到片尾时 position 显著 > durationSec → 不同轴，position 偏大
      //   · 若 position 始终 ≤ durationSec 且比例线性 → 同轴，偏移在别处
      //
      //   同时打印 seekTargetSec 便于区分「请求值回显」与「真实位置」。
      logI(`🔍轴对齐: positionSec=${this.positionSec.toFixed(3)}s `
        + `realPositionSec=${this.realPositionSec.toFixed(3)}s `
        + `durationSec=${this.durationSec.toFixed(3)}s `
        + `seekTargetSec=${this.seekTargetSec.toFixed(3)}s `
        + `pos/dur=${this.durationSec > 0 ? (this.positionSec / this.durationSec * 100).toFixed(4) : 'N/A'}%`);
      this._pushState();
    });
    s.duration.listen((v: number) => {
      this.durationSec = v;
      this._pushState();
    });
    s.playing.listen((v: boolean) => {
      this.playing = v;
      this._pushState();
    });
    s.buffering.listen((v: boolean) => {
      this.buffering = v;
      this._pushState();
    });
    s.volume.listen((v: number) => {
      this.volume = v;
      this._pushState();
    });
    s.speed.listen((v: number) => {
      this.speed = v;
      this._pushState();
    });
    s.eof.listen((v: boolean) => {
      this.eof = v;
      this._pushState();
    });
    s.buffer.listen((v: number) => {
      this.bufferSec = v;
      this._pushState();
    });
  }

  /** 供 MpvPlugin 调用：处理该视图的控制指令。 */
  handleMethod(call: MethodCall, result: MethodResult): void {
    if (this.disposed) {
      result.error('DISPOSED', 'mpv view disposed', null);
      return;
    }
    try {
      switch (call.method) {
        case 'open': {
          const url: string = call.argument('url') as string;
          // 🔒 隐私：登记需遮蔽的 LunaTV 服务器地址（由 Dart 侧下发），
          //    使 mpv 原生日志里的同一地址也被替换为 ***。
          LogRedactor.setSensitiveHosts(call.argument('sensitiveHosts') as string[] | null);
          const startAtMs: number = (call.argument('startAtMs') as number) ?? 0;
          // mpv-arkts 的 MediaOptions.start 直接映射 mpv 的 start 选项（秒），
          // 加载时即定位——比「open 后补一次 seek」更准确，也避免竞态。
          const options: MediaOptions = {};
          if (startAtMs > 0) {
            options.start = startAtMs / 1000.0;
          }
          // ArkTS 禁止隐式 any：显式标注类型，避免 arkts-no-any-unknown
          const headers: Record<string, string> | null =
            call.argument('headers') as Record<string, string> | null;
          if (headers != null) {
            const map = new Map<string, string>();
            Object.keys(headers).forEach((k: string) => {
              map.set(k, headers[k]);
            });
            if (map.size > 0) {
              options.httpHeaders = map;
            }
          }
          const media = new Media(url, options);
          // 🔴 2026-10-07 第三次修正：**删除「硬件解码」软开关，mpv 始终优先硬解。**
          //    用户决定：设置页不再提供硬解/软解开关，mpv 一律先试硬解。
          //    Dart 侧仍可下发 'forceSoftware'（仅供看门狗自动回退使用，无 UI 入口）。
          //
          //    为什么还需要 Dart 侧回退（mpv 自己的回退不够）：
          //    mpv 的 hwdec-software-fallback 只在 avcodec_send_packet 报错时计数
          //    （video/decode/vd_lavc.c:1162 handle_err），而鸿蒙硬解的故障形态是
          //    「解码成功、VO 出画成功，但帧进不了 Flutter 纹理」——计数器恒为 0，
          //    回退永不触发。因此硬解黑屏必须由 Dart 侧看门狗探测并重建会话。
          //    software-fallback 仍保持 yes，用于接住真正的初始化失败。
          const isLive: boolean = (call.argument('isLive') as boolean) ?? false;
          const forceSoftware: boolean =
            (call.argument('forceSoftware') as boolean) ?? false;
          this.player.native.setProperty(
            'hwdec-software-fallback',
            'yes'
          );
          this.player.native.setProperty('hwdec', forceSoftware ? 'no' : 'ohcodec');
          // 🔴 2026-10-07 三次修正：每次 open 都重申 hwdec-codecs 白名单。
          //    原因：Player.ets 里那行被误删过，导致 hwdec=ohcodec 下发后 mpv
          //    仍全程软解（VO 输出 yuv420p），看门狗空等 8 秒。
          //    在 open 时重申可保证「无论 initialize 阶段的选项是否被覆盖」，
          //    本次会话都带上白名单。
          this.player.native.setProperty(
            'hwdec-codecs',
            'h264,hevc,mpeg2video,mpeg4,h263,vvc'
          );
          // 会话开始：重置取帧看门狗状态（硬解会话才需要监视）。
          // 同时把 positionSec 归零 —— 否则换集时残留的上一集进度会让看门狗
          // 误判「硬解进度已前进」而漏报。
          this.positionSec = 0;
          // 🔴 2026-10-08 补齐：`realPositionSec` 必须与 positionSec 同步归零。
          //
          //   【为什么】看门狗与探针的判据都已改为 `realPositionSec > 0`
          //   （见本文件硬解探针分支 ① 与看门狗）。该字段是后加的，open 时
          //   若不复位，换集后它仍保留**上一集**的进度值 → `> 0` 恒成立 →
          //   新会话的看门狗必然误判「进度已前进、硬解正常」而跳过真正的
          //   归因分支，与上一行修复 positionSec 的原因完全相同。
          this.realPositionSec = 0;
          // 🔴 HeinPlay 新增（2026-10-08）：起播定位同步「请求值 + 定位中」态。
          //   已核实 `--start` 与用户 seek 走同一路径同精度
          //   （mpv player/loadfile.c:2072-2080 queue_seek(...MPSEEK_ABSOLUTE...)），
          //   故 open 期间 time-pos 同样不可信（真机 h11：start=856s 后 11ms 报 0ms）。
          //   Player.open() 内部已把 stream.seekingCount 置位，复位同样靠
          //   MPV_EVENT_PLAYBACK_RESTART。
          this.seekTargetSec = startAtMs / 1000.0;
          if (startAtMs > 0) {
            this.positionSec = this.seekTargetSec;
          }
          this.resetFrameWatchdog(!forceSoftware);
          // 🔴 2026-10-27：起播成功后开始周期性帧统计采样（诊断卡顿）。
          this.startFrameStat();
          // 🔒 隐私：媒体地址可能是用户自建服务器地址，日志里只保留路径。
          logI(`handleMethod open: url=${LogRedactor.redact(url)} start=${options.start ?? 0}s `
            + `hwdec=${forceSoftware ? 'no(回退)' : 'ohcodec'} `
            + `fallback=yes isLive=${isLive} `
            + `headers=${headers != null ? Object.keys(headers).length : 0}个`);
          this.player.open(media, true);
          result.success(null);
          break;
        }
        case 'play': {
          this.player.play();
          result.success(null);
          break;
        }
        case 'pause': {
          this.player.pause();
          result.success(null);
          break;
        }
        case 'seek': {
          // 🔴 2026-09-30 修正：Dart 侧传的是 positionSec（秒），原先这里误读
          //    positionMs 导致取到 undefined→0，seek 永远定位到片头。
          const posSec: number = (call.argument('positionSec') as number) ?? 0;
          const legacyMs: number = (call.argument('positionMs') as number) ?? 0;
          const target: number = (posSec !== 0 || legacyMs === 0) ? posSec : legacyMs / 1000.0;
          logI(`handleMethod seek: ${target}s`);

          // 🔴🔴 2026-10-08 新增：**丢弃「落点与当前已确认位置极近」的空 seek**。
          //
          // 【为什么必须在这里拦】h13 实测 `seek 守卫: 在途=` 计数一路涨到 6
          //   且**永不归零**（20:38:44 峰值 6 → 20:39:42 仍是 5），后果是
          //   `positionSec` 被永久钉死在 `seekTargetSec`
          //   → **Dart 收到的 position 恒定不变 → 进度条时间不走**（用户实证）。
          //
          // 【根因】mpv 对「落点 ≈ 当前解码位置」的 seek 会直接跳过，
          //   **不发 MPV_EVENT_PLAYBACK_RESTART**。而连按快进/长按快进会产生
          //   大量这类空 seek（目标只比当前大零点几秒），每次 +1 都无对应递减。
          //
          // 【判据为何用「已确认位置」而非 seekTargetSec】seekTargetSec 是
          //   **请求值**（乐观置位），用它比较会因「上一次空 seek 已把它改成当前值」
          //   而永远判定为「极近」→ 把真实 seek 也误杀。
          //   故改用 `player.state.position`（mpv 实际解码位置，权威）。
          //
          // 【阈值 0.5s】与 Dart 侧 `_safeSeekToSeconds` 的 500ms 抖动阈值一致；
          //   小于该值的位移在 25fps 下不足半帧，重定位无意义且必然触发空 seek。
          const confirmedSec: number = this.player.state.position;
          // 🔴 2026-10-08【已撤回一处错误修复】此处原本有一行
          //     `if (confirmedSec > 0) { this.realPositionSec = confirmedSec; }`
          //   已被删除，因为它把「seek 提交**之前**的旧位置」写进了 realPositionSec。
          //
          //   【为什么是错的】confirmedSec 读自 `player.state.position`，而这一行
          //   执行时 `this.player.seek(target)` **尚未调用** —— 它拿到的是 seek
          //   之前的旧位置，不是落点。把它当成"真实位置"上报，会让 Dart 侧的
          //   锚点释放判据 `realPos >= anchor - 1500ms` 在**往回拖时**被旧位置
          //   提前满足（旧位置本就比新锚点靠后）→ 锚点被误释放 → 进度条跳回旧位置。
          //
          //   【为什么删掉就对了】position 流监听（本文件 position 回调）已在
          //   **无条件**执行 `this.realPositionSec = v;`，mpv 的每一个真实采样都会
          //   被记录，无需在此处补救。这行赋值是多余的，且只引入错误值。
          if (Math.abs(target - confirmedSec) < 0.5) {
            logI(
              `handleMethod seek: ${target}s 与已确认位置 ${confirmedSec}s `
              + `相差不足 0.5s，判定为空 seek 并丢弃（避免计数泄漏卡死进度条）`,
            );
            // 仍回报目标位置，保证 UI 立即响应，只是不向 mpv 提交命令、
            // 不进守卫态（否则又会 +1 无递减）。
            this.seekTargetSec = target;
            this.positionSec = target;
            this._pushState();
            result.success(null);
            break;
          }

          // 🔴 HeinPlay 新增（2026-10-08）：记录请求值并立刻上报，屏蔽 mpv 残留 time-pos。
          //   Player.seek() 内部会把 stream.seekingCount 置位，此处的 _pushState 负责
          //   让 Flutter 第一时间把进度条画到目标点（而不是等 mpv 收敛）。
          this.seekTargetSec = target;
          this.positionSec = target;
          this._pushState();
          this.player.seek(target);
          result.success(null);
          break;
        }
        case 'setVolume': {
          const v: number = (call.argument('volume') as number) ?? 1.0;
          // Flutter 侧 0..1 → mpv 侧 0..100
          this.player.setVolume(v * 100.0);
          result.success(null);
          break;
        }
        case 'setSpeed': {
          const sp: number = (call.argument('speed') as number) ?? 1.0;
          this.player.setSpeed(sp);
          result.success(null);
          break;
        }
        case 'setFit': {
          // 🔴 2026-10-06 修复：控制栏改画面比例。BoxFit 名映射为 mpv 的
          //   video-aspect-override + panscan（参考 mpv-android 档位逻辑）。
          //   contain = 原始比例（不裁切，保留黑边）；cover = 填充（按容器裁切）；
          //   fill = 拉伸（强制铺满，破坏原始比例）。
          const fit: string = (call.argument('fit') as string) ?? 'contain';
          if (fit == 'fill') {
            this.player.native.setProperty('video-aspect-override', '0');
            this.player.native.setProperty('panscan', 0.0);
          } else if (fit == 'cover') {
            this.player.native.setProperty('video-aspect-override', '-1');
            this.player.native.setProperty('panscan', 1.0);
          } else {
            // contain / 其它：原始比例
            this.player.native.setProperty('video-aspect-override', '-1');
            this.player.native.setProperty('panscan', 0.0);
          }
          logI(`handleMethod setFit: ${fit}`);
          result.success(null);
          break;
        }
        case 'dispose': {
          this.dispose();
          result.success(null);
          break;
        }
        case 'setSurfaceSize': {
          // 🔴 2026-10-06 修复：横竖屏旋转后画面压扁。路线 B 无 XComponent，
          //   onSurfaceChanged 永不触发，故由 Dart 在旋转/尺寸变化时主动下发。
          //   同步更新 mpv 的 ohos-surface-size（出画宽高比）与 Flutter 纹理缓冲尺寸。
          const w: number = (call.argument('width') as number) ?? 0;
          const h: number = (call.argument('height') as number) ?? 0;
          if (w > 0 && h > 0) {
            this.player.native.setProperty('ohos-surface-size', `${w}x${h}`);
            if (this.textureId != null && this.textureId >= 0
                && this.textureRegistry != null) {
              this.textureRegistry.setTextureBufferSize(this.textureId, w, h);
            }
            logI(`handleMethod setSurfaceSize: ${w}x${h}`);
          }
          result.success(null);
          break;
        }
        default:
          result.notImplemented();
      }
    } catch (e) {
      result.error('MPV_ERROR', `${e}`, null);
    }
  }

  /** 绑定状态推送通道。 */
  setEventSink(sink: EventSink | null): void {
    this.eventSink = sink;
    this._pushState();
  }

  /**
   * 🔴 2026-10-27 新增：周期性打印 mpv 真实帧统计（诊断「一卡一卡」）。
   *
   * 采样 2 秒一次，全部用 getPropertyOrNaN（属性不可用时返回 NaN 而不是
   * 静默返回 0 —— 后者会把「读不到」伪装成「值为 0」，正是本工程吃过亏的地方）。
   *
   * 判据（写在日志里，便于下次直接对照）：
   *   · display-fps == 60 且 片源 24fps ⇒ 60/24 = 2.5 非整数 ⇒ 必有 3:2 judder
   *   · display-fps == 120            ⇒ 120/24 = 5.0 整数 ⇒ 不应有 judder
   *   · frame-drop-count 持续增长     ⇒ mpv 自己在丢帧（vo 侧问题）
   *   · estimated-vf-fps 远低于 24    ⇒ 出帧不足（解码或渲染跟不上）
   */
  private startFrameStat(): void {
    this.stopFrameStat();
    this.frameStatTimer = setInterval(() => {
      if (this.disposed) {
        this.stopFrameStat();
        return;
      }
      try {
        const n = this.player.native;
        const displayFps: number = n.getPropertyOrNaN('display-fps');
        const vfFps: number = n.getPropertyOrNaN('estimated-vf-fps');
        const dropVo: number = n.getPropertyOrNaN('frame-drop-count');
        const dropDec: number = n.getPropertyOrNaN('decoder-frame-drop-count');
        const mistimed: number = n.getPropertyOrNaN('mistimed-frame-count');
        const vsyncRatio: number = n.getPropertyOrNaN('vsync-ratio');
        const delayed: number = n.getPropertyOrNaN('vo-delayed-frame-count');
        const hwdec: string = n.getPropertyString('hwdec-current');
        const pixfmt: string = n.getPropertyString('video-params/pixelformat');
        // 🔴 2026-10-28 更新：区分「真按 vsync 走」和「VO 空转重绘」。
        //
        //   ⚠️ 历史注释勘误：早期这里写「OHOS 后端没有 get_vsync 回调」，
        //   那是 10-28 第三次修正之前的状况。**现在已有 get_vsync**。
        //
        //   【2026-10-29 更新】C 侧 vsync 换过一轮又换回来：第十次曾改用
        //   系统 OH_NativeVSync 的真实上屏时间戳，但真机复测**更卡**
        //   （jitter 0.90~1.56、drop(vo) ~161→202/分、delayed ~288→262/分），
        //   已回退到第八版的**自造 60Hz 栅格**（next_vsync_ns += period，
        //   上报栅格时刻而非函数返回时刻）。根因：OH_NativeVSync 是系统硬件
        //   vsync 通道（本机面板 120Hz），与 mpv display-sync 闭环需要的
        //   Flutter 合成器 60Hz 节奏**不同源**，喂错时钟反而更差。
        //
        //   判据（仍然有效）：
        //     · estimated-display-fps ≈ 60 且 vsync-jitter 很小（<0.05）
        //         ⇒ 真的在按 60Hz 走，display-sync 闭环成立
        //     · estimated-display-fps 远大于 60（如 400~500）
        //         ⇒ VO 空转重绘，present 不阻塞，display-sync 无时钟可用
        //     · estimated-display-fps 略低于 60（如 52~56）且 jitter 偏大（>0.5）
        //         ⇒ 上报的时间戳与真实 flip 节奏脱钩。第八/九版就是这个症状
        //           （自造栅格要求 get_vsync 恰好每周期调一次，而 mpv 在
        //           num_vsyncs > 1 时重复渲染不调它）。
        //     · avsync 是当前 A/V 差（秒），持续为负 = 视频跑在音频前面，
        //       正是 num_vsyncs 被 drop_repeat 抬高的直接原因
        //
        //   🔴 C 侧新增了 MP_INFO 级诊断行（Info 就能在 hilog 里看到），
        //   与本表交叉验证，**不要只靠 est-fps 反推**（第九版/方案A 两次都
        //   栽在反推上）：
        //     · 「VSync driver=self-grid period=16.667ms (60.00Hz)」
        //         ⇒ 自造栅格已启用且周期正确（若出现 native-vsync 字样则未回退）
        //     · 「VSync grid: calls=N skips=M max-lag=X ms」
        //         ⇒ skips 长期为 0 且 max-lag < 16.67ms ⇒ 栅格未脱钩（健康）；
        //           skips 持续增长 ⇒ 栅格与 flip 节奏脱钩，是卡顿的直接来源
        const estFps: number = n.getPropertyOrNaN('estimated-display-fps');
        const jitter: number = n.getPropertyOrNaN('vsync-jitter');
        const avsync: number = n.getPropertyOrNaN('avsync');
        logI(`帧统计: display-fps=${displayFps.toFixed(2)} vf-fps=${vfFps.toFixed(2)}`
          + ` drop(vo)=${dropVo} drop(dec)=${dropDec} mistimed=${mistimed}`
          + ` vsync-ratio=${vsyncRatio.toFixed(2)} delayed=${delayed}`
          + ` est-fps=${estFps.toFixed(2)} jitter=${jitter.toFixed(3)}`
          + ` avsync=${avsync.toFixed(3)}`
          + ` hwdec=${hwdec} pixfmt=${pixfmt}`
          + ` pos=${this.positionSec.toFixed(2)}s`);
      } catch (e) {
        logW(`帧统计采样异常: ${e}`);
      }
    }, 2000);
  }

  private stopFrameStat(): void {
    if (this.frameStatTimer >= 0) {
      clearInterval(this.frameStatTimer);
      this.frameStatTimer = -1;
    }
  }

  private _pushState(): void {
    if (this.eventSink == null || this.disposed) {
      return;
    }
    const payload: Record<string, Object> = {
      'viewId': this.viewId,
      'positionSec': this.positionSec,
      // 🔴 2026-10-08 新增：与 positionSec 并行上报**未经乐观置位污染的**
      //   mpv 真实位置。positionSec 在 seek 期间可能是「请求值」，
      //   而本字段恒为 `player.state.position` 观测值（0 表示尚未出帧）。
      //   Dart 侧据此判定「乐观锚点是否已被真实落点证伪」。
      'realPositionSec': this.realPositionSec,
      'seekTargetSec': this.seekTargetSec,
      'seeking': this.seeking,
      'durationSec': this.durationSec,
      'playing': this.playing,
      'buffering': this.buffering,
      // mpv-arkts 的 volume 是 0..130，Flutter 侧按 0..1 使用，这里归一到 0..1
      'volume': this.volume / 100.0,
      'speed': this.speed,
      'eof': this.eof,
      // 已缓冲到的位置（秒），Dart 侧 bufferedStream 用
      'buffer': this.bufferSec,
    };
    this.eventSink.success(payload);
  }
}

/** 工厂：为每个 viewId 创建独立 MpvPlayerView。 */
export class MpvViewFactory extends PlatformViewFactory {
  private messenger: BinaryMessenger;
  private textureRegistry: TextureRegistry;
  private views: Map<number, MpvPlayerView> = new Map();

  constructor(messenger: BinaryMessenger, textureRegistry: TextureRegistry) {
    super(new StandardMessageCodec());
    this.messenger = messenger;
    this.textureRegistry = textureRegistry;
  }

  /**
   * 解析屏幕物理分辨率，作为纹理缓冲与 mpv 窗口的尺寸。
   *
   * 🔴 2026-10-01：路线B 下 Player.onSurfaceChanged() 不会触发（无 XComponent），
   *    mpv 的 openharmony-surface-size 必须由外部给定，否则会走
   *    vo_openharmony_surface_size() 的上游 bug 分支拿到未初始化尺寸 → 黑屏。
   *
   * 取不到时退回 1920x1080（主流鸿蒙设备下限），保证永不出现 0 尺寸。
   */
  static resolveDisplaySize(): DisplaySize {
    try {
      const dm: display.Display = display.getDefaultDisplaySync();
      const w: number = dm.width;
      const h: number = dm.height;
      if (w > 0 && h > 0) {
        return { width: w, height: h };
      }
    } catch (e) {
      logE(`resolveDisplaySize 取屏幕尺寸失败: ${e}`);
    }
    return { width: 1920, height: 1080 };
  }

  /**
   * 🔴🔴 2026-10-28：只读屏幕刷新率（Hz）。取不到返回 0。
   *
   * 【为什么必须由宿主注入】mpv 的 OHOS 输出后端
   *   （video/out/opengl/context_ohos.c:127 与 video/out/vulkan/context_ohos.c:98）
   *   里 `ohos_control()` **恒返回 VO_NOTIMPL**，即 `VOCTRL_GET_DISPLAY_FPS`
   *   从未实现。后果链（已逐行核对 mpv 源码）：
   *     vo->driver->control(VOCTRL_GET_DISPLAY_FPS) 不填 fps   (vo.c:544)
   *     → in->reported_display_fps = 0                        (vo.c:548)
   *     → nominal_vsync_interval = 0                          (vo.c:556)
   *     → vsync_interval = MPMAX(0, 1) = 1ns  ← 荒谬值        (vo.c:557)
   *     → vo_get_vsync_interval(): 1 > 1 为假 → 返回 -1       (vo.c:1358)
   *     → player/video.c:838  if (vsync <= 0) return;         ← display-sync 整段跳过
   *   即**任何 display-* 模式在鸿蒙上都是静默失效的**。这是本轮「一卡一卡」
   *   迟迟修不掉的关键：不是配置写错，是底层拿不到 vsync。
   *
   * 【解法】用 display.getDefaultDisplaySync().refreshRate 读真实值，
   *   经 mpv 的 `display-fps-override` 注入 —— 该选项在 vo.c:551 处
   *   **优先于** reported_display_fps，是绕开未实现 VOCTRL 的唯一正路。
   *
   * 【数学依据】片源实测 24fps（日志 ● Video --vid=1 h264 1920x818 24 fps）：
   *     60Hz : 60/24 = 2.5  非整数 → 每帧交替占 2/3 个 vsync → 3:2 judder
   *     90Hz : 90/24 = 3.75 非整数 → 仍有 judder
   *     120Hz: 120/24 = 5.0 整除  → 完全均匀，无 judder
   *   而 Flutter 的 OhosVsyncVotingMgr 在无触摸 3 秒后**必投 FPS_60**
   *   （ohos_vsync_voting_mgr.cpp:314-317），故播放时屏幕实际被锁 60Hz，
   *   24fps 必然踩 2.5 失配。这与 AVP 流畅形成对照：AVP 走系统 AVPlayer，
   *   由系统合成器协商刷新率，不受该投票机制约束。
   *
   * 与 resolveDisplaySize() 分开，避免改动那条已稳定多年的尺寸路径。
   */
  static resolveRefreshRate(): number {
    try {
      const dm: display.Display = display.getDefaultDisplaySync();
      const rr: number = dm.refreshRate;
      if (rr != null && rr > 0) {
        logI(`resolveRefreshRate: ${rr}Hz`);
        return rr;
      }
      logW('resolveRefreshRate: 系统未报告刷新率，返回 0');
    } catch (e) {
      logE(`resolveRefreshRate 失败: ${e}`);
    }
    return 0;
  }

  create(context: common.Context, viewId: number, args: Object): PlatformView {
    // 这条日志出现，说明 Flutter 引擎确实向本工厂请求创建原生视图 ——
    // 即 Dart 侧的挂载锚点已进入渲染树且完成布局。若此日志缺失，
    // 问题一定在 Dart 侧（视频层没被挂载 / 尺寸为 0 / 被优化掉）。
    logI(`MpvViewFactory.create() viewId=${viewId} —— Flutter 请求创建原生视图`);
    // 🔴 HeinPlay 路线 B：注册 Flutter 纹理拿 surfaceId + textureId。
    //    surfaceId 直接喂给 mpv（替代 XComponent 的 onSurfaceCreated），
    //    textureId 回传 Dart 用于 Texture(textureId) 显示。
    const textureId = this.textureRegistry.getTextureId();
    const entry = this.textureRegistry.registerTexture(textureId);
    const surfaceId = entry.getSurfaceId().toString();
    logI(`MpvViewFactory.create() viewId=${viewId} 注册纹理 textureId=${textureId} surfaceId=${surfaceId}`);

    // 🔴 2026-10-01 修正（路线B 黑屏第三因）：主动设定纹理/窗口尺寸。
    //
    //   为什么必须在这里设：
    //   · 路线B 下 getView() 返回空占位、不建 XComponent，因此
    //     Player.onSurfaceChanged() **永远不会被回调** —— 尺寸下发通道整条断掉。
    //   · mpv 侧 vo_openharmony_surface_size()（openharmony_common.c:83）在读不到
    //     尺寸时会走一个上游 bug 分支：该分支**恒 return false 且不回填
    //     *out_w/*out_h**，而调用方 context_openharmony.c 里写的是
    //     `int w, h;`（未初始化）→ SET_BUFFER_GEOMETRY 拿到栈上垃圾值 →
    //     EGL surface 尺寸非法 → 黑屏。
    //   · 所以必须让 openharmony-surface-size 选项有确定值（走正常分支）。
    //
    //   尺寸来源：Flutter 的 PlatformViewCreationRequest 里带 logicalWidth/
    //   logicalHeight，但自定义工厂的 args 拿不到它，故用显示器的物理分辨率兜底。
    //   纹理与 mpv 窗口同尺寸，保证 1:1 渲染不缩放。
    const size = MpvViewFactory.resolveDisplaySize();
    this.textureRegistry.setTextureBufferSize(textureId, size.width, size.height);
    logI(`MpvViewFactory.create() viewId=${viewId} 纹理缓冲尺寸设为 ${size.width}x${size.height}`);
    // 🔴 2026-10-28：读真实刷新率（供 mpv display-fps-override 用）。
    //   与尺寸分开取，因为尺寸路径已稳定多年，不动它降低回归风险。
    const refreshRate = MpvViewFactory.resolveRefreshRate();

    // 🔴 HeinPlay 2026-10-07：包一层错误处理。
    //
    //   事故背景：MpvLib 曾处于「实验模式」（静态 import 恒 undefined + 空转的
    //   ensureMpvModuleLoaded），导致 new Player() 抛出
    //   `Cannot read property NativePlayer of undefined`。
    //   由于此处没有 try/catch，异常直接冒到 Flutter 侧变成
    //   `PlatformViewsChannel --> create failedTypeError`，
    //   表现为「所有源 + 直播全部播放失败」，而 mpv 自身 0 条日志，极难定位。
    //
    //   现在：捕获异常 → 打出明确的原因 → 返回占位视图（不崩），
    //   让上层能看到「是 NAPI 模块没加载好」，而不是一片沉默。
    let view: MpvPlayerView;
    try {
      view = new MpvPlayerView(context, viewId, args, textureId, surfaceId, size, this.textureRegistry, this, refreshRate);
    } catch (e) {
      const msg: string = (e && e.message) ? e.message : String(e);
      logE(`MpvViewFactory.create() viewId=${viewId} 创建播放器失败: ${msg}`);
      logE('  ↑ 若为「尚未加载完成」或「NativePlayer of undefined」，'
        + '说明 libmpv_wrapper.so NAPI 模块未就绪，检查 MpvLib 的动态加载是否为最新实现');
      // 兜底：再触发一次加载，供下次 create 使用
      ensureMpvModuleLoaded().catch(() => {
      });
      throw new Error(`mpv 播放器创建失败: ${msg}`);
    }
    this.views.set(viewId, view);

    // 为该视图注册独立的状态事件通道（Dart 侧按 viewId 监听）
    const events = new EventChannel(this.messenger, mpvEventsChannel(viewId));
    events.setStreamHandler({
      onListen: (args2: Object, sink: EventSink): void => {
        logI(`事件通道 onListen viewId=${viewId}`);
        view.setEventSink(sink);
        // 🔴 路线 B：onListen 时把 textureId 随首条状态推回 Dart，
        //    供 buildVideoWidget 在 Texture(textureId) 显示。
        view.pushTextureId();
      },
      onCancel: (args2: Object): void => {
        logI(`事件通道 onCancel viewId=${viewId}`);
        view.setEventSink(null);
      }
    } as StreamHandler);

    return view;
  }

  getView(viewId: number): MpvPlayerView | undefined {
    return this.views.get(viewId);
  }

  removeView(viewId: number): void {
    this.views.delete(viewId);
  }
}

/** Flutter 插件入口。 */
export class MpvPlugin implements FlutterPlugin, MethodCallHandler {
  private channel: MethodChannel | null = null;
  private factory: MpvViewFactory | null = null;
  // 🔴 HeinPlay 路线 B：持有 Flutter 纹理注册表，供工厂注册纹理拿 surfaceId。
  private textureRegistry: TextureRegistry | null = null;

  getUniqueClassName(): string {
    return 'MpvPlugin';
  }

  onAttachedToEngine(binding: FlutterPluginBinding): void {
    const messenger = binding.getBinaryMessenger();
    this.textureRegistry = binding.getTextureRegistry();
    this.factory = new MpvViewFactory(messenger, this.textureRegistry);

    // 🔴 2026-10-07 深夜：模块加载改用【静态 import】（见 MpvLib.ets 顶部说明）。
    //
    //   历史归因更正：此前这里写「静态 import 恒为 undefined（真机探针已证）」，
    //   观测没错但归因错了 —— 当时 so 缺 libuv.so 依赖，dlopen 失败，
    //   所以静态 import 拿到 undefined。补齐依赖后静态 import 即可用
    //   （20:48 能播版用的正是静态导入：日志 `实验模式：静态导入，无需动态加载`）。
    //
    //   而动态 import('libmpv_wrapper.so') 拿不到 NAPI 导出，只会返回带 default
    //   的空壳（真机日志：`模块实际导出=[default]`），是播放全挂的真凶。
    //
    //   MpvLib 现在在模块层直接 `import libmpv from 'libmpv_wrapper.so'`，
    //   这里调用的 ensureMpvModuleLoaded() 只做「校验 + 缓存」，不再有异步加载窗口，
    //   但保留调用以尽早暴露错误（视图创建前就能从日志看到失败原因）。
    ensureMpvModuleLoaded()
      .then(() => {
        logI('libmpv_wrapper 模块就绪（插件挂载阶段）');
      })
      .catch((e: Error) => {
        logE('libmpv_wrapper 模块异常: ' + (e && e.message ? e.message : String(e)));
      });

    // 注册 PlatformView 工厂
    const registry: PlatformViewRegistry = binding.getPlatformViewRegistry();
    registry.registerViewFactory(VIEW_TYPE, this.factory);

    // 控制通道（按 viewId 路由）
    this.channel = new MethodChannel(messenger, CHANNEL_CONTROL);
    this.channel.setMethodCallHandler(this);
  }

  onDetachedFromEngine(binding: FlutterPluginBinding): void {
    if (this.channel != null) {
      this.channel.setMethodCallHandler(null);
      this.channel = null;
    }
    this.factory = null;
  }

  onMethodCall(call: MethodCall, result: MethodResult): void {
    const viewId: number = (call.argument('viewId') as number) ?? -1;
    const view = this.factory?.getView(viewId);
    if (view == null) {
      result.error('NO_VIEW', `no mpv view for id ${viewId}`, null);
      return;
    }
    view.handleMethod(call, result);
  }
}
