import 'package:flutter/foundation.dart';

import 'user_data_service.dart';

/// 应用运行态服务：区分「游客态」与「服务器态」。
///
/// 背景（2026-10-31，AppGallery 上架整改）：原版本必须先登录 LunaTV 服务器
/// 才能进入应用，审核员没有服务器账号 → 审核不通过。整改后服务器登录改为
/// **非必需**：未配置/未登录服务器也能进入应用使用本地能力（本地播放记录、
/// 本地直播源），只是不展示任何影视海报、分类页不展示影视分类。
///
/// 判定口径与原登录态判定保持一致（[UserDataService.isLoggedIn]，即是否持有
/// 有效 Cookie），因此对已登录用户的行为**完全不变**。
class AppModeService extends ChangeNotifier {
  AppModeService._();

  static final AppModeService instance = AppModeService._();

  /// 当前是否处于游客态（未登录服务器）。
  ///
  /// 初始值为 true（游客），只有 [refresh] 读到登录态后才会纠正，
  /// 避免首帧闪回「服务器态」再退回游客态。
  bool _guest = true;

  bool get isGuest => _guest;

  /// 是否已连接服务器（等价于「非游客态」）。
  bool get hasServer => !_guest;

  /// 读取当前登录态并刷新游客态标记；有变化时通知监听者。
  ///
  /// 返回 true 表示当前为游客态。
  Future<bool> refresh() async {
    final loggedIn = await UserDataService.isLoggedIn();
    return _applyGuest(!loggedIn);
  }

  /// 直接设置游客态（供登录成功 / 退出登录等场景使用）。
  void setGuest(bool guest) {
    _applyGuest(guest);
  }

  bool _applyGuest(bool guest) {
    if (_guest == guest) return guest;
    _guest = guest;
    notifyListeners();
    return guest;
  }
}
