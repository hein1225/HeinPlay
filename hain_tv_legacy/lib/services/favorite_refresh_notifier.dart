import 'dart:collection';
import 'package:flutter/foundation.dart';

/// 收藏变更通知器。
///
/// 收藏在本地修改后应立即通知所有监听页面刷新，
/// 远程同步由调用方在后台自行完成。
class FavoriteRefreshNotifier {
  FavoriteRefreshNotifier._();

  static final FavoriteRefreshNotifier instance = FavoriteRefreshNotifier._();

  final ListQueue<VoidCallback> _listeners = ListQueue<VoidCallback>();

  /// 注册回调，当收藏发生变化时调用。
  void addListener(VoidCallback listener) {
    if (!_listeners.contains(listener)) {
      _listeners.add(listener);
    }
  }

  /// 移除已注册的回调。
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// 触发刷新通知。
  void notify() {
    for (final listener in _listeners.toList()) {
      listener();
    }
  }
}
