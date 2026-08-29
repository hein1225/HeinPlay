import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';
import '../models/api_response.dart';
import '../models/favorite.dart';
import '../models/live_channel.dart';
import '../models/play_record.dart';
import '../models/search_result.dart';
import '../models/skip_segment.dart';
import '../models/video_detail.dart';
import 'app_info_service.dart';
import 'cache_service.dart';
import 'connectivity_service.dart';
import 'm3u8_utils.dart';
import 'user_data_service.dart';
import '../utils/windows_logger.dart';

class LunaTVConfig {
  static const Duration searchTimeout = Duration(seconds: 30);
  static const Duration detailTimeout = Duration(seconds: 20);
  static const Duration liveTimeout = Duration(seconds: 15);
  static const Duration defaultTimeout = Duration(seconds: 15);
  static const int maxRetryCount = 2;
  static const Duration searchCacheTtl = Duration(minutes: 30);
  static const Duration detailCacheTtl = Duration(minutes: 30);
  static const Duration liveCacheTtl = Duration(minutes: 5);
  static const Duration playRecordsCacheTtl = Duration(minutes: 30);
  static const Duration favoritesCacheTtl = Duration(minutes: 30);
}

/// 包装 [http.Client]，忽略 [close] 调用，用于共享客户端场景。
///
/// 请求方按原习惯调用 `client.close()` 不会真正关闭底层连接，
/// 底层连接由 [LunaTVService] 统一管理并在配置变化时重建。
class _NonClosingClient extends http.BaseClient {
  final http.Client _inner;

  _NonClosingClient(this._inner);

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    // 共享客户端的生命周期由 LunaTVService 管理，此处不关闭底层连接。
  }
}

class LunaTVService {
  static final CacheService _cacheService = CacheService();
  static bool _cacheInitialized = false;

  /// 共享 HTTP 客户端配置标识，配置变化时需要重建客户端。
  static ({bool bypassCert, String primaryHost, InternetServerDnsPreference preference})?
      _sharedClientConfig;

  /// 共享的真实 HttpClient（IOClient 内部持有），用于在配置变化时真正关闭。
  static http.Client? _sharedInnerClient;

  /// 对外返回的共享客户端包装，忽略 close() 调用，避免请求方关闭共享连接。
  static http.Client? _sharedClient;

  /// 防止多个请求并发创建共享客户端的锁。
  static Future<http.Client>? _creatingClient;

  static Future<void> _initCache() async {
    if (!_cacheInitialized) {
      await _cacheService.init();
      _cacheInitialized = true;
    }
  }

  /// 强制重置共享客户端。
  ///
  /// 当服务器地址、DNS 偏好等配置发生变化时调用，使下一次请求使用新配置建立连接。
  static void resetSharedClient() {
    _log('LunaTVService', '重置共享 HTTP 客户端');
    _sharedInnerClient?.close();
    _sharedInnerClient = null;
    _sharedClient = null;
    _sharedClientConfig = null;
  }

  /// 创建 LunaTV API 请求专用 HTTP 客户端。
  ///
  /// Windows 桌面版 Dart 默认证书校验对自签名/非标准证书链容易触发
  /// HandshakeException，而 Android 同网络可正常访问。此处对 Windows
  /// 放宽证书校验，并禁用系统代理、保持长连接，确保用户配置的服务器地址可用。
  static void _log(String tag, String message) {
    if (Platform.isWindows) {
      WindowsLogger.log(tag, message);
    } else {
      debugPrint('[$tag] $message');
    }
  }

  /// 判断异常是否由「网络不可达 / 无路由」导致，用于触发 IPv6->IPv4 回退。
  static bool isNetworkUnreachable(Object? error) {
    if (error is SocketException) {
      return error.osError?.errorCode == 101 ||
          error.message.toLowerCase().contains('network is unreachable') ||
          error.message.toLowerCase().contains('no route to host');
    }
    final errorString = error.toString().toLowerCase();
    return errorString.contains('network is unreachable') ||
        errorString.contains('no route to host') ||
        errorString.contains('errno = 101');
  }

  /// 创建 LunaTV API 请求专用 HTTP 客户端。
  ///
  /// 默认返回共享客户端，多个请求可复用同一底层连接，减少重复解析与连接开销。
  /// [forceAutoDns] 为 true 时返回独立客户端，用于 IPv6 失败后的系统默认 DNS 兜底，
  /// 调用方需要自行关闭。
  static Future<http.Client> createApiClient({bool forceAutoDns = false}) async {
    final bypassCert = Platform.isWindows;

    // 兜底/独立客户端不走共享池，避免污染当前配置的长连接。
    if (forceAutoDns) {
      final httpClient = HttpClient();
      if (bypassCert) {
        httpClient.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        httpClient.findProxy = (uri) => 'DIRECT';
      }
      httpClient.idleTimeout = const Duration(seconds: 30);
      await _applyInternetServerDnsPreference(
        httpClient,
        forceAutoDns: true,
        bypassCert: bypassCert,
      );
      return IOClient(httpClient);
    }

    final preference = await UserDataService.getInternetServerDnsPreference();
    String primaryHost = '';
    try {
      final primaryUrl = await UserDataService.getServerUrl();
      if (primaryUrl != null && primaryUrl.trim().isNotEmpty) {
        primaryHost = Uri.tryParse(primaryUrl.trim())?.host ?? '';
      }
    } catch (_) {}

    final config = (
      bypassCert: bypassCert,
      primaryHost: primaryHost,
      preference: preference,
    );

    if (_sharedClient != null && _sharedClientConfig == config) {
      _log('LunaTVService', '复用共享 HTTP 客户端');
      return _sharedClient!;
    }

    // 串行化共享客户端创建，避免启动时多个并发请求各自创建独立客户端。
    while (_creatingClient != null) {
      await _creatingClient;
      if (_sharedClient != null && _sharedClientConfig == config) {
        _log('LunaTVService', '复用共享 HTTP 客户端');
        return _sharedClient!;
      }
    }

    Future<http.Client> doCreate() async {
      // 配置变化：关闭旧共享客户端并重建。
      _log('LunaTVService', '创建新的共享 HTTP 客户端');
      _sharedInnerClient?.close();
      _sharedInnerClient = null;
      _sharedClient = null;
      _sharedClientConfig = null;

      final httpClient = HttpClient();
      if (bypassCert) {
        httpClient.badCertificateCallback =
            (X509Certificate cert, String host, int port) => true;
        httpClient.findProxy = (uri) => 'DIRECT';
      }
      httpClient.idleTimeout = const Duration(seconds: 30);
      await _applyInternetServerDnsPreference(
        httpClient,
        bypassCert: bypassCert,
      );
      final inner = IOClient(httpClient);
      _sharedInnerClient = inner;
      _sharedClient = _NonClosingClient(inner);
      _sharedClientConfig = config;
      return _sharedClient!;
    }

    _creatingClient = doCreate();
    try {
      return await _creatingClient!;
    } finally {
      _creatingClient = null;
    }
  }

  /// 根据用户在服务器管理中设置的「互联网服务器地址 DNS 偏好」，
  /// 对互联网服务器域名强制解析为 IPv4 或 IPv6。
  /// 局域网/备用服务器以及非 LunaTV 域名保持默认解析行为。
  static Future<void> _applyInternetServerDnsPreference(
    HttpClient client, {
    bool forceAutoDns = false,
    bool bypassCert = false,
  }) async {
    final savedPreference = await UserDataService.getInternetServerDnsPreference();
    final preference = forceAutoDns ? InternetServerDnsPreference.any : savedPreference;
    // 默认/自动模式下不覆盖连接工厂，让系统按 Happy Eyeballs 自动选择 IPv4/IPv6。
    if (preference == InternetServerDnsPreference.any) {
      if (forceAutoDns) {
        _log('LunaTVService', '强制使用系统自动 DNS 选择');
      }
      return;
    }

    String primaryHost = '';
    try {
      final primaryUrl = await UserDataService.getServerUrl();
      if (primaryUrl != null && primaryUrl.trim().isNotEmpty) {
        primaryHost = Uri.tryParse(primaryUrl.trim())?.host ?? '';
      }
    } catch (_) {
      // 读取主服务器地址失败时保持空字符串，后续按默认解析处理。
    }

    switch (preference) {
      case InternetServerDnsPreference.ipv6:
        _log(
          'LunaTVService',
          '已启用互联网服务器 IPv6 优先解析（无 IPv6 时自动回退 IPv4），主服务器域名: $primaryHost',
        );
      case InternetServerDnsPreference.ipv4:
        _log(
          'LunaTVService',
          '已启用互联网服务器 IPv4 优先解析（无 IPv4 时自动回退 IPv6），主服务器域名: $primaryHost',
        );
      case InternetServerDnsPreference.any:
        _log(
          'LunaTVService',
          '互联网服务器使用系统自动 DNS（Happy Eyeballs），主服务器域名: $primaryHost',
        );
    }

    client.connectionFactory = (
      Uri url,
      String? proxyHost,
      int? proxyPort,
    ) async {
      _log(
        'LunaTVService',
        'connectionFactory 调用: ${url.host}:${url.port}, '
        'proxyHost=$proxyHost, primaryHost=$primaryHost',
      );

      // 优先处理代理连接：解析代理主机并建立连接。
      if (proxyHost != null) {
        final proxyAddresses = await InternetAddress.lookup(
          proxyHost,
          type: InternetAddressType.any,
        );
        if (proxyAddresses.isEmpty) {
          throw SocketException('无法解析代理主机 $proxyHost');
        }
        return Socket.startConnect(
          proxyAddresses.first,
          proxyPort ?? 80,
        );
      }

      /// 根据 URL 协议选择普通 Socket 或 SecureSocket 发起连接。
      ///
      /// HTTPS 请求必须在 connectionFactory 内直接完成 TLS 握手，否则 HttpClient
      /// 会把返回的 Socket 当成明文连接，导致「plain HTTP request was sent to
      /// HTTPS port」错误。
      ///
      /// 传入 [host] 为 InternetAddress 时，其 [InternetAddress.host] 会用于 TLS
      /// SNI 与证书校验；传入 String 时则同时用于解析和 SNI。
      Future<ConnectionTask<Socket>> _startConnect(Object host) async {
        if (url.scheme == 'https') {
          return SecureSocket.startConnect(
            host,
            url.port,
            onBadCertificate: bypassCert ? (_) => true : null,
          );
        }
        return Socket.startConnect(host, url.port);
      }

      // 仅对互联网服务器（主服务器地址）应用 DNS 偏好；
      // 局域网/备用服务器等其他域名保持默认解析行为。
      if (primaryHost.isEmpty || url.host != primaryHost) {
        _log('LunaTVService', '非主服务器域名，使用系统默认解析: ${url.host}');
        return _startConnect(url.host);
      }

      Future<ConnectionTask<Socket>> tryConnect(
        InternetAddress address,
        InternetAddressType type,
      ) async {
        _log(
          'LunaTVService',
          '尝试 ${type.name} 连接: ${url.host} -> ${address.address}:${url.port}',
        );
        final task = await _startConnect(address);
        try {
          // 等待真实连接/TLS 握手建立，才能把「网络不可达」等错误暴露出来并回退。
          // 单次连接尝试限制 3 秒，避免在 HTTP 15 秒超时前没有回退机会。
          await task.socket.timeout(const Duration(seconds: 3));
          _log(
            'LunaTVService',
            '${type.name} 连接成功: ${url.host} -> ${address.address}:${url.port}',
          );
          return task;
        } catch (e) {
          _log(
            'LunaTVService',
            '${type.name} 连接失败: ${url.host} -> ${address.address}:${url.port}, $e',
          );
          task.cancel();
          rethrow;
        }
      }

      Future<List<InternetAddress>> lookupOrEmpty(
        String host,
        InternetAddressType type,
      ) async {
        try {
          return await InternetAddress.lookup(host, type: type);
        } on SocketException {
          return const <InternetAddress>[];
        }
      }

      // 根据用户偏好决定优先解析的地址族；any 模式已在上文直接返回。
      final lookupType = preference == InternetServerDnsPreference.ipv6
          ? InternetAddressType.IPv6
          : InternetAddressType.IPv4;
      var addresses = await lookupOrEmpty(url.host, lookupType);
      // 按偏好解析无结果时回退到另一种地址族。
      if (addresses.isEmpty && lookupType != InternetAddressType.any) {
        final fallbackType = lookupType == InternetAddressType.IPv6
            ? InternetAddressType.IPv4
            : InternetAddressType.IPv6;
        _log(
          'LunaTVService',
          '${lookupType.name} 解析无结果，回退到 ${fallbackType.name}: ${url.host}',
        );
        addresses = await lookupOrEmpty(url.host, fallbackType);
      }
      if (addresses.isEmpty) {
        throw SocketException('无法解析主机 ${url.host}');
      }
      final address = addresses.firstWhere(
        (a) => a.type == lookupType,
        orElse: () => addresses.first,
      );

      try {
        return await tryConnect(address, lookupType);
      } on SocketException catch (e) {
        // 当按偏好地址族连接时出现「网络不可达」，自动回退到另一种地址族再试一次。
        final isUnreachable = e.osError?.errorCode == 101 ||
            e.message.toLowerCase().contains('network is unreachable') ||
            e.message.toLowerCase().contains('no route to host');
        if (isUnreachable && lookupType != InternetAddressType.any) {
          final fallbackType = lookupType == InternetAddressType.IPv6
              ? InternetAddressType.IPv4
              : InternetAddressType.IPv6;
          _log(
            'LunaTVService',
            '${lookupType.name} 不可达，准备回退到 ${fallbackType.name}: ${url.host}',
          );
          final fallbackAddresses = await lookupOrEmpty(url.host, fallbackType);
          if (fallbackAddresses.isNotEmpty) {
            _log(
              'LunaTVService',
              '回退到 ${fallbackType.name}: ${url.host} -> ${fallbackAddresses.first.address}',
            );
            return await tryConnect(
              fallbackAddresses.first,
              fallbackType,
            );
          }
        }
        rethrow;
      } on TimeoutException catch (_) {
        // 连接尝试超时（如 IPv6 可达但无法完成握手），回退到另一种地址族再试。
        final fallbackType = lookupType == InternetAddressType.IPv6
            ? InternetAddressType.IPv4
            : InternetAddressType.IPv6;
        _log(
          'LunaTVService',
          '${lookupType.name} 连接超时，准备回退到 ${fallbackType.name}: ${url.host}',
        );
        final fallbackAddresses = await lookupOrEmpty(url.host, fallbackType);
        if (fallbackAddresses.isNotEmpty) {
          _log(
            'LunaTVService',
            '回退到 ${fallbackType.name}: ${url.host} -> ${fallbackAddresses.first.address}',
          );
          return await tryConnect(
            fallbackAddresses.first,
            fallbackType,
          );
        }
        rethrow;
      }
    };
  }

  /// Windows 专用兜底 HTTP 客户端。
  ///
  /// 当 [createApiClient] 仍然失败时（如系统代理/TLS 版本等边缘情况），
  /// 尝试使用未经自定义的默认客户端再请求一次，便于诊断问题。
  static Future<http.Client> _createFallbackClient() async {
    if (Platform.isWindows) {
      try {
        final httpClient = HttpClient()
          ..badCertificateCallback =
              (X509Certificate cert, String host, int port) => true;
        await _applyInternetServerDnsPreference(
          httpClient,
          bypassCert: true,
        );
        return IOClient(httpClient);
      } catch (_) {
        return http.Client();
      }
    }
    return http.Client();
  }

  static Future<String?> _baseUrl() async {
    final last = await UserDataService.getLastSelectedServerUrl();
    if (last != null && last.trim().isNotEmpty) {
      return last.trim().replaceAll(RegExp(r'/+$'), '');
    }
    final url = await UserDataService.getServerUrl();
    if (url != null && url.trim().isNotEmpty) {
      return url.trim().replaceAll(RegExp(r'/+$'), '');
    }
    final backup = await UserDataService.getBackupServerUrl();
    if (backup.trim().isEmpty) return null;
    return backup.trim().replaceAll(RegExp(r'/+$'), '');
  }

  static Future<Map<String, String>> _headers({String? host}) async {
    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'User-Agent': AppInfoService.userAgent,
      if (host != null && host.isNotEmpty) 'Host': host,
    };
    final cookies = await UserDataService.getCookies();
    if (cookies != null && cookies.isNotEmpty) {
      headers['Cookie'] = cookies;
    }
    return headers;
  }

  static Future<http.Response> _get(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
    http.Client? cancelClient,
  }) async {
    final base = await _baseUrl();
    if (base == null) {
      throw Exception('未配置 LunaTV 服务器地址');
    }

    final uri = Uri.parse(
      base + path,
    ).replace(queryParameters: queryParameters);
    final headers = await _headers(host: uri.host);
    final effectiveTimeout = timeout ?? LunaTVConfig.defaultTimeout;

    _log(
      'LunaTVService._get',
      'GET $uri, hasCookie=${headers.containsKey('Cookie')}, '
      'timeout=${effectiveTimeout.inSeconds}s',
    );
    Exception? lastError;
    for (var attempt = 0; attempt <= LunaTVConfig.maxRetryCount; attempt++) {
      final client = cancelClient ?? await createApiClient();
      final shouldCloseClient = cancelClient == null;
      try {
        final response = await client
            .get(uri, headers: headers)
            .timeout(effectiveTimeout);
        final bodyPreview = response.statusCode >= 400
            ? response.body.length > 200
                ? '${response.body.substring(0, 200)}...'
                : response.body
            : '';
        _log(
          'LunaTVService._get',
          '响应 ${response.statusCode}, '
          'bodyLength=${response.body.length}, uri=$uri'
          '${bodyPreview.isNotEmpty ? ', body=$bodyPreview' : ''}',
        );
        // 业务接口返回 200/401 都表示服务器可达，主动同步连接状态。
        if (response.statusCode == 200 || response.statusCode == 401) {
          unawaited(ConnectivityService.instance.reportSuccess(base));
        }
        return response;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        _log('LunaTVService._get', '第${attempt + 1}次请求失败: $e, uri=$uri');
        if (attempt == LunaTVConfig.maxRetryCount) break;
      } finally {
        if (shouldCloseClient) client.close();
      }
    }

    // 当用户开启「优先 IPv6」且因网络不可达导致失败时，再尝试一次系统自动 DNS 选择，
    // 作为 IPv6 无法连通时的最后兜底。
    if (isNetworkUnreachable(lastError)) {
      final dnsPreference = await UserDataService.getInternetServerDnsPreference();
      if (dnsPreference == InternetServerDnsPreference.ipv6) {
        _log(
          'LunaTVService._get',
          'IPv6 优先模式连接失败，尝试系统自动 DNS 选择: $uri',
        );
        final autoClient = cancelClient ?? await createApiClient(forceAutoDns: true);
        final shouldCloseAuto = cancelClient == null;
        try {
          final response = await autoClient
              .get(uri, headers: headers)
              .timeout(effectiveTimeout);
          _log(
            'LunaTVService._get',
            '自动 DNS 选择响应 ${response.statusCode}, '
            'bodyLength=${response.body.length}, uri=$uri',
          );
          if (response.statusCode == 200 || response.statusCode == 401) {
            unawaited(ConnectivityService.instance.reportSuccess(base));
          }
          return response;
        } catch (e) {
          _log('LunaTVService._get', '自动 DNS 选择请求失败: $e, uri=$uri');
          lastError = e is Exception ? e : Exception(e.toString());
        } finally {
          if (shouldCloseAuto) autoClient.close();
        }
      }
    }

    // Windows 兜底：使用更保守的客户端再试一次，便于区分是自定义配置还是网络本身问题
    if (Platform.isWindows) {
      final fallbackClient = cancelClient ?? await _createFallbackClient();
      final shouldCloseFallback = cancelClient == null;
      try {
        _log('LunaTVService._get', 'Windows 兜底请求 $uri');
        final response = await fallbackClient
            .get(uri, headers: headers)
            .timeout(effectiveTimeout);
        _log(
          'LunaTVService._get',
          '兜底响应 ${response.statusCode}, '
          'bodyLength=${response.body.length}, uri=$uri',
        );
        if (response.statusCode == 200 || response.statusCode == 401) {
          unawaited(ConnectivityService.instance.reportSuccess(base));
        }
        return response;
      } catch (e) {
        _log('LunaTVService._get', '兜底请求失败: $e, uri=$uri');
        lastError = e is Exception ? e : Exception(e.toString());
      } finally {
        if (shouldCloseFallback) fallbackClient.close();
      }
    }

    throw lastError ?? Exception('请求失败: $path');
  }

  /// 带重试和 IPv6 自动回退的请求执行器。
  ///
  /// 当用户开启「优先 IPv6」且请求因网络不可达失败时，会再尝试一次系统默认的
  /// Happy Eyeballs DNS 选择，作为 IPv6 无法连通时的兜底。
  static Future<http.Response> _executeWithRetryAndFallback(
    Future<http.Response> Function(http.Client client) requestBuilder, {
    required String base,
    required Duration effectiveTimeout,
    required String path,
    String? logUri,
  }) async {
    Exception? lastError;
    for (var attempt = 0; attempt <= LunaTVConfig.maxRetryCount; attempt++) {
      final client = await createApiClient();
      try {
        final response = await requestBuilder(client).timeout(effectiveTimeout);
        if (response.statusCode == 200 || response.statusCode == 401) {
          unawaited(ConnectivityService.instance.reportSuccess(base));
        }
        return response;
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        if (attempt == LunaTVConfig.maxRetryCount) break;
      } finally {
        client.close();
      }
    }

    if (isNetworkUnreachable(lastError)) {
      final dnsPreference =
          await UserDataService.getInternetServerDnsPreference();
      if (dnsPreference == InternetServerDnsPreference.ipv6) {
        final uri = logUri ?? '$base$path';
        _log(
          'LunaTVService',
          'IPv6 优先模式连接失败，尝试系统自动 DNS 选择: $uri',
        );
        final autoClient = await createApiClient(forceAutoDns: true);
        try {
          final response =
              await requestBuilder(autoClient).timeout(effectiveTimeout);
          _log(
            'LunaTVService',
            '自动 DNS 选择响应 ${response.statusCode}, '
            'bodyLength=${response.body.length}, uri=$uri',
          );
          if (response.statusCode == 200 || response.statusCode == 401) {
            unawaited(ConnectivityService.instance.reportSuccess(base));
          }
          return response;
        } catch (e) {
          _log('LunaTVService', '自动 DNS 选择请求失败: $e, uri=$uri');
          lastError = e is Exception ? e : Exception(e.toString());
        } finally {
          autoClient.close();
        }
      }
    }

    throw lastError ?? Exception('请求失败: $path');
  }

  static Future<http.Response> _post(
    String path, {
    required String body,
    Duration? timeout,
  }) async {
    final base = await _baseUrl();
    if (base == null) {
      throw Exception('未配置 LunaTV 服务器地址');
    }

    final uri = Uri.parse(base + path);
    final headers = await _headers(host: uri.host);
    headers['Content-Type'] = 'application/json';
    final effectiveTimeout = timeout ?? LunaTVConfig.defaultTimeout;

    return _executeWithRetryAndFallback(
      (client) => client.post(uri, headers: headers, body: body),
      base: base,
      effectiveTimeout: effectiveTimeout,
      path: path,
      logUri: uri.toString(),
    );
  }

  static Future<http.Response> _delete(
    String path, {
    Map<String, String>? queryParameters,
    Duration? timeout,
  }) async {
    final base = await _baseUrl();
    if (base == null) {
      throw Exception('未配置 LunaTV 服务器地址');
    }

    final uri = Uri.parse(
      base + path,
    ).replace(queryParameters: queryParameters);
    final headers = await _headers(host: uri.host);
    final effectiveTimeout = timeout ?? LunaTVConfig.defaultTimeout;

    return _executeWithRetryAndFallback(
      (client) => client.delete(uri, headers: headers),
      base: base,
      effectiveTimeout: effectiveTimeout,
      path: path,
      logUri: uri.toString(),
    );
  }

  static Map<String, dynamic> _decodeBody(http.Response response) {
    if (response.body.trim().isEmpty) return {};
    return json.decode(response.body) as Map<String, dynamic>;
  }

  static Future<ApiResponse<String>> login({
    required String serverUrl,
    required String username,
    required String password,
  }) async {
    final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
    if (base.isEmpty) {
      return ApiResponse.error('服务器地址不能为空');
    }

    final body = <String, String>{'username': username, 'password': password};
    final loginUri = Uri.parse('$base/api/login');

    Future<ApiResponse<String>> doLogin(http.Client client) async {
      final response = await client
          .post(
            loginUri,
            headers: {
              'Accept': 'application/json, text/plain, */*',
              'Content-Type': 'application/json',
              'User-Agent': AppInfoService.userAgent,
              'Host': loginUri.host,
            },
            body: json.encode(body),
          )
          .timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final setCookie = response.headers['set-cookie'];
        if (setCookie != null && setCookie.isNotEmpty) {
          return ApiResponse.success(
            setCookie,
            statusCode: response.statusCode,
          );
        }
        return ApiResponse.success('', statusCode: response.statusCode);
      }

      final data = _decodeBody(response);
      return ApiResponse.error(
        data['error']?.toString() ?? '登录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    }

    try {
      final client = await createApiClient();
      try {
        return await doLogin(client);
      } finally {
        client.close();
      }
    } catch (e) {
      if (isNetworkUnreachable(e)) {
        final dnsPreference =
            await UserDataService.getInternetServerDnsPreference();
        if (dnsPreference == InternetServerDnsPreference.ipv6) {
          _log(
            'LunaTVService',
            '登录：IPv6 优先模式失败，尝试系统自动 DNS 选择: $loginUri',
          );
          try {
            final client = await createApiClient(forceAutoDns: true);
            try {
              return await doLogin(client);
            } finally {
              client.close();
            }
          } catch (e2) {
            return ApiResponse.error('登录请求异常: $e2');
          }
        }
      }
      return ApiResponse.error('登录请求异常: $e');
    }
  }

  static Future<ApiResponse<List<SearchResult>>> search({
    required String keyword,
    String? source,
    bool forceRefresh = false,
    http.Client? cancelClient,
  }) async {
    await _initCache();
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) {
      return ApiResponse.success([], statusCode: 200);
    }

    final cacheKey = _cacheService.generateSearchCacheKey(
      keyword: trimmed,
      source: source,
    );
    if (!forceRefresh) {
      final cached = await _cacheService.get<List<SearchResult>>(
        cacheKey,
        (raw) => (raw as List<dynamic>)
            .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
      if (cached != null) return ApiResponse.success(cached);
    }

    try {
      final query = <String, String>{'q': trimmed};
      if (source != null && source.isNotEmpty) query['source'] = source;

      final base = await _baseUrl();
      _log(
        'LunaTVService.search',
        'base=$base, keyword=$trimmed, source=$source',
      );

      final response = await _get(
        '/api/search',
        queryParameters: query,
        timeout: LunaTVConfig.searchTimeout,
        cancelClient: cancelClient,
      );

      _log(
        'LunaTVService.search',
        'status=${response.statusCode}, '
        'bodyLength=${response.body.length}',
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final resultsData = data['results'] as List<dynamic>? ?? [];
        final results = resultsData
            .map((e) => SearchResult.fromJson(e as Map<String, dynamic>))
            .toList();
        _log(
          'LunaTVService.search',
          '解析结果数=${results.length}, body前200=${response.body.substring(0, response.body.length > 200 ? 200 : response.body.length)}',
        );
        // 仅缓存非空结果，避免服务器异常/无数据时被当作“无源”长期缓存，
        // 服务器恢复后可立即重新搜索到源；空结果同时清理旧缓存。
        if (results.isNotEmpty) {
          await _cacheService.set(
            cacheKey,
            results.map((e) => e.toJson()).toList(),
            LunaTVConfig.searchCacheTtl,
          );
        } else {
          await _cacheService.delete(cacheKey);
        }
        return ApiResponse.success(results, statusCode: response.statusCode);
      }
      _log('LunaTVService.search', '非 200 响应 status=${response.statusCode}');
      return ApiResponse.error(
        'LunaTV 搜索失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e, stack) {
      _log('LunaTVService.search', '搜索异常 $e\n$stack');
      return ApiResponse.error('LunaTV 搜索异常: $e');
    }
  }

  static Future<ApiResponse<VideoDetail>> getDetail({
    required String source,
    required String id,
    String? title,
  }) async {
    if (!RegExp(r'^[\w-]+$').hasMatch(id)) {
      return ApiResponse.error('无效的影片ID格式');
    }
    await _initCache();
    final cacheKey = _cacheService.generateDetailCacheKey(
      source: source,
      id: id,
    );
    final cached = await _cacheService.get<VideoDetail>(
      cacheKey,
      (raw) => VideoDetail.fromJson(raw as Map<String, dynamic>),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final query = <String, String>{'source': source, 'id': id};
      if (title != null && title.isNotEmpty) query['title'] = title;

      final response = await _get(
        '/api/detail',
        queryParameters: query,
        timeout: LunaTVConfig.detailTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final detail = VideoDetail.fromJson(data);
        await _cacheService.set(
          cacheKey,
          detail.toJson(),
          LunaTVConfig.detailCacheTtl,
        );
        return ApiResponse.success(detail, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 详情失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 详情异常: $e');
    }
  }

  static Future<ApiResponse<List<LiveChannel>>> getLiveChannels({
    required String sourceKey,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateLiveChannelsCacheKey(
      sourceKey: sourceKey,
    );
    final cached = await _cacheService.get<List<LiveChannel>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
    if (cached != null) return ApiResponse.success(cached);

    try {
      final response = await _get(
        '/api/live/channels',
        queryParameters: {'source': sourceKey},
        timeout: LunaTVConfig.liveTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final channelsData = data['data'] as List<dynamic>? ?? <dynamic>[];
        final channels = channelsData
            .map((e) => LiveChannel.fromJson(e as Map<String, dynamic>))
            .toList();
        await _cacheService.set(
          cacheKey,
          channels.map((e) => e.toJson()).toList(),
          LunaTVConfig.liveCacheTtl,
        );
        return ApiResponse.success(channels, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 直播频道失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 直播频道异常: $e');
    }
  }

  /// 获取 LunaTV 服务端配置的所有直播源（过滤已禁用的源）。
  static Future<ApiResponse<List<Map<String, dynamic>>>> getLiveSources() async {
    try {
      final response = await _get(
        '/api/live/sources',
        timeout: LunaTVConfig.liveTimeout,
      );
      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final sourcesData = data['data'] as List<dynamic>? ?? <dynamic>[];
        final sources = sourcesData
            .cast<Map<String, dynamic>>()
            .where((e) => e['disabled'] != true)
            .toList();
        return ApiResponse.success(sources, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        'LunaTV 直播源列表失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('LunaTV 直播源列表异常: $e');
    }
  }

  static Map<String, String> _buildVideoHeaders(String targetUrl) {
    try {
      final uri = Uri.parse(targetUrl);
      final origin = '${uri.scheme}://${uri.host}';
      return {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
        'Origin': origin,
        'Referer': '$origin/',
      };
    } catch (_) {
      return {
        'User-Agent':
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
            ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36',
        'Accept': '*/*',
        'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      };
    }
  }

  /// 创建测速专用 HTTP 客户端。
  ///
  /// 部分视频 CDN 使用非标准证书或 TLS 配置，Dart 默认证书校验会触发
  /// HandshakeException，而原生播放器通常可正常访问。测速场景下放宽校验
  /// 可减少误判，与 Selene/LunaTV 的行为一致。
  static http.Client _createSpeedTestClient() {
    final httpClient = HttpClient()
      ..badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
    return IOClient(httpClient);
  }

  static Future<({Duration responseTime, double? speed, String? resolution})>
      speedTestEpisode(
    String url, {
    Duration timeout = const Duration(seconds: 12),
    int sampleBytes = 512 * 1024,
    int maxConcurrency = 3,
    String? sourceType,
    /// 若已缓存该源分辨率，传入后可跳过 M3U8 分辨率提取，但仍会解析分片用于测速。
    String? cachedResolution,
  }) async {
    final stopwatch = Stopwatch()..start();
    final headers = _buildVideoHeaders(url);
    final isM3u8 = M3u8Utils.isM3u8Url(url);
    var hasNetworkError = false;

    /// 安全排空响应流，避免连接被半开占用。
    Future<void> drain(http.StreamedResponse response) async {
      try {
        await response.stream.drain<void>();
      } catch (_) {}
    }

    /// 测量首个分片的响应延迟（RTT），优先使用 HEAD，失败则回退到 GET 读少量数据。
    Future<int?> _measureLatency(
      String targetUrl, {
      Map<String, String>? headers,
      Duration probeTimeout = const Duration(seconds: 4),
    }) async {
      final client = _createSpeedTestClient();
      try {
        try {
          final sw = Stopwatch()..start();
          final headReq = http.Request('HEAD', Uri.parse(targetUrl));
          if (headers != null && headers.isNotEmpty) {
            headReq.headers.addAll(headers);
          }
          final headResp = await client.send(headReq).timeout(probeTimeout);
          await drain(headResp);
          if (headResp.statusCode >= 200 && headResp.statusCode < 400) {
            return sw.elapsedMilliseconds;
          }
        } catch (_) {}

        try {
          final sw = Stopwatch()..start();
          final getReq = http.Request('GET', Uri.parse(targetUrl));
          if (headers != null && headers.isNotEmpty) {
            getReq.headers.addAll(headers);
          }
          final getResp = await client.send(getReq).timeout(probeTimeout);
          var received = 0;
          const maxProbeBytes = 8 * 1024;
          await for (final chunk in getResp.stream) {
            received += chunk.length;
            if (received >= maxProbeBytes) break;
          }
          await drain(getResp);
          if (getResp.statusCode >= 200 && getResp.statusCode < 400) {
            return sw.elapsedMilliseconds;
          }
        } catch (_) {}
        return null;
      } finally {
        client.close();
      }
    }

    /// 对单个 URL 做下载测速，读取最多 [maxBytes] 字节后停止并排空剩余流。
    /// 返回正数表示实测速度；返回 -1.0 表示 Dart 网络层握手/连接/超时失败，
    /// 不代表源站不可播放（原生播放器网络层通常可正常访问）。
    Future<double?> _measureSpeed(
      String targetUrl, {
      Map<String, String>? headers,
      required int maxBytes,
      required Duration measureTimeout,
    }) async {
      final client = _createSpeedTestClient();
      try {
        final req = http.Request('GET', Uri.parse(targetUrl));
        if (headers != null && headers.isNotEmpty) {
          req.headers.addAll(headers);
        }
        // 大多数 HLS 分片服务器对 Range 请求响应更快、返回 206，与原生播放器
        // 按分片拉取一致；整段 GET 易被节流或超时，导致可流畅播放的源被误判为“仅可用”。
        // 仅在不含 Range 时补充，避免覆盖调用方显式设置的分片范围。
        req.headers.putIfAbsent('Range', () => 'bytes=0-${maxBytes - 1}');
        final streamedResponse = await client.send(req).timeout(measureTimeout);

        if (streamedResponse.statusCode == 200 ||
            streamedResponse.statusCode == 206) {
          final transferStopwatch = Stopwatch()..start();
          var received = 0;
          await for (final chunk in streamedResponse.stream) {
            received += chunk.length;
            if (received >= maxBytes) break;
          }
          await drain(streamedResponse);
          transferStopwatch.stop();
          final seconds = transferStopwatch.elapsedMilliseconds / 1000.0;
          return seconds > 0 ? (received / seconds) : 0.0;
        }
        await drain(streamedResponse);
        return null;
      } on HandshakeException catch (_) {
        return -1.0;
      } on SocketException catch (_) {
        return -1.0;
      } on TimeoutException catch (_) {
        return -1.0;
      } on http.ClientException catch (_) {
        return -1.0;
      } catch (_) {
        return null;
      } finally {
        client.close();
      }
    }

    /// 快速可用性探测：HEAD 失败后尝试 GET 读少量数据，
    /// 任何 2xx/3xx 均视为可用。
    Future<({Duration responseTime, bool available})> _probeAvailability(
      String targetUrl, {
      bool drainStream = true,
    }) async {
      final probeStopwatch = Stopwatch()..start();
      final probeHeaders = _buildVideoHeaders(targetUrl);

      Future<bool> tryHead() async {
        final client = http.Client();
        try {
          final headReq = http.Request('HEAD', Uri.parse(targetUrl));
          headReq.headers.addAll(probeHeaders);
          final headResponse = await client.send(headReq).timeout(
            const Duration(seconds: 4),
          );
          if (drainStream) await drain(headResponse);
          return headResponse.statusCode >= 200 && headResponse.statusCode < 400;
        } catch (_) {
          return false;
        } finally {
          client.close();
        }
      }

      Future<bool> tryGet() async {
        final client = http.Client();
        try {
          final getReq = http.Request('GET', Uri.parse(targetUrl));
          getReq.headers.addAll(probeHeaders);
          final getResponse = await client.send(getReq).timeout(
            const Duration(seconds: 4),
          );
          if (drainStream) {
            var received = 0;
            const maxProbeBytes = 16 * 1024;
            await for (final chunk in getResponse.stream) {
              received += chunk.length;
              if (received >= maxProbeBytes) break;
            }
            await drain(getResponse);
          }
          return getResponse.statusCode >= 200 && getResponse.statusCode < 400;
        } catch (_) {
          return false;
        } finally {
          client.close();
        }
      }

      if (await tryHead()) {
        return (responseTime: probeStopwatch.elapsed, available: true);
      }
      if (await tryGet()) {
        return (responseTime: probeStopwatch.elapsed, available: true);
      }
      return (responseTime: probeStopwatch.elapsed, available: false);
    }

    String? detectedResolution = cachedResolution;
    var testUrl = url;

    // 1. M3U8 源：先解析出真正要测速的分片 URL 与分辨率，再对分片测速。
    // 这样比直接对 playlist URL 测速更准确，也能正确识别 master playlist 的真实分辨率。
    if (isM3u8) {
      try {
        final m3u8Client = _createSpeedTestClient();
        try {
          final analysis = await M3u8Utils.analyzeM3u8ForSpeedTest(
            url,
            headers: headers,
            timeout: const Duration(seconds: 8),
            maxSegments: maxConcurrency,
            client: m3u8Client,
          );
        detectedResolution ??= analysis.resolution;
        testUrl = analysis.playlistUrl;

        if (analysis.segmentUrls.isNotEmpty) {
          final firstSegment = analysis.segmentUrls.first;
          final latencyMs = await _measureLatency(
            firstSegment,
            headers: headers,
            probeTimeout: const Duration(seconds: 4),
          );
          if (latencyMs != null && latencyMs >= 0) {
            final segmentSpeeds = await Future.wait(
              analysis.segmentUrls
                  .take(maxConcurrency)
                  .map(
                    (u) => _measureSpeed(
                      u,
                      headers: headers,
                      maxBytes: sampleBytes,
                      measureTimeout: timeout,
                    ),
                  ),
            );
            if (segmentSpeeds.any((s) => s == -1.0)) {
              hasNetworkError = true;
            }
            final validSpeeds = segmentSpeeds
                .whereType<double>()
                .where((s) => s > 0)
                .toList();
            if (validSpeeds.isNotEmpty) {
              final avgSpeed =
                  validSpeeds.reduce((a, b) => a + b) / validSpeeds.length;
              return (
                responseTime: Duration(milliseconds: latencyMs),
                speed: avgSpeed,
                resolution: detectedResolution,
              );
            }
          } else {
            hasNetworkError = true;
          }
        } else {
          // 无分片（可能是纯子 playlist），回退到 playlist URL 测速。
          final speed = await _measureSpeed(
            analysis.playlistUrl,
            headers: headers,
            maxBytes: 32 * 1024,
            measureTimeout: timeout,
          );
          if (speed == -1.0) {
            hasNetworkError = true;
          } else if (speed != null && speed > 0) {
            return (
              responseTime: stopwatch.elapsed,
              speed: speed,
              resolution: detectedResolution,
            );
          }
        }
      } finally {
        m3u8Client.close();
      }
      } on HandshakeException catch (_) {
        hasNetworkError = true;
        debugPrint('speedTest M3U8 解析失败（TLS 握手） $url');
      } on SocketException catch (_) {
        hasNetworkError = true;
        debugPrint('speedTest M3U8 解析失败（连接错误） $url');
      } on TimeoutException catch (_) {
        hasNetworkError = true;
        debugPrint('speedTest M3U8 解析失败（超时） $url');
      } catch (e) {
        debugPrint('speedTest M3U8 解析失败 $url: $e');
      }
    } else {
      // 2. 非 M3U8 源：直接对 URL 做下载测速。
      detectedResolution ??= M3u8Utils.extractResolutionFromText(url);
      try {
        final speed = await _measureSpeed(
          url,
          headers: headers,
          maxBytes: sampleBytes,
          measureTimeout: timeout,
        );
        if (speed == -1.0) {
          hasNetworkError = true;
        } else if (speed != null && speed > 0) {
          return (
            responseTime: stopwatch.elapsed,
            speed: speed,
            resolution: detectedResolution,
          );
        }
      } catch (e) {
        debugPrint('speedTest 非 M3U8 URL 测速失败 $url: $e');
      }
    }

    // 3. 测速失败时做可用性探测：可访问则标记为可用（速度未知）。
    try {
      final probe = await _probeAvailability(testUrl);
      if (probe.available || hasNetworkError) {
        return (
          responseTime: probe.responseTime,
          speed: -1.0,
          resolution: detectedResolution,
        );
      }
    } catch (_) {
      hasNetworkError = true;
    }

    stopwatch.stop();
    if (hasNetworkError) {
      debugPrint('speedTest 最终判定网络层异常但可能可播放: $url');
      return (
        responseTime: stopwatch.elapsed,
        speed: -1.0,
        resolution: detectedResolution,
      );
    }
    debugPrint('speedTest 最终判定不可用: $url');
    return (
      responseTime: stopwatch.elapsed,
      speed: 0.0,
      resolution: detectedResolution,
    );
  }

  /// 对单个 URL 做轻量级可用性探测，返回是否可用及响应时间。
  /// 只做 HEAD/GET，不解析 M3U8、不测下载速度。
  static Future<({String url, Duration responseTime, bool available})>
      _probeUrlAvailability(
    String url, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final stopwatch = Stopwatch()..start();
    final headers = _buildVideoHeaders(url);

    Future<bool> tryHead() async {
      final client = _createSpeedTestClient();
      try {
        final req = http.Request('HEAD', Uri.parse(url));
        req.headers.addAll(headers);
        final resp = await client.send(req).timeout(timeout);
        await resp.stream.drain<void>();
        return resp.statusCode >= 200 && resp.statusCode < 400;
      } catch (_) {
        return false;
      } finally {
        client.close();
      }
    }

    Future<bool> tryGet() async {
      final client = _createSpeedTestClient();
      try {
        final req = http.Request('GET', Uri.parse(url));
        req.headers.addAll(headers);
        final resp = await client.send(req).timeout(timeout);
        var received = 0;
        const maxBytes = 8 * 1024;
        await for (final chunk in resp.stream) {
          received += chunk.length;
          if (received >= maxBytes) break;
        }
        await resp.stream.drain<void>();
        return resp.statusCode >= 200 && resp.statusCode < 400;
      } catch (_) {
        return false;
      } finally {
        client.close();
      }
    }

    if (await tryHead()) {
      return (url: url, responseTime: stopwatch.elapsed, available: true);
    }
    if (await tryGet()) {
      return (url: url, responseTime: stopwatch.elapsed, available: true);
    }
    return (url: url, responseTime: stopwatch.elapsed, available: false);
  }

  /// 对 [urls] 批量做轻量级可用性探测，返回每个 URL 是否可用及响应时间。
  /// 用于搜索结果列表快速标记源是否可用，不下载实际内容。
  static Future<List<({String url, Duration responseTime, bool available})>>
      probeUrls(
    List<String> urls, {
    int concurrency = 8,
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final results = <({String url, Duration responseTime, bool available})>[];
    for (var i = 0; i < urls.length; i += concurrency) {
      final batch = urls.skip(i).take(concurrency).toList();
      final batchResults = await Future.wait(
        batch.map((url) => _probeUrlAvailability(url, timeout: timeout)),
      );
      results.addAll(batchResults);
    }
    return results;
  }

  static Future<ApiResponse<VideoDetail>> getDetailForSpeedTest({
    required String source,
    required String id,
    String? title,
  }) async {
    return getDetail(source: source, id: id, title: title);
  }

  /// 生成跨源身份 key。
  /// 优先使用 doubanId，其次使用 title+year 组合。
  static String? _generateSkipConfigIdentityKey({
    required String title,
    String? year,
    int? doubanId,
  }) {
    if (doubanId != null && doubanId > 0) {
      return 'douban:$doubanId';
    }
    if (title.isNotEmpty && year != null && year.isNotEmpty) {
      return 'title:$title:$year';
    }
    return null;
  }

  static Future<ApiResponse<EpisodeSkipConfig>> getSkipConfigs({
    required String source,
    required String id,
    bool forceRefresh = false,
    String? title,
    String? year,
    int? doubanId,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateSkipConfigsCacheKey(
      source: source,
      id: id,
    );
    if (!forceRefresh) {
      final cached = await _cacheService.get<EpisodeSkipConfig>(
        cacheKey,
        (raw) => EpisodeSkipConfig.fromJson(raw as Map<String, dynamic>),
      );
      if (cached != null) return ApiResponse.success(cached);
    }

    Future<ApiResponse<EpisodeSkipConfig>> doGet({
      required String key,
      String? identityKey,
    }) async {
      try {
        final payload = <String, dynamic>{
          'action': 'get',
          'key': key,
        };
        if (identityKey != null && identityKey.isNotEmpty) {
          payload['identityKey'] = identityKey;
        }
        final body = json.encode(payload);
        final response = await _post(
          '/api/skipconfigs',
          body: body,
          timeout: LunaTVConfig.defaultTimeout,
        );

        if (response.statusCode == 200) {
          final data = _decodeBody(response);
          if (data['error'] != null) {
            return ApiResponse.error(data['error'].toString());
          }
          final configData = data['config'] as Map<String, dynamic>?;
          if (configData == null) {
            return ApiResponse.error('暂无跳过配置');
          }
          final config = EpisodeSkipConfig.fromJson(configData);
          await _cacheService.set(
            cacheKey,
            config.toJson(),
            const Duration(days: 7),
          );
          return ApiResponse.success(config, statusCode: response.statusCode);
        }
        return ApiResponse.error(
          '获取跳过配置失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      } catch (e) {
        return ApiResponse.error('获取跳过配置异常: $e');
      }
    }

    // 生成跨源身份 key，用于不同源之间共享跳过配置。
    final identityKey = _generateSkipConfigIdentityKey(
      title: title ?? '',
      year: year,
      doubanId: doubanId,
    );
    debugPrint(
      '[SkipConfig] 加载跳过配置: source=$source id=$id '
      'title=$title year=$year doubanId=$doubanId identityKey=$identityKey',
    );

    // 优先使用 source+id 精确匹配
    var result = await doGet(key: '$source+$id');
    if (result.success && result.data != null) {
      return result;
    }

    // 未命中时尝试 identityKey 跨源匹配
    if (identityKey != null && identityKey.isNotEmpty) {
      result = await doGet(
        key: '$source+$id',
        identityKey: identityKey,
      );
      if (result.success && result.data != null) {
        return result;
      }

      // 服务器跨源匹配未命中时，回退到本地按 identityKey 缓存的配置，
      // 避免同一影片更换源后因服务器索引延迟/不一致导致跳过配置丢失。
      final identityCacheKey = _cacheService.generateSkipConfigsIdentityCacheKey(
        identityKey: identityKey,
      );
      final cachedIdentity = await _cacheService.get<EpisodeSkipConfig>(
        identityCacheKey,
        (raw) => EpisodeSkipConfig.fromJson(raw as Map<String, dynamic>),
      );
      if (cachedIdentity != null) {
        debugPrint(
          '[SkipConfig] 使用本地 identityKey 缓存: identityKey=$identityKey',
        );
        // 同时按当前 source+id 缓存一份，下次可直接命中。
        await _cacheService.set(
          cacheKey,
          cachedIdentity.toJson(),
          const Duration(days: 7),
        );
        return ApiResponse.success(cachedIdentity);
      }
    }

    return result;
  }

  static Future<ApiResponse<EpisodeSkipConfig>> setSkipConfigs({
    required String source,
    required String id,
    required String title,
    required List<SkipSegment> segments,
    String? year,
    int? doubanId,
  }) async {
    await _initCache();

    final config = EpisodeSkipConfig(
      source: source,
      id: id,
      title: title,
      segments: segments,
      updatedTime: DateTime.now().millisecondsSinceEpoch ~/ 1000,
    );

    Future<ApiResponse<EpisodeSkipConfig>> doSet({
      required String key,
      String? identityKey,
    }) async {
      try {
        final payload = <String, dynamic>{
          'action': 'set',
          'key': key,
          'config': {
            'source': source,
            'id': id,
            'title': title,
            'segments': segments.map((s) => s.toJson()).toList(),
          },
        };
        if (identityKey != null && identityKey.isNotEmpty) {
          payload['identityKey'] = identityKey;
        }
        final body = json.encode(payload);
        final response = await _post(
          '/api/skipconfigs',
          body: body,
          timeout: LunaTVConfig.defaultTimeout,
        );

        if (response.statusCode == 200) {
          final data = _decodeBody(response);
          if (data['error'] != null) {
            return ApiResponse.error(data['error'].toString());
          }
          return ApiResponse.success(config, statusCode: response.statusCode);
        }
        return ApiResponse.error(
          '保存跳过配置失败: ${response.statusCode}',
          statusCode: response.statusCode,
        );
      } catch (e) {
        return ApiResponse.error('保存跳过配置异常: $e');
      }
    }

    // 生成跨源身份 key。
    final identityKey = _generateSkipConfigIdentityKey(
      title: title,
      year: year,
      doubanId: doubanId,
    );
    debugPrint(
      '[SkipConfig] 保存跳过配置: source=$source id=$id '
      'title=$title year=$year doubanId=$doubanId identityKey=$identityKey',
    );

    // 1. 先保存到 source+id（精确匹配，向后兼容）
    var result = await doSet(key: '$source+$id');
    if (!result.success) {
      return result;
    }

    // 2. 如果有 identityKey，再保存到 identityKey（跨源同步）
    if (identityKey != null && identityKey.isNotEmpty) {
      final identityResult = await doSet(
        key: '$source+$id',
        identityKey: identityKey,
      );
      if (!identityResult.success) {
        return identityResult;
      }

      // 同时按 identityKey 缓存一份到本地，供其他源回退读取。
      final identityCacheKey = _cacheService.generateSkipConfigsIdentityCacheKey(
        identityKey: identityKey,
      );
      await _cacheService.set(
        identityCacheKey,
        config.toJson(),
        const Duration(days: 30),
      );
    }

    final cacheKey = _cacheService.generateSkipConfigsCacheKey(
      source: source,
      id: id,
    );
    await _cacheService.set(
      cacheKey,
      config.toJson(),
      const Duration(days: 7),
    );
    return ApiResponse.success(config, statusCode: 200);
  }

  // ================== 播放历史接口 ==================

  /// 获取当前用户的所有播放记录。
  /// [forceRefresh] 为 true 时跳过本地缓存直接请求服务器；否则优先返回缓存，
  /// 由调用方决定是否后台刷新。
  static Future<ApiResponse<Map<String, PlayRecord>>> getPlayRecords({
    bool forceRefresh = false,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generatePlayRecordsCacheKey();

    if (!forceRefresh) {
      final cached = await _cacheService.get<Map<String, PlayRecord>>(
        cacheKey,
        (raw) => (raw as Map<String, dynamic>).map(
          (k, v) => MapEntry(k, PlayRecord.fromJson(k, v as Map<String, dynamic>)),
        ),
      );
      if (cached != null) return ApiResponse.success(cached);
    }

    return _fetchAndCachePlayRecords(cacheKey);
  }

  static Future<ApiResponse<Map<String, PlayRecord>>> _fetchAndCachePlayRecords(
    String cacheKey,
  ) async {
    final result = await _fetchPlayRecords();
    if (result.success && result.data != null) {
      await _cacheService.set(
        cacheKey,
        result.data!.map((k, v) => MapEntry(k, v.toJson())),
        LunaTVConfig.playRecordsCacheTtl,
      );
    }
    return result;
  }

  static Future<ApiResponse<Map<String, PlayRecord>>> _fetchPlayRecords() async {
    try {
      final response = await _get(
        '/api/playrecords',
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final records = <String, PlayRecord>{};
        for (final entry in data.entries) {
          final key = entry.key.toString();
          final value = entry.value as Map<String, dynamic>;
          records[key] = PlayRecord.fromJson(key, value);
        }
        return ApiResponse.success(records, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '获取播放记录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('获取播放记录异常: $e');
    }
  }

  /// 保存播放记录到后端
  static Future<ApiResponse<void>> savePlayRecord({
    required String key,
    required PlayRecord record,
  }) async {
    try {
      final body = json.encode({'key': key, 'record': record.toJson()});
      final response = await _post(
        '/api/playrecords',
        body: body,
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        await _initCache();
        await _updatePlayRecordsCache(key, record);
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '保存播放记录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('保存播放记录异常: $e');
    }
  }

  /// 将单条播放记录合并到本地缓存，避免写操作后下次读取必须重新请求远程。
  static Future<void> _updatePlayRecordsCache(
    String key,
    PlayRecord record,
  ) async {
    final cacheKey = _cacheService.generatePlayRecordsCacheKey();
    final cached = await _cacheService.get<Map<String, PlayRecord>>(
      cacheKey,
      (raw) => (raw as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, PlayRecord.fromJson(k, v as Map<String, dynamic>)),
      ),
    );
    if (cached == null) {
      await _cacheService.delete(cacheKey);
      return;
    }
    cached[key] = record;
    await _cacheService.set(
      cacheKey,
      cached.map((k, v) => MapEntry(k, v.toJson())),
      LunaTVConfig.playRecordsCacheTtl,
    );
  }

  /// 删除单条播放记录
  static Future<ApiResponse<void>> deletePlayRecord(String key) async {
    try {
      final response = await _delete(
        '/api/playrecords',
        queryParameters: {'key': key},
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        await _initCache();
        await _removePlayRecordFromCache(key);
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '删除播放记录失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('删除播放记录异常: $e');
    }
  }

  /// 从本地缓存中移除单条播放记录。
  static Future<void> _removePlayRecordFromCache(String key) async {
    final cacheKey = _cacheService.generatePlayRecordsCacheKey();
    final cached = await _cacheService.get<Map<String, PlayRecord>>(
      cacheKey,
      (raw) => (raw as Map<String, dynamic>).map(
        (k, v) => MapEntry(k, PlayRecord.fromJson(k, v as Map<String, dynamic>)),
      ),
    );
    if (cached == null) return;
    if (!cached.containsKey(key)) return;
    cached.remove(key);
    await _cacheService.set(
      cacheKey,
      cached.map((k, v) => MapEntry(k, v.toJson())),
      LunaTVConfig.playRecordsCacheTtl,
    );
  }

  // ================== 收藏接口 ==================

  /// 获取当前用户的所有收藏。
  /// [forceRefresh] 为 true 时跳过本地缓存直接请求服务器；否则优先返回缓存。
  static Future<ApiResponse<List<Favorite>>> getFavorites({
    bool forceRefresh = false,
  }) async {
    await _initCache();
    final cacheKey = _cacheService.generateFavoritesCacheKey();

    if (!forceRefresh) {
      final cached = await _cacheService.get<List<Favorite>>(
        cacheKey,
        (raw) => (raw as List<dynamic>)
            .map((e) => Favorite.fromJson(
                  (e as Map<String, dynamic>)['key'] as String,
                  e,
                ))
            .toList(),
      );
      if (cached != null) {
        final sorted = List<Favorite>.from(cached)
          ..sort((a, b) => (b.saveTime ?? 0).compareTo(a.saveTime ?? 0));
        return ApiResponse.success(sorted);
      }
    }

    return _fetchAndCacheFavorites(cacheKey);
  }

  static Future<ApiResponse<List<Favorite>>> _fetchAndCacheFavorites(
    String cacheKey,
  ) async {
    final result = await _fetchFavorites();
    if (result.success && result.data != null) {
      await _cacheService.set(
        cacheKey,
        result.data!
            .map((f) => {
                  'key': '${f.source}+${f.id}',
                  ...f.toJson(),
                })
            .toList(),
        LunaTVConfig.favoritesCacheTtl,
      );
    }
    return result;
  }

  static Future<ApiResponse<List<Favorite>>> _fetchFavorites() async {
    try {
      final response = await _get(
        '/api/favorites',
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        final favorites = data.entries.map((e) {
          return Favorite.fromJson(e.key, e.value as Map<String, dynamic>);
        }).toList();
        favorites.sort((a, b) => (b.saveTime ?? 0).compareTo(a.saveTime ?? 0));
        return ApiResponse.success(favorites, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '获取收藏失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('获取收藏异常: $e');
    }
  }

  /// 添加收藏
  static Future<ApiResponse<void>> addFavorite({
    required String key,
    required Favorite favorite,
  }) async {
    try {
      final body = json.encode({'key': key, 'favorite': favorite.toJson()});
      final response = await _post(
        '/api/favorites',
        body: body,
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        await _initCache();
        await _updateFavoritesCache(key, favorite);
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '添加收藏失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('添加收藏异常: $e');
    }
  }

  /// 将单条收藏合并到本地缓存，避免写操作后下次读取必须重新请求远程。
  static Future<void> _updateFavoritesCache(
    String key,
    Favorite favorite,
  ) async {
    final cacheKey = _cacheService.generateFavoritesCacheKey();
    final cached = await _cacheService.get<List<Favorite>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map(
            (e) => Favorite.fromJson(
              (e as Map<String, dynamic>)['key'] as String,
              e,
            ),
          )
          .toList(),
    );
    if (cached == null) {
      await _cacheService.delete(cacheKey);
      return;
    }
    final index = cached.indexWhere(
      (f) => '${f.source}+${f.id}' == key,
    );
    if (index >= 0) {
      cached[index] = favorite;
    } else {
      cached.add(favorite);
    }
    await _cacheService.set(
      cacheKey,
      cached
          .map((f) => {
                'key': '${f.source}+${f.id}',
                ...f.toJson(),
              })
          .toList(),
      LunaTVConfig.favoritesCacheTtl,
    );
  }

  /// 删除收藏
  static Future<ApiResponse<void>> deleteFavorite(String key) async {
    try {
      final response = await _delete(
        '/api/favorites',
        queryParameters: {'key': key},
        timeout: LunaTVConfig.defaultTimeout,
      );

      if (response.statusCode == 200) {
        await _initCache();
        await _removeFavoriteFromCache(key);
        return ApiResponse.success(null, statusCode: response.statusCode);
      }
      return ApiResponse.error(
        '删除收藏失败: ${response.statusCode}',
        statusCode: response.statusCode,
      );
    } catch (e) {
      return ApiResponse.error('删除收藏异常: $e');
    }
  }

  /// 从本地缓存中移除单条收藏。
  static Future<void> _removeFavoriteFromCache(String key) async {
    final cacheKey = _cacheService.generateFavoritesCacheKey();
    final cached = await _cacheService.get<List<Favorite>>(
      cacheKey,
      (raw) => (raw as List<dynamic>)
          .map(
            (e) => Favorite.fromJson(
              (e as Map<String, dynamic>)['key'] as String,
              e,
            ),
          )
          .toList(),
    );
    if (cached == null) return;
    final index = cached.indexWhere(
      (f) => '${f.source}+${f.id}' == key,
    );
    if (index < 0) return;
    cached.removeAt(index);
    await _cacheService.set(
      cacheKey,
      cached
          .map((f) => {
                'key': '${f.source}+${f.id}',
                ...f.toJson(),
              })
          .toList(),
      LunaTVConfig.favoritesCacheTtl,
    );
  }

  /// 查询是否已收藏
  static Future<bool> isFavorite(String key) async {
    try {
      final response = await _get(
        '/api/favorites',
        queryParameters: {'key': key},
        timeout: LunaTVConfig.defaultTimeout,
      );
      if (response.statusCode == 200) {
        final data = _decodeBody(response);
        return data.isNotEmpty;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 切换收藏状态
  static Future<bool> toggleFavorite({
    required String key,
    required Favorite favorite,
  }) async {
    final isFav = await isFavorite(key);
    if (isFav) {
      await deleteFavorite(key);
      return false;
    } else {
      await addFavorite(key: key, favorite: favorite);
      return true;
    }
  }

  /// 构建 LunaTV 直播流代理播放 URL。
  ///
  /// LunaTV 直播频道需要通过服务器 `/api/proxy/stream` 接口代理播放，
  /// 不能直接播放原始 URL。
  static Future<String?> getProxyStreamUrl(
    String channelUrl,
    String sourceKey,
  ) async {
    final base = await _baseUrl();
    if (base == null) return null;
    return '$base/api/proxy/stream?url=${Uri.encodeComponent(channelUrl)}&moontv-source=$sourceKey';
  }
}
