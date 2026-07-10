import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/api_response.dart';
import '../models/bangumi_calendar_item.dart';
import '../models/douban_movie.dart';
import 'cache_service.dart';

class BangumiService {
  static final CacheService _cacheService = CacheService();
  static bool _cacheInitialized = false;

  static Future<void> _initCache() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }

  static const String _calendarUrl = 'https://api.bgm.tv/calendar';
  static const String _userAgent = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

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
      final response = await http
          .get(
            Uri.parse(_calendarUrl),
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
      final response = await http
          .get(
            Uri.parse('https://api.bgm.tv/v0/subjects/$id'),
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
}
