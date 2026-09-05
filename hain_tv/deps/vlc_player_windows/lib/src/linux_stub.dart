/// Linux 占位注册类，满足 [flutter build linux] 对 vlc_player 插件平台支持的检查。
///
/// vlc_player 原生实现仅支持 Windows（[VlcPlayerPluginCApi]）。Linux 版不使用 VLC
/// 后端（播放统一走 fvp），因此这里仅提供一个空操作注册，避免构建因“插件不支持
/// linux”而失败。绝不会被实际调用到播放逻辑。
class VlcPlayerPlugin {
  /// 空操作注册。Flutter 在 Linux 上初始化插件时会调用此方法（dartPluginClass
  /// 约定为无参 registerWith()），但无原生实现需要绑定。
  static void registerWith() {
    // Linux 不支持 VLC 后端；该插件在 Linux 上不参与播放（Linux 使用 fvp）。
  }
}
