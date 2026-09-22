import 'package:flutter/foundation.dart';

/// 直播源配置变更通知器。
///
/// 当用户在"软件设置"中开启/关闭 LunaTV 服务器直播源，或在直播源管理页
/// 添加、编辑、删除直播源后，立即通知所有监听页面刷新列表，无需重启应用。
class LiveSourceRefreshNotifier extends ChangeNotifier {
  LiveSourceRefreshNotifier._();

  static final LiveSourceRefreshNotifier instance = LiveSourceRefreshNotifier._();

  void notify() => notifyListeners();
}
