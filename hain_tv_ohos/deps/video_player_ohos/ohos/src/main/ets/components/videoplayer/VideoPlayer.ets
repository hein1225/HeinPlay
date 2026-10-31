// Copyright (c) 2025 Hunan OpenValley Digital Industry Development Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_ODID file.
// Based on VideoPlayer.java originally written by
// Copyright 2013 The Flutter Authors.

import media from '@ohos.multimedia.media';
import prompt from '@ohos.promptAction';
import resourceManager from '@ohos.resourceManager';
import window from '@ohos.window';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';
import { SurfaceTextureEntry } from '@ohos/flutter_ohos/src/main/ets/view/TextureRegistry';
import image from '@ohos.multimedia.image';
import { AvplayerStatus, CommonConstants, Events, SliderMode } from './constants/CommonConstants';
import { PlayConstants } from './constants/PlayConstants';

import { PlayerModel } from './PlayerModel';
import DateFormatUtil from './util/DateFormatUtil';
import { GlobalContext } from './util/GlobalContext';
import { VideoItem } from './VideoItem';
import { BusinessError } from '@ohos.base';
import { EventChannel } from '@ohos/flutter_ohos';
import { EventSink, StreamHandler } from '@ohos/flutter_ohos/src/main/ets/plugin/common/EventChannel';
import { QueuingEventSink } from './QueuingEventSink';
import { ArrayList, HashMap } from '@kit.ArkTS';
import { audio } from '@kit.AudioKit';
import fs from '@ohos.file.fs';
import deviceInfo from '@ohos.deviceInfo';

const FORMAT_SS: String = 'ss';
const FORMAT_DASH: String = 'dash';
const FORMAT_HLS: String = 'hls';
const FORMAT_OTHER: String = 'other';

const OPERATE_ERROR: number = 801;
const AVPLAYER_STATE_ERROR: number = 5400102;
const AVPLAYER_IO_ERROR: number = 5400103;
const BUFFER_INFO_POLL_INTERVAL: number = 500;
const PLAYBACK_INFO_MIN_SDK: number = 12;
const PLAYBACK_INFO_BUFFER_DURATION_KEY: string = 'buffer_duration';

const TAG = 'VideoPlayer'

/// 🔴 2026-09-28：诊断日志统一走 WARN 级别。
///
/// 【背景】引擎的 `Log.ets` 默认 `_logLevel = WARN`，且其 `isLoggable()` 判定为
/// `level >= _logLevel`，于是 `Log.i`（INFO=4）在 WARN=5 下被判否，**所有 INFO 日志
/// 被静默丢弃**。实测设备 hilog 中插件只出现 `Log.e` 的输出（如 "AvPlayer Avoid Error
/// Reporting"），而 21 处 `Log.i` 全部不可见 —— 起播定位、缓冲档位、起播耗时等
/// 关键诊断因此长期无法观测，排查只能靠猜。
///
/// 【为何不直接改引擎 Log.ets】oh_modules 会被 `ohpm install` 重新生成而丢失补丁
/// （历史上 PlatformChannel 补丁就这样丢过一次）。虽然 `scripts/patch_oh_modules.sh`
/// 已固化该修改，但把诊断级别收敛在**本插件内部**更稳妥：不依赖外部补丁是否生效，
/// 也避免「改了却不知道有没有编译进去」的盲区。
///
/// 【抓日志】hilog 中 tag 固定为 "Flutter"（Log.ets 内常量），业务 tag 在正文前缀：
///   `Flutter: VideoPlayer --> <消息>`
/// 因此须用 `hilog -x -T Flutter`，再按正文过滤 `VideoPlayer -->`。
function diag(msg: string): void {
  Log.w(TAG, msg);
}

interface AVPlayerWithPlaybackInfo {
  getPlaybackInfo(): Promise<Record<string, Object>>;
}
export class VideoPlayer {
  private avPlayer: media.AVPlayer | null = null;
  public playerModel: PlayerModel | null = null;
  private duration: number = 0;
  private status: number = -1;
  private loop: boolean = false;
  private index: number = 0;
  private rawFile?: resourceManager.RawFileDescriptor | null = {} as resourceManager.RawFileDescriptor;
  private url: string | null = null;
  private surfaceId: string = '';
  private seekTime: number = PlayConstants.PROGRESS_SEEK_TIME;
  private positionX: number = PlayConstants.POSITION_X;
  private positionY: number = PlayConstants.POSITION_Y;
  private textureEntry: SurfaceTextureEntry;
  private eventChannel: EventChannel | null = null;
  private eventSink: QueuingEventSink | null = null;
  private interruptMode: audio.InterruptMode = audio.InterruptMode.INDEPENDENT_MODE;
  private fd: number | null = null;
  private headers: Record<string, string> | null;
  private playTime: number = 0;
  private bufferTimeTemp: number = 0;

  /// 🔴 2026-09-28 新增：缓冲条显示区间起点（毫秒）。
  ///
  /// 【为什么需要】AVPlayer 续播定位后，播放列表实际是从记录点开始拉的，
  /// 片头那一段根本没有数据。但官方上报的区间起点恒为 0（见
  /// sendBufferingUpdate），于是进度条把「0 → 峰值」整段画成已缓冲 ——
  /// 用户看到的缓冲条是「从片头就开始缓冲」，与实际拉流起点不符。
  ///
  /// 【取值规则】
  ///   · 有续播记录（startPositionMs > 0）→ 起点 = startPositionMs，固定不变；
  ///   · 无续播记录 → 起点 = 0，行为与官方完全一致。
  ///
  /// 【为什么不随 playTime 前进】起点必须**固定**在记录点：
  /// 一旦让它跟着 playTime 走，区间每秒被拖着往前滑，每 500ms 重画一次，
  /// 视觉上就是「闪烁」+「几乎没有缓冲条」（这是我 2026-09-28 改错的地方）。
  /// 固定起点 + 单调递增终点 = 缓冲条平滑增长，且长度正常。
  ///
  /// ⚠️ 本字段**只影响显示**，不参与任何定位逻辑。起播定位仍由
  /// startPositionMs → pendingSeekPosition → PREPARED seek 链路负责，
  /// 两者互不干扰（勿在此处写入任何 seek 相关副作用）。
  private bufferedStartMs: number = 0;

  /// 🔴 2026-10-26（HeinPlay 本地 fork，第十八轮）：「缓冲时长上报异常」是否已提示过。
  ///
  /// 【为什么需要】缓冲窗口钳制每 500ms 轮询一次，若每次都打日志会刷屏
  ///   （第十七轮刚因日志刷屏返工）。这里只在「首次异常」与「恢复正常」时各打一条。
  private bufferAnomalyReported: boolean = false;

  /// 🔴 2026-09-28 新增：起播耗时四段计时（HeinPlay 本地 fork）。
  ///
  /// 【为什么要分段】真机日志只有一句笼统的「initialize 完成，耗时 2572ms」，
  /// 无法判断慢在哪一段（网络建连 / prepare / 解码 / 首帧送显），任何优化都只能盲猜。
  /// 官方与社区一致建议按下表四段测量：
  ///
  ///   | 阶段       | 起点           | 终点             |
  ///   |------------|----------------|------------------|
  ///   | 资源初始化 | setMediaSource | initialized      |
  ///   | 准备       | prepare()      | prepared         |
  ///   | 播放启动   | play()         | playing          |
  ///   | 首帧链路   | setMediaSource | startRenderFrame |
  ///
  /// 其中 `startRenderFrame` 是**比 prepared 更贴近用户感受**的首帧指标（官方语义：
  /// 播放服务开始向显示模块发送第一帧）。插件原只监听 stateChange/timeUpdate/
  /// seekDone/bufferingUpdate/error，**未监听该事件**，故此前拿不到真实首帧耗时。
  ///
  /// 各字段为 `Date.now()` 毫秒时间戳，0 表示该阶段尚未发生。
  private tMediaSource: number = 0;
  private tInitialized: number = 0;
  private tPrepared: number = 0;
  private tFirstFrame: number = 0;
  private tPlayCalled: number = 0;
  private isSeeking: boolean = false;
  private isPrepared: boolean = false;
  private pendingPlay: boolean = false;
  private pendingSeekPosition: number | null = null;
  private seekPosition: number = 0;

  /// 🔴 2026-10-24（第十六轮）：本次会话是否已上报过「seek 期间的致命 5400103」。
  ///
  /// 【为什么需要】往回 seek 时 AVPlayer 的 demuxer 无法回退（TS 已被消费释放）
  ///   ⇒ 报 5400103（DEM_PARSE_ERR）并进入不可恢复的 error 态。
  ///   该错误必须**只报一次**（Dart 侧据此重建播放器）：
  ///   重复上报会导致 Dart 反复重建 ⇒ 重建风暴。
  private fatalSeekErrorReported: boolean = false;

  /// 🔴 2026-09-28 新增（HeinPlay 本地 fork）：create 阶段带下来的起播位置（毫秒）。
  ///
  /// 用途：让「续播定位」在 prepare 阶段即生效，避免 AVPlayer 先按播放列表第 0 片
  /// 拉流、之后才 seek 所造成的「从片头缓冲」。0 表示不指定（从 0 起播）。
  ///
  /// 与 [pendingSeekPosition] 的区别：后者是运行期 seekTo 在 prepare 完成前到达时的
  /// 暂存；本字段在 create 时即确定，早于 setMediaSource 被消费。
  private startPositionMs: number = 0;

  /// 🔴 2026-09-28 新增（HeinPlay 本地 fork）：点播缓冲档位（毫秒）。
  ///
  /// [bufferDurationMs]             起播前缓冲时长 → 下发给 preferredBufferDuration
  /// [bufferDurationForPlayingMs]   播放中缓冲水位 → 下发给 preferredBufferDurationForPlaying
  ///
  /// 两个字段都必须在 setMediaSource 时随 PlaybackStrategy 给出（原生无运行期 setter），
  /// 故从 create 阶段一路带下来。0 表示不下发，沿用系统默认。
  private bufferDurationMs: number = 0;
  private bufferDurationForPlayingMs: number = 0;

  /// 🔴 2026-09-28 新增：起播定位尚未完成时挂起 sendInitialized。
  ///
  /// 【为什么要挂起】`avPlayer.seek()` 是**异步**的，调用后立刻 sendInitialized()
  /// 会让 Flutter 在 seek 真正生效前就开始渲染 —— 画出的是**片头首帧**，随后才
  /// 跳到播放记录处，用户看到「每次起播闪一下开头」。
  ///
  /// 【日志证据】真机 hilog（2026-09-28 17:51:23，后端=avplayer）：
  ///   [FVP-DIAG] seek target=1209000ms before=0ms after=1209000ms
  /// `before=0ms` 说明 seek 发起那一刻播放位置仍是 0（片头）。
  ///
  /// 【为什么 fvp 没有此问题】fvp 走 libmdk 独立路径（prepare 时直接带续播点开流），
  /// 不经过 AVPlayer 插件，故天然不会闪开头 —— 这正是「fvp 不闪、avp 闪」的根因。
  private pendingInitialized: boolean = false;

  /// 🔴 2026-10-24（HeinPlay 本地 fork）：起播定位 seek 的**目标位置**。
  ///
  /// 【为什么要新字段，而不是复用 pendingSeekPosition】
  ///   原实现在 PREPARED（**尚未播放**）状态里直接 `avPlayer.seek()`。
  ///   真机（设备 9CN0223912004329，2026-10-24 20:01:44）证明这条路径不可靠：
  ///   · 换源场景下，代理已把目标段预取进缓存 ⇒ AVPlayer 拿到列表后
  ///     **瞬间**开始拉第 0 段建索引（代理日志「Prefetch: 跳过（该分片正由
  ///     播放器直连下载）」可证）；
  ///   · 此刻我们又并发下发 seek(1576029ms) ⇒ **AVPlayer 的 HLS 管线
  ///     （拉流建索引）与 seek 撞车** ⇒ 媒体服务内部错误：
  ///         unKnown state: error
  ///         AvPlayer Avoid Error Reporting: {"code":5400103}   ← IO 错误
  ///     随后 playbackInfo 查询连环 5400102，播放被判失败。
  ///   而同一次会话里**没有** seek 的场景（详情页直接进入，position=0）
  ///   完全正常 ⇒ 坐实「未播放态 seek」是触发条件。
  ///
  /// 【改法】seek 改到 **PLAYING 态**执行：鸿蒙文档规定 seek 是播放态操作，
  ///   PLAYING 态 seek 不会与管线初始化冲突。
  ///   为此 PREPARED 分支只**记录**目标并先 play()，等状态切到 PLAYING
  ///   再真正下发 seek（见 PLAYING 分支）。
  ///
  /// 【为什么不等首帧再 seek】
  ///   AVPlayer 在 PREPARED 后会自己拉第 0 段建索引；若等首帧才 seek，
  ///   等于先完整播一遍片头再跳走，起播更慢。故在 PLAYING 态**立即** seek。
  private startSeekTarget: number = -1;

  /// 🔴 2026-10-24：起播定位 SEEK_DONE 的时间戳。
  ///
  /// 用途：判定「当前这一帧是不是 **seek 之后**送显的首帧」。
  /// `startRenderFrame` 可能在 seek 之前就已触发（片头首帧），
  /// 那种帧不能用来证明「seek 后的画面已就绪」。
  private tSeekDoneAt: number = 0;

  /// 🔴 2026-10-24：已 SEEK_DONE、正在等待「seek 后首帧送显」才 sendInitialized。
  ///
  /// 【为什么要等首帧才 sendInitialized】
  ///   Flutter 侧收到 initialized 后就会创建 external texture 并开始取帧。
  ///   若此时 AVPlayer 还没往 surface 送帧，Flutter 引擎
  ///   `ohos_external_texture.cpp` 会持续报：
  ///     OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null
  ///   （真机 hilog 2026-10-24 20:00:58.963 起刷屏 2637 次）
  ///   ⇒ 画面永久冻结在 seek 前那一帧，而进度条照常前进 ——
  ///   这正是用户报的「卡住开头画面，但进度条显示的是播放记录的定位」。
  private awaitingFirstFrameForInit: boolean = false;

  /// 🔴 2026-10-24：等待「seek 后首帧」的兜底定时器句柄。
  /// 某些源/设备可能不触发 startRenderFrame ⇒ 兜底后强制 sendInitialized。
  private initFallbackTimer: number = -1;

  /// 🔴 2026-10-24：起播定位 seek 的兜底定时器句柄（2s 内未进 PLAYING 则强制 seek）。
  private startSeekFallbackTimer: number = -1;

  /// 🔴 2026-10-24（HeinPlay 本地 fork，第十四轮）：**seek 完成兜底**定时器句柄。
  ///
  /// 【为什么必须有】`isSeeking` 只能靠 `seekDone` 事件复位，而
  ///   `getPosition()` 在 `isSeeking` 为真时**直接返回 seekPosition 常量**
  ///   ⇒ 一旦 seekDone 不来，position / buffered 就被永久冻结 ⇒ 表现为「卡死」。
  ///
  /// 【真机实证】hilog 2026-10-24 21:36:43（hailog-…-13-37-35.txt）
  ///   快退后 position 恒为 0ms、buffered 恒为 [0,4354]，代理侧**零分片请求**；
  ///   21:37:03 的快进 seek 也被吞掉，position 恒为 89000ms ⇒ 两次都卡死。
  ///
  /// 【为什么 seekDone 不来】见 seekTo() 里的 SEEK_CLOSEST 说明 ——
  ///   裁剪后列表第 0 片之前**没有段**，SEEK_CLOSEST 需要的「前一段」不存在，
  ///   AVPlayer 的 seek 永远完不成 ⇒ 不派发 seekDone。
  ///
  /// 【兜底策略】2.5s 内没等到 seekDone ⇒ 强制复位 isSeeking，
  ///   让 getPosition() 回到读取真实 currentTime（宁可位置回跳，也不能永久冻结）。
  private seekWatchdogTimer: number = -1;

  private isBuffering: boolean = false;
  private isSystemBuffering: boolean = false;
  private isSeekBuffering: boolean = false;
  private bufferingInfoTimer: number = -1;
  private isPollingPlaybackInfo: boolean = false;
 	private isWindowKeepScreenOn: boolean = false;
  private cachedRotationCorrection: number = 0;

  constructor(playerModel: PlayerModel, textureEntry: SurfaceTextureEntry, rawFile: resourceManager.RawFileDescriptor | null, url: string | null, eventChannel: EventChannel, AudioFocus: Boolean, headers: Record<string, string> | null, startPositionMs: number = 0, bufferDurationMs: number = 0, bufferDurationForPlayingMs: number = 0) {
    this.playerModel = playerModel;
    this.textureEntry = textureEntry;
    this.surfaceId = textureEntry.getSurfaceId().toString();
    this.rawFile = rawFile;
    this.url = url;
    this.eventChannel = eventChannel;
    this.headers = headers;
    this.startPositionMs = startPositionMs > 0 ? startPositionMs : 0;
    // 缓冲条显示起点 = 续播记录点（无记录则为 0，与官方一致）。
    // 仅影响 sendBufferingUpdate 上报的区间起点，不参与定位（见字段注释）。
    this.bufferedStartMs = this.startPositionMs;
    // 缓冲档位（0 视为未指定，沿用系统默认行为）
    this.bufferDurationMs = bufferDurationMs > 0 ? bufferDurationMs : 0;
    this.bufferDurationForPlayingMs = bufferDurationForPlayingMs > 0 ? bufferDurationForPlayingMs : 0;
    // 复用既有的 pendingSeekPosition 通道：该字段在 PREPARED 状态处理器里会被消费
    // （见 bindState 的 AvplayerStatus.PREPARED 分支）。此时 isPrepared 仍为 false，
    // 且早于任何用户 seek，语义与「起播定位」完全一致。
    if (this.startPositionMs > 0) {
      this.pendingSeekPosition = this.startPositionMs;
      diag("续播起播定位已预置: " + this.startPositionMs + "ms");
    }
 	  try {
 	    this.isWindowKeepScreenOn = (GlobalContext.getContext().getObject('windowClass') as window.Window).getWindowProperties().isKeepScreenOn;
 	  } catch (e) {
 	    Log.e(TAG, 'getWindowProperties failed: ' + JSON.stringify(e));
 	  }
    if (AudioFocus == true) {
      this.interruptMode = audio.InterruptMode.SHARE_MODE;
      diag("set interruptMode : " + this.interruptMode);
    }
    diag("surfaceId : " + this.surfaceId);
  }

  /**
   * Creates a videoPlayer object.
   */
  async createAVPlayer() {
    diag(" createAVPlayer (textureId=" + this.textureEntry.getTextureId() + ")");
    if (this.avPlayer == null) {
      this.avPlayer = await media.createAVPlayer();
    }
    if (this.avPlayer != null) {
      this.eventSink = new QueuingEventSink();
      diag("enter setStreamHandler");
      this.eventChannel?.setStreamHandler(
        new StreamHandlerImpl(this.eventSink)
      );

      await this.bindState();

      /// 同时使用avPlayer.url和avPlayer.setMediaSource会导致直播视频无法正确播放
      if (!(this.url && this.url.startsWith('http'))) {
        if (this.url) {
          this.avPlayer.url = this.getIUri();
        } else {
          this.avPlayer.fdSrc = this.rawFile!;
        }
      } else {
        let mediaSource: media.MediaSource = media.createMediaSourceWithUrl(this.url, this.headers);
        /// 网络直播视频必须设置之后才能正常缓存
        ///
        /// 🔴 2026-09-28（HeinPlay 本地 fork）：把「点播缓冲档位」真正下发到 AVPlayer。
        ///
        /// 【原状】宿主侧 AvPlayerBackend 一直在算档位（min/max），但注释写着
        /// 「仅记录，AVPlayer 不支持运行时下发」，实际从未生效 —— 用户设置的
        /// 点播缓冲级别对 AVPlayer 完全无效，四个档位都跑默认行为。
        ///
        /// 【为什么现在能下发】鸿蒙 media.PlaybackStrategy 提供了两个缓冲字段：
        ///   · preferredBufferDuration          —— 官方："used to set the buffer size"
        ///                                         即**缓冲大小**（预读水位）
        ///   · preferredBufferDurationForPlaying —— 官方："Customize the buffering
        ///     threshold for start or restart playing"
        ///     即 **起播 / 重缓冲的判定阈值**，不是预读水位！
        /// 它们必须在 setMediaSource 时随 PlaybackStrategy 一起给出，
        /// **没有运行期 setter**，所以只能在 create/setMediaSource 这个时机下发。
        /// 这也是「插件 fork」的意义所在：宿主无法在 Dart 侧触达这两个字段。
        ///
        /// 🔴 2026-09-28 第二次修正：**上一版把两个字段的语义搞反了**。
        /// 上一版把宿主的 fvpMinMs（起播阈值，1500ms）当成「播放中缓冲水位」填进了
        /// preferredBufferDurationForPlaying，等于告诉系统「缓冲满 1.5 秒就算够」，
        /// 系统自然**从不预读更多**。真机日志实证（hilog 2026-09-28 15:52:46，
        /// AVPlayer + 增强档 max=20000）：
        ///   buffered=4920ms → 连续十余次轮询纹丝不动 → 最后才涨到 19417ms
        /// 与「增强档应预读 20 秒」严重不符，即用户报的「选了增强仍然缓冲太少」。
        ///
        /// 【正确映射】两个字段都应由**预读水位**驱动，阈值取该档位的 min：
        ///   · preferredBufferDuration          = ceil(max / 1000)  ← 预读水位（秒）
        ///   · preferredBufferDurationForPlaying = ceil(min / 1000)  ← 重缓冲阈值（秒）
        /// 二者比例与 ExoPlayer 档位一致（exo 的 BufferForPlayback / BufferForRebuffer
        /// 同样是「阈值」而 exoMaxBufferMs 是「预读量」），语义上终于对齐。
        ///
        /// 【单位】原生要「秒」，宿主侧传来的是「毫秒」，此处换算并向上取整，
        /// 避免 1500ms 截断成 1 秒导致档位偏差过大。
        let playbackStrategy: media.PlaybackStrategy | undefined = undefined;
        if (deviceInfo.sdkApiVersion >= 17) {
          playbackStrategy = { showFirstFrameOnPrepare: true } as media.PlaybackStrategy;
        }
        if (playbackStrategy !== undefined && this.bufferDurationMs > 0) {
          // 缓冲大小：官方单位为**秒**，且「缓冲区大小 = preferredBufferDuration × 1MB」。
          //
          // 🟢 2026-09-29 二次更正（推翻 2026-09-28 的「回归 20MB」结论）：
          // 上一版把 120MB 起播慢 10~14s 归因为「容量本身不能大」，并据此
          // 把档位钳回 5~20MB。**真因是当时把起播水位
          // (preferredBufferDurationForPlaying) 也一并放大了**——容量与水位未解耦。
          //
          // 华为官方「在线视频播放卡顿优化」实践（2026-09-14 原文）明确：
          //   *"缓冲区越大，能够缓存的视频数据量就越多，在遇到弱网环境或高码率
          //    视频源时可正常播放的时间也越久，进而减少或推迟卡顿。"*
          // 官方 5~20MB 表格是**推荐区间（内存考量），非 API 上限**（d.ts 无
          // @throws / value range，已核实）。故现在按 Dart 侧档位放开到
          //   低延迟 5 / 标准 30 / 增强 60 / 强力 120 MB。
          //
          // 关键解耦：起播速度由 preferredBufferDurationForPlaying（起播水位，仍 1~2s）
          // 保证，与容量无关。容量只决定「网络断流后能撑多久」，放大它**不会**拖慢
          // prepared 阶段（上次的慢是水位被放大导致的，与容量无关）。
          // 这里钳到 120MB 是**防呆双保险**，防止 Dart 侧配置写错时下发越界值。
          const rawBufferSec: number = Math.ceil(this.bufferDurationMs / 1000);
          // 🔴 2026-10-31（第二十五轮）：下限 5 → 2。
          //   直播档需要 3MB（起播后「卡一下」的时长 ≈ 容量/到达速率），
          //   5 的下限会把它顶回 5MB。
          playbackStrategy.preferredBufferDuration = Math.min(120, Math.max(2, rawBufferSec));
          diag("下发缓冲档位 preferredBufferDuration=" + playbackStrategy.preferredBufferDuration
            + "MB (源 " + this.bufferDurationMs + "ms → " + rawBufferSec + "s)");
        }
        if (playbackStrategy !== undefined) {
          // 起播/重缓冲阈值：低于它在起播或重缓时继续等待。
          // 官方语义为"起播或重启播放的缓冲阈值"，不是水位；
          // 取该档位配置的 min（与 exo 的 exoBufferForPlaybackMs 对应），向上取整秒。
          //
          // 🔴🔴🔴 2026-10-31（第二十四轮）：条件由 `> 0` 改为**恒下发**。
          //
          // 【为什么要改】原条件 `bufferDurationForPlayingMs > 0` 意味着直播档
          //   （水位置 0）时**整个字段不进入 PlaybackStrategy** ⇒ AVPlayer 退回
          //   **系统默认的动态起播水位线**。华为官方《在线视频播放卡顿优化》
          //   给出的默认算法是：
          //     · 下载速率 ≥ 码率 → 起播水位线 = 0.3 秒 × 码率
          //     · 下载速率 < 码率 → 起播水位线 = 5 秒 × 码率
          //   本地 iptv 组播源（裸 TS，8.72Mbps）下载速率 ≈ 码率，统计窗口抖动
          //   就落进第二分支 ⇒ 水位线 = 5.45MB；而直播档缓冲只有 5MB ⇒
          //   水位线永远达不到，AVPlayer 只能等缓冲区写满才起播
          //   ⇒ 实测 4.6 秒（与真机日志里 3~4 秒 buffering 吻合）。
          //
          // 【改成恒下发的好处】门槛固定、可预期，不再随下载速率测量在
          //   0.3s / 5s 两分支间跳变；且直播档现已改为 1000ms ⇒ 实际下发 1 秒。
          //   单位是秒（整数），钳到 ≥1 秒。
          playbackStrategy.preferredBufferDurationForPlaying =
            Math.max(1, Math.ceil(this.bufferDurationForPlayingMs / 1000));
          diag("下发缓冲档位 preferredBufferDurationForPlaying="
            + playbackStrategy.preferredBufferDurationForPlaying + "s (重缓冲阈值, 源 "
            + this.bufferDurationForPlayingMs + "ms)");
        }
        // 设置媒体来源和播放策略
        this.markMediaSourceSet();
        await this.avPlayer.setMediaSource(mediaSource, playbackStrategy);
      }
    }
  }

  /**
   * AVPlayer binding event.
   */
  async bindState() {
    diag("enter bindState");
    if (this.avPlayer == null) {
      Log.e(TAG, "bindState, avPlayer is null");
      return;
    }
    this.avPlayer.on(Events.STATE_CHANGE, async (state: media.AVPlayerState) => {
      let avplayerStatus: string = state;
      diag("bindState, on avPlayer, step1");
      if (this.avPlayer == null) {
        Log.e(TAG, "bindState, avPlayer is null, step2");
        return;
      }
      diag("bindState, on STATE_CHANGE, avplayerStatus=" + avplayerStatus);
      // 🔴 2026-09-28 修复编译错误「Cannot find name 'event'」。
      // 官方原版在本 switch 前声明了 event（见 flutter_packages 上游 155 行附近），
      // 我此前改造 prepare() 分支时把它连带删除，导致 PLAYING/PAUSED 分支里
      // 恢复官方 isPlayingStateUpdate 事件后找不到该变量（HarCompileArkTS 失败）。
      // 注意：官方原版此声明用的是 `let event`（带类型注解），
      // 且**每个 case 复用同一个对象**——故各 case 内不再重复声明。
      let event: HashMap<string, Object> = new HashMap<string, Object>();
      switch (avplayerStatus) {
        case AvplayerStatus.IDLE:
          this.isPrepared = false;
          this.pendingPlay = false;
          this.pendingSeekPosition = null;
          // 🔴 重新预置「起播定位」：IDLE 会无条件清空 pendingSeekPosition，
          // 而 create 阶段预置的值正是在此时被清掉的（IDLE 早于 INITIALIZED/PREPARED）。
          // 故在 IDLE 分支末尾按 startPositionMs 恢复，确保 PREPARED 时能消费到。
          if (this.startPositionMs > 0) {
            this.pendingSeekPosition = this.startPositionMs;
            diag("IDLE 后恢复起播定位: " + this.startPositionMs + "ms");
          }
          this.resetProgress();
          // Extract rotation before setting data source to avoid fd conflict with AVPlayer
          try {
            this.cachedRotationCorrection = await this.getRotationCorrection();
            diag('cachedRotationCorrection=' + this.cachedRotationCorrection);
          } catch (e) {
            Log.w(TAG, 'getRotationCorrection failed: ' + JSON.stringify(e));
          }
          if (this.url && this.url.startsWith('http')) {
            let mediaSource = media.createMediaSourceWithUrl(this.url, this.headers);
            let playbackStrategy: media.PlaybackStrategy | undefined = undefined;
            if (deviceInfo.sdkApiVersion >= 17) {
              playbackStrategy = { showFirstFrameOnPrepare: true } as media.PlaybackStrategy;
            }
            // 🔴 2026-09-28 修复（缓冲档位在 IDLE 被丢弃）：
            //
            // IDLE 是**每次起播都必经**的状态（setMediaSource → IDLE → INITIALIZED
            // → PREPARED），而这里原先只放了 showFirstFrameOnPrepare，
            // **把 create 阶段带下来的缓冲档位整个丢掉**，等于用户选的缓冲模式
            // （标准/增强/省电）对 AVPlayer 从未真正生效 —— 一直跑的是系统默认
            // 缓冲策略。这正是"选了增强档缓冲条还是很短"的直接原因之一。
            //
            // 此处补齐与 setMediaSource 主路径**完全一致**的两项下发：
            // 缓冲大小（preferredBufferDuration，官方单位=秒，1 秒=1MB，钳制 5~120MB）
            // 与重缓冲阈值（preferredBufferDurationForPlaying，秒，至少 1）。
            if (playbackStrategy !== undefined && this.bufferDurationMs > 0) {
              const rawBufferSec: number = Math.ceil(this.bufferDurationMs / 1000);
              // 与主路径完全一致：容量钳制 5~120MB（5~20 是官方推荐区间、非上限，
              // 2026-09-29 起按档位放开到 30/60/120MB 以加强弱网预缓冲）。
              // 🔴 2026-10-31（第二十五轮）：下限 5 → 2。
          //   直播档需要 3MB（起播后「卡一下」的时长 ≈ 容量/到达速率），
          //   5 的下限会把它顶回 5MB。
          playbackStrategy.preferredBufferDuration = Math.min(120, Math.max(2, rawBufferSec));
              diag("IDLE 重新 setMediaSource 补下缓冲档位 preferredBufferDuration="
                + playbackStrategy.preferredBufferDuration + "MB (源 " + this.bufferDurationMs + "ms)");
            }
            if (playbackStrategy !== undefined) {
              // 与主路径完全一致：起播水位**恒下发**（原为 `> 0`，直播档 0 时
              // 不下发 ⇒ 退回 AVPlayer 动态默认水位线 ⇒ 直播起播卡 3~4 秒）。
              // 详见主路径 2026-10-31（第二十四轮）注释。
              playbackStrategy.preferredBufferDurationForPlaying =
                Math.max(1, Math.ceil(this.bufferDurationForPlayingMs / 1000));
              diag("IDLE 重新 setMediaSource 补下缓冲档位 preferredBufferDurationForPlaying="
                + playbackStrategy.preferredBufferDurationForPlaying + "s (源 "
                + this.bufferDurationForPlayingMs + "ms)");
            }
            this.markMediaSourceSet();
            await this.avPlayer.setMediaSource(mediaSource, playbackStrategy);
          } else if (this.url) {
            this.avPlayer.url = this.getIUri();
          } else {
            this.avPlayer.fdSrc = this.rawFile!;
          }
          break;
        case AvplayerStatus.INITIALIZED:
          this.isPrepared = false;
          // 起播计时：资源初始化完成（setMediaSource → initialized）。
          this.tInitialized = Date.now();
          this.avPlayer.surfaceId = this.surfaceId;
          this.avPlayer.prepare();
          break;
        case AvplayerStatus.PREPARED:
          this.isPrepared = true;
          // 起播计时：prepare() 完成（initialized → prepared）。
          this.tPrepared = Date.now();
          this.avPlayer.videoScaleType = 0;
          this.avPlayer.audioInterruptMode = this.interruptMode;
          this.setVideoSize();
          this.duration = this.avPlayer.duration;
          // 🔴 起播定位必须排在 sendInitialized() **之前**（2026-09-28 修正）。
          //
          // 【原顺序的 bug】此前是先 sendInitialized() 再 seek，导致：
          //   Flutter 收到 initialized → 立刻开始渲染 → 画出**片头首帧**
          //     → 随后 seek 生效 → 画面才跳到播放记录处
          // 用户看到的就是「每次起播都会闪一下开头才定位到播放记录」。
          //
          // 【日志证据】真机 hilog（2026-09-28 13:28:48）：
          //   initialize 完成，耗时 2572ms，首帧就绪
          //   [FVP-DIAG] seek target=667000ms before=0ms after=667000ms
          // `before=0ms` 说明 initialize 返回那一刻播放位置仍是 0（片头），
          // seek 是之后才补上的。
          //
          // 【为什么提前到 PREPARED 里就能解决】PREPARED 表示解码器已就绪、
          // 尚未开始出帧。此刻 seek 相当于「带着目标位置进入首次播放」，
          // AVPlayer 会在首次出帧时就落在目标位置，不经过片头。
          // 同时 duration 已在上方取到，seek 的时长校验也可正常通过。
          if (this.pendingSeekPosition !== null) {
            // 🔴 2026-10-24（HeinPlay 本地 fork）：起播定位 seek 改到 **PLAYING 态**执行。
            //
            // 【原实现的问题】此前在 PREPARED（**尚未播放**）态直接 avPlayer.seek()。
            //   鸿蒙 AVPlayer 在 PREPARED 后会为 HLS 源拉第 0 段建索引；而换源场景
            //   下代理已把分片预取进缓存 ⇒ 这一拉流**瞬间完成** ⇒ 拉流与 seek
            //   撞车 ⇒ 媒体服务内部错误 5400103（IO error）⇒ 播放被判失败。
            //   真机证据（设备 9CN0223912004329，2026-10-24 20:01:44）：
            //     20:01:44.113 位置跳变（当前下标=762）        ← seek 已生效
            //     20:01:44.149 unKnown state: error
            //     20:01:44.150 AvPlayer Avoid Error Reporting: {"code":5400103}
            //   同一会话中「无 seek」的场景（详情页直接进入，position=0）完全正常
            //   ⇒ 坐实「未播放态 seek」是触发条件。
            //
            // 【新流程】PREPARED 只**记录**目标 → 先 play() 进入 PLAYING
            //   → PLAYING 分支立即下发 seek（合法播放态操作）→ SEEK_DONE
            //   → 等「seek 后首帧送显」→ 才 sendInitialized（Flutter 建 texture
            //     时 surface 必须已有帧，否则 40601000 断帧刷屏、画面永久冻结）。
            //
            // 【为什么不等首帧再 seek】AVPlayer 在 PREPARED 后本来就要拉第 0 段；
            //   若等首帧才 seek，等于先完整播一遍片头再跳走，起播更慢。
            this.pendingInitialized = true;
            this.startSeekTarget = this.pendingSeekPosition;
            diag("PREPARED 起播定位: " + this.startSeekTarget
              + "ms（挂起 sendInitialized；seek 改到 PLAYING 态执行）");
            this.pendingSeekPosition = null;
            // 定时器必须照常启动（它负责上报 buffered，与 sendInitialized 无关）。
            this.startBufferingInfoTimer();
            // 必须先进入 PLAYING，seek 才有合法状态。
            if (this.pendingPlay) {
              this.pendingPlay = false;
              this.avPlayer.play();
            }
            // 兜底：若 2s 内仍未切到 PLAYING（例如宿主未调 play），
            // 则退回在当前态下发 seek —— 宁可冒险，也不能让续播定位彻底失效。
            this.armStartSeekFallback();
            break;
          }
          this.sendInitialized();
          this.startBufferingInfoTimer();
          if (this.pendingPlay) {
            this.pendingPlay = false;
            this.avPlayer.play();
          }
          break;
        case AvplayerStatus.PLAYING:
          this.status = CommonConstants.STATUS_START;
          // 起播计时：进入播放态（play() → playing）。
          this.tPlayCalled = Date.now();
          // 🔴 2026-10-24（HeinPlay 本地 fork）：**PLAYING 态**下发起播定位 seek。
          //
          // 【为什么必须等到 PLAYING】鸿蒙 AVPlayer 的 seek 是播放态操作。
          //   在 PREPARED（未播放）态 seek 会与「为 HLS 源拉第 0 段建索引」并发，
          //   两者撞车 ⇒ 媒体服务内部错误 5400103（IO error）⇒ 播放失败。
          //   真机证据：2026-10-24 20:01:44 换源 avp 必失败（详见 PREPARED 分支注释）。
          //
          // 【为什么立即 seek 而不等首帧】等首帧意味着先播一遍片头，起播更慢。
          if (this.startSeekTarget >= 0) {
            const target: number = this.startSeekTarget;
            this.startSeekTarget = -1;
            this.clearStartSeekFallback();
            // 🔴🔴 2026-10-24（HeinPlay 本地 fork）：起播定位改用 **SEEK_NEXT_SYNC**。
            //
            // 【为什么不用 SEEK_CLOSEST —— 容器内 ffmpeg 实测（2026-10-24）】
            //   · SEEK_CLOSEST 需要在目标点**前后都解码**才能定位 ⇒ 必须额外拉
            //     目标段之前/之后的若干段，网络慢时这段开销被放大。
            //   · SEEK_NEXT_SYNC 直接跳到目标**之后**的关键帧 ⇒ 只需拉目标段。
            //   本片源每段 2s、GOP=2s ⇒ 落点偏差 0~2s（用户无感），
            //   而起播耗时少 1~3 秒 —— 这正是「avp 起播比 mpv 慢」的主要差距。
            //   ⚠️ 运行期用户手动拖动仍用 SEEK_CLOSEST / SEEK_PREV_SYNC（精度优先），
            //     只有「起播定位」用 NEXT_SYNC。
            this.avPlayer?.seek(target, media.SeekMode.SEEK_NEXT_SYNC);
            diag("PLAYING 起播定位 seek: " + target + "ms（播放态，SEEK_NEXT_SYNC）");
          }
          // 🟢 2026-09-28 恢复官方事件（此前被误删，导致 Dart 侧播放状态不同步）。
          // Dart 侧 deps/video_player_ohos/lib/src/ohos_video_player.dart:192 的
          // `case 'isPlayingStateUpdate':` 依赖本事件；缺失会使
          // VideoPlayerController.value.isPlaying 无法更新 —— 表现为
          // UI 播放状态错乱、部分控制逻辑失灵、以及观感上的「一卡一卡」。
          event.set("event", "isPlayingStateUpdate");
          event.set("isPlaying", true);
          this.eventSink?.success(event);
          this.watchStatus();
          break;
        case AvplayerStatus.PAUSED:
          this.status = CommonConstants.STATUS_PAUSE;
          // 🟢 同上，恢复官方事件。
          event.set("event", "isPlayingStateUpdate");
          event.set("isPlaying", false);
          this.eventSink?.success(event);
          this.watchStatus();
          break;
        case AvplayerStatus.COMPLETED:
          if (this.playerModel != null) {
            this.playerModel.playSpeed = PlayConstants.PLAY_SPEED;
          }
          this.sendCompleted();
          this.duration = PlayConstants.PLAYER_DURATION;
          if (!this.loop) {
            let curIndex = this.index + PlayConstants.PLAYER_NEXT;
            let globalVideoList = GlobalContext.getContext().getObject('globalVideoList') as VideoItem[];
            this.index = (curIndex === globalVideoList.length) ? PlayConstants.PLAYER_FIRST : curIndex;
            if (this.url) {
              this.url = globalVideoList[this.index].iSrc;
            } else {
              this.rawFile = globalVideoList[this.index].src;
            }
          }
          break;
        case AvplayerStatus.RELEASED:
          this.isPrepared = false;
          this.pendingPlay = false;
          this.pendingSeekPosition = null;
          this.status = CommonConstants.STATUS_STOP;
          this.watchStatus();
          diag('[PlayVideoModel] state released called')
          break;
        default:
          diag('[PlayVideoModel] unKnown state: ' + state);
          break;
      }
    });

    this.avPlayer.on(Events.TIME_UPDATE, (time: number) => {
      if (this.isSeeking) {
        this.playTime = time;
        // 🔴 2026-10-24（第十四轮）：**seekDone 兜底之二**。
        //   某些鸿蒙版本/某些源不派发 seekDone，但播放位置其实已经到位。
        //   此时若继续把 isSeeking 置真，getPosition() 会永远返回 seekPosition
        //   ⇒ 进度条冻结（真机实证：hilog 2026-10-24 21:36:43 起 position
        //   恒为 0ms / 89000ms，缓冲区间也一起冻住）。
        //   判据：播放位置已落在 seek 目标附近（±1.5s）⇒ 认定 seek 已完成。
        //
        // 🔴🔴🔴 2026-10-24（第十五轮）：**这是假兜底，必须改**。
        //   真机 hilog 2026-10-24 21:50:14.516（13-50-45.txt）：
        //     seek 兜底(timeUpdate): 位置已到位 time=0ms target=0ms → 复位 isSeeking
        //   但此时 AVPlayer 已经在 21:50:14.504 进入 **error 态**（5400103），
        //   真实播放位置根本没到 0。
        //   【为什么恒成立】`getPosition()` 在 isSeeking 时**直接返回 seekPosition 常量**，
        //   所以用 getPosition() 判「是否到位」= 用「我自己设定的目标」证「我到了」
        //   ⇒ 必然成立 ⇒ 兜底把「真的卡死」伪装成「已到位」，反而掩盖了故障。
        //   【修法】改读 **真实** currentTime（avPlayer.currentTime）。
        const real: number = this.avPlayer !== null
          ? this.avPlayer.currentTime
          : -1;
        if (real >= 0 && Math.abs(real - this.seekPosition) < 1500) {
          this.isSeeking = false;
          this.endSeekBuffering();
          this.clearSeekWatchdog();
          diag("seek 兜底(timeUpdate): 位置已到位 real=" + Math.round(real) +
            "ms target=" + this.seekPosition + "ms → 复位 isSeeking");
        }
        return;
      }
      this.initProgress(time);
      this.playTime = time;
    });

    // 🔴 2026-09-28 新增：首帧送显事件（官方语义：播放服务开始向显示模块发送第一帧）。
    //
    // 这是**最贴近用户「看到画面」感受**的起播终点，比 prepared/playing 都准。
    // 插件此前未监听该事件，导致起播耗时只能看到一个笼统的「initialize 完成」，
    // 无法判断慢在网络建连、prepare、解码还是送显。
    //
    // ⚠️ 用官方事件名字符串注册（不走自定义 Events 枚举）——枚举里没有该项，
    // 且 SDK 的 on('startRenderFrame', cb) 重载自 API 12 起可用。
    this.avPlayer.on('startRenderFrame', () => {
      this.tFirstFrame = Date.now();
      this.logStartupTiming('首帧送显');
      // 🔴 2026-10-24（HeinPlay 本地 fork）：**seek 之后**的首帧送显 → 此刻才 sendInitialized。
      //
      // 【为什么必须等这一帧】Flutter 收到 initialized 就会创建 external texture
      //   并开始取帧；若此时 surface 尚无帧，Flutter 引擎
      //   ohos_external_texture.cpp 会持续报
      //     OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null
      //   （真机 hilog 2026-10-24 20:00:58.963 起刷屏 2637 次）
      //   ⇒ 画面永久冻结在 seek 前那一帧，而进度条照常前进 ——
      //   这正是用户报的「卡住开头画面，但进度条显示的是播放记录的定位」。
      if (this.awaitingFirstFrameForInit) {
        this.awaitingFirstFrameForInit = false;
        this.clearInitFallback();
        diag("起播定位后首帧送显 → sendInitialized");
        this.sendInitialized();
      }
    });

    this.avPlayer.on(Events.SEEK_DONE, (time: number) => {
      // 🔴 2026-10-24（第十四轮）：**所有** seek 都要留痕。
      //   此前只有「起播定位」分支才打日志 ⇒ 普通用户快退/快进的 seekDone
      //   是否到达在真机日志里**完全不可见**，导致排查时无法区分
      //   「seek 没完成」与「seekDone 没派发」。
      diag("seekDone: time=" + time + "ms wasSeeking=" + this.isSeeking);
      this.clearSeekWatchdog();
      if (this.isSeeking) {
        this.isSeeking = false;
        this.endSeekBuffering();
      }
      // 起播定位完成 → 此刻才告知 Flutter「已初始化」，确保首帧就是续播点画面，
      // 不会先画出片头首帧（见 pendingInitialized 字段说明）。
      if (this.pendingInitialized) {
        this.pendingInitialized = false;
        this.tSeekDoneAt = Date.now();
        diag("起播定位完成(SEEK_DONE) time=" + time + "ms");
        // 等「seek 之后的首帧送显」再 sendInitialized（理由见 startRenderFrame 注释）。
        if (this.tFirstFrame >= this.tSeekDoneAt) {
          this.sendInitialized();
        } else {
          this.awaitingFirstFrameForInit = true;
          this.armInitFallback();
        }
        if (this.pendingPlay) {
          this.pendingPlay = false;
          // 回调为异步执行，此处 avPlayer 可能已被 reset() 置空，须显式判空
          if (this.avPlayer !== null) {
            this.avPlayer.play();
          }
        }
      }
    });

    this.avPlayer.on(Events.BUFFER_UPDATE, (infoType: media.BufferingInfoType, value: number) => {
      this.sendBufferingUpdate(infoType, value);
    });

    this.avPlayer.on(Events.ERROR, (err: BusinessError) => {
      // 播放直播视频时，设置 loop 会报错，而 loop 一定会设置(video_player.dart 中初始化之后会 _applyLooping)，所以屏蔽掉该报错
      // message: Unsupport Capability: The stream is live stream, not support loop
      /// 规避部分错误导致的reset，如：5400102 当前状态机不支持此操作；5400103 出现IO错误
      if(err.code == OPERATE_ERROR || err.code == AVPLAYER_STATE_ERROR || err.code == AVPLAYER_IO_ERROR) {
        // 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，第十五轮）：**屏蔽分支也必须留痕**。
        //
        // 【真机实证】hilog 2026-10-24 21:50:14（13-50-45.txt）：
        //   21:50:14.504 bindState, on STATE_CHANGE, avplayerStatus=error
        //   21:50:14.506 AvPlayer Avoid Error Reporting: {"code":5400103,"name":"BusinessError"}
        //   21:50:14.569 reportBufferedPositionFromPlaybackInfo error:{"code":5400102}
        //   …（5400102 每 500ms 一次，直到 21:50:31.957 released 才结束）
        // ⇒ 播放器在 seek 后**进入 error 态且不可恢复**（直到 release），
        //   而这个分支直接 `return` ⇒ 既不 reset、也不 sendError
        //   ⇒ Flutter 侧**零感知** ⇒ 表现为「快进快退后永久卡死」。
        //
        // 【为什么当初要屏蔽】避免良性错误（直播 loop 不支持、瞬时 IO 抖动）
        //   触发 reset 把正在播的会话打断。
        // 【本轮改法】保留「不 reset」的行为（不打断正常播放），
        //   但**必须把错误完整打出来**（含 message / stack），
        //   否则故障根因在真机日志里完全不可见 —— 这正是上两轮排查受阻的直接原因。
        //   另外打标 `seekInFlight`，让 Dart 侧能识别「seek 期间出的错」。
        Log.e(TAG, "AvPlayer Avoid Error Reporting: " + JSON.stringify(err));
        let curTime: number = -1;
        if (this.avPlayer !== null) {
          curTime = Math.round(this.avPlayer.currentTime);
        }
        // 🔴🔴🔴 2026-10-24（第十六轮）：**seek 期间的 5400103 必须上报给 Dart**。
        //
        // 【真机实证】hilog 2026-10-24 22:13:24（14-13-49.txt）：
        //   22:13:24.827 seekTo: target=0ms mode=SEEK_NEXT_SYNC current=4471ms
        //   22:13:24.965 avPlayer ERROR(屏蔽分支): code=5400103
        //                message=IO Error: DEM_PARSE_ERR-unkown error,
        //                media data source error unknow, video/avc-
        //                isSeeking=true seekPosition=0ms currentTime=-1ms
        //   ⇒ **往回 seek**（4471ms → 0ms）时，AVPlayer 的 demuxer 无法回退
        //     （TS 分片已被消费并释放）⇒ DEM_PARSE_ERR ⇒ 进入 error 态。
        //   ⇒ 且此时 **currentTime 变成 -1**、播放器不可恢复。
        //
        // 【为什么必须上报】AVPlayer 不会自己重新拉流（真机：seek 后代理侧
        //   **零分片请求**）⇒ 只能靠 Dart 侧「重建播放器到目标位置」来恢复。
        //   之前这个分支直接 return ⇒ Dart 零感知 ⇒ 界面永久冻住。
        //
        // 【上报条件收紧】只报 5400103（IO/DEM_PARSE，致命且不可恢复）且
        //   **正在 seek** ⇒ 避开「直播 loop 不支持」等良性错误。
        //   5400102（状态机错误）是 5400103 的后果，每 500ms 刷一次 ⇒ 不报。
        //   仍然**不 reset**（reset 会把状态机搅得更乱，且会打断正常播放）。
        if (err.code === 5400103 && this.isSeeking && !this.fatalSeekErrorReported) {
          this.fatalSeekErrorReported = true;
          diag("avPlayer 致命 seek 错误(5400103) ⇒ 上报 Dart，"
            + "由 Dart 重建播放器到用户目标位置");
          this.sendError(err);
          return;
        }
        diag("avPlayer ERROR(屏蔽分支): code=" + err.code +
          " message=" + err.message +
          " isSeeking=" + this.isSeeking +
          " seekPosition=" + this.seekPosition + "ms" +
          " currentTime=" + curTime + "ms");
        return;
      }
      Log.e(TAG, "avPlayer Events.ERROR: " + JSON.stringify(err));
      diag("avPlayer ERROR: code=" + err.code + " message=" + err.message);
      this.resetBufferingState();
      this.avPlayer?.reset();
      this.sendError(err);
    })
  }

  /**
 * 设置音频焦点模式
 * 
 * @param mixWithOthers 是否与其他音频混合播放
 *                      true: 共享模式，与其他音频混合
 *                      false: 独占模式，暂停其他音频
 */
setAudioFocus(mixWithOthers: boolean): void {
  if (this.avPlayer == null) {
    Log.w(TAG, "setAudioFocus: avPlayer is null, cannot set audio focus");
    return;
  }
  
  // 根据 mixWithOthers 参数设置中断模式
  this.interruptMode = mixWithOthers ? 
    audio.InterruptMode.SHARE_MODE : 
    audio.InterruptMode.INDEPENDENT_MODE;
  
  // 更新播放器的音频中断模式
  this.avPlayer.audioInterruptMode = this.interruptMode;
  
  diag(`setAudioFocus: mixWithOthers=${mixWithOthers}, interruptMode=${this.interruptMode}`);
}

  /**
   * Release the video player.
   */
  release() {
    this.stopBufferingInfoTimer();
    this.resetBufferingState();
    // 🔴 2026-10-24：释放兜底定时器，避免 release 后回调触发已销毁的 avPlayer。
    this.clearStartSeekFallback();
    this.clearInitFallback();
    this.startSeekTarget = -1;
    this.awaitingFirstFrameForInit = false;
    if (this.avPlayer !== null) {
      this.avPlayer.release();
      this.eventChannel?.setStreamHandler(null);
    }
    if (this.fd != null) {
      fs.closeSync(this.fd!);
    }
  }


  play() {
    if (this.avPlayer !== null) {
      if (!this.isPrepared) {
        this.pendingPlay = true;
        return;
      }
      this.avPlayer.play();
    }
  }

  /**
   * Pause Playing.
   */
  pause() {
    if (this.avPlayer !== null) {
      if (!this.isPrepared) {
        this.pendingPlay = false;
        return;
      }
      this.avPlayer.pause();
    }
  }

  seekTo(position: number) {
    if (this.avPlayer !== null) {
      if (!this.isPrepared) {
        this.pendingSeekPosition = position;
        return;
      }
      // 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，第十六轮）：**改用 SEEK_CLOSEST**。
      //
      // 【第十五轮（SEEK_NEXT_SYNC）的实测结论】
      //   hilog 2026-10-24 22:13:24（14-13-49.txt）：
      //     22:13:24.827 seekTo: target=0ms mode=SEEK_NEXT_SYNC current=4471ms
      //     22:13:24.965 code=5400103 message=IO Error: DEM_PARSE_ERR ...
      //                isSeeking=true seekPosition=0ms currentTime=-1ms
      //   ⇒ **往回 seek**（4471→0）时 AVPlayer 的 demuxer 无法回退
      //     （TS 分片已被消费并释放）⇒ DEM_PARSE_ERR ⇒ 进入不可恢复的 error 态。
      //   ⇒ 且 seek 后代理侧**零分片请求** ⇒ AVPlayer 不会自己重新拉流
      //     ⇒ 只能靠 Dart 侧「重建播放器到目标位置」恢复（第十六轮兜底）。
      //
      // 【为什么改回 SEEK_CLOSEST】
      //   · SEEK_NEXT_SYNC = seek 到「**严格晚于**目标」的下一个同步点
      //     ⇒ 误差 0~一段长（2~5 秒）。长按快进会**累积**这个误差
      //       （连点 5 次 +10s 实际可能 +60s）⇒ 体验明显偏差。
      //   · SEEK_CLOSEST = seek 到「**最接近**目标的同步点」⇒ 落在目标所在段，
      //     误差最小，且该段数据最新（刚播过、还在缓冲区）⇒ 成功概率更高。
      //   · 前提是**索引完整**（每个分片 URL 前有对应 #EXTINF）——
      //     第十五轮已修复代理裁剪丢 #EXTINF 的缺陷（真机日志已证实：
      //     裁剪后列表第 0 片 = `#EXTINF:1.84,` + URL ✓）⇒ 索引已完整。
      //
      // 【落点之前怎么办】SEEK_CLOSEST 需要「目标之前有段」，
      //   而裁剪列表的第 0 片 = 落点片 ⇒ 落点之前**架构性不可达**。
      //   ⇒ 该场景在 Dart 侧直接走「重建播放器到目标」路径，不做 seek。
      const mode: media.SeekMode = media.SeekMode.SEEK_CLOSEST;
      diag("seekTo: target=" + position + "ms mode=SEEK_CLOSEST" +
        " current=" + Math.round(this.avPlayer.currentTime) + "ms");
      this.prepareSeek(position);
      this.avPlayer.seek(position, mode);
    }
  }

  /// 🔴 2026-10-24（第十四轮）：启动 seek 完成兜底定时器（2.5s）。
  /// 没有它，seekDone 不来时 isSeeking 永为 true ⇒ position 永久冻结。
  private armSeekWatchdog(): void {
    this.clearSeekWatchdog();
    this.seekWatchdogTimer = setTimeout(() => {
      this.seekWatchdogTimer = -1;
      if (this.isSeeking) {
        this.isSeeking = false;
        this.endSeekBuffering();
        diag("⚠️ seek 兜底：2.5s 未收到 seekDone → 强制复位 isSeeking" +
          "（seekPosition=" + this.seekPosition + "ms）");
      }
    }, 2500);
  }

  /// 🔴 2026-10-24（第十四轮）：清除 seek 兜底定时器。
  private clearSeekWatchdog(): void {
    if (this.seekWatchdogTimer !== -1) {
      clearTimeout(this.seekWatchdogTimer);
      this.seekWatchdogTimer = -1;
    }
  }

  private prepareSeek(position: number): void {
    this.startSeekBuffering();
    this.isSeeking = true;
    this.seekPosition = position;
    this.armSeekWatchdog();
    // 缓冲条起点同步到 seek 目标点：此后缓冲从该点重新开始，与 fvp/exo 行为一致。
    //
    // 【为什么必须同步】若起点仍停在续播记录点（比如 944s），而用户快退到 800s，
    // 上报区间会是 [944s, 峰值] —— 播放位置 800s 落在区间**之外**，
    // 进度条上缓冲条根本不覆盖当前播放点，明显错误。
    //
    // 【与「闪烁」的区别】这里是 seek 触发的**离散**更新（一次），
    // 而之前改坏的是起点跟随 playTime 的**连续**更新（每 500ms 一次）。
    // 离散更新不会闪烁，且配合下面 bufferTimeTemp 归零，
    // 表现为「条先收缩到 seek 点，再平滑增长」—— 即「从快退点重新缓冲」。
    this.bufferedStartMs = position;
    // 峰值归零，让终点从 seek 点重新增长（单调递增，不来回跳）。
    this.bufferTimeTemp = 0;
  }

  getPosition(): number {
    if (this.isSeeking) {
      return this.seekPosition;
    }
    if (this.avPlayer !== null) {
      return Math.max(0, this.avPlayer.currentTime);
    } else {
      return 0;
    }
  }

  /**
   * Playback mode. The options are as follows: true: playing a single video; false: playing a cyclic video.
   */
  setLoop() {
    this.loop = !this.loop;
  }

  setLooping(isLooping: boolean) {
    if (this.avPlayer != null) {
      this.avPlayer.loop = isLooping;
    }
    this.loop = isLooping;
  }


  setVolume(volume: number) {
    if (this.avPlayer != null) {
      const clampedVolume = Math.max(0.0, Math.min(1.0, volume));
      this.avPlayer.setVolume(clampedVolume);
    }
  }

  /**
   * Set the playback speed.
   *
   * @param playSpeed Current playback speed.
   */
  setSpeed(playSpeed: number) {
    if (this.avPlayer == null || this.playerModel == null) {
      return;
    }
    if (CommonConstants.OPERATE_STATE.indexOf(this.avPlayer.state) === -1) {
      return;
    }
    this.playerModel.playSpeed = playSpeed;
    this.avPlayer.setSpeed(this.playerModel.playSpeed);
  }

  /**
   * Previous video.
   */
  previousVideo() {
    if (this.avPlayer == null || this.playerModel == null || this.playerModel == null) {
      return;
    }
    if (CommonConstants.OPERATE_STATE.indexOf(this.avPlayer.state) === -1) {
      return;
    }
    this.playerModel.playSpeed = PlayConstants.PLAY_SPEED;
    let globalVideoList = GlobalContext.getContext().getObject('globalVideoList') as VideoItem[];
    let curIndex = this.index - PlayConstants.CONTROL_NEXT;
    this.index = (curIndex === -PlayConstants.CONTROL_NEXT) ?
      (globalVideoList.length - PlayConstants.CONTROL_NEXT) : curIndex;
    if (this.url) {
      this.url = globalVideoList[this.index].iSrc;
    } else {
      this.rawFile = globalVideoList[this.index].src;
    }
    this.avPlayer.reset();
  }

  /**
   * Next video.
   */
  nextVideo() {
    if (this.avPlayer == null || this.playerModel == null) {
      return;
    }
    if (CommonConstants.OPERATE_STATE.indexOf(this.avPlayer.state) === -1) {
      return;
    }
    this.playerModel.playSpeed = PlayConstants.PLAY_SPEED;
    let globalVideoList = GlobalContext.getContext().getObject('globalVideoList') as VideoItem[];
    let curIndex = this.index + PlayConstants.CONTROL_NEXT;
    this.index = (curIndex === globalVideoList.length) ?
    PlayConstants.CONTROL_FIRST : curIndex;
    if (this.url) {
      this.url = globalVideoList[this.index].iSrc;
    } else {
      this.rawFile = globalVideoList[this.index].src;
    }
    this.avPlayer.reset();
  }

  /**
   * Switching Between Video Play and Pause.
   */
  switchPlayOrPause() {
    if (this.avPlayer == null || this.playerModel == null) {
      return;
    }
    if (this.status === CommonConstants.STATUS_START) {
      this.avPlayer.pause();
    } else {
      this.avPlayer.play();
    }
  }

  /**
   * Slide the progress bar to set the playback progress.
   *
   * @param value Value of the slider component.
   * @param mode Slider component change event.
   */
  setSeekTime(value: number, mode: SliderChangeMode) {
    if (this.avPlayer == null || this.playerModel == null) {
      return;
    }
    if (mode === Number(SliderMode.MOVING)) {
      this.playerModel.progressVal = value;
      this.playerModel.currentTime = DateFormatUtil.secondToTime(Math.floor(value * this.duration /
      CommonConstants.ONE_HUNDRED / CommonConstants.A_THOUSAND));
    }
    if (mode === Number(SliderMode.END) || mode === Number(SliderMode.CLICK)) {
      this.seekTime = value * this.duration / CommonConstants.ONE_HUNDRED;
      if (this.avPlayer !== null) {
        this.prepareSeek(this.seekTime);
        this.avPlayer.seek(this.seekTime, media.SeekMode.SEEK_PREV_SYNC);
      }
    }
  }

  /**
   * Setting the brightness.
   */
  setBright() {
    if (this.playerModel == null) {
      return;
    }
    let windowClass = GlobalContext.getContext().getObject('windowClass') as window.Window;
    windowClass.setWindowBrightness(this.playerModel.bright);
  }

  /**
   * Obtains the current video playing status.
   */
  getStatus() {
    return this.status;
  }

  /**
   * Initialization progress bar.
   *
   * @param time Current video playback time.
   */
  initProgress(time: number) {
    if (this.playerModel == null) {
      return;
    }
    let nowSeconds = Math.floor(time / CommonConstants.A_THOUSAND);
    let totalSeconds = Math.floor(this.duration / CommonConstants.A_THOUSAND);
    this.playerModel.currentTime = DateFormatUtil.secondToTime(nowSeconds);
    this.playerModel.totalTime = DateFormatUtil.secondToTime(totalSeconds);
    this.playerModel.progressVal = Math.floor(nowSeconds * CommonConstants.ONE_HUNDRED / totalSeconds);
  }

  /**
   * Reset progress bar data.
   */
  resetProgress() {
    if (this.playerModel == null) {
      return;
    }
    this.seekTime = PlayConstants.PROGRESS_SEEK_TIME;
    this.playerModel.currentTime = PlayConstants.PROGRESS_CURRENT_TIME;
    this.playerModel.progressVal = PlayConstants.PROGRESS_PROGRESS_VAL;
  }

  /**
   * Volume gesture method onActionStart.
   *
   * @param event Gesture event.
   */
  onVolumeActionStart(event?: GestureEvent) {
    if (!event) {
      return;
    }
    this.positionX = event.offsetX;
  }

  /**
   * Bright gesture method onActionStart.
   *
   * @param event Gesture event.
   */
  onBrightActionStart(event?: GestureEvent) {
    if (!event) {
      return;
    }
    this.positionY = event.offsetY;
  }

  /**
   * Gesture method onActionUpdate.
   *
   * @param event Gesture event.
   */
  onVolumeActionUpdate(event?: GestureEvent) {
    if (!event) {
      return;
    }
    if (this.avPlayer == null || this.playerModel == null) {
      return;
    }
    if (CommonConstants.OPERATE_STATE.indexOf(this.avPlayer.state) === -1) {
      return;
    }
    if (this.playerModel.brightShow === false) {
      this.playerModel.volumeShow = true;
      let screenWidth = GlobalContext.getContext().getObject('screenWidth') as number;
      let changeVolume = (event.offsetX - this.positionX) / screenWidth;
      let volume: number = this.playerModel.volume;
      let currentVolume = volume + changeVolume;
      let volumeMinFlag = currentVolume <= PlayConstants.MIN_VALUE;
      let volumeMaxFlag = currentVolume > PlayConstants.MAX_VALUE;
      this.playerModel.volume = volumeMinFlag ? PlayConstants.MIN_VALUE :
        (volumeMaxFlag ? PlayConstants.MAX_VALUE : currentVolume);
      this.avPlayer.setVolume(this.playerModel.volume);
      this.positionX = event.offsetX;
    }
  }

  /**
   * Gesture method onActionUpdate.
   *
   * @param event Gesture event.
   */
  onBrightActionUpdate(event?: GestureEvent) {
    if (!event || this.playerModel == null) {
      return;
    }
    if (this.playerModel.volumeShow === false) {
      this.playerModel.brightShow = true;
      let screenHeight = GlobalContext.getContext().getObject('screenHeight') as number;
      let changeBright = (this.positionY - event.offsetY) / screenHeight;
      let bright: number = this.playerModel.bright;
      let currentBright = bright + changeBright;
      let brightMinFlag = currentBright <= PlayConstants.MIN_VALUE;
      let brightMaxFlag = currentBright > PlayConstants.MAX_VALUE;
      this.playerModel.bright = brightMinFlag ? PlayConstants.MIN_VALUE :
        (brightMaxFlag ? PlayConstants.MAX_VALUE : currentBright);
      this.setBright();
      this.positionY = event.offsetY;
    }
  }

  /**
   * Gesture method onActionEnd.
   */
  onActionEnd() {
    setTimeout(() => {
      if (this.playerModel) {
        this.playerModel.volumeShow = false;
        this.playerModel.brightShow = false;
      }
      this.positionX = PlayConstants.POSITION_X;
      this.positionY = PlayConstants.POSITION_Y;
    }, PlayConstants.DISAPPEAR_TIME);
  }

  /**
   * Sets whether the screen is a constant based on the playback status.
   */
  watchStatus() {
    let windowClass = GlobalContext.getContext().getObject('windowClass') as window.Window;
    if (this.status === CommonConstants.STATUS_START) {
      windowClass.setWindowKeepScreenOn(true);
    } else {
      windowClass.setWindowKeepScreenOn(this.isWindowKeepScreenOn);
    }
  }

  /**
   * Sets the playback page size based on the video size.
   */
  setVideoSize() {
    if (this.avPlayer == null || this.playerModel == null) {
      return;
    }
    if (this.avPlayer.height > this.avPlayer.width) {
      this.playerModel.videoWidth = PlayConstants.PLAY_PLAYER_HEIGHT_FULL;
      this.playerModel.videoHeight = PlayConstants.PLAY_PLAYER_HEIGHT_FULL;
      this.playerModel.videoPosition = FlexAlign.Start;
      this.playerModel.videoMargin = PlayConstants.HEIGHT;
    } else {
      this.playerModel.videoWidth = CommonConstants.FULL_PERCENT;
      this.playerModel.videoHeight = PlayConstants.PLAY_PLAYER_HEIGHT;
      this.playerModel.videoPosition = FlexAlign.Center;
      this.playerModel.videoMargin = PlayConstants.MARGIN_ZERO;
    }
  }

  /**
   * An error is reported during network video playback.
   */
  playError() {
    prompt.showToast({
      duration: PlayConstants.PLAY_ERROR_TIME,
      message: $r('app.string.link_check_address_internet')
    });
  }

  sendInitialized(): void {
    diag("sendInitialized")
    let event: HashMap<string, Object> = new HashMap<string, Object>();
    event.set("event", "initialized");
    event.set("duration", this.avPlayer?.duration);
    event.set("width", this.avPlayer?.width);
    event.set("height", this.avPlayer?.height);
    event.set("rotationCorrection", this.cachedRotationCorrection);
    this.eventSink?.success(event);
  }

  /// 🔴 2026-10-24（HeinPlay 本地 fork）：起播定位 seek 的**兜底**。
  ///
  /// 【场景】正常路径是 PREPARED → play() → PLAYING → seek。
  ///   若宿主未调 play()（或 play 后状态迟迟不切 PLAYING），seek 就永远不会下发，
  ///   续播定位彻底失效 ⇒ 每次起播都从片头开始。
  ///   故设 2s 兜底：仍未进 PLAYING 就在当前态下发 seek。
  ///   （宁可承担「未播放态 seek」的小概率 IO error，也不能让定位彻底失效。）
  private armStartSeekFallback(): void {
    this.clearStartSeekFallback();
    this.startSeekFallbackTimer = setTimeout(() => {
      this.startSeekFallbackTimer = -1;
      if (this.startSeekTarget >= 0 && this.avPlayer !== null) {
        const target: number = this.startSeekTarget;
        this.startSeekTarget = -1;
        diag("⚠️ 起播定位兜底：600ms 内未进入 PLAYING，在当前态下发 seek " + target + "ms");
        this.avPlayer.seek(target, media.SeekMode.SEEK_NEXT_SYNC);
      }
    // 🔴 2026-10-24：2000ms → 600ms。
    //   真机实测（hilog 2026-10-24 20:34:28）：prepared → playing 只用了 **19ms**；
    //   之前之所以 2s 没进 PLAYING，是代理预取抢占了 CDN 带宽（已在代理侧修复），
    //   再等 2s 纯属白等 —— 真机实测这一项就白花 2 秒。
    }, 600);
  }

  private clearStartSeekFallback(): void {
    if (this.startSeekFallbackTimer !== -1) {
      clearTimeout(this.startSeekFallbackTimer);
      this.startSeekFallbackTimer = -1;
    }
  }

  /// 🔴 2026-10-24：等待「seek 后首帧送显」的兜底。
  ///
  /// 某些源/设备可能不触发 startRenderFrame ⇒ 兜底 1.5s 后强制 sendInitialized，
  /// 避免 Flutter 永远收不到 initialized（黑屏）。
  private armInitFallback(): void {
    this.clearInitFallback();
    this.initFallbackTimer = setTimeout(() => {
      this.initFallbackTimer = -1;
      if (this.awaitingFirstFrameForInit) {
        this.awaitingFirstFrameForInit = false;
        diag("⚠️ 起播定位后首帧未送显（兜底 1.5s）→ sendInitialized");
        this.sendInitialized();
      }
    // ⚠️ 2026-10-24 复核：**保持 1500ms，不砍到 800ms**（曾一度改成 800ms，已回退）。
    //
    // 【为什么不能砍 —— 真机 hilog 2026-10-24 实测】
    //   · 本设备上 `startRenderFrame` **一次都没触发**（原生「首帧送显」日志 0 次）
    //     ⇒ 这个兜底**每次都走满**，是必需的安全网，不是可以省掉的空等。
    //   · 实测真首帧时刻：SEEK_DONE(20:35:14.457) → 真首帧(20:35:16.172)
    //     = **1.715s**，而 1.5s 兜底在 20:35:15.958 触发 —— 只差 0.215s。
    //   · 若把兜底压到 800ms，sendInitialized 会**早于真实送显 0.9s**，
    //     而 Flutter 收到 initialized 立刻去 external texture 取帧 ⇒
    //     `OH_NativeImage_AcquireNativeWindowBuffer() failed` 刷屏
    //     ⇒ **画面永久冻结在 seek 前那一帧、进度条却照常前进**
    //     （这正是 2026-10-24 20:00:58 真机刷屏 2637 次的那个坑）。
    //
    // 【为什么 startRenderFrame 必然不触发】—— 架构上的循环依赖：
    //   native surface 要等 Flutter 侧创建 external texture 才存在，
    //   而 Flutter 的 texture 要等 initialized 才创建，initialized 又在等 startRenderFrame。
    //   ⇒ 本架构下它不可依赖，兜底必须保留。
    //
    // 【本轮真正的提速点不在这里】—— 在代理侧（落点段排队 42.6s）。
    }, 1500);
  }

  private clearInitFallback(): void {
    if (this.initFallbackTimer !== -1) {
      clearTimeout(this.initFallbackTimer);
      this.initFallbackTimer = -1;
    }
  }

  private async getRotationCorrection(): Promise<number> {
    let extractor: media.AVMetadataExtractor | null = null;
    let fd: fs.File | null = null;
    try {
      extractor = await media.createAVMetadataExtractor();
      if (this.url?.startsWith("file://")) {
        fd = fs.openSync(this.url.substring(7), fs.OpenMode.READ_ONLY);
        extractor.fdSrc = { fd: fd.fd, offset: 0, length: 0 };
      } else if (this.url) {
        if (deviceInfo.sdkApiVersion < 20) {
          return 0;
        }
        extractor.setUrlSource(this.url, this.headers ?? undefined);
      } else if (this.rawFile) {
        extractor.fdSrc = this.rawFile;
      } else {
        return 0;
      }
      const metadata = await extractor.fetchMetadata();
      const orientation = metadata.videoOrientation ? parseInt(metadata.videoOrientation) : 0;
      if (orientation === 0 || orientation === 90 || orientation === 180 || orientation === 270) {
        return orientation;
      }
      return 0;
    } catch (e) {
      Log.w(TAG, 'getRotationCorrection error: ' + JSON.stringify(e));
      return 0;
    } finally {
      if (fd) {
        fs.closeSync(fd);
      }
      extractor?.release();
      extractor = null;
    }
  }

  sendCompleted(): void {
    let event: HashMap<string, Object> = new HashMap<string, Object>();
    event.set("event", "completed");
    this.eventSink?.success(event);
  }

  /// 🔴 2026-09-28：起播计时打点（见 tMediaSource 等字段说明）。
  private markMediaSourceSet(): void {
    const now = Date.now();
    // 每次重新 setMediaSource（含 IDLE 重设）都视为新一次起播，重置全部打点，
    // 避免上一轮的时间戳污染本轮统计。
    this.tMediaSource = now;
    this.tInitialized = 0;
    this.tPrepared = 0;
    this.tFirstFrame = 0;
    this.tPlayCalled = 0;
  }

  /// 输出起播四段耗时。在首帧到达时调用一次。
  private logStartupTiming(trigger: string): void {
    if (this.tMediaSource === 0) return;
    const now = Date.now();
    const total = now - this.tMediaSource;
    const seg = (to: number): string =>
      to > 0 ? (to - this.tMediaSource).toString() + 'ms' : '-';
    diag("起播耗时[" + trigger + "] 总计=" + total + "ms"
      + " 初始化=" + seg(this.tInitialized)
      + " 准备=" + seg(this.tPrepared)
      + " 播放=" + seg(this.tPlayCalled)
      + " 首帧=" + seg(this.tFirstFrame));
  }

  resetBufferingState(): void {
    let wasBuffering = this.isBuffering;
    this.isSystemBuffering = false;
    this.isSeekBuffering = false;
    this.isSeeking = false;
    this.seekPosition = 0;
    // 🔴 2026-10-24（第十六轮）：新会话/释放 ⇒ 允许再次上报致命 seek 错误。
    //   （resetBufferingState 只在 ERROR 非屏蔽路径与 release 时被调用，
    //     **不会**在 seekDone 时被调用 ⇒ 不会导致同一会话内重复上报。）
    this.fatalSeekErrorReported = false;
    this.bufferTimeTemp = 0;
    // 🔴 2026-10-24（第十四轮）：reset/release 时必须清掉 seek 兜底定时器，
    // 否则播放器已释放后定时器仍会触发并操作已销毁的状态。
    this.clearSeekWatchdog();
    // 缓冲条起点复位到续播记录点（无记录则 0）：
    // release/reset 后若再次播放，起点应回到「本次播放的实际拉流起点」，
    // 否则会沿用上一次 seek 的落点，把缓冲条画错位置。
    this.bufferedStartMs = this.startPositionMs;
    if (wasBuffering) {
      this.syncBufferingState();
    } else {
      this.isBuffering = false;
    }
  }

  syncBufferingState(): void {
    let shouldBuffering = this.isSystemBuffering || this.isSeekBuffering;
    if (shouldBuffering == this.isBuffering) {
      return;
    }
    this.isBuffering = shouldBuffering;
    let event: HashMap<string, Object> = new HashMap<string, Object>();
    event.set("event", shouldBuffering ? "bufferingStart" : "bufferingEnd");
    this.eventSink?.success(event);
  }

  startSystemBuffering(): void {
    this.isSystemBuffering = true;
    this.syncBufferingState();
  }

  endSystemBuffering(): void {
    this.isSystemBuffering = false;
    this.syncBufferingState();
  }

  startSeekBuffering(): void {
    this.isSeekBuffering = true;
    this.syncBufferingState();
  }

  endSeekBuffering(): void {
    if (!this.isSeekBuffering) {
      return;
    }
    this.isSeekBuffering = false;
    this.syncBufferingState();
  }

  startBufferingInfoTimer(): void {
    if (deviceInfo.sdkApiVersion < PLAYBACK_INFO_MIN_SDK) {
      return;
    }
    if (this.bufferingInfoTimer !== -1 || this.avPlayer == null) {
      return;
    }
    this.bufferingInfoTimer = setInterval(() => {
      this.reportBufferedPositionFromPlaybackInfo();
    }, BUFFER_INFO_POLL_INTERVAL);
  }

  stopBufferingInfoTimer(): void {
    if (this.bufferingInfoTimer === -1) {
      return;
    }
    clearInterval(this.bufferingInfoTimer);
    this.bufferingInfoTimer = -1;
    this.isPollingPlaybackInfo = false;
  }

  async reportBufferedPositionFromPlaybackInfo(): Promise<void> {
    if (this.avPlayer == null || this.isPollingPlaybackInfo) {
      return;
    }
    this.isPollingPlaybackInfo = true;
    try {
      let avPlayer = this.avPlayer as AVPlayerWithPlaybackInfo;
      let playbackInfo = await avPlayer.getPlaybackInfo();
      let bufferDurationObject = playbackInfo[PLAYBACK_INFO_BUFFER_DURATION_KEY];
      if (typeof bufferDurationObject === 'number') {
        this.sendBufferingUpdate(media.BufferingInfoType.CACHED_DURATION, bufferDurationObject * CommonConstants.A_THOUSAND);
      }
    } catch (e) {
      console.error(TAG, "reportBufferedPositionFromPlaybackInfo error:" + JSON.stringify(e))
    } finally {
      this.isPollingPlaybackInfo = false;
    }
  }

  sendBufferingStart(): void {
    this.startSystemBuffering();
  }

  sendBufferingEnd(): void {
    this.endSystemBuffering();
  }

  sendBufferingUpdate(infoType: media.BufferingInfoType, bufferingPosition: number): void {
    let event: HashMap<string, Object> = new HashMap<string, Object>();
    if (infoType == media.BufferingInfoType.BUFFERING_START) {
      this.sendBufferingStart();
      return;
    } else if (infoType == media.BufferingInfoType.BUFFERING_END) {
      this.sendBufferingEnd();
      return;
    } else if (infoType == media.BufferingInfoType.CACHED_DURATION) {
      event.set("event", "bufferingUpdate");
      // 🟢 2026-09-28 定稿：起点 = 续播记录点（固定），终点 = 已缓冲峰值（单调递增）。
      //
      // 【需求】avp 不显示「从头开始缓冲」，只从播放记录点开始缓冲。
      // 官方实现起点恒 0，于是续播时进度条把片头整段画成已缓冲 —— 与实际不符。
      //
      // 【关键】起点必须**固定**，绝不能跟随 playTime：
      //   我曾改成 [bufferedStartMs, playTime + bufferingPosition]，结果
      //   ① 区间宽度只剩前方那点缓存 → 「几乎没有缓冲条」；
      //   ② 起终点每秒被拖着往前滑 → 每 500ms 重画 → 「闪烁」。
      //   教训：起点固定 + 终点单调递增，才是既正确又稳定的组合。
      //
      // 【终点为什么用峰值】沿用官方的 bufferTimeTemp 语义：绝对时间轴上的
      // 已缓冲终点，只增不减。单调递增保证缓冲条平滑增长、不来回跳。
      // 注意它是**绝对位置**，与固定的起点相减即得条长，长度正常。
      //
      // 【无续播记录时】bufferedStartMs = 0，行为与官方完全一致（回归安全）。
      //
      // ⚠️ 与定位逻辑严格隔离：本分支只读 bufferedStartMs，不写、不 seek。
      // 起播定位由 startPositionMs → pendingSeekPosition → PREPARED seek 负责。
      //
      // 🔴🔴🔴 2026-10-26（HeinPlay 本地 fork，第十八轮）：**钳制「可播放缓存时长」**。
      //
      // 【真机实锤】hilog 2026-10-26 08:02:44~08:02:48（鸿蒙 TV 真机，第23集 46:03）：
      //   08:02:45.921  进度 position=0ms      buffered=11656ms  duration=1432625ms
      //   08:02:47.294  用户快进 → seekTo: target=79147ms mode=SEEK_CLOSEST
      //   08:02:47.918  进度 position=79155ms buffered=1332257ms
      //                  bufFirst=79147/1332257 duration=1432625ms
      //   ⇒ AVPlayer 报的「可播放缓存时长」= 1332257-79147 = 1253 秒，
      //     而这 0.6 秒内实际只下载了十几 MB（物理上不可能缓冲 20 分钟），
      //     进度条于是被画成「缓冲到快完」（96%），用户投诉「快进后缓冲条铺满」。
      //   快退时因 prepareSeek 把 bufferTimeTemp 归零，缓冲条又「恢复正常」，
      //     正好反证数值来自 buffer_duration 的峰值、而非真实缓冲量。
      //
      // 【为什么快进后才爆】快进触发 seek → AVPlayer 重新按裁剪后的列表
      //   建立「可播放时长」估算，HLS 场景下这个估算会远大于真实缓冲量；
      //   起播时同一路径给的是正常值（11.6s），故只有「快进后」才异常。
      //
      // 【修法】把「可播放缓存时长」钳到应用设定的**缓冲窗口**以内
      //   （bufferDurationMs = 宿主算出的 avp 档位，鸿蒙默认 60s = 60MB），
      //   既保留真实缓冲的观感，又不会被异常巨值撑爆进度条。
      //   ⚠️ 只影响上报数值，不改任何播放行为（不 seek、不改缓冲档位）。
      const DEFAULT_BUFFER_WINDOW_MS: number = 60000;
      const bufferWindowMs: number = this.bufferDurationMs > 0
        ? this.bufferDurationMs
        : DEFAULT_BUFFER_WINDOW_MS;
      if (bufferingPosition > bufferWindowMs) {
        // ⚠️ 只在「首次异常 / 从异常恢复」时打一条，避免 500ms 一次的轮询刷屏
        //   （第十七轮刚因日志刷屏返工过，这里必须一次只打一条）。
        if (!this.bufferAnomalyReported) {
          this.bufferAnomalyReported = true;
          diag("⚠️ 缓冲时长上报异常：" + Math.round(bufferingPosition) +
            "ms 超过缓冲窗口 " + bufferWindowMs + "ms ⇒ 钳制（防止缓冲条铺满进度条）");
        }
        bufferingPosition = bufferWindowMs;
      } else if (this.bufferAnomalyReported) {
        this.bufferAnomalyReported = false;
      }
      let bufferedDuration = this.playTime + bufferingPosition;
      if (bufferedDuration > this.bufferTimeTemp) {
        this.bufferTimeTemp = bufferedDuration;
      }
      if (this.duration !== 0 && this.bufferTimeTemp > this.duration) {
        this.bufferTimeTemp = this.duration;
      }
      // 终点不得小于起点（续播瞬间峰值可能尚未越过记录点）。
      let bufferedEnd = this.bufferTimeTemp;
      if (bufferedEnd < this.bufferedStartMs) {
        bufferedEnd = this.bufferedStartMs;
      }
      let range: ArrayList<number> = new ArrayList<number>();
      range.add(this.bufferedStartMs);
      range.add(bufferedEnd);
      let valuesList: ArrayList<ArrayList<number>> = new ArrayList<ArrayList<number>>();
      valuesList.add(range);
      event.set("values", valuesList);
    } else {
      event.set("event", "unknown");
    }
    this.eventSink?.success(event);
  }

  sendError(error: Object): void {
    const errorMessage = error instanceof Error ? error.message : String(error);
    this.eventSink?.error("VideoError", `Video player had error: ${errorMessage}`, error);
  }

  getIUri(): string {
    let iUrl = this.url;
    const ohosFilePrefix = 'file://';
    if (iUrl != null && iUrl.startsWith(ohosFilePrefix)) {
      if (this.fd != null) {
        fs.closeSync(this.fd!);
        this.fd = null;
      }
      this.fd = fs.openSync(iUrl, fs.OpenMode.READ_ONLY).fd;
      iUrl = `fd://${this.fd!.toString()}`;
    }
    return iUrl ?? '';
  }
}

class StreamHandlerImpl implements StreamHandler {
  private eventSink: QueuingEventSink | null = null;

  constructor(eventSink: QueuingEventSink) {
    this.eventSink = eventSink;
  }

  onListen(args: Object, events: EventSink): void {
    this.eventSink?.setDelegate(events);
  }

  onCancel(args: Object): void {
    this.eventSink?.setDelegate(null);
  }
}
