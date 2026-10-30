/// HLS 预取窗口判定（纯 Dart，无依赖，可离线逐例验证）。
///
/// ## 为什么需要它
///
/// 真机 hilog 2026-10-24 09:48 实证（`hain_tv_ohos`）：
///
/// ```
/// avp 会话：播放器分片请求 44 次、预取缓存命中 0 次（命中率 0%）
/// mpv 会话：播放器分片请求 43 次、预取缓存命中 10 次（命中率 23%）
/// 同期预取分别完成 45 / 47 段 —— 预取在跑，却从没赶上播放器要的那一段
/// ```
///
/// 两个根因：
///
/// 1. **预取只在「回源直连」分支末尾推进**；缓存命中时直接 `return`，
///    ⇒ 预取只能靠**缓存未命中**来推进（鸡生蛋），提前量恒为 0。
/// 2. **预取队列是严格串行的**，而单段下载要等 CDN 首字节 0.8~2s + 传输 ~1s
///    （容器内 curl 实测 8 段并发 ttfb 0.76~1.32s ⇒ CDN 扛得住并发），
///    ⇒ 串行预取交付速率 ≈ 1 段/1~2s，贴着「1 段/2s」的消费速率跑。
///
/// 本模块负责**位置跳变后队列该保留什么**（seek 感知）与
/// **按时间定位目标分片**（seek/起播定位预热）。
///
/// ## 判定规则
///
/// 播放头下标 = `currentIndex`，预取深度 = `depth`。
/// 队列项下标 `itemIndex` 的保留条件：
///
/// ```
/// currentIndex < itemIndex <= currentIndex + depth
/// ```
///
/// - `itemIndex <= currentIndex`：seek **之前**的旧位置分片，再也用不到；
/// - `itemIndex > currentIndex + depth`：位置**向后**跳变时留下的远端分片，
///   会把新位置的预取堵在队尾。
///
/// ## 第七轮扩展：双锚点窗口（seek 预热）
///
/// 真机 hilog 2026-10-24 10:08 实证：
///
/// ```
/// 18:07:00.621 MpvBackend open: ... startAt=0:23:30.767000   ← 起播定位到 1410.767s
/// 18:07:00.631 续播定位闸门开启: 首帧已出 position=1410767ms
/// 18:07:03.628 [mpv-seek] 看门狗触发：3s 内未收到 playback-restart
/// 18:07:03.629 seek 收敛: **超时**
/// 18:07:05.216 [mpv-event] seek      ← 4.6s 后 mpv 才真正开始 seek
/// 18:07:07.498 seek 落点核对: 请求=1410.767s 落点=1410.767s ✅
/// ```
///
/// ⇒ **open 到落点整整 6.9 秒**。原因是代理此刻正预取**下标 0 附近**的分片
/// （播放头还在 0），目标下标 ~700 的分片一个都没缓存，
/// mpv 只能现等 CDN 往返。
///
/// avplayer 侧同病：
///
/// ```
/// 18:06:09.961 [SEEK-DIAG] seek target=1364790ms
/// 18:06:10.335 buffering=true … 18:06:12.735 buffering=true   ← 冻结 3.6 秒
/// 18:06:13.936 buffering=false
/// ```
///
/// ⇒ 修法：seek / 起播定位**之前**，先把预取窗口**预热到目标位置**
/// （`_prefetchTargetIndex`）。此时播放头还在旧位置，
/// 因此窗口必须同时容纳**两个锚点**：旧播放头与新目标。
library;

/// 预取窗口的起始下标（含）。播放头之后的第一个分片。
int prefetchWindowStart(int currentIndex) => currentIndex + 1;

/// 预取窗口的结束下标（含）。= 播放头 + 深度。
int prefetchWindowEnd(int currentIndex, int depth) => currentIndex + depth;

/// 队列项是否应保留在预取窗口内。
///
/// - [itemIndex] 为 null 表示该分片**不在当前分片表里**（源已切换）⇒ 丢弃；
/// - [depth] 必须 ≥ 1。
///
/// ## 窗口 = 两个区间的**并集**（不是一个大区间）
///
/// ```
/// 播放头区间：(currentIndex, currentIndex + depth]     ← 不含播放头自身
/// 目标区间： [targetIndex,  targetIndex  + depth]      ← **含目标自身**
/// ```
///
/// 为什么要含目标自身：seek 的落点**正是**目标分片，
/// 而它此刻还躺在 CDN 上（这正是「起播定位 6.9 秒」的根因）。
/// 若按「区间并集 = [min, max+depth]」去写，目标段恰好落在下界、
/// 会被当旧位置丢掉 ⇒ 预热白做。
///
/// 也不要写成一个大区间：那样「目标窗口」与「旧播放头窗口」之间的
/// 缝隙会被误保留（如 playhead=745 / target=672 时 700 号段会被留下，
/// 而它既不在新位置、也不在旧位置）。
bool keepPrefetchItem({
  required int? itemIndex,
  required int currentIndex,
  required int depth,
  int? targetIndex,
}) {
  if (itemIndex == null) return false;
  if (depth < 1) return false;
  // 播放头区间：不含播放头自身（它正在被播放器取走）。
  if (itemIndex > currentIndex &&
      itemIndex <= prefetchWindowEnd(currentIndex, depth)) {
    return true;
  }
  // 目标区间：含目标自身（seek 落点正是它）。
  if (targetIndex != null &&
      itemIndex >= targetIndex &&
      itemIndex <= targetIndex + depth) {
    return true;
  }
  return false;
}

/// 依据播放头与深度，算出应当入队的分片下标区间（含首含尾）。
///
/// 返回可直接用于 `for (var i = start; i <= end; i++)` 的半开区间。
///
/// [total] 为分片总数；越界会被裁掉。
List<int> prefetchIndices({
  required int currentIndex,
  required int depth,
  required int total,
}) {
  if (total <= 0 || depth <= 0) return const [];
  final start = prefetchWindowStart(currentIndex);
  final end = prefetchWindowEnd(currentIndex, depth);
  final lo = start < 0 ? 0 : start;
  final hi = end >= total ? total - 1 : end;
  if (lo > hi) return const [];
  return List<int>.generate(hi - lo + 1, (i) => lo + i);
}

// ── 第七轮：双锚点窗口 ─────────────────────────────────────────────────────

/// 按播放头 + 预热目标，算出应当入队的分片下标集合（去重、升序、已裁剪）。
///
/// - 播放头窗口：`(currentIndex, currentIndex + depth]`
///   —— 播放头**自身**那一段正在被播放器取走，不重复入队；
/// - 预热目标窗口：`[targetIndex, targetIndex + depth]`
///   —— 目标**自身**那一段也要预取：seek 落点正是它，
///   而它此刻还躺在 CDN 上（这正是 6.9 秒起播停顿的根因）。
///
/// [total] 为分片总数；越界会被裁掉。
List<int> prefetchIndicesWithTarget({
  required int currentIndex,
  required int depth,
  required int total,
  int? targetIndex,
}) {
  if (total <= 0 || depth <= 0) return const [];
  final out = <int>{};

  void add(int lo, int hi) {
    final a = lo < 0 ? 0 : lo;
    final b = hi >= total ? total - 1 : hi;
    for (var i = a; i <= b; i++) {
      out.add(i);
    }
  }

  add(prefetchWindowStart(currentIndex), prefetchWindowEnd(currentIndex, depth));
  if (targetIndex != null) {
    add(targetIndex, targetIndex + depth);
  }
  final list = out.toList()..sort();
  return list;
}

/// 按播放位置（毫秒）在**名义轴**上定位分片下标。
///
/// [segmentStartMs] 是每个分片在名义轴（EXTINF 累加轴）上的起点，
/// 升序、长度与分片表一致。
///
/// 返回值：
/// - 目标落在某段内 → 该段下标；
/// - 目标早于第一段 → 0；
/// - 目标晚于最后一段 → 最后一段下标；
/// - 列表为空 → -1。
///
/// 二分查找，O(log n)。
int indexForPosition(List<int> segmentStartMs, int positionMs) {
  if (segmentStartMs.isEmpty) return -1;
  if (positionMs <= segmentStartMs.first) return 0;
  if (positionMs >= segmentStartMs.last) return segmentStartMs.length - 1;
  var lo = 0;
  var hi = segmentStartMs.length - 1;
  while (lo <= hi) {
    final mid = (lo + hi) >> 1;
    final v = segmentStartMs[mid];
    if (v == positionMs) return mid;
    if (v < positionMs) {
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  // lo 是第一个 > positionMs 的下标 ⇒ 目标落在 lo-1 段内
  return lo - 1 < 0 ? 0 : lo - 1;
}
