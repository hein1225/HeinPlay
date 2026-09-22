import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../utils/windows_logger.dart';
import 'local_cache_store.dart';
import 'portable_storage_windows.dart';

/// 全应用统一的缓存服务。
///
/// 存储分两条路：
/// - **便携版（Windows）**：派生缓存落到 exe 同级的 `data/cache/entries/`，
///   每条缓存一个文件，互不牵连，并按「TTL + 7 天兜底」滚动淘汰。
/// - **其他平台**：走平台原生 SharedPreferences（逐键增量写，本就很快）。
///
/// 无论哪条路，**用户数据都不进缓存区**：登录态、服务器地址、设置、播放历史
/// 由各自的服务直接写偏好表；播放记录/收藏虽是服务端数据的本地镜像，也仍留在
/// 偏好表（见 [_preservedKeys]），避免被滚动淘汰掉。
class CacheService {
  static final CacheService _instance = CacheService._internal();
  factory CacheService() => _instance;
  CacheService._internal();

  /// 缓存结构版本号。修改缓存字段解析逻辑或需要强制刷新缓存时，应递增此值。
  static const String _cacheVersion = '1';
  static const String _cacheVersionKey = 'cache_service_version';

  /// 缓存兜底滚动周期：超过该时长未被使用过的条目一律淘汰，即便其 TTL 未到。
  ///
  /// 与 `data/app_logs/` 的日志保留期保持一致，便携目录内所有可再生成的数据
  /// 都遵循同一个「7 天」口径。
  static const Duration rollMaxAge = Duration(days: 7);

  /// 不纳入缓存区的键：它们是服务端数据的本地镜像（播放记录/收藏），
  /// 语义上是用户数据而非可丢弃的缓存，始终留在偏好表。
  static const Set<String> _preservedKeys = {
    'lunatv_playrecords',
    'lunatv_favorites',
  };

  /// 大于该估算长度的缓存条目，其 JSON 编解码改在后台 isolate 执行。
  ///
  /// 直播频道列表（含节目单）这类缓存单条可达 6MB。`json.decode` / `json.encode`
  /// 是同步执行的，跑在主 isolate 上会阻塞界面与播放器初始化数百 ms 甚至 1~2 秒；
  /// 进入直播页时「解码频道缓存」与「写回缓存（编码）」正好连在一起，是 Windows
  /// 起播前明显卡顿的来源之一。小条目继续走同步路径，避免 isolate 启动开销
  /// 把大量细碎缓存读写拖慢。
  static const int _offMainJsonThreshold = 512 * 1024;

  /// 粗略估算对象 JSON 化后的长度，用于判断是否需要挪到后台 isolate。
  /// 累计超过阈值即提前返回，避免为判断大小而完整遍历超大对象。
  static int _estimateJsonSize(dynamic data, [int depth = 0]) {
    if (data == null) return 4;
    if (data is String) return data.length + 2;
    if (data is num || data is bool) return 8;
    if (depth > 4) return 96;
    if (data is List) {
      var total = 2;
      for (final e in data) {
        total += _estimateJsonSize(e, depth + 1) + 1;
        if (total > _offMainJsonThreshold) return total;
      }
      return total;
    }
    if (data is Map) {
      var total = 2;
      for (final e in data.entries) {
        total += _estimateJsonSize(e.key, depth + 1) +
            _estimateJsonSize(e.value, depth + 1) +
            4;
        if (total > _offMainJsonThreshold) return total;
      }
      return total;
    }
    return 96;
  }

  static Future<dynamic> _decodeOffMain(String raw) {
    if (raw.length < _offMainJsonThreshold) return Future.value(json.decode(raw));
    return Isolate.run(() => json.decode(raw));
  }

  static Future<String> _encodeOffMain(Map<String, dynamic> entry) {
    if (_estimateJsonSize(entry) < _offMainJsonThreshold) {
      return Future.value(json.encode(entry));
    }
    return Isolate.run(() => json.encode(entry));
  }

  SharedPreferences? _prefs;

  /// 偏好表后端（无状态，常驻复用）。
  static const LocalCacheStore _prefsStore = PrefsCacheStore();

  /// 便携文件后端；仅 Windows 且便携目录已就绪时可用，其余情况为 null。
  LocalCacheStore? _fileStore;
  bool _fileStoreResolved = false;

  /// 一次性的启动维护（旧缓存迁移 + 7 天滚动淘汰）是否已执行。
  bool _maintenanceDone = false;

  /// 解析便携文件后端。便携目录尚未就绪（如初始化早期）时返回 null，
  /// 此时所有读写自动退回偏好表，不影响功能。
  LocalCacheStore? get _portableStore {
    if (_fileStoreResolved) return _fileStore;
    _fileStoreResolved = true;
    if (!Platform.isWindows || !PortableStorageWindows.isInitialized) return null;
    try {
      _fileStore = FileCacheStore(PortableStorageWindows.cacheDir);
    } catch (e) {
      WindowsLogger.log('CacheService', '便携缓存目录不可用，回退偏好表: $e');
      _fileStore = null;
    }
    return _fileStore;
  }

  /// 按键选择后端：便携版下除 [\_preservedKeys] 外一律落缓存目录。
  LocalCacheStore _storeFor(String key) {
    final portable = _portableStore;
    if (portable != null && !_preservedKeys.contains(key)) return portable;
    return _prefsStore;
  }

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    await _checkVersion();
    if (!_maintenanceDone) {
      _maintenanceDone = true;
      try {
        await _runMaintenance();
      } catch (e) {
        WindowsLogger.log('CacheService', '启动维护失败: $e');
      }
    }
  }

  /// 便携版启动维护：把偏好表里遗留的派生缓存迁进缓存目录，再做 7 天滚动淘汰。
  ///
  /// 只在首次 [init] 时执行一次；迁移跑完偏好表里就没有缓存条目了，后续启动
  /// 只剩一次目录扫描（几十次 stat，毫秒级）。
  Future<void> _runMaintenance() async {
    final portable = _portableStore;
    if (portable == null) return;
    final sw = Stopwatch()..start();
    final moved = await _migrateFromPrefs(portable);
    final rolled = await portable.prune(rollMaxAge);
    await _migrateLegacyPosterDir();
    WindowsLogger.log(
      'CacheService',
      '缓存维护完成 迁移=$moved 滚动淘汰=$rolled 耗时=${sw.elapsedMilliseconds}ms',
    );
  }

  /// 把偏好表里「缓存条目」搬到便携缓存目录，并从偏好表删除。
  ///
  /// 判定沿用 [clear] 同一口径：值必须是 `{"expiresAt":…,"data":…}` 结构。
  /// 这样登录态、服务器地址、设置（都不是这个结构）不会被误搬进可删除的
  /// 缓存区；播放记录/收藏虽符合结构，但被 [_preservedKeys] 排除。
  Future<int> _migrateFromPrefs(LocalCacheStore portable) async {
    final prefs = await SharedPreferences.getInstance();
    var moved = 0;
    for (final key in prefs.getKeys().toList()) {
      if (key == _cacheVersionKey || _preservedKeys.contains(key)) continue;
      // 必须用 get() + 类型判断：偏好表里混着 bool/int 类型的设置项，
      // getString() 对它们会抛 `type 'bool' is not a subtype of type 'String?'`，
      // 迁移会就此中断（只剩一半键被搬走）。
      final value = prefs.get(key);
      if (value is! String || value.isEmpty) continue;
      if (!await _looksLikeCacheEntry(value)) continue;
      await portable.write(key, value);
      await prefs.remove(key);
      moved++;
    }
    return moved;
  }

  /// 判断一个偏好值是否是 `CacheService` 写的缓存条目（`expiresAt` + `data`）。
  Future<bool> _looksLikeCacheEntry(String raw) async {
    // 粗筛：本服务写入的条目固定以 `{"data"` 开头（序列化时 data 在前、
    // expiresAt 在后）。bool/int/纯文本设置项在这里就被排除，不必为它们
    // 解析 JSON；只有真正的候选才会走到下面的完整判定。
    if (!raw.startsWith('{"data"')) return false;
    try {
      final decoded = await _decodeOffMain(raw);
      if (decoded is! Map) return false;
      return decoded.containsKey('expiresAt') && decoded.containsKey('data');
    } catch (_) {
      return false;
    }
  }

  /// 接管历史遗留的海报缓存目录 `data/temp/hainTvCache`。
  ///
  /// 便携版的临时目录已并入 `data/cache`（见 `PortablePathProviderWindows`），
  /// 海报改存在 `data/cache/hainTvCache`。图片缓存管理器按「相对缓存根的文件名」
  /// 索引文件，所以把旧文件搬过去索引依旧有效，用户不必重新下载这十几 MB 海报。
  Future<void> _migrateLegacyPosterDir() async {
    try {
      final legacyRoot = Directory(
        p.join(PortableStorageWindows.dataDir, 'temp'),
      );
      final legacy = Directory(p.join(legacyRoot.path, 'hainTvCache'));
      if (!await legacy.exists()) return;
      final target = Directory(
        p.join(PortableStorageWindows.cacheDir, 'hainTvCache'),
      );
      if (!await target.exists()) await target.create(recursive: true);
      var moved = 0;
      await for (final entity in legacy.list()) {
        if (entity is! File) continue;
        final dest = File(p.join(target.path, p.basename(entity.path)));
        try {
          if (await dest.exists()) {
            await entity.delete();
          } else {
            await entity.rename(dest.path);
            moved++;
          }
        } catch (_) {
          // 单个文件搬运失败不影响其余文件（缺的那张会按需重新下载）。
        }
      }
      try {
        await legacy.delete();
      } catch (_) {
        // 目录仍被占用时留着即可，下次启动再试。
      }
      if (await legacyRoot.list().isEmpty) {
        await legacyRoot.delete();
      }
      WindowsLogger.log('CacheService', '已接管历史海报缓存 $moved 个文件');
    } catch (e) {
      WindowsLogger.log('CacheService', '接管历史海报缓存失败: $e');
    }
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
    final store = _storeFor(key);
    final raw = await store.read(key);
    if (raw == null) return null;
    try {
      final decoded = await _decodeOffMain(raw) as Map<String, dynamic>;
      final expiresAt = decoded['expiresAt'] as int?;
      if (expiresAt != null &&
          DateTime.now().millisecondsSinceEpoch > expiresAt) {
        await store.remove(key);
        return null;
      }
      return parser(decoded['data']);
    } catch (e) {
      await store.remove(key);
      return null;
    }
  }

  Future<void> set(String key, dynamic data, Duration ttl) async {
    await init();
    final entry = {
      'data': data,
      'expiresAt': DateTime.now().add(ttl).millisecondsSinceEpoch,
    };
    await _storeFor(key).write(key, await _encodeOffMain(entry));
  }

  /// 更新缓存数据但【保持原有过期时间】，不重置 TTL。
  ///
  /// 用于只补充 catchup / EPG 等 enrichment 元数据、但不应影响数据主体（如直播源频道列表
  /// 及其播放地址）刷新周期的场景。若缓存条目尚不存在，则退回到 [fallbackTtl]。
  ///
  /// 关键用途：直播源频道列表的刷新周期由"直播源缓存时间"配置（默认 24h）控制，必须按该周期
  /// 回源重新拉取，才能拿到服务端已变更的播放地址（如 rtp→rtsp）。若 enrichment 写入用普通
  /// [set] 重置 TTL，App 频繁打开会令频道列表缓存永不过期，导致新地址永远不生效。
  Future<void> setPreservingTtl(
    String key,
    dynamic data, {
    Duration? fallbackTtl,
  }) async {
    await init();
    final store = _storeFor(key);
    int? existingExpiresAt;
    final raw = await store.read(key);
    if (raw != null) {
      try {
        final decoded = await _decodeOffMain(raw) as Map<String, dynamic>;
        existingExpiresAt = decoded['expiresAt'] as int?;
      } catch (_) {
        existingExpiresAt = null;
      }
    }
    final expiresAt = existingExpiresAt ??
        DateTime.now()
            .add(fallbackTtl ?? const Duration(hours: 24))
            .millisecondsSinceEpoch;
    final entry = {
      'data': data,
      'expiresAt': expiresAt,
    };
    await store.write(key, await _encodeOffMain(entry));
  }

  Future<void> delete(String key) async {
    await init();
    // 两个后端都清：迁移前后同一键可能短暂存在于偏好表与缓存目录两侧。
    await _storeFor(key).remove(key);
    await _prefsStore.remove(key);
  }

  Future<void> clear() async {
    await init();
    // 便携缓存目录整目录清空（里面只有可再生成的派生缓存）。
    await _portableStore?.clear();
    // 偏好表里只删 CacheService 自己创建的缓存条目（value 为包含 expiresAt 的 JSON），
    // 避免误删用户登录信息、服务器地址、设置等数据。
    final keys = _prefs!.getKeys().toList();
    for (final key in keys) {
      try {
        final value = _prefs!.get(key);
        if (value is String && value.isNotEmpty) {
          final decoded = json.decode(value) as Map<String, dynamic>;
          if (decoded.containsKey('expiresAt') && decoded.containsKey('data')) {
            await _prefs!.remove(key);
          }
        }
      } catch (_) {
        // 非 JSON 格式的 value（bool/int 设置项、纯文本值）跳过，保留用户数据
      }
    }
  }

  Future<void> clearPrefix(String prefix) async {
    await init();
    final portable = _portableStore;
    if (portable != null) {
      for (final key in await portable.keys()) {
        if (key.startsWith(prefix)) await portable.remove(key);
      }
    }
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
    // v2：EPG 时间改为统一 UTC 存储，旧版本地时间缓存需失效重新拉取。
    return 'lunatv_live_v2_$sourceKey';
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
