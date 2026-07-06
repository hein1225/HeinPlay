class VideoDetail {
  final String source;
  final String sourceName;
  final String id;
  final String title;
  final String poster;
  final String year;
  final int? doubanId;
  final String? desc;
  final List<String> episodes;
  final List<String> episodesTitles;
  final bool proxyMode;

  VideoDetail({
    required this.source,
    required this.sourceName,
    required this.id,
    required this.title,
    required this.poster,
    required this.year,
    this.doubanId,
    this.desc,
    required this.episodes,
    required this.episodesTitles,
    this.proxyMode = false,
  });

  factory VideoDetail.fromJson(Map<String, dynamic> json) {
    return VideoDetail(
      source: json['source']?.toString() ?? '',
      sourceName: json['source_name']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: json['poster']?.toString() ?? '',
      year: json['year']?.toString() ?? '',
      doubanId: json['douban_id'] is int ? json['douban_id'] : null,
      desc: json['desc']?.toString(),
      episodes: json['episodes'] != null
          ? List<String>.from(json['episodes'])
          : [],
      episodesTitles: json['episodes_titles'] != null
          ? List<String>.from(json['episodes_titles'])
          : [],
      proxyMode: json['proxyMode'] == true,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'source_name': sourceName,
      'id': id,
      'title': title,
      'poster': poster,
      'year': year,
      'douban_id': doubanId,
      'desc': desc,
      'episodes': episodes,
      'episodes_titles': episodesTitles,
      'proxyMode': proxyMode,
    };
  }
}
