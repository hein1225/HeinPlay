import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/api_response.dart';
import '../models/bangumi_calendar_item.dart';
import '../models/douban_movie.dart';
import 'cache_service.dart';
import 'user_data_service.dart';

class BangumiService {
  static final CacheService _cacheService = CacheService();
  static bool _cacheInitialized = false;

  static const String _cmliussssBase = 'https://img.doubanio.cmliussss.net';
  static const String _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

  static Future<void> _initCache() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }

  static Future<void> loadProxySettings() async {
    await UserDataService.reloadBangumiProxyCache();
  }

  static Future<String> _apiBaseUrl() async {
    final type = await UserDataService.getBangumiApiProxyType();
    switch (type) {
      case BangumiApiProxyType.cmliussss:
        return _cmliussssBase;
      case BangumiApiProxyType.custom:
        final url = await UserDataService.getBangumiApiProxyUrl();
        return url.trim().replaceAll(RegExp(r'/+$'), '');
      case BangumiApiProxyType.direct:
        return 'https://api.bgm.tv';
    }
  }

  /// 获取 Bangumi 每日放送数据，按星期分组返回。
  static Future<ApiResponse<List<BangumiCalendarItem>>> getCalendar() async {
    await _initCache();
    const cacheKey = 'bangumi_calendar';

    final cached = await _cacheService.get<List<BangumiCalendarItem>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((m) => BangumiCalendarItem.fromJson(m as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final baseUrl = await _apiBaseUrl();
      final response = await http
          .get(
            Uri.parse('$baseUrl/calendar'),
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as List<dynamic>;
        final items = data
            .expand((day) {
              final itemsData = day['items'] as List<dynamic>? ?? [];
              final weekday = day['weekday'] as Map<String, dynamic>?;
              final id = weekday?['id'] is int
                  ? weekday!['id'] as int
                  : int.tryParse(weekday?['id']?.toString() ?? '');
              return itemsData.map((item) {
                final map = Map<String, dynamic>.from(item as Map);
                map['air_weekday'] = id;
                return BangumiCalendarItem.fromJson(map);
              });
            })
            .where((item) => item.title.isNotEmpty)
            .toList();

        await _cacheService.set(
          cacheKey,
          items.map((e) => e.toJson()).toList(),
          const Duration(hours: 2),
        );
        return ApiResponse.success(items, statusCode: response.statusCode);
      }
      return ApiResponse.error('获取 Bangumi 数据失败: ${response.statusCode}', statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('Bangumi 数据请求异常: $e');
    }
  }

  /// 根据英文星期名称过滤每日放送条目。
  static List<BangumiCalendarItem> filterByWeekday(
    List<BangumiCalendarItem> items,
    String weekdayEn,
  ) {
    final targetId = _weekdayEnToId(weekdayEn);
    if (targetId == null) return [];
    return items.where((item) => item.airWeekday == targetId).toList();
  }

  static int? _weekdayEnToId(String weekdayEn) {
    const mapping = {
      'Mon': 1,
      'Tue': 2,
      'Wed': 3,
      'Thu': 4,
      'Fri': 5,
      'Sat': 6,
      'Sun': 7,
    };
    return mapping[weekdayEn];
  }

  static const List<Map<String, String>> weekdays = [
    {'en': 'Mon', 'cn': '周一'},
    {'en': 'Tue', 'cn': '周二'},
    {'en': 'Wed', 'cn': '周三'},
    {'en': 'Thu', 'cn': '周四'},
    {'en': 'Fri', 'cn': '周五'},
    {'en': 'Sat', 'cn': '周六'},
    {'en': 'Sun', 'cn': '周日'},
  ];

  /// 获取 Bangumi 条目详情，并转成详情页可用的 DoubanMovieDetails。
  static Future<ApiResponse<DoubanMovieDetails>> fetchSubject(int id) async {
    await _initCache();
    final cacheKey = 'bangumi_subject_$id';

    final cached = await _cacheService.get<DoubanMovieDetails>(
      cacheKey,
      (raw) => DoubanMovieDetails.fromJson(raw as Map<String, dynamic>),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final baseUrl = await _apiBaseUrl();
      final response = await http
          .get(
            Uri.parse('$baseUrl/v0/subjects/$id'),
            headers: {
              'User-Agent': _userAgent,
              'Accept': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final nameCn = data['name_cn']?.toString() ?? '';
        final name = data['name']?.toString() ?? '';
        final title = nameCn.isNotEmpty ? nameCn : name;

        final date = data['date']?.toString() ?? '';
        final yearMatch = RegExp(r'(\d{4})').firstMatch(date);
        var year = yearMatch?.group(1) ?? '';
        if (year == '0000') year = '';

        String? rate;
        final score = data['rating']?['score'];
        if (score is num) {
          rate = score.toStringAsFixed(1);
        } else if (score != null) {
          rate = score.toString();
        }
        if (rate == '0.0' || rate == '0') rate = null;

        String poster = '';
        final images = data['images'] as Map<String, dynamic>?;
        if (images != null) {
          poster = images['large']?.toString() ??
              images['common']?.toString() ??
              images['medium']?.toString() ??
              images['small']?.toString() ??
              '';
        }
        if (poster.startsWith('//')) poster = 'https:$poster';

        final summary = data['summary']?.toString();
        final tags = data['tags'] as List<dynamic>? ?? [];
        final genres = tags
            .take(5)
            .map((t) => t['name']?.toString() ?? '')
            .where((s) => s.isNotEmpty)
            .toList();

        final details = DoubanMovieDetails(
          id: id.toString(),
          title: title,
          poster: poster,
          year: year,
          rate: rate,
          summary: summary,
          genres: genres,
        );

        await _cacheService.set(
          cacheKey,
          details.toJson(),
          const Duration(hours: 4),
        );
        return ApiResponse.success(details, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'Bangumi 详情请求失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('Bangumi 详情请求异常: $e');
    }
  }

  /// 判断 URL 是否为 Bangumi 图片地址。
  static bool isBangumiImageUrl(String url) {
    return url.contains('lain.bgm.tv') || url.contains('bgm.tv/pic');
  }

  /// 根据当前 Bangumi 图片代理设置处理图片 URL。
  /// 由于图片在 build 阶段同步使用，调用前请确保已执行 [loadProxySettings]
  /// 或在设置页切换后刷新缓存。
  static String proxyImageUrl(String originalUrl) {
    if (originalUrl.isEmpty) return originalUrl;
    if (!isBangumiImageUrl(originalUrl)) return originalUrl;

    final type = UserDataService.cachedBangumiImageProxyType ??
        BangumiImageProxyType.cmliussss;
    final customUrl = UserDataService.cachedBangumiImageProxyUrl ?? '';

    switch (type) {
      case BangumiImageProxyType.cmliussss:
        return originalUrl.replaceAll(
          RegExp(r'https?://lain\.bgm\.tv'),
          'https://img.doubanio.cmliussss.net',
        );
      case BangumiImageProxyType.custom:
        if (customUrl.isNotEmpty) {
          final base = customUrl.replaceAll(RegExp(r'/+$'), '');
          return '$base${Uri.encodeComponent(originalUrl)}';
        }
        return originalUrl;
      case BangumiImageProxyType.direct:
        return originalUrl;
    }
  }
}
