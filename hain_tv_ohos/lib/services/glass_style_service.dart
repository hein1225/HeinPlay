import 'package:flutter/widgets.dart';

import 'package:hain_tv/services/user_data_service.dart';

/// 磨砂玻璃透明度档位（强 / 中 / 弱 / 关）。
///
/// 同时作用于「底部磨砂导航栏」与「分类页顶部分类导航」。用户可在
/// 「软件主题设置」中切换。档位越高磨砂感越强、Blur 计算开销越大，
/// 设置页会提示「影响软件使用性能」。
enum GlassLevel {
  /// 强：磨砂感最强，BackgroundBlur 开销最大。
  strong,

  /// 中：默认档，兼顾磨砂观感与性能。
  medium,

  /// 弱：最透明，Blur 开销最小。
  weak,

  /// 关：关闭磨砂，回退纯色背景（零 Blur 开销）。
  off,
}

extension GlassLevelX on GlassLevel {
  String get label => switch (this) {
    GlassLevel.strong => '强',
    GlassLevel.medium => '中',
    GlassLevel.weak => '弱',
    GlassLevel.off => '关',
  };

  /// 磨砂是否开启（= 是否生成 BackdropFilter）。
  bool get enabled => this != GlassLevel.off;

  /// 高斯模糊半径（逻辑像素），仅 [enabled] 时有意义。
  double get sigma => switch (this) {
    GlassLevel.strong => 16,
    GlassLevel.medium => 14,
    GlassLevel.weak => 11,
    GlassLevel.off => 0,
  };

  /// 半透明叠加不透明度（明亮主题），仅 [enabled] 时有意义。
  ///
  /// 【档位语义·重要】「强」= 磨砂效果最强 = **最通透**（叠加色最淡，光线透出最多）
  /// ＋ 模糊最强；「弱」= 磨砂效果最弱 = **最不透明**（叠加色最浓，最接近原来的
  /// 纯色实心栏）＋ 模糊最轻。
  ///
  /// 用户真机反馈：真磨砂上线后（内容真的从栏体下穿过），原先 0.38/0.24 的叠加色
  /// 太淡，弱档下图标与文字会被透出的海报干扰到看不清。故整体上调不透明度，
  /// 以「强」档 0.58 为基准，中、弱在其上继续加深。
  double get alphaLight => switch (this) {
    GlassLevel.strong => 0.58,
    GlassLevel.medium => 0.66,
    GlassLevel.weak => 0.74,
    GlassLevel.off => 0,
  };

  /// 半透明叠加不透明度（黑暗主题）。与 [alphaLight] 同向、整体略淡，
  /// 因为深色底本身对比度已足够，不需要压得太实。
  double get alphaDark => switch (this) {
    GlassLevel.strong => 0.50,
    GlassLevel.medium => 0.58,
    GlassLevel.weak => 0.66,
    GlassLevel.off => 0,
  };
}

/// 磨砂玻璃样式全局控制器（ChangeNotifier 单例）。
///
/// 与 `ThemeModeService` 同模式：持有当前档位、持久化到 UserDataService、
/// 变更时 `notifyListeners()` 广播。底部导航栏（MobileShell）与分类顶栏
/// （MobileCategoryScreen）监听它实时刷新；设置页切换后即时生效、无需重启。
class GlassStyleService extends ChangeNotifier {
  GlassStyleService._();

  static final GlassStyleService instance = GlassStyleService._();

  /// 底部磨砂导航栏**内容区**高度（dp），不含系统手势条安全区。
  ///
  /// 【为什么是 68】M3 `NavigationBar` 用 `CustomMultiChildLayout` 把
  /// 「选中指示器胶囊 + 图标 + 文字标签」作为一个整体垂直居中
  /// （navigation_bar.dart `_NavigationDestinationLayoutDelegate.performLayout`）。
  /// 内容块高度 = 指示器胶囊 32 + labelPadding.top 4 + 文字 16 = **52**
  /// （**最高的是指示器胶囊 32dp**，不是图标 24dp）。栏体高度必须大于该内容块，
  /// 否则胶囊/文字会贴边甚至被 `ClipRect` 裁切。实测（widget test 逐高度量取，
  /// `iconY = (H - 52) / 2`）：
  ///
  /// ```
  /// H=44 → 指示器 -4.0..28.0  裁切 4dp  ✗ 胶囊顶部被切平
  /// H=52 → 指示器  0.0..32.0  裁切 0dp  △ 刚好放下，上下零余量、贴边
  /// H=68 → 指示器  8.0..40.0  裁切 0dp  ✓ 上下各 8dp 余量（当前值）
  /// H=80 → 图标上方空白 18.0            △ Flutter 默认值，偏松
  /// ```
  ///
  /// 取 **68** 而非 52 或 80：52 虽然不裁切但内容完全贴边，视觉上背景框"不够高"；
  /// 80 是 Flutter 默认、过于松散且遮挡内容更多；68 给出对称的 8dp 呼吸余量。
  ///
  /// 【坑 1：只看图标文字会误判】44 确实是「图标 + 文字」块的零空白值，
  /// 但**选中指示器比图标上下各高 4dp**，只量图标文字就会漏掉胶囊裁切。
  ///
  /// 【坑 2：真正的「太高」根因不在数值】而在 `NavigationBar` 内置的
  /// `SafeArea` 默认 `top: true`（safe_area.dart:65-68）。导航栏原先放在 Scaffold
  /// 的 `bottomNavigationBar` 槽，该槽会以 `removeTopPadding: true` 包裹子树
  /// （scaffold.dart:3169-3171），因此吃不到状态栏高度；后来为做真磨砂把它拆进
  /// `body`（body 槽的 `removeTopPadding` 仅为 `appBar != null` → false），
  /// **状态栏高度（约 40dp）就被当作空白垫在了图标上方**。现已在 MobileShell 用
  /// `MediaQuery.removePadding(removeTop: true)` 剥掉，栏体 = 内容区 68dp +
  /// 底部手势条安全区。
  static const double navBarContentHeight = 68;

  /// 底部导航栏总高（内容区 + 手势条安全区）。供各分页滚动底部留白使用。
  static double navBarTotalHeight(BuildContext context) =>
      navBarContentHeight + MediaQuery.paddingOf(context).bottom;

  /// 当前档位，默认「关」。真实值由 [load] 从磁盘读取后覆盖。
  ///
  /// 【2026-10-07 变更】默认由「中」改为「关」：磨砂玻璃走高斯模糊实时渲染，
  /// 对 GPU 与电量有持续开销，改为默认关闭、由用户在设置里主动开启。
  GlassLevel _level = GlassLevel.off;

  GlassLevel get level => _level;

  bool get enabled => _level.enabled;

  /// 当前档位计算出的磨砂参数（供两处磨砂层共用）。
  double get sigma => _level.sigma;
  double alphaFor({required bool isLight}) =>
      isLight ? _level.alphaLight : _level.alphaDark;
  double alphaForLight() => _level.alphaLight;
  double alphaForDark() => _level.alphaDark;

  /// 从持久化存储读取档位并广播（启动时调用一次）。
  Future<void> load() async {
    final saved = await UserDataService.getGlassLevel();
    if (saved != _level) {
      _level = saved;
      notifyListeners();
    }
  }

  /// 切换档位：写盘并广播。不限层次，可即时多次调用（幂等：与当前相同则跳过）。
  Future<void> setLevel(GlassLevel level) async {
    if (level == _level) return;
    _level = level;
    notifyListeners();
    await UserDataService.saveGlassLevel(level);
  }
}
