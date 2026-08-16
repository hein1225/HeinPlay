import 'dart:collection';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import '../models/api_response.dart';
import '../models/live_channel.dart';
import '../models/live_source_config.dart';
import 'cache_service.dart';
import 'live_source_storage.dart';
import 'lunatv_service.dart';
import 'user_data_service.dart';

/// catchup 信息临时结构。
class _CatchupInfo {
  final String? catchup;
  final String? catchupSource;
  final int? catchupDays;

  _CatchupInfo({this.catchup, this.catchupSource, this.catchupDays});
}

/// 直播服务：拉取 LunaTV 直播源、解析本地 M3U/JSON、缓存频道列表。
class LiveService {
  static const Duration _fetchTimeout = Duration(seconds: 15);

  /// 默认 LunaTV 直播源标识。
  static const String defaultLunaTvSourceKey = 'default';

  /// LunaTV 内置直播源固定 ID。
  static const String lunaTvBuiltinSourceId = 'lunatv_builtin';

  /// 最近一次拉取 LunaTV 频道时使用的源 key，用于构建代理播放 URL。
  static String? lastLunaTvSourceKey;

  /// 最近一次从 M3U 头中解析到的源级 EPG 地址。
  static String? lastEpgUrl;

  /// 服务端返回的 LunaTV 直播源名称缓存。
  static String? _lunaTvServerSourceName;

  /// 服务端返回或从 M3U 头解析到的 LunaTV 源级 EPG 地址缓存。
  static String? _lunaTvEpgUrl;

  /// 内置 LunaTV 直播源配置（置顶、不可编辑删除）。
  /// 名称优先使用服务端返回的第一个启用源名称，获取失败时回退到默认名称。
  static LiveSourceConfig get lunaTvBuiltinSource {
    return LiveSourceConfig(
      id: lunaTvBuiltinSourceId,
      name: _lunaTvServerSourceName ?? 'LunaTV 直播',
      url: '',
      epgUrl: _lunaTvEpgUrl,
      sourceKey: defaultLunaTvSourceKey,
      isBuiltin: true,
      enabled: true,
      order: -1,
      createTime: DateTime.utc(2024, 1, 1),
    );
  }

  /// 拉取服务端直播源列表，将每个源转换为内置直播源配置（置顶展示）。
  static Future<List<LiveSourceConfig>> _fetchBuiltinSources() async {
    try {
      final response = await LunaTVService.getLiveSources();
      final sources = response.data ?? [];
      if (sources.isEmpty) {
        return [lunaTvBuiltinSource];
      }
      final firstName = sources.first['name']?.toString();
      if (firstName != null && firstName.isNotEmpty) {
        _lunaTvServerSourceName = firstName;
      }
      return sources.map((s) {
        final key = s['key']?.toString() ?? defaultLunaTvSourceKey;
        final name = s['name']?.toString() ?? 'LunaTV 直播';
        final url = s['url']?.toString() ?? '';
        final epgUrl = s['epgUrl']?.toString() ?? s['epg_url']?.toString();
        return LiveSourceConfig(
          id: '${lunaTvBuiltinSourceId}_$key',
          name: name,
          url: url,
          epgUrl: epgUrl,
          sourceKey: key,
          isBuiltin: true,
          enabled: true,
          order: -1,
          createTime: DateTime.utc(2024, 1, 1),
        );
      }).toList();
    } catch (_) {
      // 获取失败时回退到默认内置源，避免阻塞列表加载。
      return [lunaTvBuiltinSource];
    }
  }

  /// 获取所有直播源：LunaTV 内置源置顶（每个服务端源一个），其后为用户自定义源。
  /// 若用户在设置中关闭了 LunaTV 服务器直播源，则只返回用户自定义源。
  static Future<List<LiveSourceConfig>> getAllSources() async {
    final userConfigs = await LiveSourceStorage.getConfigs();
    final lunaTvEnabled = await UserDataService.getLunaTvLiveEnabled();
    if (!lunaTvEnabled) {
      return userConfigs;
    }
    final builtinSources = await _fetchBuiltinSources();
    return [...builtinSources, ...userConfigs];
  }

  /// 从 LunaTV 服务端获取直播频道列表。
  ///
  /// [sourceKey] 指定要拉取的服务端直播源 key；为空时自动取第一个启用源。
  /// [sourceUrl] / [epgUrl] 为该源对应的原始订阅地址与 EPG 地址，用于补全 catchup/EPG。
  ///
  /// 频道数据会缓存到本地，缓存时间由用户在"软件设置→直播源缓存时间"中配置，
  /// 默认 24 小时。缓存 key 基于直播源 key 生成，切换直播源时自动失效。
  static Future<ApiResponse<List<LiveChannel>>> fetchLunaTvChannels({
    String? sourceKey,
    String? sourceUrl,
    String? epgUrl,
  }) async {
    final enabled = await UserDataService.getLunaTvLiveEnabled();
    if (!enabled) {
      return ApiResponse.success([]);
    }

    String key = sourceKey ?? '';
    String? url = sourceUrl;
    String? serverEpgUrl = epgUrl;

    if (key.isEmpty) {
      // 未指定 sourceKey 时，拉取服务端源列表并取第一个启用源。
      final sourcesResponse = await LunaTVService.getLiveSources();
      if (!sourcesResponse.success) {
        return ApiResponse.error(sourcesResponse.message ?? '获取直播源列表失败');
      }
      final sources = sourcesResponse.data ?? [];
      if (sources.isEmpty) {
        return ApiResponse.success([]);
      }
      final first = sources.first;
      key = first['key']?.toString() ?? defaultLunaTvSourceKey;
      url = url ?? first['url']?.toString();
      serverEpgUrl = serverEpgUrl ??
          first['epgUrl']?.toString() ??
          first['epg_url']?.toString();
    }

    lastLunaTvSourceKey = key;

    // 若服务端直接返回了源级 EPG 地址，则缓存到内置源配置中。
    if (serverEpgUrl != null && serverEpgUrl.isNotEmpty) {
      _lunaTvEpgUrl = serverEpgUrl;
    }

    // 优先从缓存读取
    final cacheKey = CacheService().generateLiveChannelsCacheKey(sourceKey: key);
    final cacheHours = await UserDataService.getLiveSourceCacheHours();
    final cached = await CacheService().get<List<dynamic>>(
      cacheKey,
      (data) => data as List<dynamic>,
    );

    List<LiveChannel> channels;
    String? fillUrl;
    if (cached != null) {
      channels = cached
          .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
          .toList();
      // 旧缓存可能缺失 EPG/catchup 信息，若检测到缺失则尝试从原始订阅地址补全。
      final needFill = channels.any(
        (c) =>
            ((c.catchup == null || c.catchup!.isEmpty) &&
                (c.catchupSource == null || c.catchupSource!.isEmpty)) ||
            c.programs.isEmpty,
      );
      if (needFill) {
        fillUrl = _extractSourceUrlFromChannels(channels) ?? url;
        if (fillUrl != null && fillUrl.isNotEmpty) {
          print('LunaTV 源缓存命中但缺少 catchup，尝试从 $fillUrl 补全');
          await _fillEpgAndCatchupFromM3uUrl(channels, fillUrl);
        }
        // 补全后回写缓存，避免下次继续缺失。
        await CacheService().set(
          cacheKey,
          channels.map((c) => c.toJson()).toList(),
          Duration(hours: cacheHours),
        );
      }
      return ApiResponse.success(channels);
    }

    // 缓存未命中，从服务器拉取
    final response = await LunaTVService.getLiveChannels(sourceKey: key);
    if (response.success && response.data != null) {
      channels = response.data!;
      // LunaTV 服务端返回的频道可能丢失了 M3U 头中的 EPG 与 catchup 信息，
      // 尝试从原始订阅地址补全。
      fillUrl = _extractSourceUrlFromChannels(channels) ?? url;
      if (fillUrl != null && fillUrl.isNotEmpty) {
        print('LunaTV 源从服务器拉取，尝试从 $fillUrl 补全 EPG/catchup');
        await _fillEpgAndCatchupFromM3uUrl(channels, fillUrl);
      }
      // 缓存频道数据
      await CacheService().set(
        cacheKey,
        channels.map((c) => c.toJson()).toList(),
        Duration(hours: cacheHours),
      );
      return ApiResponse.success(channels, statusCode: response.statusCode);
    }
    return response;
  }

  /// 从频道列表中提取可能的原始订阅地址。
  static String? _extractSourceUrlFromChannels(List<LiveChannel> channels) {
    if (channels.isEmpty) return null;
    final firstUrl = channels.first.url;
    try {
      final uri = Uri.parse(firstUrl);
      final segments = uri.pathSegments;
      if (segments.isEmpty) return null;
      // 去掉最后一个路径段（通常是频道 ID），保留基础订阅路径。
      final basePath = segments.sublist(0, segments.length - 1).join('/');
      return '${uri.scheme}://${uri.host}${uri.port != 0 && uri.port != (uri.scheme == 'https' ? 443 : 80) ? ':${uri.port}' : ''}/${basePath.isNotEmpty ? '$basePath/' : ''}';
    } catch (_) {
      return null;
    }
  }

  /// 从指定 URL 下载 M3U，提取 EPG 地址与每个频道的 catchup 信息，并回填到 [channels]。
  static Future<void> _fillEpgAndCatchupFromM3uUrl(
    List<LiveChannel> channels,
    String url,
  ) async {
    final candidates = _buildM3uUrlCandidates(url);
    for (final candidate in candidates) {
      try {
        final response = await http
            .get(
              Uri.parse(candidate),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
                'Accept': '*/*',
              },
            )
            .timeout(_fetchTimeout);
        if (response.statusCode != 200) continue;
        final content = utf8.decode(response.bodyBytes, allowMalformed: true);
        if (!content.trim().toUpperCase().startsWith('#EXTM3U')) continue;

        // 提取 EPG URL
        final epgUrl = _parseM3uHeaderEpgUrl(content.split('\n').first.trim());
        if (epgUrl != null && epgUrl.isNotEmpty) {
          lastEpgUrl = epgUrl;
          _lunaTvEpgUrl = epgUrl;
        }

        // 提取每个频道的 catchup 信息
        final (catchupMap, defaultCatchup) = _extractCatchupMap(content);
        var filledCount = 0;
        var globalFilledCount = 0;
        for (final channel in channels) {
          final info = _findCatchupInfo(channel, catchupMap);
          if (info != null) {
            final index = channels.indexOf(channel);
            channels[index] = channel.copyWith(
              catchup: info.catchup,
              catchupSource: info.catchupSource,
              catchupDays: info.catchupDays,
            );
            filledCount++;
          } else if (defaultCatchup.catchup != null ||
              defaultCatchup.catchupSource != null) {
            // 若频道未单独匹配到，但 M3U 头存在全局 catchup，则应用全局默认值。
            final index = channels.indexOf(channel);
            channels[index] = channel.copyWith(
              catchup: defaultCatchup.catchup,
              catchupSource: defaultCatchup.catchupSource,
              catchupDays: defaultCatchup.catchupDays,
            );
            globalFilledCount++;
          }
        }
        print(
          'LunaTV 源从 $candidate 补全了 $filledCount 个频道的 catchup 信息'
          '（全局默认值覆盖 $globalFilledCount 个）',
        );
        // 调试：输出前 5 个未匹配到的频道及其 key，便于排查名称不一致问题。
        final unmatched = channels
            .where(
              (c) =>
                  _findCatchupInfo(c, catchupMap) == null &&
                  (defaultCatchup.catchup == null &&
                      defaultCatchup.catchupSource == null),
            )
            .take(5)
            .toList();
        if (unmatched.isNotEmpty) {
          print('未匹配到 catchup 的频道: ${unmatched.map((c) => '${c.name}(tvgId=${c.tvgId}, key=${c.tvgId?.trim().toLowerCase() ?? c.name.trim().toLowerCase()})').join(', ')}');
        }
        return;
      } catch (e) {
        print('LunaTV 源尝试 $candidate 失败: $e');
      }
    }
  }

  /// 按 tvgId、名称、清洗后的名称在 [catchupMap] 中查找最匹配的 catchup 信息。
  static _CatchupInfo? _findCatchupInfo(
    LiveChannel channel,
    Map<String, _CatchupInfo> catchupMap,
  ) {
    // 1. 按 tvgId 精确匹配（不区分大小写）。
    final tvgId = channel.tvgId?.trim().toLowerCase();
    if (tvgId != null && tvgId.isNotEmpty) {
      final info = catchupMap[tvgId];
      if (info != null) return info;
    }

    // 2. 按频道名称精确匹配（不区分大小写）。
    final name = channel.name.trim().toLowerCase();
    final nameInfo = catchupMap[name];
    if (nameInfo != null) return nameInfo;

    // 3. 按清洗后的名称匹配：移除空格、横杠、下划线、点以及常见后缀。
    final normalizedName = _normalizeChannelName(name);
    if (normalizedName.isEmpty) return null;
    for (final entry in catchupMap.entries) {
      if (_normalizeChannelName(entry.key) == normalizedName) {
        return entry.value;
      }
    }
    return null;
  }

  /// 清洗频道名称用于模糊匹配。
  static String _normalizeChannelName(String name) {
    return name
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_\.]+'), '')
        .replaceAll(RegExp(r'(综合|高清|hd|超清|uhd|4k|8k|卫视)'), '');
  }

  /// 构建可能的 M3U 订阅地址候选列表。
  static List<String> _buildM3uUrlCandidates(String url) {
    final candidates = <String>[url];
    final trimmed = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
    if (trimmed != url) candidates.add(trimmed);
    if (!url.toLowerCase().endsWith('.m3u') &&
        !url.toLowerCase().endsWith('.m3u8')) {
      candidates.add('$trimmed.m3u');
      candidates.add('$trimmed/index.m3u');
      candidates.add('$url/index.m3u');
    }
    return candidates;
  }

  /// 从 M3U 内容中提取每个频道的 catchup 信息。
  ///
  /// 返回的元组中第一个元素为按 tvgId / 名称建立的 catchup 映射，
  /// 第二个元素为 M3U 头中的全局 catchup 默认值（供未单独指定的频道使用）。
  static (Map<String, _CatchupInfo>, _CatchupInfo) _extractCatchupMap(
    String content,
  ) {
    final result = <String, _CatchupInfo>{};
    final lines = content.split('\n');
    // M3U 头中的全局 catchup 默认值。
    String? defaultCatchup;
    String? defaultCatchupSource;
    int? defaultCatchupDays;
    String? pendingName;
    String? pendingTvgId;
    String? pendingTvgName;
    String? pendingCatchup;
    String? pendingCatchupSource;
    int? pendingCatchupDays;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.toUpperCase().startsWith('#EXTM3U')) {
        final headerInfo = _parseM3uHeaderCatchup(line);
        defaultCatchup = headerInfo.catchup;
        defaultCatchupSource = headerInfo.catchupSource;
        defaultCatchupDays = headerInfo.catchupDays;
        continue;
      }

      if (line.toUpperCase().startsWith('#EXTINF')) {
        final attrs = _parseExtinfAttributes(line);
        pendingName = _parseExtinfName(line) ?? '';
        pendingTvgId = attrs['tvg-id'] ?? attrs['tvg_id'];
        pendingTvgName = attrs['tvg-name'] ?? attrs['tvg_name'];
        pendingCatchup = attrs['catchup'];
        pendingCatchupSource = attrs['catchup-source'] ?? attrs['catchup_source'];
        pendingCatchupDays = int.tryParse(
          attrs['catchup-days'] ?? attrs['catchup_days'] ?? '',
        );
        continue;
      }

      if (line.startsWith('#')) continue;

      if (pendingName != null && pendingName.isNotEmpty) {
        final info = _CatchupInfo(
          catchup: pendingCatchup ?? defaultCatchup,
          catchupSource: pendingCatchupSource ?? defaultCatchupSource,
          catchupDays: pendingCatchupDays ?? defaultCatchupDays,
        );
        if (pendingTvgId != null && pendingTvgId.trim().isNotEmpty) {
          result[pendingTvgId.trim().toLowerCase()] = info;
        }
        if (pendingTvgName != null && pendingTvgName.trim().isNotEmpty) {
          result[pendingTvgName.trim().toLowerCase()] = info;
        }
        result[pendingName.trim().toLowerCase()] = info;
      }
      pendingName = null;
      pendingTvgId = null;
      pendingTvgName = null;
      pendingCatchup = null;
      pendingCatchupSource = null;
      pendingCatchupDays = null;
    }
    return (
      result,
      _CatchupInfo(
        catchup: defaultCatchup,
        catchupSource: defaultCatchupSource,
        catchupDays: defaultCatchupDays,
      ),
    );
  }

  /// 清除 LunaTV 内置源的频道缓存。
  static Future<void> clearLunaTvCache({String? key}) async {
    final effectiveKey = key ?? lastLunaTvSourceKey ?? defaultLunaTvSourceKey;
    final cacheKey = CacheService().generateLiveChannelsCacheKey(sourceKey: effectiveKey);
    await CacheService().delete(cacheKey);
  }

  /// 根据直播源加载频道列表。
  static Future<ApiResponse<List<LiveChannel>>> loadChannelsForSource(
    LiveSourceConfig source,
  ) async {
    if (source.isBuiltin) {
      return fetchLunaTvChannels(
        sourceKey: source.sourceKey,
        sourceUrl: source.url.isNotEmpty ? source.url : null,
        epgUrl: source.epgUrl,
      );
    }
    return loadChannelsFromConfig(source);
  }

  /// 根据直播源配置加载频道列表。
  ///
  /// [config.url] 为网络地址时直接下载；为空时返回空列表。
  /// 解析结果会按 [config.id] 缓存到本地，便于退出重进后快速恢复。
  static Future<ApiResponse<List<LiveChannel>>> loadChannelsFromConfig(
    LiveSourceConfig config,
  ) async {
    final url = config.url.trim();
    if (url.isEmpty) {
      return ApiResponse.success([]);
    }

    final cacheKey = _getChannelsCacheKey(config);
    final cacheHours = await UserDataService.getLiveSourceCacheHours();

    // 若配置内容本身即为 M3U/JSON 文本（本地录入），直接解析并不缓存。
    if (url.startsWith('#EXTM3U') || url.trim().startsWith('{')) {
      try {
        final channels = _parseByContent(url);
        return ApiResponse.success(channels);
      } catch (e) {
        return ApiResponse.error('直播源解析失败: $e');
      }
    }

    // 优先读取缓存，缓存命中时立即返回，后台不再强制刷新直播源。
    final cached = await CacheService().get<List<dynamic>>(
      cacheKey,
      (data) => data as List<dynamic>,
    );
    if (cached != null) {
      final channels = cached
          .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
          .toList();
      print('自定义直播源缓存命中: ${config.name}, 频道数: ${channels.length}, '
          '含节目单频道数: ${channels.where((c) => c.programs.isNotEmpty).length}');
      return ApiResponse.success(channels);
    }

    try {
      final response = await http
          .get(
            Uri.parse(url),
            headers: {
              'User-Agent':
                  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                  ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
              'Accept': '*/*',
            },
          )
          .timeout(_fetchTimeout);

      if (response.statusCode != 200) {
        return ApiResponse.error(
          '直播源请求失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      }

      final content = utf8.decode(response.bodyBytes, allowMalformed: true);
      final channels = _parseByContent(content);
      // 若 M3U 头中解析到 EPG 地址，则持久化到对应源配置，便于下次直接拉取。
      if (lastEpgUrl != null &&
          lastEpgUrl!.isNotEmpty &&
          config.epgUrl != lastEpgUrl) {
        await LiveSourceStorage.saveConfig(
          config.copyWith(epgUrl: lastEpgUrl),
        );
      }
      // 缓存频道列表（此时节目单可能为空，EPG 拉取成功后会再次回写）。
      await CacheService().set(
        cacheKey,
        channels.map((c) => c.toJson()).toList(),
        Duration(hours: cacheHours),
      );
      return ApiResponse.success(channels);
    } catch (e) {
      return ApiResponse.error('直播源加载异常: $e');
    }
  }

  /// 获取指定直播源的频道缓存 key。
  static String _getChannelsCacheKey(LiveSourceConfig source) {
    if (source.isBuiltin) {
      return CacheService().generateLiveChannelsCacheKey(
        sourceKey:
            source.sourceKey ?? lastLunaTvSourceKey ?? defaultLunaTvSourceKey,
      );
    }
    return CacheService().generateLiveChannelsCacheKey(sourceKey: source.id);
  }

  /// 将包含节目单的频道数据缓存到指定直播源。
  static Future<void> cacheChannels(
    LiveSourceConfig source,
    List<LiveChannel> channels,
  ) async {
    final cacheKey = _getChannelsCacheKey(source);
    final cacheHours = await UserDataService.getLiveSourceCacheHours();
    await CacheService().set(
      cacheKey,
      channels.map((c) => c.toJson()).toList(),
      Duration(hours: cacheHours),
    );
    print('直播源缓存已更新: ${source.name}, 含节目单频道数: '
        '${channels.where((c) => c.programs.isNotEmpty).length}');
  }

  /// 根据内容自动识别 M3U/M3U8、TXT 或 JSON 并解析。
  static List<LiveChannel> _parseByContent(String content) {
    final trimmed = content.trim();
    if (trimmed.startsWith('#EXTM3U') ||
        trimmed.toUpperCase().contains('#EXTINF')) {
      return parseM3u(content);
    }
    if (trimmed.startsWith('{')) {
      return parseJson(content);
    }
    // TVbox 常见 txt 格式：分组,#genre# + 名称,URL
    if (trimmed.toLowerCase().contains(',#genre#')) {
      return parseTxt(content);
    }
    throw FormatException('不支持的直播源格式');
  }

  /// 解析 M3U/M3U8 内容。
  ///
  /// 连续同名同分组的 #EXTINF 会被合并为单个频道，其下所有 URL 作为备选源
  /// 保存在 [LiveChannel.backupUrls] 中，方便播放时通过左右键切换。
  static List<LiveChannel> parseM3u(String content) {
    final channels = <LiveChannel>[];
    final lines = content.split('\n');

    // M3U 头中的全局 catchup 默认值，频道自身未指定时回退使用。
    String? defaultCatchup;
    String? defaultCatchupSource;
    int? defaultCatchupDays;

    String? pendingName;
    String? pendingLogo;
    String? pendingTvgId;
    String? pendingGroup;
    String? pendingProgram;
    String? pendingCatchup;
    String? pendingCatchupSource;
    int? pendingCatchupDays;
    final pendingUrls = <String>[];

    void flushPending() {
      final name = pendingName;
      if (name != null && pendingUrls.isNotEmpty) {
        final mainUrl = pendingUrls.first;
        final backups = pendingUrls.skip(1).toList();
        channels.add(
          LiveChannel(
            name: name.isNotEmpty ? name : mainUrl,
            url: mainUrl,
            backupUrls: backups,
            logo: pendingLogo,
            tvgId: pendingTvgId,
            group: pendingGroup,
            program: pendingProgram,
            catchup: pendingCatchup ?? defaultCatchup,
            catchupSource: pendingCatchupSource ?? defaultCatchupSource,
            catchupDays: pendingCatchupDays ?? defaultCatchupDays,
          ),
        );
      }
      pendingName = null;
      pendingLogo = null;
      pendingTvgId = null;
      pendingGroup = null;
      pendingProgram = null;
      pendingCatchup = null;
      pendingCatchupSource = null;
      pendingCatchupDays = null;
      pendingUrls.clear();
    }

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) {
        flushPending();
        continue;
      }

      if (line.toUpperCase().startsWith('#EXTM3U')) {
        // 尝试解析源级 EPG 地址。
        final epgUrl = _parseM3uHeaderEpgUrl(line);
        if (epgUrl != null && epgUrl.isNotEmpty) {
          lastEpgUrl = epgUrl;
        }
        // 解析全局 catchup 默认值。
        final headerCatchup = _parseM3uHeaderCatchup(line);
        defaultCatchup = headerCatchup.catchup;
        defaultCatchupSource = headerCatchup.catchupSource;
        defaultCatchupDays = headerCatchup.catchupDays;
        continue;
      }

      if (line.startsWith('#EXTINF')) {
        final attrs = _parseExtinfAttributes(line);
        final name = _parseExtinfName(line) ?? '';
        final group = attrs['group-title'] ?? attrs['group_title'];
        final tvgId = attrs['tvg-id'] ?? attrs['tvg_id'];
        final logo = attrs['tvg-logo'] ?? attrs['tvg_logo'];
        final program = attrs['program'] ?? attrs['epg'];
        final catchup = attrs['catchup'];
        final catchupSource = attrs['catchup-source'] ?? attrs['catchup_source'];
        final catchupDays = int.tryParse(
          attrs['catchup-days'] ?? attrs['catchup_days'] ?? '',
        );

        // 若名称/分组发生变化，则先落盘上一个频道。
        if (pendingName != null &&
            (pendingName != name || pendingGroup != group)) {
          flushPending();
        }

        pendingName = name;
        pendingTvgId = tvgId;
        pendingLogo = logo;
        pendingGroup = group;
        pendingProgram = program;
        pendingCatchup = catchup;
        pendingCatchupSource = catchupSource;
        pendingCatchupDays = catchupDays;
        continue;
      }

      if (line.startsWith('#')) continue;

      // 媒体行；同一 #EXTINF 后的多个 URL 视为同一频道的备选源。
      if (pendingName != null && line.isNotEmpty) {
        pendingUrls.add(line);
      }
    }

    flushPending();
    return channels;
  }

  /// 解析 #EXTM3U 头中的 url-tvg / x-tvg-url 属性。
  static String? _parseM3uHeaderEpgUrl(String line) {
    final patterns = [
      RegExp(r'url-tvg="([^"]+)"', caseSensitive: false),
      RegExp(r"url-tvg='([^']+)'", caseSensitive: false),
      RegExp(r'x-tvg-url="([^"]+)"', caseSensitive: false),
      RegExp(r"x-tvg-url='([^']+)'", caseSensitive: false),
    ];
    for (final pattern in patterns) {
      final match = pattern.firstMatch(line);
      if (match != null) {
        return match.group(1)?.trim();
      }
    }
    return null;
  }

  /// 解析 #EXTM3U 头中的全局 catchup / catchup-source / catchup-days 默认值。
  static _CatchupInfo _parseM3uHeaderCatchup(String line) {
    final attrs = _parseExtinfAttributes(line);
    return _CatchupInfo(
      catchup: attrs['catchup'],
      catchupSource: attrs['catchup-source'] ?? attrs['catchup_source'],
      catchupDays: int.tryParse(
        attrs['catchup-days'] ?? attrs['catchup_days'] ?? '',
      ),
    );
  }

  /// 从 #EXTINF 行解析属性字典。
  static Map<String, String> _parseExtinfAttributes(String line) {
    final result = <String, String>{};
    final pattern = RegExp(r'([a-zA-Z0-9_-]+)="([^"]*)"');
    for (final match in pattern.allMatches(line)) {
      result[match.group(1)!.toLowerCase()] = match.group(2)!;
    }
    final singlePattern = RegExp(r"([a-zA-Z0-9_-]+)='([^']*)'");
    for (final match in singlePattern.allMatches(line)) {
      result[match.group(1)!.toLowerCase()] = match.group(2)!;
    }
    return result;
  }

  /// 从 #EXTINF 行解析频道名称（逗号之后）。
  static String? _parseExtinfName(String line) {
    final commaIndex = line.lastIndexOf(',');
    if (commaIndex < 0) return null;
    return line.substring(commaIndex + 1).trim();
  }

  /// 解析 JSON 内容。
  static List<LiveChannel> parseJson(String content) {
    final jsonData = json.decode(content) as Map<String, dynamic>;
    final channelsData = jsonData['channels'] as List<dynamic>?;
    if (channelsData == null) return [];
    return channelsData
        .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  /// 解析 TVbox 常见 txt 格式内容。
  ///
  /// 格式示例：
  /// ```
  /// 央视,#genre#
  /// CCTV1综合,https://example.com/cctv1.m3u8
  /// 卫视,#genre#
  /// 湖南卫视,https://example.com/hunan.m3u8
  /// ```
  static List<LiveChannel> parseTxt(String content) {
    final channels = <LiveChannel>[];
    final lines = content.split('\n');
    String? currentGroup;

    for (var raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;

      // 分组行：名称,#genre#
      if (line.toLowerCase().contains(',#genre#')) {
        final parts = line.split(',');
        if (parts.isNotEmpty && parts.first.trim().isNotEmpty) {
          currentGroup = parts.first.trim();
        }
        continue;
      }

      if (line.startsWith('#')) continue;

      // 频道行：名称,URL 或 名称,URL,节目单（取第一个逗号前为名称，第一个逗号与第二个逗号之间为 URL）
      final firstComma = line.indexOf(',');
      if (firstComma > 0) {
        final name = line.substring(0, firstComma).trim();
        final rest = line.substring(firstComma + 1).trim();
        final secondComma = rest.indexOf(',');
        final url = secondComma > 0
            ? rest.substring(0, secondComma).trim()
            : rest;
        final program = secondComma > 0
            ? rest.substring(secondComma + 1).trim()
            : null;
        if (name.isNotEmpty && url.isNotEmpty) {
          channels.add(
            LiveChannel(
              name: name,
              url: url,
              group: currentGroup,
              program: program?.isNotEmpty == true ? program : null,
            ),
          );
        }
      }
    }

    return channels;
  }

  /// 按分组归类频道，保持源文件中的原始顺序。
  ///
  /// 使用 [LinkedHashMap] 保证分组按第一次出现的顺序排列，
  /// 未分组的频道放入「其他」。
  static Map<String, List<LiveChannel>> groupChannels(
    List<LiveChannel> channels,
  ) {
    final result = LinkedHashMap<String, List<LiveChannel>>();
    for (final channel in channels) {
      final group = (channel.group ?? '其他').trim();
      result.putIfAbsent(group, () => []).add(channel);
    }
    return result;
  }

  /// 拉取并解析 EPG 节目单，将当前节目信息回填到频道列表中。
  ///
  /// [epgUrl] 优先使用传入值；若为空则回退到 [lastEpgUrl]。
  /// 支持多个 EPG 地址（逗号/空格分隔），逐个尝试直到成功。
  /// 匹配规则：先按 [LiveChannel.tvgId] 与 XMLTV channel id 匹配，
  /// 未命中时再用 [LiveChannel.name] 与 channel display-name 模糊匹配。
  static Future<void> fetchEpg(
    List<LiveChannel> channels, {
    String? epgUrl,
  }) async {
    var urls = <String>[];
    final primary = epgUrl?.trim() ?? '';
    final fallback = lastEpgUrl?.trim() ?? '';
    if (primary.isNotEmpty) urls.addAll(_splitEpgUrls(primary));
    if (fallback.isNotEmpty && fallback != primary) {
      urls.addAll(_splitEpgUrls(fallback));
    }
    urls = urls.where((u) => u.isNotEmpty).toList();
    if (urls.isEmpty || channels.isEmpty) return;

    for (final url in urls) {
      try {
        print('EPG 拉取: $url');
        final response = await http
            .get(
              Uri.parse(url),
              headers: {
                'User-Agent':
                    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
                    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
                'Accept': '*/*',
              },
            )
            .timeout(const Duration(seconds: 20));

        if (response.statusCode != 200) {
          print('EPG 拉取失败，状态码: ${response.statusCode}');
          continue;
        }
        final content = utf8.decode(response.bodyBytes, allowMalformed: true);
        _applyEpgToChannels(channels, content);
        return;
      } catch (e) {
        print('EPG 拉取失败: $e');
      }
    }
  }

  static List<String> _splitEpgUrls(String value) {
    return value
        .split(RegExp(r'[\s,]+'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
  }

  /// 根据已缓存的节目单刷新每个频道的当前节目信息，无需联网。
  ///
  /// 适用于缓存命中场景：频道列表和节目单从缓存恢复后，按当前时间重新匹配
  /// [LiveChannel.currentProgram] 与 [LiveChannel.program]。
  static void refreshCurrentPrograms(List<LiveChannel> channels) {
    final now = DateTime.now();
    var refreshedCount = 0;
    for (final channel in channels) {
      if (channel.programs.isEmpty) continue;
      EpgProgram? current;
      for (final program in channel.programs) {
        if (program.start.isBefore(now) && program.stop.isAfter(now)) {
          current = program;
          break;
        }
      }
      if (current != null) {
        channel.currentProgram = current;
        channel.program = current.title;
        refreshedCount++;
      }
    }
    print('缓存节目单当前节目刷新: $refreshedCount / ${channels.length}');
  }

  /// 解析 XMLTV 内容并回填当前节目信息。
  static void _applyEpgToChannels(List<LiveChannel> channels, String xml) {
    try {
      final document = XmlDocument.parse(xml);
      final root = document.rootElement;
      if (root.name.local != 'tv') {
        print('EPG 根节点不是 <tv>');
        return;
      }

      // channel id -> display-name 映射
      final channelNames = <String, String>{};
      final displayNameToId = <String, String>{};
      for (final channelNode in root.findElements('channel')) {
        final id = channelNode.getAttribute('id')?.trim() ?? '';
        if (id.isEmpty) continue;
        final displayName = channelNode
                .findElements('display-name')
                .firstOrNull
                ?.innerText
                .trim() ??
            '';
        channelNames[id] = displayName.isNotEmpty ? displayName : id;
        if (displayName.isNotEmpty) {
          displayNameToId[_normalizeName(displayName)] = id;
        }
      }
      print('EPG 频道数: ${channelNames.length}');

      final now = DateTime.now();
      final programsByChannel = <String, List<EpgProgram>>{};

      for (final progNode in root.findElements('programme')) {
        final channelId = progNode.getAttribute('channel')?.trim() ?? '';
        if (channelId.isEmpty) continue;
        final startAttr = progNode.getAttribute('start')?.trim() ?? '';
        final stopAttr = progNode.getAttribute('stop')?.trim() ?? '';
        final start = _parseXmlTvTime(startAttr);
        final stop = _parseXmlTvTime(stopAttr);
        if (start == null || stop == null) continue;
        final title =
            progNode.findElements('title').firstOrNull?.innerText.trim() ?? '';
        if (title.isEmpty) continue;
        programsByChannel
            .putIfAbsent(channelId, () => [])
            .add(EpgProgram(start: start, stop: stop, title: title));
      }

      // 去重并按开始时间排序
      for (final list in programsByChannel.values) {
        final seen = <String>{};
        list.retainWhere((p) {
          final key = '${p.start.millisecondsSinceEpoch}_'
              '${p.stop.millisecondsSinceEpoch}_${p.title}';
          return seen.add(key);
        });
        list.sort((a, b) => a.start.compareTo(b.start));
      }

      var matchedCount = 0;
      for (final channel in channels) {
        final matchedId = _matchEpgChannelId(
          channel,
          programsByChannel,
          channelNames,
          displayNameToId,
        );
        if (matchedId == null) continue;
        final programs = programsByChannel[matchedId]!;
        EpgProgram? current;
        for (final program in programs) {
          if (program.start.isBefore(now) && program.stop.isAfter(now)) {
            current = program;
            break;
          }
        }
        if (programs.isNotEmpty) {
          channel.programs = programs;
        }
        if (current != null) {
          channel.currentProgram = current;
          channel.program = current.title;
          matchedCount++;
        }
    }
    print('EPG 匹配成功频道数: $matchedCount / ${channels.length}');
    } catch (e) {
      print('EPG 解析失败: $e');
    }
  }

  static String? _matchEpgChannelId(
    LiveChannel channel,
    Map<String, List<EpgProgram>> programsByChannel,
    Map<String, String> channelNames,
    Map<String, String> displayNameToId,
  ) {
    final tvgId = (channel.tvgId ?? '').trim();
    final name = channel.name.trim();

    // 1. 精确 tvg-id 匹配（大小写不敏感）
    if (tvgId.isNotEmpty) {
      for (final id in programsByChannel.keys) {
        if (id.toLowerCase() == tvgId.toLowerCase()) return id;
      }
    }

    // 2. 精确名称匹配 channel id / display-name（大小写不敏感）
    if (name.isNotEmpty) {
      for (final entry in channelNames.entries) {
        if (entry.key.toLowerCase() == name.toLowerCase() ||
            entry.value.toLowerCase() == name.toLowerCase()) {
          if (programsByChannel.containsKey(entry.key)) return entry.key;
        }
      }
    }

    // 3. 规范化名称模糊匹配
    final normalizedName = _normalizeName(name);
    if (normalizedName.isNotEmpty) {
      if (displayNameToId.containsKey(normalizedName)) {
        return displayNameToId[normalizedName];
      }
      for (final entry in channelNames.entries) {
        if (_normalizeName(entry.key) == normalizedName ||
            _normalizeName(entry.value) == normalizedName) {
          if (programsByChannel.containsKey(entry.key)) return entry.key;
        }
      }
    }

    // 4. 子串匹配：EPG 名称包含频道名或频道名包含 EPG 名称
    if (name.isNotEmpty) {
      final lowerName = name.toLowerCase();
      for (final entry in channelNames.entries) {
        final lowerId = entry.key.toLowerCase();
        final lowerDisplay = entry.value.toLowerCase();
        if (lowerId.contains(lowerName) ||
            lowerDisplay.contains(lowerName) ||
            lowerName.contains(lowerId) ||
            lowerName.contains(lowerDisplay)) {
          if (programsByChannel.containsKey(entry.key)) return entry.key;
        }
      }
    }

    return null;
  }

  static String _normalizeName(String? value) {
    if (value == null) return '';
    return value
        .toLowerCase()
        .replaceAll(RegExp(r'[\s\-_\.\(\)\[\]]+'), '')
        .trim();
  }

  /// 解析 XMLTV 时间字符串，如 `20260815050000 +0800` 或 `2026-08-15 05:00:00`。
  static DateTime? _parseXmlTvTime(String value) {
    if (value.isEmpty) return null;
    // 尝试标准 XMLTV 格式：YYYYMMDDHHMMSS [+-]HHMM
    final match = RegExp(
      r'^(\d{4})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})\s*([+-]\d{2})(\d{2})?',
    ).firstMatch(value.trim());
    if (match != null) {
      final year = int.tryParse(match.group(1)!);
      final month = int.tryParse(match.group(2)!);
      final day = int.tryParse(match.group(3)!);
      final hour = int.tryParse(match.group(4)!);
      final minute = int.tryParse(match.group(5)!);
      final second = int.tryParse(match.group(6)!);
      if (year != null &&
          month != null &&
          day != null &&
          hour != null &&
          minute != null &&
          second != null) {
        try {
          var dt = DateTime.utc(year, month, day, hour, minute, second);
          final tzHours = int.tryParse(match.group(7)!) ?? 0;
          final tzMinutes = int.tryParse(match.group(8) ?? '0') ?? 0;
          final offsetMinutes = tzHours.abs() * 60 + tzMinutes;
          if (tzHours < 0) {
            dt = dt.add(Duration(minutes: offsetMinutes));
          } else {
            dt = dt.subtract(Duration(minutes: offsetMinutes));
          }
          return dt.toLocal();
        } catch (_) {
          return null;
        }
      }
    }

    // 尝试 ISO 8601 风格
    final iso = DateTime.tryParse(value);
    if (iso != null) return iso.toLocal();

    return null;
  }
}
