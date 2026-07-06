class ShortDrama {
  final int id;
  final String name;
  final String cover;
  final String updateTime;
  final double score;
  final int episodeCount;
  final String? description;
  final String? author;
  final String? backdrop;
  final double? voteAverage;
  final int? tmdbId;

  ShortDrama({
    required this.id,
    required this.name,
    required this.cover,
    required this.updateTime,
    required this.score,
    required this.episodeCount,
    this.description,
    this.author,
    this.backdrop,
    this.voteAverage,
    this.tmdbId,
  });

  factory ShortDrama.fromJson(Map<String, dynamic> json) {
    return ShortDrama(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      name: json['name']?.toString() ?? '',
      cover: json['cover']?.toString() ?? '',
      updateTime: json['update_time']?.toString() ?? '',
      score: (json['score'] as num?)?.toDouble() ?? 0,
      episodeCount: json['episode_count'] is int
          ? json['episode_count']
          : int.tryParse(json['episode_count']?.toString() ?? '1') ?? 1,
      description: json['description']?.toString(),
      author: json['author']?.toString(),
      backdrop: json['backdrop']?.toString(),
      voteAverage: (json['vote_average'] as num?)?.toDouble(),
      tmdbId: json['tmdb_id'] is int ? json['tmdb_id'] : null,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'cover': cover,
      'update_time': updateTime,
      'score': score,
      'episode_count': episodeCount,
      'description': description,
      'author': author,
      'backdrop': backdrop,
      'vote_average': voteAverage,
      'tmdb_id': tmdbId,
    };
  }
}
