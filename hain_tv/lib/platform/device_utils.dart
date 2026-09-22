import 'dart:io';
import 'package:flutter/foundation.dart';

class DeviceUtils {
  static bool? _tvOverride;

  static set isTvOverride(bool value) => _tvOverride = value;

  static bool get isWeb => kIsWeb;

  static bool get isAndroid => !kIsWeb && Platform.isAndroid;

  static bool get isIOS => !kIsWeb && Platform.isIOS;

  /// 是否手机（触摸屏精简版界面）。
  ///
  /// Android TV 虽然底层是 Android，但 [isTv] 为 true，不应视为手机，
  /// 否则直播播放页等会错误地走手机精简版布局。因此这里显式排除 TV。
  static bool get isMobile => (isAndroid || isIOS) && !isTv;

  static bool get isWindows => !kIsWeb && Platform.isWindows;

  static bool get isMacOS => !kIsWeb && Platform.isMacOS;

  static bool get isLinux => !kIsWeb && Platform.isLinux;

  static bool get isDesktop => isWindows || isMacOS || isLinux;

  /// 是否为电脑版客户端（鼠标键盘操作的桌面端：Windows / Linux）。
  ///
  /// 用于区分“电脑版 UI”与“TV 版 UI”（如登录界面是否提供扫码登录、显示“电脑版”
  /// 还是“TV 版”）。TV/Android 等遥控器/触摸屏环境不应视为电脑版。
  static bool get isComputer => isWindows || isLinux;

  static bool get isTv {
    if (_tvOverride != null) return _tvOverride!;
    // 默认不视为 TV，避免 Android 手机被误判为 TV。
    // TV/Windows 入口需在 main 中显式设置 isTvOverride = true。
    return false;
  }

  /// 是否运行在 SteamOS / Bazzite 等掌机的「游戏模式」（gamescope 会话）下。
  ///
  /// 游戏模式没有常规桌面窗口管理器，应用窗口不会自动铺满屏幕，画面会被缩在
  /// 中间（Steam Deck / ONEXPLAYER 等掌机实测）。Linux 入口据此在启动时强制全屏。
  ///
  /// 判据取「会话标记」而不是任何硬件/套接字探测：
  /// - `XDG_CURRENT_DESKTOP` 含 `gamescope` —— 游戏模式的标准会话标记；
  /// - `GAMESCOPE_WAYLAND_DISPLAY` 非空 —— gamescope 组合器注入，桌面模式不设置；
  /// - `SteamGamepadUI=1` —— Steam 大屏/游戏模式专属，桌面模式不设置（2026-09-20 补）。
  ///
  /// 经掌机实测（Bazzite / ONEXPLAYER）确认这些判据可用，同时**特意不采用**
  /// 下面这些看似合理、实际会误判的依据：
  /// - `SteamDeck=1`：SteamOS 的桌面模式同样带该变量，用它会把桌面模式也全屏；
  /// - `$XDG_RUNTIME_DIR/gamescope-0` 套接字存在：桌面模式下 Steam 常驻同样会创建它。
  static bool get isSteamGameMode {
    if (kIsWeb || !Platform.isLinux) return false;
    try {
      final env = Platform.environment;
      final desktop = (env['XDG_CURRENT_DESKTOP'] ?? '').toLowerCase();
      if (desktop.contains('gamescope')) return true;
      if ((env['GAMESCOPE_WAYLAND_DISPLAY'] ?? '').isNotEmpty) return true;
      if (env['SteamGamepadUI'] == '1') return true;
      return false;
    } catch (_) {
      // 环境变量异常时按“非游戏模式”处理，不影响正常启动。
      return false;
    }
  }

  /// 会话/环境把窗口强制成全屏，且应用无法撤销（Steam 游戏模式 / gamescope）。
  ///
  /// 2026-09-20 掌机实测：游戏模式下应用**启动时窗口就已经是全屏**
  /// （`windowManager.isFullScreen()` 为 true，而应用从未主动进入全屏），
  /// 且调用 `setFullScreen(false)` 之后它仍返回 true —— 撤销无效。
  ///
  /// 此时「全屏」是环境状态而非应用内状态。若仍让播放页的 PopScope / ESC 把它当作
  /// 「按返回先退出全屏」的依据，返回键会被永久吞掉：实测 94 次返回请求 0 次成功，
  /// 直播页与点播页都退不出去。因此由 Linux 入口在启动时探测并置位，桌面端全屏
  /// 逻辑据此跳过「退全屏」这一步。
  static bool envForcedFullScreen = false;
}
