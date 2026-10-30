import 'package:flutter/widgets.dart';

/// 全局返回键拦截器。
///
/// 用于在 TvShell 弹出退出确认之前，先让当前页面有机会处理返回键事件。
/// 例如：CategoryScreen 打开筛选面板时，返回键应先关闭面板而非退出应用。
class BackInterceptor {
  static final List<bool Function()> _interceptors = [];

  /// 「返回键已被页面自行消费」的序号。
  ///
  /// 背景：`HardwareKeyboard` 派发按键时是**遍历所有 handler、且不看其他
  /// handler 的返回值**（见 `hardware_keyboard.dart` 的 `_dispatchKeyEvent`，
  /// 循环体内只有 `handled = handled || thisResult`，不会因为 true 就 break）。
  /// 于是同一次 ESC 会先后进入：
  ///   1. `app_windows` 的全局 handler → `navigator.maybePop()`（异步）
  ///   2. 播放页自己的 handler → 同步执行「退全屏 / 关节目单 / 退回直播 / 退出播放」
  /// 第 1 步的 `maybePop` 是异步落地的，等它走到 `PopScope.onPopInvokedWithResult`
  /// 时，第 2 步已经把 `_isReplayMode` 改成 false 了 —— 于是优先级决策从
  /// 「回放 → 退回直播」直接落到最后一档「退出播放页」，用户看到的就是
  /// 「回放中按一次 ESC 直接退出播放」。
  ///
  /// 现在页面处理完返回键后调用 [markHandled] 递增序号；全局 handler 在发起
  /// `maybePop` 前记下序号，并把 `maybePop` 推迟到微任务里执行，落地时若发现
  /// 序号已变，说明本次返回键已经被页面消费，直接放弃这次 `maybePop`。
  static int _handledSerial = 0;

  /// 当前序号。全局返回键处理器用它判断「本次按键是否已被页面消费」。
  static int get handledSerial => _handledSerial;

  /// 标记「本次返回键已由页面处理完毕」，让全局 handler 不再重复 `maybePop`。
  static void markHandled() {
    _handledSerial++;
  }

  /// 「路由确实被弹出」的序号，由 [BackInterceptorObserver] 维护。
  ///
  /// [markHandled] 只能覆盖「页面自己消费了返回键但**没有弹路由**」的情况
  /// （如播放页退出回放、关闭浮层）。而多数页面是直接 `Navigator.pop()`
  /// 返回上一页 —— 它们没有（也不需要）逐页调用 [markHandled]，于是全局
  /// handler 里排队的 `maybePop` 落地时序号没变，就会**再弹一层**：
  /// 详情页按 ESC → 详情页同步 pop 回分类页 → 全局 maybePop 又把分类页弹掉
  /// → 落到根路由 → 弹出「退出确认」。用户看到的就是「返回分类页的同时
  /// 还弹出了退出弹窗」。
  ///
  /// 因此再加一条与导航栈绑定的序号：任何路由被 pop 都会递增它。全局 handler
  /// 在排队前记下该序号，微任务落地时若发现它变了，说明本次返回键已经通过
  /// 「弹路由」被消费，直接放弃这次 `maybePop`。这样所有页面都自动覆盖，
  /// 不需要逐页补 `markHandled()`。
  static int _popSerial = 0;

  /// 当前「路由被弹出」序号。
  static int get popSerial => _popSerial;

  /// 由 [BackInterceptorObserver] 在路由 pop 时调用。
  static void markPopped() {
    _popSerial++;
  }

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

/// 路由观察者：只负责把「路由被弹出」这件事记进 [BackInterceptor]。
///
/// 挂在 `MaterialApp.navigatorObservers` 上，任何页面（含 `Navigator.pop()`、
/// 系统返回、`maybePop` 自身）弹出路由都会经过 [didPop]，从而让全局返回键
/// 处理器知道「这次返回已经被消费掉了」，避免重复弹一层。
class BackInterceptorObserver extends NavigatorObserver {
  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    BackInterceptor.markPopped();
    super.didPop(route, previousRoute);
  }
}
