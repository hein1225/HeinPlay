import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hain_tv/services/m3u8_ad_filter.dart';
import 'package:http/http.dart' as http;

/// M3U8 相关通用工具。
class M3u8Utils {
  /// 判断 [url] 是否为 M3U8 播放列表地址。
  static bool isM3u8Url(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('/hls/') ||
        lower.contains('application/vnd.apple.mpegurl') ||
        lower.contains('audio/x-mpegurl');
  }

  /// 递归解析 M3U8 播放列表，返回第一个可用的视频分片 URL。
  ///
  /// 对于主播放列表（master playlist），会进入第一个变体子播放列表继续解析；
  /// 对于媒体播放列表（media playlist），返回第一个非标签行对应的 URL。
  /// 相对 URL 会根据 [url] 自动解析为绝对 URL。
  static Future<String?> resolveFirstSegmentUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 5),
    int maxDepth = 3,
  }) async {
    final result = await resolveBestSegmentUrl(
      url,
      headers: headers,
      timeout: timeout,
      maxDepth: maxDepth,
    );
    return result.segmentUrl;
  }

  /// 解析 M3U8 播放列表，优先返回码率最高的变体（master playlist）对应的首个分片，
  /// 同时返回从主播放列表解析到的分辨率标签。
  ///
  /// [resolution] 格式示例：1080P、720P、4K 等。
  static Future<({String? segmentUrl, String? resolution})> resolveBestSegmentUrl(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 5),
    int maxDepth = 3,
  }) async {
    final result = await resolveSegmentUrls(
      url,
      headers: headers,
      timeout: timeout,
      maxDepth: maxDepth,
      maxSegments: 1,
    );
    return (
      segmentUrl: result.segmentUrls.isNotEmpty ? result.segmentUrls.first : null,
      resolution: result.resolution,
    );
  }

  /// 解析 M3U8 播放列表，返回前 [maxSegments] 个真实分片 URL，
  /// 同时返回从主播放列表解析到的分辨率标签。
  static Future<({List<String> segmentUrls, String? resolution})> resolveSegmentUrls(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 5),
    int maxDepth = 3,
    int maxSegments = 3,
  }) async {
    if (!isM3u8Url(url) || maxDepth <= 0) {
      return (
        segmentUrls: isM3u8Url(url) ? const <String>[] : [url],
        resolution: null,
      );
    }

    try {
      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(timeout);
      if (response.statusCode != 200) {
        return (segmentUrls: const <String>[], resolution: null);
      }

      return resolveSegmentUrlsFromContent(
        url,
        response.body,
        maxDepth: maxDepth,
        maxSegments: maxSegments,
      );
    } catch (e) {
      debugPrint('解析 M3U8 分片失败: $e');
    }
    return (segmentUrls: const <String>[], resolution: null);
  }

  /// 从给定的 M3U8 内容解析前 [maxSegments] 个真实分片 URL，
  /// 用于测速前先用 M3u8AdFilter 过滤广告片段，避免测速到广告分片。
  static Future<({List<String> segmentUrls, String? resolution})>
      resolveSegmentUrlsFromContent(
    String url,
    String content, {
    int maxDepth = 3,
    int maxSegments = 3,
  }) async {
    if (!isM3u8Url(url) || maxDepth <= 0) {
      return (
        segmentUrls: isM3u8Url(url) ? const <String>[] : [url],
        resolution: null,
      );
    }

    try {
      final baseUri = Uri.parse(url);
      final lines = content.replaceAll('\r\n', '\n').split('\n');

      // 1. 先判断是否是 master playlist。
      final variants = _parseStreamVariants(lines);
      if (variants.isNotEmpty) {
        // 优先选择 BANDWIDTH 最高的变体；没有 BANDWIDTH 时按分辨率高度选。
        variants.sort((a, b) {
          if (a.bandwidth != null && b.bandwidth != null) {
            return b.bandwidth!.compareTo(a.bandwidth!);
          }
          if (a.bandwidth != null) return -1;
          if (b.bandwidth != null) return 1;
          final aH = a.height ?? 0;
          final bH = b.height ?? 0;
          return bH.compareTo(aH);
        });
        final best = variants.first;
        final resolvedUri = best.uri.startsWith('http://') ||
                best.uri.startsWith('https://')
            ? best.uri
            : baseUri.resolve(best.uri).toString();
        // master playlist 需要先下载子 playlist 内容；测速场景下这里不再预过滤，
        // 因为主 playlist 不含广告分片。
        final child = await resolveSegmentUrls(
          resolvedUri,
          maxDepth: maxDepth - 1,
          maxSegments: maxSegments,
        );
        return (
          segmentUrls: child.segmentUrls,
          resolution: best.resolutionLabel ?? child.resolution,
        );
      }

      // 2. 媒体播放列表：收集前 maxSegments 个非标签行。
      final segmentUrls = <String>[];
      for (final raw in lines) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty ||
            trimmed.startsWith('#') ||
            trimmed.startsWith('data:')) {
          continue;
        }

        final resolved = trimmed.startsWith('http://') ||
                trimmed.startsWith('https://')
            ? trimmed
            : baseUri.resolve(trimmed).toString();

        if (isM3u8Url(resolved)) {
          final child = await resolveSegmentUrls(
            resolved,
            maxDepth: maxDepth - 1,
            maxSegments: maxSegments,
          );
          return (
            segmentUrls: child.segmentUrls,
            resolution: child.resolution,
          );
        }
        segmentUrls.add(resolved);
        if (segmentUrls.length >= maxSegments) break;
      }
      return (segmentUrls: segmentUrls, resolution: null);
    } catch (e) {
      debugPrint('解析 M3U8 分片失败: $e');
    }
    return (segmentUrls: const <String>[], resolution: null);
  }

  /// 对 M3U8 URL 先下载并过滤广告，再返回前 [maxSegments] 个真实分片 URL 及分辨率。
  /// 这是测速入口，避免测速命中广告分片导致“不可用”误判。
  static Future<({List<String> segmentUrls, String? resolution})>
      resolveFilteredSegmentUrls(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 5),
    int maxSegments = 3,
    String? sourceType,
  }) async {
    if (!isM3u8Url(url)) {
      return (segmentUrls: [url], resolution: null);
    }
    try {
      final response = await http
          .get(Uri.parse(url), headers: headers)
          .timeout(timeout);
      if (response.statusCode != 200) {
        return (segmentUrls: const <String>[], resolution: null);
      }
      var content = response.body;

      // 使用本地广告过滤引擎先过滤 M3U8 内容，避免测速到广告分片。
      try {
        final adFilter = M3u8AdFilter();
        final purified = adFilter.purify(url, content);
        if (purified != null &&
            adFilter.currentAdCount > 0 &&
            _hasMediaSegments(purified)) {
          content = purified;
        }
      } catch (e) {
        debugPrint('测速前广告过滤失败: $e');
      }

      return resolveSegmentUrlsFromContent(
        url,
        content,
        maxDepth: 3,
        maxSegments: maxSegments,
      );
    } catch (e) {
      debugPrint('解析过滤后 M3U8 分片失败: $e');
    }
    return (segmentUrls: const <String>[], resolution: null);
  }

  /// 从主播放列表行中解析所有变体。
  ///
  /// 除 `#EXT-X-STREAM-INF` 的 `RESOLUTION` 属性外，还会从 `NAME` 属性或变体 URI
  /// 中再次提取分辨率，兼容只写 BANDWIDTH/不写 RESOLUTION 的播放列表。
  static List<_StreamVariant> _parseStreamVariants(List<String> lines) {
    final variants = <_StreamVariant>[];
    _StreamVariant? pending;
    final bandwidthRe = RegExp(r'BANDWIDTH=(\d+)');
    final resolutionRe = RegExp(r'RESOLUTION=(\d+)x(\d+)');

    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('data:')) continue;

      if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
        int? bandwidth;
        final bandMatch = bandwidthRe.firstMatch(trimmed);
        if (bandMatch != null) {
          bandwidth = int.tryParse(bandMatch.group(1)!);
        }
        pending = _StreamVariant(
          uri: '',
          attributeLine: trimmed,
          bandwidth: bandwidth,
        );
      } else if (!trimmed.startsWith('#')) {
        if (pending != null) {
          // 同时用属性行和 URI 提取分辨率，取最高者。
          final text = '${pending.attributeLine} $trimmed';
          final label = extractResolutionFromText(text);

          // 优先从 RESOLUTION=WxH 提取宽高，用于处理如 1920x818 这种
          // 高度不足 1080 但实际为 1080p 宽屏电影的变体。
          final resMatch = resolutionRe.firstMatch(pending.attributeLine);
          int? parsedWidth;
          int? parsedHeight;
          if (resMatch != null) {
            parsedWidth = int.tryParse(resMatch.group(1)!);
            parsedHeight = int.tryParse(resMatch.group(2)!);
          }

          variants.add(
            pending.copyWith(
              uri: trimmed,
              width: parsedWidth,
              height: parsedHeight ?? _heightFromLabel(label),
              resolutionLabel: _variantResolutionLabel(
                parsedWidth,
                parsedHeight,
                label,
                pending.bandwidth,
              ),
            ),
          );
          pending = null;
        }
      } else if (pending != null) {
        // 某些播放列表在 STREAM-INF 与 URI 之间还有 #EXT-X-MEDIA 等标签，
        // 把属性行追加起来一起参与分辨率提取。
        pending = pending.copyWith(
          attributeLine: '${pending.attributeLine}\n$trimmed',
        );
      }
    }
    return variants;
  }

  /// 综合 RESOLUTION 属性、文本标签与 BANDWIDTH 生成分辨率标签。
  ///
  /// 对于宽屏电影常见的高度裁剪（如 1920x818），按宽度归入 1080P。
  /// 当没有 RESOLUTION 时，优先从 URI/NAME 等文本标签推断（如 3000k、1080p），
  /// 最后回退到 BANDWIDTH，避免部分源 BANDWIDTH 与实际分辨率不符导致误判。
  static String? _variantResolutionLabel(
    int? width,
    int? height,
    String? textLabel,
    int? bandwidth,
  ) {
    if (width != null && height != null) {
      // 宽度优先：1920 宽度对应 1080p，3840 对应 4K，1280 对应 720p。
      if (width >= 3840) return '4K';
      if (width >= 2560) return '2K';
      if (width >= 1900) return '1080P';
      if (width >= 1200) return '720P';
      if (width >= 700) return '480P';
    }

    if (textLabel != null && textLabel.isNotEmpty) {
      final height = _heightFromLabel(textLabel);
      if (height != null && height > 0) {
        return textLabel;
      }
    }

    if (bandwidth != null && bandwidth > 0) {
      final kbps = bandwidth / 1000;
      if (kbps >= 6000) return '4K';
      if (kbps >= 3000) return '1080P';
      if (kbps >= 1500) return '720P';
      if (kbps >= 800) return '480P';
    }

    return textLabel;
  }

  /// 从文本中提取常见的分辨率标识（如 1080P、720P、4K）。
  ///
  /// 若存在多个，返回数值最高者。支持数字像素、常见别名（FHD/HD/SD/UHD/QHD）
  /// 以及中文清晰度描述（蓝光/超清/高清/标清/枪版）。
  static String? extractResolutionFromText(String text) {
    if (text.isEmpty) return null;
    final lower = text.toLowerCase();

    int? bestHeight;

    // 常见 4K/2K 标识。
    if (RegExp(r'(?:^|[^a-z0-9])(?:4k|uhd|ultrahd|ultra\s*hd)(?:$|[^a-z0-9])')
        .hasMatch(lower)) {
      bestHeight = _maxHeight(bestHeight, 2160);
    }
    if (RegExp(r'(?:^|[^a-z0-9])(?:2k|qhd)(?:$|[^a-z0-9])').hasMatch(lower)) {
      bestHeight = _maxHeight(bestHeight, 1440);
    }

    // 维度模式：如 1920x1080、1280x720。
    final dimensionRe = RegExp(
      r'(?:^|[^0-9])(?:3840|2560|1920|1280|854|640)\s*[xX×]\s*(2160|1440|1080|720|480|360)(?:$|[^0-9])',
    );
    for (final m in dimensionRe.allMatches(lower)) {
      final h = int.tryParse(m.group(1)!);
      if (h != null) {
        bestHeight = _maxHeight(bestHeight, h);
      }
    }

    // 码率模式：如 3000k/hls/mixed.m3u8、1500k、4000K、3000kbps、3M、4Mbps。
    // 通常 3000k 以上对应 1080p，1500-2500k 对应 720p，800-1200k 对应 480p。
    final bitrateRe = RegExp(r'(?:^|[^a-zA-Z0-9])(\d{3,5})\s*[kK](?:\s*[bB][pP][sS])?(?:[^a-zA-Z0-9]|$)');
    for (final m in bitrateRe.allMatches(lower)) {
      final kbps = int.tryParse(m.group(1)!);
      if (kbps != null && kbps >= 500) {
        int? h;
        if (kbps >= 6000) {
          h = 2160;
        } else if (kbps >= 3000) {
          h = 1080;
        } else if (kbps >= 1500) {
          h = 720;
        } else if (kbps >= 800) {
          h = 480;
        } else {
          h = 360;
        }
        bestHeight = _maxHeight(bestHeight, h);
      }
    }

    // 大写 M/Mbps 模式：如 3M、4Mbps、5Mbit（按兆比特换算，1M≈1000k）。
    final mbpsRe = RegExp(r'(?:^|[^a-zA-Z0-9])(\d{1,2})\s*[mM](?:\s*[bB][pP][sS]|\s*[bB][iI][tT])?(?:[^a-zA-Z0-9]|$)');
    for (final m in mbpsRe.allMatches(lower)) {
      final mbps = int.tryParse(m.group(1)!);
      if (mbps != null && mbps >= 1) {
        final kbps = mbps * 1000;
        int? h;
        if (kbps >= 6000) {
          h = 2160;
        } else if (kbps >= 3000) {
          h = 1080;
        } else if (kbps >= 1500) {
          h = 720;
        } else if (kbps >= 800) {
          h = 480;
        } else {
          h = 360;
        }
        bestHeight = _maxHeight(bestHeight, h);
      }
    }

    // 像素模式：1080p、720P、2160i 等。
    final pixelRe = RegExp(
      r'(?:^|[^a-zA-Z0-9])(\d{3,4})\s*[pi](?:[^a-zA-Z0-9]|$)',
    );
    for (final m in pixelRe.allMatches(lower)) {
      final h = int.tryParse(m.group(1)!);
      if (h != null && h > 240) {
        bestHeight = _maxHeight(bestHeight, h);
      }
    }

    // 常见别名。
    if (RegExp(r'(?:^|[^a-z0-9])(?:fhd|fullhd|full\s*hd)(?:$|[^a-z0-9])')
        .hasMatch(lower)) {
      bestHeight = _maxHeight(bestHeight, 1080);
    }
    if (RegExp(r'(?:^|[^a-z0-9])hd(?:$|[^a-z0-9])').hasMatch(lower)) {
      bestHeight = _maxHeight(bestHeight, 720);
    }
    if (RegExp(r'(?:^|[^a-z0-9])sd(?:$|[^a-z0-9])').hasMatch(lower)) {
      bestHeight = _maxHeight(bestHeight, 480);
    }

    // 中文清晰度描述。
    if (RegExp(r'蓝光|超清').hasMatch(text)) {
      bestHeight = _maxHeight(bestHeight, 1080);
    }
    if (RegExp(r'高清').hasMatch(text)) {
      bestHeight = _maxHeight(bestHeight, 720);
    }
    if (RegExp(r'标清').hasMatch(text)) {
      bestHeight = _maxHeight(bestHeight, 480);
    }
    if (RegExp(r'枪版|(?:^|[^a-z0-9])(?:cam|tc|ts)(?:$|[^a-z0-9])')
        .hasMatch(lower)) {
      bestHeight = _maxHeight(bestHeight, 360);
    }

    if (bestHeight == null) return null;
    return _heightToResolutionLabel(bestHeight);
  }

  static int? _maxHeight(int? a, int b) {
    if (a == null || b > a) return b;
    return a;
  }

  /// 对 M3U8 URL 做轻量级分析，用于测速。
  ///
  /// 返回实际应测速的 playlist URL、是否 master playlist、最佳分辨率标签，
  /// 以及前 [maxSegments] 个真实分片 URL。
  /// 对于 master playlist 会递归进入最佳 variant 子 playlist；
  /// 对于 media playlist 直接收集分片并从 URL 推断分辨率。
  static Future<({
    bool isMaster,
    String? resolution,
    List<String> segmentUrls,
    String playlistUrl,
  })> analyzeM3u8ForSpeedTest(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 3),
    int maxSegments = 2,
    http.Client? client,
  }) async {
    if (!isM3u8Url(url)) {
      return (
        isMaster: false,
        resolution: null,
        segmentUrls: [url],
        playlistUrl: url,
      );
    }
    try {
      final httpClient = client ?? http.Client();
      try {
        final response = await httpClient
            .get(Uri.parse(url), headers: headers)
            .timeout(timeout);
      if (response.statusCode != 200) {
        return (
          isMaster: false,
          resolution: null,
          segmentUrls: const <String>[],
          playlistUrl: url,
        );
      }
      final bytes = response.bodyBytes;
      // 部分源站返回加密/二进制 M3U8，无法用 UTF-8 解码，直接返回空分片，
      // 由上层使用原始 URL 做下载测速，避免解析异常导致源被误判为不可用。
      String content;
      try {
        content = utf8.decode(bytes, allowMalformed: false);
      } catch (_) {
        return (
          isMaster: false,
          resolution: extractResolutionFromText(url),
          segmentUrls: const <String>[],
          playlistUrl: url,
        );
      }
      // 简单校验：M3U8 文本应以 #EXTM3U 开头或至少包含 #EXT 标签；
      // 若内容明显不是 M3U8，同样交给上层处理。
      final trimmed = content.trim();
      if (!trimmed.startsWith('#EXTM3U') && !trimmed.contains('#EXT')) {
        return (
          isMaster: false,
          resolution: extractResolutionFromText(url),
          segmentUrls: const <String>[],
          playlistUrl: url,
        );
      }
      final baseUri = Uri.parse(url);
      final lines = content.replaceAll('\r\n', '\n').split('\n');

      // 1. Master playlist：选择最佳 variant 后递归分析。
      final variants = _parseStreamVariants(lines);
      if (variants.isNotEmpty) {
        final best = variants.first;
        final resolvedUri = best.uri.startsWith('http://') ||
                best.uri.startsWith('https://')
            ? best.uri
            : baseUri.resolve(best.uri).toString();
        final child = await analyzeM3u8ForSpeedTest(
          resolvedUri,
          headers: headers,
          timeout: timeout,
          maxSegments: maxSegments,
          client: client,
        );
        return (
          isMaster: true,
          resolution: best.resolutionLabel ?? child.resolution,
          segmentUrls: child.segmentUrls,
          playlistUrl: resolvedUri,
        );
      }

      // 2. Media playlist：收集分片 URL。
      final segmentUrls = <String>[];
      for (final raw in lines) {
        final trimmed = raw.trim();
        if (trimmed.isEmpty ||
            trimmed.startsWith('#') ||
            trimmed.startsWith('data:')) {
          continue;
        }
        final resolved = trimmed.startsWith('http://') ||
                trimmed.startsWith('https://')
            ? trimmed
            : baseUri.resolve(trimmed).toString();
        if (isM3u8Url(resolved)) {
          final child = await analyzeM3u8ForSpeedTest(
            resolved,
            headers: headers,
            timeout: timeout,
            maxSegments: maxSegments,
            client: client,
          );
          return (
            isMaster: false,
            resolution: child.resolution,
            segmentUrls: child.segmentUrls,
            playlistUrl: resolved,
          );
        }
        segmentUrls.add(resolved);
        if (segmentUrls.length >= maxSegments) break;
      }

      final urlResolution = extractResolutionFromText(url);
      return (
        isMaster: false,
        resolution: urlResolution,
        segmentUrls: segmentUrls,
        playlistUrl: url,
      );
      } finally {
        httpClient.close();
      }
    } catch (e) {
      debugPrint('analyzeM3u8ForSpeedTest 失败: $e');
    }
    return (
      isMaster: false,
      resolution: extractResolutionFromText(url),
      segmentUrls: const <String>[],
      playlistUrl: url,
    );
  }

  /// 检查 M3U8 内容是否仍包含非空的媒体片段行。
  static bool _hasMediaSegments(String content) {
    for (final raw in content.replaceAll('\r\n', '\n').split('\n')) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty ||
          trimmed.startsWith('#') ||
          trimmed.startsWith('data:')) {
        continue;
      }
      return true;
    }
    return false;
  }

  /// 将分辨率标签转换为近似高度，用于排序比较。
  static int? _heightFromLabel(String? label) {
    if (label == null) return null;
    final lower = label.toLowerCase();
    if (lower.contains('4k')) return 2160;
    if (lower.contains('2k')) return 1440;
    final match = RegExp(r'(\d+)p').firstMatch(lower);
    if (match != null) {
      return int.tryParse(match.group(1)!);
    }
    return null;
  }

  static String? _heightToResolutionLabel(int height) {
    if (height >= 2160) return '4K';
    if (height >= 1440) return '2K';
    if (height >= 1080) return '1080P';
    if (height >= 720) return '720P';
    if (height >= 480) return '480P';
    if (height >= 360) return '360P';
    return '${height}P';
  }
}

class _StreamVariant {
  final String uri;
  final String attributeLine;
  final int? bandwidth;
  final int? width;
  final int? height;
  final String? resolutionLabel;

  const _StreamVariant({
    required this.uri,
    this.attributeLine = '',
    this.bandwidth,
    this.width,
    this.height,
    this.resolutionLabel,
  });

  _StreamVariant copyWith({
    String? uri,
    String? attributeLine,
    int? width,
    int? height,
    String? resolutionLabel,
  }) {
    return _StreamVariant(
      uri: uri ?? this.uri,
      attributeLine: attributeLine ?? this.attributeLine,
      bandwidth: bandwidth,
      width: width ?? this.width,
      height: height ?? this.height,
      resolutionLabel: resolutionLabel ?? this.resolutionLabel,
    );
  }
}
