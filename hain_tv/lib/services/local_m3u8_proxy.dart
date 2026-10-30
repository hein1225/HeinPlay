import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes_fast.dart';
import 'package:pointycastle/block/modes/cbc.dart';

import 'm3u8_ad_filter.dart';
import 'ts_pts_normalizer.dart';
import 'hls_prefetch_window.dart';
import '../utils/windows_logger.dart';

/// 本地 M3U8/TS 代理服务。
///
/// 用于解决去广告后的 M3U8 在不同播放器后端（ExoPlayer / FVP / VLC）
/// 中播放时头部透传不一致的问题。所有资源请求统一走本地代理，由代理补全头部。
class LocalM3u8Proxy {
  /// 🔴 2026-10-29：当前活动实例（供 mpv 后端在 open/seek 前调用
  ///   [primePrefetchAt] 预热落点分片）。
  ///
  ///   鸿蒙侧同名机制（`static LocalM3u8Proxy? currentInstance`），移植过来。
  ///   全局同时只有一个代理在跑，因此单槽足够。
  static LocalM3u8Proxy? currentInstance;

  HttpServer? _server;
  String? _playlistContent;
  final Map<String, String> _baseHeaders = {};
  http.Client? _client;
  bool _closing = false;
  bool _filterEnabled = false;
  bool _discontinuityCleanup = false;
  // fvp 专属：给每个分段代理 URL 注入全局唯一序号（&hseg=N）并丢弃结构性
  // #EXT-X-DISCONTINUITY，避免 libmdk 因跨断点复用同名分片（如 plist0.ts）
  // 命中段缓存、停止续预取而卡死。仅 fvp 后端开启。
  bool _fvpRenumber = false;

  /// ★ 2026-09-25：master playlist 展开缓存。
  ///
  /// 现象（072249 日志实证）：若交给 libmdk 的 `playlist.m3u8` 是 **master**
  /// （只有 `#EXT-X-STREAM-INF` + 一行变体 URL），libmdk 需再请求「子 m3u8」取到
  /// media playlist；此时它会陷入死锁：`buffered` 恒等于 `position`（上报的缓冲
  /// 区间长度 = 0）、`buffering=true` 永不结束、永远够不到 `min` 起播阈值，于是
  /// 画面卡死、reader 反复重下同一批分片（源1 17s 内 199 次请求 / 仅 62 个唯一
  /// 分片）。而**单级** media playlist 的源（`playlist.m3u8` 本身就是 media，
  /// 如 ly166）同机同源正常播放，`buffered` 领先 `position` 达 max=20000ms。
  ///
  /// 修复：代理在 `playlist.m3u8` 出口处把 master **就地展开为 media**——直接拉取
  /// 变体 media playlist、去广告、重写分片 URL 后作为响应体返回，让 libmdk 只看到
  /// 一级结构（= 能播源的形态）。纯代理层改动，不碰 fvp/libmdk。
  ///
  /// 展开只做一次并缓存（libmdk 可能多次请求 playlist）；展开失败则**回退原 master**
  /// 保持旧行为，不使情况恶化。
  ///
  /// ⚠️ 缓存带 **3 秒 TTL**：点播（VOD）的 media playlist 不变，缓存只用于省掉重复
  /// 的 CDN 往返；但**直播**的 media playlist 会按 `#EXT-X-TARGETDURATION`（4–6s）
  /// 滚动，若永久缓存会让 libmdk 永远拿到旧播放列表而卡住。3s < 4s，直播每次
  /// reload 都会重新展开。失败时只在 TTL 窗口内退避，窗口外允许重试。
  String? _expandedPlaylist;
  DateTime? _expandedAt;
  static const Duration _kExpandedTtl = Duration(seconds: 3);

  /// 播放列表代次：`setPlaylist`（换源/换集）时自增。
  ///
  /// 展开是异步的（含一次 CDN 往返），若期间发生换源，旧源的展开结果绝不能写回
  /// `_expandedPlaylist`——否则新源会拿到**上一个源的 media playlist** 而播错内容。
  int _playlistGen = 0;

  /// fvp 专属：AES-128 解密用到的 key 缓存（按 key URI 缓存，避免每段重复拉取）。
  final Map<String, Uint8List> _aesKeyCache = {};

  // ===== HLS 并发分片预取（移植自 hain_tv_ohos，借鉴 LunaTV OptimizedHlsLoader）=====
  //
  // 命门：分片必须流经本 Dart 本地代理，才能被预取（mpv/avplayer 直连 CDN 时
  // 请求在 native 层，Dart 侧不可见）。故仅在 AdFilterEngine 强制透传（预取
  // 开关开启，或 fvp 后端）时生效。
  //
  // 做法：playlist 出口处按出现顺序收集所有「媒体分片 CDN URL」到 _segmentUrls；
  // 每次 _proxySegment 命中某分片时，定位其在列表中的下标，预取其后的 N 个分片
  // 存入内存缓存；下次播放器请求这些分片时直接命中缓存并按 Range 切片返回，
  // 消除「逐段等 CDN」的串行等待（弱网/换段效果最明显）。
  //
  // ⚠️ 移植适配：鸿蒙侧用 `kPtsNormalizeObserveOnly` 常量控制是否真的施加 PTS
  //    平移（该常量默认 false 即启用）；主工程对应的是运行时开关 `_ptsNormalize`，
  //    故出口处改为判 `_ptsNormalize`（语义一致：开关开则施加平移）。
  //
  // 约束：缓存上限 50MB、连续失败 3 次熔断（与 LunaTV 一致）；预取任务串行调度
  // （单队列 + 标志位），避免并发无上限；换源/换集（setPlaylist）与 stop 时清空，
  // 复用 _playlistGen 防止旧源预取结果污染新源。
  bool _prefetchEnabled = false;
  /// 用于「_segmentUrls 为空 → 预取未启动」警告的去重，避免每分片刷屏。
  bool _prefetchEmptyWarned = false;
  static const int _kMaxPrefetchCount = 8; // 预取后续分片数
  static const int _kMaxPrefetchCacheBytes = 50 * 1024 * 1024; // 50MB
  static const int _kMaxPrefetchFailures = 3; // 连续失败熔断

  /// 🔴🔴 2026-10-29：预取**并发**路数（移植鸿蒙的 `_kPrefetchConcurrency`）。
  ///
  /// 【为什么必须并发 —— 真机日志实锤（小米 12S Pro 2026-10-29 21:31）】
  ///   21:31:31.156 plist0 下载完（849KB）
  ///   21:31:31.385 plist1 下载完（328KB）
  ///   21:31:32.207 plist2 下载完（654KB）
  ///   21:31:33.893 plist3 下载完（396KB）
  ///   ⇒ 4 个头部段**串行**花了 2.7s；落点段 plist315 更等到 21:31:34.054
  ///     （open 后 4.3s）才到手。
  /// 串行预取的交付速率 ≈ 1 段/1~2s，贴着消费速率跑 ⇒ 提前量恒为 0。
  /// 鸿蒙侧实测：同一 CDN **8 路并发**时 ttfb 仍是 0.76~1.32s（与串行几乎一样）
  /// ⇒ CDN 扛得住并发，4 路足以把「头部段 + 落点窗口」一次性备齐。
  static const int _kPrefetchConcurrency = 4;

  /// 🔴🔴 2026-10-30：起播关键路径（**落点段**）允许额外占用的并发路数。
  ///
  /// 【为什么需要 —— 荣耀平板 V8 Pro 真机实测（2026-10-30 08:26）】
  ///   open 08:26:30.076 → 首个 time-pos 08:26:39.081（**9s 空转**，前 6 个心跳
  ///   的 time-pos 全为空 = 连时间轴都没建立）⇒ mpv 起播 ~12s，同机 ExoPlayer
  ///   只要 2.3~5.1s。
  ///   落点段（plist366, 1.2MB）在预热队列里**排第 5 位**（前面压着建索引的
  ///   plist0..3 共 2.23MB），08:26:38 才就绪；而 mpv 必须先拿到 plist0 建索引
  ///   （08:26:36）才能发出 seek ⇒ 两段串行，白等 ~2s。
  ///   ⇒ 落点段必须**插队到队首**，并允许**多占 1 路并发**立刻开跑，
  ///      与建索引段并行，而不是排队等它们腾位置。
  static const int _kPrimePriorityBonus = 1;

  /// 🔴 2026-10-29：落点预热窗口深度（含落点自身）。
  ///   落点段是 seek 的目标，必须**连它自己**一起预取（见 primePrefetchAt）。
  static const int _kPrimeDepth = 12;

  final Map<String, Uint8List> _prefetchCache = {};
  /// 🔴 预取缓存**只存原始 CDN 字节**，PTS 平移改在出口
  /// （`_servePrefetched` / 直连路径）施加。本表记录每个 key 对应的 delta，
  /// 避免出口处再异步调 `_deltaFor`（该函数会走网络探测，出口是同步路径）。
  final Map<String, int> _prefetchDelta = {};
  final List<String> _prefetchQueue = [];

  // ===== 🔴🔴 2026-10-29：起播预热（落点窗口 + 建索引头部段） =====
  //
  // 【真机实锤：小米 12S Pro 日志 2026-10-29 21:31】
  //   21:31:29.744 open startAt=1450000ms
  //   21:31:31.156 plist0 下载完（849KB）   ← mpv 建索引，从头拉
  //   21:31:31.385 plist1 下载完（328KB）
  //   21:31:32.207 plist2 下载完（654KB）
  //   21:31:33.893 plist3 下载完（396KB）   ← 4 个头部段串行 = 2.7s
  //   21:31:31.845 file-loaded → 立即 seek 1450s
  //   21:31:34.054 plist315（落点段）下载完  ← open 后 4.3s
  //   21:31:36.005 首个 time-pos（首帧）    ← open 后 6.3s
  //
  // ⇒ 两个可优化点：
  //   ① 建索引头部段（0..3）是**阻塞项**（索引没建成，seek 发不出去），
  //      但它们被**串行**下载 ⇒ 2.7s；
  //   ② 落点段 plist315 在 seek 之后才回源 ⇒ open 后 4.3s 才拿到。
  //
  // 【修法（移植鸿蒙 hain_tv_ohos 的 primePrefetchAt）】
  //   open(startAt) / seek **之前**把预热目标告诉代理，代理立刻：
  //     1. 用名义轴（EXTINF 累加）把播放位置换算成分片下标；
  //     2. 把「落点段自身 + 其后 N 段」与「建索引头部段」**并发**开跑；
  //     3. 预热线程**直接回源 CDN** 下载该分片的**原始字节**并缓存。
  //
  // 【为什么缓存「原始字节」而不是「出口明文」—— 关键设计】
  //   主工程 mpv 走的是代理的 **AES-128 解密分支**（rewriteToLocalProxy 在
  //   mpv 后端注入 &decrypt=aes128&key=&iv=）。旧预取虽然也回源 CDN，但
  //   ① 存的是密文，② 只在**明文直连分支**才被查询 ⇒ 对解密分支毫无意义：
  //   日志里「收集分片 621 个」之后**一条「命中并缓存」都没有**
  //   （预取整源静默失效）。
  //
  //   本实现缓存 **CDN 原始字节**（加密源即密文），并在出口处**伪造一个
  //   http.StreamedResponse** 顶替回源响应：
  //     · 解密分支：拿密文走**原样**的解密 + PTS 平移逻辑（零行为差异）；
  //     · 明文分支：拿明文走**原样**的 PTS 归一化逻辑（零行为差异）。
  //   ⇒ 预热只省掉一次 **回源 RTT**（真机实测 0.8~2s/段），
  //     而解密、PTS、Range、状态码等语义**完全不变**（最稳的改法）。
  final Map<String, Uint8List> _primeCache = {};
  int _primeBytes = 0;
  /// 🔴 2026-10-29：**在途**下载表（分片 URL → 下载 Future）。
  ///
  ///   用途：播放器请求某分片时，若预热线程**正在**下载同一分片，
  ///   就**等它下完**复用同一份字节，而不是自己再发一次请求。
  ///   ⇒ 既省一次回源往返，也避免「两份下载互相抢带宽」。
  final Map<String, Future<Uint8List?>> _primeInflight = {};
  /// 🔴 2026-10-29：是否已有后端请求过起播预热。
  ///
  ///   头部段预热只在该闸门打开后进行 —— 走 ExoPlayer 等不需要落点预热的
  ///   后端时，不做这份额外的并发下载。
  bool _primeRequested = false;
  final List<String> _primeQueue = [];

  /// 🔴 2026-10-30：预热队列里的「关键路径」分片（目前 = 落点段）。
  ///
  ///   落点段是 seek 的直接目标，一刻都不能等 ⇒ 它插队到队首，并允许
  ///   [_kPrimePriorityBonus] 路额外并发，让它与建索引段**并行**下载。
  final Set<String> _primePriority = <String>{};
  final Set<String> _primeQueued = {};
  int _primeWorkers = 0;

  int _prefetchTotalBytes = 0;
  int _prefetchFailCount = 0;
  bool _prefetchRunning = false;
  /// 当前 playlist 的媒体分片 CDN URL（顺序）。
  ///
  /// ⚠️ 存的是**解码后的 CDN 原始 URL**，与 `_proxySegment` 里的 `targetUrl`
  /// 同源 —— 收集侧与匹配侧必须同一形态，否则 `indexOf` 恒为 -1、预取静默失效
  /// （鸿蒙侧踩过此坑：早期收集代理 URL、匹配 CDN URL，导致整源预取失效且零日志）。
  List<String> _segmentUrls = const [];

  /// 🔴 2026-10-29：每个分片在**名义轴**（EXTINF 累加轴）上的起点（ms）。
  ///
  ///   与 [_segmentUrls] **同序等长**（同一次解析产出）⇒ 下标一一对应。
  ///   用途：把「播放位置（ms）」换算成「分片下标」，从而在 **open(startAt) /
  ///   seek 之前**把预取窗口预热到目标位置（见 [primePrefetchAt]）。
  ///
  ///   口径：mpv 的 position 走真实 PTS 轴，但本代理已做 PTS 归一化（真实轴
  ///   平移到名义轴）⇒ 两者落在同一根轴上，与鸿蒙口径一致。
  List<int> _segmentStartMs = const [];

  /// 🔴 2026-10-29：分片表尚未就绪时挂起的预热目标（ms）。
  ///   mpv 的 `open(startAt)` 发生在 master 展开完成之前（展开要 1.1~2.8s），
  ///   此刻连分片表都还没有 ⇒ 先记下位置，待 `_collectSegmentUrls` 收集完成后
  ///   自动补做（与鸿蒙同逻辑）。
  int? _pendingPrefetchTargetMs;

  /// 🔴 2026-10-29：建索引头部段数量（插队首）。
  ///
  ///   mpv 打开 m3u8 后会**从第 0 段开始**顺序拉若干分片（建播放列表索引 /
  ///   探测起播），这是**阻塞项**：索引没建成，seek 根本发不出去。
  ///   真机日志（小米 12S Pro 2026-10-29 21:31）：plist0 → plist3 依次回源，
  ///   耗时 2.7s；落点段 plist315 更是等到 open 后 4.3s 才到手。
  ///   故头部段必须**优先于**落点窗口开跑。
  static const int _kIndexHeadSegments = 4;

  /// 🔴 2026-10-15 新增：`_segmentUrls` 是由哪份 playlist 文本解析出来的。
  ///
  ///   仅用于 `_collectSegmentUrls` 的幂等守卫：内容相同即跳过重复解析。
  ///   不作为缓存 —— 内容一变就会重新收集并覆盖。
  String? _collectedFrom;

  // ───────────────────────────────────────────────────────────────────────
  // PTS 归一化（进度偏移根治）
  // ───────────────────────────────────────────────────────────────────────
  //
  // 移植自 hain_tv_legacy（TV 工程，已真机验证 residual 恒 0）。原理见
  // `lib/services/ts_pts_normalizer.dart` 头部与工作日志
  // `plan/worklogs/2026-10-11-mpv进度漂移根治-跨平台通用总结.md`。
  //
  // 一句话：mpv 的 time-pos 走「分片真实 PTS 轴」，duration 走「去广告 EXTINF
  // 名义轴」，两轴速率不同 ⇒ 进度条越播越偏。治法是把每段的 PTS/DTS/PCR 平移
  // 一个逐段常量 delta，使两轴同源。
  //
  // ⚠️ 与 legacy 的差异：legacy 恒开（其工程只有 mpv 一种后端）；主工程有
  //    mpv / exo / vlc 三种后端共存，且历史行为是无平移，故做成**可开关**，
  //    默认关闭，由上层按后端与用户设置决定（见 setPtsNormalize）。

  /// 是否启用 PTS 归一化。默认关闭（保持主工程历史行为，避免影响 exo/vlc）。
  bool _ptsNormalize = false;

  /// 🔴🔴 2026-10-17 新增：探测模式 —— 「只测量、不改字节」。
  ///
  /// 【为什么需要它】`_ptsNormalize` 一个开关同时承担了两件不同的事：
  ///   ① 建立 PTS 基准、计算每段 delta 并**施加**字节平移；
  ///   ② **判断「源的 PTS 轴是否可信」**。
  ///
  /// 上层原本的优化是「本次没裁掉任何广告片段 ⇒ 时间轴没变 ⇒ 关掉归一化」。
  /// 前半句对（不需要平移），后半句错 —— **时间轴没变，不等于时间轴是准的**。
  /// 源自身 PTS 错乱时（如真机 XiaoPaiTech BA001 2026101711 的加密源），
  /// EXTINF 名义轴是对的、真实 PTS 轴是乱跳的，两轴不一致恰恰**最需要**纠偏；
  /// 而关掉开关后连基准探测都停了，错乱直接暴露给播放器：
  ///   time-pos: 1299 → 1327 → 1330 → 1292 → 1299 → 1140 → 1128 → 990
  ///   用户观感即「进度条固定往后偏 20 秒」。
  ///
  /// 【语义】探测模式下：
  ///   · 仍然走完整的基准建立 + delta 计算（第 269 行 `_deltaFor` 的早退条件放宽）
  ///   · 但**绝不改字节**（第 1209/1781 行的平移施加处跳过）
  ///   · 每算出一个 delta 就打一条日志，供判断「源 PTS 是否可信」
  ///   · 一旦发现偏差超过阈值（[_kPtsDriftWarnMs]），说明源轴确实错乱，
  ///     上层应把它转成真正的 `_ptsNormalize = true` 来纠偏
  bool _ptsProbeOnly = false;

  /// 探测模式下，delta 偏离 0 超过该阈值即判定「源 PTS 轴错乱」（毫秒）。
  ///
  /// 取 500ms 的理由：正常源的段首 PTS 与 EXTINF 名义轴起点偏差在 ±100ms
  /// 内（关键帧对齐误差）；超过 500ms 已无法用「段内偏移」解释，必然是
  /// 累进性轴漂移。真机实测该加密源单段即跳 28 秒，远超阈值。
  static const int _kPtsDriftWarnMs = 500;

  /// 分段 → 该段在**去广告名义轴**上的起点（ms）。由上层从 M3u8AdFilter 装入。
  ///
  /// 🔴 键必须是**绝对 URL**，与 `?url=` 参数一致。两侧规则不统一会导致
  ///    查表全 miss、平移静默失效（legacy 与鸿蒙都踩过此坑）。
  Map<String, int> _segMeta = <String, int>{};

  /// 分段 → 已算出的 delta（ms）。同一分片在 seek 后可能被重复请求。
  final Map<String, int> _segDeltaCache = <String, int>{};

  /// 分段 → 已探测到的首帧 PTS（ms），仅用于埋点与排障。
  final Map<String, int> _segFirstPtsCache = <String, int>{};

  /// 判据：连续多少个分片读不出视频 PTS 就认定「本源 PTS 不可读」。
  ///
  /// 取 2 的理由：单个分片失败可能是切片边界等偶发因素，连续 2 个足以
  /// 排除偶发；同时把止损点压到最靠前 —— 真机实测该源连续失败 531 次，
  /// 若阈值取 3 会让前两个分片白付缓冲代价，取 2 则从第 3 个分片起就走流式。
  /// 见 `_deltaFor` 的 `no-pts` 分支与 `_proxySegment` 的因果注释。
  static const int _kPtsUnreadableThreshold = 2;

  /// 「本源是否能读出视频 PTS」的三态判定：
  ///   · `null` = 尚未判定（前几个分片还在探测）；
  ///   · `true`  = 已确认可读，走原有的「缓冲 + 改写 PTS」路径；
  ///   · `false` = 已确认不可读，后续分片直接流式转发，不再缓冲。
  ///
  /// 🔴 这是**源级**标志，不是逐分片标志：分片的封装方式由源决定，
  ///    同一源要么都能读出 PES PTS，要么都读不出。逐分片判断会反复付代价。
  bool? _ptsReadable;

  /// 连续读不出视频 PTS 的分片计数（读到一次即清零）。配合
  /// [_kPtsUnreadableThreshold] 把 [_ptsReadable] 从 `null` 推向 `false`。
  int _ptsUnreadableStreak = 0;

  /// 基准段（第一个能读到 PTS 的分片）的真实 PTS 与名义轴起点。
  ///
  /// 🔴 两者**必须同时**记住：只记 `_baseFirstPts` 会隐含假设「基准段的名义
  ///    起点 = 0」，而基准段不是列表首段时该假设不成立，会把基准段的名义起点
  ///    重复计入一次 ⇒ 所有分片被统一多平移 ⇒ 用户可见的「固定往后偏移」。
  int? _baseFirstPts;
  int? _baseFiltered;

  /// 🔴🔴 2026-10-17：基准所属的「名义轴区段」，用于 seek 后自动重建基准。
  ///
  /// 【为什么必须重建】
  ///   基准是**全局单例**，只在首个能读到 PTS 的分片上建立一次。用户从
  ///   319s 起播时，基准段就是 319s 那一片，`_baseFiltered` 记成它在名义轴
  ///   上的真实起点（≈318000ms）。但如果用户**快退到 90s**，此后请求的分片
  ///   全部来自名义轴 90s 附近，而 delta 仍按「相对 319s 基准」计算：
  ///
  ///     expected = baseFirstPts + (filtered − baseFiltered)
  ///              = 341480 + (90000 − 318000) = 113480ms
  ///     delta    = 113480 − 103480 = +10000ms     ← 凭空多平移 10 秒
  ///
  ///   实测真机日志（XiaoPaiTech BA001 2026101713）正是这个形态：
  ///     n=3  filtered=318000ms delta=-18000ms
  ///     n=5  filtered=90000ms  delta=-8000ms    ← 快退后 delta 整体换了基准
  ///   用户观感即「快退到目标进度后，位置往回偏十几秒」。
  ///
  /// 【判据】相邻两次请求的 `filtered` 相差超过 [kPtsBaseReseekGapMs] 就认为
  ///   发生了 seek（正常顺序播放，相邻分片名义差 = 段长，实测 ≤ 10.4s）。
  ///   阈值取 60s：远大于任何单段时长，又远小于一次有意的快退幅度。
  int? _lastRequestedFiltered;

  /// seek 判定阈值：相邻请求的名义轴跳跃超过此值即重建基准。
  static const int kPtsBaseReseekGapMs = 60000;

  /// 埋点节流计数（逐段打印会刷屏，上千段源尤甚）。
  int _axisLoggedIndex = 0;

  bool get isRunning => _server != null;

  /// 设置是否对子 M3U8 启用广告过滤。
  void setFilterEnabled(bool enabled) {
    _filterEnabled = enabled;
  }

  /// 设置去广告后是否清理孤立的 EXT-X-DISCONTINUITY 标记（Windows/fvp 需要）。
  void setDiscontinuityCleanup(bool enabled) {
    _discontinuityCleanup = enabled;
  }

  /// 设置 fvp 专属分段重编号 + 结构性 discontinuity 丢弃开关。
  /// 仅 fvp 后端开启：让每个分段代理 URL 全局唯一，规避 libmdk 段名复用卡死。
  void setFvpRenumber(bool enabled) {
    _fvpRenumber = enabled;
  }

  /// 设置是否启用 PTS 归一化（进度偏移根治）。
  ///
  /// ⚠️ 只在**真的需要**时开启：它要求媒体分片整段缓冲（无法再纯流式转发），
  /// 且会改写分片字节。对干净源（各段 delta≈0）字节零改动，开销仅为一次
  /// 首帧 PTS 探测。
  ///
  /// 关闭时会清空平移状态，避免残留基准污染后续播放。
  void setPtsNormalize(bool enabled) {
    if (_ptsNormalize == enabled) return;
    _ptsNormalize = enabled;
    if (!enabled) resetPtsBase();
    _log('PTS 归一化开关: $enabled');
  }

  /// 🔴🔴 2026-10-17 新增：设置「探测模式」（只测量、不改字节）。
  ///
  /// 与 [setPtsNormalize] 的关系：两者**正交**，可同时为 true
  /// （此时探测日志照打，但字节仍按 `_ptsNormalize` 的实际值处理）。
  /// 典型用法见 [ad_filter_engine.dart]：
  ///   · 裁掉了广告   → setPtsNormalize(true)  + setPtsProbeOnly(false) = 真平移
  ///   · 没裁掉广告   → setPtsNormalize(false) + setPtsProbeOnly(true)  = 只探测
  void setPtsProbeOnly(bool enabled) {
    if (_ptsProbeOnly == enabled) return;
    _ptsProbeOnly = enabled;
    _log('PTS 探测模式: $enabled（只测量不改字节）');
  }

  /// 探测模式下已发现的最大绝对偏差（ms），供上层决定是否升级为真平移。
  int _ptsMaxDriftSeenMs = 0;
  int get ptsMaxDriftSeenMs => _ptsMaxDriftSeenMs;

  /// 装入分段元数据（绝对 URL → 去广告名义轴起点 ms），并重置平移基准。
  ///
  /// 🔴 每次换播放列表**必须**调用：换了列表意味着真实/名义两条轴都换了基准，
  ///    沿用旧基准会让新列表的分片被平移错的值。
  void setSegmentMeta(Map<String, int> meta) {
    _segMeta = Map<String, int>.from(meta);
    resetPtsBase();
    _log('PTS 元数据已装入：${_segMeta.length} 段');
  }

  /// 当前已装入的元数据条数（仅用于日志与排障）。
  int get segmentMetaCount => _segMeta.length;

  /// 重置平移基准与逐段缓存。换源/换集/换列表时必须调用。
  void resetPtsBase() {
    _baseFirstPts = null;
    _baseFiltered = null;
    _lastRequestedFiltered = null;
    _segDeltaCache.clear();
    _segFirstPtsCache.clear();
    _axisLoggedIndex = 0;
    // 🔴 换源必须一并复位「本源 PTS 是否可读」的判定：上一个源读不出 PTS
    //    不代表新源也读不出，否则新源会被错误地永久跳过 PTS 改写。
    _ptsReadable = null;
    _ptsUnreadableStreak = 0;
  }

  void _log(String message) {
    WindowsLogger.log('LocalM3u8Proxy', message);
  }

  /// 节流日志：同一 key 在窗口内只打一次。用于高频路径（每段都会走）避免刷屏。
  final Map<String, DateTime> _throttleStamps = {};
  void _logThrottled(String message, {Duration window = const Duration(seconds: 5)}) {
    final now = DateTime.now();
    final last = _throttleStamps[message];
    if (last != null && now.difference(last) < window) return;
    _throttleStamps[message] = now;
    _log(message);
  }

  /// 计算某分片需要平移的 delta（ms）。0 表示无需平移（透传原字节）。
  ///
  /// 【原理】去广告只删播放列表的**行**，不改分片**字节**。于是：
  ///     · 真实 PTS 轴 = 分片里编码的 PTS（**含广告**的原始时间线）
  ///     · 名义轴     = 去广告后 EXTINF 累加（mpv 的 duration 走这条）
  ///   mpv `time-pos` 走真实轴、`duration` 走名义轴 ⇒ 进度条越播越偏。
  ///
  ///   修法：把每段的 PTS 平移 delta，使 `该段首 PTS + delta == 名义轴起点`。
  ///   以**基准段**（第一个能读到 PTS 的分片）为原点：
  ///     expected(i) = baseFirstPts + (filtered(i) − baseFiltered)
  ///     delta(i)    = expected(i) − firstPts(i)
  ///
  ///   🔴 与鸿蒙的差异：鸿蒙用 `filteredMs = index × 2000`（其源恰为 2s/段），
  ///     本实现一律用 [M3u8AdFilter] 产出的**真实 EXTINF 累加**，避免源段长
  ///     非整 2 秒时引入新的系统性误差。这是 legacy 相对鸿蒙的改进，沿用。
  /// [establishBase] 是否允许本调用建立 PTS 基准。
  ///
  /// 🔴 预取线程必须传 false：基准 `_baseFirstPts` 是**全局单例**（只建立一次），
  ///    而预取与播放器直连是并发的。若预取线程先返回并建立了基准，基准就会落在
  ///    一个「靠后的随机分片」上，此后所有分片的 delta 都相对错误基准计算
  ///    ⇒ 整条时间轴错位。基准只能由**播放器真实请求路径**（直连）建立。
  Future<int> _deltaFor(String segUrl, List<int> bytes,
      {bool establishBase = true}) async {
    // 🔴 探测模式也必须走完整流程：它的全部价值就在「算出 delta 但不施加」，
    //   提前返回会让「源 PTS 是否可信」永远无法判断（这正是 2026-10-17 真机
    //   进度条乱跳的成因）。
    if (!_ptsNormalize && !_ptsProbeOnly) return 0;
    if (_segMeta.isEmpty) return 0;

    // 命中缓存（同一分片可能被 seek 后重复请求）。
    final cached = _segDeltaCache[segUrl];
    if (cached != null) return cached;

    final filtered = _segMeta[segUrl];
    if (filtered == null) {
      // 🔴 查表 miss 是**静默失效**的主要来源（鸿蒙「坑 2」）。
      //   必须打日志，否则表现为「机制装了但完全没生效」而无人察觉。
      _logThrottled('PTS skip: no-meta url=$segUrl');
      return 0;
    }

    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
    final first = firstPesPtsMs(data, videoOnly: true);

    if (first == null) {
      // 🔴🔴 2026-10-16 新增：连续读不出 PTS 时，判定「本源 PTS 不可读」，
      //   让 `_proxySegment` 后续分片改走流式转发，不再付整段缓冲代价。
      //
      //   为什么用「连续计数」而不是「一次判定」：单个分片读不出 PTS 可能是
      //   偶发（切片边界、首包非 PES 等），此时关闭改写会漏掉本该修的偏移。
      //   连续 `_kPtsUnreadableThreshold` 次失败才认定是源级属性。
      //
      //   背景（模拟器日志 Xiaomi 12S Pro.2026101620）：
      //     `no-pts` 349 次 + `no-meta` 1 次 = 350 次 delta 全为 0，
      //     `pts-shift` 的 `len=N->N` 350/350 字节数完全相同 —— 即每个分片
      //     都白付了「整段读进内存 + 主 isolate 往返」，却一个 PTS 都没改。
      //     该开销在主 isolate 上串行累积，是「跳过广告位置卡死、有声音没画面」
      //     的直接原因（详见 `_proxySegment` 内的完整因果注释）。
      _ptsUnreadableStreak++;
      if (_ptsUnreadableStreak >= _kPtsUnreadableThreshold &&
          _ptsReadable != false) {
        _ptsReadable = false;
        _log(
          'PTS 归一化：连续 $_ptsUnreadableStreak 个分片读不出视频 PTS，'
          '判定本源 PTS 不可读 ⇒ 后续分片改走流式转发（不再缓冲改写）',
        );
      }
      _logThrottled('PTS skip: no-pts filtered=${filtered}ms url=$segUrl');
      return 0;
    }
    // 读到 PTS 即证明本源可读，清零计数器并恢复改写路径。
    _ptsUnreadableStreak = 0;
    if (_ptsReadable == null) _ptsReadable = true;
    _segFirstPtsCache[segUrl] = first;

    // 🔴🔴 seek 检测：快退/快进后必须重建基准，否则 delta 按旧基准算会凭空多平移。
    //   详见 `_lastRequestedFiltered` 的字段注释（真机 2026-10-17 实证）。
    if (establishBase) {
      final last = _lastRequestedFiltered;
      if (last != null && (filtered - last).abs() > kPtsBaseReseekGapMs) {
        _log(
          'PTS 基准重建（检测到 seek）：名义轴 ${last}ms → ${filtered}ms '
          '（跳跃 ${(filtered - last).abs()}ms > ${kPtsBaseReseekGapMs}ms）',
        );
        _baseFirstPts = null;
        _baseFiltered = null;
        // 旧缓存是旧基准下的产物，跨基准复用必错。
        _segDeltaCache.clear();
      }
      _lastRequestedFiltered = filtered;
    }

    // 建立基准：第一个能读到 PTS 的分片即原点。
    //
    // 🔴 必须**同时**记住基准段的名义轴起点，理由见 `_baseFiltered` 的字段注释：
    //   只记真实 PTS 会让基准段的名义起点被重复计入，表现为「固定往后偏移」。
    if (_baseFirstPts == null && establishBase) {
      // 🔴🔴🔴 2026-10-18：锚点用**名义值** `filtered`，不用真实值 `first`。
      //
      //   【原写法的问题】`_baseFirstPts = first` ⇒ 基准段 delta 恒为 0，
      //   即**基准段自身从不平移**，它的真实 PTS 被当作正确锚点。
      //   于是基准段自己的轴偏差 Δ = (first − filtered) 被**继承给之后
      //   所有分片**：`expected = first_base + (filtered_n − filtered_base)`，
      //   整条轴 = 基准段真实轴，而非名义轴。
      //
      //   【真机铁证】XiaoPaiTech BA001 2026101817，每次 seek 重建基准：
      //     filtered=431120   first=439360   Δ=+8240ms
      //     filtered=537440   first=551800   Δ=+14360ms
      //     filtered=839480   first=863200   Δ=+23720ms
      //     filtered=1038520  first=1065800  Δ=+27280ms
      //   Δ 随 seek 位置**单调增大** ⇒ 用户「越往后偏移递增」。
      //   这正是历史 10-11 记载的「两条轴速率不同」在基准机制上的具体形态。
      //
      //   【改法】锚点取名义值后：
      //     expected = filtered_base + (filtered_n − filtered_base) = filtered_n
      //   即**每一段（含基准段）都独立对齐到自己的名义轴起点**，
      //   不再继承任何基准偏差。基准段 delta = filtered − first ≠ 0，
      //   也会照常平移。
      //
      //   【安全性】源本就对齐时 Δ=0，delta 仍为 0，行为不变；
      //   只有 Δ≠0 的源才改变，且方向是「更贴合名义轴」。
      _baseFirstPts = filtered;
      _baseFiltered = filtered;
      _log(
        'PTS 基准已建立：baseFiltered=${filtered}ms trueFirst=${first}ms '
        'Δ=${first - filtered}ms baseUrl=$segUrl'
        '（锚点=名义值，基准段也参与对齐）',
      );
    }

    // 🔴 预取线程在基准尚未建立时到达：此时算不出正确 delta（基准还没定），
    //   直接放弃缓存该分片的 delta（返回 0 ⇒ 出口不平移）。
    //   这比「抢建一个错误基准」安全得多 —— 错误基准会污染**所有**分片。
    if (_baseFirstPts == null) {
      _logThrottled('PTS skip: 基准未建立，预取分片不平移 url=$segUrl');
      return 0;
    }

    final expected = _baseFirstPts! + (filtered - _baseFiltered!);
    final delta = expected - first;

    // 🔴🔴 探测模式：记录这里算出的 delta（= 源 PTS 轴相对名义轴的偏差），
    //   但**不施加**。这是判断「源轴是否可信」的唯一依据。
    //
    //   偏差含义：`delta` 是「要让该段首帧 PTS 落到名义轴起点上，需要平移多少」。
    //   一个健康的源，逐段 delta 应当基本恒定（只反映首帧的对齐误差）；
    //   若 delta 逐段剧烈变化（真机实测 28s/−158s/−138s 乱跳），说明源自身的
    //   PTS 轴是断的，此时**必须**启用真平移，否则播放器时间轴跟着乱。
    if (_ptsProbeOnly) {
      final absDelta = delta.abs();
      if (absDelta > _ptsMaxDriftSeenMs) _ptsMaxDriftSeenMs = absDelta;
      _axisLoggedIndex += 1;
      // 节流同 PTS axis：首段必打，其后每 50 段一次；另外只要偏差超过阈值
      //   （说明源轴确实错乱）就立即打一条，不能被节流吞掉。
      final overThreshold = absDelta > _kPtsDriftWarnMs;
      if (_axisLoggedIndex == 1 || _axisLoggedIndex % 50 == 0 || overThreshold) {
        _log(
          'PTS probe: n=$_axisLoggedIndex filtered=${filtered}ms trueFirst=${first}ms '
          'delta=${delta}ms${overThreshold ? ' ⚠️ 超阈值($_kPtsDriftWarnMs ms)，源 PTS 轴不可信' : ''}',
        );
      }
      // 🔴🔴 为什么不在这里「自动升级为真平移」—— 这条捷径看似能立刻纠偏，
      //   实际会制造更严重的跳变，故**刻意不做**：
      //
      //   `_shiftPtsChecked(plain, delta)` 里的 `delta` 是**相对基准段**的量：
      //       expected = _baseFirstPts + (filtered - _baseFiltered)
      //       delta    = expected - first
      //   基准段自身 delta 恒为 0（不打平移）。若基准段已按原字节发出、之后
      //   的分片才加上平移，两组分片的 PTS 轴就错开了一个 delta，播放器在
      //   切换点上会看到**新的突变** —— 等于用一个跳变换掉另一个跳变。
      //
      //   正确修法只有一条：**在起播前就决定要不要平移**，让整条时间轴从
      //   第一个分片起就是同一条轴。落地方式由上层 `ad_filter_engine.dart`
      //   按「首段探测 → 判定 → 若不可信则重建代理并开真平移」的顺序完成。
      //   这里的职责严格限定为「测量并告警」，不越权改状态。
    } else {
      // 埋点：打印两条轴的对照，`residual` 是生效的唯一判据（平移后应恒为 0）。
      //
      // 节流：逐段打印会刷屏（一个点播源上千段）。策略是**首段必打**
      //   （用于确认基准建立正确），其后每 50 段打一次（用于观察漂移趋势）。
      final shifted = first + delta;
      _axisLoggedIndex += 1;
      if (_axisLoggedIndex == 1 || _axisLoggedIndex % 50 == 0) {
        _log(
          'PTS axis: n=$_axisLoggedIndex filtered=${filtered}ms trueFirst=${first}ms '
          'expected=${expected}ms delta=${delta}ms shifted=${shifted}ms '
          'residual=${shifted - expected}ms',
        );
      }
    }

    _segDeltaCache[segUrl] = delta;
    return delta;
  }

  /// 对一段**明文** TS 做 PTS 平移，带自校验；校验失败一律返回原字节。
  ///
  /// 🔴 自校验不可省：[normalizeTsPts] 只改 PTS/DTS/PCR、**不改
  ///    continuity_counter**，一旦包边界判断错位，输出长度不变、无异常、
  ///    无日志 —— 属于静默损坏，播放器只会表现为花屏/音画不同步/时长异常，
  ///    排查成本极高。故写回前用「平移前后首帧 PTS 差 == delta」自证一次。
  ///
  /// 🔴🔴 2026-10-16 记录一次**已被证伪的假设**，避免日后重走弯路：
  ///
  ///   真机日志出现 `mpv[ad] warn: Invalid audio PTS: 983.016775 -> 983.968800`
  ///   后，曾怀疑是本函数对**音频** PES（stream_id 0xC0–0xDF）施加了由视频
  ///   首帧算出的 delta、而这里的自校验写成 `videoOnly: true` 只验视频，
  ///   导致「音频被改坏却无人发觉」。据此还加过一段 `_audioShiftOk()` 追加校验。
  ///
  ///   **该假设已被反证**（荣耀平板 V8 Pro 日志 2026101516）：
  ///     16:25:50 mpv 起播 URL 127.0.0.1:40707 → 3 次 Invalid audio PTS
  ///     16:26:46 exo 起播 **同一个 URL 40707** → 此后 0 次
  ///   两者吃的是**同一份**代理字节流（本文件完全不感知后端类型），
  ///   字节流若真被改坏，exo 必炸。⇒ 字节流无罪，问题在 mpv 侧缓存模式。
  ///
  ///   `_audioShiftOk()` 已随之删除：它会在音视频 PTS 基准正常不同源时
  ///   放弃平移，反而让进度条偏移回归，属净负面改动。
  Uint8List _shiftPtsChecked(Uint8List plain, int deltaMs) {
    if (deltaMs == 0) return plain;
    final shifted = normalizeTsPts(plain, deltaMs);
    final check = verifyPtsShift(plain, shifted, deltaMs, videoOnly: true);
    if (!check.ok) {
      _log(
        'PTS 平移自校验失败，回退原始字节：delta=${deltaMs}ms '
        'before=${check.beforeMs} after=${check.afterMs} reason=${check.reason}',
      );
      return plain;
    }
    return shifted;
  }

  String? get baseUrl {
    final server = _server;
    if (server == null) return null;
    return 'http://${server.address.host}:${server.port}';
  }

  /// 启动本地代理服务器。
  /// 返回代理根地址，例如 http://127.0.0.1:12345
  Future<String> start() async {
    if (_server != null) {
      return baseUrl!;
    }
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
    _client ??= http.Client();
    currentInstance = this;
    _log('LocalM3u8Proxy started at $baseUrl');
    return baseUrl!;
  }

  /// 设置当前播放列表内容与原始请求头。
  ///
  /// [prefetch] 是否开启本源的并发分片预取（由 AdFilterEngine 按开关传入）。
  /// 默认 false，保持主工程历史行为。
  ///
  /// [primeHead] 是否**立即**开始「建索引头部段」预热（mpv 后端专用）。
  ///
  /// 🔴🔴 2026-10-29 真机日志实锤（小米 12S Pro 2026-10-29 22:44）：
  ///   22:44:46.971  AdFilterEngine 拿到完整 media 列表（621 段）
  ///   22:44:49.078  MpvBackend open（**2.1s 之后**）
  ///   22:44:49.2x   mpv 请求 plist0（建索引的**阻塞项**）→ 22:44:51.384 才拿到
  ///   ⇒ 预热若等到 open 才开始，就只能跟 mpv **抢**同一条下载，
  ///     而 mpv 的 plist0 恰恰是整条起播链的阻塞项。
  ///   本次把分片表收集 + 头部段预热**提前到 setPlaylist**（= open 前约 2s），
  ///   plist0 在 mpv 开口前就已备好 ⇒ mpv 首次请求直接命中本地缓存。
  void setPlaylist(String content, Map<String, String> headers,
      {bool prefetch = false, bool primeHead = false}) {
    _playlistContent = content;
    _prefetchEnabled = prefetch;
    // 换源/换集必须重置展开缓存，否则会沿用上一个源展开出的 media playlist。
    _expandedPlaylist = null;
    _expandedAt = null;
    // 代次自增，让仍在途的旧源展开结果作废（见 _playlistGen 注释）。
    _playlistGen++;
    _baseHeaders
      ..clear()
      ..addAll(headers);
    // 🔴 换源/换集必须清空预取缓存，否则新源会命中旧源分片（内容错误）。
    //    与 _playlistGen 自增同理，这里额外清 _segmentUrls 防止旧源分片表污染。
    _clearPrefetchCache();
    // 🔴 2026-10-29：换源后预热目标作废（新源的分片表/下标都不同了）。
    _pendingPrefetchTargetMs = null;
    // 🔴 2026-10-29：**立刻**收集分片表（纯解析，零网络开销），
    //   这样头部段预热能比 mpv 的 open 提前约 2s 开始。
    _collectSegmentUrls(content);
    if (primeHead) {
      _primeHeadSegments(force: true);
    }
  }

  Future<void> stop() async {
    _closing = true;
    // 停止时清空预取缓存并让在途队列退出（_drainPrefetchQueue 会检查 _closing）。
    _clearPrefetchCache();
    await _server?.close(force: true);
    _server = null;
    _playlistContent = null;
    _expandedPlaylist = null;
    _expandedAt = null;
    _playlistGen++;
    _baseHeaders.clear();
    // HttpClient.close() 会等待 pending 请求结束，这里不阻塞关闭流程，
    // 避免应用退出时因正在下载的 segment 而卡顿。
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close();
      } catch (_) {
        // 忽略关闭错误
      }
    }
    _closing = false;
    _log('LocalM3u8Proxy stopped');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final method = request.method.toUpperCase();
      final path = request.uri.path;

      if (method == 'OPTIONS') {
        await _serveCorsPreflight(request);
        return;
      }

      if (path == '/playlist.m3u8') {
        await _servePlaylist(request, isHead: method == 'HEAD');
      } else if (path == '/segment') {
        await _proxySegment(request, isHead: method == 'HEAD');
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found')
          ..close();
      }
    } catch (e, stack) {
      // 🔴 2026-10-23（第八轮）：代理**停止过程中**的在途请求异常属正常收尾，
      // 不再打完整堆栈。
      //
      // 实测（Windows 真机 22:36:31 退出播放页）：`stop()` 里 `client.close()`
      // 会让在途的 segment 请求随即抛
      // `ClientException: Connection closed while receiving data`，
      // 旧实现把 **39 行堆栈**打进日志 —— 真机日志里这个噪音比真正的错误还多，
      // 反而把要紧的行淹掉。
      //
      // 判断条件用 `_client == null`（而不只是 `_closing`）：`stop()` 末尾会把
      // `_closing` 复位成 false，而在途请求的异常回调发生在那**之后**
      // （日志时序：先 "LocalM3u8Proxy stopped"，后 "handleRequest error"）。
      if (_closing || _client == null) {
        _log('LocalM3u8Proxy 请求在代理停止时中断: $e');
      } else {
        _log('LocalM3u8Proxy handleRequest error: $e');
        _log('$stack');
      }
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal server error')
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _serveCorsPreflight(HttpRequest request) async {
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.add('Access-Control-Allow-Origin', '*')
      ..headers.add('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      ..headers.add('Access-Control-Allow-Headers', 'Range, Content-Type')
      ..headers.add('Access-Control-Max-Age', '86400');
    await response.close();
  }

  Future<void> _servePlaylist(
    HttpRequest request, {
    bool isHead = false,
  }) async {
    final content = await _resolvePlaylistContent();
    final bytes = utf8.encode(content);
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
      ..headers.add('Content-Length', bytes.length.toString())
      ..headers.add('Access-Control-Allow-Origin', '*')
      ..headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
    if (!isHead) {
      response.add(bytes);
    }
    await response.close();
  }

  /// 在**最终 media playlist**（分片行已是 `$baseUrl/segment?url=<CDN>` 代理形态）
  /// 上重建 PTS 归一化元数据表。
  ///
  /// 键的形态必须与代理查表时一致：代理是在 `_proxySegment` 里把请求的 `?url=`
  /// 解出**原始 CDN 绝对地址**后调用 `_deltaFor(targetUrl, ...)` 的，所以这里
  /// 也要解出 `?url=` 参数做键，而**不能**用整条代理 URL。
  ///
  /// 值 = 该分片在**去广告名义轴**上的起点（ms），按 `#EXTINF` 累加得到，
  /// 与 `M3u8AdFilter._rebuildSegMeta` 的语义保持一致（这样 mpv 的 duration
  /// 轴与平移目标轴才同源）。
  void _rebuildSegMetaFromProxyPlaylist(String playlist) {
    if (playlist.isEmpty) return;

    final meta = <String, int>{};
    var accMs = 0; // 去广告名义轴累计
    var pendingMs = 0; // 当前 #EXTINF 声明的段长（待消费）
    var hasPending = false;

    for (final raw in playlist.replaceAll('\r\n', '\n').split('\n')) {
      final item = raw.trim();
      if (item.isEmpty) continue;

      if (item.startsWith('#EXTINF:')) {
        final m = RegExp(r'#EXTINF:\s*([0-9.]+)').firstMatch(item);
        final sec = double.tryParse(m?.group(1) ?? '') ?? 0;
        pendingMs = (sec * 1000).round();
        hasPending = true;
        continue;
      }
      if (item.startsWith('#')) continue; // 其余标签不贡献时长

      final cdnUrl = _realUrlOfProxySegment(item);
      if (cdnUrl == null) continue;

      meta[cdnUrl] = accMs;
      accMs += hasPending ? pendingMs : 0;
      hasPending = false;
      pendingMs = 0;
    }

    if (meta.isEmpty) {
      _log('PTS 元数据重建：最终 media 列表未解析出任何分片，保持原表');
      return;
    }

    // 直接写入本对象的表（而非经 M3u8AdFilter 的静态表），因为此处已是
    // 最终形态、无需再过一次绝对化。同时重置基准，避免沿用旧轴的原点。
    _segMeta = meta;
    resetPtsBase();
    _log('PTS 元数据已重建（最终 media 列表）：${_segMeta.length} 段，'
        '名义轴总长=${accMs}ms');
  }

  /// 把 `$baseUrl/segment?url=<encoded CDN>` 还原为原始 CDN 绝对地址。
  /// 非代理形态（例如已是裸 URL）则原样返回；无法解析返回 null。
  static String? _realUrlOfProxySegment(String line) {
    final idx = line.indexOf('url=');
    if (idx < 0) {
      // 不是代理形态：仅接受绝对 http(s) 地址，其余（相对路径）放弃。
      return line.startsWith('http') ? line : null;
    }
    var v = line.substring(idx + 4);
    final amp = v.indexOf('&');
    if (amp >= 0) v = v.substring(0, amp);
    if (v.isEmpty) return null;
    try {
      return Uri.decodeComponent(v);
    } catch (_) {
      return v;
    }
  }

  /// 返回 `playlist.m3u8` 的响应体：master 就地展开为 media（见 `_expandedPlaylist` 注释）。
  Future<String> _resolvePlaylistContent() async {
    final content = _playlistContent ?? '#EXTM3U\n#EXT-X-ENDLIST\n';

    if (!_isMasterPlaylist(content)) {
      // 单级 media playlist：也要收集分片表，否则预取没有可定位的下标
      // （鸿蒙侧踩过：只在 master 分支收集 ⇒ 单级源预取整源失效）。
      // 🔴 2026-10-29：分片表收集**不再**受「连续预取」开关限制。
      //   收集是纯解析（无网络开销），而起播预热（primePrefetchAt）依赖它
      //   把播放位置换算成分片下标 ⇒ 关掉连续预取的用户同样需要它。
      _collectSegmentUrls(content);
      return content;
    }

    // TTL 窗口内直接复用（展开成功用展开结果；失败则退回原 master，不做重试风暴）。
    final at = _expandedAt;
    if (at != null && DateTime.now().difference(at) < _kExpandedTtl) {
      return _expandedPlaylist ?? content;
    }

    final variantUrl = _extractFirstVariantUrl(content);
    if (variantUrl == null) {
      _log('master 展开：未找到变体 URL，保持原样');
      _expandedAt = DateTime.now();
      return content;
    }

    final gen = _playlistGen;
    try {
      final expanded = await _fetchAndRewriteM3u8(variantUrl);
      // 展开期间若已换源/换集，本次结果作废，否则会把上一个源的 media playlist
      // 写进缓存，导致新源播错内容。
      if (gen != _playlistGen) {
        _log('master 展开结果作废（期间已换源）: $variantUrl');
        return _playlistContent ?? content;
      }
      _expandedAt = DateTime.now();
      if (expanded == null || expanded.trim().isEmpty) {
        _log('master 展开失败（下载/重写为空），回退原 master: $variantUrl');
        return _expandedPlaylist ?? content;
      }
      _expandedPlaylist = expanded;
      _log('master 展开为 media（单级）成功: $variantUrl');

      // 🔴🔴 2026-10-15 点播「快进快退越往后越偏」根因修复点。
      //
      // 真机日志铁证（荣耀平板 V8 Pro，2026-10-15 11:34:32）：
      //     [AdFilterEngine] PTS 元数据已重建：1 段      ← 只有 1 条！
      //     [LocalM3u8Proxy] PTS skip: no-meta url=.../1066kb/hls/0An6C6Ko.ts
      //     （此后每一段都是 no-meta，上千次）
      // 即：PTS 归一化开关虽为 true，但 `_segMeta` 里只有 1 条键，与真实
      //     分片 URL 全部对不上 ⇒ `_deltaFor` 恒返回 0 ⇒ `_shiftPtsChecked`
      //     因 `deltaMs == 0` 原样透传 ⇒ **分片字节从未被平移过**。
      //     结果 mpv 的 time-pos 仍走「含广告的真实 PTS 轴」、duration 走
      //     「去广告 EXTINF 名义轴」，两轴速率不同 ⇒ 拖到 10:00 实际落在
      //     10:07 附近，且**偏差随位置单调增大** —— 与用户描述逐字吻合。
      //
      // 为什么上游 `AdFilterEngine` 建不出元数据：它在**绝对化之后、但仍是
      //   master 列表**的文本上调用 `rebuildSegMetaOn(resolved)`。而本站源是
      //   **多级 M3U8**（master → `1066kb/hls/index.m3u8` → `.ts`），master 里
      //   只有一行变体 URL，于是只登记出 1 条（正好就是那个子列表 URL），
      //   真正的 media playlist 是**在本函数内部**才下载展开的。
      //
      // 修法：master 展开成功后**立即**在 `expanded`（最终 media 列表）上
      //   重建元数据。这是全流程中唯一能拿到最终媒体列表的位置。
      //   注意 `_rebuildSegMeta` 依赖 `metaBaseUrl` 产出与 `?url=` 对齐的
      //   绝对键；`_fetchAndRewriteM3u8` 已把分片行改写为**代理绝对 URL**
      //   （`http://127.0.0.1:port/segment?url=...`），而代理侧查表用的是
      //   解出的**原始 CDN 绝对地址**，两者形态不同，故这里必须用
      //   `rebuildSegMetaFromProxyPlaylist` 按 `?url=` 参数解出原始地址做键。
      _rebuildSegMetaFromProxyPlaylist(expanded);
      // 🔴 预取分片表必须在**最终 media 列表**上收集。
      //    与上面 PTS 元数据同理：master 里只有一行变体 URL，在 master 上
      //    收集会得到 1 条（甚至是子列表 URL），`indexOf` 恒为 -1 ⇒ 预取
      //    静默失效。展开后的 `expanded` 才是分片行齐全的 media 列表。
      _collectSegmentUrls(expanded);
      return expanded;
    } catch (e) {
      _log('master 展开异常，回退原 master: $e');
      if (gen == _playlistGen) _expandedAt = DateTime.now();
      return _expandedPlaylist ?? content;
    }
  }

  /// 公开版 [isMasterPlaylistText]：供上游（`AdFilterEngine` 的 PTS 预探测）
  /// 判断「拿到的文本是 master 还是 media」，从而决定是否需要自行展开。
  static bool isMasterPlaylistText(String content) => _isMasterPlaylist(content);

  /// 公开版 [extractFirstVariantUrl]：取第一个变体（子 m3u8）的相对/绝对 URL。
  ///
  /// 🔴 上游拿到的是**原始 CDN 文本**（未经 `rewriteToLocalProxy`），因此返回的
  ///    是原始相对路径，调用方需配合 [resolveRelativeUrls] 或自行解析成绝对地址。
  static String? extractFirstVariantUrl(String content) =>
      _extractFirstVariantUrl(content);

  /// 下载一份播放列表文本（不做去广告、不改写、不加代理前缀）。
  ///
  /// 【为什么不复用 `_fetchAndRewriteM3u8`】那个方法有两个副作用正是探测要避免的：
  ///   ① 会把分片行改写成 `http://127.0.0.1:port/segment?url=...`，探测要的是
  ///      原始 CDN 地址，否则又得反解一遍；
  ///   ② 会跑去广告过滤，导致名义轴与真实源不一致，探测判据失真。
  ///
  /// 【失败返回 null】探测是**尽力而为**的校验，任何网络/解析异常都不能影响起播。
  ///
  /// 【为什么是 5s】探测整体预算 6s（见 `_probeSourcePtsDrift` 里的 Stopwatch），
  ///   而本方法是**串联在取样之前**的一步：`展开(≤5s) + 取样(≤6s)` 的最坏情况
  ///   是 11s，若再放宽就会把起播推过 15s 的 open 超时 —— 历史上正是这样让
  ///   某个源连画面都没出（见 `_fetchAndRewriteM3u8` 里 1401 分片展开 10s 的记录）。
  ///   真机实测本工程源展开耗时 1.1~1.3s，5s 有充足余量。
  ///   超时即放弃展开并退回 master，此时探测会明确报「样本不足」而非「可信」。
  static Future<String?> fetchPlaylistText(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final client = http.Client();
    try {
      final reqHeaders = <String, String>{
        'User-Agent': headers['User-Agent'] ??
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Range': '',
        ...headers,
      }..removeWhere((k, v) => k == 'Range' || v.isEmpty);
      final resp =
          await client.get(Uri.parse(url), headers: reqHeaders).timeout(timeout);
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        WindowsLogger.log('LocalM3u8Proxy',
            ' 播放列表拉取失败 status=${resp.statusCode}: $url');
        return null;
      }
      final text = utf8.decode(resp.bodyBytes, allowMalformed: true);
      return text.trim().isEmpty ? null : text;
    } catch (e) {
      WindowsLogger.log('LocalM3u8Proxy', ' 播放列表拉取异常: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 判定是否为 master playlist。
  ///
  /// 双重条件：含 `#EXT-X-STREAM-INF` **且**不含 `#EXTINF`（master 描述各码率变体，
  /// 没有分片时长标签）。单看 `#EXT-X-STREAM-INF` 不足以判定，避免误展开。
  static bool _isMasterPlaylist(String content) {
    if (!content.contains('#EXT-X-STREAM-INF')) return false;
    for (final line in content.split('\n')) {
      if (line.trim().startsWith('#EXTINF')) return false;
    }
    return true;
  }

  /// 取第一个 `#EXT-X-STREAM-INF` 后紧跟的变体 URL 行（跳过注释与空行）。
  ///
  /// 注意：`setPlaylist` 传入的内容已由 `rewriteToLocalProxy` 重写过，故该变体 URL
  /// 通常是本地代理形式 `http://127.0.0.1:port/segment?url=<encoded cdn url>`；
  /// 也兼容仍是原始 CDN URL 的情况。
  static String? _extractFirstVariantUrl(String content) {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (!trimmed.startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty) continue;
        if (next.startsWith('#')) break; // 遇到下一个标签，说明本变体行缺失
        return next;
      }
      break;
    }
    return null;
  }

  /// 下载并重写一个 M3U8（去广告 → 解析相对路径 → 重写分片走本地代理）。
  ///
  /// 与 `_proxySegment` 的子 M3U8 分支保持同一套处理，确保展开出的 media playlist
  /// 与「libmdk 自己请求子 m3u8」时拿到的内容完全一致（含 `hseg` 重编号与 AES 解密参数）。
  Future<String?> _fetchAndRewriteM3u8(String rawUrl) async {
    // 变体 URL 可能是本地代理形式（/segment?url=），需解出真实 CDN 地址：
    // 一来下载要走 CDN，二来相对分片路径必须基于 CDN 地址解析。
    final targetUrl = _unwrapProxyUrl(rawUrl);
    final headers = _segmentRequestHeaders(targetUrl);
    // 播放列表必须取完整内容，不能带 Range（否则拿到 206 部分内容，时长计算错误）。
    headers.remove('Range');

    final client = _client ?? http.Client();
    // 超时必须**远小于**播放器的 open 超时（`openTimeout`，默认 15s）：本方法是
    // libmdk 打开 playlist 时的**同步等待**调用，展开耗时会被原样加到起播耗时里。
    // 实测（2026-09-26 日志）：源1（944 分片）展开仅 1s，但源4（1401 分片）展开
    // 耗了 **10s**，叠加其后 initialize 共约 16s → 越过 15s 上限 → `播放失败`，
    // 该源连画面都没出。
    //
    // 🔴 2026-10-15：3s → 8s。
    //    真机实证（荣耀平板 17:56:07）：首次冷启动拉取变体列表超过 3s 硬超时
    //    ⇒ `master 展开异常：TimeoutException after 0:00:03.000000`
    //    ⇒ 回退原 master ⇒ exo 播放失败（4 次中 1 次，系统自动回退 mpv 后正常）。
    //    放宽到 8s 后仍有余量：8s 展开 + initialize 不至于稳超上层 15s 上限
    //    （见 mobile/player_screen.dart:1265），且超时仍回退原 master，
    //    行为不劣于引入展开之前。
    final sw = Stopwatch()..start();
    final resp = await client
        .get(Uri.parse(targetUrl), headers: headers)
        .timeout(const Duration(seconds: 8));
    final dlMs = sw.elapsedMilliseconds;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _log('master 展开：拉取变体 $targetUrl 返回 ${resp.statusCode}');
      return null;
    }

    final decoded = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final filterSw = Stopwatch()..start();
    final filtered = _filterEnabled
        ? _filterM3u8(
            targetUrl,
            decoded,
            cleanDiscontinuities: _discontinuityCleanup,
          )
        : decoded;
    final filterMs = filterSw.elapsedMilliseconds;
    final resolved = resolveRelativeUrls(filtered, targetUrl);
    final rewritten = rewriteToLocalProxy(
      resolved,
      baseUrl!,
      renumberSegments: _fvpRenumber,
    );
    // 分开记录「下载」「过滤」「重写」三段耗时：慢在网络还是慢在本地处理
    // （分片数越多处理越久），下次据此判断该收紧超时还是该优化重写。
    //
    // 🔴 2026-10-15：由「下载 + 处理」两段细化为三段。鸿蒙侧 hilog 实测
    //    `处理 410ms` 中 `M3u8AdFilter cost: 391ms` 占 95%，证明处理耗时的
    //    主体是**过滤**而非重写；不拆开就无法判断该优化哪一步。
    _log('master 展开：下载 ${dlMs}ms + 过滤 ${filterMs}ms + 重写 '
        '${sw.elapsedMilliseconds - dlMs - filterMs}ms，${resp.bodyBytes.length} 字节');
    return rewritten;
  }

  /// 把本地代理形式的 URL（`$baseUrl/segment?url=...`）还原为真实 CDN URL。
  String _unwrapProxyUrl(String url) {
    final base = baseUrl;
    if (base == null) return url;
    if (!url.startsWith('$base/segment')) return url;
    try {
      final inner = Uri.parse(url).queryParameters['url'];
      if (inner != null && inner.isNotEmpty) return inner;
    } catch (_) {
      // 解析失败则按原样使用
    }
    return url;
  }

  Future<void> _proxySegment(HttpRequest request, {bool isHead = false}) async {
    final urlParam = request.uri.queryParameters['url'];
    if (urlParam == null || urlParam.isEmpty) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing url')
        ..close();
      return;
    }

    final targetUrl = Uri.decodeComponent(urlParam);

    // 🔴 预取缓存命中：直接返回，不再回源（HEAD 请求不消费缓存，
    //    因为预取存的是 GET 整段语义，且 HEAD 常用于探测，回源更安全）。
    if (!isHead && _prefetchEnabled) {
      if (_servePrefetched(request, targetUrl)) {
        return;
      }
    }

    // fvp 专属：若分片被标记为 AES-128 加密（由 rewriteToLocalProxy 注入
    // &decrypt=aes128&key=&iv=），代理侧取 key 并逐段做 AES-128-CBC 解密，
    // 把明文吐给 fvp，绕过 libmdk 对“经本地代理的 AES-128 HLS”解密卡死的缺陷。
    final decryptParam = request.uri.queryParameters['decrypt'];
    if (decryptParam == 'aes128') {
      final keyParam = request.uri.queryParameters['key'];
      final ivParam = request.uri.queryParameters['iv'];
      if (keyParam == null || ivParam == null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('Missing decrypt params')
          ..close();
        return;
      }
      await _proxyDecryptedSegment(
        request,
        isHead: isHead,
        targetUrl: targetUrl,
        keyUri: Uri.decodeComponent(keyParam),
        iv: _hexToBytes(ivParam),
      );
      return;
    }

    // 透传调用方设置的所有请求头（含鉴权 token / Cookie / 自定义头），
    // 确保分片请求与播放列表请求使用一致的头部。否则部分 CDN 在分片阶段
    // 因缺头被拒，表现为“出一下声音后无画面、卡死”（首段常已被放行/缓存）。
    final headers = _segmentRequestHeaders(targetUrl);

        // 透传 Range，但 M3U8 播放列表必须获取完整内容才能正确计算总时长，
        // 否则播放器收到 206 部分响应会导致进度条/时长显示异常。
        // ⚠️ 旧逻辑用 contains('/hls/') 判定 playlist，会把 /hls/ 下的 .ts 分片
        // 误判为 playlist 而丢弃 Range → fvp 无法在分片内 seek/续拉，弱机每次
        // 重缓冲都要整段重下，是 tvLegacy 等弱机「幻灯片式卡顿」的诱因之一。
        // 改为按扩展名精确判定：playlist(.m3u8/.m3u 或无扩展名)才跳过 Range，
        // 媒体分片(.ts/.mp4/.m4s/...)一律透传 Range。
        final isPlaylistUrl = _isPlaylistUrl(targetUrl);
        final range = request.headers.value('range');
        if (range != null && range.isNotEmpty && !isPlaylistUrl) {
          headers['Range'] = range;
        }

      try {
        final requestMethod = isHead ? 'HEAD' : 'GET';
        final requestUri = Uri.parse(targetUrl);
        final client = _client ?? http.Client();
        // 🔴 2026-10-29：起播预热命中 ⇒ 用本地字节伪造响应顶替回源（省一次 RTT）。
        //   字节完全相同，下面的 PTS 归一化 / Range / 状态码逻辑一行不改。
        final primed = await _primedSegmentResponse(targetUrl);
        _log('proxySegment request: $targetUrl${primed != null ? ' (预热命中)' : ''}');
        final streamed = primed ??
            await client
                .send(http.Request(requestMethod, requestUri)..headers.addAll(headers))
                .timeout(const Duration(seconds: 30));

        final out = request.response;
        out.statusCode = streamed.statusCode;

        final contentType = streamed.headers['content-type'];
        if (contentType != null && contentType.isNotEmpty) {
          out.headers.contentType = _parseContentType(contentType);
        }
        final acceptRanges = streamed.headers['accept-ranges'];
        if (acceptRanges != null && acceptRanges.isNotEmpty) {
          out.headers.add('Accept-Ranges', acceptRanges);
        }
        final contentRange = streamed.headers['content-range'];
        if (contentRange != null && contentRange.isNotEmpty) {
          out.headers.add('Content-Range', contentRange);
        }
        out.headers.add('Access-Control-Allow-Origin', '*');
        out.headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');

        if (isHead) {
          await out.close();
          return;
        }

        // 仅按 content-type 判定 M3U8（可靠且无需缓冲整段）：是则缓冲后重写分片地址，
        // 否则（裸流/媒体分片）流式转发，避免整段缓冲导致内存暴涨或卡死。
        final isM3u8 = _isM3u8ContentType(contentType);
        if (streamed.statusCode >= 200 &&
            streamed.statusCode < 300 &&
            isM3u8) {
          final bytes = await streamed.stream.toBytes();
          final decoded = utf8.decode(bytes, allowMalformed: true);
          _log(
            'proxySegment sub-m3u8 raw: $targetUrl\n${_summarizeContent(decoded)}',
          );
          final filtered = _filterEnabled
              ? _filterM3u8(
                  targetUrl,
                  decoded,
                  cleanDiscontinuities: _discontinuityCleanup,
                )
              : decoded;
          final resolved = resolveRelativeUrls(filtered, targetUrl);
          final rewritten = rewriteToLocalProxy(
            resolved,
            baseUrl!,
            renumberSegments: _fvpRenumber,
          );
          out.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          final encoded = utf8.encode(rewritten);
          out.headers.set('Content-Length', encoded.length.toString());
          out.add(encoded);
          _log(
            'proxySegment sub-m3u8 rewritten: $targetUrl\n${_summarizeContent(rewritten)}',
          );
        } else if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
          // 非 M3U8：裸流/媒体分片。
          //
          // 🔴 两条路径，按是否开启 PTS 归一化选择：
          //   · 关闭（默认，主工程历史行为）：**流式转发**，不整段缓冲。
          //     这是刻意的——注释见下，整段缓冲对长分片/大码率源有内存风险。
          //   · 开启：必须先**整段缓冲**才能改写 PTS（PTS 平移依赖分片内所有
          //     PES 的连续性，边流边改会切断这个前提）。
          //   故把缓冲代价限制在「用户确实需要修偏移」的场景内。
          // 🔴 探测模式同样需要整段缓冲 —— 它的目的就是「拿到完整分片去解析
          //   首帧 PES PTS」，流式转发根本读不到。代价与真平移相同，但换来的是
          //   「源 PTS 是否可信」这个判断依据。上层只在「没裁掉广告」时启用，
          //   属于该场景下唯一能发现源轴错乱的手段。
          if ((_ptsNormalize || _ptsProbeOnly) && _segMeta.isNotEmpty) {
            // 🔴🔴 2026-10-16 修复「跳过广告位置卡死 / 有声音没画面」：
            //
            // 【根因】原实现无条件走「整段缓冲 → 算 delta → 改写 PTS」：
            //     final buffered = await streamed.stream.toBytes();
            //     final delta = await _deltaFor(targetUrl, buffered);
            // 但 `_deltaFor` 内部要 `firstPesPtsMs(data, videoOnly: true)`，
            // 对**读不出视频 PES 起始码**的源（某些 CDN 分片封装/加密/切片
            // 方式导致 TS 包探测失败），该函数恒返回 null ⇒ delta 恒为 0 ⇒
            // `_shiftPtsChecked(plain, 0)` 在首行 `if (deltaMs == 0) return plain;`
            // 直接返回原字节。
            //
            // 实测（**真机与模拟器完全一致**）：
            //   · 真机 BA001：`no-pts` 531 + `no-meta` 1 = 532 次 delta 全 0，
            //     `pts-shift` 的 `len=N->N` **532/532 字节数完全相同**
            //   · 模拟器：`no-pts` 349 + `no-meta` 1 = 350 次，**350/350 相同**
            //   · 两者「PTS 平移自校验失败」均为 0 次（根本没走到改写）
            // 即：**真机也在为这套改写付全额代价（整段缓冲 + 主 isolate 往返），
            // 只是它单分片快、追得上播放，才没暴露成卡死。**
            //
            // 【为何表现为卡死】该路径全程在主 isolate 上串行执行，分片
            // 150~480KB 一个接一个，中间没有让出。模拟器（x86_64 翻译层）单分片
            // 耗费 100~800ms，处理速度追不上播放 ⇒ 主 isolate 长期无空闲 ⇒
            // Flutter 无法提交渲染帧 ⇒ 画面停住；而音频走 native mpv 独立线程，
            // 不受影响 ⇒ **「有声音、没画面」**。
            // ⇒ 这是真实的性能边界，不是模拟器专属缺陷；换一台更弱的盒子
            //   （或更大码率的源）真机同样会卡。
            //
            // 【修法】源级短路：同一源的分片封装方式一致，PTS 可读与否是
            //   **源级别的属性**，不是逐分片属性。故一旦确认「本源 PTS 不可读」，
            //   后续所有分片直接走流式转发，不再逐个付缓冲代价。
            //   判定发生在 `_deltaFor` 的 `no-pts` 分支（连续失败计数）。
            if (_ptsReadable == false) {
              final len2 = streamed.contentLength;
              if (len2 != null) out.headers.set('Content-Length', len2.toString());
              _logThrottled(
                'proxySegment stream (本源 PTS 不可读，跳过缓冲改写): $targetUrl',
              );
              await out.addStream(streamed.stream);
              await out.close();
              _schedulePrefetch(targetUrl);
              return;
            }
            final buffered = await streamed.stream.toBytes();
            final delta = await _deltaFor(targetUrl, buffered);
            // 🔴 记下本分片的 delta，供 `_servePrefetched` 出口施加同样的平移。
            //    预取缓存存的是**原始字节**，若出口不补平移，命中缓存的分片
            //    会与直连分片 PTS 轴不一致 —— 表现为「预取命中后进度条跳变」。
            //    且 `_deltaFor` 会走网络探测，出口是同步路径不能再调，故必须缓存 delta。
            _prefetchDelta[targetUrl] = delta;
            final shifted = _shiftPtsChecked(buffered, delta);
            out.headers.set('Content-Length', shifted.length.toString());
            out.add(shifted);
            _logThrottled(
              'proxySegment pts-shift: $targetUrl status=${streamed.statusCode} '
              'len=${buffered.length}->${shifted.length}',
            );
            // 拿到当前分片后，预取其后的 N 个（串行队列，见 _schedulePrefetch）。
            _schedulePrefetch(targetUrl);
            await out.close();
            return;
          }
          final len = streamed.contentLength;
          if (len != null) out.headers.set('Content-Length', len.toString());
          _log('proxySegment stream: $targetUrl status=${streamed.statusCode}');
          await out.addStream(streamed.stream);
          await out.close();
          // 流式转发分支同样要触发预取：PTS 归一化默认关闭，若只在上一个
          // 分支调度，则默认配置下预取永远不会启动。
          _schedulePrefetch(targetUrl);
          return;
        } else {
          // 非 2xx：仍尽量转发错误体摘要，便于排查 404/403。
          final preview = await streamed.stream
              .transform(utf8.decoder)
              .take(200)
              .join();
          _log(
            'proxySegment error response: $targetUrl status=${streamed.statusCode} '
            'bodyPreview=$preview',
          );
          out.headers.set('Content-Length', preview.length.toString());
          out.add(utf8.encode(preview));
        }
        await out.close();
    } catch (e, stack) {
      if (!_closing) {
        _log('LocalM3u8Proxy proxySegment error: $e');
        _log('$stack');
      }
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('Proxy error')
          ..close();
      } catch (_) {}
    }
  }

  // ===== fvp 专属：代理侧 AES-128-CBC 解密 =====

  /// 构造分片请求头（与播放列表请求一致，含 Referer/Origin/User-Agent 等）。
  Map<String, String> _segmentRequestHeaders(String targetUrl) {
    final targetUri = Uri.parse(targetUrl);
    final headers = Map<String, String>.from(_baseHeaders);
    headers['User-Agent'] = _baseHeaders['User-Agent'] ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
    headers['Accept'] = '*/*';
    headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    headers['Connection'] = 'keep-alive';
    var referer = _baseHeaders['Referer'] ?? _baseHeaders['referer'];
    var origin = _baseHeaders['Origin'] ?? _baseHeaders['origin'];
    if (referer == null || referer.isEmpty) {
      referer = '${targetUri.scheme}://${targetUri.host}/';
      origin = '${targetUri.scheme}://${targetUri.host}';
    }
    headers['Referer'] = referer;
    if (origin != null && origin.isNotEmpty) {
      headers['Origin'] = origin;
    }
    return headers;
  }

  /// 取/缓存 AES-128 key（按 key URI 缓存，避免每段重复拉取）。
  Future<Uint8List> _getAesKey(http.Client client, String keyUri) async {
    final cached = _aesKeyCache[keyUri];
    if (cached != null) return cached;
    final uri = Uri.parse(keyUri);
    final req = http.Request('GET', uri);
    req.headers.addAll(_segmentRequestHeaders(keyUri));
    final resp = await client.send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('AES key HTTP ${resp.statusCode}');
    }
    final bytes = await resp.stream.toBytes();
    _aesKeyCache[keyUri] = bytes;
    return bytes;
  }

  /// fvp 专属：代理侧对单个 AES-128 加密分片做 CBC 解密后吐明文。
  ///
  /// 逻辑与 plan/aes_verify.py 离线验证逐字节对齐（地面真值 cryptography）：
  /// - 支持 fvp 的非块对齐 Range：向前取一块密文作 IV 源，解密后按请求区间切片；
  /// - 仅当 Range 覆盖段尾（最后一块）时做 PKCS7 去填充，恢复原始明文。
  Future<void> _proxyDecryptedSegment(
    HttpRequest request, {
    required bool isHead,
    required String targetUrl,
    required String keyUri,
    required Uint8List iv,
  }) async {
    final out = request.response;
    final client = _client ?? http.Client();

    late final Uint8List key;
    try {
      key = await _getAesKey(client, keyUri);
    } catch (e) {
      _log('AES key fetch failed: $keyUri -> $e');
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Key fetch failed')
        ..close();
      return;
    }
    if (key.length != 16) {
      _log('AES key length invalid: ${key.length} (expect 16)');
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Key length invalid')
        ..close();
      return;
    }

    // 解析 fvp 的 Range（bytes=START-END / START- / -SUFFIX）。
    final range = request.headers.value('range');
    final bool hasRange;
    int start;
    int end;
    if (range != null && range.startsWith('bytes=')) {
      hasRange = true;
      final parts = range.substring(6).split('-');
      if (parts.length == 2 && parts[1].isNotEmpty) {
        start = int.parse(parts[0]);
        end = int.parse(parts[1]);
      } else if (parts.length == 2) {
        start = int.parse(parts[0]); // bytes=START- ：末尾占位
        end = -1;
      } else {
        start = -int.parse(parts[0]); // bytes=-SUFFIX ：末尾 N 字节
        end = -1;
      }
    } else {
      hasRange = false;
      start = 0;
      end = -1;
    }

    // 🔴 2026-10-29：起播预热命中 ⇒ 直接用本地密文，省掉一次回源往返。
    //   解密 / PTS 平移 / Range 切片 / 状态码逻辑**一行不改**（字节完全相同）。
    //
    //   【为什么这一步是关键】旧预取是「回源 CDN、存密文」，而解密分支
    //   **从不查询预取缓存** ⇒ 加密源上预取整源静默失效。真机日志
    //   （小米 12S Pro 2026-10-29 21:31）「收集分片 621 个」之后
    //   一条「命中并缓存」都没有，就是这么来的。
    final primed = await _awaitPrimedSegment(targetUrl);
    late final Uint8List cipher;
    if (primed != null) {
      _log('Prime: 解密分支命中预热密文 ${primed.length} bytes $targetUrl');
      if (isHead) {
        // HEAD 仅回头部，不解密；长度取 Content-Length。
        final headTotal = primed.length;
        out
          ..statusCode = hasRange ? HttpStatus.partialContent : HttpStatus.ok
          ..headers.contentType = ContentType('video', 'mp2t')
          ..headers.add('Access-Control-Allow-Origin', '*')
          ..headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
        if (hasRange && headTotal > 0) {
          final s = start < 0 ? (headTotal + start).clamp(0, headTotal - 1) : start;
          final e = (end < 0 || end > headTotal - 1) ? headTotal - 1 : end;
          out.headers.set('Content-Range', 'bytes $s-$e/$headTotal');
          out.headers.add('Accept-Ranges', 'bytes');
          out.headers.set('Content-Length', (e - s + 1).toString());
        } else if (headTotal > 0) {
          out.headers.set('Content-Length', headTotal.toString());
        }
        await out.close();
        return;
      }
      cipher = primed;
    } else {
      final streamed = await client
          .send(http.Request(isHead ? 'HEAD' : 'GET', Uri.parse(targetUrl))
            ..headers.addAll(_segmentRequestHeaders(targetUrl)))
          .timeout(const Duration(seconds: 30));
      if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
        out
          ..statusCode = HttpStatus.badGateway
          ..write('Segment fetch failed ${streamed.statusCode}')
          ..close();
        return;
      }

      if (isHead) {
        // HEAD 仅回头部，不解密；长度取 Content-Length（可能缺失）。
        final total = streamed.contentLength ?? 0;
        out
          ..statusCode = hasRange ? HttpStatus.partialContent : HttpStatus.ok
          ..headers.contentType = ContentType('video', 'mp2t')
          ..headers.add('Access-Control-Allow-Origin', '*')
          ..headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
        if (hasRange && total > 0) {
          final s = start < 0 ? (total + start).clamp(0, total - 1) : start;
          final e = (end < 0 || end > total - 1) ? total - 1 : end;
          out.headers.set('Content-Range', 'bytes $s-$e/$total');
          out.headers.add('Accept-Ranges', 'bytes');
          out.headers.set('Content-Length', (e - s + 1).toString());
        } else if (total > 0) {
          out.headers.set('Content-Length', total.toString());
        }
        await out.close();
        return;
      }

      // GET：读完整密文（块对齐，长度即明文长度），本地切片/解密。
      cipher = await streamed.stream.toBytes();
    }
    final total = cipher.length;
    if (start < 0) start = (total + start).clamp(0, total - 1);
    if (end < 0 || end > total - 1) end = total - 1;

    const bs = 16;
    // 块对齐：fetchStart 回退一块作为 IV 源；fetchEnd 推进到块边界保证最后一块完整。
    var fetchStart = (start ~/ bs) * bs;
    if (fetchStart > 0) fetchStart -= bs;
    if (fetchStart < 0) fetchStart = 0;
    var fetchEnd = ((end ~/ bs) + 1) * bs - 1;
    if (fetchEnd > total - 1) fetchEnd = total - 1;

    final cipherBlock = cipher.sublist(fetchStart, fetchEnd + 1);
    final firstProcessedOffset = (fetchStart == 0) ? 0 : bs;
    final ivFirst = (fetchStart == 0) ? iv : cipherBlock.sublist(0, bs);

    final cbc = CBCBlockCipher(AESFastEngine());
    cbc.init(false, ParametersWithIV(KeyParameter(key), ivFirst));
    final plain = Uint8List(cipherBlock.length - firstProcessedOffset);
    var outOff = 0;
    for (var off = firstProcessedOffset;
        off + bs <= cipherBlock.length;
        off += bs) {
      cbc.processBlock(cipherBlock, off, plain, outOff);
      outOff += bs;
    }

    // 请求区间映射到 plain 下标。
    var pStart = start - fetchStart - firstProcessedOffset;
    var pEnd = end - fetchStart - firstProcessedOffset;
    if (pStart < 0) pStart = 0;
    if (pEnd >= plain.length) pEnd = plain.length - 1;

    // 仅当覆盖段尾（最后一块）时做 PKCS7 去填充。记下填充长度，后面要把
    // Content-Range 的总长换算成**明文**总长（见下方注释）。
    int? removedPad;
    if ((!hasRange || end >= total - 1) && plain.isNotEmpty) {
      final pad = plain[plain.length - 1];
      if (pad >= 1 && pad <= bs) {
        final unpaddedLen = plain.length - pad;
        if (pEnd >= unpaddedLen) pEnd = unpaddedLen - 1;
        removedPad = pad;
      }
    }

    // 🔴🔴 PTS 归一化必须作用在**整段明文**上，不能只改请求到的区间。
    //
    // 理由：PTS 平移依赖「分片内所有 PES 连续性」这一前提，且 delta 是按段
    //   首帧 PTS 算出来的——若只对 Range 切出的片段改字节，等于用整段的基准
    //   去改局部，且切片边界会把 PES 头截断，结果是静默损坏（长度不变、无报错）。
    // 故：先对 plain 整段平移，再按原区间切片。平移长度不变，故下面的
    //   pStart/pEnd/bodyStartAbs/bodyEndAbs 全部仍然成立，无需调整坐标。
    final shiftedPlain = _ptsNormalize
        ? _shiftPtsChecked(plain, await _deltaFor(targetUrl, plain))
        : plain;

    final body = shiftedPlain.sublist(pStart, pEnd + 1);

    // ⚠️ 这两个头必须用**同一套坐标**，否则 ffmpeg 会在读到分片末尾时报
    // `Stream ends prematurely at X, should be Y`（X=实际读到字节、Y=声明的
    // filesize）并返回 EOF；实测该源每个加密分片都触发一次（2026-09-26 日志
    // 93 次，而走普通透传的未加密源为 0 次），且 ffmpeg 可能因此反复重开同一分片。
    //
    // 此前 Content-Range 写的是 `bytes $start-$end/$total`（**密文**坐标），而
    // Content-Length 写的是 body.length（**去填充后的明文**长度）：两者相差
    // PKCS7 填充字节数（实测 8 字节，例：声明 497456 / 实收 497448），且
    // ffmpeg 会优先采用 Content-Range 的 total 作为 filesize，于是必然报错。
    //
    // AES-CBC 不改变字节位置、PKCS7 填充只在末尾，所以区间起止用绝对偏移即可；
    // 只有**总长**需要减掉填充。
    final plainTotal = removedPad != null ? total - removedPad : total;
    final bodyStartAbs = fetchStart + firstProcessedOffset + pStart;
    final bodyEndAbs = fetchStart + firstProcessedOffset + pEnd;

    out.statusCode = hasRange ? HttpStatus.partialContent : HttpStatus.ok;
    out.headers.contentType = ContentType('video', 'mp2t');
    out.headers.add('Access-Control-Allow-Origin', '*');
    out.headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
    if (hasRange) {
      out.headers.set(
          'Content-Range', 'bytes $bodyStartAbs-$bodyEndAbs/$plainTotal');
      out.headers.add('Accept-Ranges', 'bytes');
    }
    out.headers.set('Content-Length', body.length.toString());
    out.add(body);
    await out.close();
    _log('proxyDecryptedSegment: $targetUrl -> '
        'decrypted bytes=${body.length} range=$hasRange '
        'plainTotal=$plainTotal pad=${removedPad ?? 0}');
  }

  static bool _isM3u8ContentType(String? contentType) {
    if (contentType == null) return false;
    final ct = contentType.toLowerCase();
    return ct.contains('mpegurl') ||
        ct.contains('m3u8') ||
        ct.contains('application/vnd.apple.mpegurl') ||
        ct.contains('audio/x-mpegurl');
  }

  /// 判定目标地址是否为 HLS 播放列表（而非媒体分片）。
  ///
  /// 仅播放列表需要获取完整内容以正确计算总时长，故代理跳过 Range；
  /// 媒体分片（.ts/.m4s/.mp4/...）一律透传 Range，以支持分片内 seek/续拉，
  /// 避免弱机每次重缓冲都整段重下（tvLegacy「幻灯片式卡顿」的诱因之一）。
  /// ⚠️ 不可用 contains('/hls/') 粗判：/hls/ 下的 .ts 分片会被误判为 playlist 而
  /// 丢弃 Range，导致 fvp/ExoPlayer 无法分片内 seek/续拉。
  static bool _isPlaylistUrl(String url) {
    final lower = url.toLowerCase();
    // 明确的 playlist 扩展名。
    if (lower.contains('.m3u8') || lower.contains('.m3u')) return true;
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? '';
    final lastSegment =
        path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
    // 无扩展名（如 master playlist 或 /hls/xxx 形式）→ 当作播放列表。
    if (!lastSegment.contains('.')) return true;
    // 已知媒体分片扩展名 → 不是播放列表，透传 Range。
    const mediaExts = [
      '.ts',
      '.m4s',
      '.mp4',
      '.m4a',
      '.aac',
      '.vtt',
      '.webm',
      '.mkv',
      '.flv',
      '.avi',
      '.mov',
      '.key',
    ];
    for (final ext in mediaExts) {
      if (lastSegment.endsWith(ext)) return false;
    }
    // 其他带扩展名的（未知类型），保守当作播放列表（跳过 Range）。
    return true;
  }

  /// 将 M3U8 内容中的相对 URL 根据 [baseUrl] 解析为绝对 URL。
  static String resolveRelativeUrls(String content, String baseUrl) {
    final baseUri = Uri.parse(baseUrl);
    final lines = content.split('\n');
    final result = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          !trimmed.startsWith('data:') &&
          !trimmed.startsWith('http://') &&
          !trimmed.startsWith('https://')) {
        result.add(baseUri.resolve(trimmed).toString());
        continue;
      }

      // 处理 URI="..." 标签
      if (_hasUriAttribute(trimmed)) {
        result.add(_resolveUriLine(baseUrl, raw));
        if (trimmed.startsWith('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
          final nextRaw = lines[i + 1];
          final nextTrimmed = nextRaw.trim();
          if (nextTrimmed.isNotEmpty &&
              !nextTrimmed.startsWith('#') &&
              !nextTrimmed.startsWith('data:') &&
              !nextTrimmed.startsWith('http://') &&
              !nextTrimmed.startsWith('https://')) {
            result.add(baseUri.resolve(nextTrimmed).toString());
            i++;
            continue;
          }
        }
        continue;
      }

      result.add(raw);
    }

    return result.join('\n');
  }

  static bool _hasUriAttribute(String line) {
    return line.startsWith('#EXT-X-KEY') ||
        line.startsWith('#EXT-X-MAP') ||
        line.startsWith('#EXT-X-MEDIA') ||
        line.startsWith('#EXT-X-PART') ||
        line.startsWith('#EXT-X-PRELOAD-HINT') ||
        line.startsWith('#EXT-X-SESSION-DATA') ||
        line.startsWith('#EXT-X-SESSION-KEY') ||
        line.startsWith('#EXT-X-RENDITION-REPORT') ||
        line.startsWith('#EXT-X-CONTENT-STEERING');
  }

  /// 取 M3U8/文本内容前若干行用于诊断，避免日志过大。
  static String _summarizeContent(String content, {int maxLines = 20}) {
    final lines = content.split('\n');
    final head = lines.take(maxLines).join('\n');
    if (lines.length <= maxLines) return head;
    return '$head\n... (${lines.length} 行)';
  }

  static String _resolveUriLine(String base, String line) {
    final uriPattern = RegExp(r'URI="([^"]+)"');
    return line.replaceAllMapped(uriPattern, (match) {
      final original = match.group(1)!;
      try {
        return 'URI="${Uri.parse(base).resolve(original).toString()}"';
      } catch (_) {
        return match.group(0)!;
      }
    });
  }

  /// 十六进制字符串 → 字节（自动去掉 0x 前缀）。
  static Uint8List _hexToBytes(String hex) {
    final s = hex.startsWith('0x') || hex.startsWith('0X')
        ? hex.substring(2)
        : hex;
    final n = s.length ~/ 2;
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return b;
  }

  /// 字节 → 十六进制字符串（小写）。
  static String _bytesToHex(Uint8List b) {
    final sb = StringBuffer();
    for (final byte in b) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// HLS 默认 IV（无 IV 属性时）：IV[0:8)=0，IV[8:16)=大端媒体序列号。
  /// 与 ExoPlayer / libmdk 的默认 IV 推导一致。
  static Uint8List _ivFromSeq(int seq) {
    final b = Uint8List(16);
    // 仅取低 8 字节放入序列号；超高序列号做掩码避免溢出。
    final s = seq & 0xFFFFFFFFFFFFFFFF;
    for (var i = 0; i < 8; i++) {
      b[15 - i] = (s >> (8 * i)) & 0xFF;
    }
    return b;
  }

  ContentType? _parseContentType(String value) {
    try {
      final parts = value.split(';');
      final mime = parts[0].trim();
      final mimeParts = mime.split('/');
      if (mimeParts.length == 2) {
        var charset;
        for (final part in parts.skip(1)) {
          final kv = part.trim().split('=');
          if (kv.length == 2 && kv[0].toLowerCase() == 'charset') {
            charset = kv[1].trim();
          }
        }
        return ContentType(mimeParts[0], mimeParts[1], charset: charset);
      }
    } catch (_) {}
    return null;
  }

  /// 将 M3U8 内容中的所有资源 URL 重写为本地代理地址。
  ///
  /// [renumberSegments] 为 true 时（仅 fvp 后端）额外做两件事：
  /// 1. 丢弃所有 `#EXT-X-DISCONTINUITY` 标记——结构性断点会让 libmdk 重置时间轴，
  ///    且跨断点复用同名分片正是 fvp 卡死的根因；VOD/Live 均按连续时间轴播放更稳。
  /// 2. 给每个分段代理 URL 注入全局唯一序号 `&hseg=N`，使 libmdk 不会因
  ///    「跨 discontinuity 复用 plist0.ts」而命中段缓存、停止续预取。
  static String rewriteToLocalProxy(
    String content,
    String proxyBaseUrl, {
    bool renumberSegments = false,
  }) {
    final lines = content.split('\n');
    final result = <String>[];
    var segIndex = 0;

    final bool isFvp = renumberSegments;
    // fvp 专属：AES-128 解密上下文。剥离 EXT-X-KEY 后把 key URI + IV 注入每个分片
    // 代理 URL，由 _proxySegment 取 key 逐段解密，绕开 libmdk 卡死。
    String? activeAesKeyUri;
    Uint8List? activeAesIv;
    int mediaSequence = 0;
    int segEmitIndex = 0;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      // fvp 专属：丢弃结构性 #EXT-X-DISCONTINUITY（避免 libmdk 段缓存撞名卡死）。
      if (renumberSegments && trimmed == '#EXT-X-DISCONTINUITY') {
        continue;
      }

      // 解析媒体序列号（无 IV 属性时的默认 IV = 序列号低 8 字节大端）。
      if (trimmed.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final m = RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(trimmed);
        if (m != null) mediaSequence = int.parse(m.group(1)!);
      }

      // fvp 专属：AES-128 加密 HLS 经本地代理会被 libmdk 解密卡死。
      // 这里剥离 EXT-X-KEY 标签（fvp 不再需要拉 key），并把 key URI + IV 记录到
      // 上下文，供后续每个分片代理 URL 注入 &decrypt=aes128&key=&iv=。
      // 仅 fvp 后端（renumberSegments==true）开启；ExoPlayer 自带解密，保持原样。
      if (trimmed.startsWith('#EXT-X-KEY')) {
        final methodMatch = RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(trimmed);
        final method = methodMatch?.group(1);
        if (isFvp && method == 'AES-128') {
          activeAesKeyUri = RegExp(r'URI="([^"]+)"').firstMatch(trimmed)?.group(1);
          final ivMatch = RegExp(r'IV=0x([0-9A-Fa-f]+)').firstMatch(trimmed);
          activeAesIv = ivMatch != null ? _hexToBytes(ivMatch.group(1)!) : null;
          continue; // 剥离 EXT-X-KEY
        } else if (isFvp && method == 'NONE') {
          activeAesKeyUri = null;
          activeAesIv = null;
          continue; // 无加密，剥离
        } else {
          // 非 fvp，或 SAMPLE-AES 等不支持方法：保留标签并改写 URI（原行为）。
          result.add(_rewriteUriAttributes(proxyBaseUrl, raw));
          continue;
        }
      }

      // 媒体行
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          !trimmed.startsWith('data:')) {
        final proxySeg = _proxyUrl(proxyBaseUrl, trimmed);
        // fvp 专属：注入全局唯一序号，规避同名分片段缓存冲突。
        String finalSeg =
            renumberSegments ? '$proxySeg&hseg=$segIndex' : proxySeg;
        // fvp 专属：当前分片属于 AES-128 加密区间 → 注入解密参数，
        // 由代理侧取 key 后逐段解密（绕过 libmdk 卡死）。
        if (isFvp && activeAesKeyUri != null) {
          final ivHex = activeAesIv != null
              ? _bytesToHex(activeAesIv)
              : _bytesToHex(_ivFromSeq(mediaSequence + segEmitIndex));
          finalSeg +=
              '&decrypt=aes128&key=${Uri.encodeComponent(activeAesKeyUri)}&iv=$ivHex';
          segEmitIndex++;
        }
        result.add(finalSeg);
        segIndex++;
        continue;
      }

      // 需要处理 URI 的标签
      if (trimmed.startsWith('#EXT-X-MAP') ||
          trimmed.startsWith('#EXT-X-KEY') ||
          trimmed.startsWith('#EXT-X-MEDIA') ||
          trimmed.startsWith('#EXT-X-PART') ||
          trimmed.startsWith('#EXT-X-PRELOAD-HINT') ||
          trimmed.startsWith('#EXT-X-STREAM-INF') ||
          trimmed.startsWith('#EXT-X-SESSION-DATA') ||
          trimmed.startsWith('#EXT-X-SESSION-KEY') ||
          trimmed.startsWith('#EXT-X-RENDITION-REPORT') ||
          trimmed.startsWith('#EXT-X-CONTENT-STEERING')) {
        result.add(_rewriteUriAttributes(proxyBaseUrl, raw));
        // 若下一行是子 M3U8 URL，也重写
        if (trimmed.startsWith('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
          final nextRaw = lines[i + 1];
          final nextTrimmed = nextRaw.trim();
          if (nextTrimmed.isNotEmpty && !nextTrimmed.startsWith('#')) {
            // 变体 URL 不重编号（保持相对稳定），仅走代理。
            result.add(_proxyUrl(proxyBaseUrl, nextTrimmed));
            i++;
            continue;
          }
        }
        continue;
      }

      result.add(raw);
    }

    return result.join('\n');
  }

  static String _rewriteUriAttributes(String proxyBaseUrl, String line) {
    final uriPattern = RegExp(r'URI="([^"]+)"');
    return line.replaceAllMapped(uriPattern, (match) {
      final original = match.group(1)!;
      return 'URI="${_proxyUrl(proxyBaseUrl, original)}"';
    });
  }

  static String _proxyUrl(String proxyBaseUrl, String originalUrl) {
    if (originalUrl.startsWith('http://') ||
        originalUrl.startsWith('https://')) {
      return '$proxyBaseUrl/segment?url=${Uri.encodeComponent(originalUrl)}';
    }
    return originalUrl;
  }

  /// 对 M3U8 内容进行本地广告过滤。
  static String _filterM3u8(
    String baseUrl,
    String content, {
    bool cleanDiscontinuities = false,
  }) {
    try {
      final filter = M3u8AdFilter();
      final filtered = filter.purify(
        baseUrl,
        content,
        cleanDiscontinuities: cleanDiscontinuities,
      );
      if (filtered != null && filtered != content) {
        WindowsLogger.log(
          'LocalM3u8Proxy',
          '子 M3U8 过滤: ${filter.currentAdCount} 个片段',
        );
        return filtered;
      }
    } catch (e, stack) {
      WindowsLogger.log('LocalM3u8Proxy', '子 M3U8 过滤失败: $e');
      WindowsLogger.log('LocalM3u8Proxy', '$stack');
    }
    return content;
  }

  // ═══════════════════════════════════════════════════════════════════════
  // HLS 并发分片预取（移植自 hain_tv_ohos）
  // ═══════════════════════════════════════════════════════════════════════

  /// 清空并发预取缓存（换源/换集/stop 时调用），避免旧源分片污染新源。
  void _clearPrefetchCache() {
    _prefetchCache.clear();
    _prefetchDelta.clear();
    _prefetchQueue.clear();
    _prefetchTotalBytes = 0;
    // 🔴 2026-10-29：起播预热缓存同样属于「按源」状态，换源必须一并清掉，
    //   否则旧源的密文/明文会被新源的同 URL 分片命中（跨源串流）。
    _primeCache.clear();
    _primeQueued.clear();
    _primeQueue.clear();
    _primeInflight.clear();
    _primePriority.clear();
    _primeBytes = 0;
    _primeRequested = false;
    _prefetchFailCount = 0;
    _prefetchRunning = false;
    _segmentUrls = const [];
    // 🔴 2026-10-29：名义轴起点表与解密上下文表必须与分片表**同生命周期**
    //   （否则下标与分片错位 ⇒ 预热定位到错误的段）。
    _segmentStartMs = const [];
    _collectedFrom = null;
    _prefetchEmptyWarned = false;
    // 换源/换集/停止：旧的落点登记对新源无意义，必须一并清掉，
    // 否则会对新源做一次指向旧落点的预取（白抓，且误导排障）。
  }

  /// 从重写后的播放列表收集媒体分片 **CDN 原始 URL**（按出现顺序）。
  ///
  /// 统一以解码后的 CDN 原始 URL 作为预取 key：播放器每次分片请求都进入
  /// `_proxySegment` 并持有同一份 `targetUrl`（`/segment?url=<enc(CDN_url)>`
  /// 解码结果），`_schedulePrefetch`/`_storePrefetched`/`_servePrefetched`
  /// 全部基于该 key 匹配。
  ///
  /// ⚠️ 鸿蒙侧踩过的坑：早期收集的是**代理 URL**、匹配的却是 **CDN URL**，
  ///    导致 `indexOf` 恒为 -1、预取队列永远为空、预取完全不生效且零日志。
  ///    故这里必须解出 `?url=` 参数（与 `_realUrlOfProxySegment` 同源规则）。
  void _collectSegmentUrls(String rewrittenPlaylist) {
    // 🔴 2026-10-15 幂等守卫：同一份 playlist 内容不重复解析。
    //   鸿蒙侧 hilog 实测：`Prefetch: 收集分片 1302 个` 会在一次起播内重复
    //   出现 6 遍（同毫秒两次 + 后续连续多遍），成因是 TTL 缓存分支每次请求
    //   都无条件重新收集。主工程结构相同，同样存在该浪费。
    //   分片表与内容一一对应，内容不变则结果必然相同，重复执行纯属浪费。
    if (_collectedFrom == rewrittenPlaylist) return;
    _collectedFrom = rewrittenPlaylist;

    final lines = rewrittenPlaylist.split('\n');
    final urls = <String>[];
    // 🔴 2026-10-29（移植鸿蒙）：同步累计 **名义轴**（EXTINF 累加）起点，
    //   与 urls **同序等长** ⇒ 下标一一对应。
    //   用途：把播放位置换算成分片下标（seek / 起播定位预热）。
    final starts = <int>[];
    var accMs = 0;
    var pendingMs = 0;
    var hasPending = false;
    for (final raw in lines) {
      final t = raw.trim();
      if (t.isEmpty) continue;
      if (t.startsWith('#EXTINF')) {
        final m = RegExp(r'#EXTINF:\s*([\d.]+)').firstMatch(t);
        pendingMs =
            m != null ? (double.parse(m.group(1)!) * 1000).round() : 0;
        hasPending = true;
        continue;
      }
      if (t.startsWith('#')) continue;
      // 仅收录本地代理形式的媒体分片（/segment?url=...）；变体/sub-m3u8 行不收。
      if (t.contains('/segment?url=') && !t.contains('manifest')) {
        final cdn = _realUrlOfProxySegment(t);
        if (cdn != null) {
          urls.add(cdn);
          starts.add(accMs);
          accMs += hasPending ? pendingMs : 0;
          hasPending = false;
          pendingMs = 0;
        }
      }
    }
    _segmentUrls = urls;
    _segmentStartMs = starts;
    // 🔴 预取诊断：确认收集结果。此前预取静默失效时无任何日志可查，
    //   只能在代码里推断（且推错过一次）。此处打印真实收集到的分片数，
    //   以及第一片样本，便于一眼判断「是重写没生效」还是「收集条件把它滤掉了」。
    _log('Prefetch: 收集分片 ${urls.length} 个'
        '${urls.isEmpty ? " —— 重写后无 /segment?url= 行，预取将整源失效！" : "，首片=${urls.first}"}');

    // 🔴 2026-10-29：分片表刚就绪 ⇒ 补做此前挂起的「seek/起播定位预热」。
    //   mpv 的 open(startAt) 早于 master 展开完成，此刻分片表还没有，
    //   目标位置被挂在这里，等收集完成立刻补做。
    if (_pendingPrefetchTargetMs != null && urls.isNotEmpty) {
      final pending = _pendingPrefetchTargetMs!;
      _pendingPrefetchTargetMs = null;
      primePrefetchAt(Duration(milliseconds: pending));
    } else if (urls.isNotEmpty) {
      // 🔴 2026-10-29：即使没有定位目标，也预热「建索引头部段」。
      //   mpv 打开 m3u8 后会**从第 0 段开始**顺序拉若干分片来建索引，
      //   这是**阻塞项**（索引没建成，seek 发不出去）。真机日志
      //   （小米 12S Pro 2026-10-29 21:31）plist0→plist3 串行花了 2.7s。
      //   头部段（跳过 0：第 0 段此刻正被播放器回源，抢不来也省不下）
      //   提前并发备好 ⇒ mpv 逐段取时基本命中本地缓存。
      _primeHeadSegments();
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 起播预热（落点窗口 + 建索引头部段）—— 移植自 hain_tv_ohos
  // ═══════════════════════════════════════════════════════════════════════

  /// 🔴 2026-10-29：把「落点分片窗口」预热到指定播放位置。
  ///
  /// 由 mpv 后端在 `open(startAt)` / `seek()` **之前**调用。
  ///
  /// 【为什么要预热 —— 真机实锤（小米 12S Pro 2026-10-29 21:31）】
  ///   21:31:29.744 open startAt=1450000ms
  ///   21:31:31.156 plist0 下载完 → 31.385 plist1 → 32.207 plist2 → 33.893 plist3
  ///        （4 个头部段**串行** = 2.7s；索引没建完，seek 发不出去）
  ///   21:31:34.054 plist315（落点段）才下载完（open 后 4.3s）
  ///   21:31:36.005 首帧（open 后 **6.3s**）
  ///   ⇒ 落点段与头部段都是**回源 RTT 串起来**的；预热可并行把它们提前备好。
  ///
  /// 【窗口口径】（与鸿蒙 `hls_prefetch_window.dart` 一致）
  ///   落点窗口 = `[落点下标, 落点下标 + _kPrimeDepth]`，**含落点自身**
  ///   （落点正是 seek 的目标段，它此刻还躺在 CDN 上）。
  void primePrefetchAt(Duration position) {
    // ⚠️ 不受「连续预取」开关（`_prefetchEnabled`）约束：
    //   连续预取是「播放过程中提前多拉几段」，可由用户关闭；
    //   而起播预热是**起播定位/seek 的前置条件**（不预热就得干等 CDN 往返），
    //   属于本次要根治的起播问题，不能被那个开关关掉。
    _primeRequested = true;
    final ms = position.inMilliseconds;
    if (_segmentUrls.isEmpty || _segmentStartMs.isEmpty) {
      // 分片表还没就绪（master 展开未完成）⇒ 挂起，等收集完成后补做。
      _pendingPrefetchTargetMs = ms;
      _log('Prime: 分片表未就绪，挂起落点 ${ms}ms');
      return;
    }
    final idx = indexForPosition(_segmentStartMs, ms);
    if (idx < 0) return;
    _log('Prime: 落点 ${ms}ms → 分片 #$idx / 共 ${_segmentUrls.length} 段');

    // 入队顺序 = 优先级：
    //   ① 落点段自身（seek 的目标，最关键）；
    //   ② 建索引头部段 1..N-1（索引建不成就发不出 seek）；
    //   ③ 落点窗口其余段（播放推进用）。
    // 🔴 2026-10-30：落点段是 seek 的直接目标，**插队到队首**并多占一路并发
    //   （荣耀平板真机实测：它排在第 5 位时 mpv 起播要 12s）。
    _enqueuePrimeIndex(idx, priority: true);
    for (var i = 1; i < _kIndexHeadSegments; i++) {
      _enqueuePrimeIndex(i);
    }
    for (var i = idx + 1; i <= idx + _kPrimeDepth; i++) {
      _enqueuePrimeIndex(i);
    }
    _pumpPrimeWorkers();
  }

  /// 🔴 2026-10-29：预热「建索引头部段」（0.._kIndexHeadSegments-1）。
  ///
  /// 【为什么包含第 0 段 —— 2026-10-29 22:44 真机日志修正了此前的判断】
  ///   此前以为「第 0 段此刻正被播放器回源，抢不来」，故跳过它。
  ///   实测日志证明**恰恰相反**：
  ///     22:44:49.078 open → 22:44:51.384 plist0 才拿到（2.28s）
  ///     plist0 是 mpv 建索引的**阻塞项**（file-loaded 直接等它），
  ///     而它与预热并发抢带宽，旧版单独下载只要 1.95s。
  ///   ⇒ 第 0 段**必须**提前备好；配合「在途去重」，
  ///     mpv 的请求会**等**预热线程的那一次下载，而不是重复下载。
  ///
  /// [force] 为 true 时忽略「是否已请求过预热」的闸门
  ///   （用于 open 之前由 AdFilterEngine 触发的提前预热）。
  void _primeHeadSegments({bool force = false}) {
    if (!force && !_primeRequested) return;
    for (var i = 0; i < _kIndexHeadSegments; i++) {
      _enqueuePrimeIndex(i);
    }
    _pumpPrimeWorkers();
  }

  /// 把指定下标的分片加入预热队列（去重）。
  void _enqueuePrimeIndex(int index, {bool priority = false}) {
    if (index < 0 || index >= _segmentUrls.length) return;
    final url = _segmentUrls[index];
    if (_primeCache.containsKey(url)) return;
    if (_primeQueued.contains(url)) {
      // 已经在队里：若它此前是普通项、现在被标记为关键路径，则把它提到队首。
      if (priority && !_primePriority.contains(url)) {
        _primePriority.add(url);
        final at = _primeQueue.indexOf(url);
        if (at > 0) {
          _primeQueue.removeAt(at);
          _primeQueue.insert(0, url);
        }
      }
      return;
    }
    _primeQueued.add(url);
    if (priority) {
      // 关键路径项插队到队首：worker 空闲时第一个拿到的就是它。
      _primePriority.add(url);
      _primeQueue.insert(0, url);
    } else {
      _primeQueue.add(url);
    }
  }

  /// 启动预热 worker（最多 [_kPrefetchConcurrency] 路并发）。
  void _pumpPrimeWorkers() {
    // 关键路径项在队时，多放 [_kPrimePriorityBonus] 路 worker 出去，
    // 让它立刻与已在途的建索引段**并行**下载，而不是排队等它们腾位置。
    final limit = _kPrefetchConcurrency +
        (_primePriority.isNotEmpty ? _kPrimePriorityBonus : 0);
    while (_primeWorkers < limit && _primeQueue.isNotEmpty) {
      _primeWorkers++;
      unawaited(_primeWorker());
    }
  }

  /// 单个预热 worker：串行消费预热队列。
  Future<void> _primeWorker() async {
    try {
      while (_primeQueue.isNotEmpty) {
        if (_closing) {
          _primeQueue.clear();
          break;
        }
        // 🔴 2026-10-30：关键路径（落点段）已走完 ⇒ 收回多借的那一路并发，
        //   避免预热长期以 5 路跑（挤占播放器自己的取流带宽）。
        if (_primePriority.isEmpty && _primeWorkers > _kPrefetchConcurrency) {
          break;
        }
        if (_primeBytes >= _kMaxPrefetchCacheBytes) {
          _log('Prime: 缓存达上限，清空预热队列');
          _primeQueue.clear();
          break;
        }
        final url = _primeQueue.removeAt(0);
        _primePriority.remove(url);
        if (_primeCache.containsKey(url)) continue;
        await _primeOne(url);
      }
    } finally {
      _primeWorkers--;
      // 队列里可能还有新项（seek 又来了）⇒ 补拉 worker。
      if (_primeQueue.isNotEmpty) _pumpPrimeWorkers();
    }
  }

  /// 预热单个分片：回源 CDN 下载**原始字节**并缓存。
  ///
  /// 加密源缓存的是**密文**（出口的解密分支照常解密，行为零差异）；
  /// 明文源缓存的是**明文**（出口的 PTS 归一化照常施加）。
  Future<void> _primeOne(String cdnUrl) async {
    try {
      // 登记在途 Future：播放器若此时来要同一段，会**等它**而不是重复下载。
      final fut = _downloadSegmentBytes(cdnUrl);
      _primeInflight[cdnUrl] = fut;
      final body = await fut;
      if (body == null) return;
      if (_primeBytes + body.length > _kMaxPrefetchCacheBytes) {
        _log('Prime: 缓存达 50MB 上限，放弃预热 $cdnUrl');
        return;
      }
      _primeCache[cdnUrl] = body;
      _primeBytes += body.length;
      _log('Prime: 预热就绪 ${body.length} bytes $cdnUrl');
    } catch (e) {
      _log('Prime: 预热异常 $cdnUrl: $e');
    } finally {
      _primeInflight.remove(cdnUrl);
    }
  }

  /// 回源下载单个分片的原始字节（失败返回 null）。
  Future<Uint8List?> _downloadSegmentBytes(String cdnUrl) async {
    try {
      final headers = _segmentRequestHeaders(cdnUrl);
      final client = _client ?? http.Client();
      final resp = await client
          .get(Uri.parse(cdnUrl), headers: headers)
          .timeout(const Duration(seconds: 30));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _log('Prime: 预热失败 status=${resp.statusCode} $cdnUrl');
        return null;
      }
      return resp.bodyBytes;
    } catch (e) {
      _log('Prime: 预热异常 $cdnUrl: $e');
      return null;
    }
  }

  /// 🔴 2026-10-29：取该分片的「已预热字节」——已缓存则直接给；
  /// 正在下载则**等它下完**复用同一份；都没有则返回 null（调用方自己回源）。
  Future<Uint8List?> _awaitPrimedSegment(String targetUrl) async {
    final cached = _primeCache[targetUrl];
    if (cached != null) return cached;
    final inflight = _primeInflight[targetUrl];
    if (inflight == null) return null;
    try {
      // 12s 上限：万一预热线程卡住，播放器不能被无限期拖住。
      final body = await inflight.timeout(const Duration(seconds: 12));
      if (body != null) {
        _log('Prime: 复用预热在途下载 ${body.length} bytes $targetUrl');
        return body;
      }
    } catch (e) {
      _log('Prime: 等待在途预热失败（改为自行回源） $targetUrl: $e');
    }
    return null;
  }

  /// 🔴 2026-10-29：若该分片已被预热，伪造一个 http.StreamedResponse 顶替回源响应。
  ///
  /// 返回 null ⇒ 未预热，调用方照常回源。
  ///
  /// 【为什么可以这样顶替】下游对响应的全部用法只有四处：
  ///   `statusCode` / `headers['content-type']` / `contentLength` / `stream`。
  /// 伪造响应提供的是**同一份字节**，故解密、PTS 平移、Range 切片、
  /// 状态码语义与真回源**完全一致**，只省掉一次回源往返。
  Future<http.StreamedResponse?> _primedSegmentResponse(
      String targetUrl) async {
    final body = await _awaitPrimedSegment(targetUrl);
    if (body == null) return null;
    return http.StreamedResponse(
      Stream<List<int>>.value(body),
      200,
      contentLength: body.length,
      headers: const {'content-type': 'video/mp2t'},
    );
  }

  /// 把下载到的整段存入预取缓存（受 50MB 上限约束；超限则不入缓存，只服务本次请求）。
  void _storePrefetched(String proxyUrl, Uint8List body) {
    if (!_prefetchEnabled) return;
    if (_prefetchCache.containsKey(proxyUrl)) return;
    if (_prefetchTotalBytes + body.length > _kMaxPrefetchCacheBytes) {
      _log('Prefetch: 缓存达 50MB 上限，跳过缓存 $proxyUrl');
      return;
    }
    _prefetchCache[proxyUrl] = body;
    _prefetchTotalBytes += body.length;
  }

  /// 定位当前分片下标，把后续 N 个分片入队预取。
  ///
  /// 时序：`_proxySegment` 在「真实拿到当前分片」后调用本函数，
  /// 由它定位当前分片在 `_segmentUrls` 中的下标，把后续 N 个入队，
  /// 单线程串行消费队列（`_drainPrefetchQueue`，带 `_prefetchRunning` 标志位
  /// 防重入），避免并发无上限拖垮带宽。
  void _schedulePrefetch(String currentProxyUrl) {
    if (!_prefetchEnabled) return;
    if (_segmentUrls.isEmpty) {
      // 🔴 此处原为静默 return —— 正是「预取整源失效却零日志」的根源。
      //   改为限频打印一次（用 _prefetchEmptyWarned 去重，避免每分片刷屏）。
      if (!_prefetchEmptyWarned) {
        _prefetchEmptyWarned = true;
        _log('Prefetch: ⚠️ _segmentUrls 为空，预取未启动（本次播放仅提示一次）');
      }
      return;
    }
    if (_prefetchFailCount >= _kMaxPrefetchFailures) {
      _log('Prefetch: 连续失败已熔断，跳过预取');
      return;
    }
    final idx = _segmentUrls.indexOf(currentProxyUrl);
    if (idx < 0) return; // 不在列表里的（如已重写变体行）不预取
    for (var i = idx + 1; i <= idx + _kMaxPrefetchCount && i < _segmentUrls.length; i++) {
      final url = _segmentUrls[i];
      if (_prefetchCache.containsKey(url) || _prefetchQueue.contains(url)) continue;
      _prefetchQueue.add(url);
    }
    _runPrefetchQueue();
  }

  /// 串行消费预取队列（带重入标志）。
  void _runPrefetchQueue() {
    if (_prefetchRunning) return;
    _prefetchRunning = true;
    _drainPrefetchQueue();
  }

  Future<void> _drainPrefetchQueue() async {
    try {
      while (_prefetchQueue.isNotEmpty) {
        if (!_prefetchEnabled || _closing) {
          _prefetchQueue.clear();
          return;
        }
        if (_prefetchFailCount >= _kMaxPrefetchFailures) {
          _log('Prefetch: 熔断，清空队列');
          _prefetchQueue.clear();
          return;
        }
        if (_prefetchTotalBytes >= _kMaxPrefetchCacheBytes) {
          _log('Prefetch: 缓存达上限，清空队列');
          _prefetchQueue.clear();
          return;
        }
        final proxyUrl = _prefetchQueue.removeAt(0);
        if (_prefetchCache.containsKey(proxyUrl)) continue;
        await _prefetchOne(proxyUrl);
      }
    } finally {
      _prefetchRunning = false;
    }
  }

  /// 预取单个分片：`cdnUrl` 为 CDN 原始 URL（`_schedulePrefetch` 入队的即为
  /// 解码后的原始 URL），整段下载后以同一 URL 为 key 存入缓存。
  Future<void> _prefetchOne(String cdnUrl) async {
    try {
      final headers = _segmentRequestHeaders(cdnUrl);
      final client = _client ?? http.Client();
      final streamed = await client
          .get(Uri.parse(cdnUrl), headers: headers)
          .timeout(const Duration(seconds: 30));
      if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
        final body = streamed.bodyBytes;
        // 🔴🔴 2026-10-15 修复「开启预取后进度条乱跳」：delta 必须**在这里**写入。
        //
        // 原缺陷：`_prefetchDelta` 只在直连回源分支（L828）写入，而预取是
        //   **提前**下载的 —— 分片进缓存时播放器还没请求过它，直连分支未跑，
        //   `_prefetchDelta` 里没有它的键。等播放器来取时 `_servePrefetched`
        //   读 `_prefetchDelta[url] ?? 0` 得到 0 ⇒ `if (delta != 0)` 不成立
        //   ⇒ **原样吐出未平移的原始字节**。
        //
        // 后果：命中预取缓存的分片回到「真实 PTS 轴」，与已平移的邻居段不同轴，
        //   mpv 的 time-pos 在该段处跳变 —— 表现为进度条乱跳，且**静默**
        //   （delta=0 时压根不进平移分支，连自校验失败日志都不会打）。
        //   真机实证：跳幅 -27s / +31s / +167s / +161s，且关闭预取即消失。
        //
        // 修法：预取线程自己算 delta 并写入，与直连分支取同一个函数
        //   `_deltaFor`，保证两条路径语义完全一致。
        if (_ptsNormalize) {
          try {
            // establishBase: false —— 基准只能由播放器直连路径建立，
            // 否则预取抢跑会把基准定在随机分片上（详见 _deltaFor 注释）。
            _prefetchDelta[cdnUrl] =
                await _deltaFor(cdnUrl, body, establishBase: false);
          } catch (e) {
            // 算 delta 失败不应拖垮预取：退回「不平移」的旧行为即可，
            // 该分片若被命中最多是轴不一致，不会崩溃。
            _log('Prefetch: 计算 delta 失败，该分片不平移 $cdnUrl: $e');
          }
        }
        _storePrefetched(cdnUrl, body);
        _prefetchFailCount = 0; // 成功即重置连续失败计数
        _log('Prefetch: 命中并缓存 $cdnUrl (${body.length} bytes)');
      } else {
        _prefetchFailCount++;
        _log('Prefetch: 预取失败 status=${streamed.statusCode} '
            '($_prefetchFailCount/$_kMaxPrefetchFailures) $cdnUrl');
      }
    } catch (e) {
      _prefetchFailCount++;
      _log('Prefetch: 预取异常 ($_prefetchFailCount/$_kMaxPrefetchFailures) $cdnUrl: $e');
    }
  }

  /// 预取缓存命中时，按请求 Range 切片返回（无 Range 则整段返回）。
  /// 返回 true 表示已处理响应（调用方直接 return），false 表示未命中。
  ///
  /// 🔴 缓存内统一存**原始 CDN 字节**，故 PTS 平移必须在此出口施加
  /// （与 `_proxySegment` 直连路径一致）。若 delta 为 0 或自校验不通过则原样返回。
  /// 移植适配：鸿蒙侧判 `kPtsNormalizeObserveOnly`（常量，false=启用），
  /// 主工程对应运行时开关 `_ptsNormalize`（true=启用），语义等价。
  bool _servePrefetched(HttpRequest request, String proxyUrl) {
    if (!_prefetchEnabled) return false;
    final cached = _prefetchCache[proxyUrl];
    if (cached == null) return false;
    var body = cached;
    final delta = _prefetchDelta[proxyUrl] ?? 0;
    if (delta != 0 && _ptsNormalize) {
      final shifted = normalizeTsPts(body, delta);
      final chk = verifyPtsShift(body, shifted, delta, videoOnly: true);
      if (chk.ok) {
        body = shifted;
      } else {
        _log('Prefetch: PTS 平移自校验失败，回退原始字节 '
            '(${chk.reason} before=${chk.beforeMs} after=${chk.afterMs}) $proxyUrl');
      }
    }
    final out = request.response;
    final range = request.headers.value('range');
    final fullLen = body.length;
    if (range != null && range.isNotEmpty) {
      final parsed = _parseRange(range, fullLen);
      if (parsed != null) {
        final (start, end) = parsed;
        out.statusCode = HttpStatus.partialContent;
        out.headers
          ..set('Content-Length', (end - start + 1).toString())
          ..set('Content-Range', 'bytes $start-$end/$fullLen')
          ..set('Accept-Ranges', 'bytes');
        out.add(body.sublist(start, end + 1));
        out.close();
        _log('Prefetch: 缓存命中(Range) $proxyUrl bytes=$start-$end');
        return true;
      }
    }
    out.statusCode = HttpStatus.ok;
    out.headers
      ..set('Content-Length', fullLen.toString())
      ..set('Accept-Ranges', 'bytes');
    out.add(body);
    out.close();
    _log('Prefetch: 缓存命中(整段) $proxyUrl');
    return true;
  }

  /// 解析 Range 头，返回 [start, end]（含端点）；非法/越界返回 null。
  (int, int)? _parseRange(String range, int fullLen) {
    // 仅支持 "bytes=start-end" 单段，足够覆盖 HLS 分片内 seek/续拉。
    final m = RegExp(r'bytes=(\d*)-(\d*)').firstMatch(range);
    if (m == null) return null;
    final startStr = m.group(1)!;
    final endStr = m.group(2)!;
    int start;
    int end;
    if (startStr.isEmpty) {
      // suffix-range: bytes=-N（最后 N 字节）
      final n = int.tryParse(endStr);
      if (n == null || n <= 0) return null;
      start = (fullLen - n).clamp(0, fullLen - 1);
      end = fullLen - 1;
    } else {
      start = int.tryParse(startStr) ?? 0;
      end = endStr.isEmpty ? fullLen - 1 : int.tryParse(endStr) ?? (fullLen - 1);
    }
    if (start < 0 || end >= fullLen || start > end) return null;
    return (start, end);
  }
}
