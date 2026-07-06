class VideoInfo {
  final String id;
  final String source;
  final String title;
  final String sourceName;
  final String year;
  final String cover;
  final int index;
  final int totalEpisodes;
  final int playTime;
  final int totalTime;
  final int saveTime;
  final String searchTitle;
  final String? doubanId;
  final String? rate;

  VideoInfo({
    required this.id,
    required this.source,
    required this.title,
    required this.sourceName,
    required this.year,
    required this.cover,
    required this.index,
    required this.totalEpisodes,
    required this.playTime,
    required this.totalTime,
    required this.saveTime,
    required this.searchTitle,
    this.doubanId,
    this.rate,
  });

  factory VideoInfo.fromJson(Map<String, dynamic> json) {
    return VideoInfo(
      id: json['id']?.toString() ?? '',
      source: json['source']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      sourceName: json['source_name']?.toString() ?? '',
      year: json['year']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      index: json['index'] is int ? json['index'] : int.tryParse(json['index']?.toString() ?? '1') ?? 1,
      totalEpisodes: json['total_episodes'] is int
          ? json['total_episodes']
          : int.tryParse(json['total_episodes']?.toString() ?? '1') ?? 1,
      playTime: json['play_time'] is int
          ? json['play_time']
          : int.tryParse(json['play_time']?.toString() ?? '0') ?? 0,
      totalTime: json['total_time'] is int
          ? json['total_time']
          : int.tryParse(json['total_time']?.toString() ?? '0') ?? 0,
      saveTime: json['save_time'] is int
          ? json['save_time']
          : int.tryParse(json['save_time']?.toString() ?? '0') ?? 0,
      searchTitle: json['search_title']?.toString() ?? '',
      doubanId: json['douban_id']?.toString(),
      rate: json['rate']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'source': source,
      'title': title,
      'source_name': sourceName,
      'year': year,
      'cover': cover,
      'index': index,
      'total_episodes': totalEpisodes,
      'play_time': playTime,
      'total_time': totalTime,
      'save_time': saveTime,
      'search_title': searchTitle,
      'douban_id': doubanId,
      'rate': rate,
    };
  }
}
