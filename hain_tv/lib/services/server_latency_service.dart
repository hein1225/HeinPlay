import 'dart:async';

import 'app_info_service.dart';
import 'lunatv_service.dart';
import 'user_data_service.dart';

/// 服务器延迟测速服务，用于在主/备用服务器地址之间自动选择延迟最低的地址。
class ServerLatencyService {
  static const Duration _testTimeout = Duration(seconds: 5);

  static Future<({String url, int latencyMs, bool reachable})> _testOne(
    String url,
  ) async {
    final base = url.trim().replaceAll(RegExp(r'/+$'), '');
    final uri = Uri.parse('$base/api/playrecords?limit=1');
    final stopwatch = Stopwatch()..start();
    final client = await LunaTVService.createApiClient();
    try {
      final response = await client.get(uri, headers: {
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
      client.close();
    }
  }

  /// 对 [primary] 和 [backup] 进行延迟测速，返回并保存第一个可达的地址。
  ///
  /// 改为竞争模式：所有候选地址同时发起请求，只要有一个返回 200/401
  /// 立即采用该地址，不再等待其他地址的超时，显著加快双服务器场景下
  /// 的启动速度。所有地址均不可达时回退到 [primary]。
  static Future<String> selectBestServer(String primary, String? backup) async {
    final candidates = <String>[primary];
    if (backup != null && backup.trim().isNotEmpty && backup.trim() != primary) {
      candidates.add(backup.trim());
    }

    if (candidates.length == 1) {
      await UserDataService.saveLastSelectedServerUrl(primary);
      return primary;
    }

    final completer = Completer<String>();
    var pending = candidates.length;

    void onResult(({String url, int latencyMs, bool reachable}) result) {
      if (completer.isCompleted) return;
      if (result.reachable) {
        completer.complete(result.url);
        return;
      }
      pending--;
      if (pending == 0) {
        // 全部失败，回退到 primary
        completer.complete(primary);
      }
    }

    for (final url in candidates) {
      _testOne(url).then(onResult, onError: (_) {
        onResult((
          url: url,
          latencyMs: _testTimeout.inMilliseconds,
          reachable: false,
        ));
      });
    }

    final best = await completer.future;
    await UserDataService.saveLastSelectedServerUrl(best);
    return best;
  }
}
