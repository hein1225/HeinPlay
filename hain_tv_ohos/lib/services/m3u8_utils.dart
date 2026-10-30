import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hain_tv/services/m3u8_ad_filter.dart';
import 'package:http/http.dart' as http;

/// 🔴🔴 2026-10-15：M3U8 分析的高频诊断日志开关，**默认关闭**。
///
/// 背景：这些日志（整段 playlist 正文 + 逐变体明细 + 逐分片 Range-GET）
/// 在真机实测中达到**每秒 40~91 条**，配合 `debugPrint` 在 release 下
/// 依然走同步 logcat 写入，足以占满主 isolate 并让界面卡死。
///
/// 需要排查 M3U8 解析/测速问题时，把此常量临时改为 `true` 重新构建即可；
/// **不要**把它默认打开后出包 —— 正常播放路径不需要这些明细。
///
/// ⚠️ 保留的分片码率**结论**类日志（`分片最大码率=... -> 分辨率=...`、
///    `选定最佳变体 ...`）不在此开关内，始终输出，避免排障时反而少了线索。
const bool kM3u8VerboseLog = false;

/// M3U8 相关通用工具。
/// 🔴 2026-10-23（第八轮）：M3U8 解析结果类型别名。
///
/// 之前用的是匿名 record，返回类型要整段抄一遍；
/// 抽出别名后，调用方（测速重试逻辑）可以直接当类型用。
typedef M3u8Analysis = ({
  bool isMaster,
  String? resolution,
  List<String> segmentUrls,
  String playlistUrl,
  double? firstSegmentDuration,
  /// AES-128 加密源的 key URI（已解析为绝对 URL）。
  String? encryptionKeyUri,
  /// AES-128 的 IV（十六进制字符串，不含 0x 前缀）。
  String? encryptionIv,
});

class M3u8Utils {
  /// 判断 [url] 是否为 M3U8 播放列表地址。
  static bool isM3u8Url(String url) {
    final lower = url.toLowerCase();
    return lower.contains('.m3u8') ||
        lower.contains('application/vnd.apple.mpegurl') ||
        lower.contains('audio/x-mpegurl');
  }

  /// 🔴🔴 2026-10-23：判断下载到的**内容**是不是 HLS 播放列表文本。
  ///
  /// 不能只看 URL 后缀——实测存在大量「HTML 播放器页」入口：
  /// `https://hd.kuktxu.com/play/eXDMQ2Ve` 返回 1593 字节的 HTML，
  /// 内含 hls.js，真正的 m3u8 藏在页面里（`.../eXDMQ2Ve/index.m3u8`）。
  /// 这类 URL 既没有 `.m3u8` 后缀，`content-type` 又是 `text/html`。
  static bool looksLikeM3u8Content(String content) {
    final trimmed = content.trimLeft();
    return trimmed.startsWith('#EXTM3U');
  }

  /// 🔴🔴 2026-10-23：判断内容是不是「HTML 播放器页」。
  ///
  /// ⚠️ 实测页面可能**没有 `<html>` 标签**（`hd.kuktxu.com` 的播放器页直接以
  /// `<head>` 开头），所以判定条件必须放宽：只要含 HTML 标签特征即可。
  static bool looksLikeHtmlContent(String content) {
    final head = content.trimLeft().toLowerCase();
    if (head.startsWith('#extm3u')) return false;
    return head.contains('<html') ||
        head.contains('<!doctype') ||
        head.contains('<head') ||
        head.contains('<script') ||
        head.contains('</html>') ||
        (head.contains('<') && head.contains('>'));
  }

  /// 🔴🔴 2026-10-23：从 HTML 播放器页里提取内嵌的 M3U8 地址。
  ///
  /// 覆盖的写法（实测 `hd.kuktxu.com` 用的是第 1 种）：
  ///   1. `hls.loadSource("https://host/path/index.m3u8")`
  ///   2. `var url = 'https://host/path/index.m3u8';`
  ///   3. `url: "https://host/path/index.m3u8"`
  ///   4. JSON 转义写法 `https:\/\/host\/path\/index.m3u8`
  ///
  /// 返回 null 表示页面里没找到 m3u8（调用方应按「非 HLS」处理）。
  static String? extractM3u8FromHtml(String html, {String? baseUrl}) {
    // 1) 带引号的完整 URL（最常见）
    final quoted = RegExp(
      r'''["']([^"'\s<>]*?\.m3u8(?:\?[^"'\s<>]*)?)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (quoted != null) {
      final resolved = _resolveMaybeEscaped(quoted.group(1)!, baseUrl);
      if (resolved != null) return resolved;
    }
    // 2) 未加引号的裸 URL（JS 里偶见）
    final bare = RegExp(
      r'''(https?://[^\s"'<>()]+\.m3u8(?:\?[^\s"'<>()]*)?)''',
      caseSensitive: false,
    ).firstMatch(html);
    if (bare != null) {
      final resolved = _resolveMaybeEscaped(bare.group(1)!, baseUrl);
      if (resolved != null) return resolved;
    }
    // 3) 相对路径 `index.m3u8` / `./index.m3u8`
    final relative = RegExp(
      r'''["']((?:\./|\.\./|/)?[^"'\s<>]*?\.m3u8(?:\?[^"'\s<>]*)?)["']''',
      caseSensitive: false,
    ).firstMatch(html);
    if (relative != null) {
      final resolved = _resolveMaybeEscaped(relative.group(1)!, baseUrl);
      if (resolved != null) return resolved;
    }
    return null;
  }

  /// 把 HTML 里可能带 JSON 转义（`\/`）的地址还原并按 [baseUrl] 解析成绝对地址。
  static String? _resolveMaybeEscaped(String raw, String? baseUrl) {
    var value = raw.replaceAll(r'\/', '/').trim();
    if (value.isEmpty) return null;
    if (value.startsWith('http://') || value.startsWith('https://')) return value;
    if (baseUrl == null || baseUrl.isEmpty) return null;
    try {
      final base = Uri.parse(baseUrl);
      return base.resolve(value).toString();
    } catch (_) {
      return null;
    }
  }

  /// 🔴🔴 2026-10-23：判断 URL 是否像**直链媒体文件**（mp4/flv/ts…）。
  ///
  /// 用于决定「要不要为这个 URL 额外做一次内容嗅探」：
  /// 直链媒体不需要嗅探（嗅探只会白下载一大段），而**无后缀的 URL**
  /// （如 `https://host/play/AbCd1234`）很可能是 HTML 播放器页，必须嗅探。
  static bool looksLikeDirectMediaUrl(String url) {
    final path = url.toLowerCase().split('?').first.split('#').first;
    const mediaSuffixes = <String>[
      '.mp4', '.flv', '.mkv', '.mov', '.webm', '.avi', '.wmv', '.m4v',
      '.ts', '.m4s', '.mp3', '.aac', '.m4a', '.3gp', '.ogv', '.f4v', '.rmvb',
    ];
    for (final s in mediaSuffixes) {
      if (path.endsWith(s)) return true;
    }
    return false;
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
    // 1. 真实 RESOLUTION → 走**最近邻**（长边），与尺寸实测路径同口径。
    //
    // 🔴 2026-10-23（第八轮）：原来这里有两套离散阈值
    // （宽高比<0.65 的「宽屏特殊规则」+ 标准档位阈值），
    // 和 [extractResolutionFromText] 的阈值又不一致 ——
    // 同一个 1200x674 在这里是 1080、在文本提取里是 480。
    //
    // 现在统一由 [nearestResolutionLabelFromSize] 裁决：
    // 宽高比 < 0.65 的超宽屏电影，**宽必然是长边**（宽 > 1.54×高），
    // 所以用长边天然等价于「按宽度档位判断」，不需要额外的特判。
    if (width != null && height != null && width > 0 && height > 0) {
      return _heightFromLabel(nearestResolutionLabelFromSize(width, height)) ??
          height;
    }

    // 2. 文本标签（含 URI/NAME）。资源站常在 URI 中写入真实码率（如 3000k），
    //    而 BANDWIDTH 属性可能偏低或不准确，因此优先使用文本信号。
    final combined = '${textLabel ?? ''} $uri'.trim();
    if (combined.isNotEmpty) {
      final label = extractResolutionFromText(combined);
      final h = _heightFromLabel(label);
      if (h != null && h > 0) return h;
    }

    // 3. BANDWIDTH 最后回退（同样走最近邻）。
    if (bandwidth != null && bandwidth > 0) {
      final h = _heightFromLabel(
        resolutionFromBitrateKbps(bandwidth / 1000),
      );
      if (h != null && h > 0) return h;
    }

    return 0;
  }

  /// Media playlist 无 RESOLUTION/BANDWIDTH/URL 文本线索时，通过 GET Range 探测前几个
  /// 分片的大小与 #EXTINF 时长估算码率，再映射到分辨率。可解决 LunaTV 通过 hls.js
  /// 真实解码获取 1080P、但文本解析只能得到 null 的问题。
  ///
  /// 取前 [maxProbes] 个分片的最大码率，避免首个分片常因片头/低码率 ramp-up 被低估。
  /// 🔴 2026-10-23（第三轮）：从 media playlist 文本解析**首个分片的时长**。
  ///
  /// 只做文本解析，**不发任何网络请求**。配合测速请求响应头里的
  /// `Content-Range` 总大小（分片字节数），即可算出码率 →
  /// [resolutionFromBitrateKbps] → 分辨率，
  /// 从而省掉一次专门为估算码率而发的 Range 请求。
  static double? _firstSegmentDuration(List<String> lines) {
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('#EXTINF:')) {
        final value = line.substring(8).split(',').first.trim();
        final d = double.tryParse(value);
        if (d != null && d > 0) return d;
      }
    }
    return null;
  }

  /// 🔴 2026-10-23（第三轮）：码率（kbps）→ 分辨率标签。
  ///
  /// 供调用方用「测速响应头的分片总大小 + 分片时长」推算分辨率时使用。
  ///
  /// 🔴🔴 2026-10-23（第六轮）：改成**按接近哪个档返回哪个**，不再用
  /// 「离散阈值 + 对不上就掉最低档」的写法。
  /// 旧口径 661kbps 会落到 360P，但实测该流真实是 1920x818（1080P 级别）——
  /// 码率与分辨率本就没有必然关系，兜底口径至少不该制造突兀的「低清」印象。
  static String? resolutionFromBitrateKbps(double kbps) {
    return _bitrateToResolutionLabel(kbps);
  }

  static String? _bitrateToResolutionLabel(double kbps) {
    if (kbps <= 0) return null;
    // 各档位的典型码率（kbps）作为档位中心，按最近邻归类。
    const centers = <int, String>{
      650: '360P',
      1100: '480P',
      2200: '720P',
      4500: '1080P',
      7000: '2K',
      10000: '4K',
    };
    String? best;
    var bestDiff = double.infinity;
    centers.forEach((center, label) {
      final d = (center - kbps).abs().toDouble();
      if (d < bestDiff) {
        bestDiff = d;
        best = label;
      }
    });
    return best;
  }

  /// 🔴🔴 2026-10-23（第六轮）：**真实宽高 → 按接近哪个标准档归类**。
  ///
  /// 用户原话：「很多视频不是标准的1080、720、480、360分辨率，应该按接近
  /// 哪个返回哪个，而不是对不上就返回360」。
  ///
  /// 资源站大量使用**宽屏电影**分辨率（1920x818 / 1920x800 / 1280x536），
  /// 它们不在标准档位上。判定用**长边**（取宽高中较大者，兼顾竖屏源）：
  ///   · 1920x818 → 长边 1920 → 1080P ✓
  ///   · 1280x536 → 长边 1280 → 720P ✓
  ///   · 854x480  → 长边 854  → 480P ✓
  ///   · 640x360  → 长边 640  → 360P ✓
  ///   · 720x1280 （竖屏）→ 长边 1280 → 720P ✓
  static String nearestResolutionLabelFromSize(int width, int height) {
    final longSide = width > height ? width : height;
    // 各档位的长边基准像素。
    const ladder = <int, String>{
      640: '360P',
      854: '480P',
      1280: '720P',
      1920: '1080P',
      2560: '2K',
      3840: '4K',
    };
    String? best;
    var bestDiff = 1 << 30;
    ladder.forEach((px, label) {
      final d = (px - longSide).abs();
      if (d < bestDiff) {
        bestDiff = d;
        best = label;
      }
    });
    return best ?? '360P';
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
        // 🔴 2026-10-23（第八轮）：改用**最近邻**（长边），
        // 不再用「离散阈值 + 对不上就落最低档」。
        //
        // 旧口径把 1200x674 判成 480P（maxDim=1200 → >=854 → 480），
        // 而 [_estimateHeight] 对**同一个尺寸**却判 1080P ——
        // 同一视频两个答案。现在两条路径统一走
        // [nearestResolutionLabelFromSize]（唯一真相源）。
        final estimatedH =
            _heightFromLabel(nearestResolutionLabelFromSize(w, h));
        if (estimatedH != null) {
          bestHeight = _maxHeight(bestHeight, estimatedH);
        }
      }
    }

    // 码率模式：如 3000k/hls/mixed.m3u8、1500k、4000K、3000kbps、3M、4Mbps。
    // 阈值与 [_estimateHeight] 保持一致：2500k 以上对应 1080p，1500k 对应 720p，
    // 800k 对应 480p，500k 对应 360p。
    final bitrateRe = RegExp(r'(?:^|[^a-zA-Z0-9])(\d{3,5})\s*[kK](?:\s*[bB][pP][sS])?(?:[^a-zA-Z0-9]|$)');
    for (final m in bitrateRe.allMatches(lower)) {
      final kbps = int.tryParse(m.group(1)!);
      if (kbps != null && kbps >= 500) {
        // 🔴 2026-10-23（第八轮）：码率也走**最近邻**（档位中心），
        // 与尺寸路径、码率兜底路径保持同一套口径。
        final h = _heightFromLabel(resolutionFromBitrateKbps(kbps.toDouble()));
        if (h != null) {
          bestHeight = _maxHeight(bestHeight, h);
        }
      }
    }

    // 大写 M/Mbps 模式：如 3M、4Mbps、5Mbit（按兆比特换算，1M≈1000k）。
    final mbpsRe = RegExp(r'(?:^|[^a-zA-Z0-9])(\d{1,2})\s*[mM](?:\s*[bB][pP][sS]|\s*[bB][iI][tT])?(?:[^a-zA-Z0-9]|$)');
    for (final m in mbpsRe.allMatches(lower)) {
      final mbps = int.tryParse(m.group(1)!);
      if (mbps != null && mbps >= 1) {
        final kbps = mbps * 1000;
        final h = _heightFromLabel(resolutionFromBitrateKbps(kbps.toDouble()));
        if (h != null) {
          bestHeight = _maxHeight(bestHeight, h);
        }
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
    //
    // 🔴🔴 2026-10-23（第六轮）：别名只在**非 URL host** 的文本里匹配。
    //
    // 实测 `https://hd.kuktxu.com/play/eXD5yD8e` 被判成 720P —— 命中的是
    // **主机名里的 `hd`**（kuktxu 的「高清站」域名），与视频清晰度毫无关系。
    // 这类域名极常见（hd./cdn./vod. 前缀），误判面很大。
    //
    // 维度/码率/像素/中文这些**有明确数值语义**的规则仍然看原文（含 URL path），
    // 只有 hd / sd / fhd 这种「无数字的单词别名」需要排除 host。
    final aliasText = _stripUrlHosts(text).toLowerCase();
    if (RegExp(r'(?:^|[^a-z0-9])(?:fhd|fullhd|full\s*hd)(?:$|[^a-z0-9])')
        .hasMatch(aliasText)) {
      bestHeight = _maxHeight(bestHeight, 1080);
    }
    if (RegExp(r'(?:^|[^a-z0-9])hd(?:$|[^a-z0-9])').hasMatch(aliasText)) {
      bestHeight = _maxHeight(bestHeight, 720);
    }
    if (RegExp(r'(?:^|[^a-z0-9])sd(?:$|[^a-z0-9])').hasMatch(aliasText)) {
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

  /// 🔴 2026-10-23：把文本里所有 URL 的 **host 段**抹掉（保留 path/query）。
  ///
  /// 用于「无数字的清晰度别名」（hd / sd / fhd）匹配：主机名里的 `hd`
  /// 与视频清晰度无关，path 里的 `hd`（如 `/hd/` 目录）才可能是线索。
  static String _stripUrlHosts(String text) {
    return text.replaceAllMapped(
      RegExp(r'https?://[^/\s?#]+', caseSensitive: false),
      (_) => ' ',
    );
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
  static Future<M3u8Analysis> analyzeM3u8ForSpeedTest(
    String url, {
    Map<String, String> headers = const {},
    Duration timeout = const Duration(seconds: 3),
    int maxSegments = 2,
    http.Client? client,
    /// 🔴 2026-10-23（第三轮）：**码率估算不再单独发请求**。
    ///
    /// 原实现为「按分片码率推断分辨率」额外发 1~5 次 Range 请求，
    /// 与测速请求串行叠加，高延迟源要多付 1.5~2 秒 RTT。
    /// 现在码率改由**测速请求的 Content-Range 总大小 + 首个分片的
    /// #EXTINF 时长**推算（在 [LunaTVService.speedTestEpisode] 里完成），
    /// 完全省掉这一次串行 RTT。
    ///
    /// 保留这两个参数只为兼容旧调用点，解析阶段不再使用。
    @Deprecated('码率估算已并入测速请求，不再单独发探测请求')
    int estimateProbes = 5,
    @Deprecated('码率估算已并入测速请求，不再单独发探测请求')
    int estimateRangeBytes = 64 * 1024,
  }) async {
    if (!isM3u8Url(url)) {
      return (
        isMaster: false,
        resolution: null,
        segmentUrls: [url],
        playlistUrl: url,
        firstSegmentDuration: null,
        encryptionKeyUri: null,
        encryptionIv: null,
      );
    }
    try {
      // 🔴 2026-10-23：只有**自己创建**的 client 才关闭。
      //
      // 原实现无条件 `httpClient.close()`，把调用方传进来的 client 也关了 ——
      // 调用方（speedTestEpisode / 端到端脚本）继续用同一个 client 发请求时
      // 会直接抛 `ClientException: Client is already closed`。
      final ownsClient = client == null;
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
          firstSegmentDuration: null,
          encryptionKeyUri: null,
          encryptionIv: null,
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
          firstSegmentDuration: null,
          encryptionKeyUri: null,
          encryptionIv: null,
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
          firstSegmentDuration: null,
          encryptionKeyUri: null,
          encryptionIv: null,
        );
      }
      final baseUri = Uri.parse(url);
      final lines = content.replaceAll('\r\n', '\n').split('\n');

      // 1. Master playlist：选择最佳 variant 后递归分析。
      final variants = _parseStreamVariants(lines);
      // 🔴🔴 2026-10-15 修复「界面卡死」：大幅削减本函数的日志量。
      //
      //   原实现把**整个 M3U8 内容的前 800 字符**逐条 debugPrint，且为**每个
      //   variant** 各打一条。真机/模拟器日志实测：播放期间与退出播放后，
      //   这套日志以**每秒 40~91 条**的密度刷屏数秒（连带分片 Range-GET 的
      //   日志），造成主 isolate 被同步 IO 占满 —— 用户看到的是「软件界面卡死」。
      //
      //   机制：`debugPrint` 并非空操作。它走 `debugPrintThrottled`，内部有
      //   定时器与 Zone 调度，**release 下依然写 logcat**。每秒九十次
      //   同步系统调用足以让 UI 掉帧到不可交互。
      //   （源码原 TODO 已写明「问题确认后可调低日志级别或移除」—— 现执行。）
      //
      //   ⚠️ 只删「必然刷屏」的两类，**保留**后续的分片码率结论类日志：
      //      · `内容长度=... 摘要(前800)=...`  ← 整段 playlist 正文，最长的一条
      //      · `变体#N ...` 的逐条循环            ← 变体多时成倍放大
      //   这两条是刷屏主因，且其信息（几个变体、选定哪个）已被下面那条
      //   「选定最佳变体」概览覆盖，删除不丢诊断能力。
      if (kM3u8VerboseLog) {
        debugPrint('[M3U8分析] URL=$url');
        debugPrint('[M3U8分析] 内容长度=${content.length}');
        debugPrint('[M3U8分析] 解析到变体数=${variants.length}');
        for (var i = 0; i < variants.length; i++) {
          final v = variants[i];
          debugPrint(
            '[M3U8分析] 变体#$i bw=${v.bandwidth} res=${v.resolutionLabel} height=${v.height}',
          );
        }
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
          estimateProbes: estimateProbes,
          estimateRangeBytes: estimateRangeBytes,
        );
        return (
          isMaster: true,
          resolution: best.resolutionLabel ?? child.resolution,
          segmentUrls: child.segmentUrls,
          playlistUrl: resolvedUri,
          firstSegmentDuration: child.firstSegmentDuration,
          encryptionKeyUri: child.encryptionKeyUri,
          encryptionIv: child.encryptionIv,
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
            estimateProbes: estimateProbes,
            estimateRangeBytes: estimateRangeBytes,
          );
          return (
            isMaster: false,
            resolution: child.resolution,
            segmentUrls: child.segmentUrls,
            playlistUrl: resolved,
            firstSegmentDuration: child.firstSegmentDuration,
            encryptionKeyUri: child.encryptionKeyUri,
            encryptionIv: child.encryptionIv,
          );
        }
        segmentUrls.add(resolved);
        if (segmentUrls.length >= maxSegments) break;
      }

      String? urlResolution = extractResolutionFromText(url);
      // 🔴 2026-10-23（第三轮）：解析阶段**不再为码率估算发请求**。
      //
      // 原实现在这里对分片发 Range 请求拿总大小算码率（→分辨率），
      // 与后面的测速请求串行叠加：media playlist 3 次串行 RTT，
      // master playlist 更要 4 次。实测高延迟源单次 RTT 1.5~2 秒，
      // 这一发就是整轮测速慢的主因之一。
      //
      // 现在只**解析**首个分片的 #EXTINF 时长（零请求），
      // 码率改由测速请求的 Content-Range 总大小推算，
      // 由调用方 [LunaTVService.speedTestEpisode] 用
      // [resolutionFromBitrateKbps] 换算成分辨率。
      final firstDuration = _firstSegmentDuration(lines);

      // 🔴 2026-10-23：解析 `#EXT-X-KEY`（AES-128）。
      //
      // 资源站的 media playlist 普遍带 key，分片是**密文**。要拿真实分辨率
      // 必须先解密，这里把 key URI / IV 带出去，测速阶段并发取 key。
      String? keyUri;
      String? keyIv;
      for (final raw in lines) {
        final l = raw.trim();
        if (!l.startsWith('#EXT-X-KEY:')) continue;
        if (!l.contains('METHOD=AES-128')) continue;
        final u = RegExp(r'URI="([^"]+)"').firstMatch(l)?.group(1);
        if (u == null || u.isEmpty) continue;
        keyUri = u.startsWith('http://') || u.startsWith('https://')
            ? u
            : baseUri.resolve(u).toString();
        final ivm = RegExp(r'IV=0x([0-9a-fA-F]+)').firstMatch(l);
        keyIv = ivm?.group(1);
        break;
      }

      debugPrint(
        '[M3U8分析] 未解析到变体（Media playlist），从URL推断分辨率: $urlResolution，'
        '片段数: ${segmentUrls.length} 首片时长: $firstDuration'
        '${keyUri != null ? ' 加密=AES-128' : ''}',
      );
      return (
        isMaster: false,
        resolution: urlResolution,
        segmentUrls: segmentUrls,
        playlistUrl: url,
        firstSegmentDuration: firstDuration,
        encryptionKeyUri: keyUri,
        encryptionIv: keyIv,
      );
      } finally {
        if (ownsClient) httpClient.close();
      }
    } catch (e) {
      debugPrint('analyzeM3u8ForSpeedTest 失败: $e');
      // 🔴 2026-10-23：网络层异常必须**向上抛出**，不能在这里吞掉。
      //
      // 原实现吞掉异常后返回空分片，调用方无法区分「内容不是 M3U8」
      // 与「根本连不上」，于是会对 playlist URL 再测一次（再等一个
      // measureTimeout），实测连不上的源单源要耗 5~13 秒。
      // 抛出去后调用方能置位 hasNetworkError，直接跳过回退测速。
      rethrow;
    }
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
