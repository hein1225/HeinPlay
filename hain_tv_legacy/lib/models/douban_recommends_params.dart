class DoubanRecommendsParams {
  final String kind;
  final String category;
  final String format;
  final String region;
  final String year;
  final String platform;
  final String sort;
  final String label;
  final int pageLimit;
  final int page;

  const DoubanRecommendsParams({
    required this.kind,
    this.category = 'all',
    this.format = 'all',
    this.region = 'all',
    this.year = 'all',
    this.platform = 'all',
    this.sort = 'U',
    this.label = 'all',
    this.pageLimit = 30,
    this.page = 0,
  });

  DoubanRecommendsParams copyWith({
    String? kind,
    String? category,
    String? format,
    String? region,
    String? year,
    String? platform,
    String? sort,
    String? label,
    int? pageLimit,
    int? page,
  }) {
    return DoubanRecommendsParams(
      kind: kind ?? this.kind,
      category: category ?? this.category,
      format: format ?? this.format,
      region: region ?? this.region,
      year: year ?? this.year,
      platform: platform ?? this.platform,
      sort: sort ?? this.sort,
      label: label ?? this.label,
      pageLimit: pageLimit ?? this.pageLimit,
      page: page ?? this.page,
    );
  }
}
