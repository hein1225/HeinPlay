import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:hain_tv/services/m3u8_ad_filter.dart';
import 'package:http/http.dart' as http;

/// M3U8 相关通用工具。
class M3u8Utils {
  /// 判断 [url] 是否为 M3U8 播放列表地址。
  static bool isM3u8Url(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('application/vnd.apple.mpegurl') ||
        lower.contains('audio/x-mpegurl');
  }

  /// 判断 [url] 是否看起来是媒体分片（而非播放列表）。
  ///
  /// 部分 CDN 的分片路径包含 `/hls/`（如 `.../hls/925/.../plist0.ts`），仅靠路径
  /// 关键字会被误判为 M3U8 子播放列表，导致把 .ts 当 playlist 递归下载而失败。
  /// 这里通过文件扩展名（忽略 query）排除常见的音视频/密钥/图片分片。
  static bool _looksLikeMediaSegment(String url) {
    final lower = url.toLowerCase().split('?').first;
    const segmentSuffixes = <String>[
      '.ts', '.m4s', '.m4a', '.m4v', '.aac', '.ac3', '.ec3', '.mp4',
      '.mkv', '.flv', '.webm', '.mov', '.wvm', '.3gp', '.key', '.jpeg',
      '.jpg', '.png', '.gif', '.bmp', '.vtt', '.srt', '.ass', '.xml',
      '.bin', '.part', '.mp3', '.wav', '.ogg', '.mka',
    ];
    for (final s in segmentSuffixes) {
      if (lower.endsWith(s)) return true;
    }
    return false;
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

      return await resolveSegmentUrlsFromContent(
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
        // 变体已按清晰度降序排列，取第一个即最高清晰度。
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

        if (isM3u8Url(resolved) && !_looksLikeMediaSegment(resolved)) {
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

      return await resolveSegmentUrlsFromContent(
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

  /// 从 M3U8 内容中选出最高清晰度变体的 URI（绝对 URL）。
  ///
  /// 若内容不是 master playlist 或解析失败，返回 null。
  static String? pickBestVariantUri(String content, String baseUrl) {
    final lines = content.replaceAll('\r\n', '\n').split('\n');
    final variants = _parseStreamVariants(lines);
    if (variants.isEmpty) return null;

    // 变体已按清晰度降序排列，取第一个即最高清晰度。
    final best = variants.first;
    final baseUri = Uri.parse(baseUrl);
    return best.uri.startsWith('http://') || best.uri.startsWith('https://')
        ? best.uri
        : baseUri.resolve(best.uri).toString();
  }

  /// 从主播放列表行中解析所有变体。
  ///
  /// 除 `#EXT-X-STREAM-INF` 的 `RESOLUTION` 属性外，还会从 `NAME` 属性或变体 URI
  /// 中再次提取分辨率，兼容只写 BANDWIDTH/不写 RESOLUTION 的播放列表。
  /// 同时兼容两种变体 URI 写法：
  ///   - 标准写法：URI 写在 `EXT-X-STREAM-INF` 的下一行；
  ///   - 行内写法：URI 写在 `EXT-X-STREAM-INF` 行的 `URI="..."` 属性中
  ///     （Apple 规范允许，hls.js 也支持）。仅认下一行会漏掉此类 1080p 变体。
  static final _variantUriRe = RegExp(r'URI="([^"]+)"');

  static List<_StreamVariant> _parseStreamVariants(List<String> lines) {
    final variants = <_StreamVariant>[];
    _StreamVariant? pending;
    String? pendingInlineUri;
    final bandwidthRe = RegExp(r'BANDWIDTH=(\d+)');
    final resolutionRe = RegExp(r'RESOLUTION=(\d+)x(\d+)');

    void flushPending(String? fallbackUri) {
      if (pending == null) return;
      final uri = pendingInlineUri ?? fallbackUri;
      if (uri == null || uri.isEmpty) {
        // 该变体没有可用 URI（如纯属性行），丢弃，避免产生空 URI 的伪变体。
        pending = null;
        pendingInlineUri = null;
        return;
      }
      // 同时用属性行和 URI 提取分辨率，取最高者。
      final text = '${pending!.attributeLine} $uri';
      final label = extractResolutionFromText(text);

      // 优先从 RESOLUTION=WxH 提取宽高，用于处理如 1920x818 这种
      // 高度不足 1080 但实际为 1080p 宽屏电影的变体。
      final resMatch = resolutionRe.firstMatch(pending!.attributeLine);
      int? parsedWidth;
      int? parsedHeight;
      if (resMatch != null) {
        parsedWidth = int.tryParse(resMatch.group(1)!);
        parsedHeight = int.tryParse(resMatch.group(2)!);
      }

      variants.add(
        pending!.copyWith(
          uri: uri,
          width: parsedWidth,
          height: parsedHeight ?? _heightFromLabel(label),
          resolutionLabel: _variantResolutionLabel(
            parsedWidth,
            parsedHeight,
            label,
            pending!.bandwidth,
            uri,
          ),
        ),
      );
      pending = null;
      pendingInlineUri = null;
    }

    for (final raw in lines) {
      final trimmed = raw.trim();
      if (trimmed.isEmpty || trimmed.startsWith('data:')) continue;

      if (trimmed.startsWith('#EXT-X-STREAM-INF')) {
        // 遇到新的 STREAM-INF：先把上一个可能以行内 URI 收尾的变体落库。
        flushPending(null);
        int? bandwidth;
        final bandMatch = bandwidthRe.firstMatch(trimmed);
        if (bandMatch != null) {
          bandwidth = int.tryParse(bandMatch.group(1)!);
        }
        String? inlineUri;
        final uriMatch = _variantUriRe.firstMatch(trimmed);
        if (uriMatch != null) inlineUri = uriMatch.group(1);
        pending = _StreamVariant(
          uri: '',
          attributeLine: trimmed,
          bandwidth: bandwidth,
        );
        pendingInlineUri = inlineUri;
      } else if (!trimmed.startsWith('#')) {
        // 变体 URI 写在本行（标准写法）。
        flushPending(trimmed);
      } else if (pending != null) {
        // 某些播放列表在 STREAM-INF 与 URI 之间还有 #EXT-X-MEDIA 等标签，
        // 把属性行追加起来一起参与分辨率提取。
        pending = pending!.copyWith(
          attributeLine: '${pending!.attributeLine}\n$trimmed',
        );
      }
    }
    // 文件末尾仍有一个以行内 URI 收尾的变体。
    flushPending(null);
    // 按清晰度降序排列，使 variants.first 即最高清晰度变体（供测速/播放选源复用）。
    _sortVariantsByQuality(variants);
    return variants;
  }

  /// 综合 RESOLUTION 属性、URI/NAME 文本标签与 BANDWIDTH 估计视频高度。
  ///
  /// 信号优先级：真实分辨率 > 文本标签（含 URI）> BANDWIDTH。
  /// 对于宽屏电影常见的高度裁剪（如 1920x818、1080x608），按宽度档位归入
  /// 更高清晰度，与 hls.js / LunaTV 的宽度判定方式对齐。
  static int _estimateHeight({
    int? width,
    int? height,
    String? textLabel,
    int? bandwidth,
    String uri = '',
  }) {
    // 1. 真实 RESOLUTION：宽度或高度任一达标即可；宽屏电影按宽度档位。
    if (width != null && height != null && width > 0 && height > 0) {
      final isWideScreen = width > 0 && height / width < 0.65;
      final effectiveWidth = isWideScreen ? width : null;
      if (effectiveWidth != null) {
        // 宽屏电影（如 1080x608、1920x802）解码后完整宽度通常接近 1920，
        // 与 hls.js / LunaTV 读取 videoWidth（真实解码宽度）对齐。
        // 宽高比 < 0.65 且宽度落在 [1000,1280) 视为裁剪后的 1080p（完整宽约 1920）；
        // 宽度 >= 1280 才是真正的 720p 宽屏（如 1280x536）。
        if (effectiveWidth >= 1900 || height >= 1080) return 1080;
        if (effectiveWidth >= 1280) return 720;
        if (effectiveWidth >= 1000) return 1080;
        if (effectiveWidth >= 700) return 480;
        if (effectiveWidth >= 640) return 360;
        if (height >= 720) return 720;
        if (height >= 480) return 480;
        if (height >= 360) return 360;
      } else {
        if (width >= 3840 || height >= 2160) return 2160;
        if (width >= 2560 || height >= 1440) return 1440;
        if (width >= 1900 || height >= 1080) return 1080;
        if (width >= 1280 || height >= 720) return 720;
        if (width >= 854 || height >= 480) return 480;
        if (width >= 640 || height >= 360) return 360;
      }
      return height;
    }

    // 2. 文本标签（含 URI/NAME）。资源站常在 URI 中写入真实码率（如 3000k），
    //    而 BANDWIDTH 属性可能偏低或不准确，因此优先使用文本信号。
    final combined = '${textLabel ?? ''} $uri'.trim();
    if (combined.isNotEmpty) {
      final label = extractResolutionFromText(combined);
      final h = _heightFromLabel(label);
      if (h != null && h > 0) return h;
    }

    // 3. BANDWIDTH 最后回退。
    if (bandwidth != null && bandwidth > 0) {
      final kbps = bandwidth / 1000;
      if (kbps >= 5000) return 2160;
      if (kbps >= 2500) return 1080;
      if (kbps >= 1500) return 720;
      if (kbps >= 800) return 480;
      if (kbps >= 500) return 360;
    }

    return 0;
  }

  /// Media playlist 无 RESOLUTION/BANDWIDTH/URL 文本线索时，通过 GET Range 探测前几个
  /// 分片的大小与 #EXTINF 时长估算码率，再映射到分辨率。可解决 LunaTV 通过 hls.js
  /// 真实解码获取 1080P、但文本解析只能得到 null 的问题。
  ///
  /// 取前 [maxProbes] 个分片的最大码率，避免首个分片常因片头/低码率 ramp-up 被低估。
  static Future<String?> _estimateResolutionFromSegments(
    List<String> segmentUrls,
    List<String> lines, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 4),
    int maxProbes = 5,
    int rangeBytes = 64 * 1024,
    http.Client? client,
  }) async {
    if (segmentUrls.isEmpty) return null;

    // 解析 #EXTINF 时长，按顺序与分片 URL 配对。
    final durations = <double>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXTINF:')) {
        final value = line.substring(8).split(',').first.trim();
        durations.add(double.tryParse(value) ?? 0);
      } else if (line.isNotEmpty &&
          !line.startsWith('#') &&
          !line.startsWith('data:')) {
        // 只记录有效分片行的占位，保证 durations 与 segmentUrls 顺序对齐。
      }
    }

    debugPrint(
      '[M3U8分析] 开始分片码率估算，分片数=${segmentUrls.length}，#EXTINF=${durations.take(5).toList()}',
    );

    final probeCount = math.min(segmentUrls.length, maxProbes);
    final requestClient = client ?? http.Client();
    final isLocalClient = client == null;
    try {
      final probeFutures = <Future<double?>>[];
      for (var i = 0; i < probeCount; i++) {
        final url = segmentUrls[i];
        final duration = i < durations.length ? durations[i] : 0.0;
        if (duration <= 0) {
          probeFutures.add(Future.value(null));
          continue;
        }
        probeFutures.add(
          _probeSegmentBitrate(
            url,
            duration,
            headers: headers,
            timeout: timeout,
            client: requestClient,
            maxBytes: rangeBytes,
            index: i,
          ),
        );
      }

      final kbpsList = await Future.wait(probeFutures);
      var maxKbps = 0.0;
      for (final kbps in kbpsList) {
        if (kbps != null && kbps > maxKbps) maxKbps = kbps;
      }
      final bestEstimate = _bitrateToResolutionLabel(maxKbps);
      if (bestEstimate != null) {
        debugPrint(
          '[M3U8分析] 分片最大码率=${maxKbps.toStringAsFixed(0)}k -> 分辨率=$bestEstimate',
        );
      } else {
        debugPrint(
          '[M3U8分析] 分片码率估算未得到有效结果（最大码率=${maxKbps.toStringAsFixed(0)}k）',
        );
      }
      return bestEstimate;
    } finally {
      if (isLocalClient) requestClient.close();
    }
  }

  /// 探测单个分片的码率（kbps）。
  ///
  /// 优先使用 GET Range 读取 [Content-Range] 得到完整文件大小；若服务器不支持，
  /// 则回退到 HEAD；再失败则通过实际下载耗时估算吞吐并推算文件大小。
  static Future<double?> _probeSegmentBitrate(
    String url,
    double duration, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 4),
    int maxBytes = 64 * 1024,
    http.Client? client,
    int index = 0,
  }) async {
    final requestClient = client ?? http.Client();
    final isLocalClient = client == null;
    http.StreamedResponse? streamedResponse;
    try {
      final rangeHeaders = Map<String, String>.from(headers);
      rangeHeaders['Range'] = 'bytes=0-${maxBytes - 1}';

      final req = http.Request('GET', Uri.parse(url));
      req.headers.addAll(rangeHeaders);
      streamedResponse = await requestClient.send(req).timeout(timeout);

      // 优先从 Content-Range 读取完整文件大小（最准确，且避免下载整个分片）。
      final contentRange = streamedResponse.headers['content-range'];
      if (streamedResponse.statusCode == 206 && contentRange != null) {
        final match = RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(contentRange);
        if (match != null) {
          final total = int.tryParse(match.group(1)!);
          if (total != null && total > 0) {
            await streamedResponse.stream.drain<void>();
            final kbps = (total * 8) / (duration * 1000);
            debugPrint(
              '[M3U8分析] 分片 Range-GET#${index + 1}: total=$total duration=$duration kbps=${kbps.toStringAsFixed(0)}',
            );
            return kbps;
          }
        }
      }

      // 无 Content-Range 时尝试 HEAD 获取 Content-Length。
      try {
        final headResp = await requestClient
            .head(Uri.parse(url), headers: headers)
            .timeout(timeout);
        final length = headResp.contentLength;
        if (length != null && length > 0) {
          await streamedResponse.stream.drain<void>();
          final kbps = (length * 8) / (duration * 1000);
          debugPrint(
            '[M3U8分析] 分片 HEAD#${index + 1}: size=$length duration=$duration kbps=${kbps.toStringAsFixed(0)}',
          );
          return kbps;
        }
      } catch (e) {
        debugPrint('[M3U8分析] 分片 HEAD 探测失败#${index + 1}: $e');
      }

      // 最后回退：读取前 [maxBytes] 字节，按实际耗时估算吞吐。
      if (streamedResponse.statusCode == 200 ||
          streamedResponse.statusCode == 206) {
        final stopwatch = Stopwatch()..start();
        var received = 0;
        await for (final chunk in streamedResponse.stream) {
          received += chunk.length;
          if (received >= maxBytes) break;
        }
        // ⚠️ 此处不可再 drain：stream 是 single-subscription，上面的 await for
        // 已订阅（break 时自动 cancel），二次订阅会抛
        // `Bad state: Stream has already been listened to`
        // （2026-09-20 17:20 日志里 [M3U8分析] 分片探测失败#2/#3/#4 就是这个）。
        stopwatch.stop();
        if (received > 0 && stopwatch.elapsedMilliseconds > 0) {
          final seconds = stopwatch.elapsedMilliseconds / 1000.0;
          // 假设下载速率稳定，估算完整分片大小。
          final estimatedTotal = ((received / seconds) * duration).toInt();
          final kbps = (estimatedTotal * 8) / (duration * 1000);
          debugPrint(
            '[M3U8分析] 分片吞吐估算#${index + 1}: received=$received time=${seconds.toStringAsFixed(2)}s estimatedTotal=$estimatedTotal kbps=${kbps.toStringAsFixed(0)}',
          );
          return kbps;
        }
      }

      try {
        await streamedResponse.stream.drain<void>();
      } catch (_) {
        // 该 stream 可能已被上面的 await for 消费过（single-subscription），忽略。
      }
    } catch (e) {
      debugPrint('[M3U8分析] 分片探测失败#${index + 1}: $e');
    } finally {
      if (isLocalClient) requestClient.close();
    }
    return null;
  }

  /// 把估算/实测码率（kbps）映射到标准分辨率标签。
  ///
  /// 阈值与 [_estimateHeight] 的 BANDWIDTH 分支保持一致。
  static String? _bitrateToResolutionLabel(double kbps) {
    if (kbps >= 5000) return '4K';
    if (kbps >= 2500) return '1080P';
    if (kbps >= 1500) return '720P';
    if (kbps >= 800) return '480P';
    if (kbps >= 500) return '360P';
    return null;
  }

  /// 综合 RESOLUTION 属性、URI/NAME 文本标签与 BANDWIDTH 生成分辨率标签。
  static String? _variantResolutionLabel(
    int? width,
    int? height,
    String? textLabel,
    int? bandwidth,
    String uri,
  ) {
    final h = _estimateHeight(
      width: width,
      height: height,
      textLabel: textLabel,
      bandwidth: bandwidth,
      uri: uri,
    );
    if (h > 0) return _heightToResolutionLabel(h);
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

    // 维度模式：如 1920x1080、1280x720、1080x608（宽屏电影）。
    // 取宽高中的最大值映射到标准高度，避免宽屏变体按高度被低估。
    final dimensionRe = RegExp(
      r'(?:^|[^0-9])(\d{3,4})\s*[xX×]\s*(\d{3,4})(?:$|[^0-9])',
    );
    for (final m in dimensionRe.allMatches(lower)) {
      final w = int.tryParse(m.group(1)!);
      final h = int.tryParse(m.group(2)!);
      if (w != null && h != null) {
        final maxDim = math.max(w, h);
        int estimatedH;
        if (maxDim >= 3840) {
          estimatedH = 2160;
        } else if (maxDim >= 2560) {
          estimatedH = 1440;
        } else if (maxDim >= 1920) {
          estimatedH = 1080;
        } else if (maxDim >= 1280) {
          estimatedH = 720;
        } else if (maxDim >= 854) {
          estimatedH = 480;
        } else if (maxDim >= 640) {
          estimatedH = 360;
        } else {
          estimatedH = maxDim;
        }
        bestHeight = _maxHeight(bestHeight, estimatedH);
      }
    }

    // 码率模式：如 3000k/hls/mixed.m3u8、1500k、4000K、3000kbps、3M、4Mbps。
    // 阈值与 [_estimateHeight] 保持一致：2500k 以上对应 1080p，1500k 对应 720p，
    // 800k 对应 480p，500k 对应 360p。
    final bitrateRe = RegExp(r'(?:^|[^a-zA-Z0-9])(\d{3,5})\s*[kK](?:\s*[bB][pP][sS])?(?:[^a-zA-Z0-9]|$)');
    for (final m in bitrateRe.allMatches(lower)) {
      final kbps = int.tryParse(m.group(1)!);
      if (kbps != null && kbps >= 500) {
        int? h;
        if (kbps >= 5000) {
          h = 2160;
        } else if (kbps >= 2500) {
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
        if (kbps >= 5000) {
          h = 2160;
        } else if (kbps >= 2500) {
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

  /// 按清晰度对变体降序排序：综合分辨率优先，码率为次优先级。
  ///
  /// HLS 主播放列表通常按清晰度升序排列（360p→1080p），且部分变体只标 BANDWIDTH
  /// 不标 RESOLUTION；若仅按 BANDWIDTH 排序，低码率高分辨率的变体（如 HEVC 1080p）
  /// 会被高码率 720p 反超，导致错选低清。故统一使用 [_estimateHeight] 评估清晰度，
  /// 码率仅作为同分辨率下的次优先级。
  static void _sortVariantsByQuality(List<_StreamVariant> variants) {
    variants.sort((a, b) {
      final ha = _estimateHeight(
        width: a.width,
        height: a.height,
        textLabel: a.resolutionLabel,
        bandwidth: a.bandwidth,
        uri: a.uri,
      );
      final hb = _estimateHeight(
        width: b.width,
        height: b.height,
        textLabel: b.resolutionLabel,
        bandwidth: b.bandwidth,
        uri: b.uri,
      );
      if (ha != hb) return hb.compareTo(ha);
      final ba = a.bandwidth ?? 0;
      final bb = b.bandwidth ?? 0;
      return bb.compareTo(ba);
    });
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
      // 调试日志：用于排查“同源 LunaTV 1080p、海因影视 360P/720P”问题。
      // TODO: 问题确认后可调低日志级别或移除。
      debugPrint('[M3U8分析] URL=$url');
      debugPrint(
        '[M3U8分析] 内容长度=${content.length} 摘要(前800)=${content.length > 800 ? content.substring(0, 800) : content}',
      );
      debugPrint('[M3U8分析] 解析到变体数=${variants.length}');
      for (var i = 0; i < variants.length; i++) {
        final v = variants[i];
        debugPrint(
          '[M3U8分析] 变体#$i bw=${v.bandwidth} res=${v.resolutionLabel} height=${v.height} uri=${v.uri.length > 120 ? '${v.uri.substring(0, 120)}...' : v.uri}',
        );
      }
      if (variants.isNotEmpty) {
        final best = variants.first;
        final resolvedUri = best.uri.startsWith('http://') ||
                best.uri.startsWith('https://')
            ? best.uri
            : baseUri.resolve(best.uri).toString();
        debugPrint(
          '[M3U8分析] 选定最佳变体 res=${best.resolutionLabel} uri=$resolvedUri',
        );
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
        if (isM3u8Url(resolved) && !_looksLikeMediaSegment(resolved)) {
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

      String? urlResolution = extractResolutionFromText(url);
      // Media playlist 文本无分辨率线索时，用分片码率估算；避免回退到缓存/搜索的 360P。
      if (urlResolution == null && segmentUrls.isNotEmpty) {
        urlResolution = await _estimateResolutionFromSegments(
          segmentUrls,
          lines,
          headers: headers,
          timeout: const Duration(seconds: 3),
          client: httpClient,
        );
      }
      debugPrint(
        '[M3U8分析] 未解析到变体（Media playlist），从URL推断分辨率: $urlResolution，片段数: ${segmentUrls.length}',
      );
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
