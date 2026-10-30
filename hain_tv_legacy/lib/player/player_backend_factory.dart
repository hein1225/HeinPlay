import '../services/user_data_service.dart';
import 'mpv_backend.dart';
import 'video_player_backend.dart';

/// tvLegacy 专用播放后端工厂：**唯一后端为 mpv（官方内核 + 自写壳）**。
///
/// 【本轮变更】本工程原先唯一后端是 **fvp（libmdk/ffmpeg）**，现整体替换为
/// **mpv**（官方 mpv 源码经本工程 `.mpv-android/` 交叉编译的 `libmpv.so`
/// + 自写 Kotlin/JNI 壳，见 `mpv_backend.dart`）。替换动因：
/// - fvp 的 libmdk 在低端 v7 老设备上 seek/续播卡死问题长期依赖 App 层自愈，
///   而 mpv 的 `start` 选项在加载时即定位，从根上规避该缺陷；
/// - 与鸿蒙版、主工程保持同一套「自编译壳 + 官方内核」路线，便于三端对搬。
///
/// 与主工程（hain_tv）的差异——本副本已摘除另外三个后端：
/// - **ExoPlayer**（`video_player_android` + media3）：media3 的 AAR 声明 minSdk 23，
///   而 tvLegacy 目标是 Android 5.0(API 21)+，是运行时 NoClassDefFoundError 的风险源；
/// - **VLC**（`vlc_player`）：只有 Windows 实现，Android 构建无意义；
/// - **fvp**（libmdk）：本轮移除，见上。
///
/// **本工程明确不含**「HLS 并发分片预取」等吃性能的功能（那是鸿蒙版专有，
/// 后续只移植到主工程 hain_tv/）。tvLegacy 面向 Android 5.0(API 21) 的老旧
/// v7 设备，性能预算紧张，故刻意保持播放链路精简。
///
/// [PlayerBackendType] 枚举保留 `exo` / `fvp` / `vlc` 三个历史值，用途仅为：
/// 1. 兼容用户历史保存的设置字符串（`PlayerBackendType.values.firstWhere` 解析）；
/// 2. 让既有 UI / 远端控制页面的 switch 分支无需改动即可编译。
/// 但 [create] 一律返回 mpv，[availableBackends] 恒为 `[mpv]`，
/// 因此旧设置项会在首次启动时被自动纠正并写回（见 [createDefault]）。
class PlayerBackendFactory {
  /// 创建播放后端。**恒返回 mpv**；`type` 仅用于兼容调用方签名。
  ///
  /// 历史值 `fvp` / `exo` / `vlc` 走到此处时统一回退为 mpv，
  /// 避免旧设置导致「选了后端却播不了」。
  ///
  /// 渲染路线固定为纹理（安卓 SurfaceView 路线不可实现，见 [MpvBackend] 类文档）。
  static VideoPlayerBackend create(PlayerBackendType type) {
    return MpvBackend();
  }

  /// 平台默认后端：恒为 mpv（本工程不再有 fvp / ExoPlayer / VLC 运行时）。
  static PlayerBackendType get platformDefault => PlayerBackendType.mpv;

  /// 直播默认后端：恒为 mpv。
  static PlayerBackendType get platformLiveDefault => PlayerBackendType.mpv;

  /// 可供用户切换的播放后端列表：恒为 `[mpv]`。
  ///
  /// 设置页据此渲染选项，因此「点播设置 / 直播设置」的播放器一栏
  /// 会自动收敛为只剩 MPV 一项，无需改动页面代码。
  static List<PlayerBackendType> get availableBackends => const [
    PlayerBackendType.mpv,
  ];

  static Future<VideoPlayerBackend> createDefault() async {
    var type = await UserDataService.getPlayerBackend();
    // 若全局设置中的后端在本工程不可用（历史残留的 exo / fvp / vlc），
    // 回退到 mpv 并把设置写回，避免每次启动都命中这条分支。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackend(type);
    }
    return create(type);
  }

  static Future<VideoPlayerBackend> createForLive() async {
    var type = await UserDataService.getLivePlayerBackend();
    if (!availableBackends.contains(type)) {
      type = platformLiveDefault;
      await UserDataService.saveLivePlayerBackend(type);
    }
    return create(type);
  }

  static Future<VideoPlayerBackend> createForVideo(
    String source,
    String id,
  ) async {
    final fallback = await UserDataService.getPlayerBackend();
    var type = await UserDataService.getPlayerBackendForVideo(
      source,
      id,
      fallback: fallback,
    );
    // 若某个视频单独保存的后端在本工程不可用，回退到 mpv。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackendForVideo(source, id, type);
    }
    return create(type);
  }
}
