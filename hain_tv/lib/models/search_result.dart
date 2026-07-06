class SearchResult {
  final String id;
  final String title;
  final String poster;
  final List<String> episodes;
  final List<String> episodesTitles;
  final String source;
  final String sourceName;
  final String? class_;
  final String year;
  final String? desc;
  final String? typeName;
  final int? doubanId;
  final String? remarks;
  final String? resolution;

  SearchResult({
    required this.id,
    required this.title,
    required this.poster,
    required this.episodes,
    required this.episodesTitles,
    required this.source,
    required this.sourceName,
    this.class_,
    required this.year,
    this.desc,
    this.typeName,
    this.doubanId,
    this.remarks,
    this.resolution,
  });

  factory SearchResult.fromJson(Map<String, dynamic> json) {
    return SearchResult(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: json['poster']?.toString() ?? '',
      episodes: json['episodes'] != null
          ? List<String>.from(json['episodes'])
          : [],
      episodesTitles: json['episodes_titles'] != null
          ? List<String>.from(json['episodes_titles'])
          : [],
      source: json['source']?.toString() ?? '',
      sourceName: json['source_name']?.toString() ?? '',
      class_: json['class']?.toString(),
      year: json['year']?.toString() ?? '',
      desc: json['desc']?.toString(),
      typeName: json['type_name']?.toString(),
      doubanId: json['douban_id'] is int ? json['douban_id'] : null,
      remarks: json['remarks']?.toString(),
      resolution: json['resolution']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'poster': poster,
      'episodes': episodes,
      'episodes_titles': episodesTitles,
      'source': source,
      'source_name': sourceName,
      'class': class_,
      'year': year,
      'desc': desc,
      'type_name': typeName,
      'douban_id': doubanId,
      'remarks': remarks,
      'resolution': resolution,
    };
  }

  SearchResult copyWith({
    String? id,
    String? title,
    String? poster,
    List<String>? episodes,
    List<String>? episodesTitles,
    String? source,
    String? sourceName,
    String? class_,
    String? year,
    String? desc,
    String? typeName,
    int? doubanId,
    String? remarks,
    String? resolution,
  }) {
    return SearchResult(
      id: id ?? this.id,
      title: title ?? this.title,
      poster: poster ?? this.poster,
      episodes: episodes ?? this.episodes,
      episodesTitles: episodesTitles ?? this.episodesTitles,
      source: source ?? this.source,
      sourceName: sourceName ?? this.sourceName,
      class_: class_ ?? this.class_,
      year: year ?? this.year,
      desc: desc ?? this.desc,
      typeName: typeName ?? this.typeName,
      doubanId: doubanId ?? this.doubanId,
      remarks: remarks ?? this.remarks,
      resolution: resolution ?? this.resolution,
    );
  }

  String get displayType => typeName ?? class_ ?? '未知';

  String get episodeInfo => episodes.isEmpty ? '' : '共${episodes.length}集';

  String get yearInfo => year.isNotEmpty ? year : '未知年份';
}
