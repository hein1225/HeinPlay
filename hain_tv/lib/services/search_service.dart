import 'dart:async';

import 'package:flutter/foundation.dart';

import '../models/api_response.dart';
import '../models/douban_movie.dart';
import '../models/search_result.dart';
import '../models/source_option.dart';
import 'douban_service.dart';
import 'lunatv_service.dart';

class SearchService {
  static const double _similarityThreshold = 0.6;
  /// 搜索结果高相关性阈值（完全/开头/包含匹配）。
  static const double _highRelevanceThreshold = 60.0;
  /// 搜索结果中等相关性阈值（普通模糊匹配）。
  static const double _mediumRelevanceThreshold = 40.0;
  /// 手动模糊搜索阈值，比自动过滤更宽松，允许部分字符顺序匹配命中。
  static const double _fuzzyRelevanceThreshold = 25.0;

  static const Map<String, String> _chineseToArabic = {
    '一': '1', '二': '2', '三': '3', '四': '4', '五': '5',
    '六': '6', '七': '7', '八': '8', '九': '9', '十': '10',
  };
  static const List<String> _arabicToChinese = [
    '', '一', '二', '三', '四', '五', '六', '七', '八', '九', '十',
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

  /// 计算 Levenshtein 编辑距离（参考 LunaTV search-ranking.ts）。
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
  static double _calculateBaseRelevanceScore(SearchResult result, String query) {
    final title = (result.title).trim();
    final keyword = query.trim();

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
    return queries.any((q) => _calculateBaseRelevanceScore(
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
        100);
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
          current[j] = current[j - 1] > previous[j] ? current[j - 1] : previous[j];
        }
      }
      final temp = previous;
      previous = current;
      current = temp;
    }

    return previous[n];
  }

  /// 智能生成数字变体（参考 LunaTV 实现）。
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
        return query.replaceFirst(arabicMatch.group(0)!, '第${chineseNum}$suffix');
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

  /// 智能生成中文标点变体。
  static String? _generatePunctuationVariant(String query) {
    if (query.contains('：')) {
      return query.replaceAll('：', ' ').trim();
    }
    if (query.contains(':')) {
      return query.replaceAll(':', ' ').trim();
    }
    return null;
  }

  /// 智能生成搜索变体，参考 LunaTV 的 generateSearchVariants。
  /// 优先返回原始查询；仅在可能提升命中率时生成额外变体。
  /// [fuzzy] 为 true 时，额外生成剥离季/部/年番等后缀的基础标题变体，
  /// 用于提升带后缀标题（如"凡人修仙传 年番4"）的模糊搜索命中率。
  static List<String> generateSearchVariants(
    String originalQuery, {
    bool fuzzy = false,
  }) {
    final trimmed = originalQuery.trim();
    if (trimmed.isEmpty) return [trimmed];

    final variants = <String>[trimmed];

    // 1. 数字变体（最高优先级）
    final numberVariant = _generateNumberVariant(trimmed);
    if (numberVariant != null && numberVariant != trimmed) {
      variants.add(numberVariant);
    }

    // 2. 中文标点变体
    final punctuationVariant = _generatePunctuationVariant(trimmed);
    if (punctuationVariant != null && punctuationVariant != trimmed) {
      variants.add(punctuationVariant);
    }

    // 3. 空格变体（多词搜索）
    if (trimmed.contains(' ')) {
      final keywords = trimmed.split(RegExp(r'\s+'));
      if (keywords.length >= 2) {
        final lastKeyword = keywords.last;
        if (RegExp(r'第|季|集|部|篇|章').hasMatch(lastKeyword)) {
          final combined = keywords.first + lastKeyword;
          if (combined != trimmed) variants.add(combined);
        }
        final noSpaces = trimmed.replaceAll(RegExp(r'\s+'), '');
        if (noSpaces != trimmed) variants.add(noSpaces);

        // 模糊搜索时：若最后一个词像季/部/集/年番等后缀，额外生成基础标题变体
        if (fuzzy && _looksLikeSeasonSuffix(lastKeyword)) {
          final baseTitle = keywords.take(keywords.length - 1).join(' ').trim();
          if (baseTitle.isNotEmpty && baseTitle != trimmed) {
            variants.add(baseTitle);
          }
        }
      }
    }

    return variants.toSet().toList();
  }

  /// 判断 [token] 是否像季/部/集/年番等后缀标识。
  static bool _looksLikeSeasonSuffix(String token) {
    if (token.isEmpty) return false;
    return RegExp(r'第|季|部|集|篇|章|年番|季番|期|卷').hasMatch(token) ||
        RegExp(r'\d').hasMatch(token);
  }

  static Future<SearchResult> _enrichWithDouban(SearchResult result) async {
    try {
      final doubanResponse = await DoubanService.search(
        keyword: result.title,
        limit: 5,
      ).timeout(const Duration(seconds: 5));
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
  }) async {
    final enriched = <SearchResult>[];
    for (var i = 0; i < results.length; i += concurrency) {
      final batch = results.skip(i).take(concurrency).toList();
      final batchEnriched = await Future.wait(
        batch.map((result) => _enrichWithDouban(result)),
      );
      enriched.addAll(batchEnriched);
    }
    return enriched;
  }

  static Future<ApiResponse<List<SearchResult>>> search({
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

    final results = _filterByRelevance(
      lunaResponse.data!,
      keyword,
      exactMatch: exactMatch,
      fuzzy: fuzzy,
    );
    if (results.isEmpty) {
      return ApiResponse.success([], statusCode: lunaResponse.statusCode);
    }

    final enriched = await _enrichAllWithDouban(results);

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

  static Future<List<SourceOption>> speedTestSources(
    List<SourceOption> sources, {
    void Function(int index, SourceOption updated)? onProgress,
  }) async {
    final futures = <Future<void>>[];
    final updated = List<SourceOption>.from(sources);

    for (var i = 0; i < updated.length; i++) {
      final index = i;
      futures.add(() async {
        final option = updated[index];
        final detailResponse = await LunaTVService.getDetailForSpeedTest(
          source: option.source,
          id: option.id,
          title: option.title,
        );
        if (!detailResponse.success ||
            detailResponse.data == null ||
            detailResponse.data!.episodes.isEmpty) {
          updated[index] = option.copyWith(
            responseTime: const Duration(seconds: 999),
            speed: 0.0,
          );
          onProgress?.call(index, updated[index]);
          return;
        }

        final firstEpisode = detailResponse.data!.episodes.first;
        final metrics = await LunaTVService.speedTestEpisode(firstEpisode);
        updated[index] = option.copyWith(
          responseTime: metrics.responseTime,
          speed: metrics.speed,
        );
        onProgress?.call(index, updated[index]);
      }());
    }

    await Future.wait(futures);
    updated.sort((a, b) {
      final aOk = (a.speed ?? 0) > 0;
      final bOk = (b.speed ?? 0) > 0;
      if (aOk && !bOk) return -1;
      if (!aOk && bOk) return 1;
      return (b.speed ?? 0).compareTo(a.speed ?? 0);
    });
    return updated;
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

  /// 使用搜索变体并行搜索可用源，参考 LunaTV 提升 Bangumi/动漫条目命中率。
  /// [onProgress] 会在每个变体搜索完成后被调用，用于详情页实时展示已找到的结果。
  static Future<ApiResponse<List<SourceOption>>> searchSourcesFastWithVariants({
    required String keyword,
    String? source,
    bool forceRefresh = false,
    bool exactMatch = false,
    bool fuzzy = false,
    void Function(List<SourceOption> sources)? onProgress,
  }) async {
    final variants = generateSearchVariants(keyword, fuzzy: fuzzy);

    // 启动所有变体搜索，但不等待全部完成
    final futures = variants.map((variant) async {
      try {
        return await LunaTVService.search(
          keyword: variant,
          source: source,
          forceRefresh: forceRefresh,
        );
      } catch (e) {
        debugPrint('搜索变体 "$variant" 失败: $e');
        return ApiResponse<List<SearchResult>>.error('变体搜索失败: $e');
      }
    }).toList();

    final responses = <ApiResponse<List<SearchResult>>>[];
    for (var i = 0; i < futures.length; i++) {
      final response = await futures[i];
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
      variants: variants,
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
  /// 使用 LunaTV 搜索（不走豆瓣 enrich）以提升速度，失败或超时时只返回 [current]，
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
          .where(
            (s) => s.source != current.source || s.id != current.id,
          )
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
