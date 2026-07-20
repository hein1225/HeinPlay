import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  /// 缓存结构版本号。修改缓存字段解析逻辑或需要强制刷新缓存时，应递增此值。
  static const String _cacheVersion = '1';
  static const String _cacheVersionKey = 'cache_service_version';

  SharedPreferences? _prefs;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _checkVersion();
  }

  /// 检查缓存版本号，版本不一致时清空所有缓存条目，避免旧缓存导致新代码逻辑失效。
  Future<void> _checkVersion() async {
    if (_prefs == null) return;
    final storedVersion = _prefs!.getString(_cacheVersionKey);
    if (storedVersion != _cacheVersion) {
      // 先写入新版本号，避免 clear()->init() 再次触发版本检查造成递归。
      await _prefs!.setString(_cacheVersionKey, _cacheVersion);
      await clear();
    }
  }

  Future<T?> get<T>(String key, T Function(dynamic) parser) async {
    await init();
    final raw = _prefs!.getString(key);
    if (raw == null) return null;
    try {
      final decoded = json.decode(raw) as Map<String, dynamic>;
      final expiresAt = decoded['expiresAt'] as int?;
      if (expiresAt != null &&
          DateTime.now().millisecondsSinceEpoch > expiresAt) {
        await _prefs!.remove(key);
        return null;
      }
      return parser(decoded['data']);
    } catch (e) {
      await _prefs!.remove(key);
      return null;
    }
  }

  Future<void> set(String key, dynamic data, Duration ttl) async {
    await init();
    final entry = {
      'data': data,
      'expiresAt': DateTime.now().add(ttl).millisecondsSinceEpoch,
    };
    await _prefs!.setString(key, json.encode(entry));
  }

  Future<void> delete(String key) async {
    await init();
    await _prefs!.remove(key);
  }

  Future<void> clear() async {
    await init();
    // 只删除 CacheService 自己创建的缓存条目（value 为包含 expiresAt 的 JSON）
    // 避免误删用户登录信息、服务器地址、设置等数据
    final keys = _prefs!.getKeys().toList();
    for (final key in keys) {
      try {
        final raw = _prefs!.getString(key);
        if (raw != null && raw.isNotEmpty) {
          final decoded = json.decode(raw) as Map<String, dynamic>;
          if (decoded.containsKey('expiresAt') && decoded.containsKey('data')) {
            await _prefs!.remove(key);
          }
        }
      } catch (_) {
        // 非 JSON 格式的 value 跳过，保留用户设置
      }
    }
  }

  Future<void> clearPrefix(String prefix) async {
    await init();
    final keys = _prefs!.getKeys().where((k) => k.startsWith(prefix)).toList();
    for (final key in keys) {
      await _prefs!.remove(key);
    }
  }

  String generateDoubanHotCacheKey({
    required String type,
    required String tag,
    required int pageSize,
    required int pageStart,
  }) {
    return 'douban_hot_${type}_${tag}_${pageStart}_$pageSize';
  }

  String generateDoubanCategoryCacheKey({
    required String kind,
    required String category,
    required String type,
    required int pageLimit,
    required int page,
  }) {
    return 'douban_category_${kind}_${category}_$type${page}_$pageLimit';
  }

  String generateDoubanRecommendsCacheKey({
    required String kind,
    required String category,
    required String format,
    required String region,
    required String year,
    required String platform,
    required String sort,
    required String label,
    required int pageLimit,
    required int page,
  }) {
    return 'douban_recommend_${kind}_${category}_${format}_${region}_${year}_${platform}_${sort}_${label}_${page}_$pageLimit';
  }

  String generateDoubanDetailsCacheKey({required String doubanId}) {
    return 'douban_details_$doubanId';
  }

  String generateDoubanSearchCacheKey({
    required String keyword,
    required int limit,
  }) {
    return 'douban_search_${keyword}_$limit';
  }

  String generateSearchCacheKey({required String keyword, String? source}) {
    return 'lunatv_search_${source ?? 'all'}_$keyword';
  }

  String generateDetailCacheKey({required String source, required String id}) {
    return 'lunatv_detail_${source}_$id';
  }

  String generateLiveChannelsCacheKey({required String sourceKey}) {
    return 'lunatv_live_$sourceKey';
  }

  String generateSkipConfigsCacheKey({
    required String source,
    required String id,
  }) {
    return 'lunatv_skipconfigs_${source}_$id';
  }

  /// 按影片身份（doubanId 或 title+year）生成的跨源跳过配置缓存 key。
  String generateSkipConfigsIdentityCacheKey({required String identityKey}) {
    return 'lunatv_skipconfigs_identity_$identityKey';
  }

  String generatePlayRecordsCacheKey() => 'lunatv_playrecords';

  String generateFavoritesCacheKey() => 'lunatv_favorites';
}
