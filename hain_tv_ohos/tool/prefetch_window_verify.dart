// 预取窗口判据的离线逐例验证（不依赖网络 / 设备）。
//
// 关联真机证据：
//   hilog 2026-10-24 09:48 —— 预取命中率 0%，预取永远慢一拍
//   hilog 2026-10-24 10:08 —— mpv 起播定位 6.9 秒、avp seek 后冻结 3.6 秒
//                              （落点区域的分片没被预取到）
//
// 运行：dart tool/prefetch_window_verify.dart
import '../lib/services/hls_prefetch_window.dart';

int _passed = 0;
int _failed = 0;

void check(String name, bool ok) {
  if (ok) {
    _passed++;
    print('✅ $name');
  } else {
    _failed++;
    print('❌ $name');
  }
}

void main() {
  const depth = 6;

  // ── 第六轮：单锚点窗口（顺序播放 / seek 感知） ──
  check(
    '顺序播放：下一段保留',
    keepPrefetchItem(itemIndex: 101, currentIndex: 100, depth: depth),
  );
  check(
    '顺序播放：窗口末端保留',
    keepPrefetchItem(itemIndex: 106, currentIndex: 100, depth: depth),
  );
  check(
    '顺序播放：窗口外（更远）丢弃',
    !keepPrefetchItem(itemIndex: 107, currentIndex: 100, depth: depth),
  );
  check(
    '快进：旧位置（更小下标）丢弃',
    !keepPrefetchItem(itemIndex: 600, currentIndex: 700, depth: depth),
  );
  check(
    '快进：播放头自身丢弃',
    !keepPrefetchItem(itemIndex: 700, currentIndex: 700, depth: depth),
  );
  check(
    '快进：新位置下一段保留',
    keepPrefetchItem(itemIndex: 701, currentIndex: 700, depth: depth),
  );
  check(
    '快退：远端旧项丢弃',
    !keepPrefetchItem(itemIndex: 900, currentIndex: 700, depth: depth),
  );
  check(
    '不在分片表 ⇒ 丢弃',
    !keepPrefetchItem(itemIndex: null, currentIndex: 700, depth: depth),
  );
  check(
    'depth=0 ⇒ 不保留',
    !keepPrefetchItem(itemIndex: 701, currentIndex: 700, depth: 0),
  );

  // ── 第六轮：入队区间 ──
  final idxs = prefetchIndices(currentIndex: 100, depth: depth, total: 1328);
  check('入队区间长度=深度', idxs.length == depth);
  check('入队区间起点=播放头+1', idxs.first == 101);
  check('入队区间终点=播放头+深度', idxs.last == 106);

  final clipped = prefetchIndices(currentIndex: 1325, depth: depth, total: 1328);
  check('入队区间按总数裁剪（末尾只剩 2 段）',
      clipped.length == 2 && clipped.last == 1327 && clipped.first == 1326);

  final exact = prefetchIndices(currentIndex: 1320, depth: depth, total: 1328);
  check('未越界时不裁剪', exact.length == depth && exact.last == 1326);

  check('分片总数为 0 ⇒ 空区间',
      prefetchIndices(currentIndex: 0, depth: depth, total: 0).isEmpty);

  // ── 第七轮：双锚点窗口（seek 预热） ──
  //
  // 场景：播放头还在 745（旧位置），预热目标 672（seek 落点）。
  // 此刻播放器请求的仍是旧位置分片 ⇒ 若只按播放头判窗，
  // 刚预热好的目标段 672 会被当成「旧位置」丢掉 ⇒ 预热白做。
  check(
    '双锚点：目标段本身在预热后被保留（否则预热白做）',
    keepPrefetchItem(
      itemIndex: 672,
      currentIndex: 745,
      depth: depth,
      targetIndex: 672,
    ),
  );
  check(
    '双锚点：旧播放头窗口仍在保留（seek 还没生效）',
    keepPrefetchItem(
      itemIndex: 746,
      currentIndex: 745,
      depth: depth,
      targetIndex: 672,
    ),
  );
  check(
    '双锚点：目标窗口末端保留',
    keepPrefetchItem(
      itemIndex: 678,
      currentIndex: 745,
      depth: depth,
      targetIndex: 672,
    ),
  );
  check(
    '双锚点：两端都够不着的项丢弃',
    !keepPrefetchItem(
      itemIndex: 700,
      currentIndex: 745,
      depth: depth,
      targetIndex: 672,
    ),
  );
  check(
    '双锚点：目标之前很远的项丢弃',
    !keepPrefetchItem(
      itemIndex: 100,
      currentIndex: 745,
      depth: depth,
      targetIndex: 672,
    ),
  );
  check(
    '双锚点：seek 生效后（播放头==目标）行为退化为单锚点',
    keepPrefetchItem(
          itemIndex: 673,
          currentIndex: 672,
          depth: depth,
          targetIndex: 672,
        ) &&
        !keepPrefetchItem(
          itemIndex: 671,
          currentIndex: 672,
          depth: depth,
          targetIndex: 672,
        ),
  );

  // ── 第七轮：入队集合（双锚点） ──
  final withTarget = prefetchIndicesWithTarget(
    currentIndex: 745,
    depth: depth,
    total: 1328,
    targetIndex: 672,
  );
  check('双锚点入队：含目标段自身', withTarget.contains(672));
  check('双锚点入队：含目标段后续', withTarget.contains(678));
  check('双锚点入队：含播放头后续', withTarget.contains(746));
  final sortedUnique = withTarget.toSet().toList()..sort();
  check('双锚点入队：升序且去重', withTarget.join(',') == sortedUnique.join(','));
  // 播放头窗口 6 段（746..751）+ 目标窗口 7 段（672..678，含目标自身）
  check('双锚点入队：总数=6+7=13', withTarget.length == 13);

  final noTarget = prefetchIndicesWithTarget(
    currentIndex: 100,
    depth: depth,
    total: 1328,
  );
  check('无目标时退化为单锚点入队', noTarget.length == depth && noTarget.first == 101);

  // ── 第七轮：按时间定位分片下标 ──
  // 构造 10 段、每段 2 秒的名义轴（起点 0,2000,...,18000）
  final starts = List<int>.generate(10, (i) => i * 2000);
  check('时间定位：落在某段内', indexForPosition(starts, 5000) == 2);
  check('时间定位：段首命中该段', indexForPosition(starts, 4000) == 2);
  check('时间定位：早于第一段 ⇒ 0', indexForPosition(starts, -100) == 0);
  check('时间定位：等于第一段起点 ⇒ 0', indexForPosition(starts, 0) == 0);
  check('时间定位：晚于最后一段 ⇒ 末段',
      indexForPosition(starts, 999999) == 9);
  check('时间定位：空表 ⇒ -1', indexForPosition(const [], 1000) == -1);

  // 不等长（段长不等）也要正确
  final uneven = [0, 3000, 5000, 9000, 12000];
  check('时间定位：不等长段落在正确段',
      indexForPosition(uneven, 6000) == 2 &&
          indexForPosition(uneven, 10000) == 3 &&
          indexForPosition(uneven, 2999) == 0);

  // 二分查找与线性查找结果一致（随机校验）
  var consistent = true;
  final rnd = List<int>.generate(50, (i) => i * 137 % 20000);
  for (final p in rnd) {
    var expect = 0;
    for (var i = 0; i < starts.length; i++) {
      if (starts[i] <= p) expect = i;
    }
    if (indexForPosition(starts, p) != expect) {
      consistent = false;
      break;
    }
  }
  check('时间定位：二分与线性结果一致（50 例）', consistent);

  print('\n$_passed 通过 / $_failed 失败');
  if (_failed > 0) {
    throw StateError('预取窗口判据存在失败用例');
  }
  print('✅ 全部通过：预取窗口判据正确。');
}
