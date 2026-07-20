import 'package:flutter/material.dart';

/// M3U8 去广告过滤器。
///
/// 纯客户端本地过滤，不依赖服务器下发规则。
class M3u8AdFilter {
  static const String _tagDiscontinuity = '#EXT-X-DISCONTINUITY';
  static const String _tagMediaDuration = '#EXTINF';
  static const String _tagEndList = '#EXT-X-ENDLIST';
  static const String _tagKey = '#EXT-X-KEY';
  static const String _tagMap = '#EXT-X-MAP';
  static const String _tagCueOut = '#EXT-X-CUE-OUT';
  static const String _tagCueIn = '#EXT-X-CUE-IN';
  static const String _tagDateRange = '#EXT-X-DATERANGE';

  static final RegExp _regexMediaDuration = RegExp(r'#EXTINF:([\d\.]+)\b');
  static final RegExp _regexUri = RegExp(r'URI="(.+?)"');

  // 广告片段 URL 特征识别
  static final RegExp _regexAdSegmentUri = RegExp(
    r'(^|[/?&=_.-])(ads?|adv|advert(ise(ment)?)?|commercial|preroll|pre-roll|midroll|mid-roll|postroll|post-roll|sponsor|scte|vast|vmap|interstitial|bumper|pangolin|cmaz|pcdn|baidustatic|admarvel|admob|adsense|inmobi|mopub|unityads|vungle|applovin|chartboost|ironsource|startapp|adcolony|gdt|toutiao|bdstatic|sigmob|mobvista|ivideo|gdtimg|mob|tanx|umeng|aliyun|qiniudn|qiniup|kuaishou|douyincdn|bytedance|pstatp|snssdk|bdimg|baidu|360buy|jdcdn|awsstatic|cloudfront|jsdeliver|unpkg|cdnjs)([/?&=_.-]|$)',
    caseSensitive: false,
  );

  // 常见广告 CDN 域名/路径特征
  static const List<String> _adDomainKeywords = [
    'adservice',
    'adserver',
    'adsystem',
    'doubleclick',
    'googlesyndication',
    'advertising',
    '2mdn.net',
    'moatads',
    'scorecardresearch',
    'quantserve',
    'pangolin',
    'cmaz',
    'pcdn',
    'baidustatic',
    'admarvel',
    'admob',
    'adsense',
    'inmobi',
    'mopub',
    'unityads',
    'vungle',
    'applovin',
    'chartboost',
    'ironsource',
    'startapp',
    'adcolony',
    'gdt',
    'toutiao',
    'bdstatic',
    'sigmob',
    'mobvista',
    'ivideo',
    'gdtimg',
    'tanx',
    'umeng',
    'qiniudn',
    'qiniup',
    'kuaishou',
    'douyincdn',
    'bytedance',
    'pstatp',
    'snssdk',
    'bdimg',
    '360buy',
    'jdcdn',
    'awsstatic',
    'cloudfront',
    'jsdeliver',
    'unpkg',
    'cdnjs',
    // 中文常见广告关键词补充
    'guanggao',
    'gg.',
    'gg-',
    'adxx',
    'adx.',
    'advideo',
    'advideos',
    'adimg',
    'adimage',
  ];

  // 广告片段常见路径特征
  static const List<String> _adPathPatterns = [
    '/ad/',
    '/ads/',
    '/adv/',
    '/advert/',
    '/advertise/',
    '/commercial/',
    '/preroll/',
    '/midroll/',
    '/postroll/',
    '/sponsor/',
    '/vast/',
    '/vmap/',
    '/cmaf/',
    '/cmaz/',
    '/pcdn/',
    '/ivideo/',
    '/gdt/',
    '/tanx/',
    '/umeng/',
    '/mob/',
    '/asset/',
    '/break/',
    '/spot/',
    '/preview/',
    '/trailer/',
    '/intro/',
    '/recap/',
    '/clip/',
    '/jump/',
    '/promo/',
    '/adtag/',
    '/adsdk/',
    '/adimage/',
    '/adimg/',
    '/adcdn/',
    '/cdn-ad/',
    '/splash/',
    '/insert/',
    '/inset/',
    // 中文常见广告路径补充
    '/gg/',
    '/guanggao/',
    '/advideo/',
    '/advideos/',
    '/adx/',
    '/adxx/',
  ];

  // 广告追踪/跳转常见查询参数
  static const List<String> _adQueryPatterns = [
    'adid=',
    'ad_id=',
    'ads_id=',
    'campaign=',
    'creative=',
    'placement=',
    'trackid=',
    'tracking=',
    'imp=',
    'viewability=',
    // 中文/补充广告参数
    'ad_type=',
    'adtype=',
    'adformat=',
    'ad_format=',
    'adgroup=',
    'ad_group=',
    'adslot=',
    'ad_slot=',
  ];

  int currentAdCount = 0;

  /// 主入口：净化 M3U8 内容。
  /// [baseUrl] 是 M3U8 的基地址，用于相对 URL 绝对化。
  String? purify(String baseUrl, String m3u8content) {
    final start = DateTime.now();
    currentAdCount = 0;

    if (m3u8content.isEmpty) return null;
    var content = m3u8content;
    if (content.startsWith('\uFEFF')) {
      content = content.substring(1);
    }
    if (!content.startsWith('#EXTM3U')) return null;

    final lineSplit = content.contains('\r\n') ? '\r\n' : '\n';
    final lines = content.split(lineSplit);
    var totalSegments = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        totalSegments++;
      }
    }

    var result = _removeMinorityUrl(baseUrl, content);
    if (result != null && currentAdCount > 0) {
      result = _get(baseUrl, result);
    } else {
      result = _get(baseUrl, content);
    }
    result = _keepVodEndList(content, result);

    if (totalSegments > 0 && currentAdCount > totalSegments * 0.5) {
      debugPrint(
        'M3u8AdFilter ERROR: removed too many segments $currentAdCount/$totalSegments, using original content',
      );
      currentAdCount = 0;
      result = content;
    }

    if (currentAdCount > 0 && !_isPlayableMediaPlaylist(result)) {
      debugPrint(
        'M3u8AdFilter ERROR: invalid playlist after ad removal, using original content',
      );
      currentAdCount = 0;
      result = content;
    }

    final cost = DateTime.now().difference(start).inMilliseconds;
    debugPrint(
      'M3u8AdFilter cost: ${cost}ms, removed: $currentAdCount segments',
    );
    return result;
  }

  static double _maxPercent(Map<String, int> preUrlMap) {
    var maxTimes = 0;
    var totalTimes = 0;
    for (final entry in preUrlMap.entries) {
      if (entry.value > maxTimes) maxTimes = entry.value;
      totalTimes += entry.value;
    }
    if (totalTimes == 0) return 0;
    return maxTimes / totalTimes;
  }

  static const int _timesNoAd = 15;

  String? _removeMinorityUrl(String tsUrlPre, String m3u8content) {
    final lineSplit = m3u8content.contains('\r\n') ? '\r\n' : '\n';
    final lines = m3u8content.split(lineSplit);

    var totalSegments = 0;
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isNotEmpty && !trimmed.startsWith('#')) {
        totalSegments++;
      }
    }

    // 第一遍：统计归一化后的媒体路径前缀
    final preUrlMap = <String, int>{};
    for (final line in lines) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      final absoluteUrl = _toAbsoluteUrl(tsUrlPre, line);
      final ilast = absoluteUrl.lastIndexOf('.');
      if (ilast <= 4) continue;
      final preUrl = absoluteUrl.substring(0, ilast - 4);
      preUrlMap[preUrl] = (preUrlMap[preUrl] ?? 0) + 1;
    }

    if (preUrlMap.length <= 1) return null;

    var domainFiltering = false;
    if (_maxPercent(preUrlMap) < 0.8) {
      preUrlMap.clear();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        final absoluteUrl = _toAbsoluteUrl(tsUrlPre, line);
        if (!absoluteUrl.startsWith('http://') &&
            !absoluteUrl.startsWith('https://')) {
          return null;
        }
        final ifirst = absoluteUrl.indexOf('/', 9);
        if (ifirst <= 0) continue;
        final preUrl = absoluteUrl.substring(0, ifirst);
        preUrlMap[preUrl] = (preUrlMap[preUrl] ?? 0) + 1;
      }
      if (preUrlMap.length <= 1) return null;
      if (_maxPercent(preUrlMap) < 0.8) return null;

      var allDomainsExceedThreshold = true;
      for (final count in preUrlMap.values) {
        if (count <= _timesNoAd) {
          allDomainsExceedThreshold = false;
          break;
        }
      }
      if (allDomainsExceedThreshold) return null;
      domainFiltering = true;
    }

    // 保留占比最高的前缀或域名
    var maxTimes = 0;
    var maxTimesPreUrl = '';
    for (final entry in preUrlMap.entries) {
      if (entry.value > maxTimes) {
        maxTimesPreUrl = entry.key;
        maxTimes = entry.value;
      }
    }
    if (maxTimes == 0) return null;

    debugPrint(
      'M3u8AdFilter URL pattern count: ${preUrlMap.length}, maxTimes: $maxTimes, total: $totalSegments',
    );

    final filtered = StringBuffer();
    final pendingSegmentTags = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final item = raw.trim();

      if (item.isEmpty) {
        if (pendingSegmentTags.isEmpty) {
          _appendLine(filtered, raw, lineSplit);
        } else {
          pendingSegmentTags.add(raw);
        }
        continue;
      }

      if (item.startsWith('#')) {
        final output = _hasUriAttribute(item)
            ? _resolveUriLine(tsUrlPre, raw)
            : raw;
        if (_isSegmentTag(item)) {
          pendingSegmentTags.add(output);
        } else {
          _flush(filtered, pendingSegmentTags, lineSplit);
          _appendLine(filtered, output, lineSplit);
        }
        continue;
      }

      final absoluteUrl = _toAbsoluteUrl(tsUrlPre, raw);
      if (_shouldKeepMediaUrl(
        absoluteUrl,
        domainFiltering,
        maxTimesPreUrl,
        preUrlMap,
      )) {
        _flush(filtered, pendingSegmentTags, lineSplit);
        _appendLine(filtered, absoluteUrl, lineSplit);
      } else {
        pendingSegmentTags.clear();
        currentAdCount += 1;
      }
    }

    if (totalSegments > 0 && currentAdCount > totalSegments * 0.3) {
      debugPrint(
        'M3u8AdFilter suspicious ad count: $currentAdCount/$totalSegments, skipping URL filtering',
      );
      currentAdCount = 0;
      return null;
    }

    return _normalizeMediaPlaylist(filtered.toString());
  }

  String _get(String tsUrlPre, String m3u8Content) {
    var line = _resolveContent(tsUrlPre, m3u8Content);
    line = _cleanEdgeShortAds(tsUrlPre, line);
    line = _cleanEmbeddedShortAds(tsUrlPre, line);
    line = _cleanCommonAdMarkers(tsUrlPre, line);
    line = _scanDiscontinuityGroupsByDuration(tsUrlPre, line);
    line = _scanDiscontinuityBoundaries(tsUrlPre, line);
    return _cleanDiscontinuityGroups(tsUrlPre, line);
  }

  /// 检测并移除开头/结尾的贴片广告：
  /// 这些广告通常时长很短（如 3-15 秒），且与后续正片使用不同的域名或路径。
  /// 即使没有 #EXT-X-DISCONTINUITY 也能识别。
  String _cleanEdgeShortAds(String tsUrlPre, String m3u8Content) {
    final lines = m3u8Content.replaceAll('\r\n', '\n').split('\n');
    final segments = <_SegmentInfo>[];
    var pendingTagIndices = <int>[];
    int? pendingDurationIndex;
    double? pendingDuration;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final item = raw.trim();
      if (item.isEmpty || item.startsWith('#EXTM3U')) continue;

      if (item.startsWith('#EXTINF')) {
        pendingDurationIndex = i;
        final match = _regexMediaDuration.firstMatch(item);
        pendingDuration = double.tryParse(match?.group(1) ?? '0') ?? 0;
        continue;
      }

      if (item.startsWith('#')) {
        if (_isSegmentTag(item) || _isAdSignalTag(item)) {
          pendingTagIndices.add(i);
        }
        continue;
      }

      final absoluteUrl = _toAbsoluteUrl(tsUrlPre, raw);
      segments.add(
        _SegmentInfo(
          index: i,
          url: absoluteUrl,
          durationIndex: pendingDurationIndex,
          duration: pendingDuration ?? 0,
          tagIndices: List<int>.from(pendingTagIndices),
        ),
      );
      pendingTagIndices.clear();
      pendingDurationIndex = null;
      pendingDuration = null;
    }

    if (segments.length < 4) return m3u8Content;

    // 计算正片平均时长（去掉最短和最长的各 25% 后取平均，避免广告干扰）
    final sortedByDuration = List<_SegmentInfo>.from(segments)
      ..sort((a, b) => a.duration.compareTo(b.duration));
    final trimCount = (sortedByDuration.length * 0.25).floor();
    final middle = sortedByDuration.skip(trimCount).take(
      sortedByDuration.length - trimCount * 2,
    );
    if (middle.isEmpty) return m3u8Content;
    final avgDuration =
        middle.map((s) => s.duration).reduce((a, b) => a + b) / middle.length;
    if (avgDuration <= 0) return m3u8Content;

    // 记录需要保留的索引
    final keepIndices = <int>{};
    for (var i = 0; i < lines.length; i++) {
      keepIndices.add(i);
    }

    // 从头开始检查：短片段 + 域名/路径不同 => 广告
    var removedCount = 0;
    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      // 只处理前 8 个或后 8 个片段，贴片广告可能连续插入较多。
      if (i > 7 && i < segments.length - 8) continue;

      final isShort = seg.duration > 0 && seg.duration < avgDuration * 0.45;
      final isVeryShort = seg.duration > 0 && seg.duration < 6.0;
      if (!isShort && !isVeryShort) continue;

      // 与相邻正片比较域名/路径
      final neighborIndex = i <= 7
          ? (segments.length > 8 ? 8 : segments.length - 1)
          : segments.length - 9;
      final neighbor = segments[neighborIndex];
      final segHost = _hostOf(seg.url);
      final neighborHost = _hostOf(neighbor.url);
      final segPath = _pathPrefixOf(seg.url);
      final neighborPath = _pathPrefixOf(neighbor.url);
      final differentHost = segHost.isNotEmpty &&
          neighborHost.isNotEmpty &&
          segHost != neighborHost;
      final differentPath =
          segPath.isNotEmpty && neighborPath.isNotEmpty && segPath != neighborPath;
      final hasAd = _hasAdFeature(seg.url);

      if (hasAd ||
          differentHost ||
          (differentPath && (isShort || isVeryShort))) {
        keepIndices.remove(seg.index);
        if (seg.durationIndex != null) keepIndices.remove(seg.durationIndex!);
        for (final tagIdx in seg.tagIndices) {
          keepIndices.remove(tagIdx);
        }
        removedCount++;
      }
    }

    if (removedCount == 0) return m3u8Content;

    final sb = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (keepIndices.contains(i)) {
        sb.writeln(lines[i]);
      }
    }
    currentAdCount += removedCount;
    return _normalizeMediaPlaylist(sb.toString());
  }

  /// 检测并移除中间嵌入的短时长广告簇。
  ///
  /// 某些播放列表没有 #EXT-X-DISCONTINUITY，广告片段与正片域名/路径相同，
  /// 只能通过“连续多个短片段”这一特征识别。安全起见仅处理小簇，并保留
  ///  majority 校验，避免误删正片。
  String _cleanEmbeddedShortAds(String tsUrlPre, String m3u8Content) {
    final lines = m3u8Content.replaceAll('\r\n', '\n').split('\n');
    final segments = <_SegmentInfo>[];
    var pendingTagIndices = <int>[];
    int? pendingDurationIndex;
    double? pendingDuration;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final item = raw.trim();
      if (item.isEmpty || item.startsWith('#EXTM3U')) continue;

      if (item.startsWith('#EXTINF')) {
        pendingDurationIndex = i;
        final match = _regexMediaDuration.firstMatch(item);
        pendingDuration = double.tryParse(match?.group(1) ?? '0') ?? 0;
        continue;
      }

      if (item.startsWith('#')) {
        if (_isSegmentTag(item) || _isAdSignalTag(item)) {
          pendingTagIndices.add(i);
        }
        continue;
      }

      final absoluteUrl = _toAbsoluteUrl(tsUrlPre, raw);
      segments.add(
        _SegmentInfo(
          index: i,
          url: absoluteUrl,
          durationIndex: pendingDurationIndex,
          duration: pendingDuration ?? 0,
          tagIndices: List<int>.from(pendingTagIndices),
        ),
      );
      pendingTagIndices.clear();
      pendingDurationIndex = null;
      pendingDuration = null;
    }

    if (segments.length < 8) return m3u8Content;

    // 用较长片段的时长作为正片参考，避免广告拉低均值。
    final sortedByDuration = List<_SegmentInfo>.from(segments)
      ..sort((a, b) => a.duration.compareTo(b.duration));
    final longSegments = sortedByDuration
        .skip((sortedByDuration.length * 0.35).floor())
        .where((s) => s.duration > 0)
        .toList();
    if (longSegments.isEmpty) return m3u8Content;
    final mainDuration =
        longSegments.map((s) => s.duration).reduce((a, b) => a + b) /
            longSegments.length;
    if (mainDuration <= 0) return m3u8Content;

    final shortThreshold = mainDuration * 0.45;
    final absoluteShortThreshold = 8.0;

    // 主域名/路径，用于判断广告簇是否与正片不同。
    final mainHost = _hostOf(longSegments.last.url);
    final mainPath = _pathPrefixOf(longSegments.last.url);

    final keepIndices = <int>{};
    for (var i = 0; i < lines.length; i++) {
      keepIndices.add(i);
    }

    var removedCount = 0;
    var clusterStart = -1;
    var clusterEnd = -1;

    void removeCluster(int start, int end) {
      for (var i = start; i <= end && i < segments.length; i++) {
        final seg = segments[i];
        keepIndices.remove(seg.index);
        if (seg.durationIndex != null) keepIndices.remove(seg.durationIndex!);
        for (final tagIdx in seg.tagIndices) {
          keepIndices.remove(tagIdx);
        }
      }
      removedCount += end - start + 1;
    }

    for (var i = 0; i < segments.length; i++) {
      final seg = segments[i];
      final isShort = seg.duration > 0 &&
          seg.duration < shortThreshold &&
          seg.duration < absoluteShortThreshold;

      if (isShort) {
        if (clusterStart < 0) clusterStart = i;
        clusterEnd = i;
      } else {
        if (clusterStart >= 0) {
          final clusterLength = clusterEnd - clusterStart + 1;
          final clusterTotal = segments
              .sublist(clusterStart, clusterEnd + 1)
              .fold<double>(0, (sum, s) => sum + s.duration);
          final first = segments[clusterStart];
          final last = segments[clusterEnd];
          final hasAdFeature = _hasAdFeature(first.url) || _hasAdFeature(last.url);
          final hostChanged = mainHost.isNotEmpty &&
              (_hostOf(first.url) != mainHost || _hostOf(last.url) != mainHost);
          final pathChanged = mainPath.isNotEmpty &&
              (_pathPrefixOf(first.url) != mainPath ||
                  _pathPrefixOf(last.url) != mainPath);

          final surrounded = clusterStart > 0 && clusterEnd < segments.length - 1;
          final durationSpike = clusterTotal > 0 && clusterTotal < mainDuration * 0.6;
          final adLike = hasAdFeature ||
              hostChanged ||
              (clusterLength <= 3 && pathChanged) ||
              (clusterLength <= 2 && surrounded) ||
              (clusterLength <= 3 && surrounded && durationSpike);

          if (clusterLength <= 8 &&
              clusterTotal < mainDuration * 2.2 &&
              adLike) {
            removeCluster(clusterStart, clusterEnd);
          }
        }
        clusterStart = -1;
        clusterEnd = -1;
      }
    }

    // 处理末尾簇。
    if (clusterStart >= 0) {
      final clusterLength = clusterEnd - clusterStart + 1;
      final clusterTotal = segments
          .sublist(clusterStart, clusterEnd + 1)
          .fold<double>(0, (sum, s) => sum + s.duration);
      final first = segments[clusterStart];
      final hasAdFeature = _hasAdFeature(first.url);
      final hostChanged = mainHost.isNotEmpty && _hostOf(first.url) != mainHost;
      final pathChanged = mainPath.isNotEmpty && _pathPrefixOf(first.url) != mainPath;
      final durationSpike = clusterTotal > 0 && clusterTotal < mainDuration * 0.6;
      if (clusterLength <= 8 &&
          clusterTotal < mainDuration * 2.2 &&
          (hasAdFeature ||
              hostChanged ||
              (clusterLength <= 4 && pathChanged) ||
              (clusterLength <= 4 && durationSpike))) {
        removeCluster(clusterStart, clusterEnd);
      }
    }

    if (removedCount == 0) return m3u8Content;
    if (removedCount > segments.length * 0.3) {
      debugPrint(
        'M3u8AdFilter embedded short ads skipped: $removedCount/${segments.length}',
      );
      return m3u8Content;
    }

    final sb = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (keepIndices.contains(i)) {
        sb.writeln(lines[i]);
      }
    }
    currentAdCount += removedCount;
    return _normalizeMediaPlaylist(sb.toString());
  }

  String _resolveContent(String tsUrlPre, String m3u8Content) {
    final content = m3u8Content.replaceAll('\r\n', '\n');
    final sb = StringBuffer();
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      sb.writeln(_shouldResolve(trimmed) ? _resolve(tsUrlPre, trimmed) : line);
    }
    return sb.toString();
  }

  String _cleanCommonAdMarkers(String tsUrlPre, String m3u8Content) {
    final line = _resolveContent(tsUrlPre, m3u8Content);
    final sb = StringBuffer();
    final pending = <String>[];
    var inAdBreak = false;
    var changed = false;

    for (final raw in line.split('\n')) {
      final item = raw.trim();
      if (item.isEmpty) {
        if (pending.isEmpty) {
          sb.writeln(raw);
        } else {
          pending.add(raw);
        }
        continue;
      }

      if (item.startsWith('#')) {
        if (item.startsWith(_tagCueIn)) {
          if (inAdBreak || _hasAdSignal(pending)) {
            inAdBreak = false;
            pending.clear();
            changed = true;
            continue;
          }
        }
        if (_isAdBreakStart(item)) {
          _flush(sb, pending, '\n');
          inAdBreak = true;
          pending.add(raw);
          changed = true;
          continue;
        }
        if (inAdBreak) {
          pending.add(raw);
          changed = true;
          continue;
        }
        if (_isStandaloneAdTag(item)) {
          _flush(sb, pending, '\n');
          currentAdCount += 1;
          changed = true;
          continue;
        }
        if (_isSegmentTag(item) || _isAdSignalTag(item)) {
          pending.add(raw);
        } else {
          _flush(sb, pending, '\n');
          sb.writeln(raw);
        }
        continue;
      }

      if (inAdBreak || _hasAdSignal(pending) || _hasAdFeature(item)) {
        pending.clear();
        currentAdCount += 1;
        changed = true;
        continue;
      }
      _flush(sb, pending, '\n');
      sb.writeln(raw);
    }

    if (!inAdBreak) _flush(sb, pending, '\n');
    return changed ? sb.toString() : line;
  }

  static void _flush(StringBuffer sb, List<String> pending, String lineSplit) {
    for (final line in pending) {
      _appendLine(sb, line, lineSplit);
    }
    pending.clear();
  }

  static void _appendLine(StringBuffer sb, String line, String lineSplit) {
    sb.write(line);
    sb.write(lineSplit);
  }

  static bool _hasAdSignal(List<String> pending) {
    for (final line in pending) {
      final trimmed = line.trim();
      if (_isAdBreakStart(trimmed) || _isAdSignalTag(trimmed)) return true;
    }
    return false;
  }

  static bool _isAdBreakStart(String line) {
    return line.startsWith(_tagCueOut);
  }

  static bool _isAdSignalTag(String line) {
    if (line.startsWith('#EXT-OATCLS-SCTE35')) return true;
    if (line.startsWith('#EXT-X-SCTE35')) return true;
    if (line.startsWith('#EXT-X-SPLICEPOINT-SCTE35')) return true;
    if (line.startsWith('#EXT-X-CUE')) return true;
    if (line.startsWith('#EXT-X-ASSET')) return true;
    if (line.startsWith('#EXT-X-VMAP-AD-BREAK')) return true;
    if (line.startsWith('#EXT-X-AD')) return true;
    if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) return false;
    return false;
  }

  static bool _isSegmentTag(String line) {
    if (line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE')) return false;
    return line.startsWith(_tagMediaDuration) ||
        line.startsWith('#EXT-X-BYTERANGE') ||
        line.startsWith('#EXT-X-PROGRAM-DATE-TIME') ||
        line.startsWith(_tagDiscontinuity) ||
        line.startsWith('#EXT-X-PART') ||
        line.startsWith('#EXT-X-PRELOAD-HINT');
  }

  static bool _isStandaloneAdTag(String line) {
    if (!line.startsWith(_tagDateRange)) return false;
    return _isAdLikeText(line) ||
        line.contains('X-ASSET-URI') ||
        line.contains('X-ASSET-LIST');
  }

  static bool _isAdLikeText(String line) {
    final lower = line.toLowerCase();
    return lower.contains('scte') ||
        lower.contains('cue') ||
        lower.contains('interstitial') ||
        lower.contains('vmap') ||
        lower.contains('vast') ||
        lower.contains('advert') ||
        lower.contains('commercial') ||
        lower.contains('ad-') ||
        lower.contains('ad_') ||
        lower.contains('ad.') ||
        lower.contains('preroll') ||
        lower.contains('midroll') ||
        lower.contains('postroll') ||
        lower.contains('bumper');
  }

  static bool _isAdSegmentUri(String line) {
    return _regexAdSegmentUri.hasMatch(line);
  }

  static bool _hasAdDomain(String url) {
    final lower = url.toLowerCase();
    for (final keyword in _adDomainKeywords) {
      if (lower.contains(keyword)) return true;
    }
    return false;
  }

  static bool _isAdPathPattern(String url) {
    final lower = url.toLowerCase();
    for (final pattern in _adPathPatterns) {
      if (lower.contains(pattern)) return true;
    }
    return false;
  }

  static bool _hasAdQueryParam(String url) {
    final queryIndex = url.indexOf('?');
    if (queryIndex < 0 || queryIndex >= url.length - 1) return false;
    final query = url.substring(queryIndex + 1).toLowerCase();
    for (final pattern in _adQueryPatterns) {
      if (query.contains(pattern)) return true;
    }
    return false;
  }

  /// 综合判断 URL 是否具有广告特征（域名、URI 关键字、路径、查询参数）。
  static bool _hasAdFeature(String url) {
    return _isAdSegmentUri(url) ||
        _hasAdDomain(url) ||
        _isAdPathPattern(url) ||
        _hasAdQueryParam(url);
  }

  /// 基于时长特征扫描 #EXT-X-DISCONTINUITY 分组，删除明显为广告的短分组。
  ///
  /// 某些源在正片之间插入广告时会在广告前后加上 #EXT-X-DISCONTINUITY，
  /// 广告组通常只有 1-2 个片段且总时长明显短于正片组。该方法先按此规则
  /// 扫描并移除可疑分组，作为 [_cleanDiscontinuityGroups] 的前置补充。
  String _scanDiscontinuityGroupsByDuration(
    String tsUrlPre,
    String m3u8Content,
  ) {
    final lines = m3u8Content.replaceAll('\r\n', '\n').split('\n');
    final groups = _buildDiscontinuityGroups(lines);
    if (groups.length < 2) return m3u8Content;

    final main = _findMainGroup(groups);
    if (main == null || main.segmentCount < 3) return m3u8Content;
    final mainAvgDuration = main.totalDuration / main.segmentCount;
    if (mainAvgDuration <= 0) return m3u8Content;

    final keepGroup = List<bool>.filled(groups.length, true);
    var removedCount = 0;

    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      if (group.segmentCount == 0) continue;
      if (group == main) continue;

      final groupAvgDuration = group.totalDuration / group.segmentCount;
      final shortGroup = group.segmentCount <= 5 ||
          (group.totalDuration > 0 && group.totalDuration < main.totalDuration * 0.25);
      final avgDurationTooSmall = groupAvgDuration > 0 && groupAvgDuration < mainAvgDuration * 0.65;

      final differentHost =
          main.host.isNotEmpty && group.host.isNotEmpty && main.host != group.host;
      final differentPath = main.pathPrefix.isNotEmpty &&
          group.pathPrefix.isNotEmpty &&
          main.pathPrefix != group.pathPrefix;
      final hasAdFeature = group.adLikeCount > 0 ||
          _hasAdFeature(group.host) ||
          _hasAdFeature(group.pathPrefix);

      // 开头/结尾贴片广告：与正片域名/路径不同且平均时长明显较短。
      final edgeAdLike = (i == 0 || i == groups.length - 1) &&
          (differentHost || differentPath) &&
          groupAvgDuration > 0 &&
          groupAvgDuration < mainAvgDuration * 0.85;

      // 同时满足"短"且"平均时长明显小于正片"，或有明确广告特征/边缘广告特征时删除。
      if ((shortGroup && avgDurationTooSmall) ||
          (shortGroup && (hasAdFeature || edgeAdLike))) {
        keepGroup[i] = false;
        removedCount += group.segmentCount;
      }
    }

    if (removedCount == 0) return m3u8Content;
    if (removedCount > main.segmentCount * 0.4) {
      debugPrint(
        'M3u8AdFilter duration scan skipped: $removedCount/${main.segmentCount}',
      );
      return m3u8Content;
    }

    final sb = StringBuffer();
    for (var i = 0; i < groups.length; i++) {
      if (keepGroup[i]) {
        groups[i].appendTo(sb);
      }
    }
    currentAdCount += removedCount;
    return _normalizeMediaPlaylist(sb.toString());
  }

  /// 扫描被 #EXT-X-DISCONTINUITY 明确包围的短片段簇。
  ///
  /// 某些源在正片中插入广告时，会在广告前后都加上 discontinuity，
  /// 形成" discontinuity - 1~3 个短片段 - discontinuity "的结构。
  /// 即使广告片段与正片使用相同域名/路径，只要总时长明显短于正片平均时长，
  /// 就判定为广告并移除。
  String _scanDiscontinuityBoundaries(String tsUrlPre, String m3u8Content) {
    final lines = m3u8Content.replaceAll('\r\n', '\n').split('\n');

    // 收集所有 discontinuity 行索引和片段信息。
    final segments = <_SegmentInfo>[];
    final discontinuityIndices = <int>[];
    var pendingTagIndices = <int>[];
    int? pendingDurationIndex;
    double? pendingDuration;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final item = raw.trim();
      if (item.isEmpty || item.startsWith('#EXTM3U')) continue;

      if (item.startsWith(_tagDiscontinuity)) {
        discontinuityIndices.add(i);
        continue;
      }

      if (item.startsWith('#EXTINF')) {
        pendingDurationIndex = i;
        final match = _regexMediaDuration.firstMatch(item);
        pendingDuration = double.tryParse(match?.group(1) ?? '0') ?? 0;
        continue;
      }

      if (item.startsWith('#')) {
        if (_isSegmentTag(item) || _isAdSignalTag(item)) {
          pendingTagIndices.add(i);
        }
        continue;
      }

      final absoluteUrl = _toAbsoluteUrl(tsUrlPre, raw);
      segments.add(
        _SegmentInfo(
          index: i,
          url: absoluteUrl,
          durationIndex: pendingDurationIndex,
          duration: pendingDuration ?? 0,
          tagIndices: List<int>.from(pendingTagIndices),
        ),
      );
      pendingTagIndices.clear();
      pendingDurationIndex = null;
      pendingDuration = null;
    }

    if (segments.length < 4 || discontinuityIndices.length < 2) {
      return m3u8Content;
    }

    // 计算正片平均时长，用较长片段避免广告拉低均值。
    final sortedByDuration = List<_SegmentInfo>.from(segments)
      ..sort((a, b) => a.duration.compareTo(b.duration));
    final longSegments = sortedByDuration
        .skip((sortedByDuration.length * 0.35).floor())
        .where((s) => s.duration > 0)
        .toList();
    if (longSegments.isEmpty) return m3u8Content;
    final mainDuration =
        longSegments.map((s) => s.duration).reduce((a, b) => a + b) /
            longSegments.length;
    if (mainDuration <= 0) return m3u8Content;

    final keepIndices = <int>{};
    for (var i = 0; i < lines.length; i++) {
      keepIndices.add(i);
    }

    var removedCount = 0;

    // 按 discontinuity 把片段分组。
    var segIdx = 0;
    var lastDiscIndex = -1;
    for (var d = 0; d < discontinuityIndices.length; d++) {
      final discIndex = discontinuityIndices[d];
      final clusterSegments = <_SegmentInfo>[];
      while (segIdx < segments.length &&
          segments[segIdx].index > lastDiscIndex &&
          segments[segIdx].index < discIndex) {
        clusterSegments.add(segments[segIdx]);
        segIdx++;
      }

      if (clusterSegments.isNotEmpty) {
        final clusterCount = clusterSegments.length;
        final clusterTotal = clusterSegments.fold<double>(
          0,
          (sum, s) => sum + s.duration,
        );
        // 被 discontinuity 包围的短簇：片段数较少且总时长明显短于正片单片段时长。
        if (clusterCount <= 5 &&
            clusterTotal > 0 &&
            clusterTotal < mainDuration * 0.8) {
          for (final seg in clusterSegments) {
            keepIndices.remove(seg.index);
            if (seg.durationIndex != null) {
              keepIndices.remove(seg.durationIndex!);
            }
            for (final tagIdx in seg.tagIndices) {
              keepIndices.remove(tagIdx);
            }
          }
          removedCount += clusterCount;
        }
      }
      lastDiscIndex = discIndex;
    }

    // 处理最后一个 discontinuity 之后的末尾簇。
    final lastCluster = <_SegmentInfo>[];
    while (segIdx < segments.length && segments[segIdx].index > lastDiscIndex) {
      lastCluster.add(segments[segIdx]);
      segIdx++;
    }
    if (lastCluster.isNotEmpty) {
      final clusterCount = lastCluster.length;
      final clusterTotal = lastCluster.fold<double>(0, (sum, s) => sum + s.duration);
      if (clusterCount <= 5 &&
          clusterTotal > 0 &&
          clusterTotal < mainDuration * 0.8) {
        for (final seg in lastCluster) {
          keepIndices.remove(seg.index);
          if (seg.durationIndex != null) keepIndices.remove(seg.durationIndex!);
          for (final tagIdx in seg.tagIndices) {
            keepIndices.remove(tagIdx);
          }
        }
        removedCount += clusterCount;
      }
    }

    if (removedCount == 0) return m3u8Content;
    if (removedCount > segments.length * 0.3) {
      debugPrint(
        'M3u8AdFilter boundary scan skipped: $removedCount/${segments.length}',
      );
      return m3u8Content;
    }

    final sb = StringBuffer();
    for (var i = 0; i < lines.length; i++) {
      if (keepIndices.contains(i)) {
        sb.writeln(lines[i]);
      }
    }
    currentAdCount += removedCount;
    return _normalizeMediaPlaylist(sb.toString());
  }

  String _cleanDiscontinuityGroups(String tsUrlPre, String m3u8Content) {
    final line = _resolveContent(tsUrlPre, m3u8Content);
    final lines = line.split('\n');
    final groups = _buildDiscontinuityGroups(lines);
    if (groups.length < 2) return line;
    final main = _findMainGroup(groups);
    if (main == null || main.segmentCount < 3) return line;

    final sb = StringBuffer();
    var changed = false;
    for (var i = 0; i < groups.length; i++) {
      final group = groups[i];
      if (_shouldDropGroup(
        group,
        main,
        isFirstGroup: i == 0,
        isLastGroup: i == groups.length - 1,
      )) {
        currentAdCount += group.segmentCount;
        changed = true;
        continue;
      }
      group.appendTo(sb);
    }
    return changed ? sb.toString() : line;
  }

  static List<_Group> _buildDiscontinuityGroups(List<String> lines) {
    final groups = <_Group>[];
    var group = _Group();
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith(_tagDiscontinuity) && group.hasMedia()) {
        groups.add(group);
        group = _Group();
      }
      group.add(raw);
    }
    if (group.hasMedia() || group.lines.isNotEmpty) {
      groups.add(group);
    }
    return groups;
  }

  static _Group? _findMainGroup(List<_Group> groups) {
    _Group? main;
    for (final group in groups) {
      if (group.segmentCount == 0) continue;
      if (main == null || group.score() > main.score()) main = group;
    }
    return main;
  }

  static bool _shouldDropGroup(
    _Group group,
    _Group main, {
    bool isFirstGroup = false,
    bool isLastGroup = false,
  }) {
    if (group == main || group.segmentCount == 0) return false;

    final mainAvgDuration = main.segmentCount > 0
        ? main.totalDuration / main.segmentCount
        : 0;
    final groupAvgDuration = group.segmentCount > 0
        ? group.totalDuration / group.segmentCount
        : 0;

    final differentHost =
        main.host.isNotEmpty &&
        group.host.isNotEmpty &&
        main.host != group.host;

    final differentPath =
        main.pathPrefix.isNotEmpty &&
        group.pathPrefix.isNotEmpty &&
        main.pathPrefix != group.pathPrefix;

    final hasAdFeature =
        group.adLikeCount > 0 ||
        _hasAdFeature(group.host) ||
        _hasAdFeature(group.pathPrefix);

    // 广告组通常很短：片段数少 或 总时长占比小 或 平均时长远小于主内容
    final shortGroup =
        group.segmentCount <= 3 ||
        (main.totalDuration > 0 &&
            group.totalDuration > 0 &&
            group.totalDuration < main.totalDuration * 0.25) ||
        (mainAvgDuration > 0 &&
            groupAvgDuration > 0 &&
            groupAvgDuration < mainAvgDuration * 0.5);

    // 位于开头或结尾的贴片广告：只要路径/域名与主内容不同，
    // 且平均时长明显较短，就倾向于删除。
    final edgeAdLike =
        (isFirstGroup || isLastGroup) &&
        (differentHost || differentPath) &&
        groupAvgDuration > 0 &&
        mainAvgDuration > 0 &&
        groupAvgDuration < mainAvgDuration * 0.75;

    // 有明确广告特征时，即使只有 2 个组也允许删除
    final adLike =
        hasAdFeature ||
        differentHost ||
        (group.segmentCount <= 3 && differentPath) ||
        (groupAvgDuration > 0 && groupAvgDuration < 5.0 && differentPath) ||
        (groupAvgDuration > 0 &&
            mainAvgDuration > 0 &&
            groupAvgDuration < mainAvgDuration * 0.35 &&
            differentPath) ||
        edgeAdLike;

    return shortGroup && adLike;
  }

  static String _hostOf(String url) {
    if (!url.startsWith('http://') && !url.startsWith('https://')) return '';
    final start = url.indexOf('://') + 3;
    final end = url.indexOf('/', start);
    return end > start ? url.substring(start, end) : url.substring(start);
  }

  static String _pathPrefixOf(String url) {
    var clean = url;
    final query = clean.indexOf('?');
    if (query >= 0) clean = clean.substring(0, query);
    final slash = clean.lastIndexOf('/');
    return slash > 0 ? clean.substring(0, slash + 1) : '';
  }

  static String _toAbsoluteUrl(String base, String url) {
    final line = url.trim();
    if (line.isEmpty ||
        line.startsWith('http://') ||
        line.startsWith('https://')) {
      return line;
    }
    try {
      return Uri.parse(base).resolve(line).toString();
    } catch (_) {
      return line;
    }
  }

  static bool _shouldKeepMediaUrl(
    String absoluteUrl,
    bool domainFiltering,
    String maxTimesPreUrl,
    Map<String, int> preUrlMap,
  ) {
    // 明确广告特征的 URL 直接丢弃
    if (_hasAdFeature(absoluteUrl)) return false;

    if (!domainFiltering) return absoluteUrl.startsWith(maxTimesPreUrl);
    final ifirst = absoluteUrl.indexOf('/', 9);
    final domain = (ifirst > 0)
        ? absoluteUrl.substring(0, ifirst)
        : absoluteUrl;
    final cnt = preUrlMap[domain];
    return domain == maxTimesPreUrl || (cnt != null && cnt > _timesNoAd);
  }

  static bool _hasUriAttribute(String line) {
    return line.startsWith(_tagKey) || line.startsWith(_tagMap);
  }

  static String _resolveUriLine(String base, String line) {
    final match = _regexUri.firstMatch(line);
    final value = match?.group(1);
    if (value == null) return line;
    try {
      return line.replaceFirst(
        value,
        Uri.parse(base).resolve(value).toString(),
      );
    } catch (_) {
      return line;
    }
  }

  static String _normalizeMediaPlaylist(String content) {
    final sb = StringBuffer();
    var seenMedia = false;
    var hasPendingDiscontinuity = false;
    var pendingDiscontinuity = '';

    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      final item = raw.trim();
      if (_isDiscontinuityTag(item)) {
        if (seenMedia && !hasPendingDiscontinuity) {
          pendingDiscontinuity = raw;
          hasPendingDiscontinuity = true;
        }
        continue;
      }
      if (hasPendingDiscontinuity) {
        if (item.isEmpty) continue;
        if (!item.startsWith(_tagEndList)) {
          sb.writeln(pendingDiscontinuity);
        }
        hasPendingDiscontinuity = false;
      }
      if (item.isEmpty && sb.isEmpty) continue;
      sb.writeln(raw);
      if (_isMediaUriLine(item)) seenMedia = true;
    }
    return sb.toString();
  }

  static bool _isPlayableMediaPlaylist(String? content) {
    if (content == null || !content.startsWith('#EXTM3U')) return false;
    var mediaCount = 0;
    var pendingExtInf = false;
    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith(_tagMediaDuration)) {
        if (pendingExtInf) return false;
        pendingExtInf = true;
      } else if (_isMediaUriLine(line)) {
        mediaCount += 1;
        pendingExtInf = false;
      } else if (line.startsWith(_tagEndList) && pendingExtInf) {
        return false;
      }
    }
    return mediaCount > 0 && !pendingExtInf;
  }

  static String? _keepVodEndList(String original, String? result) {
    if (result == null) return null;
    if (!_hasEndList(original) || _hasEndList(result)) return result;
    return result + (result.endsWith('\n') ? '' : '\n') + _tagEndList + '\n';
  }

  static bool _hasEndList(String? content) {
    if (content == null) return false;
    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      if (raw.trim().startsWith(_tagEndList)) return true;
    }
    return false;
  }

  static bool _isMediaUriLine(String line) {
    return line.isNotEmpty && !line.startsWith('#');
  }

  static bool _isDiscontinuityTag(String line) {
    return line.startsWith(_tagDiscontinuity) &&
        !line.startsWith('#EXT-X-DISCONTINUITY-SEQUENCE');
  }

  static bool _shouldResolve(String line) {
    if (line.isEmpty) return false;
    return (!line.startsWith('#') && !line.startsWith('http')) ||
        _hasUriAttribute(line);
  }

  static String _resolve(String base, String line) {
    if (_hasUriAttribute(line)) {
      return _resolveUriLine(base, line);
    } else {
      return _toAbsoluteUrl(base, line);
    }
  }
}

class _Group {
  final List<String> lines = [];
  int segmentCount = 0;
  int adLikeCount = 0;
  double totalDuration = 0;
  String host = '';
  String pathPrefix = '';

  void add(String raw) {
    lines.add(raw);
    final line = raw.trim();
    final match = M3u8AdFilter._regexMediaDuration.firstMatch(line);
    if (match != null) {
      final value = double.tryParse(match.group(1) ?? '0') ?? 0;
      totalDuration += value;
    }
    if (line.isEmpty || line.startsWith('#')) {
      if (M3u8AdFilter._isAdSignalTag(line) ||
          M3u8AdFilter._isStandaloneAdTag(line)) {
        adLikeCount += 1;
      }
      return;
    }
    segmentCount += 1;
    if (M3u8AdFilter._hasAdFeature(line)) {
      adLikeCount += 1;
    }
    if (host.isEmpty) host = M3u8AdFilter._hostOf(line);
    if (pathPrefix.isEmpty) pathPrefix = M3u8AdFilter._pathPrefixOf(line);
  }

  bool hasMedia() => segmentCount > 0;

  void appendTo(StringBuffer sb) {
    for (final line in lines) {
      sb.writeln(line);
    }
  }

  double score() => totalDuration > 0 ? totalDuration : segmentCount.toDouble();
}

class _SegmentInfo {
  final int index;
  final String url;
  final int? durationIndex;
  final double duration;
  final List<int> tagIndices;

  _SegmentInfo({
    required this.index,
    required this.url,
    this.durationIndex,
    required this.duration,
    required this.tagIndices,
  });
}
