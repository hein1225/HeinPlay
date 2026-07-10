class BangumiCalendarItem {
  final int id;
  final String title;
  final String? poster;
  final String? year;
  final String? rate;
  final String? airDate;
  final int? airWeekday;
  final String? summary;

  const BangumiCalendarItem({
    required this.id,
    required this.title,
    this.poster,
    this.year,
    this.rate,
    this.airDate,
    this.airWeekday,
    this.summary,
  });

  factory BangumiCalendarItem.fromJson(Map<String, dynamic> json) {
    String? pickPoster() {
      final images = json['images'] as Map<String, dynamic>?;
      if (images == null) return null;
      final url = images['large']?.toString() ??
          images['common']?.toString() ??
          images['medium']?.toString() ??
          images['small']?.toString() ??
          images['grid']?.toString();
      if (url == null || url.isEmpty) return null;
      if (url.startsWith('//')) return 'https:$url';
      return url;
    }

    String? pickYear() {
      final date = json['air_date']?.toString() ?? json['date']?.toString();
      if (date == null || date.isEmpty) return null;
      final match = RegExp(r'(\d{4})').firstMatch(date);
      return match?.group(1);
    }

    String? pickRate() {
      final rating = json['rating'] as Map<String, dynamic>?;
      final score = rating?['score'];
      if (score == null) return null;
      if (score is num) {
        final value = score.toStringAsFixed(1);
        return value == '0.0' ? null : value;
      }
      final value = score.toString();
      return value == '0' || value == '0.0' ? null : value;
    }

    return BangumiCalendarItem(
      id: json['id'] is int ? json['id'] : int.tryParse(json['id']?.toString() ?? '0') ?? 0,
      title: json['name_cn']?.toString() ?? json['name']?.toString() ?? '',
      poster: pickPoster(),
      year: pickYear(),
      rate: pickRate(),
      airDate: json['air_date']?.toString(),
      airWeekday: json['air_weekday'] is int
          ? json['air_weekday']
          : int.tryParse(json['air_weekday']?.toString() ?? ''),
      summary: json['summary']?.toString(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name_cn': title,
      'images': {'large': poster},
      'air_date': airDate,
      'air_weekday': airWeekday,
      'rating': {'score': rate},
      'summary': summary,
    };
  }
}
