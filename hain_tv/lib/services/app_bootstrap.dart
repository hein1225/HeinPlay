/// 应用启动引导状态。
///
/// 用于区分「首次冷启动」与「运行期主题切换导致的整树重建」：主题切换时若重建
/// [Navigator]，初始路由应直接落到载入页实际跳转的目标（首页或登录页），
/// 避免重新走载入页（SplashScreen）与重复初始化，也不会把已停在登录页的用户
/// 错误踢回首页。
class AppBootstrap {
  AppBootstrap._();

  /// 载入页完成初始化并跳转后置为 true。
  static bool _completed = false;

  /// 是否已引导完成（载入页已离开）。
  static bool get completed => _completed;

  /// 载入页实际跳转的目标路由（'/home' 或 '/login'）。
  static String _initialRoute = '/home';

  /// 运行期重建 Navigator 时使用的初始路由。
  static String get initialRoute => _initialRoute;

  /// 标记引导完成并记录跳转目标路由。由 [SplashScreen] 在跳转前调用一次。
  static void markCompleted(String route) {
    _initialRoute = route;
    _completed = true;
  }
}
