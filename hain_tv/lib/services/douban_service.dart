import 'dart:convert';
import 'dart:math';
import 'package:http/http.dart' as http;
import '../models/api_response.dart';
import '../models/douban_movie.dart';
import '../models/douban_recommends_params.dart';
import 'cache_service.dart';
import 'user_data_service.dart';

const Map<String, String> doubanHeaders = {
  'User-Agent': 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
  'Referer': 'https://movie.douban.com/',
  'Accept': 'application/json, text/plain, */*',
};

class DoubanService {
  static final CacheService _cacheService = CacheService();
  static bool _cacheInitialized = false;
  static String? _uniqueOrigin;

  static String _getUniqueOrigin() {
    _uniqueOrigin ??= () {
      final random = Random();
      final domains = ['movie.douban.com', 'm.douban.com', 'www.douban.com'];
      final subdomains = ['app', 'mobile', 'client', 'api', 'web'];
      final baseDomain = domains[random.nextInt(domains.length)];
      final subdomain = subdomains[random.nextInt(subdomains.length)];
      final randomId = random.nextInt(9999).toString().padLeft(4, '0');
      return 'https://$subdomain$randomId.$baseDomain';
    }();
    return _uniqueOrigin!;
  }

  static Future<void> _initCache() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }

  static Future<String> _baseUrl() async {
    final source = await UserDataService.getDoubanDataSource();
    switch (source) {
      case DoubanDataSource.cdnTencent:
        return 'https://m.douban.cmliussss.net';
      case DoubanDataSource.cdnAliyun:
        return 'https://m.douban.cmliussss.com';
      case DoubanDataSource.direct:
      case DoubanDataSource.corsProxy:
        return 'https://m.douban.com';
    }
  }

  static Future<String> _resolveUrl(String target) async {
    final source = await UserDataService.getDoubanDataSource();
    if (source == DoubanDataSource.corsProxy) {
      return 'https://ciao-cors.is-an.org/${Uri.encodeComponent(target)}';
    }
    return target;
  }

  static Future<Map<String, String>> _headers() async {
    final source = await UserDataService.getDoubanDataSource();
    final headers = Map<String, String>.from(doubanHeaders);
    if (source == DoubanDataSource.corsProxy) {
      headers['Origin'] = _getUniqueOrigin();
    }
    return headers;
  }

  static Future<ApiResponse<List<DoubanMovie>>> getCategoryData({
    required String kind,
    required String category,
    required String type,
    int pageLimit = 25,
    int page = 0,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateDoubanCategoryCacheKey(
      kind: kind,
      category: category,
      type: type,
      pageLimit: pageLimit,
      page: page,
    );

    final cached = await _cacheService.get<List<DoubanMovie>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((m) => DoubanMovie.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    final base = await _baseUrl();
    final queryParams = <String, String>{
      'start': '${page * pageLimit}',
      'limit': '$pageLimit',
    };

    // 豆瓣 recent_hot 始终使用独立的 category/type 查询参数
    if (category.isNotEmpty && category != '全部') {
      queryParams['category'] = category;
    }
    if (type.isNotEmpty && type != '全部') {
      queryParams['type'] = type;
    }

    var apiUrl = Uri.parse('$base/rexxar/api/v2/subject/recent_hot/$kind')
        .replace(queryParameters: queryParams)
        .toString();
    apiUrl = await _resolveUrl(apiUrl);

    try {
      final response = await http
          .get(Uri.parse(apiUrl), headers: await _headers())
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final items = DoubanResponse.fromJson(data).items;
        await _cacheService.set(
          cacheKey,
          items.map((e) => e.toJson()).toList(),
          const Duration(hours: 24),
        );
        return ApiResponse.success(items, statusCode: response.statusCode);
      }
      return ApiResponse.error('获取豆瓣数据失败: ${response.statusCode}', statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('豆瓣数据请求异常: $e');
    }
  }

  /// 通过 LunaTV 后端的 /api/douban 代理获取豆瓣“热门”数据。
  /// 后端实际调用的是 `https://movie.douban.com/j/search_subjects?sort=recommend`，
  /// 该接口返回的内容与豆瓣网站“热门”标签页一致，比 recent_hot 更准确。
  /// 当未配置服务器或代理失败时，自动回退到 [getCategoryData]（recent_hot）。
  static Future<ApiResponse<List<DoubanMovie>>> getHotDataFromServer({
    required String type,
    required String tag,
    int pageSize = 18,
    int pageStart = 0,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateDoubanHotCacheKey(
      type: type,
      tag: tag,
      pageSize: pageSize,
      pageStart: pageStart,
    );

    final cached = await _cacheService.get<List<DoubanMovie>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((m) => DoubanMovie.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    final serverUrl = await UserDataService.getServerUrl();
    if (serverUrl == null || serverUrl.trim().isEmpty) {
      return _fallbackToRecentHot(type: type, tag: tag, pageSize: pageSize, pageStart: pageStart);
    }

    final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    final apiUrl = Uri.parse('$base/api/douban').replace(queryParameters: {
      'type': type,
      'tag': tag,
      'pageSize': pageSize.toString(),
      'pageStart': pageStart.toString(),
    }).toString();

    try {
      final response = await http
          .get(Uri.parse(apiUrl), headers: await _headers())
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final listData = data['list'] as List<dynamic>? ?? [];
        final items = listData
            .map((item) => DoubanMovie.fromJson(item as Map<String, dynamic>))
            .toList();
        await _cacheService.set(
          cacheKey,
          items.map((e) => e.toJson()).toList(),
          const Duration(hours: 24),
        );
        return ApiResponse.success(items, statusCode: response.statusCode);
      }
      return _fallbackToRecentHot(type: type, tag: tag, pageSize: pageSize, pageStart: pageStart);
    } catch (e) {
      return _fallbackToRecentHot(type: type, tag: tag, pageSize: pageSize, pageStart: pageStart);
    }
  }

  static Future<ApiResponse<List<DoubanMovie>>> _fallbackToRecentHot({
    required String type,
    required String tag,
    required int pageSize,
    required int pageStart,
  }) async {
    final mapping = _hotTagToRecentHot(type: type, tag: tag);
    return getCategoryData(
      kind: mapping.kind,
      category: mapping.category,
      type: mapping.type,
      pageLimit: pageSize,
      page: pageStart ~/ pageSize,
    );
  }

  static ({String kind, String category, String type}) _hotTagToRecentHot({
    required String type,
    required String tag,
  }) {
    if (type == 'movie') {
      return (kind: 'movie', category: '热门', type: '全部');
    }
    if (tag == '综艺') {
      return (kind: 'tv', category: 'show', type: 'show');
    }
    if (tag == '日本动画' || tag == '动画') {
      return (kind: 'tv', category: '热门', type: 'tv_animation');
    }
    // 电视剧默认
    return (kind: 'tv', category: '最近热门', type: 'tv');
  }

  static Future<ApiResponse<List<DoubanMovie>>> getHotMovies({
    int pageLimit = 18,
    int page = 0,
  }) async {
    return getHotDataFromServer(
      type: 'movie',
      tag: '热门',
      pageSize: pageLimit,
      pageStart: page * pageLimit,
    );
  }

  static Future<ApiResponse<List<DoubanMovie>>> getHotTvShows({
    int pageLimit = 18,
    int page = 0,
  }) async {
    return getHotDataFromServer(
      type: 'tv',
      tag: '热门',
      pageSize: pageLimit,
      pageStart: page * pageLimit,
    );
  }

  static Future<ApiResponse<List<DoubanMovie>>> getHotShows({
    int pageLimit = 18,
    int page = 0,
  }) async {
    return getHotDataFromServer(
      type: 'tv',
      tag: '综艺',
      pageSize: pageLimit,
      pageStart: page * pageLimit,
    );
  }

  static Future<ApiResponse<List<DoubanMovie>>> getHotAnimes({
    int pageLimit = 18,
    int page = 0,
  }) async {
    return getHotDataFromServer(
      type: 'tv',
      tag: '日本动画',
      pageSize: pageLimit,
      pageStart: page * pageLimit,
    );
  }

  static Future<ApiResponse<List<DoubanMovie>>> fetchRecommends({
    required DoubanRecommendsParams params,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateDoubanRecommendsCacheKey(
      kind: params.kind,
      category: params.category,
      format: params.format,
      region: params.region,
      year: params.year,
      platform: params.platform,
      sort: params.sort,
      label: params.label,
      pageLimit: params.pageLimit,
      page: params.page,
    );

    final cached = await _cacheService.get<List<DoubanMovie>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((m) => DoubanMovie.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    String category = params.category == 'all' ? '' : params.category;
    String format = params.format == 'all' ? '' : params.format;
    String region = params.region == 'all' ? '' : params.region;
    String year = params.year == 'all' ? '' : params.year;
    String platform = params.platform == 'all' ? '' : params.platform;
    String label = params.label == 'all' ? '' : params.label;
    // 排序参数：T=综合排序，U=近期热度，R=首映/首播时间，S=高分优先
    String sort = params.sort == 'all' ? '' : params.sort;

    // 动漫分类特殊处理：当分类是地区名称时，将其作为地区筛选
    final regions = ['中国大陆', '美国', '日本', '韩国', '中国香港', '中国台湾', '英国', '法国', '德国'];
    if (format == '动画' && regions.contains(category)) {
      // 动漫分类下，把地区名称从category移到region
      region = category;
      category = '';
    }

    final selectedCategories = <String, dynamic>{};
    if (category.isNotEmpty) selectedCategories['类型'] = category;
    if (format.isNotEmpty) selectedCategories['形式'] = format;
    if (region.isNotEmpty) selectedCategories['地区'] = region;

    final tags = <String>[];
    if (category.isNotEmpty) tags.add(category);
    if (format.isNotEmpty) tags.add(format);
    if (label.isNotEmpty) tags.add(label);
    if (region.isNotEmpty) tags.add(region);
    if (year.isNotEmpty) tags.add(year);
    if (platform.isNotEmpty) tags.add(platform);

    final base = await _baseUrl();
    final queryParams = <String, String>{
      'refresh': '0',
      'start': (params.page * params.pageLimit).toString(),
      'count': params.pageLimit.toString(),
      'selected_categories': json.encode(selectedCategories),
      'uncollect': 'false',
      'score_range': '0,10',
      'tags': tags.join(','),
    };
    if (sort.isNotEmpty) queryParams['sort'] = sort;

    var apiUrl = Uri.parse('$base/rexxar/api/v2/${params.kind}/recommend')
        .replace(queryParameters: queryParams)
        .toString();
    apiUrl = await _resolveUrl(apiUrl);

    try {
      final response = await http
          .get(Uri.parse(apiUrl), headers: await _headers())
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final itemsData = data['items'] as List<dynamic>? ?? [];
        final items = itemsData
            .where((item) => item['type'] == 'movie' || item['type'] == 'tv')
            .map((item) => DoubanMovie.fromJson(item as Map<String, dynamic>))
            .toList();
        await _cacheService.set(
          cacheKey,
          items.map((e) => e.toJson()).toList(),
          const Duration(hours: 24),
        );
        return ApiResponse.success(items, statusCode: response.statusCode);
      }
      return ApiResponse.error('获取豆瓣推荐失败: ${response.statusCode}', statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('豆瓣推荐请求异常: $e');
    }
  }

  static Future<ApiResponse<DoubanMovieDetails>> getDetails({
    required String doubanId,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateDoubanDetailsCacheKey(doubanId: doubanId);

    final cached = await _cacheService.get<DoubanMovieDetails>(
      cacheKey,
      (raw) => DoubanMovieDetails.fromJson(raw as Map<String, dynamic>),
    );
    if (cached != null && cached.title.trim().isNotEmpty) {
      return ApiResponse.success(cached);
    }
    if (cached != null) await _cacheService.delete(cacheKey);

    final base = await _baseUrl();
    var apiUrl = '$base/rexxar/api/v2/subject/$doubanId';
    apiUrl = await _resolveUrl(apiUrl);

    try {
      final response = await http
          .get(Uri.parse(apiUrl), headers: await _headers())
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (data is! Map<String, dynamic>) {
          return ApiResponse.error('豆瓣详情数据格式错误');
        }
        final details = DoubanMovieDetails.fromJson(data);
        if (details.title.trim().isEmpty) {
          return ApiResponse.error('豆瓣详情数据解析为空');
        }
        await _cacheService.set(
          cacheKey,
          details.toJson(),
          const Duration(days: 3),
        );
        return ApiResponse.success(details, statusCode: response.statusCode);
      }
      return ApiResponse.error('获取豆瓣详情失败: ${response.statusCode}', statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('豆瓣详情请求异常: $e');
    }
  }

  static Future<ApiResponse<List<DoubanMovie>>> search({
    required String keyword,
    int limit = 10,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateDoubanSearchCacheKey(
      keyword: keyword,
      limit: limit,
    );

    final cached = await _cacheService.get<List<DoubanMovie>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((m) => DoubanMovie.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    final base = await _baseUrl();
    var apiUrl =
        '$base/rexxar/api/v2/search?q=${Uri.encodeComponent(keyword)}&count=$limit';
    apiUrl = await _resolveUrl(apiUrl);

    try {
      final response = await http
          .get(Uri.parse(apiUrl), headers: await _headers())
          .timeout(const Duration(seconds: 30));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final itemsData = data['items'] as List<dynamic>? ?? [];
        final items = itemsData
            .where((item) => item['type'] == 'movie' || item['type'] == 'tv')
            .map((item) => DoubanMovie.fromJson(item as Map<String, dynamic>))
            .toList();
        await _cacheService.set(
          cacheKey,
          items.map((e) => e.toJson()).toList(),
          const Duration(minutes: 30),
        );
        return ApiResponse.success(items, statusCode: response.statusCode);
      }
      return ApiResponse.error('豆瓣搜索失败: ${response.statusCode}', statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('豆瓣搜索异常: $e');
    }
  }
}


