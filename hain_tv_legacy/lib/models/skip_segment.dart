class SkipSegment {
  final double start;
  final double end;
  final String type;
  final String? title;
  final bool autoSkip;
  final bool autoNextEpisode;
  final String mode;
  final double? remainingTime;

  SkipSegment({
    required this.start,
    required this.end,
    required this.type,
    this.title,
    this.autoSkip = true,
    this.autoNextEpisode = true,
    this.mode = 'absolute',
    this.remainingTime,
  });

  factory SkipSegment.fromJson(Map<String, dynamic> json) {
    return SkipSegment(
      start: (json['start'] as num?)?.toDouble() ?? 0,
      end: (json['end'] as num?)?.toDouble() ?? 0,
      type: json['type']?.toString() ?? 'opening',
      title: json['title']?.toString(),
      autoSkip: json['autoSkip'] == true,
      autoNextEpisode: json['autoNextEpisode'] == true,
      mode: json['mode']?.toString() ?? 'absolute',
      remainingTime: (json['remainingTime'] as num?)?.toDouble(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'start': start,
      'end': end,
      'type': type,
      'title': title,
      'autoSkip': autoSkip,
      'autoNextEpisode': autoNextEpisode,
      'mode': mode,
      'remainingTime': remainingTime,
    };
  }

  SkipSegment copyWith({
    double? start,
    double? end,
    String? type,
    String? title,
    bool? autoSkip,
    bool? autoNextEpisode,
    String? mode,
    double? remainingTime,
  }) {
    return SkipSegment(
      start: start ?? this.start,
      end: end ?? this.end,
      type: type ?? this.type,
      title: title ?? this.title,
      autoSkip: autoSkip ?? this.autoSkip,
      autoNextEpisode: autoNextEpisode ?? this.autoNextEpisode,
      mode: mode ?? this.mode,
      remainingTime: remainingTime ?? this.remainingTime,
    );
  }
}

class EpisodeSkipConfig {
  final String source;
  final String id;
  final String title;
  final List<SkipSegment> segments;
  final int updatedTime;

  EpisodeSkipConfig({
    required this.source,
    required this.id,
    required this.title,
    required this.segments,
    required this.updatedTime,
  });

  factory EpisodeSkipConfig.fromJson(Map<String, dynamic> json) {
    return EpisodeSkipConfig(
      source: json['source']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      segments: (json['segments'] as List<dynamic>? ?? [])
          .map((s) => SkipSegment.fromJson(s as Map<String, dynamic>))
          .toList(),
      updatedTime: json['updated_time'] is int
          ? json['updated_time']
          : int.tryParse(json['updated_time']?.toString() ?? '0') ?? 0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'id': id,
      'title': title,
      'segments': segments.map((s) => s.toJson()).toList(),
      'updated_time': updatedTime,
    };
  }
}
