import 'dart:async';
import 'dart:io';

import '../platform/device_utils.dart';
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
    // 电脑版（Windows/Linux）统一放宽证书校验并直连：Dart 自带 BoringSSL 在两端
    // 对自签名/非标准证书链表现一致，且桌面端可能受系统代理干扰，测速需直连才准。
    if (DeviceUtils.isComputer) {
      client.badCertificateCallback =
          (X509Certificate cert, String host, int port) => true;
      client.findProxy = (uri) => 'DIRECT';
    }
    client.idleTimeout = _testTimeout;
    // 🔴🔴 2026-10-16 修复「模拟器/无内网环境启动卡死」：
    //   `idleTimeout` 只管**已建立连接**的空闲回收，**不是 TCP 建连超时**。
    //   缺少 `connectionTimeout` 时，若目标地址被网络隔离（模拟器 NAT 访问
    //   不到局域网 NAS，或路由器把 SYN 静默丢弃），`client.getUrl(uri)`
    //   会一直挂起 —— 既不返回也不抛错，直到系统级超时（可达数分钟）。
    //
    //   这正是「打不开软件」的根因链路：
    //     splash 的 _initializeApp 串行 await →
    //     ServerLatencyService.selectBestServer（主备地址不同才测速）→
    //     _testOne → `await client.getUrl(uri)`（**此处原无超时**）→ 永久挂起。
    //   `_testOne` 里给 `request.close()` 加的 `.timeout(_testTimeout)` 位置
    //   偏后：TCP 连不上时根本走不到那一行，5 秒超时从未生效；外层
    //   `try/catch` 也只捕获异常，挡不住「永不完成」。
    //
    //   设 `connectionTimeout` 后，建连阶段即被约束在 5 秒内失败并抛
    //   SocketException，后续既有的超时/兜底逻辑才能正常接管。
    client.connectionTimeout = _testTimeout;
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
      // 🔴🔴 2026-10-16：给 `getUrl` 补显式超时（第二层防护）。
      //   `_createTestClient()` 已设 `connectionTimeout`，正常情况下建连
      //   5 秒内必失败；这里再加一层，覆盖 `connectionTimeout` 也约束不到的
      //   情形（如 DNS 解析阶段挂起、代理协商卡住、某些平台忽略该字段）。
      //   超时后统一按「不可达」返回，交由 `selectBestServer` 回退 primary，
      //   绝不让 splash 的串行 await 卡住。
      final request = await client.getUrl(uri).timeout(_testTimeout);
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
