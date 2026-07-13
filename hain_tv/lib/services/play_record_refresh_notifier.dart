import 'package:flutter/foundation.dart';

/// 播放记录变更通知器。
///
/// 播放记录保存到本地后立即通知所有监听页面（首页、我的等）刷新，
/// 避免播放退出后相关页面仍展示旧记录。
class PlayRecordRefreshNotifier extends ChangeNotifier {
  PlayRecordRefreshNotifier._();

  static final PlayRecordRefreshNotifier instance =
      PlayRecordRefreshNotifier._();

  void notify() => notifyListeners();
}
