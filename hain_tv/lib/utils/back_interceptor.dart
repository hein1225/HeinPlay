/// 全局返回键拦截器。
///
/// 用于在 TvShell 弹出退出确认之前，先让当前页面有机会处理返回键事件。
/// 例如：CategoryScreen 打开筛选面板时，返回键应先关闭面板而非退出应用。
class BackInterceptor {
  static final List<bool Function()> _interceptors = [];

  /// 注册一个拦截器。返回 true 表示已处理，后续拦截器及退出弹窗不再执行。
  static void register(bool Function() interceptor) {
    if (!_interceptors.contains(interceptor)) {
      _interceptors.add(interceptor);
    }
  }

  /// 注销拦截器。
  static void unregister(bool Function() interceptor) {
    _interceptors.remove(interceptor);
  }

  /// 依次调用拦截器（后注册的先调用），直到有拦截器返回 true。
  /// 返回 true 表示事件已被消费。
  static bool intercept() {
    for (final interceptor in _interceptors.reversed) {
      try {
        if (interceptor()) return true;
      } catch (e) {
        // 拦截器异常不影响其他拦截器
      }
    }
    return false;
  }
}
