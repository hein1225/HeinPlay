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
      resolution: _parseResolution(json),
    );
  }

  /// 优先读取 `resolution`，兼容 `quality/definition/video_quality/清晰度` 等常见字段，
  /// 并把 `1080p/720P` 等规范化成大写 P 的格式。
  /// 同时从多个字段拼接文本，使用多字段推断，提高识别率。
  static String? _parseResolution(Map<String, dynamic> json) {
    // 1. 先尝试明确字段。
    const explicitKeys = [
      'resolution',
      'quality',
      'definition',
      'video_quality',
      'video_type',
      'format',
      '清晰度',
      'resolution_name',
      'label',
    ];
    for (final key in explicitKeys) {
      final value = json[key]?.toString().trim();
      if (value != null && value.isNotEmpty) {
        final normalized = _normalizeResolution(value);
        if (normalized != null) return normalized;
      }
    }

    // 2. 多字段拼接推断。
    final text = _collectResolutionText(json);
    if (text.isNotEmpty) {
      return _inferResolutionFromText(text);
    }
    return null;
  }

  /// 收集可能包含分辨率信息的字段文本。
  static String _collectResolutionText(Map<String, dynamic> json) {
    final buffer = StringBuffer();
    const keys = [
      'title',
      'remarks',
      'desc',
      'class',
      'type_name',
      'source_name',
      'quality_tag',
    ];
    for (final key in keys) {
      final value = json[key];
      if (value != null) {
        buffer.write(' ${value.toString()}');
      }
    }
    final episodes = json['episodes'];
    if (episodes is List) {
      buffer.write(' ${episodes.take(3).join(' ')}');
    }
    return buffer.toString();
  }

  /// 从多字段文本中推断分辨率。
  static String? _inferResolutionFromText(String text) {
    final normalized = text.toLowerCase();

    // 维度模式：如 1920x1080、1280x720。
    final dimensionRe = RegExp(
      r'(?:^|[^0-9])(?:3840|2560|1920|1280|854|640)\s*[x×]\s*(2160|1440|1080|720|480|360)(?:$|[^0-9])',
    );
    int? bestHeight;
    for (final m in dimensionRe.allMatches(normalized)) {
      final h = int.tryParse(m.group(1)!);
      if (h != null && (bestHeight == null || h > bestHeight)) {
        bestHeight = h;
      }
    }

    // 像素模式：1080p、720P、2160i 等。
    final pixelRe = RegExp(
      r'(?:^|[^a-zA-Z0-9])(\d{3,4})\s*[pi](?:[^a-zA-Z0-9]|$)',
    );
    for (final m in pixelRe.allMatches(normalized)) {
      final h = int.tryParse(m.group(1)!);
      if (h != null && h > 240 && (bestHeight == null || h > bestHeight)) {
        bestHeight = h;
      }
    }

    // 常见别名。
    if (RegExp(r'(?:^|[^a-z0-9])(?:4k|uhd|ultrahd|ultra\s*hd)(?:$|[^a-z0-9])')
        .hasMatch(normalized)) {
      bestHeight = _max(bestHeight, 2160);
    }
    if (RegExp(r'(?:^|[^a-z0-9])(?:2k|qhd)(?:$|[^a-z0-9])').hasMatch(normalized)) {
      bestHeight = _max(bestHeight, 1440);
    }
    if (RegExp(r'(?:^|[^a-z0-9])(?:fhd|fullhd|full\s*hd)(?:$|[^a-z0-9])')
        .hasMatch(normalized)) {
      bestHeight = _max(bestHeight, 1080);
    }
    if (RegExp(r'(?:^|[^a-z0-9])hd(?:$|[^a-z0-9])').hasMatch(normalized)) {
      bestHeight = _max(bestHeight, 720);
    }
    if (RegExp(r'(?:^|[^a-z0-9])sd(?:$|[^a-z0-9])').hasMatch(normalized)) {
      bestHeight = _max(bestHeight, 480);
    }

    // 中文清晰度描述。
    if (RegExp(r'蓝光|超清').hasMatch(text)) bestHeight = _max(bestHeight, 1080);
    if (RegExp(r'高清').hasMatch(text)) bestHeight = _max(bestHeight, 720);
    if (RegExp(r'标清').hasMatch(text)) bestHeight = _max(bestHeight, 480);
    if (RegExp(r'枪版|(?:^|[^a-z0-9])(?:cam|tc|ts)(?:$|[^a-z0-9])')
        .hasMatch(normalized)) {
      bestHeight = _max(bestHeight, 360);
    }

    if (bestHeight == null) return null;
    return _heightToLabel(bestHeight);
  }

  static int? _max(int? a, int b) {
    if (a == null || b > a) return b;
    return a;
  }

  static String? _normalizeResolution(String raw) {
    final lower = raw.toLowerCase();
    if (lower.contains('4k')) return '4K';
    if (lower.contains('2k')) return '2K';
    final match = RegExp(r'(\d{3,4})\s*[pi]').firstMatch(lower);
    if (match != null) {
      final h = int.tryParse(match.group(1)!);
      if (h != null) {
        return _heightToLabel(h);
      }
    }
    return null;
  }

  static String _heightToLabel(int height) {
    if (height >= 2160) return '4K';
    if (height >= 1440) return '2K';
    if (height >= 1080) return '1080P';
    if (height >= 720) return '720P';
    if (height >= 480) return '480P';
    if (height >= 360) return '360P';
    return '${height}P';
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
