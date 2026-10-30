/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

import {
  EventObserver, LogObserver, MpvEvent, MpvFormat, MpvLib, MpvNode
} from './MpvLib'
import { PlayerState } from './models/PlayerState';
import { image } from '@kit.ImageKit';
import { Chapter } from './models/Chapter';
import {
  AudioTrack, Track, Tracks, SubtitleTrack, VideoTrack
} from './models/Track';
import { Media } from './models/Media';
import { Playlist } from './models/Playlist';
import { PlayerStream } from './models/PlayerStream';
import { PlayerLog } from './models/PlayerLog';
import { AudioParams } from './models/AudioParams';
import { VideoParams } from './models/VideoParams';
import { MpvLogLevel, PlayerConfig } from './models/PlayerConfig';
import { PlaylistMode } from './models/PlaylistMode';
import { Utils } from './utils/Utils';
import { LogRedactor } from './utils/LogRedactor';

interface RawTrack {
  id: number;
  codec: string;
  lang: string;
  title: string;
  type: string;
  selected: boolean;
}

@ObservedV2
export class Player extends XComponentController implements EventObserver, LogObserver {
  native: MpvLib = new MpvLib();
  private config: PlayerConfig;
  /**
   * Current player state.
   */
  @Trace state: PlayerState = new PlayerState();
  /**
   * Player event streams.
   */
  stream: PlayerStream = new PlayerStream();

  /**
   * 🔴 HeinPlay 新增（2026-10-08）：在途 seek 计数（0 = 空闲）。
   *
   * 与 `stream.seekingCount` 配套：后者用于通知 MpvBridge 进入/退出守卫态，
   * 本字段是权威计数。`seek()` 自增、`MPV_EVENT_PLAYBACK_RESTART` 递减（下限 0）。
   * 详见 `PlayerStream.seekingCount` 的注释（为什么不能用 boolean）。
   */
  private inFlightSeekCount: number = 0;

  /**
   * 🔴 HeinPlay 新增（2026-10-08）：本次守卫退出是否为「看门狗超时收敛」。
   *
   * 【为什么需要】守卫退出分支会用 `player.state.position` 刷新上报位置。
   *   若因超时退出，mpv 很可能**尚未完成这次 seek**，此时 `state.position`
   *   读到的是残留/中间值。真机 hilog 2026-10-08 23:15–23:17 实证：
   *   5 次 seek 的守卫退出与 5 次超时**一一对应**（差值 3.001~3.003s），
   *   mpv **从未**发出 PLAYBACK_RESTART，每次都拿到未收敛值（实测
   *   请求 906.150s、读到 1949.356s，差 1043 秒）。
   *
   * 【消费方】MpvBridge 在 `seekingCount` 归零回调中读取本标记：
   *   为 true 时**不采信** `state.position`，保持乐观值不动。
   *   读取后由 MpvBridge 调用 `consumeSeekTimeoutFlag()` 复位，
   *   保证下一次正常收敛不受影响。
   */
  private seekConvergedByTimeout: boolean = false;

  /** 读取并清除「超时收敛」标记（MpvBridge 在守卫退出回调中调用）。 */
  consumeSeekTimeoutFlag(): boolean {
    const flagged = this.seekConvergedByTimeout;
    this.seekConvergedByTimeout = false;
    return flagged;
  }

  /**
   * 🔴 HeinPlay 新增（2026-10-08）：seek 看门狗定时器 id（-1 = 未在等待）。
   *
   * 【为什么必须有】mpv 对「落点与当前解码位置极近」的 seek 会直接跳过，
   *   **不发 MPV_EVENT_PLAYBACK_RESTART**。若只靠该事件递减计数，
   *   这类空 seek 会让 `inFlightSeekCount` 只增不减 → `seekingCount` 永久 >0。
   *
   * 【真机后果】h13 实测计数卡在 5 不归零（20:38:44 峰值 6 → 20:39:42 仍是 5），
   *   `MpvBridge` 永久处于守卫态 → `positionSec` 被钉死在 `seekTargetSec`
   *   → **Dart 收到的 position 恒定不变 → 进度条时间不走**（用户实证现象）。
   *
   * 【机制】`seek()` 提交时重置该定时器；若 3 秒内未收到 PLAYBACK_RESTART，
   *   看门狗直接把计数收敛到 0。3 秒依据 h13 实测：正常 seek 的
   *   seek→playback-restart 间隔为 1.5s（20:08:22.167→23.691）与
   *   2.2s（20:08:16.569→18.788），留足余量。
   *
   * 注：`MpvBridge` 侧已额外拦截「相差不足 0.5s 的空 seek」从源头减少此类情况；
   *     本看门狗是**第二道保险**，覆盖其它 mpv 不发事件的边界情形。
   */
  private seekWatchdogId: number = -1;

  /**
   * 重置 seek 看门狗：3 秒内没有 PLAYBACK_RESTART 就把在途计数强制清零。
   *
   * 【为什么用「重置」而不是「只在无定时器时创建」】连续 seek 时旧定时器代表的
   *   那一次 seek 可能已被新 seek 取代，若沿用旧定时器会在第 3 秒误清零**新的**
   *   在途计数。故每次 seek 都重新计时，保证「最后一次 seek 之后 3 秒」才收敛。
   */
  private armSeekWatchdog(): void {
    if (this.seekWatchdogId >= 0) {
      clearTimeout(this.seekWatchdogId);
      this.seekWatchdogId = -1;
    }
    this.seekWatchdogId = setTimeout(() => {
      this.seekWatchdogId = -1;
      if (this.inFlightSeekCount > 0) {
        // 与文件内既有约定一致：必须用 console.warn 而非 I 级日志 ——
        // 真机 hilog 抓取默认只保留 W/E，I 级会被整条过滤掉。
        console.warn(
          `[mpv-seek] 看门狗触发：3s 内未收到 playback-restart，`
            + `在途计数 ${this.inFlightSeekCount} → 0（mpv 空 seek 不发事件）`,
        );
        // 🔴 2026-10-08 新增：标记「本次守卫是因**超时**而收敛，而非 mpv 正常完成」。
        //
        //   【为什么必须让 MpvBridge 知道】守卫退出分支会用
        //   `player.state.position` 刷新 positionSec/realPositionSec。但若是超时
        //   退出，mpv 很可能**还没完成这次 seek**，此时读到的是中间值/残留值。
        //   真机证据（hilog 2026-10-08 23:15-23:17）：5 次 seek 的守卫退出与
        //   5 次本函数触发的超时**一一对应**，时间差精确到 3.001~3.003s ——
        //   即 mpv**从未**发出 PLAYBACK_RESTART，每一次都是超时收场。
        //   这种情况下采信未收敛的 position，会把偏差写进 Dart 的进度基准。
        //
        //   【为什么不用新增 stream 字段】Stream 会对相同值去重，且新增公开
        //   字段需要同步改 PlayerStream 的 close() 与类型定义，改动面大。
        //   MpvBridge 已经订阅了 seekingCount，用「先置标记、再 add(0)」的顺序
        //   即可保证标记在监听回调执行前就已就绪（Stream.add 是同步派发）。
        this.seekConvergedByTimeout = true;
        this.inFlightSeekCount = 0;
        this.stream.seekingCount.add(0);
      }
    }, 3000);
  }

  /** 取消 seek 看门狗（已收到 PLAYBACK_RESTART 或对象销毁时调用）。 */
  private disarmSeekWatchdog(): void {
    if (this.seekWatchdogId >= 0) {
      clearTimeout(this.seekWatchdogId);
      this.seekWatchdogId = -1;
    }
  }

  /**
   * Initializes mpv player.
   *
   * ```
   * const player = new Player(new PlayerConfig({
   *   vo: "gpu-next"
   * }));
   * ```
   *
   * @param config    Player configuration, optional.
   */
  constructor(config: PlayerConfig = new PlayerConfig()) {
    super();
    this.config = config;

    this.native.addEventObserver(this);
    this.native.addLogObserver(this);
    this.native.registerEventCallback();
    this.native.registerLogCallback();
    this.native.create();

    let level = ""
    switch (this.config.logLevel) {
      case MpvLogLevel.Fatal:
        level = "fatal";
        break;
      case MpvLogLevel.Error:
        level = "error";
        break;
      case MpvLogLevel.Warn:
        level = "warn";
        break;
      case MpvLogLevel.Info:
        level = "info";
        break;
      case MpvLogLevel.V:
        level = "v";
        break;
      case MpvLogLevel.Debug:
        level = "debug";
        break;
      case MpvLogLevel.Trace:
        level = "trace";
        break;
    }
    this.native.requestLogMessages(level);

    // Basic
    this.native.setOptionString("config", "yes");
    this.native.setOptionString("config-dir", this.config.configDir);
    this.native.setOptionString("profile", "fast");
    this.native.setOptionString("idle", "yes");
    this.native.setOptionString("keep-open", "yes");
    this.native.setOptionString("input-ime", "no");
    this.native.setOptionString("input-builtin-bindings", "no");
    this.native.setOptionString("watch-later-options", "start,vid,aid,sid");
    this.native.setOptionString("osc", this.config.osc ? "yes" : "no");
    this.native.setOptionString("osd-level", this.config.osd ? "1" : "0");

    // Render backend
    // 🔴🔴 2026-10-28 第六次修正：默认后端改为 Vulkan（"ohosvk"）。
    //   方针：除 legacy 版本外，全平台尽可能走 Vulkan，不因遇到困难退回 OpenGL。
    //
    //   ① gpu-context：本工程有**两条独立的 OHOS 后端**，注册名只差三个字母：
    //        "ohos"   → video/out/opengl/context_ohos.c（OpenGL/EGL，旧路径）
    //        "ohosvk" → video/out/vulkan/context_ohos.c（Vulkan，现默认）
    //      ⚠️ 与官方 master 的 "openharmony" 也不同，换源码时必须同步改。
    //      两者各有各的 ra_ctx_params 与 init()，改错一个等于没改，而且
    //      编译/链接/符号/字符串检查全查不出来（只有反汇编或真机日志能发现）。
    //   ② hwdec：现在**有硬解了**，用 "ohcodec"（ErBWs 走鸿蒙 OHCodec）。
    //      Vulkan 下的零拷贝由 hwdec_ohcodec_pl.c 提供（libplacebo interop），
    //      依赖 VK_OHOS_native_buffer / VK_OHOS_external_memory 两个设备扩展，
    //      libplacebo 已打补丁启用，设备侧实测支持（Maleoon 910）。
    //      🔴 2026-10-07 二次修正：hwdec-software-fallback **恢复为始终 yes**
    //      （与上游 Player.ets 原始默认一致）。
    //      真机证据：把回退关掉（下发 no）这一步本身就把播放打破了 —— 点播
    //      （mpv 与 avplayer）播放失败，而关闭之前一切正常。
    //      机制：mpv vd_lavc.c 中只要 hwdec=no（用户显式要软解）use_hwdec 恒为 false，
    //      同样落入 else 分支；此时若 software_fallback == INT_MAX（即 no），mpv 判定
    //      「软解回退被禁用」并置 ctx->force_eof = true → 只有声音没画面 / 播放失败。
    //      故必须允许回退：硬解失败自动转软解，保证永远能出画。
    //   ③ 尺寸选项名：该分支用 "ohos-surface-size"（不是 openharmony-surface-size）。
    this.native.setOptionString("vo", this.config.vo);
    this.native.setOptionString("gpu-context", this.config.gpuContext);
    this.native.setOptionString("hwdec-software-fallback", "yes");
    this.native.setOptionString("hwdec", this.config.hwdec ? "ohcodec" : "no");
    //   🔴 2026-10-07 三次修正：补回被误删的 hwdec-codecs 白名单！
    //      上游基线（Player.ets.orig L111）本来有这一行：
    //        setOptionString("hwdec-codecs", "h264,hevc,mpeg2video,mpeg4,h263,vvc")
    //      在 10-07 重排注释时被误删，后果是 mpv 不再对 h264/hevc 尝试 ohcodec 硬解，
    //      静默全程软解 —— 真机日志实证：7 次 hwdec=ohcodec 下发，但 7 次
    //      VO: [gpu-next] 1920x818 **yuv420p**（纯 CPU 帧格式），且全日志无任何
    //      「Opening decoder / Using hardware decoding」记录。
    //      这正是用户反馈「之前硬解也没问题、现在变差」的根因：
    //      硬解从未生效，只是白等看门狗 8 秒后回退。
    this.native.setOptionString("hwdec-codecs", "h264,hevc,mpeg2video,mpeg4,h263,vvc");
    if (this.config.gpuContext === "ohos") {
      this.native.setOptionString("opengl-es", "yes");
      this.native.setOptionString("egl-output-format", "rgba8");
    } else if (this.config.gpuContext === "ohosvk") {
      // 🔴 2026-10-28 第六次修正：Vulkan 侧显式配置。
      //   ① vulkan-swap-mode=fifo：FIFO 是唯一能保证不撕裂且被合成器承认的模式，
      //      也是 context_ohos.c 里 ra_vk_ctx_init 传入的 preferred_mode 默认值。
      //      显式写出来是为了让日志里能看到实际生效值，避免「以为设了」。
      //   ② swapchain-depth=2（默认值，此处不覆盖）：注意它的语义是
      //      libplacebo 的**GPU 渲染队列深度**（vulkan.h:352-355 明文说明它只能
      //      等到 GPU 渲染完、等不到上屏完成），不是 present 队列深度。
      //      ⚠️ 2026-10-28 上一轮曾在 GL 路径上试过 swapchain-depth=1 并判定
      //      「无效」——那个结论本身没错，但原因是该参数**只在 Vulkan 路径生效**
      //      （ra_vk_ctx_init 里才把它传给 pl_vulkan_swapchain_params），
      //      GL 路径压根不用它。现在走 Vulkan，这个旋钮才真正有效，
      //      但先保持默认 2，一次只改一个问题。
      this.native.setOptionString("vulkan-swap-mode", "fifo");
    }

    // Video
    //
    // 🔴🔴 2026-10-07 换源/卡顿复测后修正：video-sync 由 display-resample 改为 audio。
    //
    //   【现象】点播播放期间周期性「画面卡一下，然后快放追上声音」，声音全程正常。
    //   【真因】真机日志 22:58:54.541 明确报：
    //            Audio/Video desynchronisation detected! ... Consider trying
    //            `--profile=fast` and/or `--hwdec=auto` as they may help.
    //          并行出现的还有 12 次 Invalid audio PTS（如 1143.232 -> 1145.066644，
    //          瞬间跳 1.8 秒）。
    //
    //   display-resample 的语义是：**把视频时钟锁到显示器刷新率**，并靠微调音频
    //   重采样率来适配。它要求片源帧率与屏幕刷新率有整齐倍率关系。
    //   本机屏幕 60Hz，而该点播源多是 25fps 的 PAL 片源：60/25 = 2.4，不是整数。
    //   于是 mpv 必须持续微调音频去凑 —— 只要音频 PTS 稍有跳变（源里那条 mp2 音轨
    //   本身就有 Header missing 缺损），重采样器就跟不上，判定失去同步，
    //   表现即「先冻住画面 → 再快放把落后帧追回来对齐音频」。
    //   注意此时**音频是基准**，所以声音听不出问题，只有画面在被拉扯。
    //
    //   audio 模式的语义是：**直接以音频时钟为基准**放视频，不锁定屏幕刷新率。
    //   这是 mpv 默认值，也是所有移动端播放器的通行做法 —— 移动设备刷新率固定、
    //   片源帧率五花八门，锁刷新率没有收益，只有失同步风险。
    //   代价：不做 24/25/30→60 的完美帧节奏（可能有轻微 3:2 类抖动），
    //   但对「IPTV 直播 + 网络点播」这类内容观感无影响，而换来的稳定同步是必需的。
    // 🔴🔴 2026-10-28 第五次修正：**改回 display-resample**，与宿主 extraOptions 配套。
    //
    //   【为什么推翻 10-07 的结论】10-07 改回 audio 的直接诱因是 25fps 片源
    //   （60/25 = 2.4 非整数）+ 音轨 PTS 缺损导致 desynchronisation。那个判断
    //   在当时是对的，但它把「display-resample 本身有问题」和「那条音轨有问题」
    //   混在了一起。本轮（10-28）拿到关键新证据后结论必须修正：
    //
    //   【新证据①】本轮片源实测 **24 fps**（日志 ● Video --vid=1 h264 1920x818 24 fps）。
    //     mpv 的 calc_best_speed()（player/video.c:680）在 24fps@60Hz 下返回 **1.0**
    //     —— 即**不做任何变速**，只把每帧交替分配 2 个 / 3 个 vsync。
    //     已实测验证：25fps 会算出 1.0286（加速 2.86%）并拉扯音频，而 24fps 不会。
    //     所以「display-resample 会变速导致失同步」这条在 24fps 上**不成立**。
    //
    //   【新证据②】AVP 能流畅播放 ⇒ 片源/解码/屏幕/系统调度全部正常，
    //     差异只在 mpv 的输出路径。而 mpv 的 OHOS 后端 ohos_control() 恒返回
    //     VO_NOTIMPL，VOCTRL_GET_DISPLAY_FPS 从未实现 ⇒ display-fps=0 ⇒
    //     vsync_interval 退化成 1ns ⇒ 任何依赖 vsync 的时序全部失效。
    //
    //   【为什么 audio 模式必然卡】audio 模式完全不看 vsync，按帧 PTS 直接送。
    //     24fps 帧间隔 41.67ms，而屏幕 60Hz 每 16.67ms 刷新一次 ⇒ 每帧要
    //     跨 2.5 个刷新周期 ⇒ 实际呈现节奏被迫变成 33.3ms/50ms 交替（3:2 judder）。
    //     叠加 interpolation=no，没有任何手段抹平这个间隔差 ⇒ 肉眼即「一卡一卡」。
    //
    //   【display-resample 怎么解决】它把视频时钟锁到 vsync，并配合
    //     interpolation=yes 在 vsync 边界混合出中间帧，把 2/3 交替的不均匀
    //     间隔补成等距 —— 这是消除 24@60 judder 的标准做法（也是桌面 mpv 的推荐配）。
    //     前提是 display-fps 必须正确，故宿主侧注入 display-fps-override。
    //   【2026-10-28 第十次 / 10-29 十二次】C 侧 vsync 换过一轮又换回来。
    //     第十次改用系统 OH_NativeVSync 回调的真实上屏时间戳，动机是「自造栅格
    //     要求 get_vsync 恰好每周期被调一次，而 mpv 在 num_vsyncs > 1 时会重复
    //     渲染同一帧、只在最后一轮 flip，中间轮次不调 get_vsync ⇒ 栅格脱钩」。
    //     但 10-29 真机复测证明**换成系统 vsync 更卡**，已回退到第八版自造栅格：
    //       指标          第八版   第九版   方案A(实测)
    //       jitter        0.73     1.13     0.90~1.56
    //       drop(vo)/分   81       122      ~161 / ~202
    //       delayed/分    34       60       ~288 / ~262
    //     根因是**时钟域不同源**：OH_NativeVSync 是系统硬件 vsync 通道（本机面板
    //     120Hz），而 mpv display-sync 闭环要的是 Flutter 合成器的出帧节奏
    //     （60Hz，即这里注入的 display-fps-override）。拿前者喂 vo.c 估计器
    //     等于喂错时钟。
    //     ⇒ display-resample 的闭环时钟仍由 C 侧自造 60Hz 栅格提供，
    //       display-fps-override 必须与它保持同源（都是 60Hz）。
    this.native.setOptionString("video-sync", "display-resample");
    this.native.setOptionString("target-colorspace-hint", "yes");
    // interpolation 与 display-resample 是配套的：靠插帧把帧补回 vsync 节奏。
    // 🔴 2026-10-28：由 no 改回 yes。10-07 关掉它的理由是「不锁刷新率时插帧无意义」，
    //   现在锁刷新率了，插帧正是消除 3:2 judder 的唯一手段。
    //   （宿主 extraOptions 里也设了 yes，两处一致，避免矛盾。）
    this.native.setOptionString("interpolation", "yes");
    this.native.setOptionString("correct-downscaling", "no");
    this.native.setOptionString("sigmoid-upscaling", "no");
    this.native.setOptionString("dither-depth", "no");
    this.native.setOptionString("deinterlace", this.config.deinterlace ? "yes" : "no");
    this.native.setOptionString("demuxer-max-bytes", "1024MiB");
    this.native.setOptionString("demuxer-max-back-bytes", "512MiB");

    // Audio
    this.native.setOptionString("volume", "100");
    this.native.setOptionString("alang", this.config.alang);

    // Subtitle and OSD
    this.native.setOptionString("sub-scale-with-window", "no");
    this.native.setOptionString("sub-use-margins", "no");
    this.native.setOptionString("sub-auto", "fuzzy");
    this.native.setOptionString("sub-file-paths", "sub:subtitles");
    this.native.setOptionString("subs-fallback", "yes");
    this.native.setOptionString("slang", this.config.slang);
    this.native.setOptionString("osd-font", "HarmonyOS Sans");

    // Custom Subtitle
    this.native.setOptionString("sub-font-size", "38");
    this.native.setOptionString("sub-color", "#ffffffff");
    this.native.setOptionString("sub-outline-size", "2");
    this.native.setOptionString("sub-outline-color", "#ff000000");
    this.native.setOptionString("sub-bold", "yes");
    this.native.setOptionString("sub-italic", "no");
    this.native.setOptionString("sub-blur", "2");

    // 🔴 HeinPlay 扩展（2026-09-30）：宿主自定义 mpv 选项。
    //    必须放在**内置选项全部下发之后、native.initialize() 之前**，
    //    这样宿主才能覆盖上面的默认值（例如 cache-secs / demuxer-readahead-secs）。
    this.config.extraOptions.forEach((value: string, key: string) => {
      this.native.setOptionString(key, value);
    });

    // 🔴 HeinPlay 路线 B（2026-09-30）：在 initialize 之前把 Flutter 纹理的
    //    surfaceId 作为 wid 注入 mpv（mpv_set_option 只能在 initialize 前调用）。
    //    这是黑屏修复的核心接缝：flutter-ohos 纹理合成路径下 XComponent 不回调
    //    onSurfaceCreated，故不再依赖它，而是主动注入合法 surfaceId 让 vo=gpu-next
    //    的 openharmony GPU 上下文建出可渲染窗口。
    if (this.config.surfaceId != null && this.config.surfaceId.length > 0) {
      console.warn(`[mpv-surface] 构造注入 wid surfaceId=${this.config.surfaceId}`);
      this.native.attachSurface(this.config.surfaceId);
      this.surfaceAttached = true;
    }

    this.native.initialize();

    const properties: Map<string, MpvFormat> = new Map([
      ["time-pos/full", MpvFormat.MPV_FORMAT_DOUBLE],
      ["duration/full", MpvFormat.MPV_FORMAT_DOUBLE],
      ["playlist-playing-pos", MpvFormat.MPV_FORMAT_INT64],
      ["track-list", MpvFormat.MPV_FORMAT_NODE],
      ["chapter-list", MpvFormat.MPV_FORMAT_NODE],
      ["video-params", MpvFormat.MPV_FORMAT_NODE],
      ["audio-params", MpvFormat.MPV_FORMAT_NODE],
      ["video-bitrate", MpvFormat.MPV_FORMAT_DOUBLE],
      ["audio-bitrate", MpvFormat.MPV_FORMAT_DOUBLE],
      ["pause", MpvFormat.MPV_FORMAT_FLAG],
      ["paused-for-cache", MpvFormat.MPV_FORMAT_FLAG],
      ["volume", MpvFormat.MPV_FORMAT_DOUBLE],
      ["speed", MpvFormat.MPV_FORMAT_DOUBLE],
      ["media-title", MpvFormat.MPV_FORMAT_STRING],
      ["eof-reached", MpvFormat.MPV_FORMAT_FLAG],
      ["cache-buffering-state", MpvFormat.MPV_FORMAT_DOUBLE],
      ["demuxer-cache-time", MpvFormat.MPV_FORMAT_INT64],
    ]);

    properties.forEach((fmt: MpvFormat, prop: string) => {
      this.native.observeProperty(prop, fmt);
    });
  }

  /**
   * Opens a media or playlist.
   *
   * ```
   * player.open(new Media("file://media/Photo/1310/VID_1/VID_1.mp4"));
   * ```
   *
   * ```
   * player.open(new Playlist([
   *   new Media("file://media/Photo/1310/VID_1/VID_1.mp4"),
   *   new Media("https://www.example.com/sample1.mp4"),
   *   new Media("https://www.example.com/sample2.mp4")
   * ], 0));
   * ```
   *
   * @param files     Media item or playlist to open.
   * @param play      Whether to start playback immediately, optional.
   */
  open(files: Media | Playlist, play: boolean = true): void {
    const playlist = files instanceof Media ?
      new Playlist([files]) :
      files;

    if (playlist.medias.length == 0) {
      return;
    }

    this.state.playlist = playlist;
    // 🔴 2026-10-07：这里保留向 self playlist 流投递新片单（UI 用它渲染片单角标）。
    //   真正的播放列表清理由 native 层 loadfile 的 **replace** 语义完成
    //   （mpv 内核 cmd_loadfile 会原子地 playlist_clear → insert → set_entry，
    //   见下方注释与 main.cpp load_file），因此此处不需要、也不应再做 clear 补偿。

    // 🔴 2026-10-07 换源修复：**删除 stop / playlist-clear / playlist-play-index 三连。**
    //
    //   【历史】这三条曾是 `loadfile ... append` 的补偿：loadfile 追加到列表末尾
    //     且不切换播放，必须先把列表清空、把 current 置 none，追加的唯一条目
    //     才会被自动选中。但它们是经 native.command() 异步下发，与随后下发的
    //     loadFile 在同一命令队列里**竞争**——偶发把刚 loadfile 进来的条目又清掉，
    //     造成「换源后 mpv 零事件、画面停在旧会话、进度条恒 0」（真机 23:22:06），
    //     以及后来删除补偿后全平台不能播（真机 23:28:28 / 23:28:39，全 idle）。
    //
    //   【现在】根因已在 native 层修掉：`load_file` 的 flags 由 "append" 改为
    //     "replace"。mpv 内核的 cmd_loadfile 在收到底层这个命令时会原子地执行
    //       playlist_clear() → playlist_insert_at() → mp_set_playlist_entry()
    //     （见 mpv 源码 player/command.c: cmd_loadfile），一条命令替代原来四条，
    //     既不需要任何补偿，也不存在命令竞争。
    //     这与 AVP 后端「每次换源新建 player / 新建 media source、从不复用播放列表」
    //     的语义完全等价——正是应该对齐的做法。
     this.stream.playlist.add(playlist);

    // 🔴 HeinPlay 新增（2026-10-08）：`--start` 起播定位同样进「定位中」态。
    //
    //   【为什么】已核实 mpv 源码：`--start` 走的是与用户 seek **完全同一条路径**
    //     和同一精度 —— player/loadfile.c:2072-2080
    //         queue_seek(mpctx, MPSEEK_ABSOLUTE, play_start_pts, MPSEEK_DEFAULT, 0);
    //     因此 open 期间 `time-pos` 同样会先吐残留值（片头 0 或上一集进度）。
    //     真机证据（h11）：open start=856s 后 11ms 就报 position=0ms，
    //     导致续播闸门错判「首帧已出」。
    //
    //   【与 START_FILE 的分工】此处是「命令已下、文件尚未开始加载」的乐观置位，
    //     保证 loadfile 到 start-file 之间到达的残留 time-pos 也被守卫。
    //     mpv 随后发 START_FILE 时会**统一重置为 1**（见 onEvent），
    //     因此这里无论置多少都不会累积泄漏。
    this.inFlightSeekCount++;
    this.stream.seekingCount.add(this.inFlightSeekCount);
    this.armSeekWatchdog();

    playlist.medias.forEach((media: Media) => {
      const options = new Map<string, string>();
      if (media.httpHeaders && media.httpHeaders.size > 0) {
        const headers: string[] = [];
        media.httpHeaders.forEach((value: string, name: string) => {
          const header = `${name}: ${value}`;
          headers.push(`%${header.length}%${header}`);
        });
        options.set("http-header-fields", headers.join(","));
      }
      if (media.start !== undefined) {
        options.set("start", media.start.toString());
      }
      if (media.end !== undefined) {
        options.set("end", media.end.toString());
      }

      const url = Utils.sanitizeUri(media.uri);
      this.native.loadFile(url, options)
    });

    // 🔴 2026-10-07：`playlist-pos` 仅对**多条目片单**有意义，必须保留。
    //   单文件场景下 loadfile(replace) 已原子完成 clear+insert+set_entry 并选中新条目，
    //   无需再设；但剧集连播场景（一次性把多集塞进 Playlist）依赖这一句
    //   把播放位置定到 playlist.index 指定的那一集。原先无条件设置，
    //   在单文件时会于 loadfile 之后追加一条可能错位的异步命令，故加条件收窄。
    if (playlist.medias.length > 1 && playlist.index >= 0) {
      this.native.setProperty("playlist-pos", playlist.index);
    }

    // 🔴 2026-10-07：**`pause` 显式归位，且必须在 loadfile 之后立即下发。**
    //   原因与 loadfile 从 append 改为 replace 直接相关（见 main.cpp load_file）：
    //     · replace 的 load_action.play 恒为 **true**（mpv 源码 get_load_action case 0），
    //       即 loadfile 本身就会让新条目立即开始播放——这是我们要的默认行为；
    //     · 但上层 `open(media, play=false)` 的场景（预加载下一条、不立即出声）
    //       必须在新条目开始播放后把它按下暂停。原先该场景**完全不设 pause**，
    //       行为取决于上次残留状态（换源时通常停在 false，于是静音预加载直接出声）。
    //   顺序要求：必须在 native.loadFile() **之后**。若放在之前，
    //   异步队列可能是「pause=true → loadfile(replace, play=true)」，
    //   后者会把 pause 翻回 false，等于没设。
    this.native.setProperty("pause", play ? false : true);
  }

  /**
   * Stops playback.
   */
  stop(): void {
    this.native.command(["stop"]);
    this.native.command(["playlist-clear"]);
    this.native.command(["playlist-play-index", "none"]);

    const previous = this.state;
    const reset = new PlayerState();
    reset.volume = previous.volume;
    reset.speed = previous.speed;
    reset.playlistMode = previous.playlistMode;
    reset.buffering = false;
    this.state = reset;

    this.stream.playlist.add(reset.playlist);
    this.stream.playing.add(reset.playing);
    this.stream.eof.add(reset.eof);
    this.stream.duration.add(reset.duration);
    this.stream.position.add(reset.position);
    this.stream.buffering.add(reset.buffering);
    this.stream.bufferingPercentage.add(reset.bufferingPercentage);
    this.stream.buffer.add(reset.buffer);
    this.stream.track.add(reset.track);
    this.stream.tracks.add(reset.tracks);
    this.stream.chapters.add(reset.chapters);
    this.stream.videoParams.add(reset.videoParams);
    this.stream.videoBitrate.add(reset.videoBitrate);
    this.stream.audioParams.add(reset.audioParams);
    this.stream.audioBitrate.add(reset.audioBitrate);
  }

  /**
   * Destroys mpv player.
   */
  destroy(): void {
    // 必须先取消看门狗：否则定时器会在 `stream.destroy()` 之后触发，
    // 往一个已关闭的 Stream 里 add，轻则噪声日志重则异常。
    this.disarmSeekWatchdog();
    this.stop();
    this.native.removeEventObserver(this);
    this.native.removeLogObserver(this);
    this.native.removeEventCallbacks();
    this.native.removeLogCallback();
    this.native.destroy();
    this.stream.destroy();
  }

  /**
   * Starts or resumes playback.
   */
  play(): void {
    if (this.state.eof) {
      this.seek(0);
      this.native.setProperty("playlist-pos", 0);
    }
    this.native.setProperty("pause", false);
  }

  /**
   * Pauses playback.
   */
  pause(): void {
    this.native.setProperty("pause", true);
  }

  /**
   * Toggles between playing and paused states.
   */
  playOrPause(): void {
    this.native.command(["cycle", "pause"]);
  }

  /**
   * Seeks to an absolute playback position.
   *
   * 【2026-10-08 调查记录·结论：seek 模式无需修改】曾怀疑「往前跳」源于
   *   seek 模式未精确，尝试把 `absolute` 改为 `absolute+exact`。
   *   查阅 mpv 源码后**证伪并回退**：
   *    · DOCS/man/input.rst:321-323 —— "exact is used for absolute seeks"；
   *    · options/options.c:1050 —— `.hr_seek = 2`（默认 `--hr-seek=yes`）；
   *    · player/playloop.c:351-355 —— hr_seek 判定式中
   *      `(opts->hr_seek >= 0 && seek.type == MPSEEK_ABSOLUTE)` 已为真。
   *   即 `absolute` 默认就走精确 seek（从上一关键帧解码到目标帧），
   *   追加 `+exact` 不改变任何行为。
   *
   * 【真因·已锁定】不是 seek 定位不准，而是 **`time-pos` 在 seek 期间不可信**：
   *   它会先吐出上一次播放位置的**残留值**，再收敛到新落点。Dart 侧把这期间
   *   的采样当成真位置 → 下一页以它作基准 → 表现为「定位好了又往前跳一段」。
   *   真机证据（h11）：请求 857556ms，seek 后 8ms 就采到 931596ms（残留），
   *   偏差 +74040ms —— 正是用户感知的「往前跳 1 分钟」。
   *
   *   解法对标 AVP：AVP 在原生侧用 `if (this.isSeeking) return this.seekPosition;`
   *   屏蔽 seek 期间的原始时钟。此处通过 stream.seekingCount 暴露等价状态，
   *   由 MpvBridge 在 seek 期间改报「请求值」。
   *
   * @param seconds   Absolute playback position in seconds.
   */
  seek(seconds: number): void {
    // 🔴 HeinPlay 修订（2026-10-08）：seek 期间进入「定位中」态，语义同 AVP isSeeking。
    //   复位在 onEvent 的 MPV_EVENT_PLAYBACK_RESTART —— mpv 保证每次 seek 完成后
    //   必发该事件，等价于 AVP 的 SEEK_DONE。
    //
    //   【必须用计数而非布尔】`Stream.add()` 对相同值去重且**不通知监听者**，
    //   而 seek 可重入：连按快进时上一次 seek 未完成，`add(true)` 会被去重丢弃，
    //   导致该次定位期无守卫，残留 time-pos 污染 Dart `_position`。
    //   改用自增计数后每次 seek 都是新值，必然送达；PLAYBACK_RESTART 递减，
    //   归零才代表全部在途 seek 完成。
    this.inFlightSeekCount++;
    this.stream.seekingCount.add(this.inFlightSeekCount);
    this.armSeekWatchdog();
    this.native.command(["seek", seconds.toFixed(3), "absolute"]);
    this.state.eof = false;
    this.stream.eof.add(false);
  }

  /**
   * Advances to the next playlist item.
   */
  next(): void {
    this.play();
    this.native.command(["playlist-next"]);
  }

  /**
   * Returns to the previous playlist item.
   */
  previous(): void {
    this.play();
    this.native.command(["playlist-prev"]);
  }

  /**
   * Jumps to the the specified playlist item.
   *
   * @param index     Playlist item index.
   */
  jump(index: number): void {
    if (index < 0 || index >= this.state.playlist.medias.length) {
      return;
    }
    this.play();
    this.native.setProperty("playlist-pos", index);
  }

  /**
   * Sets the playback volume.
   *
   * @param volume    Playback volume.
   */
  setVolume(volume: number): void {
    this.native.setProperty("volume", volume);
  }

  /**
   * Sets the playback speed.
   *
   * @param speed     Playback speed.
   */
  setSpeed(speed: number): void {
    if (speed <= 0) {
      return;
    }
    this.native.setProperty("speed", speed);
  }

  /**
   * Selects the video track.
   *
   * @param track     Video track.
   */
  setVideoTrack(track: VideoTrack): void {
    this.native.setProperty("vid", track.id);
    this.state.track.video = track;
    this.stream.track.add(this.state.track);
  }

  disableVideoTrack(): void {
    this.setVideoTrack(VideoTrack.no());
  }

  loadExternalVideoTrack(url: string): void {
    this.native.command(["video-add", url]);
  }

  /**
   * Selects the audio track or loads an external audio track.
   *
   * ```
   * player.setAudioTrack(
   *   AudioTrack.uri(
   *     "https://www.iandevlin.com/html5test/webvtt/v/upc-tobymanley.mp4",
   *     "",
   *     "chi",
   *     "external"
   *   )
   * );
   * ```
   *
   * @param track     Audio track.
   */
  setAudioTrack(track: AudioTrack): void {
    if (track.isUri) {
      this.native.command([
        "audio-add",
        track.id,
        "select",
        track.title.length > 0 ? track.title : "external",
        track.lang.length > 0 ? track.lang : "auto"
      ]);
    } else {
      this.native.setProperty("aid", track.id);
    }
    this.state.track.audio = track;
    this.stream.track.add(this.state.track);
  }

  disableAudioTrack(): void {
    this.setAudioTrack(AudioTrack.no());
  }

  loadExternalAudioTrack(url: string, lang: string = "", title: string = ""): void {
    this.setAudioTrack(AudioTrack.uri(url, "", lang, title));
  }

  /**
   * Selects the subtitle track or loads an external subtitle track.
   *
   * ```
   * player.setSubtitleTrack(
   *   SubtitleTrack.uri(
   *     "https://www.iandevlin.com/html5test/webvtt/upc-video-subtitles-en.vtt",
   *     "",
   *     "chi",
   *     "external"
   *   )
   * );
   * ```
   *
   * @param track     Subtitle track.
   */
  setSubtitleTrack(track: SubtitleTrack): void {
    if (track.isUri) {
      this.native.command([
        "sub-add",
        track.id,
        "select",
        track.title.length > 0 ? track.title : "external",
        track.lang.length > 0 ? track.lang : "auto"
      ]);
    } else {
      this.native.setProperty("sid", track.id);
    }
    this.state.track.subs = track;
    this.stream.track.add(this.state.track);
  }

  disableSubtitleTrack(): void {
    this.setSubtitleTrack(SubtitleTrack.no());
  }

  loadExternalSubtitleTrack(url: string, lang: string = "", title: string = ""): void {
    this.setSubtitleTrack(SubtitleTrack.uri(url, "", lang, title));
  }

  /**
   * Sets the playlist playback mode.
   *
   * @param mode  Playlist playback mode.
   */
  setPlaylistMode(mode: PlaylistMode): void {
    switch (mode) {
      case PlaylistMode.None:
        this.native.command(["playlist-unshuffle"]);
        this.native.setProperty("loop-file", "no");
        this.native.setProperty("loop-playlist", "no");
        break;
      case PlaylistMode.File:
        this.native.command(["playlist-unshuffle"]);
        this.native.setProperty("loop-file", "inf");
        this.native.setProperty("loop-playlist", "no");
        break;
      case PlaylistMode.Playlist:
        this.native.command(["playlist-unshuffle"]);
        this.native.setProperty("loop-file", "no");
        this.native.setProperty("loop-playlist", "inf");
        break;
      case PlaylistMode.Random:
        this.native.setProperty("loop-file", "no");
        this.native.setProperty("loop-playlist", "no");
        this.native.command(["playlist-shuffle"]);
        break;
    }

    this.state.playlistMode = mode;
    this.stream.playlistMode.add(mode);
  }

  setLoopMode(mode: PlaylistMode): void {
    this.setPlaylistMode(mode);
  }

  /**
   * Captures the current video frame as a PixelMap.
   *
   * @param withSub   Whether to include subtitles.
   *
   * @return Captured video frame.
   */
  screenshot(withSub: boolean = true): PixelMap {
    const raw = this.native.commandWithReturn([
      "screenshot-raw",
      withSub ? "subtitles" : "video",
      "bgra"
    ]) as Map<string, MpvNode>;
    const imageOptions: image.InitializationOptions = {
      size: { width: raw["w"], height: raw["h"] },
    }
    return image.createPixelMapSync(raw["data"], imageOptions);
  }

  onSurfaceCreated(surfaceId: string): void {
    // 🔴 HeinPlay 诊断（2026-09-30）：这是判定黑屏根因的**决定性日志**。
    //    mpv 只能渲染到「原生窗口 surface」—— 由本回调把 surfaceId 通过
    //    mpv_set_option("wid", ...) 交给 mpv，vo=gpu-next 才能出画。
    //    若本回调**从未被调用**，说明 XComponent 在 flutter-ohos 的
    //    PlatformView(RENDER_TYPE_TEXTURE 合成) 路径下拿不到 surface，
    //    黑屏就是必然结果，且与 mpv 本身无关。
    console.warn(`[mpv-surface] onSurfaceCreated surfaceId=${surfaceId}`);
    this.native.attachSurface(surfaceId);
    console.warn(`[mpv-surface] attachSurface 已下发 wid=${surfaceId}`);
    this.config.onReady();
  }

  /**
   * 🔴 HeinPlay 路线 B（2026-09-30）：不依赖 XComponent 的 surface 生命周期回调，
   * 由桥接层主动注入 surfaceId。
   *
   * 背景：flutter-ohos 的 PlatformView 走 RENDER_TYPE_TEXTURE 合成时，节点内的
   * XComponent 不会回调 onSurfaceCreated（拿不到原生 surface），导致 mpv 的 wid 为空、
   * vo=gpu-next 报 "Missing surface pointer"、黑屏（有声无画）。
   *
   * 解法：直接注册 Flutter 纹理（registerTexture）拿到合法 surfaceId，主动喂给 mpv，
   * 其 openharmony GPU 上下文会据此 CreateNativeWindowFromSurfaceId 建出可渲染窗口。
   * 该 surfaceId 与 XComponent surfaceId 对 mpv 完全等价（同一 OH_NativeWindow 机制）。
   *
   * @param surfaceId Flutter 纹理的 surfaceId（字符串形式的数字）
   */
  attachToSurface(surfaceId: string): void {
    if (this.surfaceAttached) {
      console.warn(`[mpv-surface] attachToSurface 已绑定，忽略重复调用 surfaceId=${surfaceId}`);
      return;
    }
    console.warn(`[mpv-surface] attachToSurface surfaceId=${surfaceId}`);
    this.native.attachSurface(surfaceId);
    console.warn(`[mpv-surface] attachSurface 已下发 wid=${surfaceId}`);
    this.surfaceAttached = true;
    this.config.onReady();
  }

  private surfaceAttached: boolean = false;

  onSurfaceChanged(_: string, rect: SurfaceRect): void {
    console.warn(`[mpv-surface] onSurfaceChanged ${rect.surfaceWidth}x${rect.surfaceHeight}`);
    // 🔴 2026-10-06 改回 "ohos-surface-size"（ErBWs/mpv feat-ohos 分支的选项名）。
    //    该分支 options.c 里是 OPT_SIZE_BOX(ohos_surface_size)；
    //    官方 master 补丁版才是 "openharmony-surface-size"。换源码分支必须同步改。
    //    注：路线B（wid 由 Flutter 纹理 surfaceId 注入）下本回调**不会触发**
    //    （没有 XComponent），尺寸实际由 MpvBridge 在 initialize 前以
    //    extraOptions 形式下发。这里保留是为了兼容未来切回 XComponent 的方案。
    this.native.setProperty("ohos-surface-size", `${rect.surfaceWidth}x${rect.surfaceHeight}`);
  }

  onSurfaceDestroyed(_: string): void {
    console.warn(`[mpv-surface] onSurfaceDestroyed`);
    this.native.detachSurface();
  }

  onPropertyChanged(property: string, value?: string | number | boolean): void {
    switch (typeof value) {
      case "number":
        if (property == "time-pos/full") {
          this.state.position = parseFloat(value.toFixed(3));
          this.stream.position.add(this.state.position);
        } else if (property == "duration/full") {
          this.state.duration = parseFloat(value.toFixed(3));
          this.stream.duration.add(this.state.duration);
        } else if (property == "playlist-playing-pos") {
          this.state.playlist.index = value;
          this.stream.playlist.add(this.state.playlist);
        } else if (property == "volume") {
          this.state.volume = value;
          this.stream.volume.add(value);
        } else if (property == "speed") {
          this.state.speed = value;
          this.stream.speed.add(value);
        } else if (property == "cache-buffering-state") {
          this.state.bufferingPercentage = value;
          this.stream.bufferingPercentage.add(value);
        } else if (property == "demuxer-cache-time") {
          this.state.buffer = value;
          this.stream.buffer.add(value);
        } else if (property == "video-bitrate") {
          this.state.videoBitrate = value;
          this.stream.videoBitrate.add(value);
        } else if (property == "audio-bitrate") {
          this.state.audioBitrate = value;
          this.stream.audioBitrate.add(value);
        }
        break;
      case "string":
        if (property == "media-title") {
          this.state.title = value;
        } else if (property == "track-list") {
          this.loadTracks(value);
        } else if (property == "video-params") {
          this.loadVideoParams(value);
        } else if (property == "audio-params") {
          this.loadAudioParams(value);
        } else if (property == "chapter-list") {
          this.loadChapters(value);
        }
        break;
      case "boolean":
        if (property == "pause") {
          this.state.playing = !value;
          this.stream.playing.add(this.state.playing);
        } else if (property == "paused-for-cache") {
          this.state.buffering = value;
          this.stream.buffering.add(value);
        } else if (property == "eof-reached") {
          this.state.eof = value;
          this.stream.eof.add(value);
          if (value) {
            this.state.playing = false;
            this.state.buffering = false;
            this.state.track = new Track();
            this.state.tracks = new Tracks();
            this.stream.playing.add(false);
            this.stream.buffering.add(false);
            this.stream.track.add(this.state.track);
            this.stream.tracks.add(this.state.tracks);
          }
        }
        break;
      default:
        break;
    }
  }

  onEvent(id: number, name: string): void {
    if (id === MpvEvent.MPV_EVENT_START_FILE) {
      // 🔴 HeinPlay 新增（2026-10-08）：换文件时 mpv 会**丢弃所有在途 seek**
      //   （它们不会再发 playback-restart）。若不在此归零，计数会永久泄漏，
      //   守卫态卡在「定位中」，position 将被永久钉死在 seekTargetSec 上。
      //   故把「加载新文件」视为新的 seek 世代：归零后置 1 ——
      //   因为 open 的 `--start` 本身也是一次定位，同样需要守卫其残留 time-pos。
      //   （open() 里已有一次 ++，这里统一重置为 1，避免重复叠加。）
      this.inFlightSeekCount = 1;
      this.stream.seekingCount.add(this.inFlightSeekCount);
      this.state.playing = true;
      this.state.eof = false;
      this.state.buffering = true;
      this.stream.playing.add(true);
      this.stream.eof.add(false);
      this.stream.buffering.add(true);
    }
    // 🔴 HeinPlay 新增（2026-10-08）：seek 完成 → 退出「定位中」态。
    //
    //   为什么用 PLAYBACK_RESTART 而不是 MPV_EVENT_SEEK：
    //    · MPV_EVENT_SEEK 表示「seek 已开始」，语义是置位而非复位；
    //    · PLAYBACK_RESTART 表示「解码器已从新位置恢复输出」，即**画面已就位**，
    //      与 AVP 的 SEEK_DONE 语义一一对应（AVP 也是在该回调里 isSeeking=false）。
    //
    //   ⚠️ 边界：某些 seek（落点与当前极近）mpv 可能不发 playback-restart。
    //      但那种情况残留值本来就≈目标值，上报它也不会造成跳动；
    //      且 MpvBridge 侧另有 open/loadFile 兜底，不会永久卡在 seek 态。
    //
    //   【为何递减而非置 0】连按快进时会有多个 seek 在途，mpv 逐个完成并各发一次
    //     playback-restart。若一次到位全部清零，**未完成的 seek 就失去守卫**，
    //     其残留 time-pos 会污染 Dart `_position`。递减到 0 才是真正的空闲。
    //
    //   🔴🔴 2026-10-08 二次修正（h13 实测泄漏）：计数会**永久卡在非 0**。
    //     真机日志 `seek 守卫: 在途=` 序列末尾停在 5 再未归零，其根因是
    //     **mpv 对「落点与当前位置极近」的 seek 不会发 playback-restart**
    //     （--hr-seek-framedrop 下命中当前解码位置时直接跳过）。
    //     连按快进会批量产生这类「空 seek」，每次 ++ 却没有对应的递减，
    //     计数只增不减 → seekingCount 永久 >0。
    //
    //     后果比「守卫失效」更严重：MpvBridge 在 seeking 期间把 position
    //     钉死在 seekTargetSec，于是**进度条永久卡住不动**，且 Dart 侧后续
    //     所有以 _position 为基准的操作（跳过片头片尾判据、切源续播基准）
    //     全部读到这个钉死的值 → 这正是用户报的「在定位好的基础上再往前跳」。
    //
    //   【修法】PLAYBACK_RESTART 只递减；**另设兜底上限**：seek 提交时记下时间戳，
    //     若超过 3 秒仍无 playback-restart，说明 mpv 不会为这次 seek 发事件，
    //     直接把计数收敛到 0。3 秒取值依据：h13 实测正常 seek 的
    //     seek→playback-restart 间隔为 2.2s（20:08:16.569→18.788）与
    //     1.5s（20:08:22.167→23.691），留足余量。
    if (id === MpvEvent.MPV_EVENT_PLAYBACK_RESTART) {
      if (this.inFlightSeekCount > 0) {
        this.inFlightSeekCount--;
      }
      // 🔴 2026-10-08：收到真实 PLAYBACK_RESTART 说明本次 seek **正常收敛**，
      //   清除「超时收敛」标记。若不清，上一次超时留下的 true 会被下一次
      //   守卫退出误读（虽然 MpvBridge 读取后会复位，但正常路径也应显式清零，
      //   避免依赖消费方的时序）。
      if (this.inFlightSeekCount === 0) {
        this.seekConvergedByTimeout = false;
      }
      // 事件已到达，看门狗无需再兜底 —— 必须取消，否则它会在 3 秒后
      // 把一个**新的**在途 seek 计数误清零。
      if (this.inFlightSeekCount === 0) {
        this.disarmSeekWatchdog();
      }
      this.stream.seekingCount.add(this.inFlightSeekCount);
    }
    // 🔴 HeinPlay 修订（2026-09-30）：同上，上游用 BuildProfile.DEBUG 关掉了 release
    //    下的事件日志。事件流是判断 mpv 生命周期（file-loaded / video-reconfig /
    //    playback-restart）的关键证据，发布包必须能看到，故改为始终输出。
    console.warn(`[mpv-event] ${name}`);
  }

  onLogMessage(prefix: string, level: string, msg: string): void {
    const log = new PlayerLog(prefix, level, msg);
    // 🔴 HeinPlay 修订（2026-09-30）：上游把原生日志输出包在 `if (BuildProfile.DEBUG)` 里，
    //    而 release 构建的 BuildProfile.DEBUG=false —— 于是**发布包里 mpv 日志一条都没有**，
    //    排查黑屏/起播慢时完全瞎。更糟的是 hilog.debug 在部分设备上还会被默认等级过滤。
    //
    //    这里改为：**始终输出**，且走 console.warn —— 必须用 W 级而非 I 级，
    //    因为真机 hilog 抓取默认只保留 W/E（INFO 级被过滤，整份日志零条 I）。
    //    仅对 noisy 级别做长度截断，避免刷爆日志。
    //    前缀统一为 `[mpv]`，抓日志用 `hilog | grep '\[mpv\]'`。
    const noisy = level === "v" || level === "debug" || level === "trace";
    // 🔒 隐私：mpv 原生日志里可能出现媒体地址（可能是用户自建服务器地址），
    //    输出到 hilog 前统一脱敏，保留路径与参数、遮蔽主机名。
    const text = LogRedactor.redact(log.toString());
    const line = noisy
      ? `[mpv][${level}] ${text.substring(0, 400)}${text.length > 400 ? '...(截断)' : ''}`
      : `[mpv][${level}] ${text}`;
    if (noisy) {
      // noisy 级别默认不打印（可用 extraOptions 的 logLevel=v 主动打开）
    } else {
      console.warn(line);
    }
    this.stream.log.add(log);
    if (level == "error") {
      this.stream.error.add(msg);
    }
  }

  private loadTracks(json: string): void {
    const tracks = new Tracks();
    const selected = new Track();
    let raw = JSON.parse(json) as RawTrack[];

    raw.map((track) => {
      switch (track.type) {
        case "audio":
          const audio = new AudioTrack(track.id, track.codec, track.lang, track.title);
          tracks.audio.push(audio);
          if (track.selected) {
            selected.audio = audio;
          }
          break;
        case "video":
          const video = new VideoTrack(track.id, track.codec, track.lang, track.title);
          tracks.video.push(video);
          if (track.selected) {
            selected.video = video;
          }
          break;
        case "sub":
          const subtitle = new SubtitleTrack(track.id, track.codec, track.lang, track.title);
          tracks.subs.push(subtitle);
          if (track.selected) {
            selected.subs = subtitle;
          }
          break;
      }
    });
    this.state.tracks = tracks;
    this.state.track = selected;
    this.stream.tracks.add(tracks);
    this.stream.track.add(selected);
  }

  private loadChapters(json: string): void {
    this.state.chapters = JSON.parse(json) as Chapter[];
    this.stream.chapters.add(this.state.chapters);
  }

  private loadVideoParams(json: string): void {
    let raw = JSON.parse(json) as Map<string, Object>;
    const params = new VideoParams();
    params.pixelFormat = raw["pixelformat"] ?? "";
    params.hwPixelFormat = raw["hw-pixelformat"] ?? "";
    params.w = raw["w"] ?? 0;
    params.h = raw["h"] ?? 0;
    params.dw = raw["dw"] ?? 0;
    params.dh = raw["dh"] ?? 0;
    params.aspect = raw["aspect"] ?? 0;
    params.par = raw["par"] ?? 0;
    params.sar = raw["sar"] ?? 0;
    params.colormatrix = raw["colormatrix"] ?? "";
    params.colorLevels = raw["colorlevels"] ?? "";
    params.primaries = raw["primaries"] ?? "";
    params.gamma = raw["gamma"] ?? "";
    params.light = raw["light"] ?? "";
    params.chromaLocation = raw["chroma-location"] ?? "";
    params.rotate = raw["rotate"] ?? 0;
    params.stereoIn = raw["stereo-in"] ?? "";
    params.averageBpp = raw["average-bpp"] ?? 0;
    params.alpha = raw["alpha"] ?? "";
    this.state.videoParams = params;
    this.stream.videoParams.add(params);
  }

  private loadAudioParams(json: string): void {
    const raw = JSON.parse(json) as Map<string, Object>;
    const params = new AudioParams();
    params.format = raw["format"] ?? "";
    params.sampleRate = raw["samplerate"] ?? 0;
    params.channels = raw["channels"] ?? "";
    this.state.audioParams = params;
    this.stream.audioParams.add(params);
  }
}
