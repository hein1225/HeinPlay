class DoubanRecommendItem {
  final String id;
  final String title;
  final String poster;
  final String? rate;

  const DoubanRecommendItem({
    required this.id,
    required this.title,
    required this.poster,
    this.rate,
  });

  factory DoubanRecommendItem.fromJson(Map<String, dynamic> json) {
    return DoubanRecommendItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: json['poster']?.toString() ?? '',
      rate: json['rate']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {'id': id, 'title': title, 'poster': poster, 'rate': rate};
  }
}

class DoubanMovieDetails {
  final String id;
  final String title;
  final String poster;
  final String? rate;
  final String year;
  final String? summary;
  final List<String> genres;
  final List<String> directors;
  final List<String> screenwriters;
  final List<String> actors;
  final String? duration;
  final List<String> countries;
  final List<String> languages;
  final String? releaseDate;
  final String? originalTitle;
  final String? imdbId;
  final int? totalEpisodes;
  final List<DoubanRecommendItem> recommends;

  const DoubanMovieDetails({
    required this.id,
    required this.title,
    required this.poster,
    this.rate,
    required this.year,
    this.summary,
    this.genres = const [],
    this.directors = const [],
    this.screenwriters = const [],
    this.actors = const [],
    this.duration,
    this.countries = const [],
    this.languages = const [],
    this.releaseDate,
    this.originalTitle,
    this.imdbId,
    this.totalEpisodes,
    this.recommends = const [],
  });

  factory DoubanMovieDetails.fromJson(Map<String, dynamic> json) {
    String? nonEmptyString(dynamic value) {
      final stringValue = value?.toString().trim();
      if (stringValue == null || stringValue.isEmpty || stringValue == 'null') {
        return null;
      }
      return stringValue;
    }

    List<String> stringList(dynamic value) {
      if (value is List) {
        return value.map(nonEmptyString).whereType<String>().toList();
      }
      final singleValue = nonEmptyString(value);
      return singleValue == null ? <String>[] : <String>[singleValue];
    }

    List<String> nameList(dynamic value) {
      if (value is! List) return <String>[];
      return value
          .map((item) {
            if (item is Map<String, dynamic>) {
              return nonEmptyString(item['name']);
            }
            return nonEmptyString(item);
          })
          .whereType<String>()
          .toList();
    }

    int? parseInt(dynamic value) {
      if (value is int) return value;
      return int.tryParse(value?.toString() ?? '');
    }

    String poster = '';
    if (json['poster'] != null) {
      poster = json['poster']?.toString() ?? '';
    } else if (json['cover_url'] != null) {
      poster = json['cover_url']?.toString() ?? '';
    } else if (json['images'] != null) {
      final images = json['images'] as Map<String, dynamic>?;
      poster =
          images?['large']?.toString() ??
          images?['medium']?.toString() ??
          images?['small']?.toString() ??
          '';
    } else if (json['pic'] != null) {
      final pic = json['pic'] as Map<String, dynamic>?;
      poster =
          pic?['large']?.toString() ??
          pic?['normal']?.toString() ??
          pic?['medium']?.toString() ??
          pic?['small']?.toString() ??
          '';
    }
    if (poster.startsWith('//')) {
      poster = 'https:$poster';
    }

    String? rate = nonEmptyString(json['rate']);
    if (rate == null && json['rating'] != null) {
      final rating = json['rating'] as Map<String, dynamic>?;
      final value = rating?['average'] ?? rating?['value'];
      if (value != null) {
        if (value is num) {
          rate = value.toStringAsFixed(1);
        } else {
          rate = value.toString();
        }
      }
    }
    if (rate == '0' || rate == '0.0') rate = null;

    String year = json['year']?.toString() ?? '';
    if (year.isEmpty && json['pubdate'] != null) {
      final pubdate = stringList(json['pubdate']).join(' ');
      final yearMatch = RegExp(r'(\d{4})').firstMatch(pubdate);
      year = yearMatch?.group(1) ?? '';
    }

    final directors =
        json['directors'] is List &&
            (json['directors'] as List).any((item) => item is Map)
        ? nameList(json['directors'])
        : stringList(json['directors']);

    final screenwriters =
        json['screenwriters'] is List &&
            (json['screenwriters'] as List).any((item) => item is Map)
        ? nameList(json['screenwriters'])
        : stringList(json['screenwriters']);

    final actorsSource = json['actors'] ?? json['casts'];
    final actors =
        actorsSource is List && actorsSource.any((item) => item is Map)
        ? nameList(actorsSource)
        : stringList(actorsSource);

    final genres = stringList(json['genres']);
    final countries = stringList(json['countries']);
    final languages = stringList(json['languages']);

    List<DoubanRecommendItem> recommends = [];
    if (json['recommends'] != null) {
      final recommendsData = json['recommends'] as List<dynamic>? ?? [];
      recommends = recommendsData
          .map((r) => DoubanRecommendItem.fromJson(r as Map<String, dynamic>))
          .toList();
    }

    final totalEpisodes = parseInt(
      json['episodes_count'] ?? json['totalEpisodes'] ?? json['total_episodes'],
    );
    final pubdates = stringList(json['pubdate']);
    final durations = stringList(json['durations']);

    return DoubanMovieDetails(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: poster,
      rate: rate,
      year: year,
      summary: nonEmptyString(json['summary'] ?? json['intro']),
      genres: genres,
      directors: directors,
      screenwriters: screenwriters,
      actors: actors,
      duration:
          nonEmptyString(json['duration']) ??
          (durations.isNotEmpty ? durations.first : null),
      countries: countries,
      languages: languages,
      releaseDate:
          nonEmptyString(json['releaseDate']) ??
          (pubdates.isNotEmpty ? pubdates.first : null),
      originalTitle: nonEmptyString(
        json['originalTitle'] ?? json['original_title'],
      ),
      imdbId: nonEmptyString(json['imdbId'] ?? json['imdb']),
      totalEpisodes: totalEpisodes,
      recommends: recommends,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'poster': poster,
      'rate': rate,
      'year': year,
      'summary': summary,
      'genres': genres,
      'directors': directors,
      'screenwriters': screenwriters,
      'actors': actors,
      'duration': duration,
      'countries': countries,
      'languages': languages,
      'releaseDate': releaseDate,
      'originalTitle': originalTitle,
      'imdbId': imdbId,
      'totalEpisodes': totalEpisodes,
      'recommends': recommends.map((r) => r.toJson()).toList(),
    };
  }
}

class DoubanMovie {
  final String id;
  final String title;
  final String poster;
  final String? rate;
  final String year;

  const DoubanMovie({
    required this.id,
    required this.title,
    required this.poster,
    this.rate,
    required this.year,
  });

  factory DoubanMovie.fromJson(Map<String, dynamic> json) {
    // 兼容豆瓣 recommend API 的 target 包裹结构
    final data = json['target'] is Map<String, dynamic>
        ? json['target'] as Map<String, dynamic>
        : json;

    String? pickPoster() {
      String? url;
      if (data['poster'] != null) url = data['poster']?.toString();
      if (url == null && data['cover_url'] != null)
        url = data['cover_url']?.toString();
      if (url == null && data['cover'] != null) url = data['cover']?.toString();
      if (url == null && data['img'] != null) url = data['img']?.toString();
      if (url == null && data['thumb'] != null) url = data['thumb']?.toString();
      if (url == null && data['pic'] != null) {
        final pic = data['pic'] as Map<String, dynamic>?;
        url =
            pic?['normal']?.toString() ??
            pic?['large']?.toString() ??
            pic?['medium']?.toString() ??
            pic?['small']?.toString();
      }
      if (url == null && data['images'] != null) {
        final images = data['images'] as Map<String, dynamic>?;
        url =
            images?['large']?.toString() ??
            images?['medium']?.toString() ??
            images?['small']?.toString();
      }
      if (url != null && url.isNotEmpty) {
        if (url.startsWith('//')) url = 'https:$url';
        return url;
      }
      return null;
    }

    String? rate;
    if (data['rate'] != null) {
      rate = data['rate']?.toString();
    } else if (data['score'] != null) {
      final value = data['score'];
      rate = value is num ? value.toStringAsFixed(1) : value.toString();
    } else if (data['rating'] != null) {
      final rating = data['rating'] as Map<String, dynamic>?;
      final value = rating?['value'] ?? rating?['average'];
      if (value != null) {
        rate = value is num ? value.toStringAsFixed(1) : value.toString();
      }
    }
    if (rate == '0' || rate == '0.0') rate = null;

    String year = '';
    if (data['year'] != null) {
      year = data['year']?.toString() ?? '';
    }
    if (year.isEmpty && data['card_subtitle'] != null) {
      final cardSubtitle = data['card_subtitle']?.toString() ?? '';
      final yearMatch = RegExp(r'(\d{4})').firstMatch(cardSubtitle);
      year = yearMatch?.group(1) ?? '';
    }
    if (year.isEmpty && data['pubdate'] != null) {
      final pubdates = data['pubdate'];
      if (pubdates is List && pubdates.isNotEmpty) {
        final yearMatch = RegExp(
          r'(\d{4})',
        ).firstMatch(pubdates.first.toString());
        year = yearMatch?.group(1) ?? '';
      } else {
        final yearMatch = RegExp(r'(\d{4})').firstMatch(pubdates.toString());
        year = yearMatch?.group(1) ?? '';
      }
    }

    return DoubanMovie(
      id: data['id']?.toString() ?? '',
      title: data['title']?.toString() ?? '',
      poster: pickPoster() ?? '',
      rate: rate,
      year: year,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'poster': poster,
      'rate': rate,
      'year': year,
    };
  }
}

class DoubanResponse {
  final List<DoubanMovie> items;

  const DoubanResponse({required this.items});

  factory DoubanResponse.fromJson(Map<String, dynamic> json) {
    final itemsData = json['items'] as List<dynamic>? ?? [];
    return DoubanResponse(
      items: itemsData
          .map((item) => DoubanMovie.fromJson(item as Map<String, dynamic>))
          .toList(),
    );
  }
}
