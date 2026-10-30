import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'aes128_cbc.dart';
import 'm3u8_ad_filter.dart';
import 'ts_pts_normalizer.dart';
import '../utils/windows_logger.dart';

/// 本地 M3U8/TS 代理服务。
///
/// 用于解决去广告后的 M3U8 在不同播放器后端（ExoPlayer / FVP / VLC）
/// 中播放时头部透传不一致的问题。所有资源请求统一走本地代理，由代理补全头部。
///
/// 🔴🔴 2026-10-12：新增 **PTS 归一化**（去广告轴对齐）——见 [_deltaFor]。
class LocalM3u8Proxy {
  /// 🔴 当前活动实例。供 static 的 [_filterM3u8] 在子 M3U8 过滤出口把
  /// 元数据回装到实例上（static 方法拿不到 `this`）。
  /// 全局同时只有一个代理在跑，因此单槽足够。
  static LocalM3u8Proxy? _instance;

  /// 🔴 2026-10-29：当前活动实例（供 mpv 后端在 open/seek **之前**调用
  ///   [primePrefetchAt] 预热落点分片）。
  ///
  ///   移植自 hain_tv（主工程）与 hain_tv_ohos（鸿蒙）：真机日志
  ///   （小米 12S Pro 2026-10-29 21:31）证明 mpv 起播要等 6.3s 才出首帧，
  ///   根因是「建索引头部段」与「落点段」全部串行等 CDN 往返。
  static LocalM3u8Proxy? currentInstance;

  HttpServer? _server;
  String? _playlistContent;
  final Map<String, String> _baseHeaders = {};
  http.Client? _client;
  bool _closing = false;
  bool _filterEnabled = false;
  bool _discontinuityCleanup = false;

  /// 🔴 是否启用 PTS 归一化（把分片真实 PTS 轴平移到去广告名义轴）。
  ///
  /// 【为什么要开关】平移会**重写分片字节**，属高风险改动。保留一个硬开关
  /// 便于出问题一键回退到纯透传（历史行为）。
  bool _ptsNormalize = true;

  /// 分片 URL（绝对） → 该分片在**去广告名义轴**上的起点 ms。
  /// 由 `M3u8AdFilter` 在过滤出口重建，经 [setSegMeta] 送入。
  Map<String, int> _segMeta = <String, int>{};

  /// 基准分片（列表首个分片）的**首个视频 PES 的真实 PTS**（ms）。
  /// 建立一次后固定：它定义了「真实轴 → 名义轴」的平移原点。
  int? _baseFirstPts;

  /// 基准分片在**去广告名义轴**上的起点 ms。
  ///
  /// 🔴 与 [_baseFirstPts] 成对使用。两条轴必须锚定到**同一个分片**，
  /// 否则基准段之前的时长会被重复计入，导致整体固定偏移。
  int? _baseFiltered;

  /// 每段的 delta 缓存：URL → deltaMs。避免同一分片被重复请求时反复计算。
  final Map<String, int> _segDeltaCache = <String, int>{};

  /// 每段的「首 PTS」缓存：URL → ms。用于诊断与基准复用。
  final Map<String, int> _segFirstPtsCache = <String, int>{};

  /// AES 密钥缓存：keyUri → 16 字节密钥。避免每段都重新下载 key.key。
  final Map<String, Uint8List> _aesKeyCache = <String, Uint8List>{};

  /// 解密失败计数（仅用于日志节流，避免每段刷屏）。
  int _decryptFailCount = 0;

  /// 埋点节流：上次打印轴信息的段序号（每 N 段打一次，避免刷屏）。
  int _axisLoggedIndex = -1;

  bool get isRunning => _server != null;

  /// 设置是否对子 M3U8 启用广告过滤。
  void setFilterEnabled(bool enabled) {
    _filterEnabled = enabled;
  }

  /// 设置去广告后是否清理孤立的 EXT-X-DISCONTINUITY 标记（Windows/fvp 需要）。
  void setDiscontinuityCleanup(bool enabled) {
    _discontinuityCleanup = enabled;
  }

  /// 🔴 送入去广告名义轴元数据（分片绝对 URL → 起点 ms）。
  ///
  /// 由 `AdFilterEngine.filterM3u8` 在过滤完成后调用。调用方应同时
  /// [resetPtsBase]，因为换了播放列表意味着真实/名义两条轴都换了基准。
  void setSegMeta(Map<String, int> meta, {String? aesKeyUri}) {
    _segMeta = Map<String, int>.from(meta);
    _log(
      'PTS 元数据已装入：${_segMeta.length} 段 '
      'aesKey=${aesKeyUri ?? "无（非加密源）"}',
    );
  }

  /// 🔴 重置 PTS 基准（换源/换子列表时调用）。
  void resetPtsBase() {
    _baseFirstPts = null;
    _baseFiltered = null;
    _segDeltaCache.clear();
    _segFirstPtsCache.clear();
    _axisLoggedIndex = -1;
  }

  /// 🔴 从**子 M3U8 过滤出口**装入元数据并重置基准。
  ///
  /// 与 [setSegMeta] 的区别：子列表是另一条播放列表，其真实 PTS 基准与
  /// 名义原点都与顶层不同，**必须连带重置基准**，否则首段 delta 会算错。
  void _installSegMetaFromSubList(Map<String, int> meta, {String? aesKeyUri}) {
    _segMeta = Map<String, int>.from(meta);
    _aesKeyCache.clear(); // 换列表必然换密钥，避免沿用旧密钥
    resetPtsBase();
    _log(
      'PTS 元数据已装入（子列表）：${_segMeta.length} 段 '
      'aesKey=${aesKeyUri ?? "无（非加密源）"}',
    );
  }

  /// 是否启用 PTS 归一化。
  void setPtsNormalize(bool enabled) {
    _ptsNormalize = enabled;
    _log('PTS 归一化开关 = $enabled');
  }

  void _log(String message) {
    WindowsLogger.log('LocalM3u8Proxy', message);
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
    _instance = this;
    currentInstance = this;
    _log('LocalM3u8Proxy started at $baseUrl');
    return baseUrl!;
  }

  /// 设置当前播放列表内容与原始请求头。
  ///
  /// [primeHead] 是否**立即**开始「建索引头部段」预热（mpv 后端专用）。
  ///
  /// 🔴 2026-10-29 真机日志实锤（小米 12S Pro 2026-10-29 22:44）：
  ///   拿到完整 media 列表比 MpvBackend open 早约 2.1s；plist0 是 mpv 建索引的
  ///   **阻塞项**，若预热等到 open 才开始，就只能跟 mpv 抢同一条下载。
  void setPlaylist(String content, Map<String, String> headers,
      {bool primeHead = false}) {
    _playlistContent = content;
    _baseHeaders
      ..clear()
      ..addAll(headers);
    // 🔴 2026-10-29：换源必须清掉旧源的预热缓存（否则旧源字节会被新源命中）。
    _primeCache.clear();
    _primeQueued.clear();
    _primeQueue.clear();
    _primeInflight.clear();
    _primePriority.clear();
    _primeBytes = 0;
    _primeRequested = false;
    _pendingPrefetchTargetMs = null;
    // 🔴 2026-10-29：收集分片表（纯解析，无网络开销）——
    //   起播预热要用它把「播放位置」换算成「分片下标」。
    _collectSegmentUrls(content);
    if (primeHead) {
      _primeHeadSegments(force: true);
    }
  }

  // ═══════════════════════════════════════════════════════════════════════
  // 起播预热（落点窗口 + 建索引头部段）—— 移植自 hain_tv / hain_tv_ohos
  // ═══════════════════════════════════════════════════════════════════════

  /// 🔴 2026-10-29：预热缓存（CDN 原始字节 → 分片 URL）。
  ///
  ///   加密源存**密文**（出口的解密分支照常解密），明文源存**明文**
  ///   （出口的 PTS 归一化照常施加）⇒ 预热只省掉一次回源 RTT，
  ///   解密 / 平移 / Range / 状态码语义**完全不变**。
  final Map<String, Uint8List> _primeCache = {};
  int _primeBytes = 0;
  /// 🔴 2026-10-29：**在途**下载表（分片 URL → 下载 Future）。
  ///   播放器请求某分片时，若预热线程正在下载同一分片，就等它下完复用同一份
  ///   字节，而不是自己再发一次请求（既省往返，也避免两份下载互抢带宽）。
  final Map<String, Future<Uint8List?>> _primeInflight = {};
  final List<String> _primeQueue = [];

  /// 🔴 2026-10-30：预热队列里的「关键路径」分片（目前 = 落点段）。
  ///
  ///   落点段是 seek 的直接目标，一刻都不能等 ⇒ 它插队到队首，并允许
  ///   [_kPrimePriorityBonus] 路额外并发，让它与建索引段**并行**下载。
  final Set<String> _primePriority = <String>{};
  final Set<String> _primeQueued = {};
  int _primeWorkers = 0;
  /// 是否已有后端请求过起播预热（头部段预热只在该闸门打开后进行）。
  bool _primeRequested = false;

  /// 分片 CDN URL（顺序）与各自在**名义轴**（EXTINF 累加轴）上的起点 ms。
  List<String> _segmentUrls = const [];
  List<int> _segmentStartMs = const [];

  /// 分片表尚未就绪时挂起的预热目标（ms）。
  int? _pendingPrefetchTargetMs;

  /// 建索引头部段数量（mpv 从第 0 段开始顺序拉若干段来建索引）。
  static const int _kIndexHeadSegments = 4;
  /// 落点预热窗口深度（含落点自身）。
  static const int _kPrimeDepth = 12;
  /// 预热并发路数（CDN 扛得住并发：8 路并发 ttfb 与串行几乎一样）。
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
  /// 预热缓存上限 50MB。
  static const int _kMaxPrefetchCacheBytes = 50 * 1024 * 1024;

  /// `_collectedFrom` 幂等守卫：同一份 playlist 不重复解析。
  String? _collectedFrom;

  /// 🔴 2026-10-29：把「落点分片窗口」预热到指定播放位置。
  ///
  /// 由 mpv 后端在 `open(startAt)` / `seek()` **之前**调用。
  ///
  /// 【真机实锤（小米 12S Pro 2026-10-29 21:31）】
  ///   21:31:29.744 open startAt=1450000ms
  ///   21:31:31.156~33.893 plist0~3 串行下载（2.7s，建索引阻塞）
  ///   21:31:34.054 plist315（落点段）才下载完（open 后 4.3s）
  ///   21:31:36.005 首帧（open 后 6.3s）
  void primePrefetchAt(Duration position) {
    final ms = position.inMilliseconds;
    _primeRequested = true;
    if (_segmentUrls.isEmpty || _segmentStartMs.isEmpty) {
      _pendingPrefetchTargetMs = ms;
      _log('Prime: 分片表未就绪，挂起落点 ${ms}ms');
      return;
    }
    final idx = _indexForPosition(ms);
    if (idx < 0) return;
    _log('Prime: 落点 ${ms}ms → 分片 #$idx / 共 ${_segmentUrls.length} 段');

    // 入队顺序 = 优先级：落点段自身 → 建索引头部段 → 落点窗口其余段。
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

  /// 预热「建索引头部段」（0.._kIndexHeadSegments-1）。
  ///
  /// 【包含第 0 段的理由】2026-10-29 22:44 真机日志：plist0 是 mpv 建索引的
  /// **阻塞项**（file-loaded 直接等它），且它与预热并发抢带宽
  /// （单独下载 1.95s → 并发时 2.28s）⇒ 必须提前备好，
  /// 并配合「在途去重」让 mpv 复用同一次下载。
  ///
  /// [force] 为 true 时忽略「是否已请求过预热」的闸门（open 之前触发）。
  void _primeHeadSegments({bool force = false}) {
    if (!force && !_primeRequested) return;
    for (var i = 0; i < _kIndexHeadSegments; i++) {
      _enqueuePrimeIndex(i);
    }
    _pumpPrimeWorkers();
  }

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
      if (_primeQueue.isNotEmpty) _pumpPrimeWorkers();
    }
  }

  /// 预热单个分片：回源 CDN 下载**原始字节**并缓存。
  Future<void> _primeOne(String cdnUrl) async {
    try {
      // 登记在途 Future：播放器若此时来要同一段，会等它而不是重复下载。
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
    } finally {
      _primeInflight.remove(cdnUrl);
    }
  }

  /// 回源下载单个分片的原始字节（失败返回 null）。
  Future<Uint8List?> _downloadSegmentBytes(String cdnUrl) async {
    try {
      final headers = Map<String, String>.from(_baseHeaders);
      headers['Accept'] = '*/*';
      headers['Connection'] = 'keep-alive';
      var referer = _baseHeaders['Referer'] ?? _baseHeaders['referer'];
      var origin = _baseHeaders['Origin'] ?? _baseHeaders['origin'];
      if (referer == null || referer.isEmpty) {
        final u = Uri.parse(cdnUrl);
        referer = '${u.scheme}://${u.host}/';
        headers['Origin'] = '${u.scheme}://${u.host}';
      }
      headers['Referer'] = referer;
      if (origin != null && origin.isNotEmpty) headers['Origin'] = origin;

      final resp = await (_client ?? http.Client())
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

  /// 取该分片的「已预热字节」：已缓存直接给；正在下载则等它下完复用；
  /// 都没有则返回 null（调用方自己回源）。
  Future<Uint8List?> _awaitPrimedSegment(String targetUrl) async {
    final cached = _primeCache[targetUrl];
    if (cached != null) return cached;
    final inflight = _primeInflight[targetUrl];
    if (inflight == null) return null;
    try {
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

  /// 若该分片已被预热（或正在预热），伪造一个 http.StreamedResponse 顶替回源响应。
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

  /// 从**重写后**的播放列表收集分片 CDN URL 与名义轴起点。
  void _collectSegmentUrls(String rewrittenPlaylist) {
    if (_collectedFrom == rewrittenPlaylist) return;
    _collectedFrom = rewrittenPlaylist;

    final urls = <String>[];
    final starts = <int>[];
    var accMs = 0;
    var pendingMs = 0;
    var hasPending = false;
    for (final raw in rewrittenPlaylist.split('\n')) {
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
      if (t.contains('/segment?url=')) {
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
    _log('Prime: 收集分片 ${urls.length} 个');

    if (_pendingPrefetchTargetMs != null && urls.isNotEmpty) {
      final pending = _pendingPrefetchTargetMs!;
      _pendingPrefetchTargetMs = null;
      primePrefetchAt(Duration(milliseconds: pending));
    } else if (urls.isNotEmpty) {
      _primeHeadSegments();
    }
  }

  /// 把 `$baseUrl/segment?url=<encoded CDN>` 还原为原始 CDN 绝对地址。
  static String? _realUrlOfProxySegment(String line) {
    final idx = line.indexOf('url=');
    if (idx < 0) return line.startsWith('http') ? line : null;
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

  /// 按播放位置（ms）在名义轴上二分定位分片下标。
  int _indexForPosition(int positionMs) {
    final starts = _segmentStartMs;
    if (starts.isEmpty) return -1;
    if (positionMs <= starts.first) return 0;
    if (positionMs >= starts.last) return starts.length - 1;
    var lo = 0;
    var hi = starts.length - 1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      final v = starts[mid];
      if (v == positionMs) return mid;
      if (v < positionMs) {
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    return lo - 1 < 0 ? 0 : lo - 1;
  }

  Future<void> stop() async {
    _closing = true;
    await _server?.close(force: true);
    _server = null;
    if (identical(_instance, this)) _instance = null;
    if (identical(currentInstance, this)) currentInstance = null;
    _primeCache.clear();
    _primeQueued.clear();
    _primeQueue.clear();
    _primeBytes = 0;
    _playlistContent = null;
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

  // ───────────────────────────────────────────────────────────────────────
  // PTS 归一化（去广告轴对齐）
  // ───────────────────────────────────────────────────────────────────────

  /// 🔴🔴 计算某分片需要平移的 delta（ms）。
  ///
  /// 【原理】（移植自鸿蒙版 `local_m3u8_proxy.dart` 的 `_deltaFor`，见工作日志
  ///   `2026-10-11-mpv进度漂移根治-跨平台通用总结.md` §3）
  ///
  ///   去广告只删播放列表的**行**，不改分片**字节**。于是：
  ///     · 真实 PTS 轴 = 分片里编码的 PTS（**含广告**的原始时间线）
  ///     · 名义轴     = 去广告后 EXTINF 累加（mpv 的 duration 走这条）
  ///   mpv `time-pos` 走真实轴、`duration` 走名义轴 ⇒ 进度条越播越偏。
  ///
  ///   修法：把每段的 PTS 平移 `delta`，使 `该段首PTS + delta == 名义轴起点`。
  ///   以**列表首段**为原点：
  ///     expected(i) = baseFirstPts + filteredMs(i)
  ///     delta(i)    = expected(i) − firstPts(i)
  ///
  ///   🔴 与鸿蒙的唯一差异：鸿蒙用 `filteredMs = index × 2000`（其源恰为 2s/段），
  ///     legacy 一律用 [M3u8AdFilter] 产出的**真实 EXTINF 累加**，避免源段长
  ///     非整 2 秒时引入新的系统性误差。
  ///
  /// 【返回】需平移的毫秒数；0 表示无需平移（透传原字节）。
  Future<int> _deltaFor(String segUrl, List<int> bytes) async {
    if (!_ptsNormalize) return 0;
    if (_segMeta.isEmpty) return 0;

    // 命中缓存（同一分片可能被 seek 后重复请求）。
    final cached = _segDeltaCache[segUrl];
    if (cached != null) return cached;

    final filtered = _segMeta[segUrl];
    if (filtered == null) {
      // 🔴 查表 miss 是**静默失效**的主要来源（鸿蒙日志「坑 2」）。
      //   必须打日志，否则表现为「机制装了但完全没生效」而无人察觉。
      _log('PTS skip: no-meta url=$segUrl');
      return 0;
    }

    final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);

    // 🔴🔴 2026-10-12（移植鸿蒙方案后）：进到这里的一律是**明文**。
    //
    // 【历史包袱已清除】上一版曾在这里对密文做「只读解密再读 PTS」的回退，
    //   那是为「密文原样转发给 mpv」的旧架构打的补丁。新架构下 AES 分片走
    //   `_proxyDecryptedSegment`，**调用本函数时已经是解密并去填充后的明文**，
    //   再解一次密只会得到垃圾。故该分支已删除。
    //
    // 【同时删掉的还有静态 `_aesKeyUri` 依赖】key 现在由分片 URL 参数携带
    //   （`&key=`），不再依赖静态成员，多源并发时不会互相覆盖。
    final first = firstPesPtsMs(data, videoOnly: true);

    if (first == null) {
      _log('PTS skip: no-pts filtered=${filtered}ms url=$segUrl');
      return 0;
    }
    _segFirstPtsCache[segUrl] = first;

    // 建立基准：第一个能读到 PTS 的分片即原点。
    //
    // 🔴🔴 2026-10-12 关键修正：必须**同时**记住基准段的**名义轴**起点。
    //
    // 【原先的 bug】旧式 `expected = _baseFirstPts + filtered` 隐含假设
    //   「基准段的名义起点 = 0」。但只要基准段不是列表首段（例如首段被
    //   判为广告而删除、或首段解密失败读不到 PTS），这个假设就不成立，
    //   基准段的名义起点会被**重复计入一次**，表现为：
    //   **所有分片被统一多平移 `filtered_base` 毫秒** —— 即用户报告的
    //   「快进快退定位后**固定往后偏移一定时间**」。
    //
    //   实测（真实源 1394 段，AES-128）：基准段 idx1 的 filtered=3520ms、
    //   真实 PTS=5000ms ⇒ 旧式算出恒定 delta=+3520ms，与实测的固定偏移吻合。
    //
    // 【正确公式】把两条轴都锚定到同一个基准段：
    //   expected = _baseFirstPts + (filtered − _baseFiltered)
    //   即基准段自身 delta 恒为 0，其余段按**名义轴上的相对位移**平移。
    if (_baseFirstPts == null) {
      _baseFirstPts = first;
      _baseFiltered = filtered;
      _log(
        'PTS 基准已建立：baseFirstPts=${first}ms baseFiltered=${filtered}ms '
        'baseUrl=$segUrl（该段 delta 恒为 0）',
      );
    }

    final expected = _baseFirstPts! + (filtered - _baseFiltered!);
    final delta = expected - first;

    // 埋点：打印两条轴的对照，`residual` 是生效的唯一判据（平移后应恒为 0）。
    //
    // 节流：逐段打印会刷屏（一个点播源上千段）。策略是**首段必打**
    //   （用于确认基准建立正确），其后每 50 段打一次（用于观察漂移趋势）。
    final shifted = first + delta;
    _axisLoggedIndex += 1;
    if (_axisLoggedIndex == 0 || _axisLoggedIndex % 50 == 0) {
      _log(
        'PTS axis: n=$_axisLoggedIndex filtered=${filtered}ms trueFirst=${first}ms '
        'expected=${expected}ms delta=${delta}ms shifted=${shifted}ms '
        'residual=${shifted - expected}ms',
      );
    }

    _segDeltaCache[segUrl] = delta;
    return delta;
  }

  /// 取（并缓存）AES-128 key。失败返回 null 并打节流日志。
  ///
  /// 有 key 缓存 ⇒ 每段不会重复拉 key（鸿蒙同款做法）。
  Future<Uint8List?> _fetchAesKey(String? keyUri) async {
    if (keyUri == null || keyUri.isEmpty) return null;
    final cached = _aesKeyCache[keyUri];
    if (cached != null) return cached;
    try {
      final resp = await (_client ?? http.Client())
          .get(Uri.parse(keyUri), headers: _baseHeaders)
          .timeout(const Duration(seconds: 8));
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        _logThrottled('AES 密钥下载失败 status=${resp.statusCode} uri=$keyUri');
        return null;
      }
      final body = resp.bodyBytes;
      if (body.length != 16) {
        _logThrottled('AES 密钥长度异常 ${body.length}（应为 16）uri=$keyUri');
        return null;
      }
      final key = Uint8List.fromList(body);
      _aesKeyCache[keyUri] = key;
      _log('AES 密钥已获取（16 字节）uri=$keyUri');
      return key;
    } catch (e) {
      _logThrottled('AES 密钥获取异常：$e uri=$keyUri');
      return null;
    }
  }

  /// 🔴🔴 2026-10-12 移植鸿蒙方案核心：AES-128 分片「解密 → 平移 PTS → 吐明文」。
  ///
  /// 这是修复「快进快退后固定往后偏移」的关键一环。与直连路径的差别：
  ///   · 回源拿到的是**密文**，先整体解密成本段明文；
  ///   · 在**明文**上做 PTS 归一化（[normalizeTsPts]）；
  ///   · 归一化必须按**明文整段**做，而不是按 Range 切片做 ——
  ///     因为 PTS 改写依赖分片内所有 PES 的连续性，切片会切断这个前提。
  ///
  /// 【Range 语义】本函数**不支持**分片内 Range：播放器拿到的 Content-Length
  ///   会小于源站的密文长度（AES-CBC 密文比明文多 PKCS7 填充），所以源站的
  ///   Range 坐标对播放器无意义。策略是：
  ///     · 忽略请求的 Range，整段解密后**按明文的请求区间切片**返回 206；
  ///     · Content-Range 与 Content-Length 一律用**明文坐标**，两者同套坐标。
  ///   ⚠️ 这套「两坐标必须一致」的教训来自鸿蒙实测：`Content-Range` 用密文
  ///   总长、`Content-Length` 用去填充明文长，两者差 8 字节 ⇒ ffmpeg 报
  ///   `Stream ends prematurely` 并反复重开分片（2026-09-26 日志 93 次）。
  Future<void> _proxyDecryptedSegment(
    HttpRequest request, {
    required bool isHead,
    required String targetUrl,
    required String keyUri,
    required Uint8List iv,
  }) async {
    final out = request.response;
    try {
      final key = await _fetchAesKey(keyUri);
      if (key == null) {
        _logThrottled('AES 分片解密失败（无 key）：$targetUrl');
        out.statusCode = HttpStatus.internalServerError;
        await out.close();
        return;
      }

      // 回源拿完整密文
      final headers = Map<String, String>.from(_baseHeaders);
      headers['Accept'] = '*/*';
      headers['Connection'] = 'keep-alive';
      var referer = _baseHeaders['Referer'] ?? _baseHeaders['referer'];
      if (referer == null || referer.isEmpty) {
        final u = Uri.parse(targetUrl);
        referer = '${u.scheme}://${u.host}/';
        headers['Origin'] = '${u.scheme}://${u.host}';
      }
      headers['Referer'] = referer;

      // 🔴 分段计时埋点（2026-10-12 缓冲慢排查）。
      //   真机实测每段 250KB 要 4~11 秒，而本地 AES 解密仅 36ms，
      //   故必须把「回源 / 读体 / 解密 / 平移」四段计时打出来才能定位。
      final swSeg = Stopwatch()..start();
      _log('proxyDecryptedSegment request: $targetUrl');
      // 🔴 2026-10-29：起播预热命中 ⇒ 直接用本地密文，省掉一次回源往返。
      //   解密 / PKCS7 去填充 / PTS 平移 / Range 切片逻辑**一行不改**
      //   （字节与回源完全相同），只是省掉了「等 CDN」这一段。
      final primed = await _awaitPrimedSegment(targetUrl);
      late final Uint8List cipher;
      late final int tHeaders;
      late final int tBody;
      if (primed != null) {
        _log('Prime: 解密分支命中预热密文 ${primed.length} bytes $targetUrl');
        cipher = primed;
        tHeaders = swSeg.elapsedMilliseconds;
        tBody = tHeaders;
      } else {
        final resp = await (_client ?? http.Client())
            .send(http.Request('GET', Uri.parse(targetUrl))..headers.addAll(headers))
            .timeout(const Duration(seconds: 30));
        tHeaders = swSeg.elapsedMilliseconds;
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          _logThrottled('AES 分片回源失败 status=${resp.statusCode} url=$targetUrl');
          out.statusCode = resp.statusCode;
          await out.close();
          return;
        }
        cipher = await resp.stream.toBytes();
        tBody = swSeg.elapsedMilliseconds;
      }

      // 🔴 哨兵：源站返回的可能**本就是明文**（未加密分片、或已被上游解密）。
      //
      // 【判据】TS 明文必然是 188 字节栅格且每包首字节为 sync byte 0x47。
      //   密文是均匀噪声，落在同一栅格上的概率约 1/256 ⇒ 命中率 <1% vs 明文 100%。
      //   本判据在探测集上实测：明文 4/4 命中 100%，密文 4/4 命中 <1%。
      //
      // 【不加这个哨兵会怎样】对明文再解一次密 ⇒ 得到垃圾字节 ⇒ 播放器花屏/卡死。
      //   这不是假想风险：探测集 `/tmp/ptsprobe/` 里就有 4 个分片（b867/b868/
      //   b870/b1390）首 16 字节为 `47 40 11 10`，即 TS sync byte，说明真实环境
      //   确实存在「标记为加密、实际返回明文」的分片。
      if (_looksLikePlainTs(cipher)) {
        _log('AES 分片实为明文（跳过解密）：url=$targetUrl len=${cipher.length}');
        await _emitPlainSegment(
          request,
          out: out,
          isHead: isHead,
          targetUrl: targetUrl,
          plain: cipher,
        );
        return;
      }

      // 整段解密（含 PKCS7 填充）
      final plainPadded = Aes128Cbc.decrypt(cipher, key, iv: iv);
      if (plainPadded == null) {
        _logThrottled('AES 分片解密返回 null（长度非 16 倍数？）'
            'len=${cipher.length} url=$targetUrl');
        out.statusCode = HttpStatus.internalServerError;
        await out.close();
        return;
      }

      // PKCS7 去填充（仅对**整段**做一次，不能在切片后做）
      final plain = _stripPkcs7(plainPadded);
      final tDecrypt = swSeg.elapsedMilliseconds;

      await _emitPlainSegment(
        request,
        out: out,
        isHead: isHead,
        targetUrl: targetUrl,
        plain: plain,
        tag: 'proxyDecryptedSegment',
        extra: 'cipher=${cipher.length} pad=${plainPadded.length - plain.length}',
      );
      final tTotal = swSeg.elapsedMilliseconds;
      _log('TIMING seg: url=$targetUrl total=${tTotal}ms '
          'headers=${tHeaders}ms body=${tBody - tHeaders}ms '
          'decrypt=${tDecrypt - tBody}ms emit=${tTotal - tDecrypt}ms '
          'len=${cipher.length}');
    } catch (e, stack) {
      _log('proxyDecryptedSegment error: $e url=$targetUrl');
      _log('$stack');
      try {
        out.statusCode = HttpStatus.internalServerError;
        await out.close();
      } catch (_) {}
    }
  }

  /// 把**明文**分片做 PTS 归一化后发出。解密路径与「实为明文」路径共用。
  ///
  /// 【坐标统一】Content-Length / Content-Range 一律用**明文**坐标。
  ///   ⚠️ 鸿蒙踩过的坑（2026-09-26 日志 93 次报错）：Range 用密文坐标、
  ///   Length 用去填充明文长度 ⇒ ffmpeg 报 `Stream ends prematurely at X,
  ///   should be Y` 并反复重开同一分片。两条坐标必须同源。
  Future<void> _emitPlainSegment(
    HttpRequest request, {
    required HttpResponse out,
    required bool isHead,
    required String targetUrl,
    required Uint8List plain,
    String tag = 'emitPlainSegment',
    String extra = '',
  }) async {
    // 🔴 关键一步：在**明文整段**上做 PTS 归一化
    var payload = plain;
    final delta = await _deltaFor(targetUrl, plain);
    if (delta != 0) {
      payload = _applyPtsShift(targetUrl, plain, delta);
    }

    out.statusCode = HttpStatus.ok;
    out.headers.contentType = ContentType('video', 'mp2t');
    out.headers.add('Access-Control-Allow-Origin', '*');
    out.headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
    out.headers.set('Content-Length', payload.length.toString());
    if (delta != 0) {
      out.headers.set('X-Pts-Shift', delta.toString());
    }
    if (isHead) {
      await out.close();
      return;
    }
    out.add(payload);
    await out.close();
    _log('$tag: $targetUrl -> ${extra.isEmpty ? '' : '$extra '}'
        'plain=${plain.length} delta=${delta}ms');
  }

  /// 判断字节是否**已经是 TS 明文**（未加密）。
  ///
  /// 【判据】TS 明文是 188 字节定长包，每包首字节必为 sync byte 0x47。
  ///   密文是均匀噪声，同一栅格命中率约 1/256 ≈ 0.4%。
  ///   取前 8 个包判定即可，实测明文 100%、密文 <1%，区分度极高。
  ///
  /// 【为什么不直接看首字节】单个包有 1/256 的偶然命中率，8 个包可压到 ≈0。
  static bool _looksLikePlainTs(Uint8List data) {
    if (data.length < 188 * 4) return false;
    const kTsPacket = 188;
    const kSync = 0x47;
    var hit = 0;
    final n = 8;
    for (var i = 0; i < n; i++) {
      final off = i * kTsPacket;
      if (off >= data.length) break;
      if (data[off] == kSync) hit++;
    }
    return hit >= 6;
  }

  /// PKCS7 去填充。填充非法（0 或 >16）时原样返回，交由 PTS 解析自行判断。
  static Uint8List _stripPkcs7(Uint8List data) {
    if (data.isEmpty) return data;
    final pad = data[data.length - 1];
    if (pad < 1 || pad > 16 || pad > data.length) return data;
    return Uint8List.sublistView(data, 0, data.length - pad);
  }

  /// 日志节流：同一类失败最多打 5 条，避免每段刷屏。
  void _logThrottled(String message) {
    if (_decryptFailCount < 5) {
      _decryptFailCount++;
      _log(message);
      if (_decryptFailCount == 5) {
        _log('（同类解密日志已达上限 5 条，后续不再打印）');
      }
    }
  }

  /// 🔴 对分片字节做 PTS 平移，带自校验与失败回退。
  ///
  /// 返回平移后的字节。以下情况一律**回退原始字节**（宁可偏，不可花）：
  ///   · delta 为 0（无需平移）
  ///   · 平移自校验失败（[verifyPtsShift] 返回 !ok）
  ///   · 任何异常
  Uint8List _applyPtsShift(String segUrl, Uint8List bytes, int deltaMs) {
    if (deltaMs == 0) return bytes;
    try {
      final shifted = normalizeTsPts(bytes, deltaMs);
      final check = verifyPtsShift(bytes, shifted, deltaMs, videoOnly: true);
      if (!check.ok) {
        _log(
          'PTS 平移自校验失败，回退原始字节：url=$segUrl delta=${deltaMs}ms '
          'reason=${check.reason} before=${check.beforeMs}ms after=${check.afterMs}ms',
        );
        return bytes;
      }
      _log(
        'PTS 平移成功：url=$segUrl delta=${deltaMs}ms '
        '${check.beforeMs}ms -> ${check.afterMs}ms',
      );
      return shifted;
    } catch (e) {
      _log('PTS 平移异常，回退原始字节：url=$segUrl delta=${deltaMs}ms err=$e');
      return bytes;
    }
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
    final content = _playlistContent ?? '#EXTM3U\n#EXT-X-ENDLIST\n';
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
    final targetUri = Uri.parse(targetUrl);

    // 🔴🔴 2026-10-12 移植鸿蒙方案：AES-128 分片走「代理解密」专用路径。
    //
    // 由 `rewriteToLocalProxy` 在分片 URL 上注入 `&decrypt=aes128&key=&iv=`。
    // 代理取 key → 解密整段 → 在**明文**上归一化 PTS → 把**明文**吐给播放器。
    //
    // 【为什么必须这样】PTS 编码在密文内部。若只解密来「读」而把密文原样转发，
    //   则改字节这一步必然失败（在密文上读 PTS 恒 null）——
    //   这正是我上一轮的实测日志 `reason=no-pts-before before=nullms` ×50，
    //   50/50 全部回退、零次平移成功。鸿蒙的解法是让播放器根本不接触密文。
    final decryptParam = request.uri.queryParameters['decrypt'];
    final keyParam = request.uri.queryParameters['key'];
    final ivParam = request.uri.queryParameters['iv'];
    if (decryptParam == 'aes128' && keyParam != null && ivParam != null) {
      await _proxyDecryptedSegment(
        request,
        isHead: isHead,
        targetUrl: targetUrl,
        keyUri: Uri.decodeComponent(keyParam),
        iv: _hexToBytes(Uri.decodeComponent(ivParam)),
      );
      return;
    }

    // 透传调用方设置的所有请求头（含鉴权 token / Cookie / 自定义头），
    // 确保分片请求与播放列表请求使用一致的头部。否则部分 CDN 在分片阶段
    // 因缺头被拒，表现为“出一下声音后无画面、卡死”（首段常已被放行/缓存）。
    final headers = Map<String, String>.from(_baseHeaders);
    headers['User-Agent'] = _baseHeaders['User-Agent'] ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
    headers['Accept'] = '*/*';
    headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    headers['Connection'] = 'keep-alive';

    // 优先使用传入的 Referer/Origin；否则根据目标 URL 自动推导
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

    // 透传 Range，但 M3U8 播放列表必须获取完整内容才能正确计算总时长，
    // 否则播放器收到 206 部分响应会导致进度条/时长显示异常。
    final isM3u8Url =
        targetUrl.toLowerCase().contains('.m3u8') ||
        targetUrl.toLowerCase().contains('/hls/');
    final range = request.headers.value('range');
    if (range != null && range.isNotEmpty && !isM3u8Url) {
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
          final rewritten = rewriteToLocalProxy(resolved, baseUrl!);
          // 🔴 2026-10-29：变体（子）播放列表才是真正的分片表 ——
          //   master 场景下顶层列表只有变体行，起播预热必须等这里展开。
          _collectSegmentUrls(rewritten);
          out.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          final encoded = utf8.encode(rewritten);
          out.headers.set('Content-Length', encoded.length.toString());
          out.add(encoded);
          _log(
            'proxySegment sub-m3u8 rewritten: $targetUrl\n${_summarizeContent(rewritten)}',
          );
        } else if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
          // 🔴🔴 2026-10-12：媒体分片——由「纯流式转发」改为「缓冲后按需平移 PTS」。
          //
          // 【为什么必须缓冲】PTS 写在 TS 包内，改字节就必须先拿全整段。
          //   这是历史 `out.addStream(streamed.stream)` 无法做归一化的结构性原因。
          //
          // 【代价与守门】每段要在内存里收完才能发（约 2s / 1–2MB）。
          //   因此只对**真的是 TS** 的分片做缓冲；其余（裸流、图片、未知格式）
          //   一律保持原流式转发，避免无谓的内存与延迟开销。
          //
          // 【失败回退】任何一步判定不成立都退回原始字节转发，
          //   宁可进度偏，也绝不给出损坏的分片。
          final isTsCandidate = _looksLikeTsSegment(targetUrl);
          if (isTsCandidate && _ptsNormalize && _segMeta.isNotEmpty) {
            final body = await streamed.stream.toBytes();
            final delta = await _deltaFor(targetUrl, body);
            final payload = delta == 0
                ? body
                : _applyPtsShift(targetUrl, body, delta);
            out.headers.set('Content-Length', payload.length.toString());
            if (delta != 0) {
              out.headers.set('X-Pts-Shift', delta.toString());
            }
            out.add(payload);
            await out.close();
            return;
          }
          // 非 TS 或未启用归一化：保持流式转发（历史行为）。
          final len = streamed.contentLength;
          if (len != null) out.headers.set('Content-Length', len.toString());
          _log('proxySegment stream: $targetUrl status=${streamed.statusCode}');
          await out.addStream(streamed.stream);
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
          ..write('Proxy error')
          ..close();
      } catch (_) {}
    }
  }

  /// 🔴 判断分片是否**可能**是 MPEG-TS（需要缓冲并平移 PTS）。
  ///
  /// 只做保守的**保守判定**：仅当 URL 明确指向 TS 时返回 true。不确定一律
  /// 返回 false，保持流式转发——如此即便判错也只是「不平移」（退化为历史行为），
  /// 不会引入新故障。
  static bool _looksLikeTsSegment(String url) {
    final u = url.toLowerCase();
    // 剥离 query，避免 `?a=.mp4` 这类干扰后缀判定。
    final path = u.split('?').first;
    return path.endsWith('.ts') ||
        path.endsWith('.m2ts') ||
        path.endsWith('.mts') ||
        path.contains('/ts/');
  }

  static bool _isM3u8ContentType(String? contentType) {
    if (contentType == null) return false;
    final ct = contentType.toLowerCase();
    return ct.contains('mpegurl') ||
        ct.contains('m3u8') ||
        ct.contains('application/vnd.apple.mpegurl') ||
        ct.contains('audio/x-mpegurl');
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
  /// 🔴🔴 2026-10-12 移植鸿蒙方案（第二轮，这次是**完整**移植）：
  ///
  /// 【上一轮为什么失败】我上一轮只做了「代理侧解密读 PTS」，却仍把**密文**
  ///   原样转发给 mpv，期望 mpv 自己解密。但 PTS 写在密文里，代理改不了；
  ///   而在密文上改字节会破坏密文。实测日志 50/50 全是
  ///   `reason=no-pts-before before=nullms`（在密文上读 PTS 恒 null）
  ///   ⇒ **一次平移都没做成，密文原封不动发出**。
  ///
  /// 【鸿蒙的正确做法】由**代理把密文解开**，在**明文**上归一化 PTS，
  ///   然后把**明文**吐给播放器（播放器不再自己解密，EXT-X-KEY 被剥离）。
  ///   这样「改字节」才有意义 —— 鸿蒙真机验证 residual 全 0、seek 差额全 0。
  ///
  /// 【实现】解析到 `#EXT-X-KEY:METHOD=AES-128` 时**剥离该标签**，把 key URI
  ///   与 IV 记入上下文，逐个分片 URL 注入
  ///   `&decrypt=aes128&key=<keyUri>&iv=<ivHex>`；
  ///   代理侧 `_proxySegment` 见到该参数就走 `_proxyDecryptedSegment`。
  ///
  /// 【IV 规则】`#EXT-X-KEY` 未给 IV 时，规范默认 IV = 媒体序列号（低 8 字节
  ///   大端）。本源实测显式给了 `IV=0x0000...`，走显式分支。
  static String rewriteToLocalProxy(String content, String proxyBaseUrl) {
    final lines = content.split('\n');
    final result = <String>[];

    // AES-128 解密上下文（随 `#EXT-X-KEY` 行更新，作用于其后所有分片）
    String? activeAesKeyUri;
    Uint8List? activeAesIv;
    var mediaSequence = 0;
    var segEmitIndex = 0;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      // 媒体序列号（无 IV 属性时的默认 IV 来源）
      if (trimmed.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final m = RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(trimmed);
        if (m != null) mediaSequence = int.parse(m.group(1)!);
        result.add(raw);
        continue;
      }

      // 🔴 AES-128：剥离标签 + 记录上下文（见方法注释）
      if (trimmed.startsWith('#EXT-X-KEY')) {
        final methodMatch = RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(trimmed);
        final method = methodMatch?.group(1);
        if (method == 'AES-128') {
          activeAesKeyUri =
              RegExp(r'URI="([^"]+)"').firstMatch(trimmed)?.group(1);
          final ivMatch = RegExp(r'IV=0x([0-9A-Fa-f]+)').firstMatch(trimmed);
          activeAesIv = ivMatch != null ? _hexToBytes(ivMatch.group(1)!) : null;
          continue; // 剥离：播放器不再需要拉 key（代理已解密）
        } else if (method == 'NONE') {
          activeAesKeyUri = null;
          activeAesIv = null;
          continue; // 无加密，剥离
        }
        // 其他方法（SAMPLE-AES 等）不支持：保留标签并改写 URI（原行为）
        result.add(_rewriteUriAttributes(proxyBaseUrl, raw));
        continue;
      }

      // 媒体行
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          !trimmed.startsWith('data:')) {
        var proxySeg = _proxyUrl(proxyBaseUrl, trimmed);
        // 当前分片处于 AES-128 加密区间 → 注入解密参数
        if (activeAesKeyUri != null) {
          final ivHex = activeAesIv != null
              ? _bytesToHex(activeAesIv)
              : _bytesToHex(_ivFromSeq(mediaSequence + segEmitIndex));
          proxySeg +=
              '&decrypt=aes128&key=${Uri.encodeComponent(activeAesKeyUri)}&iv=$ivHex';
          segEmitIndex++;
        }
        result.add(proxySeg);
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

  /// 十六进制串 → 字节。奇数长度按左补 0 处理（宽容但不会越界）。
  static Uint8List _hexToBytes(String hex) {
    final h = hex.length.isOdd ? '0$hex' : hex;
    final out = Uint8List(h.length ~/ 2);
    for (var i = 0; i < out.length; i++) {
      final v = int.tryParse(h.substring(i * 2, i * 2 + 2), radix: 16);
      if (v == null) {
        throw FormatException('非法十六进制: $hex');
      }
      out[i] = v;
    }
    return out;
  }

  /// 字节 → 小写十六进制串。
  static String _bytesToHex(Uint8List bytes) {
    final sb = StringBuffer();
    for (final b in bytes) {
      sb.write(b.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// HLS 规范默认 IV：`#EXT-X-KEY` 未给 IV 时，取媒体序列号的低 8 字节大端。
  static Uint8List _ivFromSeq(int seq) {
    final iv = Uint8List(16);
    for (var i = 0; i < 8; i++) {
      iv[15 - i] = (seq >> (8 * i)) & 0xFF;
    }
    return iv;
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
      // 🔴🔴 2026-10-12：子 M3U8 也必须在过滤出口取回元数据并装入实例。
      //
      // 【根因】顶层的 master playlist 只有 EXT-X-STREAM-INF、没有任何
      //   #EXTINF 分段（真机实测仅 118 字节 / 0 段），真正的分段列表在
      //   子 M3U8 里（真机实测 68 段）。若只在顶层取一次元数据，子列表的
      //   分段元数据会被产出后**丢弃**，代理侧 `_segMeta` 恒为空
      //   ⇒ 分片查表全部 miss ⇒ PTS 修复**静默失效**。
      //   真机日志表现为：`PTS 元数据 0 段（空，PTS 归一化将不生效）`，
      //   且全程无任何 `PTS axis:` 行。
      //
      // 【为何是 takeSegMeta】它会取走并清空静态表，避免跨播放列表串味。
      final meta = M3u8AdFilter.takeSegMeta();
      final keyUri = M3u8AdFilter.takeAesKeyUri();
      if (meta.isNotEmpty) {
        _instance?._installSegMetaFromSubList(meta, aesKeyUri: keyUri);
      }
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
}
