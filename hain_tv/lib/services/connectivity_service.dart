import 'dart:async';
import 'package:flutter/foundation.dart';
import 'app_info_service.dart';
import 'lunatv_service.dart';
import 'user_data_service.dart';

/// 服务器连接有效判定：
/// 1. 用户已登录（本地保存了 Cookie）。
/// 2. 使用 Cookie 请求 `/api/playrecords?limit=1` 返回 200。
/// 未登录或请求失败均视为未连接，避免根路径 404 等误报。

/// LunaTV 服务器连接状态服务。
///
/// 在应用启动及运行期间定期探测配置的 LunaTV 服务器是否可达，
/// 并通过 [ValueNotifier] 向各页面提供实时连接状态。
class ConnectivityService {
  ConnectivityService._();

  static final ConnectivityService instance = ConnectivityService._();

  static const Duration _checkInterval = Duration(seconds: 30);
  static const Duration _requestTimeout = Duration(seconds: 5);

  /// 当前是否已与 LunaTV 服务器建立有效连接。
  final ValueNotifier<bool> isServerConnected = ValueNotifier<bool>(true);

  /// 当前连接的服务器类型：'internet' | 'lan' | 'none'。
  final ValueNotifier<String> serverType = ValueNotifier<String>('none');

  Timer? _timer;
  bool _checking = false;
  DateTime? _lastSuccessAt;

  /// 启动周期性探测。
  void startMonitoring() {
    _timer?.cancel();
    _checkConnection();
    _timer = Timer.periodic(_checkInterval, (_) => _checkConnection());
  }

  /// 停止周期性探测。
  void stopMonitoring() {
    _timer?.cancel();
    _timer = null;
  }

  /// 立即执行一次探测。
  Future<void> checkNow() async => _checkConnection();

  /// 业务接口调用成功时主动上报，避免周期性探测失败导致状态误报为未连接。
  Future<void> reportSuccess([String? url]) async {
    _lastSuccessAt = DateTime.now();
    if (!isServerConnected.value) {
      isServerConnected.value = true;
    }

    if (url != null && url.trim().isNotEmpty) {
      final backup = await UserDataService.getBackupServerUrl();
      final normalizedUrl = url.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
      final normalizedBackup = backup.trim().toLowerCase().replaceAll(RegExp(r'/+$'), '');
      final type = normalizedBackup.isNotEmpty && normalizedUrl == normalizedBackup
          ? 'lan'
          : 'internet';
      if (serverType.value != type) {
        serverType.value = type;
      }
    }
  }

  Future<void> _checkConnection() async {
    if (_checking) return;
    _checking = true;

    try {
      // 优先使用当前选中的服务器地址（测速/手动选择后保存的地址），
      // 其次互联网服务器，最后 fallback 到局域网服务器。
      final primary = await UserDataService.getServerUrl();
      final backup = await UserDataService.getBackupServerUrl();
      final selected = await UserDataService.getLastSelectedServerUrl();
      final serverUrl = (selected != null && selected.trim().isNotEmpty)
          ? selected
          : (primary != null && primary.trim().isNotEmpty)
              ? primary
              : (backup.trim().isNotEmpty ? backup : null);
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        _updateStatus(false, 'internet');
        return;
      }

      // 必须已登录才算有效连接
      final loggedIn = await UserDataService.isLoggedIn();
      if (!loggedIn) {
        _updateStatus(false, 'internet');
        return;
      }

      final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final cookies = await UserDataService.getCookies();
      final client = LunaTVService.createApiClient();
      try {
        final response = await client
            .get(
              Uri.parse('$base/api/playrecords').replace(
                queryParameters: {
                  'limit': '1',
                  '_t': DateTime.now().millisecondsSinceEpoch.toString(),
                },
              ),
              headers: {
                'Accept': 'application/json, text/plain, */*',
                'User-Agent': AppInfoService.userAgent,
                if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
              },
            )
            .timeout(_requestTimeout);

      // 只有登录态有效且接口返回 200 才算连接成功
      var connected = response.statusCode == 200;
      // 若本次探测失败，但近期有业务接口实际调用成功，则仍保持已连接状态，
      // 避免探测 URL 与业务 URL 不一致或瞬时波动导致状态误报。
      if (!connected &&
          _lastSuccessAt != null &&
          DateTime.now().difference(_lastSuccessAt!) <= _checkInterval) {
        connected = true;
      }
      final serverType = await UserDataService.getCurrentServerType();
      _updateStatus(connected, serverType);
      return;
      } finally {
        client.close();
      }
    } catch (e) {
      // 异常失败时同样参考最近业务成功记录，避免误报未连接。
      if (_lastSuccessAt != null &&
          DateTime.now().difference(_lastSuccessAt!) <= _checkInterval) {
        final serverType = await UserDataService.getCurrentServerType();
        _updateStatus(true, serverType);
      } else {
        _updateStatus(false, 'internet');
      }
    } finally {
      _checking = false;
    }
  }

  void _updateStatus(bool connected, String type) {
    if (serverType.value != type) {
      serverType.value = type;
    }
    if (isServerConnected.value != connected) {
      isServerConnected.value = connected;
    }
  }
}
