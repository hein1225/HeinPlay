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
    final client = LunaTVService.createApiClient();
    try {
      final response = await client.get(uri, headers: {
        'User-Agent': AppInfoService.userAgent,
      }).timeout(_testTimeout);
      stopwatch.stop();
      final ok = response.statusCode == 200 || response.statusCode == 401;
      return (
        url: url,
        latencyMs: stopwatch.elapsedMilliseconds,
        reachable: ok,
      );
    } catch (_) {
      return (
        url: url,
        latencyMs: _testTimeout.inMilliseconds,
        reachable: false,
      );
    } finally {
      client.close();
    }
  }

  /// 对 [primary] 和 [backup] 进行延迟测速，返回并保存延迟最低的可达地址。
  /// 所有地址均不可达时回退到 [primary]。
  static Future<String> selectBestServer(String primary, String? backup) async {
    final candidates = <String>[primary];
    if (backup != null && backup.trim().isNotEmpty && backup.trim() != primary) {
      candidates.add(backup.trim());
    }

    final results = await Future.wait(candidates.map(_testOne));
    final reachable = results.where((r) => r.reachable).toList();
    if (reachable.isEmpty) {
      await UserDataService.saveLastSelectedServerUrl(primary);
      return primary;
    }

    reachable.sort((a, b) => a.latencyMs.compareTo(b.latencyMs));
    final best = reachable.first.url;
    await UserDataService.saveLastSelectedServerUrl(best);
    return best;
  }
}
