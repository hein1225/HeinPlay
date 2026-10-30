import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;

import '../models/api_response.dart';
import '../models/douban_movie.dart';
import '../models/search_result.dart';
import '../models/source_option.dart';
import 'douban_service.dart';
import 'local_storage_service.dart';
import 'lunatv_service.dart';
import 'm3u8_utils.dart';
import 'playback_activity.dart';

class SearchService {
  static const double _similarityThreshold = 0.6;

  /// 搜索结果高相关性阈值（完全/开头/包含匹配）。
  static const double _highRelevanceThreshold = 60.0;

  /// 搜索结果中等相关性阈值（普通模糊匹配）。
  static const double _mediumRelevanceThreshold = 40.0;

  /// 手动模糊搜索阈值，比自动过滤更宽松，允许部分字符顺序匹配命中。
  static const double _fuzzyRelevanceThreshold = 25.0;

  static const Map<String, String> _chineseToArabic = {
    '一': '1',
    '二': '2',
    '三': '3',
    '四': '4',
    '五': '5',
    '六': '6',
    '七': '7',
    '八': '8',
    '九': '9',
    '十': '10',
  };
  static const List<String> _arabicToChinese = [
    '',
    '一',
    '二',
    '三',
    '四',
    '五',
    '六',
    '七',
    '八',
    '九',
    '十',
  ];

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s\u4e00-\u9fff]+'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
  }

  static double _titleSimilarity(String a, String b) {
    final na = _normalize(a);
    final nb = _normalize(b);
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;

    final lcsLength = _lcsLength(na, nb);
    return (2 * lcsLength) / (na.length + nb.length);
  }

  /// 计算 Levenshtein 编辑距离。
  static int _levenshteinDistance(String str1, String str2) {
    final len1 = str1.length;
    final len2 = str2.length;
    if (len1 == 0) return len2;
    if (len2 == 0) return len1;

    final matrix = List.generate(
      len1 + 1,
      (_) => List<int>.filled(len2 + 1, 0),
    );

    for (var i = 0; i <= len1; i++) {
      matrix[i][0] = i;
    }
    for (var j = 0; j <= len2; j++) {
      matrix[0][j] = j;
    }

    for (var i = 1; i <= len1; i++) {
      for (var j = 1; j <= len2; j++) {
        final cost = str1[i - 1] == str2[j - 1] ? 0 : 1;
        final deletion = matrix[i - 1][j] + 1;
        final insertion = matrix[i][j - 1] + 1;
        final substitution = matrix[i - 1][j - 1] + cost;
        matrix[i][j] = deletion < insertion
            ? (deletion < substitution ? deletion : substitution)
            : (insertion < substitution ? insertion : substitution);
      }
    }

    return matrix[len1][len2];
  }

  /// 计算标题与关键词的相似度百分比（0-1）。
  static double _similarityScore(String str1, String str2) {
    final distance = _levenshteinDistance(str1, str2);
    final maxLen = str1.length > str2.length ? str1.length : str2.length;
    return maxLen == 0 ? 1.0 : 1.0 - distance / maxLen;
  }

  /// 检查标题是否包含关键词的所有字符（按顺序，允许间隔）。
  static bool _containsCharsInOrder(String title, String keyword) {
    var keywordIndex = 0;
    for (var i = 0; i < title.length && keywordIndex < keyword.length; i++) {
      if (title[i] == keyword[keywordIndex]) {
        keywordIndex++;
      }
    }
    return keywordIndex == keyword.length;
  }

  /// 计算搜索结果基础相关性分数（0-100），不包含年份/豆瓣等加分。
  /// 完全匹配 100 分，开头匹配 80 分，包含匹配 60 分，模糊匹配 0-40 分。
  static double _calculateBaseRelevanceScore(
    SearchResult result,
    String query,
  ) {
    final title = (result.title).trim().toLowerCase();
    final keyword = query.trim().toLowerCase();

    if (title.isEmpty || keyword.isEmpty) return 0;

    final titleNoSpace = title.replaceAll(RegExp(r'\s+'), '');
    final keywordNoSpace = keyword.replaceAll(RegExp(r'\s+'), '');

    if (title == keyword || titleNoSpace == keywordNoSpace) {
      return 100;
    }
    if (title.startsWith(keyword) || titleNoSpace.startsWith(keywordNoSpace)) {
      return 80;
    }
    if (title.contains(keyword) || titleNoSpace.contains(keywordNoSpace)) {
      return 60;
    }
    if (_containsCharsInOrder(titleNoSpace, keywordNoSpace)) {
      final similarity = _similarityScore(titleNoSpace, keywordNoSpace);
      return 20 + similarity * 20; // 20-40 分
    }

    final matchedChars = keywordNoSpace
        .split('')
        .where((char) => titleNoSpace.contains(char))
        .length;
    final matchRatio = keywordNoSpace.isEmpty
        ? 0.0
        : matchedChars / keywordNoSpace.length;
    // LunaTV 式兜底：查询字符在结果中出现比例 >= 50% 视为相关命中
    if (matchRatio >= 0.5) {
      return 40 + matchRatio * 20; // 50-60 分
    }
    return matchRatio * 15; // 0-15 分
  }

  /// 计算搜索结果总相关性分数（基础分 + 年份/豆瓣加分）。
  static double _calculateRelevanceScore(SearchResult result, String query) {
    var score = _calculateBaseRelevanceScore(result, query);

    // 年份加分：越新的作品加分越多，最多 +10
    final year = int.tryParse(result.year) ?? 0;
    if (year > 0) {
      final currentYear = DateTime.now().year;
      final yearDiff = currentYear - year;
      if (yearDiff >= 0) {
        if (yearDiff <= 5) {
          score += 10 - yearDiff;
        } else if (yearDiff <= 10) {
          score += 5;
        } else if (yearDiff <= 20) {
          score += 2;
        }
      }
    }

    // 豆瓣信息加分
    if (result.doubanId != null && result.doubanId! > 0) {
      score += 5;
    }

    return score > 110 ? 110 : score;
  }

  /// 判断 [title] 是否与 [query] 或任意 [variants] 精确匹配。
  static bool isExactTitleMatch(
    String title,
    String query, {
    List<String>? variants,
  }) {
    final queries = [query, ...(variants ?? [])];
    return queries.any(
      (q) =>
          _calculateBaseRelevanceScore(
            SearchResult(
              id: '',
              title: title,
              poster: '',
              episodes: [],
              episodesTitles: [],
              source: '',
              sourceName: '',
              year: '',
            ),
            q,
          ) >=
          100,
    );
  }

  /// 根据相关性过滤并排序搜索结果。
  /// - [exactMatch] 为 true 时，仅保留标题与查询（或变体）完全匹配的结果（基础分 100）。
  /// - [exactMatch] 为 false 时，优先保留完全/开头/包含匹配（>=60）。
  /// - [fuzzy] 为 true 时，无高相关结果则进一步降级到 [_fuzzyRelevanceThreshold]，
  ///   用于手动模糊搜索场景，允许字符顺序匹配等较低相关度结果命中。
  static List<SearchResult> _filterByRelevance(
    List<SearchResult> results,
    String query, {
    List<String>? variants,
    bool exactMatch = false,
    bool fuzzy = false,
  }) {
    final queries = [query, ...(variants ?? [])];
    final scored = results.map((result) {
      double bestBase = 0;
      double bestTotal = 0;
      for (final q in queries) {
        final base = _calculateBaseRelevanceScore(result, q);
        final total = _calculateRelevanceScore(result, q);
        if (base > bestBase) bestBase = base;
        if (total > bestTotal) bestTotal = total;
      }
      return _ScoredResult(result, bestBase, bestTotal);
    }).toList();

    List<_ScoredResult> filtered;
    if (exactMatch) {
      // 严格精确匹配：标题必须等于查询或某个变体
      filtered = scored.where((item) => item.baseScore >= 100).toList();
    } else {
      // 优先严格匹配（完全/开头/包含）
      filtered = scored
          .where((item) => item.baseScore >= _highRelevanceThreshold)
          .toList();
      // 降级到模糊匹配
      if (filtered.isEmpty) {
        filtered = scored
            .where(
              (item) =>
                  item.baseScore >=
                  (fuzzy
                      ? _fuzzyRelevanceThreshold
                      : _mediumRelevanceThreshold),
            )
            .toList();
      }
    }

    if (filtered.isEmpty && results.isNotEmpty) {
      final topSamples = scored
        ..sort((a, b) => b.baseScore.compareTo(a.baseScore));
      debugPrint(
        '[SourceSearch] 过滤后无结果，原始数=${results.length}, '
        'query=$query, variants=$variants, exactMatch=$exactMatch, fuzzy=$fuzzy, '
        'TOP5=${topSamples.take(5).map((s) => "${s.result.title}(${s.baseScore.toStringAsFixed(1)})")}',
      );
    }

    filtered.sort((a, b) {
      if (b.totalScore != a.totalScore) {
        return b.totalScore.compareTo(a.totalScore);
      }
      final yearA = int.tryParse(a.result.year) ?? 0;
      final yearB = int.tryParse(b.result.year) ?? 0;
      if (yearB != yearA) {
        return yearB.compareTo(yearA);
      }
      return a.result.title.compareTo(b.result.title);
    });

    return filtered.map((item) => item.result).toList();
  }

  static int _lcsLength(String a, String b) {
    final m = a.length;
    final n = b.length;
    if (m == 0 || n == 0) return 0;

    var previous = List<int>.filled(n + 1, 0);
    var current = List<int>.filled(n + 1, 0);

    for (var i = 1; i <= m; i++) {
      for (var j = 1; j <= n; j++) {
        if (a[i - 1] == b[j - 1]) {
          current[j] = previous[j - 1] + 1;
        } else {
          current[j] = current[j - 1] > previous[j]
              ? current[j - 1]
              : previous[j];
        }
      }
      final temp = previous;
      previous = current;
      current = temp;
    }

    return previous[n];
  }

  /// 智能生成数字变体。
  /// - "极速车魂第3季" -> "极速车魂第三季"
  /// - "中国奇谭第二季" -> "中国奇谭2"
  static String? _generateNumberVariant(String query) {
    // 模式1: "第X季/部/集/期" 格式（中文数字 -> 阿拉伯数字）
    final chinesePattern = RegExp(r'第([一二三四五六七八九十])(季|部|集|期)');
    final chineseMatch = chinesePattern.firstMatch(query);
    if (chineseMatch != null) {
      final chineseNum = chineseMatch.group(1)!;
      final arabicNum = _chineseToArabic[chineseNum];
      if (arabicNum != null) {
        final base = query.replaceFirst(chineseMatch.group(0)!, '').trim();
        if (base.isNotEmpty) return '$base$arabicNum';
      }
    }

    // 模式2: "第X季/部/集/期" 格式（阿拉伯数字 -> 中文数字）
    final arabicPattern = RegExp(r'第(\d+)(季|部|集|期)');
    final arabicMatch = arabicPattern.firstMatch(query);
    if (arabicMatch != null) {
      final num = int.tryParse(arabicMatch.group(1)!);
      final suffix = arabicMatch.group(2)!;
      if (num != null && num >= 1 && num <= 10) {
        final chineseNum = _arabicToChinese[num];
        return query.replaceFirst(
          arabicMatch.group(0)!,
          '第${chineseNum}$suffix',
        );
      }
    }

    // 模式3: 末尾纯数字（如 "中国奇谭2" -> "中国奇谭第二季"）
    final endNumberMatch = RegExp(r'^(.+?)(\d+)$').firstMatch(query);
    if (endNumberMatch != null) {
      final base = endNumberMatch.group(1)!.trim();
      final num = int.tryParse(endNumberMatch.group(2)!);
      if (num != null && num >= 1 && num <= 10 && base.isNotEmpty) {
        final chineseNum = _arabicToChinese[num];
        return '${base}第${chineseNum}季';
      }
    }

    return null;
  }

  /// 智能生成搜索变体。
  /// 为减少 API 调用并加快搜索速度，仅保留原始查询和数字变体（如"第二季"→"第2季"）。
  static List<String> generateSearchVariants(
    String originalQuery, {
    bool fuzzy = false,
  }) {
    final trimmed = originalQuery.trim();
    if (trimmed.isEmpty) return [trimmed];

    final variants = <String>[trimmed];

    // 仅保留数字变体，减少并发 API 调用
    final numberVariant = _generateNumberVariant(trimmed);
    if (numberVariant != null && numberVariant != trimmed) {
      variants.add(numberVariant);
    }

    // 对于带中文标点/空格的标题，生成去标点变体，提升源标题与查询不完全一致时的命中率。
    final punctuationVariant = _generatePunctuationVariant(trimmed);
    if (punctuationVariant != null &&
        punctuationVariant != trimmed &&
        !variants.contains(punctuationVariant)) {
      variants.add(punctuationVariant);
    }

    return variants;
  }

  /// 移除常见中文/英文标点并压缩空格，用于匹配源站标题格式差异。
  static String? _generatePunctuationVariant(String query) {
    final withoutPunctuation = query
        .replaceAll(
          RegExp(r'[\u3000\uFF01-\uFF0F\uFF1A-\uFF20\uFF3B-\uFF40\uFF5B-\uFF5E]'),
          ' ',
        )
        .replaceAll(RegExp(r'[!"#$%&()*+,-./:;<=>?@\[\\\]^_`{|}~]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (withoutPunctuation.isEmpty || withoutPunctuation == query) return null;
    return withoutPunctuation;
  }

  static Future<SearchResult> _enrichWithDouban(SearchResult result) async {
    try {
      final doubanResponse = await DoubanService.search(
        keyword: result.title,
        limit: 5,
      ).timeout(const Duration(seconds: 2));
      if (!doubanResponse.success || doubanResponse.data == null) {
        return result;
      }

      DoubanMovie? bestMatch;
      var bestScore = 0.0;

      for (final candidate in doubanResponse.data!) {
        var score = _titleSimilarity(result.title, candidate.title);
        if (result.year.isNotEmpty && candidate.year.isNotEmpty) {
          if (result.year == candidate.year) {
            score += 0.2;
          }
        }
        if (score > bestScore) {
          bestScore = score;
          bestMatch = candidate;
        }
      }

      if (bestMatch != null && bestScore >= _similarityThreshold) {
        return result.copyWith(
          poster: bestMatch.poster.isNotEmpty ? bestMatch.poster : null,
          doubanId: int.tryParse(bestMatch.id),
          year: result.year.isEmpty && bestMatch.year.isNotEmpty
              ? bestMatch.year
              : null,
        );
      }
    } catch (e) {
      // 豆瓣匹配失败时保留原结果，不阻断搜索流程
    }
    return result;
  }

  static Future<List<SearchResult>> _enrichAllWithDouban(
    List<SearchResult> results, {
    int concurrency = 5,
    void Function(int completed, int total, List<SearchResult> enrichedSoFar)?
        onProgress,
  }) async {
    final enriched = <SearchResult>[];
    for (var i = 0; i < results.length; i += concurrency) {
      final batch = results.skip(i).take(concurrency).toList();
      final batchEnriched = await Future.wait(
        batch.map((result) => _enrichWithDouban(result)),
      );
      enriched.addAll(batchEnriched);
      onProgress?.call(enriched.length, results.length, enriched.toList());
    }
    return enriched;
  }

  /// 将进度回调推迟到下一帧执行，避免在 build 阶段触发 setState 导致异常。
  static void _notifyProgress(
    void Function(List<SearchResult>, String)? onProgress,
    List<SearchResult> results,
    String text,
  ) {
    if (onProgress == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onProgress(results, text);
    });
  }

  /// 搜索页主搜索入口（恢复 f77c04a 发布版本逻辑）。
  /// 与详情页源搜索不同，这里以服务端结果为主；开启 [fuzzy] 后即使全部被客户端
  /// 相关性过滤，也会兜底返回 LunaTV 原始结果，保持搜索页的模糊搜索体验。
  static Future<ApiResponse<List<SearchResult>>> search({
    required String keyword,
    String? source,
    http.Client? cancelClient,
    bool exactMatch = false,
    bool fuzzy = false,
    /// 进度回调，搜索找到结果后会立即触发一次（未 enrich），后续每完成一批
    /// 豆瓣信息补充再触发一次，供 UI 实时刷新结果与进度文案。
    void Function(List<SearchResult> results, String progressText)? onProgress,
  }) async {
    final lunaResponse = await LunaTVService.search(
      keyword: keyword,
      source: source,
      cancelClient: cancelClient,
    );
    if (!lunaResponse.success || lunaResponse.data == null) {
      return ApiResponse.error(
        lunaResponse.message ?? '搜索失败',
        statusCode: lunaResponse.statusCode,
      );
    }

    final results = _filterByRelevance(
      lunaResponse.data!,
      keyword,
      exactMatch: exactMatch,
      fuzzy: fuzzy,
    );
    if (results.isEmpty) {
      // 模糊搜索模式下若全部被过滤，直接返回 LunaTV 原始结果兜底，
      // 避免桌面键鼠输入因大小写/空格等细节搜不到内容。
      if (fuzzy && lunaResponse.data!.isNotEmpty) {
        _notifyProgress(
          onProgress,
          lunaResponse.data!,
          '已找到 ${lunaResponse.data!.length} 个结果，正在补充海报信息...',
        );
        final enriched = await _enrichAllWithDouban(
          lunaResponse.data!,
          onProgress: (completed, total, enrichedSoFar) {
            _notifyProgress(
              onProgress,
              enrichedSoFar,
              '正在补充海报信息 ($completed/$total)',
            );
          },
        );
        return ApiResponse.success(
          enriched.toList(),
          statusCode: lunaResponse.statusCode,
        );
      }
      return ApiResponse.success([], statusCode: lunaResponse.statusCode);
    }

    // 先立即回调未 enrich 的结果，让用户尽快看到搜索内容
    _notifyProgress(
      onProgress,
      results,
      '已找到 ${results.length} 个结果，正在补充海报信息...',
    );

    final enriched = await _enrichAllWithDouban(
      results,
      onProgress: (completed, total, enrichedSoFar) {
        _notifyProgress(
          onProgress,
          enrichedSoFar,
          '正在补充海报信息 ($completed/$total)',
        );
      },
    );

    return ApiResponse.success(
      enriched.toList(),
      statusCode: lunaResponse.statusCode,
    );
  }

  static List<SourceOption> groupBySource(List<SearchResult> results) {
    final map = <String, SourceOption>{};
    for (final result in results) {
      final key = '${result.source}_${result.id}';
      if (!map.containsKey(key)) {
        map[key] = SourceOption.fromSearchResult(result);
      }
    }
    return map.values.toList();
  }

  /// 测速档位：按播放状态决定并发数、单分片采样字节、分片内并发。
  ///
  /// 🔴 2026-10-23：播放进行中时整体降档，把带宽让给播放缓冲。
  ///
  /// | 状态         | 外层并发 | 单分片采样 | 分片内并发 | 在途峰值 |
  /// |--------------|---------|-----------|-----------|---------|
  /// | 无播放       | 2       | 512KB     | 3         | 6×512KB  |
  /// | 播放取流中   | 1       | 256KB     | 1         | 1×256KB  |
  ///
  /// 峰值在途下载量从 3MB 降到 256KB（≈12 倍），采样量仍远大于 TCP 慢启动
  /// 窗口，测出的速度具有代表性。
  ///
  /// 🔴 2026-10-23：播放中采样 128KB → 256KB。128KB 样本在高速网络下单次
  /// 传输耗时可能不足 1ms，量化误差过大；256KB 把误差减半，同时占用仍
  /// 只有空闲档的 1/2。
  ///
  /// 🔴 2026-10-23（第二轮调整）：播放中**批次并发 1 → 2**。
  ///
  /// 上一轮 Windows 实测发现「播放期间测速太慢」的**主因不是单源测速慢，
  /// 而是源与源之间完全串行**：详情页一次要测 20+ 个源，播放中每源最坏
  /// 8 秒（外层超时），串行下来整轮要 2~3 分钟，源列表上的速度迟迟不出。
  ///
  /// 改并发 2 后整轮约缩短一半。带宽代价可控：
  ///   播放中在途峰值 = 2 源 × 256KB = 512KB
  ///   空闲档在途峰值 = 2 源 × 3 分片 × 512KB = 3MB
  /// 播放档仍只有空闲档的 1/6，对正在播放的视频流影响很小。
  @visibleForTesting
  static ({int concurrency, int sampleBytes, int segmentConcurrency})
      speedTestBudget({required bool playbackActive}) {
    return playbackActive
        ? (concurrency: 2, sampleBytes: 256 * 1024, segmentConcurrency: 1)
        : (concurrency: 2, sampleBytes: 512 * 1024, segmentConcurrency: 3);
  }

  static Future<List<SourceOption>> speedTestSources(
    List<SourceOption> sources, {
    /// 每次有源测速完成时回调当前已排序的完整列表，供 UI 实时刷新。
    void Function(List<SourceOption> sortedSources)? onProgress,
    // 🔴 2026-10-23：并发从 4 降到 2。
    //   测速与播放**并行**跑（详情页后台测速，播放页同时起播），并发过高会
    //   抢光带宽与连接池：
    //     · 荣耀平板实测：24 源测速持续 68s，活跃源首包被拖到 10.5s；
    //     · Windows server 实测：测速请求与本地代理抢连接，反复出现
    //       `analyzeM3u8ForSpeedTest 失败: HandshakeException`，叠加
    //       换源/换播放器的资源重建 → **软件卡死**。
    //   降并发后测速总时长变长（后台无感），但播放侧不再被拖慢。
    int concurrency = 2,
    /// 播放记录中的源标识（格式 source+id）。存在时优先对该源做真实测速。
    String? playedSourceKey,
    /// 为 true 时对所有源做真实下载测速与分辨率分析；否则仅测速优先级源（13 个）。
    bool testAllSources = false,
    /// 无播放记录时测速完成前的进度文案回调，供详情页展示“测速中 x/y”。
    void Function(int completed, int total)? onProgressText,
    /// 为 true 时只测试 [sources] 中尚未被探测过（speed 为 null）的源，
    /// 用于测速期间新增源或补充 episodes 后的补测，避免全部源重测一遍。
    bool onlyUntested = false,
  }) async {
    // 真实下载测速覆盖优先级源；其余源通过快速可用性探测标记为可用/不可用。
    // 默认选择策略：播放记录原始源 + 响应最快 4 个源 + 随机 8 个源。
    const speedTestCount = 13;
    const priorityFastCount = 4;
    const perSourceTimeout = Duration(seconds: 8);
    // 🔴 2026-10-23（第三轮）：**内部预算比外层硬超时早 1 秒收口**。
    //
    // `Future.timeout` 只放弃等待，不会中止底层 HTTP 请求。原来内层的
    // 解析超时 8 秒 + 测速超时 12 秒，串起来最多 20 秒，于是内层必然
    // 在外层放弃之后还继续跑 2~4 秒：白占带宽，日志里还会同时出现
    // `outer-timeout-abandoned` 与 `note=unavailable` 两条互相矛盾的记录。
    //
    // 现在内层拿 7 秒预算，保证**在外层 8 秒之前自己收口并给出结论**，
    // 外层超时基本不再触发。
    const innerBudget = Duration(seconds: 7);
    // 🔴 2026-10-23：探测并发 8 → 4，同样为播放侧让出带宽与连接。
    const probeConcurrency = 4;

    /// 为每个源补充从 sourceName/remarks 推断的分辨率，避免服务端未返回时完全空白。
    SourceOption _inferResolution(SourceOption option) {
      if (option.resolution != null && option.resolution!.isNotEmpty) {
        return option;
      }
      final text = <String>[option.sourceName, option.remarks ?? ''].join(' ');
      final inferred = M3u8Utils.extractResolutionFromText(text);
      if (inferred != null) {
        return option.copyWith(resolution: inferred);
      }
      return option;
    }

    var workingSources = sources.map(_inferResolution).toList();
    final testedKeys = <String>{};

    // 不再预填本地分辨率缓存：详情页统一走实时 M3U8 解析/测速，避免旧缓存
    // 把某个源永久锁死在低分辨率上（例如早期误判为 360P 后每次都回退到 360P）。

    void _notifyProgress() {
      final sorted = _sortSourcesBySpeed(
        workingSources,
        recordKey: playedSourceKey,
        testedKeys: testedKeys,
      );
      onProgress?.call(sorted);
    }

    // 阶段 1：快速可用性探测，覆盖所有源，让列表中的每个源都有 speed/responseTime。
    // 探测只做轻量级 HEAD/GET，不解析 M3U8 也不测下载速度，避免浪费流量和时间。
    // 仅在非补测模式下执行探测；补测模式下已有真实测速结果，避免被探测结果覆盖。
    if (!onlyUntested) {
      final urlsToProbe = <String>[];
      final probeIndexMap = <int, int>{}; // probe list index -> workingSources index
      for (var i = 0; i < workingSources.length; i++) {
        final option = workingSources[i];
        if (option.episodes.isEmpty) continue;
        final testEpisodeIndex = option.episodes.length > 1 ? 1 : 0;
        probeIndexMap[urlsToProbe.length] = i;
        urlsToProbe.add(option.episodes[testEpisodeIndex]);
      }

      if (urlsToProbe.isNotEmpty) {
        final probeResults = await LunaTVService.probeUrls(
          urlsToProbe,
          concurrency: probeConcurrency,
          timeout: const Duration(seconds: 4),
        );
        for (var i = 0; i < probeResults.length; i++) {
          final sourceIdx = probeIndexMap[i];
          if (sourceIdx == null) continue;
          final option = workingSources[sourceIdx];
          final r = probeResults[i];
          workingSources[sourceIdx] = option.copyWith(
            responseTime: r.responseTime,
            speed: r.available ? -1.0 : 0.0,
          );
        }
        _notifyProgress();
      }
    }

    // 阶段 2：选择需要做真实下载测速与分辨率识别的源。
    final List<SourceOption> sourcesToSpeedTest;
    if (onlyUntested) {
      // 仅测试尚未被探测过的源（speed 为 null），用于补测新增源或刚补充 episodes 的源。
      sourcesToSpeedTest = workingSources.where((s) => s.speed == null).toList();
      if (playedSourceKey != null && playedSourceKey.isNotEmpty) {
        final originalIndex = sourcesToSpeedTest.indexWhere(
          (s) => '${s.source}+${s.id}' == playedSourceKey,
        );
        if (originalIndex > 0) {
          final original = sourcesToSpeedTest.removeAt(originalIndex);
          sourcesToSpeedTest.insert(0, original);
        }
      }
    } else if (testAllSources) {
      // 对所有源测速，但把 playedSourceKey 对应的原始源置顶优先测速。
      sourcesToSpeedTest = List<SourceOption>.from(workingSources);
      if (playedSourceKey != null && playedSourceKey.isNotEmpty) {
        final originalIndex = sourcesToSpeedTest.indexWhere(
          (s) => '${s.source}+${s.id}' == playedSourceKey,
        );
        if (originalIndex > 0) {
          final original = sourcesToSpeedTest.removeAt(originalIndex);
          sourcesToSpeedTest.insert(0, original);
        }
      }
    } else {
      sourcesToSpeedTest = _selectSourcesForSpeedTest(
        workingSources,
        playedSourceKey: playedSourceKey,
        maxTestCount: speedTestCount,
        topPriorityCount: priorityFastCount,
      );
    }
    for (final s in sourcesToSpeedTest) {
      testedKeys.add('${s.source}+${s.id}');
    }

    final totalToTest = sourcesToSpeedTest.length;
    var completedCount = 0;

    // 🔴 2026-10-23：播放中给播放缓冲让路。
    //
    //   测速与播放并行跑时，两者**物理带宽共享**（连接池独立，但网卡共享）。
    //   原先只有固定并发 2（外层）× 3（分片内层）= 最多 6 条 512KB 并发流，
    //   在慢网络下会把带宽吃满，直接拖垮播放缓冲。
    //
    //   现在按 [PlaybackActivity] 的实时状态自适应，档位见
    //   [speedTestBudget]：
    //     · 无播放        → 维持原档（并发 2 / 采样 512KB / 分片并发 3）
    //     · 播放取流中    → 降档（并发 2 / 采样 256KB / 分片并发 1），
    //                       在途峰值 2×1×256KB = 512KB，
    //                       仅为空闲档（2×3×512KB = 3MB）的 1/6，
    //                       测速结果仍然有效
    //     · 缓冲告急      → 完全停手，等缓冲恢复再继续（超时就放弃本轮）
    //
    //   ⚠️ 档位与 [speedTestBudget] 的实际返回值必须一致。
    //     2026-10-24 修正：本注释曾停留在「并发 1 / 采样 128KB / 降 24 倍」
    //     的旧档（改动 4 把播放中批次并发 1→2、采样 128KB→256KB 后未同步），
    //     与同文件 592-595 行的正确说明自相矛盾 —— 过期注释就是记忆漂移源。
    //
    //   注：这里**不使用令牌桶限速**。限速会让 `received/seconds` 测出来的
    //   速度被限速值污染，慢源会被误判成快源；改用「降采样量」控制占用，
    //   既让出带宽又不失真。
    //
    /// 播放缓冲告急时等待缓冲恢复；超时则返回 false，放弃本轮剩余测速。
    ///
    /// 上限取 60 秒：[PlaybackActivity] 的告急持续上限是 45 秒，超过后
    /// 会自动解除告急、退回普通降档，因此正常情况下这里都会等到恢复。
    Future<bool> _waitForPlaybackBandwidth({
      Duration maxWait = const Duration(seconds: 60),
    }) async {
      if (!PlaybackActivity.instance.mustYield) return true;
      final deadline = DateTime.now().add(maxWait);
      while (DateTime.now().isBefore(deadline)) {
        await Future.delayed(const Duration(milliseconds: 500));
        if (!PlaybackActivity.instance.mustYield) return true;
      }
      return false;
    }

    var i = 0;
    while (i < sourcesToSpeedTest.length) {
      // 每批开始前重新读取播放状态：播放可能在上一批期间才起播。
      final budget = speedTestBudget(
        playbackActive: PlaybackActivity.instance.isActive,
      );
      final effConcurrency = budget.concurrency;
      final effSampleBytes = budget.sampleBytes;
      final effSegmentConcurrency = budget.segmentConcurrency;

      // 🔴 2026-10-23：**正在播放的源不测速，只识别分辨率**。
      //
      //   原因有二：
      //     1. 该源的流量正被播放器占用，再测一次会让测出的速度被自身
      //        播放流污染 —— 表现为「一开始播放，源的速度就显示很慢」，
      //        进而误导换源排序；
      //     2. 测速纯属重复消耗带宽，对正在播放的源没有任何决策价值。
      //
      //   跳过的源只做 M3U8 解析以拿到真实分辨率，速度记为 -1.0
      //   （语义：可用但速度未知），与阶段 1 探测的「可用」语义一致。
      final playingSourceKey = PlaybackActivity.instance.currentSourceKey;

      final batchEnd = (i + effConcurrency).clamp(0, sourcesToSpeedTest.length);
      await Future.wait([
        for (var j = i; j < batchEnd; j++)
          () async {
            final option = sourcesToSpeedTest[j];
            if (option.episodes.isEmpty) {
              completedCount++;
              onProgressText?.call(completedCount, totalToTest);
              return;
            }

            final testEpisodeIndex = option.episodes.length > 1 ? 1 : 0;
            final episodeUrl = option.episodes[testEpisodeIndex];
            // 不再用本地缓存的分辨率作为测速兜底；每次进入详情页都重新解析 M3U8
            // 获取真实分辨率，避免旧缓存把源锁死在低分辨率。
            final cachedResolution = null;

            // 正在播放的源 → 只识别分辨率，不测速。
            final isPlayingSource = playingSourceKey != null &&
                playingSourceKey == '${option.source}+${option.id}';

            final cancelToken = SpeedTestCancelToken();
            final metrics = await LunaTVService.speedTestEpisode(
              episodeUrl,
              sourceType: option.source,
              cachedResolution: cachedResolution,
              // 播放中用小样本，测完即弃，把带宽让给缓冲。
              sampleBytes: effSampleBytes,
              maxConcurrency: effSegmentConcurrency,
              resolutionOnly: isPlayingSource,
              // 🔴 2026-10-23（第三轮）：内层预算比外层硬超时早 1 秒收口，
              // 让每个源都拿到**明确结论**而不是被外层放弃。
              timeout: innerBudget,
              cancelToken: cancelToken,
            )
                .timeout(perSourceTimeout)
                .catchError((_) {
              // 外层超时 → 通知内层立刻停止，别再白跑几秒。
              cancelToken.cancel();
              // 单源测速超时视为可用但速度未知，避免把可播放源误判为不可用。
              //
              // 🔴 2026-10-23：外层超时后内部请求**不会立刻中止**，仍可能在
              // 几秒后跑完并打印 `note=unavailable`。若不区分，事后看日志会
              // 误以为该源被判定为「不可用」，而它其实是被外层放弃的。
              // 这里补一条明确的放弃日志。
              debugPrint(
                '[SpeedTestSpeed] source=${option.source} url=$episodeUrl '
                'speed=null sample=${effSampleBytes}B '
                'pa=${PlaybackActivity.instance.isActive} '
                'note=outer-timeout-abandoned',
              );
              return (
                responseTime: Duration.zero,
                speed: -1.0,
                resolution: null,
              );
            });

            final fallbackText = <String>[
              option.sourceName,
              option.remarks ?? '',
              episodeUrl,
            ].join(' ');
            // 实测分辨率优先于搜索阶段的文本推断/缓存，M3U8 真实解析最可信。
            final detectedResolution = metrics.resolution ??
                option.resolution ??
                M3u8Utils.extractResolutionFromText(fallbackText);

            // 缓存从真实 M3U8 分析得到的分辨率，便于下次直接使用。
            // 若实测分辨率与缓存/旧值不同，用实测值覆盖。
            if (detectedResolution != null && detectedResolution.isNotEmpty) {
              await LocalStorageService.setSourceResolutionCache(
                option.source,
                option.id,
                detectedResolution,
              );
            }

            final updated = option.copyWith(
              responseTime: metrics.responseTime,
              speed: metrics.speed,
              resolution: detectedResolution,
            );

            // 把真实测速结果写回 workingSources 的对应位置。
            final sourceIdx = workingSources.indexWhere(
              (s) => s.source == option.source && s.id == option.id,
            );
            if (sourceIdx >= 0) {
              workingSources[sourceIdx] = updated;
              _notifyProgress();
            }
            completedCount++;
            onProgressText?.call(completedCount, totalToTest);
          }(),
      ]);

      i = batchEnd;

      // 缓冲告急时把带宽完全让给播放：等待缓冲恢复，超时则放弃本轮剩余测速。
      if (i < sourcesToSpeedTest.length) {
        if (!await _waitForPlaybackBandwidth()) {
          debugPrint(
            '[SpeedTest] 播放缓冲持续告急，放弃本轮剩余测速'
            '（已完成 $completedCount/$totalToTest）',
          );
          break;
        }
        await Future.delayed(
          Duration(milliseconds: PlaybackActivity.instance.isActive ? 400 : 150),
        );
      }
    }

    return _sortSourcesBySpeed(
      workingSources,
      recordKey: playedSourceKey,
      testedKeys: testedKeys,
    );
  }

  /// 按测速结果排序源列表。
  /// - [recordKey] 对应的源永远置顶（若存在）。
  /// - 真实测速过的源排在记录源之后。
  /// - 同等级内按「可用性 > 分辨率 > 速度」排序，避免 360P 因速度略高而压过 1080P。
  static List<SourceOption> _sortSourcesBySpeed(
    List<SourceOption> sources, {
    String? recordKey,
    Set<String>? testedKeys,
  }) {
    if (sources.length <= 1) return List<SourceOption>.from(sources);

    final keys = testedKeys ?? <String>{};
    SourceOption? recordSource;
    if (recordKey != null && recordKey.isNotEmpty) {
      final idx = sources.indexWhere((s) => '${s.source}+${s.id}' == recordKey);
      if (idx >= 0) {
        recordSource = sources[idx];
      }
    }

    /// 可用性：测出真实速度 > 可用但速度未知 > 不可用/未知。
    int _availabilityRank(double? speed) {
      if (speed == null || speed == 0) return 0;
      if (speed == -1.0) return 1;
      return 2;
    }

    /// 分辨率档位：用于保证 1080P 排在 720P/360P 之前。
    int _resolutionRank(String? resolution) {
      switch (resolution) {
        case '4K':
          return 5;
        case '1080P':
          return 4;
        case '720P':
          return 3;
        case '480P':
          return 2;
        case '360P':
          return 1;
        default:
          return 0;
      }
    }

    final others = sources.where((s) => s != recordSource).toList();
    others.sort((a, b) {
      final aKey = '${a.source}+${a.id}';
      final bKey = '${b.source}+${b.id}';
      final aTested = keys.contains(aKey);
      final bTested = keys.contains(bKey);

      // 真实测速过的源排在最前面。
      if (aTested && !bTested) return -1;
      if (!aTested && bTested) return 1;

      // 同等级内先比可用性。
      final aAvail = _availabilityRank(a.speed);
      final bAvail = _availabilityRank(b.speed);
      if (aAvail != bAvail) return bAvail.compareTo(aAvail);

      // 可用性相同再比分辨率档位，避免低清源因速度高排在前面。
      final aRes = _resolutionRank(a.resolution);
      final bRes = _resolutionRank(b.resolution);
      if (aRes != bRes) return bRes.compareTo(aRes);

      // 同分辨率内按真实速度降序。
      final aEffective = a.speed == -1.0 ? 0.0 : (a.speed ?? 0.0);
      final bEffective = b.speed == -1.0 ? 0.0 : (b.speed ?? 0.0);
      return bEffective.compareTo(aEffective);
    });

    if (recordSource != null) {
      return [recordSource, ...others];
    }
    return others;
  }

  /// 选择需要真实测速的源：总数不超过 [maxTestCount]。
  /// 若存在 [playedSourceKey]，优先保留播放记录中的原始源，再从剩余源中按响应时间
  /// 取最快的 [topPriorityCount] 个，最后随机补齐剩余位置。
  static List<SourceOption> _selectSourcesForSpeedTest(
    List<SourceOption> sources, {
    String? playedSourceKey,
    required int maxTestCount,
    required int topPriorityCount,
  }) {
    if (sources.length <= maxTestCount) return sources;

    final selected = <SourceOption>[];
    final selectedKeys = <String>{};

    // 1. 优先加入播放记录中的原始源。
    if (playedSourceKey != null && playedSourceKey.isNotEmpty) {
      final originalIndex = sources.indexWhere(
        (s) => '${s.source}+${s.id}' == playedSourceKey,
      );
      if (originalIndex >= 0) {
        selected.add(sources[originalIndex]);
        selectedKeys.add(playedSourceKey);
      }
    }

    // 2. 从剩余源中按响应时间取最快的源。
    final remaining = sources.where((s) {
      return !selectedKeys.contains('${s.source}+${s.id}');
    }).toList();
    remaining.sort((a, b) {
      final aTime = a.responseTime?.inMilliseconds ?? 0x7FFFFFFFFFFFFFFF;
      final bTime = b.responseTime?.inMilliseconds ?? 0x7FFFFFFFFFFFFFFF;
      return aTime.compareTo(bTime);
    });

    final fastCount = topPriorityCount.clamp(0, maxTestCount - selected.length);
    for (var i = 0; i < fastCount && i < remaining.length; i++) {
      selected.add(remaining[i]);
      selectedKeys.add('${remaining[i].source}+${remaining[i].id}');
    }

    // 3. 随机补齐剩余位置。
    final pool = sources.where((s) {
      return !selectedKeys.contains('${s.source}+${s.id}');
    }).toList()..shuffle();
    final randomNeed = maxTestCount - selected.length;
    if (randomNeed > 0) {
      selected.addAll(pool.take(randomNeed));
    }

    return selected;
  }

  static Future<ApiResponse<List<SourceOption>>> searchSources({
    required String keyword,
    String? source,
    bool exactMatch = false,
    bool fuzzy = false,
  }) async {
    final response = await search(
      keyword: keyword,
      source: source,
      exactMatch: exactMatch,
      fuzzy: fuzzy,
    );
    if (!response.success || response.data == null) {
      return ApiResponse.error(
        response.message ?? '搜索失败',
        statusCode: response.statusCode,
      );
    }
    final grouped = groupBySource(response.data!);
    return ApiResponse.success(grouped, statusCode: response.statusCode);
  }

  /// 快速搜索可用源，不走豆瓣 enrich，避免详情页等待过久。
  static Future<ApiResponse<List<SourceOption>>> searchSourcesFast({
    required String keyword,
    String? source,
    bool exactMatch = false,
    bool fuzzy = false,
  }) async {
    final lunaResponse = await LunaTVService.search(
      keyword: keyword,
      source: source,
    );
    if (!lunaResponse.success || lunaResponse.data == null) {
      return ApiResponse.error(
        lunaResponse.message ?? '搜索失败',
        statusCode: lunaResponse.statusCode,
      );
    }
    final filtered = _filterByRelevance(
      lunaResponse.data!,
      keyword,
      exactMatch: exactMatch,
      fuzzy: fuzzy,
    );
    final grouped = groupBySource(filtered);
    return ApiResponse.success(grouped, statusCode: lunaResponse.statusCode);
  }

  /// 使用搜索变体并行搜索可用源，提升 Bangumi/动漫条目命中率。
  /// [onProgress] 会在每个变体搜索完成后被调用，用于详情页实时展示已找到的结果。
  static Future<ApiResponse<List<SourceOption>>> searchSourcesFastWithVariants({
    required String keyword,
    String? source,
    bool forceRefresh = false,
    bool exactMatch = false,
    bool fuzzy = false,
    void Function(List<SourceOption> sources)? onProgress,
    /// 🔴 详情页后台源搜索的单次请求超时（可传更短的值快速失败）。
    Duration? timeout,
  }) async {
    final variants = generateSearchVariants(keyword, fuzzy: fuzzy);

    // 顺序搜索变体：先搜原始词，有结果立即返回，避免并发 API 调用过多导致等待时间长
    final responses = <ApiResponse<List<SearchResult>>>[];
    for (final variant in variants) {
      try {
        final response = await LunaTVService.search(
          keyword: variant,
          source: source,
          forceRefresh: forceRefresh,
          timeout: timeout,
        );
        responses.add(response);

        // 每完成一个变体就进行一次中间结果回调，减少详情页等待感
        if (onProgress != null) {
          final seen = <String>{};
          final merged = <SearchResult>[];
          for (final r in responses) {
            if (r.success && r.data != null) {
              for (final result in r.data!) {
                final key = '${result.source}_${result.id}';
                if (!seen.contains(key)) {
                  seen.add(key);
                  merged.add(result);
                }
              }
            }
          }
          final filtered = _filterByRelevance(
            merged,
            keyword,
            variants: variants.sublist(0, responses.length),
            exactMatch: exactMatch,
            fuzzy: fuzzy,
          );
          onProgress(groupBySource(filtered));
        }

        // 若当前变体搜索成功且有数据，直接返回，不再搜索后续变体
        if (response.success && response.data != null && response.data!.isNotEmpty) {
          break;
        }
      } catch (e) {
        debugPrint('搜索变体 "$variant" 失败: $e');
        responses.add(ApiResponse<List<SearchResult>>.error('变体搜索失败: $e'));
      }
    }

    // 合并结果并去重
    final seen = <String>{};
    final merged = <SearchResult>[];
    for (final response in responses) {
      if (response.success && response.data != null) {
        for (final result in response.data!) {
          final key = '${result.source}_${result.id}';
          if (!seen.contains(key)) {
            seen.add(key);
            merged.add(result);
          }
        }
      }
    }

    // 根据相关性过滤，避免变体搜索带来大量不匹配的影视
    final filtered = _filterByRelevance(
      merged,
      keyword,
      variants: variants.sublist(0, responses.length),
      exactMatch: exactMatch,
      fuzzy: fuzzy,
    );

    // 如果全部失败，返回第一个失败的错误信息
    if (filtered.isEmpty) {
      final firstError = responses.firstWhere(
        (r) => !r.success,
        orElse: () => ApiResponse<List<SearchResult>>.success([]),
      );
      if (!firstError.success) {
        return ApiResponse.error(
          firstError.message ?? '搜索失败',
          statusCode: firstError.statusCode,
        );
      }
    }

    final grouped = groupBySource(filtered);
    return ApiResponse.success(grouped);
  }

  /// 搜索某部影片的可用源，并把 [current] 放在第一位，其余去重排在后面。
  /// 使用后端搜索（不走豆瓣 enrich）以提升速度，失败或超时时只返回 [current]，
  /// 避免让用户长时间等待在搜索页。
  static Future<List<SourceOption>> searchAlternativeSources({
    required String keyword,
    required SourceOption current,
    bool exactMatch = false,
    bool fuzzy = false,
  }) async {
    try {
      // 从播放记录进入时强制重新搜索其他源，避免旧缓存导致只能使用当前源
      final response = await LunaTVService.search(
        keyword: keyword,
        forceRefresh: true,
      );
      if (!response.success || response.data == null) {
        return [current];
      }
      final filtered = _filterByRelevance(
        response.data!,
        keyword,
        exactMatch: exactMatch,
        fuzzy: fuzzy,
      );
      final grouped = groupBySource(filtered);
      final others = grouped
          .where((s) => s.source != current.source || s.id != current.id)
          .toList();
      return [current, ...others];
    } catch (e) {
      debugPrint('searchAlternativeSources: 搜索可用源失败 $e');
      return [current];
    }
  }
}

/// 带分数的搜索结果包装，仅用于 SearchService 内部排序。
class _ScoredResult {
  final SearchResult result;
  final double baseScore;
  final double totalScore;

  _ScoredResult(this.result, this.baseScore, this.totalScore);
}


