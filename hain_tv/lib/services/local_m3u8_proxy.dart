import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:pointycastle/api.dart';
import 'package:pointycastle/block/aes_fast.dart';
import 'package:pointycastle/block/modes/cbc.dart';

import 'm3u8_ad_filter.dart';
import '../utils/windows_logger.dart';

/// 本地 M3U8/TS 代理服务。
///
/// 用于解决去广告后的 M3U8 在不同播放器后端（ExoPlayer / FVP / VLC）
/// 中播放时头部透传不一致的问题。所有资源请求统一走本地代理，由代理补全头部。
class LocalM3u8Proxy {
  HttpServer? _server;
  String? _playlistContent;
  final Map<String, String> _baseHeaders = {};
  http.Client? _client;
  bool _closing = false;
  bool _filterEnabled = false;
  bool _discontinuityCleanup = false;
  // fvp 专属：给每个分段代理 URL 注入全局唯一序号（&hseg=N）并丢弃结构性
  // #EXT-X-DISCONTINUITY，避免 libmdk 因跨断点复用同名分片（如 plist0.ts）
  // 命中段缓存、停止续预取而卡死。仅 fvp 后端开启。
  bool _fvpRenumber = false;

  /// ★ 2026-09-25：master playlist 展开缓存。
  ///
  /// 现象（072249 日志实证）：若交给 libmdk 的 `playlist.m3u8` 是 **master**
  /// （只有 `#EXT-X-STREAM-INF` + 一行变体 URL），libmdk 需再请求「子 m3u8」取到
  /// media playlist；此时它会陷入死锁：`buffered` 恒等于 `position`（上报的缓冲
  /// 区间长度 = 0）、`buffering=true` 永不结束、永远够不到 `min` 起播阈值，于是
  /// 画面卡死、reader 反复重下同一批分片（源1 17s 内 199 次请求 / 仅 62 个唯一
  /// 分片）。而**单级** media playlist 的源（`playlist.m3u8` 本身就是 media，
  /// 如 ly166）同机同源正常播放，`buffered` 领先 `position` 达 max=20000ms。
  ///
  /// 修复：代理在 `playlist.m3u8` 出口处把 master **就地展开为 media**——直接拉取
  /// 变体 media playlist、去广告、重写分片 URL 后作为响应体返回，让 libmdk 只看到
  /// 一级结构（= 能播源的形态）。纯代理层改动，不碰 fvp/libmdk。
  ///
  /// 展开只做一次并缓存（libmdk 可能多次请求 playlist）；展开失败则**回退原 master**
  /// 保持旧行为，不使情况恶化。
  ///
  /// ⚠️ 缓存带 **3 秒 TTL**：点播（VOD）的 media playlist 不变，缓存只用于省掉重复
  /// 的 CDN 往返；但**直播**的 media playlist 会按 `#EXT-X-TARGETDURATION`（4–6s）
  /// 滚动，若永久缓存会让 libmdk 永远拿到旧播放列表而卡住。3s < 4s，直播每次
  /// reload 都会重新展开。失败时只在 TTL 窗口内退避，窗口外允许重试。
  String? _expandedPlaylist;
  DateTime? _expandedAt;
  static const Duration _kExpandedTtl = Duration(seconds: 3);

  /// 播放列表代次：`setPlaylist`（换源/换集）时自增。
  ///
  /// 展开是异步的（含一次 CDN 往返），若期间发生换源，旧源的展开结果绝不能写回
  /// `_expandedPlaylist`——否则新源会拿到**上一个源的 media playlist** 而播错内容。
  int _playlistGen = 0;

  /// fvp 专属：AES-128 解密用到的 key 缓存（按 key URI 缓存，避免每段重复拉取）。
  final Map<String, Uint8List> _aesKeyCache = {};

  bool get isRunning => _server != null;

  /// 设置是否对子 M3U8 启用广告过滤。
  void setFilterEnabled(bool enabled) {
    _filterEnabled = enabled;
  }

  /// 设置去广告后是否清理孤立的 EXT-X-DISCONTINUITY 标记（Windows/fvp 需要）。
  void setDiscontinuityCleanup(bool enabled) {
    _discontinuityCleanup = enabled;
  }

  /// 设置 fvp 专属分段重编号 + 结构性 discontinuity 丢弃开关。
  /// 仅 fvp 后端开启：让每个分段代理 URL 全局唯一，规避 libmdk 段名复用卡死。
  void setFvpRenumber(bool enabled) {
    _fvpRenumber = enabled;
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
    // 换源/换集必须重置展开缓存，否则会沿用上一个源展开出的 media playlist。
    _expandedPlaylist = null;
    _expandedAt = null;
    // 代次自增，让仍在途的旧源展开结果作废（见 _playlistGen 注释）。
    _playlistGen++;
    _baseHeaders
      ..clear()
      ..addAll(headers);
  }

  Future<void> stop() async {
    _closing = true;
    await _server?.close(force: true);
    _server = null;
    _playlistContent = null;
    _expandedPlaylist = null;
    _expandedAt = null;
    _playlistGen++;
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
    final content = await _resolvePlaylistContent();
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

  /// 返回 `playlist.m3u8` 的响应体：master 就地展开为 media（见 `_expandedPlaylist` 注释）。
  Future<String> _resolvePlaylistContent() async {
    final content = _playlistContent ?? '#EXTM3U\n#EXT-X-ENDLIST\n';

    if (!_isMasterPlaylist(content)) return content;

    // TTL 窗口内直接复用（展开成功用展开结果；失败则退回原 master，不做重试风暴）。
    final at = _expandedAt;
    if (at != null && DateTime.now().difference(at) < _kExpandedTtl) {
      return _expandedPlaylist ?? content;
    }

    final variantUrl = _extractFirstVariantUrl(content);
    if (variantUrl == null) {
      _log('master 展开：未找到变体 URL，保持原样');
      _expandedAt = DateTime.now();
      return content;
    }

    final gen = _playlistGen;
    try {
      final expanded = await _fetchAndRewriteM3u8(variantUrl);
      // 展开期间若已换源/换集，本次结果作废，否则会把上一个源的 media playlist
      // 写进缓存，导致新源播错内容。
      if (gen != _playlistGen) {
        _log('master 展开结果作废（期间已换源）: $variantUrl');
        return _playlistContent ?? content;
      }
      _expandedAt = DateTime.now();
      if (expanded == null || expanded.trim().isEmpty) {
        _log('master 展开失败（下载/重写为空），回退原 master: $variantUrl');
        return _expandedPlaylist ?? content;
      }
      _expandedPlaylist = expanded;
      _log('master 展开为 media（单级）成功: $variantUrl');
      return expanded;
    } catch (e) {
      _log('master 展开异常，回退原 master: $e');
      if (gen == _playlistGen) _expandedAt = DateTime.now();
      return _expandedPlaylist ?? content;
    }
  }

  /// 判定是否为 master playlist。
  ///
  /// 双重条件：含 `#EXT-X-STREAM-INF` **且**不含 `#EXTINF`（master 描述各码率变体，
  /// 没有分片时长标签）。单看 `#EXT-X-STREAM-INF` 不足以判定，避免误展开。
  static bool _isMasterPlaylist(String content) {
    if (!content.contains('#EXT-X-STREAM-INF')) return false;
    for (final line in content.split('\n')) {
      if (line.trim().startsWith('#EXTINF')) return false;
    }
    return true;
  }

  /// 取第一个 `#EXT-X-STREAM-INF` 后紧跟的变体 URL 行（跳过注释与空行）。
  ///
  /// 注意：`setPlaylist` 传入的内容已由 `rewriteToLocalProxy` 重写过，故该变体 URL
  /// 通常是本地代理形式 `http://127.0.0.1:port/segment?url=<encoded cdn url>`；
  /// 也兼容仍是原始 CDN URL 的情况。
  static String? _extractFirstVariantUrl(String content) {
    final lines = content.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final trimmed = lines[i].trim();
      if (!trimmed.startsWith('#EXT-X-STREAM-INF')) continue;
      for (var j = i + 1; j < lines.length; j++) {
        final next = lines[j].trim();
        if (next.isEmpty) continue;
        if (next.startsWith('#')) break; // 遇到下一个标签，说明本变体行缺失
        return next;
      }
      break;
    }
    return null;
  }

  /// 下载并重写一个 M3U8（去广告 → 解析相对路径 → 重写分片走本地代理）。
  ///
  /// 与 `_proxySegment` 的子 M3U8 分支保持同一套处理，确保展开出的 media playlist
  /// 与「libmdk 自己请求子 m3u8」时拿到的内容完全一致（含 `hseg` 重编号与 AES 解密参数）。
  Future<String?> _fetchAndRewriteM3u8(String rawUrl) async {
    // 变体 URL 可能是本地代理形式（/segment?url=），需解出真实 CDN 地址：
    // 一来下载要走 CDN，二来相对分片路径必须基于 CDN 地址解析。
    final targetUrl = _unwrapProxyUrl(rawUrl);
    final headers = _segmentRequestHeaders(targetUrl);
    // 播放列表必须取完整内容，不能带 Range（否则拿到 206 部分内容，时长计算错误）。
    headers.remove('Range');

    final client = _client ?? http.Client();
    // 超时必须**远小于**播放器的 open 超时（`openTimeout`，默认 15s）：本方法是
    // libmdk 打开 playlist 时的**同步等待**调用，展开耗时会被原样加到起播耗时里。
    // 实测（2026-09-26 日志）：源1（944 分片）展开仅 1s，但源4（1401 分片）展开
    // 耗了 **10s**，叠加其后 initialize 共约 16s → 越过 15s 上限 → `播放失败`，
    // 该源连画面都没出。取 3s：正常源一次 CDN 往返 < 1s（源1 实测 718ms），余量 3 倍；
    // 超时即回退原 master，行为不劣于引入展开之前。
    final sw = Stopwatch()..start();
    final resp = await client
        .get(Uri.parse(targetUrl), headers: headers)
        .timeout(const Duration(seconds: 3));
    final dlMs = sw.elapsedMilliseconds;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      _log('master 展开：拉取变体 $targetUrl 返回 ${resp.statusCode}');
      return null;
    }

    final decoded = utf8.decode(resp.bodyBytes, allowMalformed: true);
    final filtered = _filterEnabled
        ? _filterM3u8(
            targetUrl,
            decoded,
            cleanDiscontinuities: _discontinuityCleanup,
          )
        : decoded;
    final resolved = resolveRelativeUrls(filtered, targetUrl);
    final rewritten = rewriteToLocalProxy(
      resolved,
      baseUrl!,
      renumberSegments: _fvpRenumber,
    );
    // 分开记录「下载」与「处理」耗时：慢在网络还是慢在本地重写（分片数越多
    // 重写越久），下次据此判断该收紧超时还是该优化重写。
    _log('master 展开：下载 ${dlMs}ms + 处理 '
        '${sw.elapsedMilliseconds - dlMs}ms，${resp.bodyBytes.length} 字节');
    return rewritten;
  }

  /// 把本地代理形式的 URL（`$baseUrl/segment?url=...`）还原为真实 CDN URL。
  String _unwrapProxyUrl(String url) {
    final base = baseUrl;
    if (base == null) return url;
    if (!url.startsWith('$base/segment')) return url;
    try {
      final inner = Uri.parse(url).queryParameters['url'];
      if (inner != null && inner.isNotEmpty) return inner;
    } catch (_) {
      // 解析失败则按原样使用
    }
    return url;
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

    // fvp 专属：若分片被标记为 AES-128 加密（由 rewriteToLocalProxy 注入
    // &decrypt=aes128&key=&iv=），代理侧取 key 并逐段做 AES-128-CBC 解密，
    // 把明文吐给 fvp，绕过 libmdk 对“经本地代理的 AES-128 HLS”解密卡死的缺陷。
    final decryptParam = request.uri.queryParameters['decrypt'];
    if (decryptParam == 'aes128') {
      final keyParam = request.uri.queryParameters['key'];
      final ivParam = request.uri.queryParameters['iv'];
      if (keyParam == null || ivParam == null) {
        request.response
          ..statusCode = HttpStatus.badRequest
          ..write('Missing decrypt params')
          ..close();
        return;
      }
      await _proxyDecryptedSegment(
        request,
        isHead: isHead,
        targetUrl: targetUrl,
        keyUri: Uri.decodeComponent(keyParam),
        iv: _hexToBytes(ivParam),
      );
      return;
    }

    // 透传调用方设置的所有请求头（含鉴权 token / Cookie / 自定义头），
    // 确保分片请求与播放列表请求使用一致的头部。否则部分 CDN 在分片阶段
    // 因缺头被拒，表现为“出一下声音后无画面、卡死”（首段常已被放行/缓存）。
    final headers = _segmentRequestHeaders(targetUrl);

        // 透传 Range，但 M3U8 播放列表必须获取完整内容才能正确计算总时长，
        // 否则播放器收到 206 部分响应会导致进度条/时长显示异常。
        // ⚠️ 旧逻辑用 contains('/hls/') 判定 playlist，会把 /hls/ 下的 .ts 分片
        // 误判为 playlist 而丢弃 Range → fvp 无法在分片内 seek/续拉，弱机每次
        // 重缓冲都要整段重下，是 tvLegacy 等弱机「幻灯片式卡顿」的诱因之一。
        // 改为按扩展名精确判定：playlist(.m3u8/.m3u 或无扩展名)才跳过 Range，
        // 媒体分片(.ts/.mp4/.m4s/...)一律透传 Range。
        final isPlaylistUrl = _isPlaylistUrl(targetUrl);
        final range = request.headers.value('range');
        if (range != null && range.isNotEmpty && !isPlaylistUrl) {
          headers['Range'] = range;
        }

      try {
        final requestMethod = isHead ? 'HEAD' : 'GET';
        final requestUri = Uri.parse(targetUrl);
        final client = _client ?? http.Client();
        _log('proxySegment request: $targetUrl');
        final streamed = await client
            .send(http.Request(requestMethod, requestUri)..headers.addAll(headers))
            .timeout(const Duration(seconds: 30));

        final out = request.response;
        out.statusCode = streamed.statusCode;

        final contentType = streamed.headers['content-type'];
        if (contentType != null && contentType.isNotEmpty) {
          out.headers.contentType = _parseContentType(contentType);
        }
        final acceptRanges = streamed.headers['accept-ranges'];
        if (acceptRanges != null && acceptRanges.isNotEmpty) {
          out.headers.add('Accept-Ranges', acceptRanges);
        }
        final contentRange = streamed.headers['content-range'];
        if (contentRange != null && contentRange.isNotEmpty) {
          out.headers.add('Content-Range', contentRange);
        }
        out.headers.add('Access-Control-Allow-Origin', '*');
        out.headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');

        if (isHead) {
          await out.close();
          return;
        }

        // 仅按 content-type 判定 M3U8（可靠且无需缓冲整段）：是则缓冲后重写分片地址，
        // 否则（裸流/媒体分片）流式转发，避免整段缓冲导致内存暴涨或卡死。
        final isM3u8 = _isM3u8ContentType(contentType);
        if (streamed.statusCode >= 200 &&
            streamed.statusCode < 300 &&
            isM3u8) {
          final bytes = await streamed.stream.toBytes();
          final decoded = utf8.decode(bytes, allowMalformed: true);
          _log(
            'proxySegment sub-m3u8 raw: $targetUrl\n${_summarizeContent(decoded)}',
          );
          final filtered = _filterEnabled
              ? _filterM3u8(
                  targetUrl,
                  decoded,
                  cleanDiscontinuities: _discontinuityCleanup,
                )
              : decoded;
          final resolved = resolveRelativeUrls(filtered, targetUrl);
          final rewritten = rewriteToLocalProxy(
            resolved,
            baseUrl!,
            renumberSegments: _fvpRenumber,
          );
          out.headers.contentType =
              ContentType('application', 'vnd.apple.mpegurl');
          final encoded = utf8.encode(rewritten);
          out.headers.set('Content-Length', encoded.length.toString());
          out.add(encoded);
          _log(
            'proxySegment sub-m3u8 rewritten: $targetUrl\n${_summarizeContent(rewritten)}',
          );
        } else if (streamed.statusCode >= 200 && streamed.statusCode < 300) {
          // 非 M3U8：流式转发（裸流/媒体分片），不整段缓冲。
          final len = streamed.contentLength;
          if (len != null) out.headers.set('Content-Length', len.toString());
          _log('proxySegment stream: $targetUrl status=${streamed.statusCode}');
          await out.addStream(streamed.stream);
          await out.close();
          return;
        } else {
          // 非 2xx：仍尽量转发错误体摘要，便于排查 404/403。
          final preview = await streamed.stream
              .transform(utf8.decoder)
              .take(200)
              .join();
          _log(
            'proxySegment error response: $targetUrl status=${streamed.statusCode} '
            'bodyPreview=$preview',
          );
          out.headers.set('Content-Length', preview.length.toString());
          out.add(utf8.encode(preview));
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

  // ===== fvp 专属：代理侧 AES-128-CBC 解密 =====

  /// 构造分片请求头（与播放列表请求一致，含 Referer/Origin/User-Agent 等）。
  Map<String, String> _segmentRequestHeaders(String targetUrl) {
    final targetUri = Uri.parse(targetUrl);
    final headers = Map<String, String>.from(_baseHeaders);
    headers['User-Agent'] = _baseHeaders['User-Agent'] ??
        'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';
    headers['Accept'] = '*/*';
    headers['Accept-Language'] = 'zh-CN,zh;q=0.9,en;q=0.8';
    headers['Connection'] = 'keep-alive';
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
    return headers;
  }

  /// 取/缓存 AES-128 key（按 key URI 缓存，避免每段重复拉取）。
  Future<Uint8List> _getAesKey(http.Client client, String keyUri) async {
    final cached = _aesKeyCache[keyUri];
    if (cached != null) return cached;
    final uri = Uri.parse(keyUri);
    final req = http.Request('GET', uri);
    req.headers.addAll(_segmentRequestHeaders(keyUri));
    final resp = await client.send(req).timeout(const Duration(seconds: 30));
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw Exception('AES key HTTP ${resp.statusCode}');
    }
    final bytes = await resp.stream.toBytes();
    _aesKeyCache[keyUri] = bytes;
    return bytes;
  }

  /// fvp 专属：代理侧对单个 AES-128 加密分片做 CBC 解密后吐明文。
  ///
  /// 逻辑与 plan/aes_verify.py 离线验证逐字节对齐（地面真值 cryptography）：
  /// - 支持 fvp 的非块对齐 Range：向前取一块密文作 IV 源，解密后按请求区间切片；
  /// - 仅当 Range 覆盖段尾（最后一块）时做 PKCS7 去填充，恢复原始明文。
  Future<void> _proxyDecryptedSegment(
    HttpRequest request, {
    required bool isHead,
    required String targetUrl,
    required String keyUri,
    required Uint8List iv,
  }) async {
    final out = request.response;
    final client = _client ?? http.Client();

    late final Uint8List key;
    try {
      key = await _getAesKey(client, keyUri);
    } catch (e) {
      _log('AES key fetch failed: $keyUri -> $e');
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Key fetch failed')
        ..close();
      return;
    }
    if (key.length != 16) {
      _log('AES key length invalid: ${key.length} (expect 16)');
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Key length invalid')
        ..close();
      return;
    }

    // 解析 fvp 的 Range（bytes=START-END / START- / -SUFFIX）。
    final range = request.headers.value('range');
    final bool hasRange;
    int start;
    int end;
    if (range != null && range.startsWith('bytes=')) {
      hasRange = true;
      final parts = range.substring(6).split('-');
      if (parts.length == 2 && parts[1].isNotEmpty) {
        start = int.parse(parts[0]);
        end = int.parse(parts[1]);
      } else if (parts.length == 2) {
        start = int.parse(parts[0]); // bytes=START- ：末尾占位
        end = -1;
      } else {
        start = -int.parse(parts[0]); // bytes=-SUFFIX ：末尾 N 字节
        end = -1;
      }
    } else {
      hasRange = false;
      start = 0;
      end = -1;
    }

    final streamed = await client
        .send(http.Request(isHead ? 'HEAD' : 'GET', Uri.parse(targetUrl))
          ..headers.addAll(_segmentRequestHeaders(targetUrl)))
        .timeout(const Duration(seconds: 30));
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      out
        ..statusCode = HttpStatus.badGateway
        ..write('Segment fetch failed ${streamed.statusCode}')
        ..close();
      return;
    }

    if (isHead) {
      // HEAD 仅回头部，不解密；长度取 Content-Length（可能缺失）。
      final total = streamed.contentLength ?? 0;
      out
        ..statusCode = hasRange ? HttpStatus.partialContent : HttpStatus.ok
        ..headers.contentType = ContentType('video', 'mp2t')
        ..headers.add('Access-Control-Allow-Origin', '*')
        ..headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
      if (hasRange && total > 0) {
        final s = start < 0 ? (total + start).clamp(0, total - 1) : start;
        final e = (end < 0 || end > total - 1) ? total - 1 : end;
        out.headers.set('Content-Range', 'bytes $s-$e/$total');
        out.headers.add('Accept-Ranges', 'bytes');
        out.headers.set('Content-Length', (e - s + 1).toString());
      } else if (total > 0) {
        out.headers.set('Content-Length', total.toString());
      }
      await out.close();
      return;
    }

    // GET：读完整密文（块对齐，长度即明文长度），本地切片/解密。
    final cipher = await streamed.stream.toBytes();
    final total = cipher.length;
    if (start < 0) start = (total + start).clamp(0, total - 1);
    if (end < 0 || end > total - 1) end = total - 1;

    const bs = 16;
    // 块对齐：fetchStart 回退一块作为 IV 源；fetchEnd 推进到块边界保证最后一块完整。
    var fetchStart = (start ~/ bs) * bs;
    if (fetchStart > 0) fetchStart -= bs;
    if (fetchStart < 0) fetchStart = 0;
    var fetchEnd = ((end ~/ bs) + 1) * bs - 1;
    if (fetchEnd > total - 1) fetchEnd = total - 1;

    final cipherBlock = cipher.sublist(fetchStart, fetchEnd + 1);
    final firstProcessedOffset = (fetchStart == 0) ? 0 : bs;
    final ivFirst = (fetchStart == 0) ? iv : cipherBlock.sublist(0, bs);

    final cbc = CBCBlockCipher(AESFastEngine());
    cbc.init(false, ParametersWithIV(KeyParameter(key), ivFirst));
    final plain = Uint8List(cipherBlock.length - firstProcessedOffset);
    var outOff = 0;
    for (var off = firstProcessedOffset;
        off + bs <= cipherBlock.length;
        off += bs) {
      cbc.processBlock(cipherBlock, off, plain, outOff);
      outOff += bs;
    }

    // 请求区间映射到 plain 下标。
    var pStart = start - fetchStart - firstProcessedOffset;
    var pEnd = end - fetchStart - firstProcessedOffset;
    if (pStart < 0) pStart = 0;
    if (pEnd >= plain.length) pEnd = plain.length - 1;

    // 仅当覆盖段尾（最后一块）时做 PKCS7 去填充。记下填充长度，后面要把
    // Content-Range 的总长换算成**明文**总长（见下方注释）。
    int? removedPad;
    if ((!hasRange || end >= total - 1) && plain.isNotEmpty) {
      final pad = plain[plain.length - 1];
      if (pad >= 1 && pad <= bs) {
        final unpaddedLen = plain.length - pad;
        if (pEnd >= unpaddedLen) pEnd = unpaddedLen - 1;
        removedPad = pad;
      }
    }

    final body = plain.sublist(pStart, pEnd + 1);

    // ⚠️ 这两个头必须用**同一套坐标**，否则 ffmpeg 会在读到分片末尾时报
    // `Stream ends prematurely at X, should be Y`（X=实际读到字节、Y=声明的
    // filesize）并返回 EOF；实测该源每个加密分片都触发一次（2026-09-26 日志
    // 93 次，而走普通透传的未加密源为 0 次），且 ffmpeg 可能因此反复重开同一分片。
    //
    // 此前 Content-Range 写的是 `bytes $start-$end/$total`（**密文**坐标），而
    // Content-Length 写的是 body.length（**去填充后的明文**长度）：两者相差
    // PKCS7 填充字节数（实测 8 字节，例：声明 497456 / 实收 497448），且
    // ffmpeg 会优先采用 Content-Range 的 total 作为 filesize，于是必然报错。
    //
    // AES-CBC 不改变字节位置、PKCS7 填充只在末尾，所以区间起止用绝对偏移即可；
    // 只有**总长**需要减掉填充。
    final plainTotal = removedPad != null ? total - removedPad : total;
    final bodyStartAbs = fetchStart + firstProcessedOffset + pStart;
    final bodyEndAbs = fetchStart + firstProcessedOffset + pEnd;

    out.statusCode = hasRange ? HttpStatus.partialContent : HttpStatus.ok;
    out.headers.contentType = ContentType('video', 'mp2t');
    out.headers.add('Access-Control-Allow-Origin', '*');
    out.headers.add('Cache-Control', 'no-cache, no-store, must-revalidate');
    if (hasRange) {
      out.headers.set(
          'Content-Range', 'bytes $bodyStartAbs-$bodyEndAbs/$plainTotal');
      out.headers.add('Accept-Ranges', 'bytes');
    }
    out.headers.set('Content-Length', body.length.toString());
    out.add(body);
    await out.close();
    _log('proxyDecryptedSegment: $targetUrl -> '
        'decrypted bytes=${body.length} range=$hasRange '
        'plainTotal=$plainTotal pad=${removedPad ?? 0}');
  }

  static bool _isM3u8ContentType(String? contentType) {
    if (contentType == null) return false;
    final ct = contentType.toLowerCase();
    return ct.contains('mpegurl') ||
        ct.contains('m3u8') ||
        ct.contains('application/vnd.apple.mpegurl') ||
        ct.contains('audio/x-mpegurl');
  }

  /// 判定目标地址是否为 HLS 播放列表（而非媒体分片）。
  ///
  /// 仅播放列表需要获取完整内容以正确计算总时长，故代理跳过 Range；
  /// 媒体分片（.ts/.m4s/.mp4/...）一律透传 Range，以支持分片内 seek/续拉，
  /// 避免弱机每次重缓冲都整段重下（tvLegacy「幻灯片式卡顿」的诱因之一）。
  /// ⚠️ 不可用 contains('/hls/') 粗判：/hls/ 下的 .ts 分片会被误判为 playlist 而
  /// 丢弃 Range，导致 fvp/ExoPlayer 无法分片内 seek/续拉。
  static bool _isPlaylistUrl(String url) {
    final lower = url.toLowerCase();
    // 明确的 playlist 扩展名。
    if (lower.contains('.m3u8') || lower.contains('.m3u')) return true;
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? '';
    final lastSegment =
        path.split('/').lastWhere((s) => s.isNotEmpty, orElse: () => '');
    // 无扩展名（如 master playlist 或 /hls/xxx 形式）→ 当作播放列表。
    if (!lastSegment.contains('.')) return true;
    // 已知媒体分片扩展名 → 不是播放列表，透传 Range。
    const mediaExts = [
      '.ts',
      '.m4s',
      '.mp4',
      '.m4a',
      '.aac',
      '.vtt',
      '.webm',
      '.mkv',
      '.flv',
      '.avi',
      '.mov',
      '.key',
    ];
    for (final ext in mediaExts) {
      if (lastSegment.endsWith(ext)) return false;
    }
    // 其他带扩展名的（未知类型），保守当作播放列表（跳过 Range）。
    return true;
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

  /// 十六进制字符串 → 字节（自动去掉 0x 前缀）。
  static Uint8List _hexToBytes(String hex) {
    final s = hex.startsWith('0x') || hex.startsWith('0X')
        ? hex.substring(2)
        : hex;
    final n = s.length ~/ 2;
    final b = Uint8List(n);
    for (var i = 0; i < n; i++) {
      b[i] = int.parse(s.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return b;
  }

  /// 字节 → 十六进制字符串（小写）。
  static String _bytesToHex(Uint8List b) {
    final sb = StringBuffer();
    for (final byte in b) {
      sb.write(byte.toRadixString(16).padLeft(2, '0'));
    }
    return sb.toString();
  }

  /// HLS 默认 IV（无 IV 属性时）：IV[0:8)=0，IV[8:16)=大端媒体序列号。
  /// 与 ExoPlayer / libmdk 的默认 IV 推导一致。
  static Uint8List _ivFromSeq(int seq) {
    final b = Uint8List(16);
    // 仅取低 8 字节放入序列号；超高序列号做掩码避免溢出。
    final s = seq & 0xFFFFFFFFFFFFFFFF;
    for (var i = 0; i < 8; i++) {
      b[15 - i] = (s >> (8 * i)) & 0xFF;
    }
    return b;
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
  ///
  /// [renumberSegments] 为 true 时（仅 fvp 后端）额外做两件事：
  /// 1. 丢弃所有 `#EXT-X-DISCONTINUITY` 标记——结构性断点会让 libmdk 重置时间轴，
  ///    且跨断点复用同名分片正是 fvp 卡死的根因；VOD/Live 均按连续时间轴播放更稳。
  /// 2. 给每个分段代理 URL 注入全局唯一序号 `&hseg=N`，使 libmdk 不会因
  ///    「跨 discontinuity 复用 plist0.ts」而命中段缓存、停止续预取。
  static String rewriteToLocalProxy(
    String content,
    String proxyBaseUrl, {
    bool renumberSegments = false,
  }) {
    final lines = content.split('\n');
    final result = <String>[];
    var segIndex = 0;

    final bool isFvp = renumberSegments;
    // fvp 专属：AES-128 解密上下文。剥离 EXT-X-KEY 后把 key URI + IV 注入每个分片
    // 代理 URL，由 _proxySegment 取 key 逐段解密，绕开 libmdk 卡死。
    String? activeAesKeyUri;
    Uint8List? activeAesIv;
    int mediaSequence = 0;
    int segEmitIndex = 0;

    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final trimmed = raw.trim();

      // fvp 专属：丢弃结构性 #EXT-X-DISCONTINUITY（避免 libmdk 段缓存撞名卡死）。
      if (renumberSegments && trimmed == '#EXT-X-DISCONTINUITY') {
        continue;
      }

      // 解析媒体序列号（无 IV 属性时的默认 IV = 序列号低 8 字节大端）。
      if (trimmed.startsWith('#EXT-X-MEDIA-SEQUENCE:')) {
        final m = RegExp(r'#EXT-X-MEDIA-SEQUENCE:(\d+)').firstMatch(trimmed);
        if (m != null) mediaSequence = int.parse(m.group(1)!);
      }

      // fvp 专属：AES-128 加密 HLS 经本地代理会被 libmdk 解密卡死。
      // 这里剥离 EXT-X-KEY 标签（fvp 不再需要拉 key），并把 key URI + IV 记录到
      // 上下文，供后续每个分片代理 URL 注入 &decrypt=aes128&key=&iv=。
      // 仅 fvp 后端（renumberSegments==true）开启；ExoPlayer 自带解密，保持原样。
      if (trimmed.startsWith('#EXT-X-KEY')) {
        final methodMatch = RegExp(r'METHOD=([A-Z0-9-]+)').firstMatch(trimmed);
        final method = methodMatch?.group(1);
        if (isFvp && method == 'AES-128') {
          activeAesKeyUri = RegExp(r'URI="([^"]+)"').firstMatch(trimmed)?.group(1);
          final ivMatch = RegExp(r'IV=0x([0-9A-Fa-f]+)').firstMatch(trimmed);
          activeAesIv = ivMatch != null ? _hexToBytes(ivMatch.group(1)!) : null;
          continue; // 剥离 EXT-X-KEY
        } else if (isFvp && method == 'NONE') {
          activeAesKeyUri = null;
          activeAesIv = null;
          continue; // 无加密，剥离
        } else {
          // 非 fvp，或 SAMPLE-AES 等不支持方法：保留标签并改写 URI（原行为）。
          result.add(_rewriteUriAttributes(proxyBaseUrl, raw));
          continue;
        }
      }

      // 媒体行
      if (trimmed.isNotEmpty &&
          !trimmed.startsWith('#') &&
          !trimmed.startsWith('data:')) {
        final proxySeg = _proxyUrl(proxyBaseUrl, trimmed);
        // fvp 专属：注入全局唯一序号，规避同名分片段缓存冲突。
        String finalSeg =
            renumberSegments ? '$proxySeg&hseg=$segIndex' : proxySeg;
        // fvp 专属：当前分片属于 AES-128 加密区间 → 注入解密参数，
        // 由代理侧取 key 后逐段解密（绕过 libmdk 卡死）。
        if (isFvp && activeAesKeyUri != null) {
          final ivHex = activeAesIv != null
              ? _bytesToHex(activeAesIv)
              : _bytesToHex(_ivFromSeq(mediaSequence + segEmitIndex));
          finalSeg +=
              '&decrypt=aes128&key=${Uri.encodeComponent(activeAesKeyUri)}&iv=$ivHex';
          segEmitIndex++;
        }
        result.add(finalSeg);
        segIndex++;
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
            // 变体 URL 不重编号（保持相对稳定），仅走代理。
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
  static String _filterM3u8(
    String baseUrl,
    String content, {
    bool cleanDiscontinuities = false,
  }) {
    try {
      final filter = M3u8AdFilter();
      final filtered = filter.purify(
        baseUrl,
        content,
        cleanDiscontinuities: cleanDiscontinuities,
      );
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
