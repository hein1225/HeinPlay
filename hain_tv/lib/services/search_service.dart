import 'dart:async';

import '../models/api_response.dart';
import '../models/douban_movie.dart';
import '../models/search_result.dart';
import '../models/source_option.dart';
import 'douban_service.dart';
import 'lunatv_service.dart';

class SearchService {
  static const double _similarityThreshold = 0.6;

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

    final results = lunaResponse.data!;
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
  }) async {
    final response = await search(keyword: keyword, source: source);
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
    final grouped = groupBySource(lunaResponse.data!);
    return ApiResponse.success(grouped, statusCode: lunaResponse.statusCode);
  }

  /// 搜索某部影片的可用源，并把 [current] 放在第一位，其余去重排在后面。
  /// 使用 LunaTV 搜索（不走豆瓣 enrich）以提升速度，失败或超时时只返回 [current]，
  /// 避免让用户长时间等待在搜索页。
  static Future<List<SourceOption>> searchAlternativeSources({
    required String keyword,
    required SourceOption current,
  }) async {
    try {
      final response = await LunaTVService.search(keyword: keyword)
          .timeout(const Duration(seconds: 5));
      if (!response.success || response.data == null) {
        return [current];
      }
      final grouped = groupBySource(response.data!);
      final others = grouped
          .where(
            (s) => s.source != current.source || s.id != current.id,
          )
          .toList();
      return [current, ...others];
    } catch (e) {
      return [current];
    }
  }
}
