/// tvLegacy 专用 `video_player_android` 占位实现。
///
/// **本工程唯一播放后端是 fvp（libmdk/ffmpeg）。**
///
/// 真实的 `video_player_android` 会注册 ExoPlayer 实现并把 media3 一族 AAR
/// 带进构建（其声明 minSdk 23），在 Android 5.0/6.0 上存在
/// `NoClassDefFoundError` 风险。因此这里只保留一个空的注册入口：
/// Flutter 的 dart plugin registrant 会调用 [AndroidVideoPlayer.registerWith]，
/// 但故意什么都不做——播放器实例由
/// `PlayerBackendFactory._registerFvp()` 调用 `fvp.registerWith()` 接管
/// （它会替换 `VideoPlayerPlatform.instance`）。
class AndroidVideoPlayer {
  /// 故意留空：不注册 ExoPlayer，交由 fvp 接管。
  static void registerWith() {}
}
