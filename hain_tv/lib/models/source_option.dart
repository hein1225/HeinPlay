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
    );
  }

  SourceOption copyWith({
    Duration? responseTime,
    double? speed,
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
      resolution: resolution,
      responseTime: responseTime ?? this.responseTime,
      speed: speed ?? this.speed,
    );
  }
}
