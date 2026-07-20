import 'search_result.dart';

class SourceOption {
  final String source;
  final String sourceName;
  final String id;
  final String title;
  final String? poster;
  final String year;
  final int? doubanId;
  final String? remarks;
  final String? resolution;
  final Duration? responseTime;
  final double? speed;
  /// 保存搜索结果中的剧集 URL 列表，测速时可直接使用，避免重复请求详情接口。
  final List<String> episodes;

  const SourceOption({
    required this.source,
    required this.sourceName,
    required this.id,
    required this.title,
    this.poster,
    this.year = '',
    this.doubanId,
    this.remarks,
    this.resolution,
    this.responseTime,
    this.speed,
    this.episodes = const [],
  });

  factory SourceOption.fromSearchResult(SearchResult result) {
    return SourceOption(
      source: result.source,
      sourceName: result.sourceName,
      id: result.id,
      title: result.title,
      poster: result.poster.isNotEmpty ? result.poster : null,
      year: result.year,
      doubanId: result.doubanId,
      remarks: result.remarks,
      resolution: result.resolution,
      episodes: result.episodes,
    );
  }

  SourceOption copyWith({
    Duration? responseTime,
    double? speed,
    String? resolution,
    List<String>? episodes,
  }) {
    return SourceOption(
      source: source,
      sourceName: sourceName,
      id: id,
      title: title,
      poster: poster,
      year: year,
      doubanId: doubanId,
      remarks: remarks,
      resolution: resolution ?? this.resolution,
      responseTime: responseTime ?? this.responseTime,
      speed: speed ?? this.speed,
      episodes: episodes ?? this.episodes,
    );
  }
}
