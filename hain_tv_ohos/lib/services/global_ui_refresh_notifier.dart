import 'package:flutter/foundation.dart';

/// 全局 UI 刷新通知器。
///
/// 手机控制（远程设置服务）修改设置后，通过本通知器广播「需要刷新」事件，
/// App 根（TV / 桌面）监听后在原地 [setState] 重建 [MaterialApp]，使正在运行的
/// 页面按最新 [UserDataService] 值重新读取并即时反映，无需用户手动返回重进。
class GlobalUiRefreshNotifier extends ChangeNotifier {
  static final GlobalUiRefreshNotifier instance =
      GlobalUiRefreshNotifier._();

  GlobalUiRefreshNotifier._();

  /// 累计刷新次数，监听者可用其判断是否有新变更。
  int _version = 0;
  int get version => _version;

  /// 通知所有监听者：设置已变更，请刷新 UI。
  void notify() {
    _version++;
    notifyListeners();
  }
}
