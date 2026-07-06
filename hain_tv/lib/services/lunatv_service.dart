import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/api_response.dart';
import '../models/favorite.dart';
import '../models/live_channel.dart';
import '../models/play_record.dart';
import '../models/search_result.dart';
import '../models/short_drama.dart';
import '../models/skip_segment.dart';
import '../models/video_detail.dart';
import 'cache_service.dart';
import 'user_data_service.dart';

class LunaTVConfig {
  static const Duration searchTimeout = Duration(seconds: 8);
  static const Duration detailTimeout = Duration(seconds: 20);
  static const Duration liveTimeout = Duration(seconds: 15);
  static const Duration shortDramaTimeout = Duration(seconds: 15);
  static const Duration defaultTimeout = Duration(seconds: 15);
  static const int maxRetryCount = 2;
  static const Duration searchCacheTtl = Duration(minutes: 30);
  static const Duration detailCacheTtl = Duration(minutes: 30);
  static const Duration liveCacheTtl = Duration(minutes: 5);
  static const Duration shortDramaCacheTtl = Duration(minutes: 30);
}

class ShortDramaListResult {
  final List<ShortDrama> list;
  final bool hasMore;

  ShortDramaListResult({required this.list, required this.hasMore});
}

class LunaTVService {
  static final CacheService _cacheService = CacheService();
  static bool _cacheInitialized = false;

  static Future<void> _initCache() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }

  static Future<String?> _baseUrl() async {
    final url = await UserDataService.getServerUrl();
    if (url == null || url.trim().isEmpty) return null;
    return url.trim().replaceAll(RegExp(r'/+$'), '');
  }

  static Future<Map<String, String>> _headers() async {
    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': 'HainTV/1.0.0 Flutter',
    };
    final cookies = await UserDataService.getCookies();
    if (cookies != null && cookies.isNotEmpty) {
      headers['Cookie'] = cookies;
    }
    return headers;
  }

  static Future<http.Response> _get(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
  }) async {
    final base = await _baseUrl();
    if (base == null) {
      throw Exception('未配置 LunaTV 服务器地址');
    }

    final uri = Uri.parse(base + path).replace(queryParameters: queryParameters);
    final headers = await _headers();
    final effectiveTimeout = timeout ?? LunaTVConfig.defaultTimeout;

    Exception? lastError;
    for (var attempt = 0; attempt <= LunaTVConfig.maxRetryCount; attempt++) {
      try {
        final response = await http
            .get(uri, headers: headers)
            .timeout(effectiveTimeout);
        return response;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt == LunaTVConfig.maxRetryCount) break;
      }
    }
    throw lastError ?? Exception('请求失败: $path');
  }

  static Future<http.Response> _post(
    String path, {
    required String body,
    Duration? timeout,
  }) async {
    final base = await _baseUrl();
    if (base == null) {
      throw Exception('未配置 LunaTV 服务器地址');
    }

    final uri = Uri.parse(base + path);
    final headers = await _headers();
    headers['Content-Type'] = 'application/json';
    final effectiveTimeout = timeout ?? LunaTVConfig.defaultTimeout;

    Exception? lastError;
    for (var attempt = 0; attempt <= LunaTVConfig.maxRetryCount; attempt++) {
      try {
        final response = await http
            .post(uri, headers: headers, body: body)
            .timeout(effectiveTimeout);
        return response;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt == LunaTVConfig.maxRetryCount) break;
      }
    }
    throw lastError ?? Exception('请求失败: $path');
  }

  static Future<http.Response> _delete(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
  }) async {
    final base = await _baseUrl();
    if (base == null) {
      throw Exception('未配置 LunaTV 服务器地址');
    }

    final uri = Uri.parse(base + path).replace(queryParameters: queryParameters);
    final headers = await _headers();
    final effectiveTimeout = timeout ?? LunaTVConfig.defaultTimeout;

    Exception? lastError;
    for (var attempt = 0; attempt <= LunaTVConfig.maxRetryCount; attempt++) {
      try {
        final response = await http
            .delete(uri, headers: headers)
            .timeout(effectiveTimeout);
        return response;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt == LunaTVConfig.maxRetryCount) break;
      }
    }
    throw lastError ?? Exception('请求失败: $path');
  }

  static Map<String, dynamic> _decodeBody(http.Response response) {
    if (response.body.trim().isEmpty) return {};
    return json.decode(response.body) as Map<String, dynamic>;
  }

  static Future<ApiResponse<String>> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      return ApiResponse.error('服务器地址不能为空');
    }

    final body = <String, String>{
      'username': username,
      'password': password,
    };

    try {
      final response = await http
          .post(
            Uri.parse('$base/api/login'),
            headers: {
              'Accept': 'application/json, text/plain, */*',
              'Content-Type': 'application/json',
              'User-Agent': 'HainTV/1.0.0 Flutter',
            },
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null && setCookie.isNotEmpty) {
          return ApiResponse.success(setCookie, statusCode: response.statusCode);
        }
        return ApiResponse.success('', statusCode: response.statusCode);
      }

      final data = _decodeBody(response);
      return ApiResponse.error(
        data['error']?.toString() ?? '登录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('登录请求异常: $e');
    }
  }

  static Future<ApiResponse<List<SearchResult>>> search({
    required String keyword,
    String? source,
  }) async {
    await _initCache();
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return ApiResponse.success([], statusCode: 200);
    }

    final cacheKey = _cacheService.generateSearchCacheKey(
      keyword: trimmed,
      source: source,
    );
    final cached = await _cacheService.get<List<SearchResult>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final query = <String, String>{'q': trimmed};
      if (source != null && source.isNotEmpty) query['source'] = source;

      final response = await _get(
        '/api/search',
        queryParameters: query,
        timeout: LunaTVConfig.searchTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final resultsData = data['results'] as List<dynamic>? ?? [];
        final results = resultsData
            .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
            .toList();
        await _cacheService.set(
          cacheKey,
          results.map((e) => e.toJson()).toList(),
          LunaTVConfig.searchCacheTtl,
        );
        return ApiResponse.success(results, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 搜索失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 搜索异常: $e');
    }
  }

  static Future<ApiResponse<VideoDetail>> getDetail({
    required String source,
    required String id,
    String? title,
  }) async {
    if (!RegExp(r'^[\w-]+$').hasMatch(id)) {
      return ApiResponse.error('无效的影片ID格式');
    }
    await _initCache();
    final cacheKey = _cacheService.generateDetailCacheKey(
      source: source,
      id: id,
    );
    final cached = await _cacheService.get<VideoDetail>(
      cacheKey,
      (raw) => VideoDetail.fromJson(raw as Map<String, dynamic>),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final query = <String, String>{
        'source': source,
        'id': id,
      };
      if (title != null && title.isNotEmpty) query['title'] = title;

      final response = await _get(
        '/api/detail',
        queryParameters: query,
        timeout: LunaTVConfig.detailTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final detail = VideoDetail.fromJson(data);
        await _cacheService.set(
          cacheKey,
          detail.toJson(),
          LunaTVConfig.detailCacheTtl,
        );
        return ApiResponse.success(detail, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 详情失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 详情异常: $e');
    }
  }

  static Future<ApiResponse<List<LiveChannel>>> getLiveChannels({
    required String sourceKey,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateLiveChannelsCacheKey(
      sourceKey: sourceKey,
    );
    final cached = await _cacheService.get<List<LiveChannel>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final response = await _get(
        '/api/live/channels',
        queryParameters: {'source': sourceKey},
        timeout: LunaTVConfig.liveTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final channelsData = data['data'] as List<dynamic>? ?? <dynamic>[];
        final channels = channelsData
            .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
            .toList();
        await _cacheService.set(
          cacheKey,
          channels.map((e) => e.toJson()).toList(),
          LunaTVConfig.liveCacheTtl,
        );
        return ApiResponse.success(channels, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 直播频道失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 直播频道异常: $e');
    }
  }

  static Future<ApiResponse<ShortDramaListResult>> getShortDramas({
    required int categoryId,
    int page = 1,
    int size = 20,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateShortDramasCacheKey(
      categoryId: categoryId,
      page: page,
      size: size,
    );
    final cached = await _cacheService.get<ShortDramaListResult>(
      cacheKey,
      (raw) {
        final map = raw as Map<String, dynamic>;
        return ShortDramaListResult(
          list: (map['list'] as List<dynamic>)
              .map((e) => ShortDrama.fromJson(e as Map<String, dynamic>))
              .toList(),
          hasMore: map['hasMore'] == true,
        );
      },
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final response = await _get(
        '/api/shortdrama/list',
        queryParameters: {
          'categoryId': categoryId.toString(),
          'page': page.toString(),
          'size': size.toString(),
        },
        timeout: LunaTVConfig.shortDramaTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final listData = data['list'] as List<dynamic>? ?? [];
        final hasMore = data['hasMore'] == true;
        final list = listData
            .map((e) => ShortDrama.fromJson(e as Map<String, dynamic>))
            .toList();
        final result = ShortDramaListResult(list: list, hasMore: hasMore);
        await _cacheService.set(
          cacheKey,
          {
            'list': list.map((e) => e.toJson()).toList(),
            'hasMore': hasMore,
          },
          LunaTVConfig.shortDramaCacheTtl,
        );
        return ApiResponse.success(result, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 短剧列表失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 短剧列表异常: $e');
    }
  }

  static Future<({Duration responseTime, double? speed})> speedTestEpisode(
    String url, {
    Duration timeout = const Duration(seconds: 10),
    int sampleBytes = 512 * 1024,
  }) async {
    final stopwatch = Stopwatch()..start();

    Future<({Duration responseTime, double? speed})> doTest(
      String testUrl, {
      bool useRange = true,
    }) async {
      final req = http.Request('GET', Uri.parse(testUrl));
      req.headers['User-Agent'] =
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
          ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
      req.headers['Accept'] = '*/*';
      req.headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
      if (useRange) {
        req.headers['Range'] = 'bytes=0-${sampleBytes - 1}';
      }
      final streamedResponse = await http.Client()
          .send(req)
          .timeout(timeout);

      if (streamedResponse.statusCode == 200 ||
          streamedResponse.statusCode == 206) {
        var received = 0;
        await for (final chunk in streamedResponse.stream) {
          received += chunk.length;
          if (received >= sampleBytes) break;
        }
        stopwatch.stop();
        final seconds = stopwatch.elapsedMilliseconds / 1000.0;
        // 即使 received 小于 sampleBytes（如 .m3u8 文件较小），也计算实际速度
        final speed = seconds > 0 ? (received * 8 / seconds) : 0.0;
        return (responseTime: stopwatch.elapsed, speed: speed);
      }
      return (responseTime: stopwatch.elapsed, speed: null);
    }

    try {
      // 先尝试 Range 请求
      var result = await doTest(url, useRange: true);
      if (result.speed != null && result.speed! > 0) return result;

      // Range 失败则尝试普通 GET
      stopwatch.reset();
      stopwatch.start();
      result = await doTest(url, useRange: false);
      if (result.speed != null && result.speed! > 0) return result;

      stopwatch.stop();
      return (responseTime: stopwatch.elapsed, speed: 0.0);
    } catch (e) {
      stopwatch.stop();
      return (responseTime: stopwatch.elapsed, speed: 0.0);
    }
  }

  static Future<ApiResponse<VideoDetail>> getDetailForSpeedTest({
    required String source,
    required String id,
    String? title,
  }) async {
    return getDetail(source: source, id: id, title: title);
  }

  static Future<ApiResponse<EpisodeSkipConfig>> getSkipConfigs({
    required String source,
    required String id,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateSkipConfigsCacheKey(
      source: source,
      id: id,
    );
    final cached = await _cacheService.get<EpisodeSkipConfig>(
      cacheKey,
      (raw) => EpisodeSkipConfig.fromJson(raw as Map<String, dynamic>),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final body = json.encode({
        'action': 'get',
        'key': '$source+$id',
      });
      final response = await _post(
        '/api/skipconfigs',
        body: body,
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        if (data['error'] != null) {
          return ApiResponse.error(data['error'].toString());
        }
        final configData = data['config'] as Map<String, dynamic>?;
        if (configData == null) {
          return ApiResponse.error('暂无跳过配置');
        }
        final config = EpisodeSkipConfig.fromJson(configData);
        await _cacheService.set(
          cacheKey,
          config.toJson(),
          const Duration(days: 7),
        );
        return ApiResponse.success(config, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '获取跳过配置失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('获取跳过配置异常: $e');
    }
  }

  static Future<ApiResponse<EpisodeSkipConfig>> setSkipConfigs({
    required String source,
    required String id,
    required String title,
    required List<SkipSegment> segments,
  }) async {
    await _initCache();
    try {
      final body = json.encode({
        'action': 'set',
        'key': '$source+$id',
        'config': {
          'source': source,
          'id': id,
          'title': title,
          'segments': segments.map((s) => s.toJson()).toList(),
        },
      });
      final response = await _post(
        '/api/skipconfigs',
        body: body,
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        if (data['error'] != null) {
          return ApiResponse.error(data['error'].toString());
        }
        final config = EpisodeSkipConfig(
          source: source,
          id: id,
          title: title,
          segments: segments,
          updatedTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
        );
        final cacheKey = _cacheService.generateSkipConfigsCacheKey(
          source: source,
          id: id,
        );
        await _cacheService.set(
          cacheKey,
          config.toJson(),
          const Duration(days: 7),
        );
        return ApiResponse.success(config, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '保存跳过配置失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('保存跳过配置异常: $e');
    }
  }

  // ================== 播放历史接口 ==================

  /// 获取当前用户的所有播放记录
  static Future<ApiResponse<Map<String, PlayRecord>>> getPlayRecords() async {
    try {
      final response = await _get(
        '/api/playrecords',
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final records = <String, PlayRecord>{};
        for (final entry in data.entries) {
          final key = entry.key.toString();
          final value = entry.value as Map<String, dynamic>;
          records[key] = PlayRecord.fromJson(key, value);
        }
        return ApiResponse.success(records, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '获取播放记录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('获取播放记录异常: $e');
    }
  }

  /// 保存播放记录到后端
  static Future<ApiResponse<void>> savePlayRecord({
    required String key,
    required PlayRecord record,
  }) async {
    try {
      final body = json.encode({
        'key': key,
        'record': record.toJson(),
      });
      final response = await _post(
        '/api/playrecords',
        body: body,
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '保存播放记录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('保存播放记录异常: $e');
    }
  }

  /// 删除单条播放记录
  static Future<ApiResponse<void>> deletePlayRecord(String key) async {
    try {
      final response = await _delete(
        '/api/playrecords',
        queryParameters: {'key': key},
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '删除播放记录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('删除播放记录异常: $e');
    }
  }

  // ================== 收藏接口 ==================

  /// 获取当前用户的所有收藏
  static Future<ApiResponse<List<Favorite>>> getFavorites() async {
    try {
      final response = await _get(
        '/api/favorites',
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final favorites = data.entries.map((e) {
          return Favorite.fromJson(e.key, e.value as Map<String, dynamic>);
        }).toList();
        favorites.sort((a, b) => (b.saveTime ?? 0).compareTo(a.saveTime ?? 0));
        return ApiResponse.success(favorites, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '获取收藏失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('获取收藏异常: $e');
    }
  }

  /// 添加收藏
  static Future<ApiResponse<void>> addFavorite({
    required String key,
    required Favorite favorite,
  }) async {
    try {
      final body = json.encode({
        'key': key,
        'favorite': favorite.toJson(),
      });
      final response = await _post(
        '/api/favorites',
        body: body,
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '添加收藏失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('添加收藏异常: $e');
    }
  }

  /// 删除收藏
  static Future<ApiResponse<void>> deleteFavorite(String key) async {
    try {
      final response = await _delete(
        '/api/favorites',
        queryParameters: {'key': key},
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '删除收藏失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('删除收藏异常: $e');
    }
  }

  /// 查询是否已收藏
  static Future<bool> isFavorite(String key) async {
    try {
      final response = await _get(
        '/api/favorites',
        queryParameters: {'key': key},
        timeout: LunaTVConfig.defaultTimeout,
      );
      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        return data.isNotEmpty;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 切换收藏状态
  static Future<bool> toggleFavorite({
    required String key,
    required Favorite favorite,
  }) async {
    final isFav = await isFavorite(key);
    if (isFav) {
      await deleteFavorite(key);
      return false;
    } else {
      await addFavorite(key: key, favorite: favorite);
      return true;
    }
  }
}
