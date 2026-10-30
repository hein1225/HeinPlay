import 'package:flutter/material.dart';

/// 隐藏滚动条，但**完整保留滚动能力**（鼠标滚轮 / 触控板 / 键盘均可滚）。
///
/// ## 为什么要它
///
/// Flutter 的 `MaterialScrollBehavior.buildScrollbar` 在**桌面平台**
/// （`TargetPlatform.windows` / `linux` / `macOS`）会**无条件**给所有
/// 滚动视图挂一个常驻滚动条；移动端才是「滚动时才淡出」。
/// 于是 Windows / Linux 桌面版上，凡是内容高度超过视口的滚动区域
/// （典型如登录页：底部「后续可在我的-设置中补充或修改服务器地址」一行
/// 在窗口不够高时就会溢出）都会出现一条常驻的细竖条，视觉上很突兀。
///
/// `ThemeData.scrollbarTheme` 只决定滚动条**长什么样**，不决定**显不显示**
/// —— 显示与否由 `ScrollBehavior` 决定，所以必须在滚动视图的**祖先**
/// 用 `ScrollConfiguration` 关掉。
///
/// ## 用法
///
/// ```dart
/// HiddenScrollbar(
///   child: SingleChildScrollView(child: ...),
/// )
/// ```
///
/// 注意：`ScrollConfiguration` 是 `InheritedWidget`，只对其**子树**生效，
/// 必须包在滚动视图的**外面**（祖先方向）。
class HiddenScrollbar extends StatelessWidget {
  const HiddenScrollbar({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ScrollConfiguration(
      // copyWith 定义在 ScrollBehavior 上（不是 ScrollConfiguration），
      // scrollbars: false 表示不给滚动视图挂常驻滚动条。
      behavior: const ScrollBehavior().copyWith(scrollbars: false),
      child: child,
    );
  }
}
