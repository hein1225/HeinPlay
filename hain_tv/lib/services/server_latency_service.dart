import 'dart:async';
import 'dart:io';

import 'app_info_service.dart';
import 'lunatv_service.dart';
import 'user_data_service.dart';

/// 服务器延迟测速服务，用于在主/备用服务器地址之间自动选择延迟最低的地址。
class ServerLatencyService {
  static const Duration _testTimeout = Duration(seconds: 5);

  /// 创建测速专用独立 HTTP 客户端。
  ///
  /// 该客户端不进入 [LunaTVService] 共享客户端池（共享客户端 close 为空操作且
  /// 被全局复用），而是每次测速各自持有，以便落败方连接可被 [HttpClient.close]
  /// 强制中止，实现「谁先响应就选谁、其余立即终止」而非「等两个都连上才选」。
  static HttpClient _createTestClient() {
    final client = HttpClient();
    if (Platform.isWindows) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
      client.findProxy = (uri) => 'DIRECT';
    }
    client.idleTimeout = _testTimeout;
    return client;
  }

  static Future<({String url, int latencyMs, bool reachable})> _testOne(
    HttpClient client,
    String url,
  ) async {
    final base = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/api/playrecords?limit=1');
    final stopwatch = Stopwatch()..start();
    try {
      final request = await client.getUrl(uri);
      request.headers.set('User-Agent', AppInfoService.userAgent);
      request.headers.set('Host', uri.host);
      // 观察底层 future，避免 force-close 中止时产生未处理异常。
      final closeFut = request.close();
      closeFut.catchError((_) => Completer<HttpClientResponse>().future);
      late final HttpClientResponse response;
      try {
        response = await closeFut.timeout(_testTimeout);
      } on TimeoutException {
        return (
          url: url,
          latencyMs: _testTimeout.inMilliseconds,
          reachable: false,
        );
      }
      stopwatch.stop();
      final ok = response.statusCode == 200 || response.statusCode == 401;
      try {
        await response.drain<void>();
      } catch (_) {}
      return (url: url, latencyMs: stopwatch.elapsedMilliseconds, reachable: ok);
    } catch (e) {
      // IPv6 优先模式失败时，尝试系统自动 DNS 选择。
      if (LunaTVService.isNetworkUnreachable(e)) {
        final dnsPreference =
            await UserDataService.getInternetServerDnsPreference();
        if (dnsPreference == InternetServerDnsPreference.ipv6) {
          final autoClient = await LunaTVService.createApiClient(
            forceAutoDns: true,
          );
          try {
            final response = await autoClient.get(uri, headers: {
              'User-Agent': AppInfoService.userAgent,
              'Host': uri.host,
            }).timeout(_testTimeout);
            stopwatch.stop();
            final ok = response.statusCode == 200 || response.statusCode == 401;
            return (
              url: url,
              latencyMs: stopwatch.elapsedMilliseconds,
              reachable: ok,
            );
          } catch (_) {
            // 兜底失败，返回不可达。
          } finally {
            autoClient.close();
          }
        }
      }
      return (
        url: url,
        latencyMs: _testTimeout.inMilliseconds,
        reachable: false,
      );
    } finally {
      // 强制关闭底层连接，中止任何仍在飞的请求（无论本候选是否胜出）。
      client.close(force: true);
    }
  }

  /// 对 [primary] 和 [backup] 进行延迟测速，返回并保存第一个可达的地址。
  ///
  /// 竞争模式：所有候选地址同时发起请求，一旦某地址返回 200/401，
  /// 立即采用该地址并**强制中止其余候选的在飞连接**（而非等它们各自超时），
  /// 显著加快双服务器场景下的启动速度。所有地址均不可达时回退到 [primary]。
  static Future<String> selectBestServer(String primary, String? backup) async {
    final candidates = <String>[primary];
    if (backup != null && backup.trim().isNotEmpty && backup.trim() != primary) {
      candidates.add(backup.trim());
    }

    if (candidates.length == 1) {
      await UserDataService.saveLastSelectedServerUrl(primary);
      return primary;
    }

    final clients = <String, HttpClient>{};
    final completer = Completer<String>();
    var pending = candidates.length;

    void cancelLosers(String winner) {
      for (final entry in clients.entries) {
        if (entry.key != winner) {
          // 胜出方已定，立即中止其余候选的 TCP/TLS 握手，避免空占连接。
          entry.value.close(force: true);
        }
      }
    }

    void onResult(({String url, int latencyMs, bool reachable}) result) {
      if (completer.isCompleted) return;
      if (result.reachable) {
        completer.complete(result.url);
        cancelLosers(result.url);
        return;
      }
      pending--;
      if (pending == 0) {
        // 全部失败，回退到 primary
        completer.complete(primary);
      }
    }

    for (final url in candidates) {
      final client = _createTestClient();
      clients[url] = client;
      _testOne(client, url).then(onResult, onError: (_) {
        onResult((
          url: url,
          latencyMs: _testTimeout.inMilliseconds,
          reachable: false,
        ));
      });
    }

    final best = await completer.future;
    // 兜底关闭所有仍存活的客户端（胜出方已在 _testOne.finally 中关闭）。
    for (final client in clients.values) {
      client.close(force: true);
    }
    await UserDataService.saveLastSelectedServerUrl(best);
    return best;
  }
}
