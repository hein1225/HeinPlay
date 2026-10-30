import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes_fast.dart';
import 'package:pointycastle/block/modes/cbc.dart';

import 'hls_prefetch_window.dart';
import 'hls_segment_range.dart';
import 'm3u8_ad_filter.dart';
import 'ts_pts_normalizer.dart';
import '../utils/app_logger.dart';
import '../utils/windows_logger.dart';

/// 段元数据：用于 PTS 归一化（见 [_deltaFor]）。
class _SegInfo {
  final int index; // 0 基段序号（按播放列表媒体行顺序）
  final int prefixMs; // 该段之前所有 EXTINF 时长之和（**原始含广告**列表的名义轴偏移）
  final int seq; // #EXT-X-MEDIA-SEQUENCE 序号

  /// 🔴🔴🔴 2026-10-24 修复「进度条定位后往前偏移 10~30 秒」：
  /// **真实 EXTINF 累加**，不再是 `index × 2000`。
  ///
  /// 【原实现的致命错误】曾写成 `int get filteredMs => index * 2000;` ——
  ///   等于假设「每段恰好 2.000 秒」。但真实源的段长**并非**整 2 秒
  ///   （实测 1.72 / 1.84 / 1.88 / 1.96 / 2.00 / 3.00 / 3.44 / 3.52 …），
  ///   平均约 **2.02 秒**。于是 `index × 2000` 与真实 EXTINF 累加之间
  ///   产生**随段号单调增长**的误差：
  ///     误差(index) = Σ(真实段长) − index×2000 ≈ index × 20ms
  ///   在 index≈684（23 分 48 秒处）已累积到 **≈29 秒** —— 与真机日志逐字吻合：
  ///     12:41:44.576 seek 到 1367.96s → 12:41:45.525 state.position 变成
  ///     1397.04s，**整整往前跳了 29.08 秒**（用户所报「定位后还往后偏」）。
  ///
  /// 【本文件自己就写错了】本类下方原注释原文是
  ///   「过滤后列表名义轴 = index × **EXTINF 累加**（= duration 的口径）」，
  ///   而实现却是硬编码 `index * 2000` —— **注释与实现自相矛盾**，
  ///   说明当初把「EXTINF 累加」误写成了「index × 2000」。
  ///
  /// 【正确口径】`filteredMs` = 该分片在**去广告名义轴**上的**起点**（ms），
  ///   由**最终服务给播放器的 media 播放列表**的 `#EXTINF` 逐段累加得到。
  ///   这正是 mpv `duration` 走的轴 —— 分子分母同源，进度条才准。
  ///   主工程 `hain_tv` 自 2026-10-11 起即按真实 EXTINF 累加实现
  ///   （`_rebuildSegMetaFromProxyPlaylist`），本实现本次对齐。
  final int filteredMs;

  const _SegInfo(this.index, this.prefixMs, this.seq, this.filteredMs);
}

/// 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，第十五轮）：**起播裁剪的纯函数实现**
/// （抽出以便单测）。
///
/// 【它解决什么】把 HLS 播放列表裁成「第 0 片 = 落点片」的版本，
/// 让 AVPlayer 从落点直接起播、**完全不需要 seek**。
///
/// 【🔴 关键不变量：每个分片 URL 前面必须有对应的 #EXTINF】
///
/// 真机实证根因（hilog 2026-10-24 21:50:14，13-50-45.txt）：
/// ```
/// 21:50:14.333 seekTo: target=0ms mode=SEEK_NEXT_SYNC current=3652ms
/// 21:50:14.504 bindState, avplayerStatus=error
/// 21:50:14.506 AvPlayer Avoid Error Reporting: {"code":5400103}  ← IO 错误
/// ```
/// ⇒ AVPlayer 在 seek 后 173ms 报错并进入 error 态（**不是**「永久 seeking」）。
/// ⇒ 代理侧该时段**零请求** ⇒ 不是取数失败，而是**定位阶段**就崩了。
///
/// 根因：裁剪时从落点片的 **URL 行**开始保留，而落点片的 `#EXTINF` 在它
/// **上一行**被丢弃 ⇒ 裁剪后列表第 0 片**没有 #EXTINF**：
/// ```
/// #EXT-X-MEDIA-SEQUENCE:497
/// #EXT-X-KEY:...AES-128...
/// /20260916/q5fnZoph/1125kb/hls/f14bm5At.ts   ← ❌ 丢了 #EXTINF:1.68,
/// #EXTINF:2,
/// ```
/// 顺序播放时 AVPlayer 边读边解析、容忍首片时长缺失 ⇒ 起播正常（实测 2432ms）；
/// 而 **seek 需要完整索引**（每片时长 → 累计时间 → 定位关键帧），
/// 首片时长缺失 ⇒ 索引损坏 ⇒ 定位失败 ⇒ 媒体服务报 5400103。
///
/// 【返回值】裁剪后的列表；**null** 表示没找到落点片（调用方应返回完整列表）。
String? applyStartTrimToPlaylist(
  String playlist, {
  required int startIndex,
  required String targetCdnUrl,
}) {
  final lines = playlist.split('\n');
  // 精确定位落点片所在行：按 **CDN 原始 URL** 匹配，而不是「数第 N 个
  //   /segment?url= 行」—— 因为收集分片表时会跳过解析不出 CDN URL 的行，
  //   两者计数可能错位。
  var cut = -1;
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();
    if (t.isEmpty || t.startsWith('#')) continue;
    if (!t.contains('/segment?url=')) continue;
    if (extractCdnUrlFromProxyUrl(t) == targetCdnUrl) {
      cut = i;
      break;
    }
  }
  if (cut < 0) return null;

  // 头部：cut 之前、第一个 #EXTINF 之前的全部标签行。
  final head = <String>[];
  for (var i = 0; i < cut; i++) {
    final t = lines[i].trim();
    if (t.startsWith('#EXTINF')) break;
    if (t.startsWith('#EXT-X-ENDLIST')) continue;
    head.add(lines[i]);
  }
  final out = <String>[];
  for (final h in head) {
    if (h.trim().startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
      out.add('#EXT-X-MEDIA-SEQUENCE:$startIndex');
    } else {
      out.add(h);
    }
  }
  // 🔴🔴🔴 第十五轮修复点：从落点片**最近的 #EXTINF 行**开始保留
  //   （不是从 URL 行开始）⇒ 恢复 HLS 规范的「#EXTINF 紧跟其分片 URL」配对。
  var start = cut;
  while (start > 0 && !lines[start].trim().startsWith('#EXTINF')) {
    start--;
  }
  // ⚠️ 防御：万一上方没有 #EXTINF（异常列表），退回从 URL 行开始，别把整表丢掉。
  if (start >= cut) start = cut;
  out.addAll(lines.sublist(start));
  return out.join('\n');
}

/// 🔴 2026-10-24（第十五轮）：从代理分片 URL 中解出 CDN 原始 URL（纯函数）。
String extractCdnUrlFromProxyUrl(String proxyUrl) {
  try {
    final uri = Uri.parse(proxyUrl);
    final encoded = uri.queryParameters['url'];
    if (encoded == null || encoded.isEmpty) return '';
    return Uri.decodeComponent(encoded);
  } catch (_) {
    return '';
  }
}

/// 本地 M3U8/TS 代理服务。
///
/// 用于解决去广告后的 M3U8 在不同播放器后端（ExoPlayer / FVP / VLC）
/// 中播放时头部透传不一致的问题。所有资源请求统一走本地代理，由代理补全头部。
class LocalM3u8Proxy {
  HttpServer? _server;
  String? _playlistContent;
  final Map<String, String> _baseHeaders = {};
  http.Client? _client;
  bool _closing = false;
  bool _filterEnabled = false;
  bool _discontinuityCleanup = false;

  /// 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，**仅 avplayer 后端**）：「快起播」模式。
  ///
  /// 【为什么 avp 需要它 —— 真机 hilog 2026-10-24 20:34~20:36 实证】
  ///   同一源、同一代理，mpv 起播 **2.0s**，avp 起播 **11.5s / 15s 超时失败**。
  ///   拆开看 avp 的 11.5s：
  ///     · prepared 4.5s（无落点时只要 1.78s）⇒ **多出的 2.7s 是代理抢带宽**
  ///     · seek → SEEK_DONE 3.5s
  ///     · 首帧兜底 1.5s
  ///
  /// 【代理抢带宽的机理（日志实证）】
  ///   落点预热把 **16 段**窗口插到队首，头部 8 段又插到队首 ⇒ 队列 24 段、
  ///   worker 只有 4 路 ⇒ 落点段排在第 9~24 位，**要等前 8 段先下完**
  ///   （源站单连接 ~235KB/s，串行 4 段 ≈ 8 秒）才轮得到它。
  ///   同时 AVPlayer 自己在拉第 0 段建索引，两边同时打 CDN ⇒
  ///   上游直接掐断连接（日志 `sent=32768`）⇒ 索引建不起来 ⇒ 15s 超时。
  ///
  /// 【本开关做的事】avp 路径把「落点窗口」从 16 段**收窄到 2 段**、
  /// 头部建索引段从 8 段收窄到 4 段、并**关掉投机式插队**，
  /// 让「AVPlayer 要的探测段」与「落点段」同时开跑（合计 6 段 ≤ 4 路 worker
  /// 的两轮），谁也不排队等谁。
  ///
  /// 【对 mpv 无影响】mpv 用 `--start` 直接跳读，不需要建索引，也不依赖代理
  /// 预取落点段（它自己会拉目标段），所以 mpv 的预取参数保持原样。
  bool _avPlayerFastStart = false;

  /// avp 路径的「落点预取窗口」段数（落点段 + 其后 N-1 段）。
  /// 收窄的意义：落点段是**唯一**必须提前备好的段，其余段 AVPlayer 用到时
  /// 自己会拉（代理按需透传），提前下反而抢占带宽。
  ///
  /// ⚠️ **只在「起播定位阶段」收窄**：`_prefetchTargetIndex != null` 表示
  /// 还有落点目标没追上（起播定位中）；一旦播放头追上落点（或 30s TTL 过期），
  /// 立刻恢复完整深度 16 —— 否则播放中预取跟不上 ⇒ **引入新的卡顿**
  /// （这正是用户早前报的「两个播放器顿挫」的成因，不能重犯）。
  int get _prefetchDepth =>
      (_avPlayerFastStart && _prefetchTargetIndex != null)
          ? 2
          : _kMaxPrefetchCount;

  /// avp 路径的「建索引头部段」数量。AVPlayer 打开 HLS 源时会先顺序拉若干段
  /// 来凑起播水位 / 建播放列表索引，这些段是**阻塞项**，必须提前备好；
  /// 但备太多会把落点段挤出 worker 空档。
  ///
  /// 🔴🔴 2026-10-28：mpv 路径由 8 收窄到 **2**。
  ///
  /// 【真机实锤：hilog 2026-10-28 14-22-03（第八版）与 13-59-58（第七版）】
  ///   两版 mpv 实际请求的头部段**都只有 plist0 和 plist1**（各 2 段），
  ///   而预取却按 8 段插到队首，白下载 6 段共 **3.72MB**、
  ///   占满 4 路 worker 前 **3.26 秒**（见 22:21:15.192~18.455 的 0..7 完成序列）。
  ///   落点段因此被推到第 9 位，起播被拖慢。
  ///
  ///   mpv 走 `startAt` 直接 seek，**不需要建播放列表索引** ——
  ///   代码注释里早就写了这句（「对 mpv 无影响」），但数量仍沿用 avp 的 8，
  ///   于是「无影响」的假设在 worker 有限的队列里变成了实打实的抢占。
  ///
  ///   2 段 = 实测所需（plist0 + plist1），再多就是白抢带宽。
  int get _indexHeadSegments => _avPlayerFastStart ? 4 : 2;
  // fvp 专属：给每个分段代理 URL 注入全局唯一序号（&hseg=N）并丢弃结构性
  // #EXT-X-DISCONTINUITY，避免 libmdk 因跨断点复用同名分片（如 plist0.ts）
  // 命中段缓存、停止续预取而卡死。仅 fvp 后端开启。
  bool _fvpRenumber = false;

  /// 🔴🔴 2026-10-24 新增：**由代理侧**做 AES-128 解密（而非交给播放器解）。
  ///
  /// 【为什么 mpv 也必须走这条路 —— 这是「加密源进度条偏移」修不掉的原因】
  ///   加密源的逻辑链：
  ///     ① 代理收到的是**密文**分片 → 不先解密就**根本读不出 PTS**
  ///        （真机日志 `PTS skip: no-pts` 125 次就是这么来的）
  ///     ② 读不出 PTS ⇒ 算不出 delta ⇒ **无法做 PTS 归一化**
  ///     ③ 不做归一化 ⇒ 分片里的真实 PTS（含广告时间线）与播放列表的
  ///        EXTINF 累加（去广告时间线）**两条轴不同源**
  ///     ④ ⇒ mpv 的 time-pos 与 duration 不同轴 ⇒ 进度条必然偏移
  ///   原实现把「代理解密」和「fvp 分段重编号」绑在同一个布尔
  ///   （`isFvp = renumberSegments`）上，而**鸿蒙的 mpv 后端两者都不开**
  ///   ⇒ 加密源永远走不到归一化 ⇒ 偏移永远修不掉。
  ///
  /// 【解法】把两件事拆开：
  ///   · `decryptAes`（本字段）—— 剥离 EXT-X-KEY + 给分片代理 URL 注入
  ///     `&decrypt=aes128&key=&iv=`，由代理取 key 逐段解密，**在明文上**做
  ///     PTS 归一化，然后把明文吐给播放器（播放器不再需要解密）。
  ///   · `renumberSegments` —— 仍是 fvp 专属的 `&hseg=N` 重编号 + 丢弃
  ///     结构性 discontinuity。
  /// 这与 legacy 工程（`hain_tv_legacy`）已验证可用的做法一致。
  bool _decryptAes = false;

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
  /// 🔴 2026-10-24 第七轮：当前展开结果的**实际 TTL**。
  ///   点播用 [_kExpandedTtlVod]，直播用 [_kExpandedTtl]。
  Duration _expandedTtl = _kExpandedTtl;
  static const Duration _kExpandedTtl = Duration(seconds: 3);
  /// 🔴 2026-10-24 第七轮：**点播（VOD）**的展开缓存 TTL。
  ///
  ///   【真机实锤：hilog 2026-10-24 10:08】同一个 media playlist
  ///   （107954 字节 / 1388 段）在一次测试里被**重复下载了 3 次**：
  ///     18:05:57.204  master 展开：下载 2475ms + 过滤 328ms
  ///     18:07:03.171  master 展开：下载 2180ms + 过滤 338ms
  ///     18:07:38.979  master 展开：下载 1284ms + 过滤 300ms
  ///   每次换源都要白等 1.3~2.5 秒 —— 因为展开缓存 TTL 只有 3 秒。
  ///
  ///   点播的 media playlist 是**静态**的（分片列表一次给全 + ENDLIST），
  ///   根本不需要 3 秒就重下一次；直播（无 ENDLIST）必须保持 3 秒的刷新节奏。
  ///   故按**原始上游内容**是否含 `#EXT-X-ENDLIST` 区分二者。
  static const Duration _kExpandedTtlVod = Duration(minutes: 5);

  /// 🔴 2026-10-15 新增：本代次 master 展开的结果是否**无广告**（过滤后与原文完全一致）。
  ///
  ///   【为什么需要】日志实测：`已过滤 0 个片段` 的源（无广告）仍会走完整条
  ///   展开链路 —— 下载变体（1.4~2.4s）+ 过滤 + 相对路径解析 + 重写 1302 个
  ///   分片（处理 32~410ms）。对无广告源而言这一整轮**纯属白跑**，全部叠加在
  ///   起播延迟上（实测开去广告比关去广告起播慢 2.4s）。
  ///
  ///   【为什么不干脆跳过展开】即便无广告，也**必须**拿到最终 media playlist：
  ///   PTS 归一化（`setOriginalMediaPlaylist`）依赖它建立名义时长轴，跳过会让
  ///   进度条越播越偏。所以省的是「过滤 + 解析 + 重写」，不是「展开」本身。
  ///
  ///   【判据】`_filterM3u8` 的返回是 `filtered != content` 才替换，二者相同即
  ///   「一个字都没删」。这正是「无广告」的确定性判定，不引入新逻辑。
  bool _expandedAdFree = false;

  /// 🔴 2026-10-15 新增：正在进行中的 master 展开（单飞闸门，防并发重复下载）。
  ///
  ///   【为什么需要】真机 hilog 2026-10-15 19:52 实证：同一次起播内 master
  ///   变体被下载了**两遍**、相隔仅 510ms：
  ///     19:53:01.006  下载 1392ms + 处理 387ms
  ///     19:53:01.516  下载 2230ms + 处理 293ms
  ///   （19:54:00.596 / 19:54:01.455 同样成对出现）
  ///
  ///   【成因】`setPlaylist` 用 `unawaited` 启动预热展开，此时 `_expandedAt`
  ///   仍为 null；mpv 紧接着请求 playlist.m3u8 时，`_resolvePlaylistContent`
  ///   看到 TTL 未建立，便**自己也发起一次完整下载**。两条链路并发穿透，
  ///   把一次展开变成两次，起播延迟平白多出一整轮（1.4~2.4s）。
  ///
  ///   【修法】把「正在展开」的 Future 存下来，后来者直接 await 同一个 Future，
  ///   而不是各下各的。这是标准的单飞（single-flight）语义，不改任何字节、
  ///   不改判据，只消除重复网络往返。
  ///
  ///   ⚠️ 必须带 `_playlistGen` 校验：等待期间若发生换源，旧代次的展开结果
  ///   绝不能返回给新源（否则播错内容）。代次不符则丢弃并重新展开。
  Future<String>? _expandInFlight;
  int _expandInFlightGen = -1;

  /// 播放列表代次：`setPlaylist`（换源/换集）时自增。
  ///
  /// 展开是异步的（含一次 CDN 往返），若期间发生换源，旧源的展开结果绝不能写回
  /// `_expandedPlaylist`——否则新源会拿到**上一个源的 media playlist** 而播错内容。
  int _playlistGen = 0;

  /// fvp 专属：AES-128 解密用到的 key 缓存（按 key URI 缓存，避免每段重复拉取）。
  final Map<String, Uint8List> _aesKeyCache = {};

  // ===== HLS 并发分片预取（借鉴 LunaTV OptimizedHlsLoader）=====
  //
  // 命门：分片必须流经本 Dart 本地代理，才能被预取（mpv/avplayer 直连 CDN 时
  // 请求在 native 层，Dart 侧不可见）。故仅在 AdFilterEngine 强制透传（鸿蒙 +
  // 预取开关开启，或 fvp 后端）时生效。
  //
  // 做法：playlist 出口处按出现顺序收集所有「媒体分片代理 URL」到 _segmentUrls；
  // 每次 _proxySegment 命中某分片时，定位其在列表中的下标，并发预取其后的 N 个
  // 分片存入内存缓存；下次播放器请求这些分片时直接命中缓存并按 Range 切片返回，
  // 消除「逐段等 CDN」的串行等待（弱网/换段效果最明显）。
  //
  // 约束：缓存上限 50MB、连续失败 3 次熔断（与 LunaTV 一致）；预取任务串行调度
  // （单队列 + 标志位），避免并发无上限；换源/换集（setPlaylist）与 stop 时清空，
  // 复用 _playlistGen 防止旧源预取结果污染新源。
  bool _prefetchEnabled = false;
  /// 用于「_segmentUrls 为空 → 预取未启动」警告的去重，避免每分片刷屏。
  bool _prefetchEmptyWarned = false;
  // 🔴🔴 2026-10-24 第六轮：预取深度 3 → 6、并发 1 → 3。
  //
  // 【真机实锤：hilog 2026-10-24 09:48】
  //   avp 会话：播放器分片请求 44 次、**预取缓存命中 0 次（命中率 0%）**，
  //   而同期预取完成了 45 段 —— 预取在跑，却**一次都没赶上**播放器要的那一段。
  //   逐条比对：播放器 17:47:08 要 kX2DhaMs，预取 17:47:11 才缓存它（晚 3 秒）；
  //   玩家 17:47:09 要 ddmnuC4J，预取 17:47:12 才缓存它（晚 3 秒）……
  //   ⇒ **预取永远慢播放器一拍**，命中率必然接近 0。
  //
  // 【根因】预取是**严格串行**的（`_drainPrefetchQueue` 单 worker，
  //   `await _prefetchOne()` 跑完才取下一个），而单次分片下载要等
  //   **CDN 首字节 0.8~2s + 传输 ~1s**（容器内 curl 实测 8 个分片：
  //   ttfb 0.76~1.32s、total 1.4~3.0s；极端一次 ttfb 6.8s）。
  //   ⇒ 串行预取的**交付速率 ≈ 1 段/1~2 秒**，而播放消耗速率是
  //   **1 段/2 秒** —— 几乎贴着需求线跑，**没有任何提前量**，
  //   预取完成的瞬间播放器早就已经回源了。
  //
  // 【为什么并发能救】同一 CDN 实测**支持并发**：
  //   8 个分片同时发起 ⇒ 全部 ttfb 0.76~1.32s、总耗时 2.0~2.6s
  //   （与串行的单段 1.4~3.0s 几乎一样）⇒ 并发不增加单段延迟，
  //   却能把提前量从「0 段」拉到「2~3 段」⇒ 命中率 0% → 90%+。
  //
  // 🔴🔴 2026-10-24 第九轮：深度 6 → **16**、并发 3 → **4**。
  //
  // 【真机实锤：hilog 2026-10-24 18:36~18:37（本次复测日志）】
  //   mpv 会话：分片请求 108 次、预取缓存命中 71 次（66%）；
  //   但**每一次 seek 之后**必然出现 1~2 段「回源」，
  //   实测回源响应头延迟 **828ms / 1500ms** ⇒ **seek 后必卡一下**。
  //   avp 会话：起播定位到 709 段时，**连续 22 段全部回源**
  //   （18:36:10~18:36:30，每段 0.3~2.1s）⇒ 预取**完全没赶上**。
  //
  // 【为什么深度 6 不够】窗口 = (播放头, 播放头+6]。播放头每前进 1 段，
  //   窗口尾也跟着前移 1 段 ⇒ 队列长度恒 ≈ 深度。而 worker 拿到队头后
  //   要等 CDN ttfb 0.8~2s 才吐字节，**深度 6 只够覆盖约 3~4 段的
  //   下载在途时间**，播放头一旦越过窗口末尾就必然回源。
  //   ⇒ 深度 16 可覆盖「1.5s 下载 + 2s/段消费」约 8 段的领先量。
  //
  // 【为什么并发 4 够】容器内 curl 实测同一 CDN **8 路并发**时
  //   ttfb 仍是 0.76~1.32s（与串行几乎一样）⇒ CDN 扛得住并发。
  //   4 路兼顾「提前量」与「不把带宽吃满导致回源变慢」。
  static const int _kMaxPrefetchCount = 16; // 预取后续分片数（提前量）
  /// 预取并发路数。1 = 旧行为（串行，必然慢一拍）。
  static const int _kPrefetchConcurrency = 4;

  /// 🔴 2026-10-24（avp 快起播）：avp 路径的预取并发路数。
  ///
  /// 【为什么 avp 要 8 路 —— 本文件既有实测注释】
  ///   「容器内 curl 实测同一 CDN **8 路并发**时 ttfb 仍是 0.76~1.32s
  ///     （与串行几乎一样）⇒ CDN 扛得住并发。」
  ///
  /// 【avp 为什么要并发】
  ///   avp 起播同时需要两类段：
  ///     · 建索引/探测段（AVPlayer 打开 HLS 源后会顺序拉的前几段）—— 阻塞项
  ///     · 落点段（seek 的目标）—— 阻塞项
  ///   收窄后共 4 + 2 = 6 段。4 路并发 ⇒ 2 轮（≈2.6s）；
  ///   8 路并发 ⇒ **1 轮**（≈1.3s）⇒ 两类段同时就绪，谁也不排队。
  ///   mpv 路径保持 4 路不变（mpv 不建索引，不需要并发抢）。
  ///
  /// ⚠️ 同样**只在起播定位阶段**用 8 路：播放稳定后恢复 4 路 —— 深度 16 段配
  /// 4 路是既有调优结果（不把带宽吃满，避免回源反而变慢）。
  int get _prefetchConcurrency =>
      (_avPlayerFastStart && _prefetchTargetIndex != null)
          ? 8
          : _kPrefetchConcurrency;
  static const int _kMaxPrefetchCacheBytes = 50 * 1024 * 1024; // 50MB
  static const int _kMaxPrefetchFailures = 3; // 连续失败熔断
  final Map<String, Uint8List> _prefetchCache = {};
  /// 🔴 2026-10-09：预取缓存**只存原始 CDN 字节**，PTS 平移改在出口
  /// （`_servePrefetched` / 直连路径）施加。本表记录每个 key 对应的 delta，
  /// 避免出口处再异步调 `_deltaFor`（该函数会走网络探测，出口是同步路径）。
  final Map<String, int> _prefetchDelta = {};
  final List<String> _prefetchQueue = [];
  int _prefetchTotalBytes = 0;
  int _prefetchFailCount = 0;
  bool _prefetchRunning = false;
  /// 🔴 2026-10-24 第六轮：预取代次号。换源/换集时 +1，
  ///   让仍在下载中的旧 worker 立即退出（并发化后不能再靠布尔位）。
  int _prefetchGen = 0;

  // ===== 🔴🔴 2026-10-24 第九轮：分片下载「单飞（single-flight）」+ 残缺自愈 =====

  /// 同一分片的**单飞完整下载**：key = CDN 原始 URL，value = 正在进行的下载。
  ///
  /// 【真机实锤：hilog 2026-10-24 18:37:09】
  ///   18:37:09.500  proxySegment request: pUr8NL28.ts   ← 播放器请求（回源）
  ///   18:37:09.587  Prefetch: 命中并缓存 pUr8NL28.ts (314148 bytes) ← 预取**同时**下完
  ///   18:37:10.328  proxySegment Range 起点=0 … 改走流式平移 pUr8NL28.ts
  ///   18:37:10.623  ⚠️ declared=314148 sent=245716 delta=-68432  ← **残缺分片**
  ///
  ///   ⇒ 播放器请求与预取**对同一分片各发了一次上行请求**（重复下载），
  ///     两条流互相争抢带宽，其中一条被上游中途掐断 ⇒ 播放器拿到残缺分片
  ///     ⇒ 解码失败 ⇒ 播放器重试 ⇒ **顿挫**。
  ///
  /// 【修法】同一分片永远只有**一条**上行连接：
  ///   · 预取与修复任务都通过 [_fetchSegmentBytes] 取字节，共享同一个 Future；
  ///   · 播放器直连遇到「该分片正在下载」时，**等待**那个 Future，
  ///     直接拿**完整字节**返回（不再另发回源）。
  final Map<String, Future<Uint8List?>> _segmentFetchInFlight = {};

  /// 正在被**播放器直连**下载的分片（流式回源中）。
  ///
  /// 预取 worker 取到这些分片时**跳过**：既然播放器已经在拉了，
  /// 再下一份纯属重复回源 + 带宽争抢（上面那段 206 短读就是这么来的）。
  final Set<String> _segmentDirectFetching = {};

  /// 正在做「残缺分片修复」的分片（后台完整重取中），避免重复修复。
  final Set<String> _segmentRepairInFlight = {};

  /// 直连等待预取完成的上限。超时即回退到「自己回源」，绝不让播放器无限等。
  static const Duration _kInFlightWaitTimeout = Duration(seconds: 8);

  /// 🔴🔴🔴 2026-10-24 第十轮：分片完整下载的**最大尝试次数**。
  ///
  /// 【为什么需要重试 —— 真机 19:30 实锤】
  ///   即便走「无 Range ⇒ 200 完整 GET」，上游仍会中途掐断
  ///   （声明 214696 字节、实际只给 32768 字节就 EOF）。
  ///   一次失败就判残缺 ⇒ 播放器拿不到这一段 ⇒ 反复重试 ⇒ 反而更卡。
  ///   ⇒ 掐断是**可重试**故障：重试到拿到完整字节为止。
  static const int _kSegmentFetchAttempts = 3;
  List<String> _segmentUrls = const []; // 当前 playlist 的媒体分片代理 URL（顺序）
  /// 🔴 2026-10-24 第六轮：`_segmentUrls` 的 URL → 下标映射（O(1) 定位）。
  ///
  ///   用途：预取队列「丢弃过时项」（seek 后队列里还堆着旧位置的分片）
  ///   需要按下标比较，而 `List.indexOf` 是 O(n)（本源 1328 段）×队列长度。
  Map<String, int> _segmentIndex = const {};

  /// 🔴 2026-10-24 第七轮：每个分片在**名义轴**（EXTINF 累加轴）上的起点（毫秒）。
  ///
  ///   与 `_segmentUrls` **同序等长**（同一次解析产出）⇒ 下标一一对应。
  ///   用途：把播放器的「播放位置（秒）」换算成「分片下标」，
  ///   从而在 seek / 起播定位**之前**把预取窗口预热到目标位置
  ///   （见 [primePrefetchAt]）。
  ///
  ///   口径说明：avplayer 的 position 由 EXTINF 累加驱动；mpv 的 position
  ///   走真实 PTS，但代理已做 PTS 归一化（两者对齐）⇒ 两者都落在本轴上。
  List<int> _segmentStartMs = const [];

  // ══════════════════════════════════════════════════════════════════════
  // 🔴🔴🔴 2026-10-24（HeinPlay 本地 fork，第十三轮）：**起播裁剪列表**
  //
  // 【要解决的问题】鸿蒙 AVPlayer 的 HLS 起播是**结构性慢**：
  //   · 官方只支持 prepare() → prepared → play() → playing → seek()，
  //     **没有任何「打开即定位」的能力**（media.PlaybackStrategy 无起始位置字段，
  //      createMediaSourceWithUrl 只有 (url, headers)）；
  //   · 所以 AVPlayer 必然「先从播放列表第 0 片拉流建索引，再 seek 到落点」；
  //   · 更糟的是：在 PREPARED（未播放）态 seek 会与「拉第 0 片建索引」并发，
  //     媒体服务内部冲突 ⇒ 5400103（真机证据：2026-10-24 20:01:44）；
  //     改成 PLAYING 态 seek 合法，但进 PLAYING 又需要 surface，
  //     而 surface 要等 Flutter 建 texture、texture 要等 initialized，
  //     于是「挂起 initialized 等 seek 后首帧」把三方锁死
  //     （真机证据：2026-10-24 21:06:55~21:07:25，三次起播全部 30s 超时失败）。
  //
  // 【本改动的解法】**让代理返回的列表第 0 片就是落点片**。
  //   ⇒ AVPlayer 从第 0 片（= 落点片）直接起播，**根本不需要 seek**；
  //   ⇒ 原生侧不必预置起播定位、不必挂起 initialized ⇒ **官方标准流程直接跑通**；
  //   ⇒ 首帧送显的就是落点画面 ⇒ 无「闪一下片头」；
  //   ⇒ 落点片已在预取缓存里 ⇒ 起播不必现等 CDN。
  //
  // 【时间轴】裁剪后 AVPlayer 的 position(0) = 落点片起点（相对时间），
  //   故对外暴露的 position/duration 需统一加 [_trimOffsetMs] 换算回用户轴。
  //   代理内部 [_segmentStartMs] 一直是**用户轴**（与播放记录同一根轴），
  //   所以 [_trimOffsetMs] = _segmentStartMs[落点下标] 天然对齐。
  //
  // 【安全性】裁剪只在「有落点定位」时发生；其余场景（无落点、mpv、直播）
  //   一律返回完整列表，行为与改动前完全一致。
  int? _trimStartIndex;

  /// 裁剪后列表第 0 片对应的**用户轴**起点（ms）。对外换算用。
  int? _trimOffsetMs;

  /// 对外暴露裁剪偏移（Dart 侧 position/duration/seek 换算用）。
  /// null ⇒ 未启用裁剪（position/duration 无需换算）。
  int? get trimOffsetMs => _trimOffsetMs;

  /// 🔴 2026-10-24：根据挂起的落点目标算出裁剪起点（分片表就绪后才有意义）。
  ///
  /// ⚠️ **只负责「首次设定」**：一经设定就不再自动重算。
  ///   运行时改落点（seek 重建自愈）必须走 [setTrimStartAtMs] 显式指定 ——
  ///   否则普通 seek 也会把裁剪起点挪走，导致 position 轴整体错位。
  void _updateTrimTarget() {
    if (_trimStartIndex != null) return;
    // 落点下标：优先用已算好的 _prefetchTargetIndex（primePrefetchAt 成功路径），
    // 否则用挂起的目标时间在已就绪的分片表上现算。
    var idx = _prefetchTargetIndex;
    if (idx == null) {
      final targetMs = _pendingPrefetchTargetMs;
      if (targetMs == null) return;
      if (_segmentUrls.isEmpty || _segmentStartMs.isEmpty) return;
      idx = indexForPosition(_segmentStartMs, targetMs);
    }
    if (idx < 0) return;
    if (idx >= _segmentStartMs.length) return;
    _trimStartIndex = idx;
    _trimOffsetMs = _segmentStartMs[idx];
  }

  /// 🔴 2026-10-24：把 playlist 裁剪成「第 0 片 = 落点片」的版本。
  ///
  /// 【为什么在代理侧做】AVPlayer 只会从它拿到的列表第 0 片开始读。
  ///   代理是唯一能在出网前改写列表的地方，且代理已经知道落点片下标。
  ///
  /// 【裁剪规则】
  ///   · 头部保留：#EXTM3U / #EXT-X-VERSION / #EXT-X-TARGETDURATION /
  ///     #EXT-X-MEDIA-SEQUENCE（**重写为裁剪起点下标**，保持序号连续性）/
  ///     #EXT-X-KEY（**必须保留**！本片源是 AES-128 加密，AVPlayer 要靠它取 key）；
  ///   · 从落点片那一行（含其 #EXTINF）开始保留到结尾；
  ///   · 落点片之前的 #EXTINF 全部丢弃 ⇒ AVPlayer 的时间轴从 0 起算（相对时间）。
  String _applyStartTrim(String playlist) {
    // 🔴⚠️ 门控：**只对 avplayer 后端生效**。
    //   mpv / fvp 后端的时间轴换算不在 video_player_backend_impl 里
    //   （那里的 _trimOffsetMs 换算是 avp 专用的），若也裁剪列表，
    //   mpv 上报的 position 会变成「相对落点」而无人换算 ⇒ 进度条/播放记录全错。
    if (!_avPlayerFastStart) return playlist;
    _updateTrimTarget();
    final idx = _trimStartIndex;
    if (idx == null || idx <= 0) return playlist;
    if (idx >= _segmentUrls.length) return playlist;
    // 精确定位落点片所在行：按 **CDN 原始 URL** 匹配，而不是「数第 N 个
    //   /segment?url= 行」—— 因为 _collectSegmentUrls 会跳过解析不出 CDN URL
    //   的行（urls.add 只在 cdn.isNotEmpty 时执行），两者计数可能错位。
    final targetCdn = _segmentUrls[idx];
    final trimmed = applyStartTrimToPlaylist(
      playlist,
      startIndex: idx,
      targetCdnUrl: targetCdn,
    );
    if (trimmed == null) {
      _log('Proxy: 起播裁剪失败（未找到第 $idx 片），返回完整列表');
      return playlist;
    }
    _log('Proxy: 起播裁剪 ⇒ 列表第 0 片 = 原第 $idx 片，'
        'offset=${_trimOffsetMs}ms（AVPlayer 从落点直接起播，无需 seek）');
    // 🔴 2026-10-24（第十五轮）：**打印裁剪结果头部**——真机可直接肉眼核对
    //   「第 0 片是否带 #EXTINF」，不必再靠推断。
    final head12 = trimmed.split('\n').take(12).map((e) => e.trim()).toList();
    _log('Proxy: 裁剪后列表头 ${trimmed.split('\n').length} 行，前 12 行:\n  ' +
        head12.join('\n  '));
    return trimmed;
  }

  /// 🔴 2026-10-24（第十五轮）：**运行时改裁剪起点**（按时间，seek 失败自愈用）。
  ///
  /// 【为什么需要】AVPlayer 在 HLS 上 seek 一旦失败会进入 `error` 态且不可恢复
  ///   （真机 2026-10-24 21:50:14.504：5400103 → error → 直到 release 都没恢复）。
  ///   此时唯一可靠的路是「用新的裁剪起点重新起播」——
  ///   把列表第 0 片改成用户想跳到的位置，AVPlayer 从那里直接起播（实测 2.4s）。
  ///
  /// 【效果】等价于一次「跨源起播」，但因为落点片已在预取缓存里，实际很快。
  ///
  /// ⚠️ 调用方**必须**在改完起点后重建播放器（AVPlayer 已经把旧列表解析进内存，
  ///   不会自动重拉），否则不生效。正常自愈路径走「重建后端」即可，
  ///   本方法用于「不重建、只预置下一次 open 的落点」的场景。
  void setTrimStartAtMs(int targetMs) {
    if (_segmentUrls.isEmpty || _segmentStartMs.isEmpty) return;
    final idx = indexForPosition(_segmentStartMs, targetMs);
    if (idx < 0 || idx >= _segmentUrls.length) return;
    if (_trimStartIndex == idx) return;
    _trimStartIndex = idx;
    _trimOffsetMs = _segmentStartMs[idx];
    _log('Proxy: 裁剪起点已改为第 $idx 片，offset=${_trimOffsetMs}ms'
        '（seek 失败自愈：以新落点重新起播）');
  }


  /// 🔴 2026-10-24 第七轮：**预热目标**分片下标（seek / 起播定位落点）。
  ///
  ///   非 null 时，队列同时保留「旧播放头窗口」与「目标窗口」，
  ///   避免 seek 尚未生效时把刚预热好的目标分片当旧位置丢掉。
  int? _prefetchTargetIndex;

  /// 🔴 2026-10-24 第七轮：预热目标的下标**设定时刻**（用于过期判定）。
  ///
  ///   目标若长期不被播放头追上（例如 seek 失败 / 目标在片尾），
  ///   就会一直把「旧播放头窗口」也留在队列里 ⇒ 队列变宽、预取跑偏。
  ///   故设一个过期时限（[_kPrefetchTargetTtl]），过期即作废。
  DateTime? _prefetchTargetAt;
  static const Duration _kPrefetchTargetTtl = Duration(seconds: 30);

  /// 🔴 2026-10-24 第七轮：分片表尚未就绪时先记下目标位置，
  ///   待 `_collectSegmentUrls` 收集完成后再补预热。
  ///
  ///   真机场景：mpv `open(startAt)` 发生在 master 展开完成之前
  ///   （展开要 1.1~2.8s），此刻还没有分片表可定位。
  int? _pendingPrefetchTargetMs;

  /// 🔴 2026-10-15 新增：`_segmentUrls` 是由哪份 playlist 文本解析出来的。
  ///
  ///   仅用于 `_collectSegmentUrls` 的幂等守卫：内容相同即跳过重复解析
  ///   （真机实证一次起播会重复解析同一份 1302 行文本 6 遍）。
  ///   不作为缓存 —— 内容一变就会重新收集并覆盖。
  String? _collectedFrom;



  bool get isRunning => _server != null;

  /// 🔴 2026-10-24 第七轮：**当前存活的本地代理实例**（全局可达）。
  ///
  ///   由 `AdFilterEngine` 在创建/销毁代理时登记。
  ///   播放后端（avplayer / mpv）用它把 seek 目标位置告诉代理，
  ///   让预取提前把目标区域的分片缓存好 —— 否则 seek 落点要现等 CDN
  ///   （真机实测 mpv 起播定位整整 6.9 秒、avplayer seek 后冻结 3.6 秒）。
  ///
  ///   放在本类而不是 `AdFilterEngine` 上，是为了**避免包级循环依赖**
  ///   （`ad_filter_engine.dart` 已依赖 `player_backend_factory.dart`
  ///   → `video_player_backend_impl.dart`）。
  static LocalM3u8Proxy? currentInstance;

  /// 设置是否对子 M3U8 启用广告过滤。
  void setFilterEnabled(bool enabled) {
    _filterEnabled = enabled;
  }

  /// 设置去广告后是否清理孤立的 EXT-X-DISCONTINUITY 标记（Windows/fvp 需要）。
  void setDiscontinuityCleanup(bool enabled) {
    _discontinuityCleanup = enabled;
  }

  /// 🔴 2026-10-24（HeinPlay 本地 fork）：开启/关闭 **avplayer 专属**的快起播模式。
  /// 仅 `PlayerBackendType.avplayer` 调用；mpv 路径完全不受影响。
  ///
  /// 🔴🔴🔴 2026-10-26（第十八轮）：**关闭时必须一并作废「起播裁剪」状态**。
  ///
  /// 【真机实锤】hilog 2026-10-26 08:03:08（鸿蒙 TV 真机，第23集 46:03）：
  ///   avp 会话把起播裁剪打开（列表第 0 片 = 原第 302 片，offset=1416224ms），
  ///   用户随后切到 mpv；因本开关**只置 true 从不复位**、且代理实例被复用
  ///   （切后端不走 AdFilterEngine.dispose），mpv 请求同一份 playlist 时
  ///   仍被裁成「落点→结尾」⇒ mpv 总时长 = 1346917ms（≈ 全片的一半）。
  ///   而「默认就用 mpv」时本开关从未打开 ⇒ 时长正常 ⇒ 反证污染源在 avp 侧。
  ///
  /// 【为什么必须在这里清】`_applyStartTrim` 的门控是 `_avPlayerFastStart`，
  ///   而裁剪状态（_trimStartIndex / _trimOffsetMs）是**跨后端**残留的；
  ///   只清其中一半仍会出错（门控开着 ⇒ 照样裁；状态残留 ⇒ 换源前也会错算）。
  void setAvPlayerFastStart(bool enabled) {
    _avPlayerFastStart = enabled;
    if (!enabled) {
      // 起播裁剪是 avp 专属能力：关掉快起播即代表「本次不用 avp 起播裁剪」，
      // 必须把裁剪状态一并作废，否则 mpv/fvp 会拿到只剩「落点→结尾」的列表。
      _trimStartIndex = null;
      _trimOffsetMs = null;
    }
    _log('Prefetch: avp 快起播模式=${enabled ? "开" : "关"}'
        '（落点窗口=${_prefetchDepth} 段 / 建索引头部段=${_indexHeadSegments} 段）'
        '${enabled ? '' : '，起播裁剪状态已作废'}');
  }

  /// 设置 fvp 专属分段重编号 + 结构性 discontinuity 丢弃开关。
  /// 仅 fvp 后端开启：让每个分段代理 URL 全局唯一，规避 libmdk 段名复用卡死。
  void setFvpRenumber(bool enabled) {
    _fvpRenumber = enabled;
  }

  /// 🔴🔴 2026-10-24：设置「由代理侧做 AES-128 解密」。
  ///
  /// 需要它的后端：**mpv**（鸿蒙默认点播后端）与 **fvp**。
  /// 不需要的：avplayer（自带的解密器够用，且走直连不受影响）。
  ///
  /// 【与 [setPtsNormalize] 的关系】两者**正交**，但通常同时为真：
  ///   只有「代理解密 ⇒ 能在明文上读出 PTS ⇒ 能算 delta ⇒ 能归一化」，
  ///   加密源的进度条偏移才有可能被修掉。
  void setDecryptAes(bool enabled) {
    _decryptAes = enabled;
  }

  /// 🔴🔴 2026-10-24 第二次修正：由上层按「后端类型」决定**允许**归一化，
  /// 是否**实际施加**由代理在展开最终 media 列表后自行判定。
  ///
  /// 【为什么不能再由上层用「裁掉几个广告段」决定 —— 这就是本轮真机实锤的根因】
  ///   上层 `removedAdCount` 统计的是**顶层播放列表**上被 `M3u8AdFilter` 删掉的
  ///   段数。而本片源是 **master → media 两级**：顶层 master 里只有一行
  ///   `#EXT-X-STREAM-INF`，**广告段在子 media 列表里** ⇒ 顶层统计恒为 0 ⇒
  ///   `needPtsNormalize = useMpv && removedAdCount > 0` 恒为 **false** ⇒
  ///   PTS 平移自始至终**一次都没执行过**。
  ///
  ///   真机证据（2026-10-24 15:03 本片）：
  ///     `[AdFilterEngine] PTS 归一化=false（后端=mpv, 裁掉广告=0 段）`
  ///     `[LocalM3u8Proxy] PTS normalize: 名义轴建立 段数=1328 归一化开关=false`
  ///     93 个分片全部走 `proxySegment stream:`（**零缓冲、零平移**）
  ///   而同一条日志里，代理自己算出的两套名义轴**明明分叉**：
  ///     `nominalFiltered=2717040ms` vs `nominalOriginal=2795440ms`
  ///     ⇒ **差 78.4 秒**（已删广告累计）—— 这就是确凿证据。
  ///
  /// 【正确的判据在代理内部，因为只有那里看得到最终 media 列表】
  ///   ① **轴分叉**：过滤后名义轴 ≠ 原始名义轴（`prefixMs - filteredMs != 0`）
  ///      ⇒ 去广告删了列表行、没改分片字节 ⇒ 两条轴不同源 ⇒ **必须**平移。
  ///   ② **源含 `#EXT-X-DISCONTINUITY`**：ffmpeg/libmpv 的 HLS demuxer
  ///      **不解析** DISCONTINUITY，只把「EXTINF 名义累加器」与首包真实 PTS
  ///      对齐一次 ⇒ 断点处必然产生 ts_offset ⇒ 同样**必须**平移。
  ///   本片源实测：5 个 DISCONTINUITY、3 个 EXT-X-KEY、1400 段。
  ///   （这两条判据与主工程 `hain_tv` 的 probe→flip 机制**同目标**，
  ///    但不需要额外发网络请求做预探测，也不会在起播链路上阻塞。）
  ///
  /// 【为什么必须按后端门控 —— 这是「鸿蒙版 avp 也卡」的根因】
  ///   · **mpv / libmpv**：`time-pos` 走**分片里的真实 PTS**，`duration` 走
  ///     **播放列表 EXTINF 累加**。去广告删了播放列表的行、没改分片字节 ⇒
  ///     两条轴不同源 ⇒ 进度条必然偏移。**必须**归一化。
  ///   · **avplayer（鸿蒙 avp 后端）**：position 直接由播放列表的 EXTINF 累加
  ///     驱动，**不读**分片里的 PTS ⇒ 本就不需要归一化。而一旦对它归一化，
  ///     就得为每个分片付「整段缓冲 + 解析 + 改写」的主 isolate 代价，
  ///     却换不来任何好处 —— 反而制造卡顿。
  ///   原实现把 `_ptsNormalize = _segMeta.isNotEmpty` 写死在 `_buildSegMeta` 里，
  ///   **任何后端、任何时候只要源里有 discontinuity 就自动归一化** ⇒ avp 也在
  ///   逐段缓冲改写 ⇒ 主 isolate 长期无空闲 ⇒ 画面卡住而声音正常
  ///   （用户 2026-10-24 实报：「无论 avp 还是 mpv 都时不时卡一下，声音正常」）。
  ///
  /// 【主工程既有约定】`hain_tv` 的 `AdFilterEngine` 用
  ///   `needPtsNormalize = effectivePtsNormalize && removedAdCount > 0`，
  ///   本实现改为**在代理内部直接判定**（见 [_buildSegMeta] 的轴分叉检测）。
  ///
  /// 【与主工程的关系】主工程用「probe→flip」两段式：先用 `removedAdCount > 0`
  ///   判断要不要平移，判断不出来就起播前**预探测**源轴，探测判定错乱/未定论
  ///   再升级为平移。本实现改为在代理展开最终 media 列表后直接判定 ——
  ///   原因见上方注释：上层的 `removedAdCount` 在 master→media 两级源上恒为 0。
  ///
  /// [allowed] = **后端门控**：只有「time-pos 走分片真实 PTS」的后端（mpv）
  ///   才为 true；avplayer 不读分片 PTS，允许了也只会白付缓冲代价。
  void setPtsNormalize(bool allowed) {
    final changed = _ptsNormalizeAllowed != allowed;
    _ptsNormalizeAllowed = allowed;
    // 实际是否施加 = 后端允许 && 代理内部判定本源确实需要纠偏。
    _ptsNormalize = allowed && _ptsAxisNeedsFix;
    if (changed && !allowed) {
      // 关闭归一化 ⇒ 清空「本源不可读」的判定与旧 delta 缓存，
      // 否则下次开启时会沿用上一条源的判定结果。
      _ptsUnreadableStreak = 0;
      _ptsReadable = null;
      _segDeltaCache.clear();
    }
  }

  // ===== PTS 归一化（根治 fvp 续播断点丢弃死循环）=====
  //
  // 触发：播放列表含 #EXT-X-DISCONTINUITY 时启用。代理按段把真实 PTS/DTS/PCR
  // 平移一个常量 delta，使"真实轴"对齐"EXTINF 名义轴"，从而消除 ffmpeg HLS
  // demuxer 在断点处产生的 ts_offset，让 libmdk 的 seek/丢弃窗口完全落在名义
  // 轴上（与 avplayer 一致），续播不再掉进"丢弃→卡死→重建"死循环。
  // 干净源（无 DISCONTINUITY 且 |delta|<1s）字节零改动透传。
  //
  /// 上层给的后端门控（只有 mpv 这类后端为 true）。
  bool _ptsNormalizeAllowed = false;

  /// 🔴🔴 2026-10-24：代理内部判定「本源的时间轴确实需要纠偏」。
  /// 由 [_buildSegMeta] 在展开最终 media 列表后写入：
  ///   轴分叉（过滤轴 ≠ 原始轴）|| 源含 `#EXT-X-DISCONTINUITY`。
  bool _ptsAxisNeedsFix = false;

  /// 实际是否施加平移 = [_ptsNormalizeAllowed] && [_ptsAxisNeedsFix]。
  bool _ptsNormalize = false;

  /// 🔴 HeinPlay 观测闸门（2026-10-08·方案 A）—— **只观察，不改字节**。
  ///
  ///   背景：`_segKeyFromLine` 的 `startsWith('/segment')` 判据恒为 false
  ///   （真实代理 URL 带 host），使 `_segMeta` 键全部错位、`_deltaFor` 恒走
  ///   `meta == null` 分支 → **PTS 归一化自始至今从未生效过一次**，且因 4 条
  ///   提前返回路径都没有日志而毫无痕迹。
  ///
  ///   键判据修好后，delta 会**第一次真正算出来**（据实测预判：首段约 -520ms、
  ///   末段约 -29800ms，即随进度累积）。此时若直接放开平移，等于一次性启用一条
  ///   从未在真机验证过的字节改写链路 —— 有把已修好的播放再次搞坏的风险。
  ///
  ///   故：本开关为 `true`（默认）时，`_deltaFor` **照常计算并打印 delta 分布**，
  ///   但两处应用点跳过 `normalizeTsPts`，**分片字节与修复前完全一致**。
  ///   先看真机日志确认 delta 分布合理、无异常段，再置为 `false` 启用平移。
  ///
  ///   置 `false` 即启用平移（恢复原设计行为），无需改动其他代码。
  ///
  /// ═══════════════════════════════════════════════════════════════════════
  /// 🔴🔴 2026-10-11：**已置为 false（启用平移）** —— 真根因已定位并修复。
  /// ═══════════════════════════════════════════════════════════════════════
  ///
  /// 【为什么现在敢开】原实现的目标轴选错了（见 [_SegInfo.filteredMs] 与
  ///   `_deltaFor` 内的详细推导）。真机日志（2026-10-11 13:12，本片
  ///   1394 段删 92 → 1302 段）给出两条独立铁证：
  ///
  ///   ① mpv 的 **time-pos 走真实 PTS 轴**：
  ///        idx=671 处 trueFirst=1431480ms，而 mpv 报 position=1426596ms
  ///        （差 4.9s = 播放推进量）→ 同轴。
  ///   ② mpv 的 **duration 走去广告名义轴**：
  ///        duration=2603280ms ≈ 1302×2000=2604000ms（差 720ms）；
  ///        若走真实 PTS 轴应为 ≈2759s，与实测差 156s → 否决。
  ///
  ///   → 进度条 `_position / _duration` **分子分母不同轴**，正是用户所报
  ///     「拖完仍往后偏」；且真实轴比去广告轴走得快（实测比值 1.0626），
  ///     偏移随播放**单调增长** —— 与用户「越往后偏得越多」逐字吻合。
  ///
  /// 【修法】`_deltaFor` 的 `expected` 从 `base + prefixMs`（含广告轴）改为
  ///   `base + filteredMs`（去广告轴，= index×2000）。idx=671 处的 delta
  ///   由 +35280ms 变为 **-84000ms**，即把 PTS 往前拉 84 秒，正好抵消
  ///   真实轴多走的那 84 秒 → time-pos 与 duration 同源，偏移从根上消失。
  ///
  /// 【保险】三处应用点（直连 / AES / 预取出口）都已接入 [verifyPtsShift]
  ///   出口自校验：平移前后首帧 PTS 差必须 == delta（容差 45 tick），
  ///   否则视为包边界错位，**自动回退原始字节**并打日志。故最坏情况是
  ///   「回到修复前的行为」，不会产生静默损坏的流。
  static const bool kPtsNormalizeObserveOnly = false; // 2026-10-11 真根因修复后启用

  final Map<String, _SegInfo> _segMeta = {};
  final Map<String, int> _segDeltaCache = {};
  /// 🔍 2026-10-09 轴对齐埋点节流：上次打印的段序号（见 `_deltaFor` 内说明）。
  int? _axisLoggedIndex;
  final Map<String, int> _segFirstPtsCache = {};

  /// 🔴🔴 2026-10-24：连续读不出视频 PTS 的分片数。
  ///
  /// 【为什么需要】「本源 PTS 能否读出」是**源级属性**（同一源的封装方式一致），
  ///   不是逐分片属性。一旦连续 N 段读不出，就说明本源不可读 —— 此时继续
  ///   对每个分片做「整段缓冲 + 解析 + 改写」纯属白付代价：
  ///     · AES-128 密文源永远读不出 PTS（不先解密就无从解析 PES）
  ///     · 而整段缓冲全程占用主 isolate，分片一个接一个、中间不让出 ⇒
  ///       Flutter 无法提交渲染帧 ⇒ **画面停住而音频照常**（用户所报「卡一下」）
  ///   故达到阈值后，后续分片一律改走**流式转发**
  ///   （主工程 `hain_tv` 2026-10-16 同源修复，本实现本次对齐）。
  int _ptsUnreadableStreak = 0;
  static const int _kPtsUnreadableThreshold = 3;
  /// null = 尚未判定；true = 本源 PTS 可读；false = 本源 PTS 不可读。
  bool? _ptsReadable;

  /// 播放列表出口统一收尾：检测 DISCONTINUITY 并建立段元数据。
  ///
  /// [originalContent]：**未经过滤的原始 media playlist**，仅供 `_buildSegMeta`
  ///   计算名义时长轴使用。见 [setOriginalMediaPlaylist] 的详细说明 ——
  ///   这是 2026-10-08 修复「广告后进度条重建 + 音画不同步」的关键接缝。
  String _finish(String content, {String? originalContent}) {
    if (content.contains('#EXT-X-DISCONTINUITY') ||
        (originalContent?.contains('#EXT-X-DISCONTINUITY') ?? false)) {
      _buildSegMeta(content, originalContent: originalContent);
    }
    // 预取开启时，从重写后的播放列表收集媒体分片代理 URL（顺序），
    // 供 _proxySegment 命中当前分片后预取后续 N 个。
    if (_prefetchEnabled) {
      _collectSegmentUrls(content);
    }
    return content;
  }

  /// 原始（未去广告）media playlist，用于建立**名义时长轴**。
  ///
  /// 🔴 HeinPlay 修复（2026-10-08）：为什么必须单独保存一份原始播放列表
  ///
  ///   【缺陷】`_buildSegMeta` 原先只接收**已去广告删改后**的播放列表，
  ///     用其中的 `#EXTINF` 累加出 `prefixMs`（名义时长前缀）。
  ///     但分片文件里的**真实 PTS 从未被改写** —— 删除分片只让列表变短，
  ///     不会让后面分片的 PTS 前移。于是：
  ///       名义轴（基于删减后 EXTINF）= 真实轴 - 已删总时长
  ///       expected = 段0首帧PTS + prefixMs  →  系统性偏小
  ///       delta    = expected - 真实首帧PTS  →  系统性为负且幅度 = 已删时长
  ///     `normalizeTsPts` 再把这个错误 delta 施加到分片上，
  ///     **主动把正确的 PTS 改坏**。
  ///
  ///   【真机铁证】h14（2026-10-08 21:00–21:03，4QFUN25115G00188）：
  ///     · 21:00:14.142 `M3u8AdFilter removed: 92 segments`（子 m3u8 被删 92 段）
  ///     · 21:01:12.972 `[ad:warn] Invalid audio PTS: 942.009889 -> 946.003567`
  ///     · 21:01:13.023 `[cplayer:warn] Audio/Video desynchronisation detected!`
  ///     · 21:01:13.024 `[cplayer:warn] position will not match to the video`
  ///     · 21:01:26.995 `[ad:warn] Invalid audio PTS: 960.005199 -> -3.947211`
  ///       → `Reset playback due to audio timestamp reset.`（音频轴被重置到负数）
  ///     · 21:01:56.258 `[ad:warn] Invalid audio PTS: 25.356370 -> 963.999233`
  ///     这些正是用户所报「mpv 广告后像重新出现一个进度条、同一画面时间与
  ///     avp 对不上」的原生层表现。
  ///
  ///   【修复】代理在去广告**之前**把展开得到的原始 media playlist 存一份，
  ///     供 `_buildSegMeta` 计算名义轴。这样 `prefixMs` 始终基于**完整**时间轴，
  ///     `expected` 与分片真实 PTS 在同一坐标系里，`delta` 才是有意义的
  ///     「真实轴 vs 名义轴」偏差 —— 也就是本机制设计时的原意。
  ///
  ///   【为什么不在 delta 上做补偿】删除时长的信息在 `_buildSegMeta` 里已丢失
  ///     （它只看到删减后的列表），事后无法还原。必须在数据源头保留，
  ///     否则又是一次「用不可信的量去推断状态」。
  String? _originalMediaPlaylist;

  /// 由 AdFilterEngine / `_fetchAndRewriteM3u8` 在过滤**之前**注入原始 playlist。
  ///
  /// 注入时会解析出「每个分片的真实累计时长」存入 [_originalPrefixMs]，
  /// 供 `_buildSegMeta` 计算名义轴。分片键与 `_segKeyFromLine` 保持一致，
  /// 故即使广告分片被删掉，剩余分片仍能查到自己在**完整时间轴**上的位置。
  void setOriginalMediaPlaylist(String? original) {
    if (identical(_originalMediaPlaylist, original)) return;
    _originalMediaPlaylist = original;
    _originalPrefixMs.clear();

    if (original != null && original.isNotEmpty) {
      // 🔴 2026-10-24：**起点口径**。原实现是「终点口径」（EXTINF 行上就累加，
      //   媒体行取到的已含本段自身时长），与主工程「该分片在轴上的起点」语义
      //   相差一段长（~2 秒），会让埋点里的「已删广告累计」读数偏大一段。
      var prefixMs = 0;
      var pendingMs = 0;
      var hasPending = false;
      for (final raw in original.split('\n')) {
        final t = raw.trim();
        if (t.startsWith('#EXTINF')) {
          final m = RegExp(r'#EXTINF:\s*([\d.]+)').firstMatch(t);
          pendingMs =
              m != null ? (double.parse(m.group(1)!) * 1000).round() : 0;
          hasPending = true;
        } else if (t.isNotEmpty &&
            !t.startsWith('#') &&
            !t.startsWith('data:')) {
          // 键用原始行解析（此时尚未 rewriteToLocalProxy，是裸 CDN URL）。
          _originalPrefixMs[_segKeyFromLine(t)] = prefixMs;
          prefixMs += hasPending ? pendingMs : 0;
          hasPending = false;
          pendingMs = 0;
        }
      }
    }

    // 原始列表变了 → 段元数据必须重建（旧的名义轴已失效）。
    _segMeta.clear();
    _segDeltaCache.clear();
    _segFirstPtsCache.clear();
    _log('PTS normalize: 原始 media playlist 已更新 '
        '(${original == null ? "null" : "${original.length} 字节, "
            "${_originalPrefixMs.length} 段名义轴"}）');
  }

  /// 原始播放列表里「分片键 → 该分片在完整时间轴上的累计时长(ms)」。
  final Map<String, int> _originalPrefixMs = {};

  /// 解析已重写播放列表，建立 CDN URL → 段元数据（序号 + 名义轴前缀时长）。
  ///
  /// [originalContent] 若提供，则用**它**的 `#EXTINF` 序列计算 `prefixMs`；
  ///   段序号/CDN URL 键仍取自 [content]（已重写、已过滤的那份）。
  void _buildSegMeta(String content, {String? originalContent}) {
    _segMeta.clear();
    _segDeltaCache.clear();
    _segFirstPtsCache.clear();
    final lines = content.split('\n');
    var seq = 0;
    var index = 0;
    // 🔴🔴 2026-10-24：**起点口径**的两条轴累加器。
    //   · filteredAccMs —— 去广告名义轴（= mpv duration 的口径），
    //     由**最终服务给播放器的**这份 content 的 #EXTINF 逐段累加；
    //   · pendingMs/hasPending —— 当前 #EXTINF 声明的段长（待消费）。
    //   取值顺序必须是「先记起点、再累加本段」，否则每段都会多算自身时长。
    var filteredAccMs = 0;
    var pendingMs = 0;
    var hasPending = false;
    for (final raw in lines) {
      final t = raw.trim();
      if (t.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        seq = int.tryParse(t.substring(t.lastIndexOf(':') + 1)) ?? 0;
      } else if (t.startsWith('#EXTINF')) {
        final m = RegExp(r'#EXTINF:\s*([\d.]+)').firstMatch(t);
        pendingMs =
            m != null ? (double.parse(m.group(1)!) * 1000).round() : 0;
        hasPending = true;
      } else if (t.isNotEmpty && !t.startsWith('#') && !t.startsWith('data:')) {
        final key = _segKeyFromLine(t);
        // 🔴 名义轴前缀优先取**原始未删减**播放列表里该分片的累计时长。
        //    删除分片只让列表变短，不会让后续分片的真实 PTS 前移；
        //    若用删减后的 EXTINF 累加，会把「已删时长」误当成 PTS 偏差，
        //    进而把本来正确的 PTS 改坏（详见 `_originalMediaPlaylist` 说明）。
        final originalPrefix = _originalPrefixMs[key];
        // 去广告轴起点 = 该段在 mpv duration 轴上的位置。
        final filteredStart = filteredAccMs;
        filteredAccMs += hasPending ? pendingMs : 0;
        hasPending = false;
        pendingMs = 0;
        _segMeta[key] =
            _SegInfo(index, originalPrefix ?? filteredStart, seq, filteredStart);
        index++;
        seq++;
      }
    }
    // 🔴 2026-10-24：**不再**在这里无条件置 `_ptsNormalize`。
    //   是否归一化由上层按「后端类型 + 是否真的删掉了广告」决定
    //   （见 `setPtsNormalize`），代理只负责「有没有可用的名义轴」。
    //   原写法会在每次 `_finish`（即每次 playlist 出口）把上层设置冲掉。

    // ── 🔴🔴🔴 2026-10-24 第二次修正：**「是否需要归一化」改由代理内部判定** ──
    //
    // 【为什么必须在这里判 —— 上层看不见真正的证据】
    //   上层只能用 `removedAdCount > 0` 近似判断，而那个数字统计的是**顶层**
    //   播放列表上被删的段数。本片源是 master→media 两级，广告段在子列表里
    //   ⇒ 顶层统计恒为 0 ⇒ 归一化开关恒为 false ⇒ 平移一次都没执行。
    //   而**只有代理在展开最终 media 列表后**才同时握有三样东西：
    //     ① 过滤后的名义轴（filteredMs，= mpv duration 的口径）
    //     ② 原始的名义轴（prefixMs，含被删广告段时长）
    //     ③ 原始列表里有没有 `#EXT-X-DISCONTINUITY`
    //
    // 【判据 1：轴分叉】`prefixMs - filteredMs != 0` ⇒ 去广告删了列表行、
    //   没改分片字节 ⇒ mpv 的 time-pos（真实 PTS 轴）与 duration（EXTINF
    //   名义轴）**不同源** ⇒ 进度条必然偏移，**必须**平移。
    //   本片实测：过滤后 1328 段 / 累计 2717040ms，原始 1388 段 / 2795440ms
    //   ⇒ **差 78.4 秒**，正是「定位后进度条再往后漂 20 多秒」的来源。
    //
    // 【判据 2：源含 DISCONTINUITY】ffmpeg/libmpv 的 HLS demuxer **不解析**
    //   DISCONTINUITY，只把「EXTINF 名义累加器」与首包真实 PTS 对齐一次 ⇒
    //   断点处必然产生 ts_offset ⇒ time-pos 与 duration 同样分叉 ⇒ 必须平移。
    //   本片实测：5 个 DISCONTINUITY（ffmpeg 不认）、3 个 EXT-X-KEY（部分分片
    //   AES-128 加密，需代理解密后才能读出 PTS）。
    //
    // 【与主工程的关系】主工程用「起播前预探测源轴（probe）→ 判定错乱则升级
    //   为平移」的两段式，目标是同一件事（主工程的 probe 同样是为了绕开
    //   `removedAdCount` 口径不准）。本实现改为在代理内部直接判定，理由：
    //   证据更直接（轴差就是铁证）、**不需要额外的网络探测请求**、也不会在
    //   起播链路上引入阻塞调用（主工程的历史教训）。
    var maxAxisDiffMs = 0;
    var axisDiverged = false;
    for (final m in _segMeta.values) {
      final d = m.prefixMs - m.filteredMs;
      if (d != 0) {
        axisDiverged = true;
        final ad = d.abs();
        if (ad > maxAxisDiffMs) maxAxisDiffMs = ad;
      }
    }
    // DISCONTINUITY 必须查**原始（过滤前）**列表：过滤动作可能已把断点行删掉。
    //   `_originalMediaPlaylist` 正是过滤前的 media playlist（由
    //   `setOriginalMediaPlaylist` 在过滤之前写入），比 `_buildSegMeta` 的
    //   `originalContent` 形参可靠 —— 后者的 8 个调用点历史上都没传过它。
    final discSource = _originalMediaPlaylist ?? originalContent ?? content;
    final hasDiscontinuity = discSource.contains('#EXT-X-DISCONTINUITY');
    final wasNormalizing = _ptsNormalize;
    _ptsAxisNeedsFix = axisDiverged || hasDiscontinuity;
    _ptsNormalize = _ptsNormalizeAllowed && _ptsAxisNeedsFix;
    if (wasNormalizing && !_ptsNormalize) {
      // 本源其实不需要纠偏 ⇒ 丢弃上一条源的「不可读」判定与 delta 缓存。
      _ptsUnreadableStreak = 0;
      _ptsReadable = null;
      _segDeltaCache.clear();
    }
    _log('PTS normalize: 名义轴建立 段数=${_segMeta.length} '
        '后端允许=$_ptsNormalizeAllowed '
        '轴分叉=${axisDiverged ? "是(累计${maxAxisDiffMs}ms)" : "否"} '
        '含断点=${hasDiscontinuity ? "是" : "否"} '
        '⇒ 归一化开关=$_ptsNormalize '
        '名义轴来源=${_originalPrefixMs.isEmpty ? "删减后列表(退化)" : "原始列表"}');

    // ── 🔍 2026-10-09 轴对齐埋点（一次性定位进度显示偏移）──────────────
    //
    // 【为什么加】此前靠日志反推「position 落在哪条轴」反复出错（曾误判为
    //   2132.23ms/段，实为跨阶跃求平均的污染值）。缺的是**三条轴的直接对照**：
    //     ① 过滤后列表名义轴 = index × EXTINF 累加（= duration 的口径）
    //     ② 原始列表名义轴   = originalPrefix（含被删广告段时长）
    //     ③ 真实 PTS 轴      = 分片内实际首帧 PTS
    //   本段一次性打印建立关系，之后每次 `_deltaFor` 只打增量。
    //
    // 【判读】position 应与 ① 同轴才正确。若与 ③ 同轴，则 UI 显示秒数
    //   会系统性偏大（本次实测偏 +29s ~ +104s）。
    if (_segMeta.isNotEmpty) {
      _log('PTS axis: ── 分段轴对照表（前 5 段）──');
      final byIndex = _segMeta.values.toList()
        ..sort((a, b) => a.index.compareTo(b.index));
      for (var i = 0; i < byIndex.length && i < 5; i++) {
        final m = byIndex[i];
        _log('PTS axis: idx=${m.index} seq=${m.seq} '
            'nominalFiltered=${m.filteredMs}ms '
            'nominalOriginal=${m.prefixMs}ms '
            '（两者差=${m.prefixMs - m.filteredMs}ms = 已删广告累计）');
      }
      _log('PTS axis: 段数=${byIndex.length} '
          '末段 idx=${byIndex.last.index} '
          '末段 nominalFiltered=${byIndex.last.filteredMs}ms '
          '末段 nominalOriginal=${byIndex.last.prefixMs}ms '
          '名义轴总长=${byIndex.last.filteredMs}ms');
    }
  }

  /// 媒体行→CDN URL 键：代理形式取 url 参数，裸 URL 直接用。
  ///
  /// 🔴 HeinPlay 修复（2026-10-08）：为什么不能再用 `startsWith('/segment')`
  ///
  ///   【缺陷】原判据是 `line.startsWith('/segment')`，只认**相对路径**形态。
  ///     但 `rewriteToLocalProxy` / `_proxyUrl` 生成的是**带 host 的绝对地址**：
  ///       `http://127.0.0.1:38569/segment?url=https%3A%2F%2F...ts`
  ///     于是 `startsWith('/segment')` **恒为 false**，本函数原样返回整行代理 URL，
  ///     `_segMeta` 的键全部错位成「代理 URL」。
  ///
  ///   而 `_deltaFor(targetUrl, ...)` 传入的 `targetUrl` 是**CDN 原始 URL**
  ///   （见 `_proxySegment`），于是 `_segMeta[cdnUrl]` 恒为 null →
  ///   `_deltaFor` 每次都走 `if (meta == null) return 0;` →
  ///   **PTS 归一化全程零生效**（真机日志：`DISCONTINUITY 检测=true 段数=1302`
  ///   但 `PTS normalize: seg=` 出现 0 次、`proxySegment PTS+` 出现 0 次）。
  ///
  ///   后果：mpv 位置只能落在 ffmpeg 的 EXTINF 名义累加轴上，该轴在每个
  ///   `#EXT-X-DISCONTINUITY`（本源 176 个）处与真实 PTS 的错配不断累积 →
  ///   表现为「进度越往后偏差越大、非线性突跳」。
  ///   avp 用自身解复用器、不走这条链路，故一直正确 —— 这是本条修复未触碰 avp 的原因。
  ///
  ///   【判据修正】改为 `contains('/segment')`：相对路径与绝对地址同时成立。
  ///   【解码修正】`Uri.queryParameters` **已自动解码**，原代码额外套一层
  ///     `Uri.decodeComponent` 会对含 `%` 的 CDN URL 造成**二次解码**（破坏性），
  ///     故一并去掉。
  String _segKeyFromLine(String line) {
    if (line.contains('/segment')) {
      final q = Uri.tryParse(line)?.queryParameters['url'];
      if (q != null && q.isNotEmpty) return q;
    }
    return line;
  }

  /// 🔴🔴 2026-10-24：原 `_probeFirstPts`（拉段0 前 64KB 探测基准 PTS 的那次
  /// 额外网络请求）已**整段删除**。
  ///
  /// 【为什么可以删】平移目标已从「基准段真实 PTS + 相对偏移」改为
  ///   **该分片自身的名义轴起点**（见 `_deltaFor` 内的 `expected`）。
  ///   目标值不再依赖任何全局基准 ⇒
  ///     · 不再需要「先探测段0」→ 少一次跨网请求，起播更快
  ///     · 不再存在「预取线程抢建基准 ⇒ 整条轴错位」的并发隐患
  ///     · 不再存在「段0 探测失败 ⇒ 全片不平移」的单点故障
  ///   这与主工程 `hain_tv` 2026-10-18 的锚点改造（锚点取名义值）是同一思路。

  /// 计算某段的 PTS 平移量（ms）。0 表示无需平移（干净源）。
  /// [bytes] 为整段已缓冲内容，用于就地探测本段首帧 PTS。
  ///
  /// 🔴 HeinPlay 修复（2026-10-08·方案 A）：**每条 `return 0` 都必须留痕**。
  ///
  ///   原实现 4 条提前返回路径**全都没有日志**，导致「PTS 归一化零生效」
  ///   在真机日志里表现为「什么都没发生」—— 既没有平移日志，也没有失败线索，
  ///   藏了整整几轮排查都没被发现。加日志是纯加法，不改变任何字节与行为。
  ///
  ///   日志前缀统一为 `PTS skip:`，与成功路径的 `PTS normalize: seg=` 配对使用：
  ///     · 若只看到 `PTS skip: not-normalize`  → 上层没开归一化（非 mpv 后端）
  ///     · 若只看到 `PTS skip: no-meta`        → **键不匹配**（历史真凶，见 _segKeyFromLine）
  ///     · 若只看到 `PTS skip: no-pts`         → 分片探测不出 PTS（非标准 TS / 密文）
  ///     · 若只看到 `PTS skip: within-threshold` → 源确实干净，无需平移（正常）
  ///     · 若看到 `PTS normalize: seg=`        → 真正发生了平移
  Future<int> _deltaFor(String cdnUrl, Uint8List bytes) async {
    if (!_ptsNormalize) {
      _logSkip(cdnUrl, 'not-normalize', '归一化未启用（_ptsNormalize=false）');
      return 0;
    }
    final cached = _segDeltaCache[cdnUrl];
    if (cached != null) return cached;
    final first = await _firstPesPtsInBackground(bytes);
    return _deltaFromFirstPts(cdnUrl, first);
  }

  /// 🔴🔴🔴 2026-10-24 第十轮：首个视频 PES 的 PTS 探测放**后台 isolate**。
  ///
  /// 【为什么必须挪 —— 真机实锤：hilog 2026-10-24 19:27~19:30】
  ///   `firstPesPtsMs` 要**扫描整个分片**（200~480KB）才能找到第一个视频 PES，
  ///   它原本跑在**主 isolate** 上 ⇒ 每个分片都要占住主 isolate 数百毫秒
  ///   ⇒ Flutter 无法提交渲染帧
  ///   ⇒ `OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null`
  ///      爆发 **505 次**（真机 19:27~19:30 全程）
  ///   ⇒ **画面停住、声音照常**（音频走 native 播放线程，不受影响）。
  ///   同一份日志里 position 推进速率全程 1.00x ⇒ 卡在**帧交付**环节。
  ///
  /// 【为什么本轮必须做】第十轮把媒体分片改成「完整下载 → 校验 → 写出」，
  ///   每个分片都会经过 [_deltaFor] 一次 ⇒ 若留在主 isolate，
  ///   主 isolate 的占用会比流式时代**更重** ⇒ 顿挫可能反弹。
  ///   ⇒ 探测挪到后台 isolate，主 isolate 只等结果。
  Future<int?> _firstPesPtsInBackground(Uint8List bytes) async {
    try {
      return await Isolate.run(() => firstPesPtsMs(bytes, videoOnly: true));
    } catch (e) {
      _log('首个 PES PTS 后台 isolate 不可用，回退主 isolate 同步执行：$e');
      return firstPesPtsMs(bytes, videoOnly: true);
    }
  }

  /// 🔴 2026-10-24：由「本段真实首帧 PTS」推导平移量（**纯逻辑**，无网络、无缓冲）。
  ///
  /// 【为什么要抽出来】
  ///   整段缓冲路径（[_deltaFor]）与流式路径（[_serveSegmentShiftedStream]）必须用
  ///   **同一套判据**，否则会出现「同一分片在两条路径上平移量不同」
  ///   ⇒ PTS 轴在分片边界跳变 ⇒ 进度条跳变/画面卡顿。
  ///   故判据（阈值 1 秒 / 上限 120 秒 / 源级短路 / 缓存写入 / 日志）全部收敛到本函数。
  ///
  /// [countUnreadable]：是否把「读不出视频 PTS」计入**源级不可读**短路计数。
  ///   整段路径传 true（它的短路意义是「别再为整段缓冲白付代价」）；
  ///   **流式路径必须传 false** —— 流式前缀只有 6KB，视频 PES 偶尔还没出现，
  ///   若据此判定「本源不可读」，后续所有分片都不再归一化 ⇒ **漂移回归**。
  ///   而流式路径本就没有「整段缓冲」代价，无需短路。
  int _deltaFromFirstPts(String cdnUrl, int? first,
      {bool countUnreadable = true}) {
    final meta = _segMeta[cdnUrl];
    if (meta == null) {
      // ⚠️ 这条曾经是「静默失效」的真凶：键对不上 → 每段都从这里返回。
      _logSkip(
        cdnUrl,
        'no-meta',
        '键不在 _segMeta 中（段数=${_segMeta.length}）'
        '${_segMeta.isEmpty ? "；_segMeta 为空" : ""}',
      );
      return 0;
    }
    if (first == null) {
      // 🔴🔴 2026-10-24：源级短路计数（对齐主工程 `hain_tv` 2026-10-16 修复）。
      //   「本源 PTS 能否读出」是**源级属性**：AES-128 密文源永远读不出，
      //   而每个分片都为此白付「整段缓冲 + 主 isolate 往返」的代价。
      //   连续达到阈值即判定本源不可读 ⇒ 后续分片改走流式转发。
      if (countUnreadable) {
        _ptsUnreadableStreak++;
        if (_ptsUnreadableStreak >= _kPtsUnreadableThreshold &&
            _ptsReadable != false) {
          _ptsReadable = false;
          _log('PTS 归一化：连续 $_ptsUnreadableStreak 个分片读不出视频 PTS，'
              '判定本源 PTS 不可读 ⇒ 后续分片改走流式转发（不再缓冲改写）');
        }
      }
      _logSkip(cdnUrl, 'no-pts', '本段探测不出视频首帧 PTS');
      return 0;
    }
    // 读到 PTS 即证明本源可读，清零计数器。
    _ptsUnreadableStreak = 0;
    if (_ptsReadable == null) _ptsReadable = true;
    _segFirstPtsCache[cdnUrl] = first;

    // ── 🔴🔴🔴 2026-10-24 核心修复：平移目标 = **该分片在去广告名义轴上的起点**
    //
    // 【原来错在哪】`expected = _baseFirstPts! + meta.filteredMs`，而当时的
    //   `filteredMs` 是 `index × 2000`（硬编码「每段恰好 2 秒」）。
    //   但真实源的段长**并非**整 2 秒（实测 1.72 / 1.84 / 1.88 / 1.96 /
    //   2.00 / 3.00 / 3.44 / 3.52 …），平均约 2.02 秒 ⇒ 误差随段号**线性增长**：
    //     误差(index) = Σ(真实段长) − index×2000 ≈ index × 20ms
    //   在 index≈684（23 分 48 秒处）累积到 **≈29 秒** —— 与真机日志逐字吻合：
    //     12:41:44.576  seek 到 1367.96s
    //     12:41:45.525  state.position 变成 1397.04s  ⇒ **往前跳了 29.08 秒**
    //   即用户所报「每次快进快退 / 读取播放记录，进度条在定位的时间再往后偏移」。
    //
    // 【现在怎么算】`meta.filteredMs` = 由**最终服务给播放器的**那份 media
    //   播放列表的 `#EXTINF` **真实累加**得到的轴起点（见 `_buildSegMeta`）。
    //   它与 mpv 的 `duration` **同源**（同一份播放列表、同一批 EXTINF），
    //   ⇒ 进度条的分子（time-pos）与分母（duration）同轴，偏移从根上消失。
    //   另：不再依赖任何全局基准 ⇒ 预取/直连并发、seek 后重建都无需特殊处理。
    //
    // 【与主工程的关系】主工程 `hain_tv` 2026-10-11 起即按真实 EXTINF 累加
    //   实现（`_rebuildSegMetaFromProxyPlaylist`），2026-10-18 再把锚点从
    //   「基准段真实 PTS」改为「名义值」，最终 `expected` 等价于本实现写法。
    //   本实现本次直接对齐终态。
    final expected = meta.filteredMs;
    final delta = expected - first;
    // ── 🔍 2026-10-09 轴对齐埋点：三条轴逐段对照 ──────────────────────
    //
    // 【判读要点】
    //   · first        = 本段真实首帧 PTS（轴③）
    //   · nominalFiltered = meta.index × 2000（轴① = duration 口径）
    //   · nominalOriginal = meta.prefixMs（轴② = 原始列表累加）
    //   · expected     = baseFirstPts + nominalOriginal（当前 delta 的目标轴）
    //   · trueOffset   = first - nominalFiltered（真实轴相对 duration 轴的偏移）
    //
    //   若 trueOffset 恒为 0 → 真实轴与 duration 轴同源，无需平移。
    //   若 trueOffset != 0     → position 与 duration 不同轴，UI 必然偏移。
    final nominalFiltered = meta.filteredMs;
    final trueOffset = first - nominalFiltered;
    // 只在偏移跨过整秒或每 50 段打一次，避免刷屏（1302 段全打会淹没日志）。
    final shouldLog = trueOffset != 0 &&
        ((meta.index % 50 == 0) ||
            _axisLoggedIndex == null ||
            (meta.index - _axisLoggedIndex!).abs() >= 50);
    if (shouldLog) {
      _axisLoggedIndex = meta.index;
      // 🔴 2026-10-11：打印「平移后 PTS」及其与 duration 轴的残差 —— 这是修复
      //   是否生效的**唯一判据**。修复正确时 residual 应恒为 0。
      _log('PTS axis: idx=${meta.index} seq=${meta.seq} '
          'trueFirst=${first}ms '
          'nominalFiltered=${nominalFiltered}ms '
          'nominalOriginal=${meta.prefixMs}ms '
          'trueOffset=${trueOffset}ms '
          'expected=${expected}ms delta=${delta}ms '
          'shifted=${first + delta}ms residual=${first + delta - expected}ms');
    }
    if (delta.abs() < 1000) {
      _logSkip(
        cdnUrl,
        'within-threshold',
        'seg=${meta.index} delta=${delta}ms 在阈值内（源干净）',
      );
      return 0; // 阈值内视为干净源
    }
    // ── 🔴🔴 2026-10-15：平移量上限保护 —— 拦「源内第二个 PTS 坐标系」
    //
    // 【真机现场（hilog 12-30-26，本片 1302 段 / 删 92 段）】
    //   seg 441: first=963480ms  delta=-76000ms   ← 正常
    //   seg 442: first=  1480ms  delta=+888000ms  ← 归一化算出平移 888 秒
    //   seg 457: first=969480ms  delta=-50000ms   ← 又恢复正常
    //   即 seg 442~456 这 15 段的真实首帧 PTS 属于**另一套坐标系**（从 ~0 起数），
    //   而 `expected`（去广告轴）把它当成连续的，于是 delta 被算成 +888000ms。
    //
    // 【为什么数值对、结果却坏】
    //   `shifted = first + delta == expected`（residual=0）在**算术上成立**，
    //   于是出口自校验 `verifyPtsShift` 会放行（它只核对「平移前后首帧差 == delta」）。
    //   但把这 15 段各自整体 +888 秒后，它们内部的每一帧时间戳都被推前 888 秒，
    //   而它们前后的分片（seg 441 / seg 457）仍停在 96 万毫秒附近 ——
    //   mpv 的 HLS demuxer 遇到这种「相邻分片 PTS 断层 888 秒」会错乱时间轴：
    //     真机实测 20:29:47 position 883996ms → 843996ms（**倒退 40 秒**）
    //     20:29:58 起 position 停在 858716ms 不再前进（**画面卡死**）
    //   而此时软件层完好（能退出播放、能快进快退），与用户描述逐字吻合。
    //
    // 【修法】平移量超过上限时不平移，返回 0 保持原始字节。
    //   · 上限 120 秒的依据：正常源的 |delta| = 已删广告累计时长，
    //     本次实测 -50000/-72000/-76000ms（即 50~76 秒）；120 秒留了 ~1.6 倍余量。
    //     而异常值 888 秒是该上限的 7.4 倍，不会被误判为正常。
    //   · 为什么不做「补偿到正确的另一坐标系」：删除时长的信息在 `_buildSegMeta`
    //     里已丢失（见上方 L549 附近注释），此处无法重建，只能选择不平移。
    //
    // 【对「快进快退进度条」的影响 —— 必须守住】
    //   · 正常源（|delta| <= 120s，绝大多数）走下面原路径，行为与修复前**逐字节一致**，
    //     residual 仍恒为 0 ⇒ 进度条正确性不受任何影响。
    //   · 仅异常段（本次 15 段）不平移。这是「两害相权」：原行为是整片卡死，
    //     新行为是该 30 秒区间内进度条可能与画面不同步，但不卡死、可继续播。
    //   · 返回 0 不进 `_segDeltaCache`，三条出口路径（直连/预取/缓存命中）
    //     读到的都是 0 ⇒ 语义一致，不会出现「同一段两条路径平移量不同」的跳变。
    const kPtsMaxShiftMs = 120000; // 单分片平移上限：120 秒
    if (delta.abs() > kPtsMaxShiftMs) {
      _logSkip(
        cdnUrl,
        'shift-overflow',
        'seg=${meta.index} delta=${delta}ms 超出平移上限 ${kPtsMaxShiftMs}ms，'
        '不平移（该段真实首帧 PTS=${first}ms 疑似属另一坐标系，'
        '强行平移会让 mpv 时间轴错乱并卡死）',
      );
      return 0;
    }
    _segDeltaCache[cdnUrl] = delta;
    _log('PTS normalize: seg=${meta.index} delta=${delta}ms '
        'expected=$expected first=$first url=$cdnUrl');
    return delta;
  }

  /// 🔴🔴 2026-10-24：在**后台 isolate** 里做 PTS 平移。
  ///
  /// 【为什么必须挪走 —— 这正是用户反复报的「画面时不时卡一下，声音正常」】
  ///   `normalizeTsPts` 要逐个 TS 包（188 字节）定位 PES 头并改写 PTS/DTS/PCR，
  ///   单段 150~480KB ⇒ 在主 isolate 上是**毫秒级重活**。归一化开启后
  ///   **每个分片**都要走一遍；若留在主 isolate 串行执行，Flutter 提交渲染帧
  ///   的机会被挤掉 ⇒ 画面停住，而音频走 native 播放线程不受影响 ⇒
  ///   「有声音、没画面」。
  ///
  ///   注：上一轮把卡顿归因于「整段缓冲」是**误判** —— 真机日志里 93 个分片
  ///   全部走 `proxySegment stream:`（**零缓冲、零平移**），用户仍报卡顿，
  ///   说明卡顿来自 ffmpeg demuxer 在 PTS 轴分叉处的报错
  ///   （`Packet corrupt` / `Invalid audio PTS` / `A-V desynchronisation`）。
  ///   但归一化一旦真正开启，平移的开销就会**实打实**落在主 isolate 上，
  ///   所以这一层必须提前隔离掉，否则修好偏移的同时会制造新的卡顿。
  ///
  /// 【代价】isolate 创建 ~1ms + 字节拷贝（memcpy，300KB 级）⇒ 每段约
  ///   1~2ms；1328 段全量平移总开销 < 3 秒，分摊到整集播放无感。
  ///
  /// 【失败回退】鸿蒙 isolate 若不可用则抛异常 ⇒ 返回 null，由调用方回退到
  ///   主 isolate 同步执行 —— 宁可卡顿也不能不归一化（偏移是硬伤）。
  Future<Uint8List?> _normalizeInBackground(Uint8List bytes, int delta) async {
    try {
      return await Isolate.run(() => normalizeTsPts(bytes, delta));
    } catch (e) {
      _log('PTS 平移后台 isolate 不可用，回退主 isolate 同步执行：$e');
      return null;
    }
  }

  /// 🔴🔴🔴 2026-10-24：**流式**平移转发 —— 消除「整段缓冲」造成的首字节延迟。
  ///
  /// 【真机实锤：hilog 2026-10-24 07:52（本片源 1328 段）】
  ///   · 分片「收到请求 → 吐出首字节」中位 **1168ms**、首片 **2.3s**。
  ///     成因：PTS 平移要求整段缓冲 ⇒ 代理必须**把整个分片下载完**才能吐第一个字节。
  ///   · 而每分片内容仅约 2 秒 ⇒ 播放器缓冲在**每个分片边界**被反复饿空
  ///     ⇒ **画面停住、音频照常**（音频走 native 播放线程，不受影响）。
  ///   · 同期 mpv 的 position 推进速率全程 **1.00x**（数据供给其实跟得上），
  ///     但 `OH_NativeImage_AcquireNativeWindowBuffer() failed or buffer is null`
  ///     爆发 **1436 次**（28 个突发段，单段最多 200 次 ≈ 停顿 6.7 秒）
  ///     ⇒ 卡在**帧交付**环节，不在数据环节。
  ///   · avp（AVPlayer）同样走本代理（`http://127.0.0.1:<port>/playlist.m3u8`），
  ///     供给间隔实测 1.17 秒/段 而内容需要 2.13 秒/段 ⇒ 持续落后 ⇒ avp 也卡。
  ///
  /// 【解法】PTS 平移是「给每个包加同一个常数」，**包与包完全独立**，
  ///   根本不需要「整段缓冲后一次性改写」⇒ 可以**边下边改边吐**。
  ///   只需先缓冲到能判定 delta 为止（首个视频 PES 的 PTS，通常在前 2~3 个
  ///   TS 包内，≤ 1KB），随后立刻流式输出 ⇒ 首字节延迟降到「一个网络 chunk」。
  ///
  /// 【安全约束】
  ///   ① 判定 delta 之前**不吐出任何字节** ⇒ 判据不成立时可安全退回
  ///      「原样透传」（与原 `verifyPtsShift` 失败回退原字节的语义一致）；
  ///   ② 平移量与整段路径**共用** [_deltaFromFirstPts] ⇒ 两条路径判据一致，
  ///      不会出现「同一分片两条路径平移量不同」导致的轴跳变；
  ///   ③ Range 请求**不走本路径**（拿不到分片开头，误判首个 PES 会静默损坏字节）。
  Future<void> _serveSegmentShiftedStream(
    HttpRequest request,
    http.StreamedResponse streamed,
    String cdnUrl,
  ) async {
    final out = request.response;
    final len = streamed.contentLength;
    if (len != null) out.headers.set('Content-Length', len.toString());

    // ── delta 判定（与整段路径共用同一套判据）──────────────────────
    int resolveDelta(int? firstPts) {
      if (firstPts != null) {
        // countUnreadable=false：流式前缀只有约 6KB，个别分片的视频 PES
        // 可能尚未出现，不能据此判定「本源不可读」（那会导致漂移回归）。
        return _deltaFromFirstPts(cdnUrl, firstPts, countUnreadable: false);
      }
      // 前缀里还没出现视频 PES：若预取/缓存已算好 delta 则沿用
      //（同一分片已被完整探测过，可信）；否则本段不平移
      //（与整段路径「no-pts ⇒ delta=0」语义一致）。
      return _prefetchDelta[cdnUrl] ?? _segDeltaCache[cdnUrl] ?? 0;
    }

    final shifted = shiftTsSegment(
      streamed.stream,
      resolveDelta,
      onDecided: (delta, firstPts) {
        if (delta != 0) {
          // 缓存存**原始字节**，delta 供预取出口施加 ⇒ 与直连路径同语义。
          _prefetchDelta[cdnUrl] = delta;
          _segDeltaCache[cdnUrl] = delta;
        }
        _log('proxySegment PTS+${delta != 0 ? "$delta" : ""}ms stream(flow): '
            '$cdnUrl status=${streamed.statusCode}');
      },
      onVerifyFailed: (reason, before, after) {
        _log('PTS 平移自校验失败（流式路径改为原样透传） '
            '($reason before=$before after=$after) $cdnUrl');
      },
    );
    // 🔍 2026-10-24 观测：实际吐出的字节数必须与 Content-Length 一致。
    //   若不一致（如「包起点定位丢字节」），播放器拿到的是**残缺分片** ⇒
    //   AVFoundation 会拒收并反复重试 ⇒ 死锁（真机 08:21 实锤）。
    //   这条日志是区分「字节损坏」与「时间戳不兼容」的唯一直接证据。
    var sent = 0;
    var firstChunkMs = -1;
    final sw = Stopwatch()..start();
    final counted = shifted.map((c) {
      if (firstChunkMs < 0) firstChunkMs = sw.elapsedMilliseconds;
      sent += c.length;
      return c;
    });
    await out.addStream(counted);
    await out.close();
    final declared = streamed.contentLength;
    if (declared != null && declared != sent) {
      _log('⚠️ proxySegment 流式字节数与 Content-Length 不一致: '
          'declared=$declared sent=$sent delta=${sent - declared} $cdnUrl');
      // 🔴🔴 2026-10-24 第九轮：残缺分片**立刻**后台补齐。
      //   播放器收到残缺数据 ⇒ 解码失败 ⇒ 会**重试**同一段；
      //   补齐后缓存里是完整字节 ⇒ 重试一次即成功 ⇒ 不再反复卡顿。
      //   （真机 18:37:10 / 18:37:52 两次残缺都是同一段 pUr8NL28.ts。）
      _scheduleSegmentRepair(cdnUrl);
    } else {
      _log('proxySegment 流式字节守恒: $sent bytes '
          '首字节=${firstChunkMs}ms 总耗时=${sw.elapsedMilliseconds}ms $cdnUrl');
    }
  }

  /// 记录一次「未平移」的决策（方案 A 诊断日志，纯观测，不影响行为）。
  void _logSkip(String cdnUrl, String reason, String detail) {
    _log('PTS skip: $reason seg=${_segMeta[cdnUrl]?.index ?? "-"} $detail');
  }


  void _log(String message) {
    WindowsLogger.log('LocalM3u8Proxy', message);
  }

  /// 🔴🔴🔴 2026-10-24（第十七轮）：**按分片去重的日志**（只打「每个分片第一次」）。
  ///
  /// 【为什么需要 —— 真机 hilog 2026-10-24 22:38:46~22:39:45（14-39-46.txt）】
  ///   20 秒内本代理打出 **947 条唯一日志**（hilog 里每行还被重复 15 次
  ///   ⇒ 实际写入约 1.4 万行）。其中绝大多数是**正常顺序播放**的每段一条：
  ///     Prefetch: 命中并缓存 …            158 条
  ///     Prefetch: 缓存命中(整段) …         127 条
  ///     Proxy: 复用预取中的分片 …          56 条
  ///     Prefetch: 位置跳变 …               42 条  ← 顺序播放也会打！
  ///
  ///   而 `WindowsLogger.log` → `print` → Flutter 引擎 → **同步 syslog 写**，
  ///   每行都是主 isolate 上的同步字符串拼接 + 系统调用。
  ///   1.4 万行足以拖慢起播：本轮 master 展开下载 1560ms（上轮 1332ms）、
  ///   裁剪→prepared 1372ms（上轮 861ms）。
  ///
  /// 【策略】正常播放路径的高频日志改为「每分片只打一次」；
  ///   seek/错误/自愈等**低频且关键**的日志仍走 [_log] 全量保留。
  ///   这样日志量从 O(段数×次数) 降到 O(段数)，且不丢任何诊断信息
  ///   （同一分片的重复命中本就无信息量）。
  void _logOnce(String key, String message) {
    if (!_loggedOnceKeys.add(key)) return;
    // 兜底：极端长播（数千段）时清空，避免 Set 无界增长。
    if (_loggedOnceKeys.length > 4096) {
      _loggedOnceKeys.clear();
      _loggedOnceKeys.add(key);
    }
    // ⚠️ 用 logDirect 而非 WindowsLogger.log：后者走 debugPrintThrottled
    //   （12KB/秒限速 + 无上限排队），预取高峰会积压数 MB、拖慢主 isolate
    //   ⇒ 直接表现为「起播变慢」。logDirect 只绕过控制台出口的节流，
    //   文件出口与 log 完全一致，不丢日志。
    AppLogger.logDirect('LocalM3u8Proxy', message);
  }

  final Set<String> _loggedOnceKeys = <String>{};

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
    _log('LocalM3u8Proxy started at $baseUrl');
    return baseUrl!;
  }

  /// 设置当前播放列表内容与原始请求头。
  /// [prefetch] 是否开启本源的并发分片预取（由 AdFilterEngine 按开关 + 平台传入）。
  void setPlaylist(String content, Map<String, String> headers,
      {bool prefetch = false}) {
    // 🔴🔴 2026-10-24 第七轮：**master 内容未变 ⇒ 保留展开缓存与分片缓存**。
    //
    // 【真机实锤：hilog 2026-10-24 10:08】用户换了 2 次源（zuidazy.co →
    //   caiji.moduapi.cc），但两次指向**同一个视频**、master 也**逐字节相同**
    //   （https://play.modujx17.com/20260915/ZDZnPg2F/index.m3u8，118 字节）。
    //   而每次换源都把 107954 字节的 media playlist **重新下载一遍**：
    //     18:05:57.204  master 展开：下载 2475ms + 过滤 328ms
    //     18:07:03.171  master 展开：下载 2180ms + 过滤 338ms
    //     18:07:38.979  master 展开：下载 1284ms + 过滤 300ms
    //   ⇒ 每次换源白等 1.3~2.5 秒（用户看到的就是「切源后黑屏两秒」）。
    //
    // 【为什么可以复用】展开结果是 master 内容的**纯函数**
    //   （同 master ⇒ 同变体 URL ⇒ 同 media playlist）。
    //   master 文本逐字节相同 ⇒ 展开结果必然相同 ⇒ 复用是安全的。
    //   同理，已缓存的**分片字节**也仍然有效（分片 URL 不变）。
    //
    // ⚠️ 边界：master 文本不同（换集 / 换视频）时，一切照旧清空 ——
    //   绝不能把上一个视频的 media playlist 喂给新视频。
    // 判定「同源」需同时满足：master 文本相同 **且** 请求头相同。
    //   · master 文本在 `setPlaylist` 之前已被 `resolveRelativeUrls` 解析为
    //     **绝对 URL** ⇒ 文本相同即变体 URL 相同 ⇒ 展开结果必然相同；
    //   · 请求头（Referer/Authorization 等）不同则 CDN 可能返回不同内容，
    //     此时必须重下。
    final sameHeaders = _baseHeaders.length == headers.length &&
        headers.entries.every((e) => _baseHeaders[e.key] == e.value);
    final samePlaylist = content == _playlistContent && sameHeaders;
    _playlistContent = content;
    _prefetchEnabled = prefetch;
    if (samePlaylist) {
      _log('Prefetch: master 内容未变，复用展开缓存与分片缓存'
          '（省掉一次 media playlist 重下 + ${_segmentUrls.length} 段分片重下）');
      _baseHeaders
        ..clear()
        ..addAll(headers);
      // 与正常路径一致：预热是 fire-and-forget，绝不 await（会把下载加进起播延迟）。
      unawaited(_warmupExpandedPlaylist());
      return;
    }
    _clearPrefetchCache();
    // 换源/换集必须重置展开缓存，否则会沿用上一个源展开出的 media playlist。
    _expandedPlaylist = null;
    _expandedAt = null;
    _expandedTtl = _kExpandedTtl;
    _expandedAdFree = false;
    // 换源/停机时丢弃在途展开句柄：新代次必须重新展开，绝不能复用旧源结果。
    // （`_expandInFlightGen` 代次校验已能兜住，这里显式清掉让语义更直白。）
    _expandInFlight = null;
    _expandInFlightGen = -1;
    // 原始 media playlist 同理：新源必须重新注入，否则会拿旧源的名义轴
    // 去算 PTS delta（跨源污染 → PTS 被改坏）。
    setOriginalMediaPlaylist(null);
    // 代次自增，让仍在途的旧源展开结果作废（见 _playlistGen 注释）。
    _playlistGen++;
    _baseHeaders
      ..clear()
      ..addAll(headers);
    // 🔴 2026-10-08 新增：**主动预热 master 展开**，不要等 mpv 来要。
    //
    //   【为什么必须预热】真机 hilog 2026-10-08 23:03 实测的起播时序：
    //     23:03:26.068  handleMethod open（mpv 立刻请求 playlist.m3u8）
    //     23:03:29.125  首个 proxySegment 请求 ← 代理此时才开始下载子 m3u8
    //     23:03:34.470  拿到子 m3u8 raw        ← 耗时 5.4 秒
    //     23:03:34.742  子 M3U8 过滤: 92 个片段
    //     23:03:42.253  file-loaded            ← open 后 16.2 秒
    //     23:03:45.382  playback-restart       ← open 后 19.3 秒，用户才看到画面
    //   即：**mpv open 之后、真正拿到分片之前，有 8.4 秒纯粹在等代理展开 master。**
    //   用户感受就是「起播速度明显变慢」。
    //
    //   【为什么预热是安全的】`_resolvePlaylistContent` 本身带 TTL 缓存与
    //     `_playlistGen` 代次校验（展开期间换源则结果作废），预热只是把这次
    //     IO **提前**到 open 之前发生，不改任何字节、不改判据。
    //     即便预热失败，也只是回到「懒展开」的原行为，不会让播放变坏。
    //
    //   【为什么用 unawaited 而不 await】setPlaylist 在 open 主链路上被同步调用，
    //     await 会把 5.4 秒的下载直接加进起播延迟 —— 与目标相反。
    //     这里只要「让 IO 在后台跑起来」，mpv 来要时通常已就绪或接近就绪。
    unawaited(_warmupExpandedPlaylist());
  }

  /// 🔴 2026-10-08 新增：预热 master → media 的展开（失败静默，不影响播放）。
  ///
  /// 仅当当前 playlist 确实是 master（含 `#EXT-X-STREAM-INF` 且无 `#EXTINF`）时
  /// 才有意义 —— 否则 `_resolvePlaylistContent` 走同步分支，无需预热。
  Future<void> _warmupExpandedPlaylist() async {
    final content = _playlistContent;
    if (content == null || !_isMasterPlaylist(content)) return;
    // 已展开且在 TTL 内 → 无需重复下载。
    final at = _expandedAt;
    if (at != null && DateTime.now().difference(at) < _expandedTtl) return;
    final gen = _playlistGen;
    final sw = Stopwatch()..start();
    try {
      // 直接调用 _resolvePlaylistContent：它内部已完成「下载 + 重写 + 缓存 + 收集分片」，
      // 预热成功后再有请求进来就命中 L597 的 TTL 缓存，零网络等待。
      await _resolvePlaylistContent();
      if (gen != _playlistGen) return;
      // 🔴 2026-10-26（第二十轮）：文案改为「播放器」——
      //   该预热对 avplayer 与 mpv 一律生效，原文案只写 mpv 会误导排查。
      _log('master 预热完成: 耗时 ${sw.elapsedMilliseconds}ms'
          '（播放器首次请求 playlist 时将命中缓存，无需再等展开）');
    } catch (e) {
      // 预热失败不改变任何行为 —— 后续请求仍会走正常的懒展开路径。
      _log('master 预热失败（不影响播放，退回懒展开）: $e');
    }
  }

  Future<void> stop() async {
    _closing = true;
    await _server?.close(force: true);
    _server = null;
    _playlistContent = null;
    _expandedPlaylist = null;
    _expandedAt = null;
    _expandedAdFree = false;
    // 换源/停机时丢弃在途展开句柄：新代次必须重新展开，绝不能复用旧源结果。
    // （`_expandInFlightGen` 代次校验已能兜住，这里显式清掉让语义更直白。）
    _expandInFlight = null;
    _expandInFlightGen = -1;
    _playlistGen++;
    // 换源/停机必须清掉原始 media playlist 与名义轴 —— 否则新源会拿
    // 上一个源的时间轴基准去计算 PTS delta（跨源污染）。
    setOriginalMediaPlaylist(null);
    _baseHeaders.clear();
    _clearPrefetchCache();
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
          ..write('Not found');
        await request.response.close();
      }
    } catch (e, stack) {
      // 🔴 2026-10-23（第八轮）：代理**停止过程中**的在途请求异常属正常收尾，
      // 不再打完整堆栈（实测真机：39 行堆栈噪音淹掉真正的错误）。
      // 判断用 `_client == null`（`_closing` 在 stop() 末尾已复位，
      // 而在途请求的异常回调发生在那之后）。
      if (_closing || _client == null) {
        _log('LocalM3u8Proxy 请求在代理停止时中断: $e');
      } else {
        _log('LocalM3u8Proxy handleRequest error: $e');
        _log('$stack');
      }
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal server error');
        await request.response.close();
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
    // 🔴 2026-10-24：起播裁剪 —— 让列表第 0 片就是落点片，
    // AVPlayer 便可从落点直接起播，完全不需要 seek（详见 _trimStartIndex 注释）。
    final bytes = utf8.encode(_applyStartTrim(content));
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

  /// 清空并发预取缓存（换源/换集/stop 时调用），避免旧源分片污染新源。
  void _clearPrefetchCache() {
    _prefetchCache.clear();
    _prefetchDelta.clear();
    _prefetchQueue.clear();
    _prefetchTotalBytes = 0;
    _prefetchFailCount = 0;
    // 🔴 2026-10-24 第六轮：预取改为**多 worker 并发**后，不能再用布尔位
    //   `_prefetchRunning` 表示「有预取在跑」—— 换源时若把它直接置 false，
    //   旧 worker 还阻塞在下载里，新一轮 `_drainPrefetchQueue` 就会**叠加**
    //   第二组 worker（并发数翻倍、旧源分片继续下载）。
    //   改用**代次号**：换源即 +1，worker 每轮检查代次，不一致立刻退出。
    _prefetchGen++;
    _segmentUrls = const [];
    _segmentIndex = const {};
    _segmentStartMs = const [];
    // 🔴 2026-10-24 第七轮：换源 ⇒ 预热目标与挂起目标一并作废
    //   （旧源的下标对新源无意义）。
    _prefetchTargetIndex = null;
    _prefetchTargetAt = null;
    _pendingPrefetchTargetMs = null;
    // 🔴 2026-10-24（第十三轮）：换源 ⇒ 起播裁剪状态一并作废
    //   （旧源的落点下标/偏移对新源无意义；若不清，新源会按旧 offset 换算 position）。
    _trimStartIndex = null;
    _trimOffsetMs = null;
    _collectedFrom = null;
    _prefetchEmptyWarned = false;
    // 🔴 2026-10-24 第九轮：换源 ⇒ 直连标记与修复标记一并作废
    //   （旧源的分片 URL 对新源无意义；in-flight 的 Future 本身不能取消，
    //   它自然结束即可，只是不能再让新源去等它）。
    _segmentDirectFetching.clear();
    _segmentRepairInFlight.clear();
  }

  /// 从重写后的 playlist 内容中按出现顺序收集媒体分片【CDN 原始 URL】。
  ///
  /// 供 _proxySegment 命中当前分片后定位下标、预取后续 N 个。
  /// 统一以解码后的 CDN 原始 URL 作为预取 key：播放器每次分片请求都进入
  /// _proxySegment 并持有同一份 targetUrl（/segment?url=<enc(CDN_url)> 解码结果），
  /// _schedulePrefetch/_storePrefetched/_servePrefetched 全部基于该 key 匹配，
  /// 避免旧实现「收集的是代理 URL、匹配的却是 CDN URL」导致 indexOf 恒为 -1、
  /// 预取队列永远为空、预取完全不生效。
  void _collectSegmentUrls(String rewrittenPlaylist) {
    // 🔴 2026-10-15 幂等守卫：同一份 playlist 内容不重复解析。
    //   真机 hilog 2026-10-15 19:52 实证：`Prefetch: 收集分片 1302 个` 在
    //   19:52:13.217 / .226 **同一毫秒内出现两次**，19:52:14.4xx 附近又连出现
    //   4 次 —— 一次起播共重复解析 6 遍 × 1302 行。成因是 `_resolvePlaylistContent`
    //   的 TTL 缓存分支每次请求都无条件重新收集，而预热路径与 mpv 首次请求
    //   会先后命中同一份缓存内容。
    //   分片表与内容一一对应，内容不变则解析结果必然相同，重复执行纯属浪费。
    if (_collectedFrom == rewrittenPlaylist) return;
    _collectedFrom = rewrittenPlaylist;

    final lines = rewrittenPlaylist.split('\n');
    final urls = <String>[];
    // 🔴 2026-10-24 第七轮：同步累计 **名义轴**（EXTINF 累加）起点，
    //   与 urls **同序等长** ⇒ 下标一一对应。
    //   用途：把播放位置换算成分片下标（seek 预热）。
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
        final cdn = _extractTargetUrl(t);
        if (cdn.isNotEmpty) {
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
    // 🔴 2026-10-24 第六轮：同时建立 URL → 下标映射，供预取队列按下标
    //   丢弃过时项（seek 后队列里堆的旧位置分片）O(1) 判定。
    final index = <String, int>{};
    for (var i = 0; i < urls.length; i++) {
      index.putIfAbsent(urls[i], () => i);
    }
    _segmentIndex = index;
    // 🔴 2026-10-07 预取诊断：确认收集结果。此前预取静默失效时无任何日志可查，
    //   只能在代码里推断（且推错过一次）。此处打印真实收集到的分片数，
    //   以及第一片样本，便于一眼判断「是重写没生效」还是「收集条件把它滤掉了」。
    _log('Prefetch: 收集分片 ${urls.length} 个'
        '${urls.isEmpty ? " —— 重写后无 /segment?url= 行，预取将整源失效！" : "，首片=${urls.first}"}');

    // 🔴 2026-10-24 第七轮：分片表刚就绪 ⇒ 补做此前挂起的「seek/起播定位预热」。
    if (_pendingPrefetchTargetMs != null && urls.isNotEmpty) {
      final pending = _pendingPrefetchTargetMs!;
      _pendingPrefetchTargetMs = null;
      primePrefetchAt(Duration(milliseconds: pending));
    }
  }

  /// 🔴🔴 2026-10-24 第七轮：**把预取窗口预热到指定播放位置**。
  ///
  /// ## 为什么必须做（真机 hilog 2026-10-24 10:08 实锤）
  ///
  /// ```
  /// 18:07:00.621 MpvBackend open: ... startAt=0:23:30.767000   ← 起播定位到 1410.767s
  /// 18:07:03.628 [mpv-seek] 看门狗触发：3s 内未收到 playback-restart
  /// 18:07:05.216 [mpv-event] seek          ← 4.6s 后 mpv 才真正开始 seek
  /// 18:07:07.498 seek 落点核对: 请求=1410.767s 落点=1410.767s ✅
  /// ```
  ///
  /// ⇒ **open 到落点整整 6.9 秒**。avplayer 侧同样：
  ///
  /// ```
  /// 18:06:09.961 [SEEK-DIAG] seek target=1364790ms
  /// 18:06:10.335 buffering=true … 18:06:12.735 buffering=true   ← 冻结 3.6 秒
  /// ```
  ///
  /// ## 真因
  ///
  /// 代理的预取窗口**跟着播放头走**。而 seek / 起播定位发生时：
  ///
  /// - avplayer：原生侧在 `create` 阶段就预置了 1508000ms 的落点，
  ///   代理此刻的播放头仍是 0；
  /// - mpv：`open(startAt)` 发生在 master 展开完成之前（展开要 1.1~2.8s），
  ///   代理此刻更是连分片表都还没有。
  ///
  /// ⇒ 目标区域（下标 ~700）的分片**一个都没缓存**，
  /// 播放器只能现等 CDN 往返（单段 ttfb 0.78~2.10s）。
  ///
  /// ## 修法
  ///
  /// 在 seek / 起播定位**之前**把目标位置告诉代理，代理立刻：
  ///
  /// 1. 用名义轴把播放位置换算成分片下标；
  /// 2. 把该下标及其后续 [\_kMaxPrefetchCount] 段**入队并立即开跑**；
  /// 3. 置 [_prefetchTargetIndex]，使队列在 seek 生效前**不会**把刚预热好的
  ///    目标分片误当「旧位置」丢掉（双锚点窗口，见 `hls_prefetch_window.dart`）。
  ///
  /// 分片表尚未就绪时（mpv `open` 早于 master 展开）先记下位置，
  /// 待 `_collectSegmentUrls` 收集完成后自动补做。
  void primePrefetchAt(Duration position) {
    if (!_prefetchEnabled) {
      // 预取尚未开启（开关关闭 / 还没 setPlaylist）：先把目标记下来，
      // 待分片表就绪后补做。**不要直接丢弃** ——
      // avplayer 的 create 阶段定位就发生在 setPlaylist 之前几百毫秒。
      _pendingPrefetchTargetMs ??= position.inMilliseconds;
      return;
    }
    if (_segmentUrls.isEmpty || _segmentStartMs.isEmpty) {
      _pendingPrefetchTargetMs = position.inMilliseconds;
      _log('Prefetch: 预热目标 ${position.inMilliseconds}ms 已挂起'
          '（分片表未就绪，待收集后补做）');
      return;
    }
    final idx = indexForPosition(_segmentStartMs, position.inMilliseconds);
    if (idx < 0) return;
    // 目标没变 ⇒ 无需重复入队与打日志（长按快进会高频调用）。
    if (_prefetchTargetIndex == idx && _prefetchTargetAt != null) {
      _runPrefetchQueue();
      return;
    }
    _prefetchTargetIndex = idx;
    _prefetchTargetAt = DateTime.now();
    // 目标窗口的入队（目标段自身也要预取：seek 落点正是它）。
    //
    // 🔴🔴 2026-10-24 第九轮：目标窗口**插到队首**，而不是追加到队尾。
    //
    // 【真机实锤：hilog 2026-10-24 18:37:16】
    //   18:37:16.732  Prefetch: 预热目标 1440200ms ⇒ 分片下标 701（入队 6 项）
    //   18:37:16.774  proxySegment request: DHHArizP.ts   ← **仅 42ms 后**
    //   ⇒ 播放器 seek 后**立刻**就来要落点段。目标段排在队尾 ⇒
    //     worker 还在下载旧位置的段 ⇒ 落点段迟迟不被预取 ⇒
    //     播放器只能回源（实测响应头就等了 1.5 秒）⇒ **seek 后必卡一下**。
    var added = 0;
    final targetUrls = <String>[];
    // 🔴🔴🔴 2026-10-28（起播慢 / 缓冲浅）：**必须传 targetIndex**。
    //
    // 【真机实锤：hilog 2026-10-28 14-22-03（第八版，落点 1411s）】
    //   22:21:12.320 预热目标 1411000ms ⇒ 分片下标 299（新增 16 项，窗口 299..315）
    //   但落点段 299 **从未被预取完成**（预取完成集 = 300..315，恰好 16 段）
    //   ⇒ mpv 只能自己回源拉 299，而 299 是 1848KB 的大分片
    //   ⇒ 到手耗时 **10.16 秒** ⇒ 起播慢、缓冲浅（lead 仅 1.4~12s，应达 30s）。
    //
    // 【根因】这里漏传 `targetIndex`，于是 `prefetchIndicesWithTarget` 只生成
    //   **播放头窗口** `(idx, idx+depth]` —— 它按设计**不含播放头自身**
    //   （见 hls_prefetch_window.dart:68 `prefetchWindowStart = currentIndex + 1`）。
    //   而 seek 已提交时 `currentIndex == targetIndex == idx`，
    //   ⇒ 落点段恰好是那个「被排除的自身」⇒ **永远进不了队列**。
    //
    //   日志之所以写「窗口 299..315」，是因为 _log 用 `idx` 拼字符串，
    //   与实际入队的 `300..315` 不一致 —— 日志本身误导了排查。
    //
    // 【对照证据】第七版同样漏段（落点 290 也没被预取），只是那次 290 仅
    //   289KB，回源 4.84s 尚可忍受；第八版落在 1848KB 大分片上才暴露。
    //   两版都缺「窗口首段」= 结构性缺陷，不是偶发。
    //
    // 【修法】把 `targetIndex: idx` 传进去 ⇒ 目标窗口 `[idx, idx+depth]`
    //   含落点自身，与播放头窗口合并去重后共 17 段，落点段排第一（下方排序保证）。
    for (final i in prefetchIndicesWithTarget(
      currentIndex: idx,
      depth: _prefetchDepth,
      total: _segmentUrls.length,
      targetIndex: idx,
    )) {
      final url = _segmentUrls[i];
      if (_prefetchCache.containsKey(url)) continue;
      targetUrls.add(url);
    }
    // 离落点越近越先下载（落点段本身排第一）。
    targetUrls.sort((a, b) {
      final da = ((_segmentIndex[a] ?? idx) - idx).abs();
      final db = ((_segmentIndex[b] ?? idx) - idx).abs();
      return da.compareTo(db);
    });
    // 🔴🔴🔴 2026-10-24（第十七轮）：**已在队列中的目标段必须「提到队首」，不能跳过**。
    //
    // 【真机实锤：hilog 2026-10-24 22:39（14-39-46.txt）—— seek 时好时坏的唯一差异】
    //   四次 seek 对照，`新增 N 项` 与成败**完全一致**：
    //     22:39:08  target=190474ms  新增 0 项  ⇒ ❌ 2.5s 兜底 + 6s 冻结 = 9s 才重建
    //     22:39:24  target=107956ms  新增 2 项  ⇒ ✅ 1.1s seekDone
    //     22:39:28  target=235224ms  新增 2 项  ⇒ ✅ 0.8s seekDone
    //     22:39:31  target=132417ms  新增 0 项  ⇒ ❌ 2.5s 兜底 + 6s 冻结
    //
    //   根因：旧代码 `if (cache || queue.contains(url)) continue;` ——
    //   目标段**已经在队列里**（顺序播放时播放头窗口早就把它排进去了）
    //   但位置在**队尾**（队首被更早入队的其他段占着）。
    //   此时 `continue` 让它保持原位 ⇒ 「插队首」根本没发生 ⇒
    //   落点段要等 worker 把前面所有段下完才轮到 ⇒ AVPlayer 等不到
    //   ⇒ seekDone 不派发 ⇒ 走兜底 ⇒ 用户看到「卡死」。
    //   而「新增 2 项」那两次目标段**不在**队列里 ⇒ 真的插到了队首 ⇒ 成功。
    //
    //   【修法】不在缓存里的（含已在队列中的）**一律先移出队列再插队首**。
    //   已在队列里的段若正被 worker 下载，重复入队会被 `_runPrefetchQueue`
    //   的 in-flight 去重挡住，不会重复下载；只是优先级被提到最高。
    var promoted = 0;
    for (final url in targetUrls) {
      if (_prefetchQueue.remove(url)) promoted++;
    }
    _prefetchQueue.insertAll(0, targetUrls);
    added = targetUrls.length;
    _logOnce('prime:$idx:$added', 'Prefetch: 预热目标 '
        '${position.inMilliseconds}ms ⇒ 分片下标 $idx'
        '（新增 $added 项入队到队首，其中 $promoted 项由队尾提前，'
        '窗口 $idx..${idx + _prefetchDepth}，'
        '实际入队首段=${targetUrls.isEmpty ? "无" : _segmentIndex[targetUrls.first]}）');
    // 🔴🔴🔴 2026-10-24 第十一轮：**建索引头部段插到队首**（原先排在队尾 = 最低优先级）。
    //
    // 【为什么 —— 真机实锤：hilog 2026-10-24 20:00:46~20:00:58（avp 首次起播 11.4s）】
    //   AVPlayer 打开 m3u8 后，会**从第 0 段开始**顺序拉若干分片
    //   （凑起播水位 + 建立播放列表索引），才能执行 seek 落点。实测：
    //     20:00:49.672 请求第 0 段 → 20:00:53.080 才拿到   （等 3.4s）
    //     20:00:53.096 请求第 1 段 → 20:00:54.879 才拿到   （等 1.8s）
    //     20:00:54.893 请求第 2 段 → 20:00:56.000 才拿到   （等 1.1s）
    //     20:00:55.068 请求第 3 段 → 20:00:57.515 才拿到   （等 2.4s）
    //     20:00:57.919 SEEK_DONE（open 后 11.2s）
    //   每段都等 1~3.4 秒的原因：此刻 4 个预取 worker **全被落点窗口
    //   745..761 占满**，头部段排在队尾 ⇒ 只能等 worker 空出来才轮到自己。
    //   而源站单连接仅 ~235KB/s（并发时才 ~2.7MB/s），串行 4 段 ≈ 8 秒。
    //
    // 【改法】头部段**插队首**（比落点窗口更早开跑），并把数量从 3 提到 8。
    //   依据：对 avp 而言**建索引是阻塞项** —— 索引没建成，seek 根本发不出去，
    //   落点段备得再快也没用；建好索引后还有解码时间，落点段来得及。
    //   对 mpv 无影响：mpv 走 startAt 直接 seek，不需要建索引；
    //   多备 8 段头部只是多 8 个并发下载，摊在 8 路 worker 上约 1 秒。
    // 🔴 2026-10-24（avp 快起播）：头部段数量按后端收窄。
    //   8 段是「队列 24 段、worker 4 路」时落点段被挤到第 9~24 位的元凶。
    //   avp 收窄为 4 ⇒ 队列 = 4 头部 + 2 落点 = 6 段，两轮 worker 即可全部下完。
    final headHi = (_indexHeadSegments - 1).clamp(0, _segmentUrls.length - 1);
    final headItems = <String>[];
    for (var i = 0; i <= headHi; i++) {
      final url = _segmentUrls[i];
      if (_prefetchCache.containsKey(url) || _prefetchQueue.contains(url)) continue;
      headItems.add(url);
    }
    if (headItems.isNotEmpty) {
      // 🔴 插到**队首**：建索引是 avp 的阻塞项，必须比落点窗口先开跑。
      //   （原先 addAll 到队尾 ⇒ 排在落点窗口之后 ⇒ 必然等 worker 空转。）
      _prefetchQueue.insertAll(0, headItems);
      _log('Prefetch: 建索引头部段插队首 0..$headHi（${headItems.length} 项）'
          '—— 播放器从头部起拉以建立播放列表索引（阻塞项，优先于落点窗口）');
    }
    _runPrefetchQueue();
  }

  /// 返回 `playlist.m3u8` 的响应体：master 就地展开为 media（见 `_expandedPlaylist` 注释）。
  Future<String> _resolvePlaylistContent() async {
    final content = _playlistContent ?? '#EXTM3U\n#EXT-X-ENDLIST\n';

    if (!_isMasterPlaylist(content)) {
      final finished = _finish(content);
      if (_prefetchEnabled) _collectSegmentUrls(finished);
      return finished;
    }

    // TTL 窗口内直接复用（展开成功用展开结果；失败则退回原 master，不做重试风暴）。
    final at = _expandedAt;
    if (at != null && DateTime.now().difference(at) < _expandedTtl) {
      final cached = _finish(_expandedPlaylist ?? content);
      if (_prefetchEnabled) _collectSegmentUrls(cached);
      return cached;
    }

    // 🔴 2026-10-15 单飞闸门：若已有同代次的展开在途，直接复用它，不要各下各的。
    //
    //   真机实证（见 `_expandInFlight` 注释）：预热链路与 mpv 首次请求会在
    //   TTL 尚未建立时并发穿透，把一次展开变成两次、相隔仅 500ms 左右，
    //   起播平白多等一整轮 1.4~2.4s 的 CDN 往返。
    //   这里只做「合并同代次的在途请求」，不改展开逻辑本身。
    //
    //   ⚠️ 代次校验：在途展开若是**上一代次**留下的（期间已换源），绝不能复用，
    //      否则新源会拿到旧源的 media playlist。此时丢弃句柄重新展开。
    final inflight = _expandInFlight;
    if (inflight != null && _expandInFlightGen == _playlistGen) {
      _log('master 展开：命中在途展开，复用之（避免重复下载）');
      try {
        return await inflight;
      } catch (e) {
        // `_expandMasterOnce` 自身已把展开异常转为 fallback，正常不会到这里；
        // 但 `_finish` 等收尾步骤仍可能抛出。复用方必须与发起方行为一致 ——
        // 回退原 master，而不是把异常抛给 HTTP 处理链路（那会变成 500）。
        _log('master 展开：复用在进行途展开时异常，回退原 master: $e');
        final fallback = _finish(_expandedPlaylist ?? content);
        if (_prefetchEnabled) _collectSegmentUrls(fallback);
        return fallback;
      }
    }

    final variantUrl = _extractFirstVariantUrl(content);
    if (variantUrl == null) {
      _log('master 展开：未找到变体 URL，保持原样');
      _expandedAt = DateTime.now();
      final plain = _finish(content);
      if (_prefetchEnabled) _collectSegmentUrls(plain);
      return plain;
    }

    final gen = _playlistGen;
    final future = _expandMasterOnce(content, variantUrl, gen);
    _expandInFlight = future;
    _expandInFlightGen = gen;
    try {
      return await future;
    } finally {
      // 只有「自己仍是当前在途句柄」时才清理，避免把后继者的句柄清掉。
      if (identical(_expandInFlight, future)) {
        _expandInFlight = null;
        _expandInFlightGen = -1;
      }
    }
  }

  /// 🔴 2026-10-15 抽出：执行一次 master → media 的展开（供单飞闸门调用）。
  ///
  /// 与原内联实现逐行等价，仅把「下载 → 代次校验 → 缓存 → 收尾」独立成方法，
  /// 便于被 `_expandInFlight` 复用为同一个 Future。
  Future<String> _expandMasterOnce(
    String content,
    String variantUrl,
    int gen,
  ) async {
    try {
      final expanded = await _fetchAndRewriteM3u8(variantUrl);
      // 展开期间若已换源/换集，本次结果作废，否则会把上一个源的 media playlist
      // 写进缓存，导致新源播错内容。
      if (gen != _playlistGen) {
        _log('master 展开结果作废（期间已换源）: $variantUrl');
        final stale = _finish(_playlistContent ?? content);
        if (_prefetchEnabled) _collectSegmentUrls(stale);
        return stale;
      }
      _expandedAt = DateTime.now();
      if (expanded == null || expanded.trim().isEmpty) {
        // 展开失败 ⇒ 回退原 master。这种结果**不能**按点播长 TTL 缓存。
        _expandedTtl = _kExpandedTtl;
        _log('master 展开失败（下载/重写为空），回退原 master: $variantUrl');
        final fallback = _finish(_expandedPlaylist ?? content);
        if (_prefetchEnabled) _collectSegmentUrls(fallback);
        return fallback;
      }
      _expandedPlaylist = expanded;
      _log('master 展开为 media（单级）成功: $variantUrl');
      final finished = _finish(expanded);
      // 🔴 2026-10-07 修复：master 展开分支**必须**收集分片 URL。
      //    此前只在 `!_isMasterPlaylist` 分支调用 _collectSegmentUrls，
      //    导致所有 master 型源（如 yyv15.qwe132456.cc）的 _segmentUrls 恒为空，
      //    _schedulePrefetch 在 `if (_segmentUrls.isEmpty) return;` 处静默返回，
      //    HLS 并发分片预取**完全未生效**（真机日志实证：预取关键字 0 次）。
      if (_prefetchEnabled) _collectSegmentUrls(finished);
      return finished;
    } catch (e) {
      _log('master 展开异常，回退原 master: $e');
      if (gen == _playlistGen) _expandedAt = DateTime.now();
      final fallback = _finish(_expandedPlaylist ?? content);
      if (_prefetchEnabled) _collectSegmentUrls(fallback);
      return fallback;
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
    // 超时必须**小于**播放器的 open 超时（`openTimeout`，默认 15s）：本方法是
    // libmdk 打开 playlist 时的**同步等待**调用，展开耗时会被原样加到起播耗时里。
    // 实测（2026-09-26 日志）：源1（944 分片）展开仅 1s，但源4（1401 分片）展开
    // 耗了 **10s**，叠加其后 initialize 共约 16s → 越过 15s 上限 → `播放失败`，
    // 该源连画面都没出。
    //
    // 🔴 2026-10-15 调整：3s → 8s（与主工程 `hain_tv` 对齐）。
    //   【为什么必须放宽】真机 hilog 2026-10-15 19:52 实测 master 变体下载耗时
    //   分布为 1392/1460/1550/2230/2339/2402 ms —— **后两次直接撞上 3s 上限**，
    //   日志出现 2 次 `master 展开异常，回退原 master: TimeoutException`。
    //   回退后 mpv 拿到的是未展开的 master，PTS 归一化失去最终 media 列表，
    //   起播被拉长且偶发 `播放失败`。
    //   【为什么 8s 安全】预热路径（`_warmupExpandedPlaylist`）用 `unawaited`
    //   异步执行，**不在** open 同步链路上，放宽不会拖慢 open；而 8s 仍留出
    //   7s 给后续 initialize，低于 15s 上限。若 8s 仍超时，行为与 3s 相同
    //   （回退原 master），不劣于放宽之前。
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
    // 🔴 HeinPlay 修复（2026-10-08）：必须在**过滤之前**把原始 media playlist
    //   交给代理保存，作为 PTS 名义时长轴的基准。
    //   若在过滤之后取，删除分片造成的时长缩短会被误当成 PTS 偏差，
    //   导致 normalizeTsPts 把正确的 PTS 改坏 —— 真机表现为
    //   `Invalid audio PTS` → `Reset playback` → 进度条重建 + 音画不同步。
    //   详见 `_originalMediaPlaylist` 的完整说明。
    setOriginalMediaPlaylist(decoded);
    // 🔴 2026-10-24 第七轮：按**原始上游内容**判定点播/直播，决定展开缓存 TTL。
    //   点播（含 ENDLIST）⇒ 分片列表静态 ⇒ TTL 5 分钟，换源不再重复下载；
    //   直播（无 ENDLIST）⇒ 保持 3 秒刷新节奏，行为与此前完全一致。
    //   注意：判定必须用**原始**内容，不能用重写后的（重写路径会补 ENDLIST）。
    final isVod = decoded.contains('#EXT-X-ENDLIST');
    _expandedTtl = isVod ? _kExpandedTtlVod : _kExpandedTtl;
    final filterSw = Stopwatch()..start();
    final filtered = _filterEnabled
        ? _filterM3u8(
            targetUrl,
            decoded,
            cleanDiscontinuities: _discontinuityCleanup,
          )
        : decoded;
    final filterMs = filterSw.elapsedMilliseconds;
    // 🔴 2026-10-15 新增：记录本代次是否「无广告」（过滤前后一字节未变）。
    //   无广告源可跳过相对路径解析的直接重写开销（见 `_expandedAdFree`）。
    //   注意：`filtered == decoded` 表示 purify **什么都没改**，此时用入参是
    //   正确行为（`_filterM3u8` 内部的既有判据），这里只是把它显式化。
    _expandedAdFree = identical(filtered, decoded) || filtered == decoded;
    final resolved = resolveRelativeUrls(filtered, targetUrl);
    final rewritten = rewriteToLocalProxy(
      resolved,
      baseUrl!,
      renumberSegments: _fvpRenumber,
      decryptAes: _decryptAes,
    );
    // 分开记录「下载」「过滤」「重写」三段耗时：下次据此判断该收紧超时
    // 还是该优化重写（分片数越多重写越久）。
    _log('master 展开：下载 ${dlMs}ms + 过滤 ${filterMs}ms + 重写 '
        '${sw.elapsedMilliseconds - dlMs - filterMs}ms，${resp.bodyBytes.length} 字节'
        '${_expandedAdFree ? "（无广告，已按透传优化）" : ""}');
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
        ..write('Missing url');
      await request.response.close();
      return;
    }

    final targetUrl = Uri.decodeComponent(urlParam);

    // fvp/mpv 专属：若分片被标记为 AES-128 加密（由 rewriteToLocalProxy 注入
    // &decrypt=aes128&key=&iv=），代理侧取 key 并逐段做 AES-128-CBC 解密，
    // 把明文吐给播放器。
    //   · fvp：绕过 libmdk 对「经本地代理的 AES-128 HLS」解密卡死的缺陷；
    //   · mpv：为了能在**明文**上读出 PTS 并做 PTS 归一化（否则加密源的
    //     进度条偏移修不掉）。
    final decryptParam = request.uri.queryParameters['decrypt'];
    if (decryptParam == 'aes128') {
      final keyParam = request.uri.queryParameters['key'];
      final ivParam = request.uri.queryParameters['iv'];
      if (keyParam == null || ivParam == null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('Missing decrypt params');
        await request.response.close();
        return;
      }
      // 🔴 2026-10-24：key URI 可能是**相对路径**（`URI="key.key"`）。
      //   绝对化规则：按**分片自身的 CDN URL** 解析（key 通常与分片同目录）。
      //   不做这一步 ⇒ 代理去拉 "key.key" 这个相对地址必然失败 ⇒
      //   加密源全部分片 502 ⇒ 根本播不出来。
      var keyUri = Uri.decodeComponent(keyParam);
      if (!keyUri.startsWith('http://') && !keyUri.startsWith('https://')) {
        try {
          keyUri = Uri.parse(targetUrl).resolve(keyUri).toString();
        } catch (_) {
          // 解析失败就保留原值，交给后续取 key 报错（错误信息更直观）。
        }
      }
      await _proxyDecryptedSegment(
        request,
        isHead: isHead,
        targetUrl: targetUrl,
        keyUri: keyUri,
        iv: _hexToBytes(ivParam),
      );
      return;
    }

    // 透传调用方设置的所有请求头（含鉴权 token / Cookie / 自定义头），
    // 确保分片请求与播放列表请求使用一致的头部。否则部分 CDN 在分片阶段
    // 因缺头被拒，表现为“出一下声音后无画面、卡死”（首段常已被放行/缓存）。
    final headers = _segmentRequestHeaders(targetUrl);

    // 🔴🔴🔴 2026-10-24 第六轮：**预取调度前移**（在真正取流之前就排下一批）。
    //
    // 【真机实锤：hilog 2026-10-24 09:48】旧实现有两处致命时序错误：
    //
    //   ❶ **缓存命中即 return，完全不推进预取**。
    //      旧代码在 `_servePrefetched()` 返回 true 时直接 `return`，
    //      而 `_schedulePrefetch()` 只挂在「回源直连」的三条分支末尾
    //      ⇒ **只有回源时才推进预取**。
    //      这是一个「鸡生蛋」死循环：预取只能靠**缓存未命中**来推进，
    //      而它又永远慢一拍 ⇒ 命中率被锁死在 0%。
    //      实测：avp 会话 44 次分片请求、**缓存命中 0 次**；
    //            mpv 会话 43 次请求、命中 10 次（23%）；
    //            同期预取分别完成 45 / 47 段 —— 预取在跑，却**从没赶上**。
    //
    //   ❷ **调度发生在响应发完之后**。分片从 CDN 回来要 1~2 秒，
    //      等响应结束才排下一批 ⇒ 下一批又晚 1~2 秒 ⇒ 提前量恒为负。
    //
    // 【修法】把 `_schedulePrefetch(targetUrl)` 提到**取流之前**：
    //   拿到 targetUrl 就能定位下标，立刻把后续 N 段排进预取队列，
    //   与本次取流**并行**；命中/未命中两条路径都推进。
    if (!isHead && _prefetchEnabled) {
      _schedulePrefetch(targetUrl);
    }

        // 预取缓存命中：当前请求分片的 CDN 原始 URL 已在缓存（之前被并发预取），
        // 直接按 Range 切片返回，不再回源（消除逐段等 CDN 的串行等待）。
        // 统一以解码后的 targetUrl(CDN URL) 为 key，与 _schedulePrefetch/_storePrefetched 一致。
        if (!isHead && _prefetchEnabled) {
          if (await _servePrefetched(request, targetUrl)) {
            return;
          }
          // 🔴🔴 2026-10-24 第九轮：**该分片正在被预取下载** ⇒ 等它，别再回源。
          //
          // 【真机实锤：hilog 2026-10-24 18:37:09】
          //   18:37:09.500 播放器请求 pUr8NL28.ts（缓存尚未命中 ⇒ 准备回源）
          //   18:37:09.587 预取**同时**把同一段下完（314148 bytes 完整）
          //   18:37:10.623 直连那条流被上游掐断 ⇒ declared=314148 sent=245716
          //   ⇒ **残缺分片** ⇒ 播放器重试 ⇒ 顿挫。
          //
          // 【为什么等它更快】日志实测：预取那条 200 完整请求 **87ms** 就下完；
          //   而直连那条 206 请求光**响应头**就等了 828ms。
          //   ⇒ 等预取 = 既拿到**完整字节**，又只花一条上行连接。
          final waited = await _awaitSegmentInFlight(targetUrl);
          if (waited != null) {
            // 自己落缓存 + 算 delta（与预取线程同源同值，幂等覆盖）。
            if (_ptsNormalize) {
              try {
                _prefetchDelta[targetUrl] = await _deltaFor(targetUrl, waited);
              } catch (e) {
                _log('Proxy: 复用分片时计算 delta 失败，该分片不平移 $targetUrl: $e');
              }
            }
            _storePrefetched(targetUrl, waited);
            if (await _servePrefetched(request, targetUrl)) {
              return;
            }
            // 落库/切片异常 ⇒ 落回直连回源。
          }
        }

        // 透传 Range，但 M3U8 播放列表必须获取完整内容才能正确计算总时长，
        // 否则播放器收到 206 部分响应会导致进度条/时长显示异常。
        // ⚠️ 旧逻辑用 contains('/hls/') 判定 playlist，会把 /hls/ 下的 .ts 分片
        // 误判为 playlist 而丢弃 Range → fvp 无法在分片内 seek/续拉，弱机每次
        // 重缓冲都要整段重下，是 tvLegacy 等弱机「幻灯片式卡顿」的诱因之一。
        // 改为按扩展名精确判定：playlist(.m3u8/.m3u 或无扩展名)才跳过 Range，
        // 媒体分片(.ts/.mp4/.m4s/...)一律透传 Range。
        final isPlaylistUrl = _isPlaylistUrl(targetUrl);
        final range = request.headers.value('range');
        // 🔴🔴 2026-10-24 第九轮：**`Range: bytes=0-` 不再透传给上游**。
        //
        // 【真机实锤：hilog 2026-10-24 18:37】同一个分片 pUr8NL28.ts：
        //   · 预取走「无 Range ⇒ 200」→ 314148 bytes **完整**（71 次全中，0 失败）；
        //   · 直连走「`Range: bytes=0-` ⇒ 206」→ **两次被中途掐断**
        //     （sent=245716 / sent=147392）⇒ 残缺分片 ⇒ 顿挫。
        // ⇒ 206 路径在这个 CDN 上不可靠；`bytes=0-` 语义上就是「整个分片」，
        //   去掉 Range 走 200 完整路径，**内容完全等价**，
        //   响应再由代理自己构造成 206 + Content-Range 交回播放器
        //   （⇒ 播放器侧行为与之前**逐字节一致**）。
        //
        // 判据（整段 vs 部分 Range）收敛到纯函数
        // [rangeRequestsWholeSegment]：`bytes=0-` 与 `bytes=0-65535`
        // **必须区分**（前者整段、后者部分），混判 ⇒ 残缺分片。
        final wantsWholeSegment = !isPlaylistUrl &&
            rangeRequestsWholeSegment(range);
        if (shouldForwardRange(range: range, isPlaylistUrl: isPlaylistUrl)) {
          headers['Range'] = range!;
        }
        // 🔴 第九轮：直连回源期间标记该分片 ⇒ 预取 worker 取到它时跳过
        //   （避免对同一分片再拉一份，见 [_prefetchWorker]）。
        final markingDirect = !isHead && _prefetchEnabled && !isPlaylistUrl;
        if (markingDirect) _segmentDirectFetching.add(targetUrl);

      // 🔴🔴🔴 2026-10-24 第十轮：媒体分片走「完整下载」，**不走流式转发**。
      //   完整论证见 [_serveSegmentComplete]。
      final out = request.response;
      try {
        final requestMethod = isHead ? 'HEAD' : 'GET';
        final requestUri = Uri.parse(targetUrl);
        final client = _client ?? http.Client();
        _log('proxySegment request: $targetUrl');

        // 🔴🔴🔴 第十轮：**媒体分片** ⇒ 完整下载（单飞 + 完整性校验 + 重试）。
        //
        // 【为什么必须这样 —— 真机实锤：hilog 2026-10-24 19:27~19:30】
        //   · avp（AVPlayer）在 19:30:17 只请求了 **1 个**分片（6oxczFWF.ts），
        //     代理声明 `Content-Length: 214696` 却只写出 **32768** 字节
        //     ⇒ AVPlayer 按 Content-Length 等满，永远等不到完整分片
        //     ⇒ `prepared` 之后**再无 `playing`**（18 秒后被释放）
        //     ⇒ 画面卡死在开头画面，而进度条仍按播放记录显示
        //     ⇒ 用户侧：「播放期间 mpv 切换 avp 直接卡死」。
        //   · 同期 mpv：流式平移后 `sent=8272/314148`
        //     ⇒ `[ffmpeg/demuxer:warn] mpegts: Packet corrupt`
        //     ⇒ 解码失败重试 ⇒ 顿挫。
        //
        // 【根因】流式转发一旦被上游掐断（或播放器提前关闭连接），
        //   代理写出的字节数就 < Content-Length ⇒ 播放器拿到**残缺分片**。
        //   AVPlayer 尤其不能容忍（它按 Content-Length 等满，不会把短读当结束）。
        if (!isHead && !isPlaylistUrl) {
          await _serveSegmentComplete(request, out, targetUrl);
          return;
        }

        final streamed = await client
            .send(http.Request(requestMethod, requestUri)..headers.addAll(headers))
            .timeout(const Duration(seconds: 30));

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
        // 🔴🔴 2026-10-24 第九轮：上游因「去掉 Range」而返回 **200** 时，
        //   代理自己把响应还原成播放器要的 **206 + Content-Range**。
        //
        // 【为什么要还原】播放器发的是 `Range: bytes=0-`，原先上游回 206。
        //   现在上游回 200（完整路径更稳），但若直接把 200 交回播放器，
        //   部分播放器（libmdk/fvp）对 200/206 的处理路径不同 ⇒ 行为可能变化。
        //   代理自己构造 206 + `bytes 0-(total-1)/total` ⇒
        //   **与原先上游的 206 响应逐字节等价**，播放器侧零感知。
        if (wantsWholeSegment &&
            range != null &&
            range.isNotEmpty &&
            streamed.statusCode == 200) {
          final total = streamed.contentLength;
          final cr = total == null ? null : buildWholeSegmentContentRange(total);
          if (cr != null) {
            out.statusCode = HttpStatus.partialContent;
            out.headers.set('Content-Range', cr);
          }
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
            decryptAes: _decryptAes,
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
          // 非 M3U8：媒体分片（.ts/.mp4/.m4s...）
          //
          // 🔴🔴 2026-10-24 修复「鸿蒙版无论 avp 还是 mpv 都时不时卡一下，
          //   声音正常」——**原实现无条件整段缓冲**（`toBytes()`），再按需改写。
          //
          // 【为什么这会卡】该路径全程在主 isolate 上串行执行，分片 150~480KB
          //   一个接一个、中间不让出 ⇒ Flutter 无法提交渲染帧 ⇒ **画面停住**；
          //   而音频走 native 播放线程，不受影响 ⇒ **「有声音、没画面」**。
          //   纯理论不够，本片真机日志是实锤：125 个分片因「读不出 PTS」
          //   （AES-128 密文）白付了「整段缓冲 + 主 isolate 往返」的代价，
          //   字节数一个都没变（`PTS skip: no-pts` 125 次）。
          //
          // 【修法（对齐主工程 `hain_tv` 2026-10-16 同源修复）】
          //   ① 归一化没开（avp 后端 / 源里没删广告）⇒ 直接流式转发，不缓冲；
          //   ② 归一化开了、但本源 PTS 连续读不出 ⇒ 判定源级不可读 ⇒ 流式转发；
          //   ③ 只有「归一化开着 **且** 本源可读」才整段缓冲做改写。
          final needShift = _ptsNormalize && _segMeta.isNotEmpty;
          if (!needShift || _ptsReadable == false) {
            final len = streamed.contentLength;
            if (len != null) out.headers.set('Content-Length', len.toString());
            _log('proxySegment stream: $targetUrl status=${streamed.statusCode}'
                '${_ptsReadable == false ? "（本源 PTS 不可读，跳过缓冲改写）" : ""}');
            // 🔴🔴 2026-10-24 第九轮：**统计实际吐出的字节数**。
            //   上游可能中途掐断（真机实证 declared=314148 sent=245716）⇒
            //   播放器拿到**残缺分片** ⇒ 解码失败 ⇒ 重试 ⇒ 顿挫。
            //   这里既留证据，又触发后台补齐（见 [_scheduleSegmentRepair]）。
            var sent = 0;
            await out.addStream(streamed.stream.map((c) {
              sent += c.length;
              return c;
            }));
            await out.close();
            if (len != null && sent != len) {
              _log('⚠️ proxySegment 流式字节数与 Content-Length 不一致: '
                  'declared=$len sent=$sent delta=${sent - len} $targetUrl');
              _scheduleSegmentRepair(targetUrl);
            }
            return;
          }
          // 🔴🔴🔴 2026-10-24：**优先走流式平移**（消除整段缓冲的首字节延迟）。
          //
          // 【为什么】整段缓冲要求「先下载完整分片再吐字节」，真机实测
          //   （hilog 2026-10-24 07:52）该延迟中位 **1168ms**、首片 **2.3s**，
          //   而每分片内容仅约 2 秒 ⇒ 播放器缓冲在**每个分片边界**被反复饿空
          //   ⇒ **画面停住、音频照常**（同期 mpv position 推进速率全程 1.00x，
          //   数据供给其实跟得上，卡的是帧交付环节）。
          //   而 PTS 平移是「每包加同一常数」，包与包独立 ⇒ 可以边下边改边吐。
          //
          // 🔴🔴🔴 2026-10-24 第五轮修复：**`Range: bytes=0-` 同样走流式平移**。
          //
          // 【真机实锤：hilog 2026-10-24 09:09（本轮）】
          //   mpv 对**每一个**分片都发 `Range: bytes=0-`（实测 100/100 起点=0），
          //   而旧判据是「**没有** Range 头才走流式」⇒ 第三轮做好的流式平移
          //   在真机上**一次都没触发**（日志 `stream(flow)` 0 次、
          //   `流式字节守恒` 0 次），全部 100 个分片仍走**整段缓冲**
          //   ⇒ 实测首字节延迟中位 **875ms**、最大 1330ms（分片内容仅约 2 秒）
          //   ⇒ 缓冲余量只剩 3~7 秒 ⇒ **每个分片边界都被饿空**
          //   ⇒ mpv 侧「小顿挫」。
          //
          // 【安全前提】`Range: bytes=0-` 的起点是 0 ⇒ 拿到的就是**完整分片**
          //   ⇒ 首个视频 PES 可靠可判定 ⇒ 与整段缓冲路径**逐字节等价**
          //   （`tool/flow_shift_verify.dart` 已在真实分片上验证过等价）。
          //   真正的「部分 Range」（起点 > 0，或上游只回了分片的一部分）
          //   仍然走整段缓冲 —— 那里拿不到分片开头，误判会静默损坏字节。
          final rangeStart = _rangeStartOf(range);
          // 🔴 第九轮：整段判据与「上游 Range 转发判据」**同源**
          //   （都用 [rangeRequestsWholeSegment]）⇒ 两处口径不会打架。
          //   ⚠️ 起点 0 **不足以**判定整段：`bytes=0-65535` 也是起点 0，
          //      但它是**部分** Range（只要前 64KB）⇒ 必须走整段缓冲。
          final wholeSegment =
              rangeRequestsWholeSegment(range) && _coversWholeSegment(streamed);
          if (wholeSegment) {
            if (rangeStart != null) {
              _log('proxySegment Range 起点=$rangeStart 188 对齐✅ '
                  '且上游返回完整分片 ⇒ 改走流式平移 $targetUrl');
            }
            await _serveSegmentShiftedStream(request, streamed, targetUrl);
            return;
          }
          // 整段缓冲后按需做 PTS 归一化（消除断点 ts_offset），
          // 长度严格不变，Range 部分响应亦安全。
          final bytes = await streamed.stream.toBytes();
          var body = bytes;
          var delta = 0;
          // 🔍 2026-10-24 观测：Range 响应的字节起点**未必**落在 TS 包边界上
          //   （TS 分片按 188 字节对齐，Range 起点是任意字节偏移）。
          //   若起点不对齐，对该片段施加 PTS 平移会**错位改写字节** ⇒ 静默损坏。
          //   这里记录起点与对齐情况，为下一轮真机复测提供判据。
          final rangeAligned = rangeStart == null || (rangeStart % 188 == 0);
          if (rangeStart != null) {
            _log('proxySegment Range 起点=$rangeStart '
                '${rangeAligned ? "188 对齐✅" : "未对齐⚠️(平移会错位改写字节)"} '
                'bytes=${bytes.length} $targetUrl');
          }
          if (_ptsNormalize) {
            // 观测模式下 _deltaFor 仍照常计算并打日志，只是不把 delta 落到字节上。
            delta = await _deltaFor(targetUrl, bytes);
            if (delta != 0) {
              _prefetchDelta[targetUrl] = delta; // 供 _servePrefetched 出口施加
            }
            if (delta != 0 && !kPtsNormalizeObserveOnly) {
              // 🔴 2026-10-24：平移放后台 isolate（见 [_normalizeInBackground]），
              // 避免逐包解析占住主 isolate 导致渲染帧提交被挤掉。
              final shifted = await _normalizeInBackground(bytes, delta) ??
                  normalizeTsPts(bytes, delta);
              // 🔴 出口自校验：平移前后首帧 PTS 差必须 == delta，否则视为
              // 本次平移不可信（包边界错位/PTS 解析落错字节 = 静默损坏），
              // 回退原始字节。这是「打开 kPtsNormalizeObserveOnly」的前置保险。
              final chk = verifyPtsShift(bytes, shifted, delta, videoOnly: true);
              if (chk.ok) {
                body = shifted;
              } else {
                _log('proxySegment PTS 平移自校验失败，回退原始字节 '
                    '(${chk.reason} before=${chk.beforeMs} after=${chk.afterMs}) $targetUrl');
              }
            }
          }
          // 🔴 2026-10-09 修正：缓存里**只存原始 CDN 字节**。
          // 旧写法 `_storePrefetched(targetUrl, body)` 存的是 `body`(平移后)，
          // 而 `_prefetchOne` 存的是原始字节 —— 同一个 key 两条语义不同的写入
          // 路径。一旦 PTS 归一化开启，同一分片可能这次吐平移版、下次吐原始版，
          // 表现为 PTS 回跳/跳变。现统一为「缓存存原始，出口再平移」。
          //
          // 🔴🔴 2026-10-24 第九轮：**只有完整分片才允许入缓存**。
          //
          // 【为什么】走到这条路径说明上游给的是**部分 Range**（起点 > 0），
          //   `bytes` 里只有分片的一段 ⇒ 把它当「整段」存进缓存，
          //   后续播放器请求该分片（要整段）会命中缓存并拿到**残缺分片**
          //   ⇒ 解码失败 ⇒ 播放器重试 ⇒ 顿挫。
          //   ⇒ 残缺数据**绝不能**进缓存。
          final upstreamComplete = _coversWholeSegment(streamed);
          if (upstreamComplete) {
            _storePrefetched(targetUrl, bytes);
          } else {
            _log('proxySegment 部分 Range 响应（${bytes.length} bytes，起点=$rangeStart）'
                ' ⇒ 不入预取缓存，避免缓存残缺分片 $targetUrl');
          }
          out.headers.set('Content-Length', body.length.toString());
          _log('proxySegment ${delta != 0 ? "PTS+${delta}ms " : ""}stream: '
              '$targetUrl status=${streamed.statusCode}');
          out.add(body);
          await out.close();
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
          ..write('Proxy error');
        await request.response.close();
      } catch (_) {}
    } finally {
      // 🔴 2026-10-24 第九轮：直连标记必须**在所有出口**（正常/异常）都清掉，
      //   否则该分片会被预取永久跳过 ⇒ 永远只能回源。
      if (markingDirect) _segmentDirectFetching.remove(targetUrl);
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
        ..write('Key fetch failed');
      await out.close();
      return;
    }
    if (key.length != 16) {
      _log('AES key length invalid: ${key.length} (expect 16)');
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Key length invalid');
      await out.close();
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

    final streamed = await client
        .send(http.Request(isHead ? 'HEAD' : 'GET', Uri.parse(targetUrl))
          ..headers.addAll(_segmentRequestHeaders(targetUrl)))
        .timeout(const Duration(seconds: 30));
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Segment fetch failed ${streamed.statusCode}');
      await out.close();
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
    final cipher = await streamed.stream.toBytes();
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

    // 🔴🔴 2026-10-24：要做 PTS 归一化时**必须解密整段**。
    //
    // 【为什么】PTS 探测读的是「分片**第一帧**」的 PES 头，那只在分片开头。
    //   若只解请求区间，Range 切片一旦不含开头 ⇒ 探测必失败 ⇒ delta 恒 0 ⇒
    //   **加密源的进度条偏移永远修不掉**（这正是本轮要解决的问题）。
    //   代价：Range 请求多解一段（整段约 250KB），换来「能归一化」。
    final needFullPlain = _ptsNormalize && _segMeta.isNotEmpty;
    if (needFullPlain) {
      fetchStart = 0;
      fetchEnd = total - 1;
    }

    // 🔴🔴 2026-10-24：哨兵 —— 源站可能**标记为加密、实际返回明文**。
    //
    // 【为什么必须判】对明文再解一次密 ⇒ 得到垃圾字节 ⇒ 播放器花屏/卡死。
    //   这不是假想风险：legacy 工程实测确有分片首字节为 0x47（TS sync byte），
    //   即真实环境存在「标记为加密、实际明文」的分片。
    // 【判据】TS 明文是 188 字节定长包，每包首字节必为 0x47；密文是均匀噪声，
    //   同一栅格的命中概率 ≈1/256，前 8 包全中几乎不可能 ⇒ 区分度极高。
    final cipherIsPlainTs = _looksLikePlainTs(cipher);

    late final Uint8List plain;
    var firstProcessedOffset = 0;
    if (cipherIsPlainTs) {
      _log('proxyDecryptedSegment 实为明文（跳过解密）: '
          '$targetUrl len=${cipher.length}');
      plain = cipher;
      fetchStart = 0;
      fetchEnd = total - 1;
    } else {
      final cipherBlock = cipher.sublist(fetchStart, fetchEnd + 1);
      firstProcessedOffset = (fetchStart == 0) ? 0 : bs;
      final ivFirst = (fetchStart == 0) ? iv : cipherBlock.sublist(0, bs);

      final cbc = CBCBlockCipher(AESFastEngine());
      cbc.init(false, ParametersWithIV(KeyParameter(key), ivFirst));
      final buf = Uint8List(cipherBlock.length - firstProcessedOffset);
      var outOff = 0;
      for (var off = firstProcessedOffset;
          off + bs <= cipherBlock.length;
          off += bs) {
        cbc.processBlock(cipherBlock, off, buf, outOff);
        outOff += bs;
      }
      plain = buf;
    }

    // 请求区间映射到 plain 下标。
    var pStart = start - fetchStart - firstProcessedOffset;
    var pEnd = end - fetchStart - firstProcessedOffset;
    if (pStart < 0) pStart = 0;
    if (pEnd >= plain.length) pEnd = plain.length - 1;

    // 仅当覆盖段尾（最后一块）时做 PKCS7 去填充。记下填充长度，后面要把
    // Content-Range 的总长换算成**明文**总长（见下方注释）。
    // 「实为明文」的分片不做去填充（TS 流的末字节不是 padding）。
    int? removedPad;
    if (!cipherIsPlainTs &&
        (!hasRange || end >= total - 1) &&
        plain.isNotEmpty) {
      final pad = plain[plain.length - 1];
      if (pad >= 1 && pad <= bs) {
        final unpaddedLen = plain.length - pad;
        if (pEnd >= unpaddedLen) pEnd = unpaddedLen - 1;
        removedPad = pad;
      }
    }

    final body = plain.sublist(pStart, pEnd + 1);

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
    var finalBody = body;
    if (_ptsNormalize && _segMeta.isNotEmpty) {
      // 🔴🔴 2026-10-24：在**整段明文**上做归一化（不是请求区间切片）。
      //
      // 【为什么】PTS 探测读的是分片**第一帧**的 PES 头。若在切片上做，
      //   Range 切片不含开头 ⇒ 探测失败 ⇒ delta 恒 0 ⇒
      //   **加密源的进度条偏移永远修不掉**（正是本轮要解决的问题）。
      //   legacy 工程（`hain_tv_legacy`）就是这么做的（`_emitPlainSegment`）。
      //
      // 【顺序不能反】先在整段上平移，再按请求区间切片。
      //   反过来（先切片后平移）会让切片起点丢掉分片首帧。
      final d = await _deltaFor(targetUrl, plain);
      if (d != 0 && !kPtsNormalizeObserveOnly) {
        // 与直连路径一致：平移交后台 isolate（见 [_normalizeInBackground]）。
        final shifted = await _normalizeInBackground(plain, d) ??
            normalizeTsPts(plain, d);
        // 与直连路径同一套出口自校验（见 normalizeTsPts 调用处说明）。
        final chk = verifyPtsShift(plain, shifted, d, videoOnly: true);
        if (chk.ok) {
          finalBody = shifted.sublist(pStart, pEnd + 1);
        } else {
          _log('proxyDecryptedSegment PTS 平移自校验失败，回退原始字节 '
              '(${chk.reason} before=${chk.beforeMs} after=${chk.afterMs}) $targetUrl');
        }
      }
    }
    out.headers.set('Content-Length', finalBody.length.toString());
    out.add(finalBody);
    await out.close();
    _log('proxyDecryptedSegment: $targetUrl -> '
        'decrypted bytes=${body.length} range=$hasRange '
        'plainTotal=$plainTotal pad=${removedPad ?? 0}');
  }

  /// 🔴🔴 2026-10-24：判断字节是否**已经是 TS 明文**（未加密）。
  ///
  /// 【判据】TS 明文是 188 字节定长包，每包首字节必为 sync byte 0x47。
  ///   密文是均匀噪声，同一栅格的命中概率约 1/256 ≈ 0.4%；
  ///   取前 8 个包判定 ⇒ 实测明文 100% 命中、密文 <1% 命中，区分度极高。
  ///
  /// 【为什么必须有】源站可能「标记为 AES-128、实际返回明文」。对明文再解一次密
  ///   ⇒ 得到垃圾字节 ⇒ 播放器花屏/卡死。legacy 工程实测确有此类分片
  ///   （首 16 字节为 `47 40 11 10`）。
  static bool _looksLikePlainTs(Uint8List data) {
    if (data.length < 188 * 4) return false;
    const kTsPacket = 188;
    const kSync = 0x47;
    var hit = 0;
    const n = 8;
    for (var i = 0; i < n; i++) {
      final off = i * kTsPacket;
      if (off >= data.length) break;
      if (data[off] == kSync) hit++;
    }
    return hit >= 6;
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
    bool decryptAes = false,
  }) {
    final lines = content.split('\n');
    final result = <String>[];
    var segIndex = 0;

    // 🔴🔴 2026-10-24：「代理解密」与「fvp 分段重编号」是**两件独立的事**，
    //   原实现把两者绑在同一个布尔（`isFvp = renumberSegments`）上，
    //   而**鸿蒙的 mpv 后端两者都不开** ⇒ 加密源永远走不到 PTS 归一化。
    //   · proxyDecrypt —— 剥离 EXT-X-KEY + 给分片代理 URL 注入
    //     `&decrypt=aes128&key=&iv=`，由代理取 key 逐段解密。
    //     fvp：绕开 libmdk 解密卡死；mpv：**为了能在明文上读出 PTS 做归一化**。
    //   · isFvp —— `&hseg=N` 分段重编号 + 丢弃结构性 discontinuity（fvp 专属）。
    final bool proxyDecrypt = decryptAes;
    final bool isFvp = renumberSegments;
    // AES-128 解密上下文。剥离 EXT-X-KEY 后把 key URI + IV 注入每个分片
    // 代理 URL，由 _proxySegment 取 key 逐段解密。
    String? activeAesKeyUri;
    Uint8List? activeAesIv;
    int mediaSequence = 0;
    int segEmitIndex = 0;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      // fvp 专属：丢弃结构性 #EXT-X-DISCONTINUITY（避免 libmdk 段缓存撞名卡死）。
      if (isFvp && trimmed == '#EXT-X-DISCONTINUITY') {
        continue;
      }

      // 解析媒体序列号（无 IV 属性时的默认 IV = 序列号低 8 字节大端）。
      if (trimmed.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final m = RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(trimmed);
        if (m != null) mediaSequence = int.parse(m.group(1)!);
      }

      // AES-128 加密 HLS：需要由**代理侧**解密时（fvp / mpv），
      // 剥离 EXT-X-KEY 标签（播放器不再需要拉 key），并把 key URI + IV 记录到
      // 上下文，供后续每个分片代理 URL 注入 &decrypt=aes128&key=&iv=。
      // 不需要代理解密的后端（avplayer）保持原样，由播放器自己解密。
      if (trimmed.startsWith('#EXT-X-KEY')) {
        final methodMatch = RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(trimmed);
        final method = methodMatch?.group(1);
        if (proxyDecrypt && method == 'AES-128') {
          activeAesKeyUri = RegExp(r'URI="([^"]+)"').firstMatch(trimmed)?.group(1);
          final ivMatch = RegExp(r'IV=0x([0-9A-Fa-f]+)').firstMatch(trimmed);
          activeAesIv = ivMatch != null ? _hexToBytes(ivMatch.group(1)!) : null;
          continue; // 剥离 EXT-X-KEY
        } else if (proxyDecrypt && method == 'NONE') {
          activeAesKeyUri = null;
          activeAesIv = null;
          continue; // 无加密，剥离
        } else {
          // 不由代理解密，或 SAMPLE-AES 等不支持方法：保留标签并改写 URI（原行为）。
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
        // 当前分片属于 AES-128 加密区间 → 注入解密参数，
        // 由代理侧取 key 后逐段解密（fvp 绕开 libmdk 卡死；
        // mpv 为了在**明文**上做 PTS 归一化）。
        if (proxyDecrypt && activeAesKeyUri != null) {
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

  // ===== HLS 并发分片预取实现（借鉴 LunaTV OptimizedHlsLoader）=====
  //
  // 时序：_proxySegment 在「真实拿到当前分片」后调用 _schedulePrefetch(targetUrl)，
  // 由它定位当前分片在 _segmentUrls 中的下标，把后续 N 个入队，单线程串行消费队列
  // （_runPrefetchQueue，带 _prefetchRunning 标志位防重入），避免并发无上限拖垮带宽。
  // 预取到的整段存入 _prefetchCache（键=代理 URL，值=整段字节），受 50MB 上限约束；
  // 后续播放器请求这些分片时，_proxySegment 入口先查缓存命中，命中则按 Range 切片返回，
  // 不再回源。连续失败 3 次触发熔断（暂停预取），换源/换集清空（见 _clearPrefetchCache）。

  /// 把下载到的整段存入预取缓存（受 50MB 上限约束）。
  ///
  /// 🔴 2026-10-24：原实现超上限就「跳过缓存」且**从不淘汰**，
  ///   而 [_drainPrefetchQueue] 在「缓存达上限」时又直接清空队列
  ///   ⇒ 预取在长视频上会在缓存写满后**永久停止**
  ///   （50MB / 约 400KB ≈ 125 段 ≈ 250 秒视频，之后全部退化为
  ///   「回源 → 整段缓冲 → 吐出」⇒ 首字节延迟 1.1 秒 ⇒ 卡顿复发）。
  ///   改为 **LRU 淘汰最旧分片**（Dart 的 Map 保持插入顺序，
  ///   `keys.first` 即最旧），保证预取能一直跟上播放。
  void _storePrefetched(String proxyUrl, Uint8List body) {
    if (!_prefetchEnabled) return;
    if (_prefetchCache.containsKey(proxyUrl)) return;
    while (_prefetchTotalBytes + body.length > _kMaxPrefetchCacheBytes &&
        _prefetchCache.isNotEmpty) {
      final oldest = _prefetchCache.keys.first;
      final removed = _prefetchCache.remove(oldest);
      if (removed != null) {
        _prefetchTotalBytes -= removed.length;
        // delta 与字节必须同寿命，否则淘汰后残留的 delta 会让
        // 「重新下载的同一分片」拿到过期/错位的平移量。
        _prefetchDelta.remove(oldest);
      }
    }
    if (_prefetchTotalBytes + body.length > _kMaxPrefetchCacheBytes) {
      _log('Prefetch: 缓存达 50MB 上限且无可淘汰项，跳过缓存 $proxyUrl');
      return;
    }
    _prefetchCache[proxyUrl] = body;
    _prefetchTotalBytes += body.length;
  }

  /// 定位当前分片下标，把后续 N 个分片代理 URL 入队预取。
  void _schedulePrefetch(String currentProxyUrl) {
    if (!_prefetchEnabled) return;
    if (_segmentUrls.isEmpty) {
      // 🔴 2026-10-07：此处原为静默 return —— 正是「预取整源失效却零日志」的根源。
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
    // 🔴 2026-10-24 第六轮：用 URL→下标映射 O(1) 定位（此前 `List.indexOf`
    //   是 O(n)，本源 1328 段，每次分片请求都要线性扫一遍）。
    final idx = _segmentIndex[currentProxyUrl] ?? -1;
    if (idx < 0) return; // 不在列表里的（如已重写变体行）不预取

    // 🔴🔴 2026-10-24 第六轮：**丢弃过时队列项**（seek 感知）。
    //
    // 【真机实锤：hilog 2026-10-24 09:48】avp 会话 17:47:21.868 快进
    //   （1442515ms → 1482413ms）之后，队列里仍堆着**旧位置**的分片，
    //   预取在 17:47:22~17:47:25 依次缓存的
    //   AQYbfoSC / JBkcEpBJ / eRX4SVyX / JYk29OJj **全部是旧位置的段**，
    //   而新位置真正需要的 6SIkjHF2 / bEv1LPSm / Ex5HMBaI 一个都没预取到
    //   ⇒ 播放器每段都得回源等 CDN（0.8~2s）⇒ **position 冻结 5 秒**
    //   （日志 `AVP_DECODE_STALL: position 卡在 1482413ms 已≥2s 无推进` ×2、
    //     `buffering=true` ×5）。
    //
    // 【修法】播放器请求的分片下标 = 播放头。队列只保留**播放头窗口内**
    //   （idx < i <= idx + 深度）的项，其余一律丢弃：
    //   · i <= idx：seek 之前的旧位置分片，再也不会用到；
    //   · i > idx + 深度：位置跳变（**向后** seek）时留下的远端分片，
    //     会把新位置的预取堵在队尾。
    //
    // 🔴 2026-10-24 第七轮：窗口改为**双锚点** —— 播放头 ∪ 预热目标。
    //   原因：seek 尚未生效时，播放器请求的仍是旧位置分片；
    //   若只按播放头判窗，刚预热好的目标分片会被当成「旧位置」丢掉，
    //   预热就白做了（真机 mpv 起播定位 6.9 秒就是这么来的）。
    var target = _prefetchTargetIndex;
    // 目标过期 ⇒ 作废（避免长期把旧播放头窗口也留在队列里）。
    final at = _prefetchTargetAt;
    if (target != null && at != null &&
        DateTime.now().difference(at) >= _kPrefetchTargetTtl) {
      _prefetchTargetIndex = null;
      _prefetchTargetAt = null;
      target = null;
    }
    final staleCount = _prefetchQueue.length;
    if (staleCount > 0) {
      _prefetchQueue.removeWhere((u) => !keepPrefetchItem(
            itemIndex: _segmentIndex[u],
            currentIndex: idx,
            depth: _prefetchDepth,
            targetIndex: target,
          ));
      final dropped = staleCount - _prefetchQueue.length;
      // 🔴 2026-10-24（第十七轮）：**只有真的「位置跳变」才打日志**。
      //
      // 【真机实证】旧代码 `dropped > 0` 就打印，而**正常顺序播放**时
      //   播放头每前进一段，窗口末端就会滑出 1 项 ⇒ 每段都打一条
      //   「位置跳变（当前下标=N），丢弃过时队列 1 项」。
      //   20 秒内 42 条（hilog 里 ×15 = 630 行），全部是**正常播放**，
      //   信息量为零，还把「位置跳变」这个关键词污染得无法用于排查。
      //
      //   真正的 seek 跳变一次会丢弃整窗（实测 13 项 / 16 项）。
      //   ⇒ 阈值取 3：≥3 才是跳变，1~2 是正常窗口滑动，静默。
      if (dropped >= 3) {
        _log('Prefetch: 位置跳变（当前下标=$idx），丢弃过时队列 $dropped 项'
            '（seek 前的旧位置分片）');
      }
    }

    // 🔴🔴 2026-10-24 第九轮：**预热目标尚未达成时，只预取目标窗口**。
    //
    // 【真机实锤：hilog 2026-10-24 18:36:07】
    //   18:36:07.311 预热目标 1455000ms ⇒ 下标 709（入队 709..715）
    //   18:36:07.349 播放器请求第 0 段 ⇒ 旧逻辑又把「播放头窗口 1..6」入队
    //   18:36:10.193 播放头跳到 709 ⇒ 「丢弃过时队列 6 项」—— 1..6 全废
    //
    // 【为什么这是致命的】那 6 个作废的段**白占了 3 个 worker 槽位**
    //   （每个约 1.3 秒）⇒ 落点段 709 足足晚了一轮才下完
    //   ⇒ 18:36:10.193 播放器来要 709 时缓存里还没有 ⇒ **回源**（0.3~2.1s）
    //   ⇒ **起播定位必卡**。
    //
    // 【修法】目标已定、播放头还没到 ⇒ 队列里**只留目标窗口**，
    //   旧播放头窗口一个都不排。
    final targetPending = target != null && idx < target;
    if (targetPending) {
      final lo = target;
      final hi = (target + _prefetchDepth).clamp(0, _segmentUrls.length - 1);
      // 🔴🔴🔴 2026-10-24 第十轮：**建索引段插队首**。
      //
      // 【为什么 —— 真机实锤：hilog 2026-10-24 19:30:16（mpv 切 avp 卡死现场）】
      //   切换到 avp 后，AVPlayer **从第 0 段开始**顺序拉分片来建立播放列表
      //   索引（EXTINF 累加），才能算出 seek 落点：
      //     19:30:16.298 当前下标=0   ← 缓存命中
      //     19:30:16.452 当前下标=1   ← 缓存命中
      //     19:30:16.465 当前下标=2   ← **回源** ⇒ 被上游掐断（sent=32768）
      //   ⇒ 索引建不起来 ⇒ AVPlayer 永远停在开头 ⇒ 「画面卡死在开头画面、
      //     而进度条仍正确定位在播放记录」。
      //   对照成功那次（19:29:16~19:29:20）：第 0/1 段都拿到后，日志立刻出现
      //   「位置跳变（当前下标=747）」⇒ 索引建成 ⇒ 秒跳落点 ✔
      //
      //   而「预热目标未达成 ⇒ 只预取目标窗口」会**放任**这几段回源；
      //   切换时 4 个 worker 又全被落点段占着 ⇒ 建索引段抢不到带宽
      //   ⇒ 更容易被上游掐断 ⇒ **切换比「直接用 avp 起播」更容易卡**。
      //
      // 【修法】目标窗口照排，但**额外**把「播放头起的最多 N 段」插到队首：
      //   它们是**当前阻塞点**（播放器正等着），不是第九轮清掉的那种作废项
      //   （作废项是「旧位置的远端段」；这里是「当前正在等的头部段」）。
      // 🔴🔴 2026-10-24（avp 快起播）：**关闭投机式插队**。
      //
      // 【为什么关掉 —— 真机 hilog 2026-10-24 20:34:39 实证】
      //   AVPlayer 顺序爬索引时，播放器每要一段，这段投机逻辑就把
      //   「idx..idx+3」再插一次队首 ⇒ 队列被反复重排、worker 不断切换任务：
      //     20:34:39.617 建索引段插队首 5..8（1 项）
      //     20:34:39.643 建索引段插队首 6..9（2 项）
      //     20:34:39.671 建索引段插队首 7..10（3 项）
      //     20:34:39.689 建索引段插队首 8..11（2 项）
      //   落点段因此被越推越后 ⇒ AVPlayer 一直等不到落点段 ⇒ 15s 超时失败。
      //
      // 【改法】avp 路径下**不投机插队**：AVPlayer 要哪段，代理就让它排队，
      //   队列里已有的「头部建索引段 + 落点段」自然会先下完（都是它马上要的）。
      //   投机只在 mpv 路径保留（mpv 不建索引，投机对 mpv 无害）。
      final probeItems = <String>[];
      var probeHi = idx;
      if (!_avPlayerFastStart) {
        const kIndexProbeSegments = 3;
        probeHi = (idx + kIndexProbeSegments).clamp(0, _segmentUrls.length - 1);
        for (var i = idx; i <= probeHi; i++) {
          final url = _segmentUrls[i];
          if (_prefetchCache.containsKey(url) || _prefetchQueue.contains(url)) continue;
          probeItems.add(url);
        }
        if (probeItems.isNotEmpty) {
          _prefetchQueue.insertAll(0, probeItems);
          _log('Prefetch: 建索引段插队首 $idx..$probeHi（${probeItems.length} 项）'
              '—— 播放器正等这几段建立播放列表索引');
        }
      }
      // ⚠️ 这里**只入队目标窗口**，不排「旧播放头窗口」的新项，
      //    也**不丢弃**已在队列里的旧播放头项（那部分已由上面的
      //    [keepPrefetchItem] 双锚点窗口保留）——
      //    正在下载的段不该被中途作废，而目标过期（30s TTL）后
      //    播放头窗口会自动恢复入队。
      //
      // 🔴🔴 2026-10-24（avp 快起播）：**avp 路径下落点窗口必须插队首**。
      //
      // 【真机 hilog 2026-10-24 实证的 42.6 秒黑洞】
      //   20:34:33.578  position=105579ms buffering=true   ← AVPlayer 已跳到落点，在等落点段
      //   ...（中间 42.6 秒无任何进度日志）...
      //   20:35:16.172  position=105309ms bufFirst=105279/115189  ← 落点段 42.6 秒后才到手
      //   原因：落点窗口（日志里的「预取目标窗口 49..51」）是用 `add` **追加到队尾**的，
      //   前面还压着建索引段 + 旧播放头窗口的段 ⇒ 落点段排到第 9~24 位，
      //   4 路 worker 要跑 3~6 轮才轮到它。
      //
      // 【改法】avp：落点窗口 `insertAll(0, ...)` 插队首。
      //   头部建索引段与落点段是 AVPlayer **同时**在等的两类段，
      //   8 路并发下一批 8 段能把「头部 4 + 落点 2」同批下完，谁也不排队。
      //   mpv：保持原样（`add` 追加），mpv 不建索引，落点段不需要抢队首。
      final targetItems = <String>[];
      for (var i = lo; i <= hi; i++) {
        final url = _segmentUrls[i];
        if (_prefetchCache.containsKey(url) || _prefetchQueue.contains(url)) continue;
        targetItems.add(url);
      }
      if (targetItems.isEmpty) {
        // 落点窗口已在队列/缓存中（可能已被插到更靠前的位置）⇒ 无需重复入队。
      } else if (_avPlayerFastStart) {
        _prefetchQueue.insertAll(0, targetItems);
        _log('Prefetch: 落点窗口**插队首** $lo..$hi（${targetItems.length} 项）'
            '—— AVPlayer 正在等这几段，不能排在队尾');
      } else {
        _prefetchQueue.addAll(targetItems);
      }
      _log('Prefetch: 预热目标未达成（当前下标=$idx，目标=$target）'
          ' ⇒ 预取目标窗口 $lo..$hi'
          '${probeItems.isEmpty ? '' : ' + 建索引段 $idx..$probeHi'}');
    } else {
      for (final i in prefetchIndicesWithTarget(
        currentIndex: idx,
        depth: _prefetchDepth,
        total: _segmentUrls.length,
        targetIndex: target,
      )) {
        final url = _segmentUrls[i];
        if (_prefetchCache.containsKey(url) || _prefetchQueue.contains(url)) continue;
        _prefetchQueue.add(url);
      }
    }
    // 🔴 2026-10-24 第七轮：播放头已经追上（或越过）预热目标 ⇒ 目标锚点过期，
    //   交还单锚点窗口，避免旧目标段长期占着队列。
    if (target != null && idx >= target) {
      _prefetchTargetIndex = null;
      _prefetchTargetAt = null;
    }
    _runPrefetchQueue();
  }

  /// 串行消费预取队列（带重入标志）。
  void _runPrefetchQueue() {
    if (_prefetchRunning) return;
    _prefetchRunning = true;
    _drainPrefetchQueue();
  }

  /// 🔴🔴 2026-10-24 第六轮：预取队列**改为多 worker 并发消费**。
  ///
  /// 【为什么要改】旧实现是**单 worker 串行**：
  ///   `while (队列非空) { 取一个; await _prefetchOne(); }`
  ///   而单次分片下载要等 **CDN 首字节 0.8~2s + 传输 ~1s**
  ///   （容器内 curl 实测 8 个分片：ttfb 0.76~1.32s、total 1.4~3.0s，
  ///   极端一次 ttfb 6.8s；同一 CDN **8 路并发**时 ttfb 仍是 0.76~1.32s、
  ///   总耗时 2.0~2.6s ⇒ **并发不加单段延迟**）。
  ///   ⇒ 串行预取的交付速率只有 1 段/1~2 秒，而播放消耗 1 段/2 秒
  ///   ⇒ 预取**永远慢一拍**，提前量恒为 0 ⇒ 缓存命中率 0%（avp 会话实测）
  ///   ⇒ 每个分片边界都要现等 CDN ⇒ **小顿挫**。
  ///
  /// 【改法】起 [_prefetchConcurrency] 个 worker 并行消费同一队列。
  ///   Dart 单 isolate 事件循环保证 `removeAt(0)` 不会竞态
  ///   （检查与取出之间没有 await）。
  Future<void> _drainPrefetchQueue() async {
    final gen = _prefetchGen;
    try {
      final workers = <Future<void>>[];
      for (var i = 0; i < _prefetchConcurrency; i++) {
        workers.add(_prefetchWorker(gen));
      }
      await Future.wait(workers);
    } finally {
      _prefetchRunning = false;
      // 安全网：worker 退出与新任务入队之间存在极小窗口（入队时 `_prefetchRunning`
      // 仍为 true ⇒ 不会另起一组 worker），这里补一次拉起，避免任务滞留。
      if (_prefetchQueue.isNotEmpty && _prefetchEnabled && !_closing) {
        _runPrefetchQueue();
      }
    }
  }

  /// 单个预取 worker：从队头取分片并下载，直到队列空。
  Future<void> _prefetchWorker(int gen) async {
    while (true) {
      if (_prefetchQueue.isEmpty) return;
      if (!_prefetchEnabled || _closing || gen != _prefetchGen) {
        if (gen != _prefetchGen) _prefetchQueue.clear();
        return;
      }
      if (_prefetchFailCount >= _kMaxPrefetchFailures) {
        _log('Prefetch: 熔断，清空队列');
        _prefetchQueue.clear();
        return;
      }
      if (_prefetchTotalBytes >= _kMaxPrefetchCacheBytes) {
        // 🔴 2026-10-24：原来这里「清空队列并 return」⇒ 预取**永久停止**
        //   （缓存一旦写满就再也起不来，长视频后半程全部退化为回源整段缓冲
        //   ⇒ 首字节延迟 1.1 秒 ⇒ 卡顿复发）。
        //   现在缓存超限由 [_storePrefetched] 的 **LRU 淘汰**处理，
        //   这里不再中断队列 —— 继续预取，淘汰逻辑保证内存有界。
        _log('Prefetch: 缓存达上限，交给 LRU 淘汰后继续预取');
      }
      final proxyUrl = _prefetchQueue.removeAt(0);
      if (_prefetchCache.containsKey(proxyUrl)) continue;
      // 🔴🔴 2026-10-24 第九轮：跳过「播放器正在直连下载」的分片。
      //
      // 【真机实锤：hilog 2026-10-24 18:37:09】播放器请求 pUr8NL28.ts 时，
      //   预取**同时**在下载同一段 ⇒ 两条上行流争抢带宽 ⇒
      //   直连那条被掐断（declared=314148 sent=245716）⇒ **残缺分片** ⇒ 顿挫。
      //
      // 【修法】播放器已经在拉了，预取就别再下一份。
      //   （播放器直连走的是流式，字节不完整也没关系——
      //     短读会触发 [_scheduleSegmentRepair] 后台补齐完整字节。）
      if (_segmentDirectFetching.contains(proxyUrl)) {
        _log('Prefetch: 跳过（该分片正由播放器直连下载，避免重复回源） $proxyUrl');
        continue;
      }
      await _prefetchOne(proxyUrl);
    }
  }

  /// 预取单个分片：参数 cdnUrl 为 CDN 原始 URL（_schedulePrefetch 入队的即为解码后的
  /// 原始 URL），整段下载后以同一 URL 为 key 存入缓存。
  ///
  /// 🔴 2026-10-24 第九轮：下载走 [_fetchSegmentBytes]（**单飞**）——
  ///   同一分片若已有下载在途（修复任务 / 另一条预取链路），直接复用那个 Future，
  ///   绝不并发拉同一段。
  Future<void> _prefetchOne(String cdnUrl) async {
    try {
      final body = await _fetchSegmentBytes(cdnUrl);
      if (body == null) {
        _prefetchFailCount++;
        _log('Prefetch: 预取失败（空响应） ($_prefetchFailCount/$_kMaxPrefetchFailures) $cdnUrl');
        return;
      }
      // 🔴🔴 2026-10-15 修复「开启预取后进度条乱跳」：delta 必须在**这里**写入。
      //
      // 原缺陷：`_prefetchDelta` 只在直连回源分支（L1085）写入，而预取是
      //   **提前**下载的 —— 分片进缓存时播放器还没请求过它，直连分支未跑过，
      //   `_prefetchDelta` 里没有它的键。等播放器来取时 `_servePrefetched`
      //   读 `_prefetchDelta[url] ?? 0` 得 0 ⇒ `if (delta != 0)` 不成立
      //   ⇒ **原样吐出未平移的原始字节**。
      //
      // 后果：命中预取缓存的分片停留在「真实 PTS 轴」，与已平移的邻居段
      //   不同轴 ⇒ 进度条在该段处跳变，且**静默**（delta=0 不进平移分支，
      //   连自校验失败日志都不会打）。真机实证跳幅达 ±167s，关闭预取即消失。
      //
      // 修法：预取线程自己算 delta 并写入，与直连分支取同一个 `_deltaFor`，
      //   保证两条路径语义一致。
      //   🔴 2026-10-24：原先这里要传 `establishBase: false`，是因为 delta 依赖
      //   「全局基准段真实 PTS」，预取线程不能抢建基准。现在 delta 的目标
      //   （`meta.filteredMs`）**只由该分片自身决定**，不再有任何全局状态 ⇒
      //   预取与直连天然等价，参数已删除。
      if (_ptsNormalize) {
        try {
          _prefetchDelta[cdnUrl] = await _deltaFor(cdnUrl, body);
        } catch (e) {
          // 算 delta 失败不应拖垮预取：退回「不平移」的旧行为即可。
          _log('Prefetch: 计算 delta 失败，该分片不平移 $cdnUrl: $e');
        }
      }
      _storePrefetched(cdnUrl, body);
      _prefetchFailCount = 0; // 成功即重置连续失败计数
      _logOnce('hit:$cdnUrl',
          'Prefetch: 命中并缓存 $cdnUrl (${body.length} bytes)');
    } catch (e) {
      _prefetchFailCount++;
      _log('Prefetch: 预取异常 ($_prefetchFailCount/$_kMaxPrefetchFailures) $cdnUrl: $e');
    }
  }

  // ===== 🔴🔴 2026-10-24 第九轮：分片单飞下载 + 残缺分片自愈 =====

  /// **单飞**取一个分片的完整字节。
  ///
  /// 同一分片永远只有**一条**上行连接：后来的调用者直接拿同一个 Future。
  /// 这样「预取」与「播放器直连」不会再对同一分片各拉一次
  /// （那会互相争抢带宽，把其中一条流掐断 ⇒ 残缺分片 ⇒ 播放器重试 ⇒ 顿挫）。
  Future<Uint8List?> _fetchSegmentBytes(String cdnUrl) {
    final existing = _segmentFetchInFlight[cdnUrl];
    if (existing != null) return existing;
    final fut = _doFetchSegmentBytes(cdnUrl);
    _segmentFetchInFlight[cdnUrl] = fut;
    // 完成后清理登记。用 then(onError:) 而不是 whenComplete：
    // 后者在原始 Future 出错时会再抛出一个无人接管的异常（unhandled）。
    fut.then<void>(
      (_) => _dropInFlight(cdnUrl, fut),
      onError: (Object _, StackTrace __) => _dropInFlight(cdnUrl, fut),
    );
    return fut;
  }

  void _dropInFlight(String cdnUrl, Future<Uint8List?> fut) {
    if (identical(_segmentFetchInFlight[cdnUrl], fut)) {
      _segmentFetchInFlight.remove(cdnUrl);
    }
  }

  /// 实际下载一个分片的**完整**字节（**不带 Range**，走上游 200 完整路径）。
  ///
  /// 【为什么不用 Range】真机 hilog 2026-10-24 18:37 实测：
  ///   · 预取走「无 Range ⇒ 200」：71 次全部完整、0 次失败、0 次异常；
  ///   · 直连走「`Range: bytes=0-` ⇒ 206」：2 次被上游**中途掐断**
  ///     （declared=314148 sent=245716 / sent=147392）⇒ 残缺分片 ⇒ 顿挫。
  ///   ⇒ 206 路径在这个 CDN 上不可靠，完整 GET 才是稳的那条。
  ///
  /// 🔴🔴🔴 2026-10-24 第十轮：**加重试**。
  ///   真机 19:30 实测：即便是「无 Range ⇒ 200」路径，上游也会中途掐断
  ///   （声明 214696、只给 32768 字节）⇒ 一次失败就判残缺会让播放器
  ///   反复重试 ⇒ 反而更卡。⇒ 掐断属于**可重试**故障，重试到拿到完整为止。
  Future<Uint8List?> _doFetchSegmentBytes(String cdnUrl) async {
    Object? lastError;
    for (var attempt = 1; attempt <= _kSegmentFetchAttempts; attempt++) {
      try {
        final headers = _segmentRequestHeaders(cdnUrl);
        final client = _client ?? http.Client();
        final resp = await client
            .get(Uri.parse(cdnUrl), headers: headers)
            .timeout(const Duration(seconds: 30));
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          throw HttpException('分片下载失败 status=${resp.statusCode} $cdnUrl');
        }
        final body = resp.bodyBytes;
        // 自校验：完整 GET 的字节数必须等于 Content-Length。
        // 不等说明**上游也掐了**——此时缓存它等于缓存残缺数据，
        // 必须当作失败（宁可让播放器重试，也不能交付残缺分片）。
        final declared = resp.headers['content-length'];
        if (declared != null) {
          final d = int.tryParse(declared);
          if (d != null && d != body.length) {
            throw HttpException(
              '分片字节数与 Content-Length 不一致 declared=$d got=${body.length} $cdnUrl',
            );
          }
        }
        if (attempt > 1) {
          _log('Proxy: 分片第 $attempt 次重试成功（完整 ${body.length} bytes） $cdnUrl');
        }
        return body;
      } catch (e) {
        lastError = e;
        if (attempt < _kSegmentFetchAttempts) {
          _log('Proxy: 分片下载失败，重试 $attempt/$_kSegmentFetchAttempts $cdnUrl: $e');
          await Future<void>.delayed(Duration(milliseconds: 250 * attempt));
        }
      }
    }
    throw HttpException('分片下载重试 $_kSegmentFetchAttempts 次仍失败: $lastError');
  }

  /// 🔴🔴🔴 2026-10-24 第十轮：媒体分片的**完整下载**出口。
  ///
  /// 【为什么必须有这个出口 —— 真机实锤：hilog 2026-10-24 19:27~19:30】
  ///   · avp（AVPlayer）19:30:17 只请求了 **1 个**分片（6oxczFWF.ts），
  ///     代理声明 `Content-Length: 214696` 却只写出 **32768** 字节
  ///     ⇒ AVPlayer 按 Content-Length 等满，永远等不到完整分片
  ///     ⇒ `prepared` 之后**再无 `playing`**（18 秒后被释放）
  ///     ⇒ 画面卡死在开头画面，而进度条仍按播放记录显示
  ///     ⇒ 用户侧：「播放期间 mpv 切换 avp 直接卡死」。
  ///   · 同期 mpv：流式平移后 `sent=8272/314148`
  ///     ⇒ `[ffmpeg/demuxer:warn] mpegts: Packet corrupt`
  ///     ⇒ 解码失败重试 ⇒ 顿挫。
  ///
  /// 【根因】流式转发一旦被上游掐断（或播放器提前关闭连接），
  ///   代理写出的字节数 < Content-Length ⇒ 播放器拿到**残缺分片**。
  ///   AVPlayer 尤其不能容忍：它按 Content-Length 等满，不会把短读当「结束」。
  ///
  /// 【修法】分片一律「完整下载 → 校验 → 一次性写出」：
  ///   ① 完整下载走 [_fetchSegmentBytes]：**单飞**（与预取共用同一条上行连接）
  ///      + Content-Length 自校验 + 失败重试；
  ///   ② 下载不完整 ⇒ 重试；仍不完整 ⇒ 回 502，**绝不写残缺**；
  ///   ③ 完整 ⇒ 落预取缓存 + 算 delta ⇒ 复用 [_servePrefetched] 的统一出口
  ///      （按 Range 切片 + 后台 isolate 平移 + Content-Length 严格一致）。
  ///
  /// 【为什么不会明显变慢】预取命中率真机实测 **94%**
  ///   （缓存命中 122 + 复用预取 37 / 总请求 ≈ 160）
  ///   ⇒ 绝大多数请求走 [_servePrefetched] 的**零延迟**路径；
  ///   只有未命中的少数才需要完整下载一次（1~2 秒）。
  ///   相比之下，「流式但残缺」会让播放器**反复重试**同一段，代价更大。
  Future<void> _serveSegmentComplete(
    HttpRequest request,
    HttpResponse out,
    String targetUrl,
  ) async {
    Uint8List? bytes;
    final sw = Stopwatch()..start();
    try {
      bytes = await _fetchSegmentBytes(targetUrl);
    } catch (e) {
      _log('❌ proxySegment 完整下载失败 $targetUrl: $e');
    }
    final fetchMs = sw.elapsedMilliseconds;
    if (bytes == null || bytes.isEmpty) {
      // 绝不写残缺：明确失败，让播放器重试这一段（而不是拿到半截数据卡死）。
      out.statusCode = HttpStatus.badGateway;
      out.headers.set('Content-Length', '0');
      await out.close();
      return;
    }
    // 落缓存 + 算 delta（与预取线程同源同值，幂等覆盖）。
    if (_ptsNormalize) {
      try {
        _prefetchDelta[targetUrl] = await _deltaFor(targetUrl, bytes);
      } catch (e) {
        _log('Proxy: 直连分片计算 delta 失败，该分片不平移 $targetUrl: $e');
      }
    }
    _storePrefetched(targetUrl, bytes);
    // 统一出口：按 Range 切片 / 整段，Content-Length 与实际字节**严格一致**。
    if (await _servePrefetched(request, targetUrl)) {
      return;
    }
    // 预取未启用 ⇒ 直接整段写出（字节守恒）。
    out.statusCode = HttpStatus.ok;
    out.headers
      ..set('Content-Length', bytes.length.toString())
      ..set('Accept-Ranges', 'bytes');
    out.add(bytes);
    await out.close();
    _log('proxySegment 完整直连: $targetUrl (${bytes.length} bytes, 下载 ${fetchMs}ms)');
  }

  /// 等待「该分片正在被预取/修复下载」的那次下载完成，**直接返回完整字节**。
  ///
  /// 【为什么直接返回字节，而不是「等完再查缓存」】
  ///   预取线程拿到字节后还要 `await _deltaFor(...)` → `_storePrefetched(...)`
  ///   两步才把它落进缓存；而等待方的 Future 在**字节到达**时就恢复了
  ///   ⇒ 那一刻缓存里**可能还没有**这份数据 ⇒ 查缓存必然落空。
  ///   ⇒ 直接拿字节，由调用方自己落缓存 + 算 delta（幂等，结果一致）。
  ///
  /// 返回 null 表示「没有在途下载」或「等待失败/超时」⇒ 调用方回退直连回源。
  Future<Uint8List?> _awaitSegmentInFlight(String cdnUrl) async {
    final fut = _segmentFetchInFlight[cdnUrl];
    if (fut == null) return null;
    try {
      final bytes = await fut.timeout(_kInFlightWaitTimeout);
      if (bytes != null) {
        _logOnce('reuse:$cdnUrl',
            'Proxy: 复用预取中的分片（完整 ${bytes.length} bytes，不再回源） $cdnUrl');
      }
      return bytes;
    } catch (e) {
      _log('⚠️ 等待分片预取超时/失败，回退到直连回源 $cdnUrl: $e');
      return null;
    }
  }

  /// 后台**补齐**一个残缺分片：重新完整下载一份，存进预取缓存。
  ///
  /// 【为什么必须补】播放器拿到残缺分片 ⇒ 解码失败 ⇒ 会**重试**同一段。
  ///   若不补齐，重试命中的还是残缺数据 ⇒ 反复卡顿（真机 18:37:10 / 18:37:52
  ///   两次都是同一段 pUr8NL28.ts 被掐断）。
  ///   补齐后缓存里是**完整字节**，播放器重试即可一次成功。
  void _scheduleSegmentRepair(String cdnUrl) {
    if (!_prefetchEnabled || _closing) return;
    if (_segmentRepairInFlight.contains(cdnUrl)) return;
    _segmentRepairInFlight.add(cdnUrl);
    // 用 then(onError:) 而不是 whenComplete：后者在原 Future 出错时会
    // 再抛出一个无人接管的异常（unhandled exception）。
    _repairSegment(cdnUrl).then<void>(
      (_) => _segmentRepairInFlight.remove(cdnUrl),
      onError: (Object _, StackTrace __) =>
          _segmentRepairInFlight.remove(cdnUrl),
    );
  }

  Future<void> _repairSegment(String cdnUrl) async {
    try {
      final body = await _fetchSegmentBytes(cdnUrl);
      if (body == null) return;
      if (_ptsNormalize) {
        try {
          _prefetchDelta[cdnUrl] = await _deltaFor(cdnUrl, body);
        } catch (e) {
          _log('Proxy: 修复分片时计算 delta 失败，该分片不平移 $cdnUrl: $e');
        }
      }
      _storePrefetched(cdnUrl, body);
      _log('Proxy: ✅ 残缺分片已补齐（完整 ${body.length} bytes 重新入缓存） $cdnUrl');
    } catch (e) {
      _log('Proxy: ❌ 残缺分片补齐失败 $cdnUrl: $e');
    }
  }

  /// 从代理分片 URL 解析出 CDN 原始 URL（/segment?url=<encoded>）。
  String _extractTargetUrl(String proxyUrl) {
    try {
      final uri = Uri.parse(proxyUrl);
      final encoded = uri.queryParameters['url'];
      if (encoded == null || encoded.isEmpty) return '';
      return Uri.decodeComponent(encoded);
    } catch (_) {
      return '';
    }
  }

  /// 预取缓存命中时，按请求 Range 切片返回（无 Range 则整段返回）。
  /// 返回 true 表示已处理响应（调用方直接 return），false 表示未命中。
  ///
  /// 🔴 2026-10-09：缓存内统一存**原始 CDN 字节**，故 PTS 平移必须在此出口施加
  /// （与 `_proxySegment` 直连路径一致）。若 delta 为 0 或自校验不通过则原样返回。
  ///
  /// 🔴 2026-10-24：改为 **async**，把平移交后台 isolate（见
  /// [_normalizeInBackground]）—— 预取命中率很高，这里是平移最频繁的出口，
  /// 绝不能让它在主 isolate 上跑逐包解析。
  Future<bool> _servePrefetched(HttpRequest request, String proxyUrl) async {
    // 🔴🔴🔴 第十轮：**预取开关关闭时也要能走这个出口**。
    //   直连分片现在统一走「完整下载 → 落缓存 → 本出口」，
    //   若这里因 `_prefetchEnabled=false` 直接返回 false，
    //   就会退化成「不分片段」的 200 响应 ⇒ 部分 Range 请求不合法。
    if (!_prefetchEnabled && !_prefetchCache.containsKey(proxyUrl)) {
      return false;
    }
    final cached = _prefetchCache[proxyUrl];
    if (cached == null) return false;
    var body = cached;
    final delta = _prefetchDelta[proxyUrl] ?? 0;
    // 🔴🔴🔴 第十轮：**部分 Range 的起点不在 TS 包边界上时禁止平移**。
    //   平移是「每包加同一常数」，起点错位 ⇒ 会把一个 TS 包劈成两半分别改写
    //   ⇒ 静默损坏字节（表现为 Packet corrupt / 花屏）。
    final range = request.headers.value('range');
    final rangeStart = _rangeStartOf(range);
    final rangeAligned = rangeStartIsTsAligned(rangeStart);
    if (delta != 0 && !rangeAligned) {
      _log('Prefetch: 部分 Range 起点=$rangeStart 非 188 对齐 ⇒ 本次不平移（防字节损坏）'
          ' $proxyUrl');
    }
    if (delta != 0 && rangeAligned && !kPtsNormalizeObserveOnly) {
      final shifted = await _normalizeInBackground(body, delta) ??
          normalizeTsPts(body, delta);
      final chk = verifyPtsShift(body, shifted, delta, videoOnly: true);
      if (chk.ok) {
        body = shifted;
      } else {
        _log('Prefetch: PTS 平移自校验失败，回退原始字节 '
            '(${chk.reason} before=${chk.beforeMs} after=${chk.afterMs}) $proxyUrl');
      }
    }
    final out = request.response;
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
        // 🔴🔴🔴 2026-10-24：**必须 await close()**。
        //
        // 【真机实锤：hilog 2026-10-24 20:34:35~20:35:16 的 42.6 秒死循环】
        //   代理在这 42.6 秒里反复对**同一批 4 个段**打：
        //     「命中并缓存 3KpzUuSi.ts (191024 bytes)」
        //     「复用预取中的分片（完整 191024 bytes，不再回源）3KpzUuSi.ts」
        //   而 AVPlayer 反复来要同一段 ⇒ **它从未接受这份字节**。
        //   原因：`HttpResponse.add` 是**异步**写出的，原来这里 `out.close()`
        //   **没有 await** ⇒ 函数立刻返回 ⇒ socket 在数据写完前就被关闭
        //   ⇒ AVPlayer 按 Content-Length 等满却只收到部分字节 ⇒ 判定分片残缺
        //   ⇒ 重试同一段 ⇒ 代理再给同一份残缺数据 ⇒ **无限重试**。
        //   （与第十轮记录的老坑同源：那次是「声明 214696 只写出 32768」，
        //     这次是「复用预取缓存的路径」上的同一类截断。）
        await out.close();
        _log('Prefetch: 缓存命中(Range) $proxyUrl bytes=$start-$end');
        return true;
      }
    }
    out.statusCode = HttpStatus.ok;
    out.headers
      ..removeAll('Content-Range') // 200 响应不得携带 Content-Range
      ..set('Content-Length', fullLen.toString())
      ..set('Accept-Ranges', 'bytes');
    out.add(body);
    // 🔴 同上：必须 await close()，否则整段响应也会被截断。
    await out.close();
    _logOnce('whole:$proxyUrl', 'Prefetch: 缓存命中(整段) $proxyUrl');
    return true;
  }

  /// 解析 Range 头，返回 [start, end]（含端点）；非法/越界返回 null。
  ///
  /// 🔴 2026-10-24 第十轮：实现已委托到纯 Dart 判据
  /// [parseRangeBytes]（可离线逐例验证，见 tool/segment_integrity_verify.dart）。
  (int, int)? _parseRange(String range, int fullLen) {
    return parseRangeBytes(range, fullLen);
  }

  /// 解析 Range 头中的**起始字节偏移**；无法解析（如 suffix-range `bytes=-N`）返回 null。
  ///
  /// 【实现说明 —— 2026-10-24 第五轮】判据已抽到纯 Dart 模块
  ///   `hls_segment_range.dart`（可离线逐例验证），此处保留薄封装。
  int? _rangeStartOf(String? range) => rangeStartOf(range);

  bool _coversWholeSegment(http.StreamedResponse streamed) {
    return coversWholeSegment(
      statusCode: streamed.statusCode,
      contentRange: streamed.headers['content-range'],
    );
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
        // 🔴🔴 2026-10-08 回退：**恢复 `filtered != content` 判据**。
        //
        //   【曾犯的错】一度改为只判 `filtered != null`，理由是「purify 的
        //     回退路径原样返回 content，会被这里丢弃」。但实际上这个判据是
        //     **刻意设计的**：`filtered == content` 恰恰表示「purify 什么都没
        //     改」，此时用入参是正确行为。
        //
        //   【实测灾难】改为只判 null 后，把 purify 各分支（含被篡改的
        //     ENDLIST 补全）的输出全部放行，导致播放列表被伪造为有限列表：
        //       · mpv：总时长恒为 **2 秒**，只能从头播、**无法快进**
        //       · avp：`avplayerStatus=error` + `code 5400103`，**直接无法播放**
        //
        //   【教训】不要为了让某条修复「生效」而放宽一个**上游采纳判据** ——
        //     那会把该函数所有分支的输出（包括尚未验证的）一并放行。
        //     修 ENDLIST 应该修在产生它的地方，而不是拆掉调度层的保护。
        return filtered;
      }
    } catch (e, stack) {
      WindowsLogger.log('LocalM3u8Proxy', '子 M3U8 过滤失败: $e');
      WindowsLogger.log('LocalM3u8Proxy', '$stack');
    }
    return content;
  }
}
