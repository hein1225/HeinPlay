import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'm3u8_ad_filter.dart';
import '../utils/windows_logger.dart';

/// 本地 M3U8/TS 代理服务。
///
/// 用于解决去广告后的 M3U8 在不同播放器后端（ExoPlayer / flutter_mpv / 外部 mpv）
/// 中播放时头部透传不一致的问题。所有资源请求统一走本地代理，由代理补全头部。
class LocalM3u8Proxy {
  HttpServer? _server;
  String? _playlistContent;
  final Map<String, String> _baseHeaders = {};
  http.Client? _client;
  bool _closing = false;
  bool _filterEnabled = false;

  bool get isRunning => _server != null;

  /// 设置是否对子 M3U8 启用广告过滤。
  void setFilterEnabled(bool enabled) {
    _filterEnabled = enabled;
  }

  void _log(String message) {
    WindowsLogger.log('LocalM3u8Proxy', message);
  }

  String? get baseUrl {
    final server = _server;
    if (server == null) return null;
    return 'http://${server.address.host}:${server.port}';
  }

  /// 启动本地代理服务器。
  /// 返回代理根地址，例如 http://127.0.0.1:12345
  Future<String> start() async {
    if (_server != null) {
      return baseUrl!;
    }
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server!.listen(_handleRequest);
    _client ??= http.Client();
    _log('LocalM3u8Proxy started at $baseUrl');
    return baseUrl!;
  }

  /// 设置当前播放列表内容与原始请求头。
  void setPlaylist(String content, Map<String, String> headers) {
    _playlistContent = content;
    _baseHeaders
      ..clear()
      ..addAll(headers);
  }

  Future<void> stop() async {
    _closing = true;
    await _server?.close(force: true);
    _server = null;
    _playlistContent = null;
    _baseHeaders.clear();
    // HttpClient.close() 会等待 pending 请求结束，这里不阻塞关闭流程，
    // 避免应用退出时因正在下载的 segment 而卡顿。
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.close();
      } catch (_) {
        // 忽略关闭错误
      }
    }
    _closing = false;
    _log('LocalM3u8Proxy stopped');
  }

  Future<void> _handleRequest(HttpRequest request) async {
    try {
      final method = request.method.toUpperCase();
      final path = request.uri.path;

      if (method == 'OPTIONS') {
        await _serveCorsPreflight(request);
        return;
      }

      if (path == '/playlist.m3u8') {
        await _servePlaylist(request, isHead: method == 'HEAD');
      } else if (path == '/segment') {
        await _proxySegment(request, isHead: method == 'HEAD');
      } else {
        request.response
          ..statusCode = HttpStatus.notFound
          ..write('Not found')
          ..close();
      }
    } catch (e, stack) {
      _log('LocalM3u8Proxy handleRequest error: $e');
      _log('$stack');
      try {
        request.response
          ..statusCode = HttpStatus.internalServerError
          ..write('Internal server error')
          ..close();
      } catch (_) {}
    }
  }

  Future<void> _serveCorsPreflight(HttpRequest request) async {
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.add('Access-Control-Allow-Origin', '*')
      ..headers.add('Access-Control-Allow-Methods', 'GET, HEAD, OPTIONS')
      ..headers.add('Access-Control-Allow-Headers', 'Range, Content-Type')
      ..headers.add('Access-Control-Max-Age', '86400');
    await response.close();
  }

  Future<void> _servePlaylist(
    HttpRequest request, {
    bool isHead = false,
  }) async {
    final content = _playlistContent ?? '#EXTM3U\n#EXT-X-ENDLIST\n';
    final bytes = utf8.encode(content);
    final response = request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType('application', 'vnd.apple.mpegurl')
      ..headers.add('Content-Length', bytes.length.toString())
      ..headers.add('Access-Control-Allow-Origin', '*')
      ..headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
    if (!isHead) {
      response.add(bytes);
    }
    await response.close();
  }

  Future<void> _proxySegment(HttpRequest request, {bool isHead = false}) async {
    final urlParam = request.uri.queryParameters['url'];
    if (urlParam == null || urlParam.isEmpty) {
      request.response
        ..statusCode = HttpStatus.badRequest
        ..write('Missing url')
        ..close();
      return;
    }

    final targetUrl = Uri.decodeComponent(urlParam);
    final targetUri = Uri.parse(targetUrl);

    final headers = <String, String>{
      'User-Agent':
          _baseHeaders['User-Agent'] ??
          'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
              ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      'Connection': 'keep-alive',
    };

    // 优先使用传入的 Referer/Origin；否则根据目标 URL 自动推导
    var referer = _baseHeaders['Referer'] ?? _baseHeaders['referer'];
    var origin = _baseHeaders['Origin'] ?? _baseHeaders['origin'];
    if (referer == null || referer.isEmpty) {
      referer = '${targetUri.scheme}://${targetUri.host}/';
      origin = '${targetUri.scheme}://${targetUri.host}';
    }
    headers['Referer'] = referer;
    if (origin != null && origin.isNotEmpty) {
      headers['Origin'] = origin;
    }

    // 透传 Range，但 M3U8 播放列表必须获取完整内容才能正确计算总时长，
    // 否则播放器收到 206 部分响应会导致进度条/时长显示异常。
    final isM3u8Url =
        targetUrl.toLowerCase().contains('.m3u8') ||
        targetUrl.toLowerCase().contains('/hls/');
    final range = request.headers.value('range');
    if (range != null && range.isNotEmpty && !isM3u8Url) {
      headers['Range'] = range;
    }

    try {
      final requestMethod = isHead ? 'HEAD' : 'GET';
      final requestUri = Uri.parse(targetUrl);
      final client = _client ?? http.Client();
      _log('proxySegment request: $targetUrl');
      final response = await client
          .send(
            http.Request(requestMethod, requestUri)..headers.addAll(headers),
          )
          .timeout(const Duration(seconds: 30))
          .then(http.Response.fromStream);

      _log(
        'proxySegment response: $targetUrl status=${response.statusCode} '
        'contentType=${response.headers['content-type']} '
        'contentLength=${response.headers['content-length']}',
      );

      final out = request.response;
      out.statusCode = response.statusCode;

      final contentType = response.headers['content-type'];
      if (contentType != null && contentType.isNotEmpty) {
        out.headers.contentType = _parseContentType(contentType);
      }

      final acceptRanges = response.headers['accept-ranges'];
      if (acceptRanges != null && acceptRanges.isNotEmpty) {
        out.headers.add('Accept-Ranges', acceptRanges);
      }

      final contentRange = response.headers['content-range'];
      if (contentRange != null && contentRange.isNotEmpty) {
        out.headers.add('Content-Range', contentRange);
      }

      out.headers.add('Access-Control-Allow-Origin', '*');
      out.headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');

      if (!isHead) {
        var bodyBytes = response.bodyBytes;
        final isM3u8 = _isM3u8Content(response);
        // 如果响应是子 M3U8/播放列表且请求成功，按需进行广告过滤，
        // 再把资源 URL 重写为本地代理地址。
        if (response.statusCode >= 200 &&
            response.statusCode < 300 &&
            isM3u8) {
          final decoded = utf8.decode(bodyBytes, allowMalformed: true);
          _log(
            'proxySegment sub-m3u8 raw: $targetUrl\n${_summarizeContent(decoded)}',
          );
          final filtered = _filterEnabled ? _filterM3u8(targetUrl, decoded) : decoded;
          final resolved = resolveRelativeUrls(filtered, targetUrl);
          final rewritten = rewriteToLocalProxy(resolved, baseUrl!);
          bodyBytes = utf8.encode(rewritten);
          // 确保播放器把子 M3U8 识别为播放列表
          out.headers.contentType = ContentType('application', 'vnd.apple.mpegurl');
          _log(
            'proxySegment sub-m3u8 rewritten: $targetUrl\n${_summarizeContent(utf8.decode(bodyBytes, allowMalformed: true))}',
          );
        } else if (response.statusCode < 200 || response.statusCode >= 300) {
          // 记录非 2xx 响应摘要，便于排查 404/403 等问题
          final preview = utf8.decode(bodyBytes, allowMalformed: true);
          _log(
            'proxySegment error response: $targetUrl status=${response.statusCode} '
            'bodyPreview=${preview.length > 200 ? '${preview.substring(0, 200)}...' : preview}',
          );
        }
        // 必须根据实际 body 长度设置 Content-Length，避免上游返回错误页面时长度不一致。
        out.headers.set('Content-Length', bodyBytes.length.toString());
        out.add(bodyBytes);
        _log(
          'proxySegment served: $targetUrl status=${response.statusCode} bytes=${bodyBytes.length}',
        );
      }
      await out.close();
    } catch (e, stack) {
      if (!_closing) {
        _log('LocalM3u8Proxy proxySegment error: $e');
        _log('$stack');
      }
      try {
        request.response
          ..statusCode = HttpStatus.badGateway
          ..write('Proxy error')
          ..close();
      } catch (_) {}
    }
  }

  static bool _isM3u8Content(http.Response response) {
    final contentType = response.headers['content-type']?.toLowerCase() ?? '';
    if (contentType.contains('mpegurl') ||
        contentType.contains('m3u8') ||
        contentType.contains('application/vnd.apple.mpegurl') ||
        contentType.contains('audio/x-mpegurl')) {
      return true;
    }
    final body = response.body;
    // M3U8 播放列表大小通常远小于媒体片段，超过 512KB 的响应更可能是媒体数据
    return body.length < 512 * 1024 && body.trim().startsWith('#EXTM3U');
  }

  /// 将 M3U8 内容中的相对 URL 根据 [baseUrl] 解析为绝对 URL。
  static String resolveRelativeUrls(String content, String baseUrl) {
    final baseUri = Uri.parse(baseUrl);
    final lines = content.split('\n');
    final result = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          !trimmed.startsWith('data:') &&
          !trimmed.startsWith('http://') &&
          !trimmed.startsWith('https://')) {
        result.add(baseUri.resolve(trimmed).toString());
        continue;
      }

      // 处理 URI="..." 标签
      if (_hasUriAttribute(trimmed)) {
        result.add(_resolveUriLine(baseUrl, raw));
        if (trimmed.startsWith('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
          final nextRaw = lines[i + 1];
          final nextTrimmed = nextRaw.trim();
          if (nextTrimmed.isNotEmpty &&
              !nextTrimmed.startsWith('#') &&
              !nextTrimmed.startsWith('data:') &&
              !nextTrimmed.startsWith('http://') &&
              !nextTrimmed.startsWith('https://')) {
            result.add(baseUri.resolve(nextTrimmed).toString());
            i++;
            continue;
          }
        }
        continue;
      }

      result.add(raw);
    }

    return result.join('\n');
  }

  static bool _hasUriAttribute(String line) {
    return line.startsWith('#EXT-X-KEY') ||
        line.startsWith('#EXT-X-MAP') ||
        line.startsWith('#EXT-X-MEDIA') ||
        line.startsWith('#EXT-X-PART') ||
        line.startsWith('#EXT-X-PRELOAD-HINT') ||
        line.startsWith('#EXT-X-SESSION-DATA') ||
        line.startsWith('#EXT-X-SESSION-KEY') ||
        line.startsWith('#EXT-X-RENDITION-REPORT') ||
        line.startsWith('#EXT-X-CONTENT-STEERING');
  }

  /// 取 M3U8/文本内容前若干行用于诊断，避免日志过大。
  static String _summarizeContent(String content, {int maxLines = 20}) {
    final lines = content.split('\n');
    final head = lines.take(maxLines).join('\n');
    if (lines.length <= maxLines) return head;
    return '$head\n... (${lines.length} 行)';
  }

  static String _resolveUriLine(String base, String line) {
    final uriPattern = RegExp(r'URI="([^"]+)"');
    return line.replaceAllMapped(uriPattern, (match) {
      final original = match.group(1)!;
      try {
        return 'URI="${Uri.parse(base).resolve(original).toString()}"';
      } catch (_) {
        return match.group(0)!;
      }
    });
  }

  ContentType? _parseContentType(String value) {
    try {
      final parts = value.split(';');
      final mime = parts[0].trim();
      final mimeParts = mime.split('/');
      if (mimeParts.length == 2) {
        var charset;
        for (final part in parts.skip(1)) {
          final kv = part.trim().split('=');
          if (kv.length == 2 && kv[0].toLowerCase() == 'charset') {
            charset = kv[1].trim();
          }
        }
        return ContentType(mimeParts[0], mimeParts[1], charset: charset);
      }
    } catch (_) {}
    return null;
  }

  /// 将 M3U8 内容中的所有资源 URL 重写为本地代理地址。
  static String rewriteToLocalProxy(String content, String proxyBaseUrl) {
    final lines = content.split('\n');
    final result = <String>[];

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      // 媒体行
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          !trimmed.startsWith('data:')) {
        result.add(_proxyUrl(proxyBaseUrl, trimmed));
        continue;
      }

      // 需要处理 URI 的标签
      if (trimmed.startsWith('#EXT-X-MAP') ||
          trimmed.startsWith('#EXT-X-KEY') ||
          trimmed.startsWith('#EXT-X-MEDIA') ||
          trimmed.startsWith('#EXT-X-PART') ||
          trimmed.startsWith('#EXT-X-PRELOAD-HINT') ||
          trimmed.startsWith('#EXT-X-STREAM-INF') ||
          trimmed.startsWith('#EXT-X-SESSION-DATA') ||
          trimmed.startsWith('#EXT-X-SESSION-KEY') ||
          trimmed.startsWith('#EXT-X-RENDITION-REPORT') ||
          trimmed.startsWith('#EXT-X-CONTENT-STEERING')) {
        result.add(_rewriteUriAttributes(proxyBaseUrl, raw));
        // 若下一行是子 M3U8 URL，也重写
        if (trimmed.startsWith('#EXT-X-STREAM-INF') && i + 1 < lines.length) {
          final nextRaw = lines[i + 1];
          final nextTrimmed = nextRaw.trim();
          if (nextTrimmed.isNotEmpty && !nextTrimmed.startsWith('#')) {
            result.add(_proxyUrl(proxyBaseUrl, nextTrimmed));
            i++;
            continue;
          }
        }
        continue;
      }

      result.add(raw);
    }

    return result.join('\n');
  }

  static String _rewriteUriAttributes(String proxyBaseUrl, String line) {
    final uriPattern = RegExp(r'URI="([^"]+)"');
    return line.replaceAllMapped(uriPattern, (match) {
      final original = match.group(1)!;
      return 'URI="${_proxyUrl(proxyBaseUrl, original)}"';
    });
  }

  static String _proxyUrl(String proxyBaseUrl, String originalUrl) {
    if (originalUrl.startsWith('http://') ||
        originalUrl.startsWith('https://')) {
      return '$proxyBaseUrl/segment?url=${Uri.encodeComponent(originalUrl)}';
    }
    return originalUrl;
  }

  /// 对 M3U8 内容进行本地广告过滤。
  static String _filterM3u8(String baseUrl, String content) {
    try {
      final filter = M3u8AdFilter();
      final filtered = filter.purify(baseUrl, content);
      if (filtered != null && filtered != content) {
        WindowsLogger.log(
          'LocalM3u8Proxy',
          '子 M3U8 过滤: ${filter.currentAdCount} 个片段',
        );
        return filtered;
      }
    } catch (e, stack) {
      WindowsLogger.log('LocalM3u8Proxy', '子 M3U8 过滤失败: $e');
      WindowsLogger.log('LocalM3u8Proxy', '$stack');
    }
    return content;
  }
}
