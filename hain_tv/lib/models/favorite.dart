class Favorite {
  final String source;
  final String id;
  final String title;
  final String cover;
  final String sourceName;
  final String? typeName;
  final int? saveTime;

  Favorite({
    required this.source,
    required this.id,
    required this.title,
    required this.cover,
    required this.sourceName,
    this.typeName,
    this.saveTime,
  });

  factory Favorite.fromJson(String key, Map<String, dynamic> json) {
    final parts = key.split('+');
    return Favorite(
      source: parts.isNotEmpty ? parts[0] : '',
      id: parts.length > 1 ? parts[1] : '',
      title: json['title'] as String? ?? '',
      cover: json['cover'] as String? ?? '',
      sourceName: json['source_name'] as String? ?? '',
      typeName: json['type_name'] as String?,
      saveTime: (json['save_time'] as num?)?.toInt(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'title': title,
      'cover': cover,
      'source_name': sourceName,
      if (typeName != null) 'type_name': typeName,
    };
  }
}
