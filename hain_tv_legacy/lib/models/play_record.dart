class PlayRecord {
  final String id;
  final String source;
  final String title;
  final String sourceName;
  final String cover;
  final String year;
  final int index;
  final int totalEpisodes;
  final int playTime;
  final int totalTime;
  final int saveTime;
  final String searchTitle;
  final String? remarks;
  final String? doubanId;
  final String? type;

  PlayRecord({
    required this.id,
    required this.source,
    required this.title,
    required this.sourceName,
    required this.cover,
    required this.year,
    required this.index,
    required this.totalEpisodes,
    required this.playTime,
    required this.totalTime,
    required this.saveTime,
    required this.searchTitle,
    this.remarks,
    this.doubanId,
    this.type,
  });

  /// 从后端返回的 key-value 格式创建，key 格式为 "source+id"
  factory PlayRecord.fromJson(String key, Map<String, dynamic> json) {
    final parts = key.split('+');
    final source = parts.length > 1 ? parts[0] : '';
    final id = parts.length > 1 ? parts[1] : key;

    return PlayRecord(
      id: id,
      source: source,
      title: json['title']?.toString() ?? '',
      sourceName:
          json['source_name']?.toString() ?? json['source']?.toString() ?? '',
      cover: json['cover']?.toString() ?? json['posterUrl']?.toString() ?? '',
      year: json['year']?.toString() ?? '',
      index: json['index'] is int
          ? json['index']
          : int.tryParse(
                  json['index']?.toString() ??
                      json['episodeIndex']?.toString() ??
                      '1',
                ) ??
                1,
      totalEpisodes: json['total_episodes'] is int
          ? json['total_episodes']
          : int.tryParse(json['total_episodes']?.toString() ?? '1') ?? 1,
      playTime: json['play_time'] is int
          ? json['play_time']
          : int.tryParse(
                  json['play_time']?.toString() ??
                      json['progress']?.toString() ??
                      '0',
                ) ??
                0,
      totalTime: json['total_time'] is int
          ? json['total_time']
          : int.tryParse(json['total_time']?.toString() ?? '0') ?? 0,
      saveTime: json['save_time'] is int
          ? json['save_time']
          : int.tryParse(json['save_time']?.toString() ?? '0') ?? 0,
      searchTitle:
          json['search_title']?.toString() ?? json['title']?.toString() ?? '',
      remarks: json['remarks']?.toString(),
      doubanId: json['douban_id']?.toString(),
      type: json['type']?.toString(),
    );
  }

  /// 本地存储格式
  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'source_name': sourceName,
      'cover': cover,
      'year': year,
      'index': index,
      'total_episodes': totalEpisodes,
      'play_time': playTime,
      'total_time': totalTime,
      'save_time': saveTime,
      'search_title': searchTitle,
      'remarks': remarks,
      'douban_id': doubanId,
      'type': type,
    };
  }

  /// LunaTV 后端需要的格式
  Map<String, dynamic> toLunaTvJson() {
    return {
      'title': title,
      'posterUrl': cover,
      'episodeIndex': index,
      'progress': playTime,
      'saveTime': saveTime,
      if (doubanId != null) 'douban_id': doubanId,
      if (year.isNotEmpty) 'year': year,
    };
  }

  PlayRecord copyWith({
    String? id,
    String? source,
    String? title,
    String? sourceName,
    String? cover,
    String? year,
    int? index,
    int? totalEpisodes,
    int? playTime,
    int? totalTime,
    int? saveTime,
    String? searchTitle,
    String? remarks,
    String? doubanId,
    String? type,
  }) {
    return PlayRecord(
      id: id ?? this.id,
      source: source ?? this.source,
      title: title ?? this.title,
      sourceName: sourceName ?? this.sourceName,
      cover: cover ?? this.cover,
      year: year ?? this.year,
      index: index ?? this.index,
      totalEpisodes: totalEpisodes ?? this.totalEpisodes,
      playTime: playTime ?? this.playTime,
      totalTime: totalTime ?? this.totalTime,
      saveTime: saveTime ?? this.saveTime,
      searchTitle: searchTitle ?? this.searchTitle,
      remarks: remarks ?? this.remarks,
      doubanId: doubanId ?? this.doubanId,
      type: type ?? this.type,
    );
  }
}
