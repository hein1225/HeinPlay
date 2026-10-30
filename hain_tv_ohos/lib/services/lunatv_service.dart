import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

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
import '../platform/device_utils.dart';
import 'app_info_service.dart';
import 'cache_service.dart';
import 'connectivity_service.dart';
import 'm3u8_utils.dart';
import 'media_resolution_probe.dart';
import 'playback_activity.dart';
import 'user_data_service.dart';
import '../utils/windows_logger.dart';

import '../utils/log_redactor.dart';

/// 🔴 2026-10-23（第六轮）：分辨率探测时保留的分片样本字节数。
///
/// 实测 SPS 位于分片开头 602 字节处；64KB 足够覆盖各种封装的头部，
/// 内存占用也可忽略。
const int _kResolutionProbeBytes = 64 * 1024;

/// 🔴 2026-10-23（第六轮）：十六进制字符串 → 16 字节 IV。
Uint8List? _hexIvToBytes(String? hex) {
  if (hex == null) return null;
  final clean = hex.replaceAll(RegExp(r'[^0-9a-fA-F]'), '');
  if (clean.length < 32) return null;
  final out = Uint8List(16);
  for (var i = 0; i < 16; i++) {
    final v = int.tryParse(clean.substring(i * 2, i * 2 + 2), radix: 16);
    if (v == null) return null;
    out[i] = v;
  }
  return out;
}

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

/// 🔴 2026-10-23（第三轮）：单源测速的取消令牌。
///
/// `Future.timeout` 只能放弃等待，无法中止底层 HTTP 请求。外层批处理
/// 超时后若不通知被测源，这个源会继续跑完（实测多跑 2~4 秒），
/// 白占带宽，并且日志里同时出现 `outer-timeout-abandoned` 与
/// `note=unavailable` 两条互相矛盾的记录。
///
/// 用法：外层超时 → `token.cancel()` → 被测函数在 await 边界检查
/// `token.isCancelled` 并立即返回。
class SpeedTestCancelToken {
  bool _cancelled = false;
  bool get isCancelled => _cancelled;
  void cancel() => _cancelled = true;
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
  /// 电脑版（Windows/Linux）Dart 默认证书校验对自签名/非标准证书链容易触发
  /// HandshakeException，而 Android 同网络可正常访问。此处对电脑版
  /// 放宽证书校验，并禁用系统代理、保持长连接，确保用户配置的服务器地址可用。
  static void _log(String tag, String message) {
    // 🔒 隐私：统一脱敏，避免服务器地址 / 用户名 / 密码进入日志。
    final safe = LogRedactor.redact(message);
    if (DeviceUtils.isComputer) {
      WindowsLogger.log(tag, safe);
    } else {
      debugPrint('[$tag] $safe');
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
    final bypassCert = DeviceUtils.isComputer;

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
    if (DeviceUtils.isComputer) {
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

    // 电脑版兜底：使用更保守的客户端再试一次，便于区分是自定义配置还是网络本身问题
    if (DeviceUtils.isComputer) {
      final fallbackClient = cancelClient ?? await _createFallbackClient();
      final shouldCloseFallback = cancelClient == null;
      try {
        _log('LunaTVService._get', '电脑版兜底请求 $uri');
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
    /// 🔴 2026-10-23：为 true 时**只做分辨率识别，不做下载测速**。
    ///
    /// 用于「正在播放的源」——该源的流量正在被播放器占用，再测一次不仅
    /// 测出来的值被自身播放流污染（显示很慢），还会白白再抢一遍带宽。
    /// 此时直接解析 M3U8 拿到真实分辨率后返回，速度标记为 -1.0
    /// （语义：可用但速度未知）。
    bool resolutionOnly = false,
    /// 🔴 2026-10-23（第三轮）：取消令牌。
    ///
    /// 外层批处理给每个源设了 8 秒硬超时，但 Dart 的 `Future.timeout`
    /// **只停止等待，不会中止底层任务**。于是被判超时的源仍会在几秒后
    /// 跑完并打印 `note=unavailable`，既白占带宽，又让日志出现
    /// 「超时放弃」和「判定不可用」两行自相矛盾的记录。
    ///
    /// 外层超时后调用 [SpeedTestCancelToken.cancel]，本函数在每个
    /// await 边界检查该令牌并立即返回，不再继续发请求。
    SpeedTestCancelToken? cancelToken,
  }) async {
    final stopwatch = Stopwatch()..start();
    final headers = _buildVideoHeaders(url);
    // 🔴🔴 2026-10-23：改为可变 —— 嗅探出「HTML 播放器页」内嵌的 m3u8 后
    // 会把这里改成 true（见下方 _sniffM3u8FromHtmlEntry 调用处）。
    var isM3u8 = M3u8Utils.isM3u8Url(url);
    var hasNetworkError = false;

    /// 🔴 2026-10-23（第三轮）：**整源预算截止时间**。
    ///
    /// 原来每个网络操作各自吃满自己的 timeout：M3U8 解析 8 秒 + 测速 12 秒，
    /// 串起来最多 20 秒，而外层批处理的硬超时只有 8 秒 —— 于是必然出现
    /// 「外层已放弃、内层还在跑」的情况（实测内层多跑 2~4 秒，
    /// 日志里同时出现 `outer-timeout-abandoned` 与 `note=unavailable`）。
    ///
    /// 现在整源共享一个截止时间，每个操作只允许用「剩余预算」，
    /// 内层保证在外层超时之前自己收口，给出明确结论。
    final deadline = DateTime.now().add(timeout);

    /// 剩余预算（不小于 0）。
    Duration remaining() {
      final left = deadline.difference(DateTime.now());
      return left.isNegative ? Duration.zero : left;
    }

    /// 播放是否正在取流。写进日志便于事后核对「播放中测速」的实际档位。
    final playbackActive = PlaybackActivity.instance.isActive;

    /// 只识别分辨率模式下返回的速度占位：-1.0 = 可用但速度未知。
    const double resolutionOnlySpeed = -1.0;

    /// 统一的测速日志前缀，事后 grep `[SpeedTestRes]` 即可还原整轮测速。
    String logTag(String extra) =>
        '[SpeedTestRes] source=$sourceType url=$url $extra '
        'pa=$playbackActive sample=${sampleBytes}B '
        'segConc=${resolutionOnly ? 0 : maxConcurrency}';


    /// 🔴 2026-10-23（改动2）：把**实测速度值**写进日志。
    ///
    /// 原实现只打印 source/url/resolved/resolution，且打印发生在 M3U8 解析之后、
    /// 速度测出之前，因此全日志没有任何速度数值，事后无法核实「播放中测速
    /// 到底有多慢」。现在每次测速（含失败与降级）都打一条 `[SpeedTestSpeed]`。
    void logSpeed(
      double? speedBytesPerSec, {
      required String resolved,
      int? segmentCount,
      int? latencyMs,
      Duration? elapsed,
      String? note,
    }) {
      final s = speedBytesPerSec;
      final showRate = s != null && s >= 0;
      debugPrint(
        '[SpeedTestSpeed] source=$sourceType url=$url resolved=$resolved '
        'speed=${s == null ? 'null' : s.toStringAsFixed(0)} B/s '
        'speedKBps=${showRate ? (s / 1024).toStringAsFixed(1) : 'n/a'} '
        'speedMbps=${showRate ? (s * 8 / 1000000).toStringAsFixed(2) : 'n/a'} '
        'latency=${latencyMs ?? -1}ms '
        'elapsed=${elapsed?.inMilliseconds ?? -1}ms '
        'sample=${sampleBytes}B segs=${segmentCount ?? 0} '
        'pa=$playbackActive${note != null ? ' note=$note' : ''}',
      );
    }

    /// 🔴🔴 2026-10-23：嗅探「HTML 播放器页」，取出内嵌的真正 m3u8 地址。
    ///
    /// 实测（Windows 真机）：jinyingzy.com 的播放地址
    /// `https://hd.kuktxu.com/play/eXD5yD8e` 没有 `.m3u8` 后缀，服务器返回
    /// 1593 字节的 HTML（`content-type: text/html`），页面里用 hls.js 播
    /// `https://hd.kuktxu.com/play/eXD5yD8e/index.m3u8`。
    ///
    /// 只读前 64KB 就够判断并提取，不会变成一次大下载。
    ///
    /// 返回 null = 不是 HTML 播放器页（或嗅探失败），调用方按原逻辑处理。
    Future<String?> _sniffM3u8FromHtmlEntry(
      String url, {
      required Map<String, String> headers,
      required Duration timeout,
    }) async {
      final client = _createSpeedTestClient();
      try {
        final req = http.Request('GET', Uri.parse(url));
        if (headers.isNotEmpty) {
          req.headers.addAll(headers);
        }
        final resp = await client.send(req).timeout(timeout);
        if (resp.statusCode != 200) return null;
        final chunks = <int>[];
        await for (final chunk in resp.stream) {
          chunks.addAll(chunk);
          if (chunks.length >= 64 * 1024) break;
        }
        final body = utf8.decode(chunks, allowMalformed: true);
        if (!M3u8Utils.looksLikeHtmlContent(body)) return null;
        return M3u8Utils.extractM3u8FromHtml(body, baseUrl: url);
      } catch (_) {
        return null;
      } finally {
        client.close();
      }
    }

    /// 对单个 URL 做下载测速，读取最多 [maxBytes] 字节后**立即停止**。
    /// 返回正数表示实测速度；返回 -1.0 表示 Dart 网络层握手/连接/超时失败，
    /// 不代表源站不可播放（原生播放器网络层通常可正常访问）。
    ///
    /// 🔴 2026-10-23：同时返回首字节延迟（latencyMs）。
    ///
    /// 原实现先用 [_measureLatency] 单独发一次 HEAD（或 GET 8KB）探测 RTT，
    /// 紧接着 [_measureSpeed] 又对**同一个分片**再发一次 GET 下载样本 ——
    /// 两次请求打同一个 URL，多付一个完整 RTT（实测 0.6~1.6 秒/源）。
    /// 现在一次请求同时得到延迟与速度：send 之后开始读流，记录首个数据块
    /// 到达时刻即为首字节延迟，传输计时段保持原语义（不含首包等待）。
    /// 🔴🔴 2026-10-23（第六轮）：额外返回**样本字节**（分片开头若干 KB）。
    ///
    /// 用途：从码流里读 SPS 拿**真实分辨率**。
    /// 资源站的 media playlist 没有 RESOLUTION，只能靠码率反推，而码率与
    /// 分辨率没有必然关系（实测 661kbps 的流真实是 1920x818 = 1080P 级别）。
    /// 测速本来就在下载分片，把开头这几十 KB 留下来几乎零成本。
    Future<
        ({
          double? speed,
          int? latencyMs,
          int? totalBytes,
          bool isText,
          Uint8List? probeSample,
        })> _measureSpeed(
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
        final requestStopwatch = Stopwatch()..start();
        final streamedResponse = await client.send(req).timeout(measureTimeout);

        // 🔴 2026-10-23（第三轮）：从 Content-Range 读出**分片总大小**。
        //
        // 这一行原本要单独发一次 Range 探测请求才能拿到（分片码率估算），
        // 现在测速请求本身就带 Range 头，响应头里已经写着
        // `Content-Range: bytes 0-262143/1234567`，末位就是分片总大小。
        // 配合 playlist 的 #EXTINF 时长即可算出码率 → 分辨率，
        // 整轮测速因此少一次串行 RTT（高延迟源一次就 1.5~2 秒）。
        int? totalBytes;
        final contentRange = streamedResponse.headers['content-range'];
        if (contentRange != null) {
          final match =
              RegExp(r'bytes\s+\d+-\d+/(\d+)').firstMatch(contentRange);
          totalBytes = int.tryParse(match?.group(1) ?? '');
        } else if (streamedResponse.statusCode == 200) {
          // 🔴 2026-10-23（第三轮）：**服务器不支持 Range** 时会忽略 Range 头
          // 直接返回 200 + 完整 body，此时 `content-length` 就是分片总大小，
          // 同样可以拿来推算码率。
          //
          // ⚠️ 206 响应里 content-length 只是**本次返回的部分长度**
          // （例如 262144），不是分片总大小，所以只有 200 时才用它兜底。
          totalBytes = int.tryParse(
            streamedResponse.headers['content-length'] ?? '',
          );
        }

        // 🔴🔴 2026-10-23：判断响应**是不是文本**（HTML 播放器页 / m3u8 清单）。
        //
        // 直链媒体（mp4/ts/flv…）与分片都是二进制，不受影响；
        // 但「HTML 播放器页」只有 1~2KB，1ms 就下载完 → 会算出 18MB/s 的
        // **假速度**，把实际一播放就卡死的源显示成最快的源。
        // 这里提前识别文本类响应，让上层不采信它的速度值。
        final contentTypeLower =
            (streamedResponse.headers['content-type'] ?? '').toLowerCase();
        final typeSaysText = contentTypeLower.contains('text/') ||
            contentTypeLower.contains('mpegurl') ||
            contentTypeLower.contains('javascript') ||
            contentTypeLower.contains('json') ||
            contentTypeLower.contains('xml');

        if (streamedResponse.statusCode == 200 ||
            streamedResponse.statusCode == 206) {
          final transferStopwatch = Stopwatch()..start();
          var received = 0;
          int? firstByteMs;
          var isText = typeSaysText;
          // 🔴 2026-10-23（第六轮）：留一份分片开头的样本字节用于 SPS 探测。
          //
          // 实测 SPS 位于分片开头 602 字节处，64KB 足够覆盖各种封装的头部。
          final probeBuilder = BytesBuilder(copy: false);
          await for (final chunk in streamedResponse.stream) {
            firstByteMs ??= requestStopwatch.elapsedMilliseconds;
            if (received == 0 && chunk.length >= 8) {
              // 首个数据块的前 8 字节：绝大多数是可打印 ASCII → 文本。
              //
              // ⚠️ 不能只看单个字节（'#'=m3u8、'<'=HTML）：二进制分片也可能
              // 恰好以 0x23/0x3C 开头，那样会把正常分片误判成文本 → 速度被
              // 丢弃 → 好源被误判成「不可用」。连续 8 字节里 7 个以上可打印
              // 才是文本，误判概率可忽略。
              var printable = 0;
              for (var i = 0; i < 8; i++) {
                final b = chunk[i];
                if (b == 0x0A ||
                    b == 0x0D ||
                    b == 0x09 ||
                    (b >= 0x20 && b <= 0x7E)) {
                  printable++;
                }
              }
              if (printable >= 7) isText = true;
            }
            if (probeBuilder.length < _kResolutionProbeBytes) {
              final need = _kResolutionProbeBytes - probeBuilder.length;
              probeBuilder.add(chunk.length <= need ? chunk : chunk.sublist(0, need));
            }
            received += chunk.length;
            if (received >= maxBytes) break;
          }
          // 🔴🔴 2026-10-23（第四轮）：**不要 drain 剩余响应体**。
          //
          // 原实现在读完 maxBytes 样本后调用 `drain(streamedResponse)`，
          // 意图是「释放连接」，但实际行为是**把分片剩下的部分整个下载完**：
          //   · 服务器支持 Range 时返回 206，剩余量 = 总量 - 样本量
          //   · 服务器忽略 Range 时返回 200，剩余量 = 整个分片
          //
          // 实测反推（Windows 真机日志）：
          //   modujx17  speed=90.4KB/s elapsed=10258ms → 分片总量约 827KB
          //   maoyanplay speed=159.8KB/s elapsed=7790ms → 分片总量约 964KB
          //   bdzy1    speed=128.9KB/s elapsed=7354ms → 分片总量约 798KB
          // 样本只要 256KB，多下的 300~700KB 占了单源耗时的 **50% 以上**。
          // 慢速源尤其致命：多下 600KB @90KB/s 就是多等 6.7 秒。
          //
          // 测速只要样本，不需要 body 读完；连接由 `client.close()` 释放
          // （finally 里统一关闭），不会泄漏。
          transferStopwatch.stop();
          // 🔴 2026-10-23：计时改用微秒。原实现用 elapsedMilliseconds，
          // 传输耗时不足 1 ms 时 seconds==0 → 返回 0.0 → UI 判为「不可用」。
          // 播放中降档到 128/256KB 样本后，在千兆宽带或局域网近端 CDN 上
          // 单次传输经常低于 1 ms，于是「好源被误判为不可用」。微秒计时可
          // 正确给出数百 MB/s 的真实值。
          final micros = transferStopwatch.elapsedMicroseconds;
          final speed = micros <= 0 ? 0.0 : received * 1000000 / micros;
          return (
            speed: speed,
            latencyMs: firstByteMs ?? requestStopwatch.elapsedMilliseconds,
            totalBytes: totalBytes,
            isText: isText,
            probeSample: probeBuilder.isEmpty ? null : probeBuilder.takeBytes(),
          );
        }
        // 🔴 2026-10-23（第四轮）：错误响应同样不 drain —— 错误页/占位页的
        // body 再长也没有读取价值，等它读完纯属白等。
        return (
          speed: null,
          latencyMs: null,
          totalBytes: totalBytes,
          isText: typeSaysText,
          probeSample: null,
        );
      } on HandshakeException catch (_) {
        return (
            speed: -1.0,
            latencyMs: null,
            totalBytes: null,
            isText: false,
            probeSample: null,
          );
      } on SocketException catch (_) {
        return (
            speed: -1.0,
            latencyMs: null,
            totalBytes: null,
            isText: false,
            probeSample: null,
          );
      } on TimeoutException catch (_) {
        return (
            speed: -1.0,
            latencyMs: null,
            totalBytes: null,
            isText: false,
            probeSample: null,
          );
      } on http.ClientException catch (_) {
        return (
            speed: -1.0,
            latencyMs: null,
            totalBytes: null,
            isText: false,
            probeSample: null,
          );
      } catch (_) {
        return (
            speed: null,
            latencyMs: null,
            totalBytes: null,
            isText: false,
            probeSample: null,
          );
      } finally {
        client.close();
      }
    }

    /// 🔴 2026-10-23（第六轮）：取 AES-128 解密 key（16 字节）。
    ///
    /// 资源站的 media playlist 分片普遍是 AES-128 密文，要从码流读 SPS 拿
    /// **真实分辨率**必须先解密。key 只有 16 字节、整条 playlist 共用一个，
    /// 一次请求即可，且**与分片测速并发**发起 —— 不增加串行 RTT。
    Future<Uint8List?> _fetchAesKey(
      String keyUri, {
      Map<String, String>? headers,
      required Duration timeout,
    }) async {
      try {
        final client = _createSpeedTestClient();
        try {
          final resp = await client
              .get(Uri.parse(keyUri), headers: headers)
              .timeout(timeout);
          if (resp.statusCode != 200) return null;
          final bytes = resp.bodyBytes;
          if (bytes.length < 16) return null;
          return Uint8List.sublistView(bytes, 0, 16);
        } finally {
          client.close();
        }
      } catch (_) {
        return null;
      }
    }

    String? detectedResolution;
    var testUrl = url;

    /// 🔴 2026-10-23（第三轮）：打印分辨率日志。
    ///
    /// 原来这条日志紧跟在 M3U8 解析之后打印，而**码率推算出的分辨率**
    /// 要等测速请求拿到 Content-Range 总大小才知道。于是日志里的
    /// `resolution=` 有时是 null、有时是旧值。
    ///
    /// 现在统一在「拿到最终结论、准备打速度日志之前」打印，
    /// 保证一条 `[SpeedTestRes]` 就是该源的最终分辨率，
    /// 且每个源只有一条（不再出现解析后一条、fallback 再一条）。
    void logResolution({String suffix = ''}) {
      debugPrint(
        logTag(
          'resolved=$testUrl resolution=$detectedResolution$suffix'
          '${resolutionOnly ? ' mode=resolution-only' : ''}',
        ),
      );
    }

    // 🔴🔴 2026-10-23：嗅探「HTML 播放器页」入口，取出真正的 m3u8 地址。
    //
    // 实测（Windows 真机，jinyingzy.com 源）：
    //   源给的播放地址 `https://hd.kuktxu.com/play/eXD5yD8e` **没有 .m3u8 后缀**，
    //   服务器返回 1593 字节的 **HTML 播放器页**（content-type: text/html），
    //   里面用 hls.js 播放 `https://hd.kuktxu.com/play/eXD5yD8e/index.m3u8`。
    //
    // 旧逻辑按「URL 后缀」判定，于是：
    //   · 测速走 direct 分支，把 1593 字节 HTML 1ms 下载完 → **假 18MB/s**
    //     （界面显示这个源极快，实际一播放就卡死）；
    //   · 播放时 AdFilterEngine 判定「非 M3U8 地址」→ 跳过代理 → 播放器
    //     直接打开 HTML → **画面卡住、总时长读不出来**。
    //
    // 现在：URL 不像直链媒体时，先花一次请求嗅探内容；确认是 HTML 播放器页
    // 就把内嵌的 m3u8 取出来，按真正的 HLS 流程解析与测速。
    var effectiveUrl = url;
    if (!isM3u8 && !M3u8Utils.looksLikeDirectMediaUrl(url)) {
      final sniffed = await _sniffM3u8FromHtmlEntry(
        url,
        headers: headers,
        timeout: remaining(),
      );
      if (sniffed != null) {
        debugPrint('[SpeedTestSniff] HTML 播放器页 → 内嵌 m3u8: $sniffed');
        effectiveUrl = sniffed;
        isM3u8 = true;
      }
    }

    // 1. M3U8 源：先解析出真正要测速的分片 URL 与分辨率，再对分片测速。
    // 这样比直接对 playlist URL 测速更准确，也能正确识别 master playlist 的真实分辨率。
    if (isM3u8) {
      try {
        final m3u8Client = _createSpeedTestClient();
        try {
          // 🔴 2026-10-23（第八轮）：解析走**带短重试**的版本。
          //
          // 原来这里对源站抖动**零容错**：一次连接被对端关掉，整个源就
          // 判不出分辨率（resolution=null）。
          final analysis = await _analyzeM3u8WithRetry(
            effectiveUrl,
            headers: headers,
            maxSegments: math.max(maxConcurrency, 2),
            client: m3u8Client,
            deadline: deadline,
            cancelToken: cancelToken,
          );
        // 实测解析出的分辨率优先于缓存/文本推断，因为 M3U8 文本是真实的。
        detectedResolution = analysis.resolution ?? detectedResolution;
        testUrl = analysis.playlistUrl;

        // 🔴 2026-10-23（第三轮）：外层已放弃本源 → 立即停止，不再发请求。
        if (cancelToken?.isCancelled ?? false) {
          logResolution(suffix: ' (cancelled)');
          logSpeed(
            resolutionOnlySpeed,
            resolved: testUrl,
            elapsed: stopwatch.elapsed,
            note: 'cancelled',
          );
          return (
            responseTime: stopwatch.elapsed,
            speed: resolutionOnlySpeed,
            resolution: detectedResolution,
          );
        }

        // 🔴 2026-10-23：只识别分辨率模式——不下载任何分片，直接返回。
        // 正在播放的源由播放器自己拉流，再测一次既污染速度值又白抢带宽。
        if (resolutionOnly) {
          logResolution();
          logSpeed(
            resolutionOnlySpeed,
            resolved: testUrl,
            elapsed: stopwatch.elapsed,
            note: 'resolution-only',
          );
          return (
            responseTime: stopwatch.elapsed,
            speed: resolutionOnlySpeed,
            resolution: detectedResolution,
          );
        }

        if (analysis.segmentUrls.isNotEmpty) {
          // 🔴 2026-10-23：延迟与速度合并为一次请求（见 [_measureSpeed] 注释）。
          // 原先这里先 [_measureLatency] 探测一次、再 [_measureSpeed] 下载一次，
          // 对同一个分片重复发两遍请求，白付一个 RTT。
          // 🔴🔴 2026-10-23（第六轮）：加密源**并发**取 AES-128 key。
          //
          // 资源站的 media playlist 普遍带 `#EXT-X-KEY`，分片是密文；
          // 要从码流读 SPS 拿真实分辨率必须先解密。
          // key 请求与分片测速**并发**发起（Future 启动后不立刻 await），
          // 因此不增加串行 RTT。
          final keyFuture = analysis.encryptionKeyUri != null
              ? _fetchAesKey(
                  analysis.encryptionKeyUri!,
                  headers: headers,
                  timeout: remaining(),
                )
              : null;

          final measurements = await Future.wait(
            analysis.segmentUrls
                .take(maxConcurrency)
                .map(
                  (u) => _measureSpeed(
                    u,
                    headers: headers,
                    maxBytes: sampleBytes,
                    measureTimeout: remaining(),
                  ),
                ),
          );

          // ��� key 与测速并发，这里取结果（早已完成或失败）。
          final aesKey = keyFuture != null ? await keyFuture : null;
          final aesIv = _hexIvToBytes(analysis.encryptionIv);
          if (measurements.any((m) => m.speed == -1.0)) {
            hasNetworkError = true;
          }
          final valid = measurements
              .where((m) => m.speed != null && m.speed! > 0)
              .toList();
          if (valid.isNotEmpty) {
            final avgSpeed =
                valid.map((m) => m.speed!).reduce((a, b) => a + b) / valid.length;
            // 取各分片中最快的首字节延迟，代表该源的最佳响应表现。
            final latencyMs = valid
                .map((m) => m.latencyMs)
                .whereType<int>()
                .fold<int?>(null, (a, b) => a == null || b < a ? b : a);

            // 🔴🔴🔴 2026-10-23（第六轮）：**从码流 SPS 读真实分辨率**（最权威）。
            //
            // 背景：资源站大量用「media playlist + AES-128 加密 TS」交付，
            // 播放列表里没有 RESOLUTION，只能靠码率反推，而**码率与分辨率没有
            // 必然关系**。实测 `play.xluuss.com` 的源：
            //   真实分辨率 1920x818（宽屏电影，1080P 级别），码率仅 661kbps
            //   → 旧口径落档到 360P（错的，同片源在另一站点的 master playlist
            //     里写着 RESOLUTION=1920x818 → 判 1080P，同一个视频两个结论）。
            //
            // SPS 里的宽高是**编码器写入的真实值**，最权威；拿到后再按
            // 「接近哪个标准档」归类（宽屏电影 1920x818 → 1080P）。
            final probeSample = valid
              .map((m) => m.probeSample)
              .firstWhere((e) => e != null, orElse: () => null);
            if (probeSample != null) {
              final probed = MediaResolutionProbe.probe(
                probeSample,
                aesKey: aesKey,
                aesIv: aesIv,
              );
              if (probed != null) {
                detectedResolution = M3u8Utils.nearestResolutionLabelFromSize(
                  probed.width,
                  probed.height,
                );
                debugPrint(
                  '[SpeedTestRes] SPS 实测分辨率: '
                  '${probed.width}x${probed.height} -> $detectedResolution'
                  '${aesKey != null ? ' (AES-128 解密后)' : ''}',
                );
              }
            }

            // 🔴 2026-10-23（第三轮）：SPS 读不到时，用「测速响应头的分片总大小
            // + 首个分片的 #EXTINF 时长」推算码率 → 分辨率（**兜底**）。
            //
            // 原来这一步要在解析阶段单独发一次 Range 请求才能拿到分片总大小，
            // 与测速请求串行叠加（高延迟源一次 RTT 就 1.5~2 秒）。
            // 现在测速请求本身就带 Range 头，响应头 `Content-Range` 的末位
            // 就是分片总大小，配合 playlist 里的分片时长即可算出码率，
            // **完全省掉这一次串行 RTT**。
            final segDuration = analysis.firstSegmentDuration;
            if (detectedResolution == null &&
                segDuration != null &&
                segDuration > 0 &&
                measurements.isNotEmpty) {
              final totalBytes = measurements.first.totalBytes;
              if (totalBytes != null && totalBytes > 0) {
                final kbps = totalBytes * 8 / (segDuration * 1000);
                detectedResolution = M3u8Utils.resolutionFromBitrateKbps(kbps);
                if (detectedResolution != null) {
                  debugPrint(
                    '[SpeedTestRes] 码率推算分辨率(兜底): '
                    '${kbps.toStringAsFixed(0)}kbps -> $detectedResolution',
                  );
                }
              }
            }

            logResolution();
            logSpeed(
              avgSpeed,
              resolved: testUrl,
              segmentCount: valid.length,
              latencyMs: latencyMs,
              elapsed: stopwatch.elapsed,
              note: 'segment-avg',
            );
            return (
              responseTime: Duration(milliseconds: latencyMs ?? -1),
              speed: avgSpeed,
              resolution: detectedResolution,
            );
          }
        } else if (!hasNetworkError) {
          // 无分片（可能是纯子 playlist），回退到 playlist URL 测速。
          //
          // 🔴 2026-10-23：网络层已经失败时**不再回退**——对连不上的源再测
          // 一次 playlist URL 只是白等一个 measureTimeout（实测 5~13 秒/源）。
          // （解析阶段抛异常时本来就会直接跳到外层 catch，这里是双保险。）
          final measured = await _measureSpeed(
            analysis.playlistUrl,
            headers: headers,
            maxBytes: 32 * 1024,
            measureTimeout: remaining(),
          );
          final speed = measured.speed;
          if (speed == -1.0) {
            hasNetworkError = true;
          } else if (measured.isText) {
            // 🔴 2026-10-23：下到的是文本（HTML 播放器页）而非媒体流，
            // 速度值无意义（见 direct 分支的说明）。
            debugPrint(
              '[SpeedTestSniff] 回退测速下到的是文本，不作为速度值: '
              '${analysis.playlistUrl}',
            );
          } else if (speed != null && speed > 0) {
            logResolution();
            logSpeed(
              speed,
              resolved: analysis.playlistUrl,
              latencyMs: measured.latencyMs,
              elapsed: stopwatch.elapsed,
              note: 'playlist-fallback',
            );
            return (
              responseTime: Duration(milliseconds: measured.latencyMs ?? -1),
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
      } on http.ClientException catch (_) {
        // 🔴 2026-10-23：ClientException（连接被对端关闭、响应头未收全）
        // 同样是网络层失败，必须置位，否则会对 playlist URL 再测一次。
        hasNetworkError = true;
        debugPrint('speedTest M3U8 解析失败（连接异常） $url');
      } catch (e) {
        debugPrint('speedTest M3U8 解析失败 $url: $e');
      }
    } else {
      // 2. 非 M3U8 源：直接对 URL 做下载测速。
      detectedResolution ??= M3u8Utils.extractResolutionFromText(url);

      // 🔴 2026-10-23：只识别分辨率模式——不做下载测速。
      if (resolutionOnly) {
        logResolution();
        logSpeed(
          resolutionOnlySpeed,
          resolved: url,
          elapsed: stopwatch.elapsed,
          note: 'resolution-only',
        );
        return (
          responseTime: stopwatch.elapsed,
          speed: resolutionOnlySpeed,
          resolution: detectedResolution,
        );
      }

      try {
        final measured = await _measureSpeed(
          url,
          headers: headers,
          maxBytes: sampleBytes,
          measureTimeout: remaining(),
        );
        final speed = measured.speed;
        if (speed == -1.0) {
          hasNetworkError = true;
        } else if (measured.isText) {
          // 🔴🔴 2026-10-23：下到的是**文本**（HTML 播放器页 / 清单），
          // 不是媒体流。这种响应的「速度」毫无意义 —— HTML 页只有 1~2KB，
          // 1ms 就传完，会算出 18MB/s 的假速度，把实际一播放就卡死的源
          // 显示成最快的源（真机实测 jinyingzy.com 就是这样）。
          //
          // 这种情况说明这个 URL 本身不是可直连播放的媒体地址，
          // 前面嗅探也没能从 HTML 里挖出 m3u8 ⇒ 按「不可用」处理。
          debugPrint(
            '[SpeedTestSniff] 响应是文本内容，不作为速度值: $url',
          );
          logResolution();
          logSpeed(
            null,
            resolved: url,
            elapsed: stopwatch.elapsed,
            note: 'text-not-media',
          );
          return (
            responseTime: stopwatch.elapsed,
            speed: null,
            resolution: detectedResolution,
          );
        } else if (speed != null && speed > 0) {
          logResolution();
          logSpeed(
            speed,
            resolved: url,
            latencyMs: measured.latencyMs,
            elapsed: stopwatch.elapsed,
            note: 'direct',
          );
          return (
            responseTime: Duration(milliseconds: measured.latencyMs ?? -1),
            speed: speed,
            resolution: detectedResolution,
          );
        }
      } catch (e) {
        debugPrint('speedTest 非 M3U8 URL 测速失败 $url: $e');
      }
    }

    // 3. 🔴 2026-10-23（第二轮调整）：**不再做可用性探测**。
    //
    // 用户明确要求：「不用可用性探测，只要能连接开始测速就是可用的」。
    //
    // 原实现测速失败后会再发一轮 HEAD + GET 探测，白等 4~8 秒，而结论
    // 与测速本身的信息高度重叠。实测真实站点：连不上的源单源耗 5~13 秒，
    // 其中大半花在这轮注定失败的探测上，直接拖慢整轮测速。
    //
    // 现在的可用性判定规则（全部由测速流程自身产生，无额外请求）：
    //   · 连上并开始下载、拿到数据 → 可用，速度为实测值
    //   · 网络层异常（TLS 握手失败 / 连接被关闭 / 超时）→ 可用但速度未知
    //     （speed = -1.0，UI 显示绿色「可用」）。沿用既有宽容策略：Dart 的
    //     网络栈与原生播放器不同，Dart 连不上不等于原生播放器播不了。
    //   · 其余情况（HTTP 错误码、内容不是 M3U8 等）→ 不可用（speed = 0.0）

    debugPrint(
      logTag(
        'resolved=$testUrl resolution=$detectedResolution (fallback)',
      ),
    );
    stopwatch.stop();
    if (hasNetworkError) {
      debugPrint('speedTest 最终判定网络层异常但可能可播放: $url');
      logSpeed(
        -1.0,
        resolved: testUrl,
        elapsed: stopwatch.elapsed,
        note: 'network-error-playable',
      );
      return (
        responseTime: stopwatch.elapsed,
        speed: -1.0,
        resolution: detectedResolution,
      );
    }
    debugPrint('speedTest 最终判定不可用: $url');
    logSpeed(
      0.0,
      resolved: testUrl,
      elapsed: stopwatch.elapsed,
      note: 'unavailable',
    );
    return (
      responseTime: stopwatch.elapsed,
      speed: 0.0,
      resolution: detectedResolution,
    );
  }

  /// 🔴 2026-10-23（第八轮）：M3U8 解析带**短重试**。
  ///
  /// 实测（Windows 真机 22:33~22:35 一轮测速）：
  /// `www.maoyanzy.com` 源 `https://play.maoyanplay.top/20260907/XZ6JZYEt/index.m3u8`
  /// 报 `ClientException: Connection closed before full header was received`，
  /// 解析直接失败 → 该源 `resolution=null`。
  /// 而**同一个 URL 用 curl 直连一次就成功**（HTTP 200，master playlist，
  /// 带 `RESOLUTION=864x368`）—— 说明是源站偶发断连，不是源失效。
  ///
  /// 问题在于：`LunaTVService._get` 有 `maxRetryCount` 重试，
  /// 但**测速的 M3U8 解析这条路径没有** —— 源站抖一下，这个源就整个
  /// 判不出分辨率（界面上的清晰度列直接空掉）。
  ///
  /// 重试策略：
  ///   · 只重试**网络层**异常（连接被关闭 / Socket / 超时 / TLS 握手）；
  ///   · HTTP 4xx/5xx 由 `analyzeM3u8ForSpeedTest` 直接返回空分片
  ///     （不抛异常），天然不会进重试 —— 403/404 重试多少次都没用；
  ///   · TLS 握手失败最多再试 1 次：实测这批源站的 HTTPS 本身是坏的
  ///     （curl 直连同样报 `unexpected eof while reading`），多试只是白等；
  ///   · 每次尝试都用**剩余预算**做超时，预算不够就放弃重试；
  ///   · 退避 250ms / 500ms，期间检查取消令牌。
  ///
  /// 复用同一个 [client]：连接池复用省掉重复 TLS 握手，
  /// 对高延迟源尤其划算。
  static Future<M3u8Analysis> _analyzeM3u8WithRetry(
    String url, {
    required Map<String, String> headers,
    required int maxSegments,
    required http.Client client,
    required DateTime deadline,
    SpeedTestCancelToken? cancelToken,
  }) async {
    Duration left() {
      final l = deadline.difference(DateTime.now());
      return l.isNegative ? Duration.zero : l;
    }

    const maxAttempts = 3;
    Object? lastError;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (cancelToken?.isCancelled ?? false) {
        throw TimeoutException('测速已取消', left());
      }
      final budget = left();
      if (budget <= Duration.zero) break;

      try {
        return await M3u8Utils.analyzeM3u8ForSpeedTest(
          url,
          headers: headers,
          maxSegments: maxSegments,
          client: client,
          // 🔴 2026-10-23（第三轮）：解析阶段**不再发码率估算请求**，
          // 解析超时收紧到「整源剩余预算」之内。
          //
          // 原来这里固定 8 秒、测速固定 12 秒，两者串起来最多 20 秒，
          // 而外层硬超时只有 8 秒 → 必然「外层放弃、内层还在跑」。
          // 现在解析只能用剩余预算，测速同样，保证整源在 timeout 内收口。
          timeout: budget,
        );
      } catch (e) {
        lastError = e;
        // TLS 握手失败：源站 HTTPS 本身坏了（curl 同样失败），最多再试 1 次。
        final maxForError = (e is HandshakeException) ? 2 : maxAttempts;
        if (attempt >= maxForError) break;
        if (!_isTransientNetworkError(e)) break;

        final backoff = Duration(milliseconds: 250 * attempt);
        // 剩余预算不够「退避 + 至少 1 秒解析」就不再试了。
        if (left() <= backoff + const Duration(seconds: 1)) break;

        debugPrint(
          '[SpeedTestRes] M3U8 解析第$attempt 次失败($e)，'
          '${backoff.inMilliseconds}ms 后重试: $url',
        );
        await Future.delayed(backoff);
      }
    }
    throw lastError ?? StateError('M3U8 解析失败且无异常信息: $url');
  }

  /// 判断异常是否属于**值得重试**的网络层抖动。
  ///
  /// 包含：连接被对端关闭（ClientException）、Socket 错误、
  /// 超时、TLS 握手失败。
  /// 不包含：HTTP 状态码错误（解析阶段不会抛）、其它编程错误。
  static bool _isTransientNetworkError(Object e) =>
      e is SocketException ||
      e is http.ClientException ||
      e is TimeoutException ||
      e is HandshakeException;

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
