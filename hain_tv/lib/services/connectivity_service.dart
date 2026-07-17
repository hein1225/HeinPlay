import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
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

  final ValueNotifier<bool> isServerConnected = ValueNotifier<bool>(true);

  Timer? _timer;
  bool _checking = false;

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

  Future<void> _checkConnection() async {
    if (_checking) return;
    _checking = true;

    try {
      final serverUrl = await UserDataService.getServerUrl();
      if (serverUrl == null || serverUrl.trim().isEmpty) {
        _updateStatus(false);
        return;
      }

      // 必须已登录才算有效连接
      final loggedIn = await UserDataService.isLoggedIn();
      if (!loggedIn) {
        _updateStatus(false);
        return;
      }

      final base = serverUrl.trim().replaceAll(RegExp(r'/+$'), '');
      final cookies = await UserDataService.getCookies();
      final response = await http
          .get(
            Uri.parse('$base/api/playrecords').replace(
              queryParameters: {
                'limit': '1',
                '_t': DateTime.now().millisecondsSinceEpoch.toString(),
              },
            ),
            headers: {
              'Accept': 'application/json, text/plain, */*',
              'User-Agent': 'HainTV/1.1.5 Flutter',
              if (cookies != null && cookies.isNotEmpty) 'Cookie': cookies,
            },
          )
          .timeout(_requestTimeout);

      // 只有登录态有效且接口返回 200 才算连接成功
      _updateStatus(response.statusCode == 200);
    } catch (e) {
      _updateStatus(false);
    } finally {
      _checking = false;
    }
  }

  void _updateStatus(bool connected) {
    if (isServerConnected.value != connected) {
      isServerConnected.value = connected;
    }
  }
}
