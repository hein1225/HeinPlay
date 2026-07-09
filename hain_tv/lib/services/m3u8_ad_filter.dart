import 'package:flutter/material.dart';

/// M3U8 去广告过滤器。
///
/// 移植自 TVBoxOS 的 M3u8.java（https://github.com/TVBoxOS/TVBoxOS），
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

  static final RegExp _regexMediaDuration = RegExp(
    r'#EXTINF:([\d\.]+)\b',
  );
  static final RegExp _regexUri = RegExp(r'URI="(.+?)"');

  // 广告片段 URL 特征识别
  static final RegExp _regexAdSegmentUri = RegExp(
    r'(^|[/?&=_.-])(ads?|adv|advert(ise(ment)?)?|commercial|preroll|pre-roll|midroll|mid-roll|postroll|post-roll|sponsor|scte|vast|vmap|interstitial|bumper)([/?&=_.-]|$)',
    caseSensitive: false,
  );

  // 常见广告 CDN 域名特征
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
        final output = _hasUriAttribute(item) ? _resolveUriLine(tsUrlPre, raw) : raw;
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
    line = _cleanCommonAdMarkers(tsUrlPre, line);
    return _cleanDiscontinuityGroups(tsUrlPre, line);
  }

  String _resolveContent(String tsUrlPre, String m3u8Content) {
    final content = m3u8Content.replaceAll('\r\n', '\n');
    final sb = StringBuffer();
    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      sb.writeln(
        _shouldResolve(trimmed) ? _resolve(tsUrlPre, trimmed) : line,
      );
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

      if (inAdBreak ||
          _hasAdSignal(pending) ||
          _isAdSegmentUri(item) ||
          _hasAdDomain(item)) {
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

  static void _flush(
    StringBuffer sb,
    List<String> pending,
    String lineSplit,
  ) {
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

  String _cleanDiscontinuityGroups(String tsUrlPre, String m3u8Content) {
    final line = _resolveContent(tsUrlPre, m3u8Content);
    final lines = line.split('\n');
    final groups = _buildDiscontinuityGroups(lines);
    if (groups.length < 3) return line;
    final main = _findMainGroup(groups);
    if (main == null || main.segmentCount < 3) return line;

    final sb = StringBuffer();
    var changed = false;
    for (final group in groups) {
      if (_shouldDropGroup(group, main)) {
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

  static bool _shouldDropGroup(_Group group, _Group main) {
    if (group == main || group.segmentCount == 0) return false;

    final shortGroup = group.segmentCount <= 2 ||
        (main.totalDuration > 0 &&
            group.totalDuration > 0 &&
            group.totalDuration < main.totalDuration * 0.18);

    final differentHost = main.host.isNotEmpty &&
        group.host.isNotEmpty &&
        main.host != group.host;

    final differentPath = main.pathPrefix.isNotEmpty &&
        group.pathPrefix.isNotEmpty &&
        main.pathPrefix != group.pathPrefix;

    final hasAdFeature = group.adLikeCount > 0 ||
        _hasAdDomain(group.host) ||
        _isAdSegmentUri(group.pathPrefix);

    final adLike = hasAdFeature || differentHost ||
        (group.segmentCount <= 2 && differentPath);

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
    if (!domainFiltering) return absoluteUrl.startsWith(maxTimesPreUrl);
    final ifirst = absoluteUrl.indexOf('/', 9);
    final domain = (ifirst > 0) ? absoluteUrl.substring(0, ifirst) : absoluteUrl;
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
      return line.replaceFirst(value, Uri.parse(base).resolve(value).toString());
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
    return result +
        (result.endsWith('\n') ? '' : '\n') +
        _tagEndList +
        '\n';
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
    if (M3u8AdFilter._isAdSegmentUri(line) ||
        M3u8AdFilter._hasAdDomain(line)) {
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
