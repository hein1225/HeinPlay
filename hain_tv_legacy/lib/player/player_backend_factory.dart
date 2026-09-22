import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;

import '../services/user_data_service.dart';
import 'fvp_backend.dart';
import 'video_player_backend.dart';

/// tvLegacy 专用播放后端工厂：**唯一后端为 fvp（libmdk/ffmpeg）**。
///
/// 与主工程（hain_tv）的差异——本副本已摘除另外两个后端：
/// - **ExoPlayer**（`video_player_android` + media3）：media3 的 AAR 声明 minSdk 23，
///   而 tvLegacy 目标是 Android 5.0(API 21)+，是运行时 NoClassDefFoundError 的风险源；
/// - **VLC**（`vlc_player`）：只有 Windows 实现，Android 构建无意义。
///
/// [PlayerBackendType] 枚举仍保留 `exo` / `vlc` 两个值，用途仅为：
/// 1. 兼容用户历史保存的设置字符串（`PlayerBackendType.values.firstWhere` 解析）；
/// 2. 让既有 UI / 远端控制页面的 switch 分支无需改动即可编译。
/// 但 [create] 一律返回 fvp，[availableBackends] 恒为 `[fvp]`，
/// 因此旧设置项会在首次启动时被自动纠正并写回（见 [createDefault]）。
class PlayerBackendFactory {
  /// 注册 fvp（libmdk/ffmpeg 网络栈）为唯一播放平台实现。
  ///
  /// fvp 用 ffmpeg 网络栈，能连部分 ExoPlayer(OkHttp) 无法连通的 IPTV 域名。
  /// 调用后 `VideoPlayerPlatform.instance` 即被替换为 MDK 实现，
  /// 所有基于 `video_player` 的控制器（点播 / 直播 / 回放）都走 fvp。
  static void _registerFvp() {
    if (Platform.isAndroid) {
      fvp.registerWith(options: {
        'platforms': ['android'],
        'lowLatency': 1,
        // ⚠️ 让 seek 走「快速定位」（2026-09-20 定稿根因）：
        // fvp 包内部 `_seekFlags` 默认 = fromStart|inCache（1026），**缺少
        // KeyFrame(=Fast, 256) 标志**，于是 libmdk 退化为「精确 seek」——必须
        // 从关键帧起逐帧解码到目标位置才停。对 HLS 远距离 seek（点播续播定位到
        // 第 109 秒）等于要下载+解码前 109 秒全部内容，表现为长时间冻结。
        // 实证：16:34 日志中 seek 到 109560ms 后，8.8 秒只推进 620ms。
        // libmdk 默认标志 MDK_SeekFlag_Default=1282 本就含 KeyFrame，这里补上，
        // seek 会跳到目标附近的关键帧即刻可播。代价：定位精度为一个 GOP（1~4s）。
        'fastSeek': true,
        // MDK 全局选项。avformat 值语法为 key1=val1:key2=val2...（冒号分隔），
        // 之前误用逗号导致选项未生效。lowLatency=1 已由 fvp 内部自动设置
        // avformat.fflags=+nobuffer、fpsprobesize=0、analyzeduration=100000，
        // 这里只保留 TLS 校验关闭（兼容自签/非标准端口 IPTV 源）。
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    } else if (Platform.operatingSystem == 'ohos') {
      // 鸿蒙（OHOS）没有 Android 运行时，视频层同样只用 fvp（官方支持 OHOS 5.0+，
      // 经 OpenGL 渲染）。tvLegacy 不构建鸿蒙，此处保留以兼容共享代码路径。
      fvp.registerWith(options: {
        'platforms': ['ohos'],
        'lowLatency': 1,
        // 同 Android：补 KeyFrame(=Fast) 标志，避免 libmdk 精确 seek 逐帧解码卡死。
        'fastSeek': true,
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    }
  }

  /// 创建播放后端。**恒返回 fvp**；`type` 仅用于兼容调用方签名。
  static VideoPlayerBackend create(PlayerBackendType type) {
    _registerFvp();
    return FvpBackend();
  }

  /// 平台默认后端：恒为 fvp（本工程不再有 ExoPlayer / VLC 运行时）。
  static PlayerBackendType get platformDefault => PlayerBackendType.fvp;

  /// 直播默认后端：恒为 fvp。
  static PlayerBackendType get platformLiveDefault => PlayerBackendType.fvp;

  /// 可供用户切换的播放后端列表：恒为 `[fvp]`。
  ///
  /// 设置页据此渲染选项，因此「点播设置 / 直播设置」的播放器一栏
  /// 会自动收敛为只剩 FVP 一项，无需改动页面代码。
  static List<PlayerBackendType> get availableBackends =>
      const [PlayerBackendType.fvp];

  static Future<VideoPlayerBackend> createDefault() async {
    var type = await UserDataService.getPlayerBackend();
    // 若全局设置中的后端在本工程不可用（历史残留的 exo / vlc），
    // 回退到 fvp 并把设置写回，避免每次启动都命中这条分支。
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
    // 若某个视频单独保存的后端在本工程不可用，回退到 fvp。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackendForVideo(source, id, type);
    }
    return create(type);
  }
}
