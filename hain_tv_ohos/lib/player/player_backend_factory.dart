import 'dart:io';

import 'package:video_player_ohos/video_player_ohos.dart' show OhosVideoPlayer;
import 'package:video_player_platform_interface/video_player_platform_interface.dart'
    show VideoPlayerPlatform;

import '../services/user_data_service.dart';
import 'avplayer_backend.dart';
import 'mpv_backend.dart';
import 'video_player_backend.dart';
import 'video_render_mode.dart';

/// 鸿蒙专用播放后端工厂：**avplayer（鸿蒙原生 AVPlayer）与 mpv（libmpv）**。
///
/// 🔴 2026-10-23：默认后端由 mpv 改为 **avplayer**（系统原生 AVPlayer），
///   mpv 退为备选。动因：avplayer 是鸿蒙系统级播放器，起播路径短、
///   兼容性最稳，与 Android 版默认走 ExoPlayer 的策略保持一致；mpv 保留作
///   非标准源 / 自签证书 / 硬解偏好用户的备选。
///
/// 🔴 2026-10-06：fvp（libmdk/ffmpeg）已从鸿蒙侧彻底移除。
/// mpv-arkts 在真机验证通过：硬解 ohcodec + ohaudio + 纹理出画，点播/直播均正常，
/// 已接管 fvp 全部角色（含此前 fvp 唯一优势的「非标准源/自签证书兼容」，
/// 现由 mpv 的 `tls_verify=0` 等价项 + 去广告代理承担）。
///
/// 鸿蒙可用后端（[availableBackends]）：
/// - [avplayer]：**默认**，系统原生 AVPlayer，起播快、兼容性最稳。
/// - [mpv]：备选，基于 @mpv-ohos/mpv-arkts 的 libmpv 封装，硬解、续播语义正确。
///
/// [PlayerBackendType] 枚举保留 `exo` / `vlc` / `fvp` 三个值，用途仅为：
/// 1. 兼容用户历史保存的设置字符串（`PlayerBackendType.values.firstWhere` 解析）；
/// 2. 让既有 UI / 远端控制页面的 switch 分支无需改动即可编译。
/// 但 [create] 对这三个值一律回落到 [mpv]（见 create 的归一化与 availableBackends）。
class PlayerBackendFactory {
  /// 在 HarmonyOS 上注册 avplayer（video_player_ohos），使其接管
  /// `VideoPlayerPlatform.instance`（供 avplayer 后端使用）。
  ///
  /// mpv / erika 后端不经 video_player 体系，无需切换平台实现。
  /// 历史上 fvp 也需抢回该实例（无条件覆盖），现已随 fvp 移除而删除该分支。
  ///
  /// 因此本方法绝不能像过去那样在 [create] 开头无条件调用 —— 那样 AVPlayer 后端
  /// 把 `VideoPlayerPlatform.instance` 切到指定后端对应的实现。
  ///
  /// 背景：仅 avplayer 后端依赖 `video_player` 体系（经 video_player_ohos 提供
  /// `OhosVideoPlayer` 平台实现）；mpv 经 @mpv-ohos/mpv-arkts 原生层独立渲染，
  /// erika 自成一套播放器体系，二者都不碰 `VideoPlayerPlatform.instance`。
  ///
  /// fvp 已移除，故不再有「两个插件抢 instance」的冲突；选 avplayer 时只需确保
  /// instance 是 `OhosVideoPlayer`（若当前不是，重新注册一次把它设回去）。
  static void _ensurePlatformFor(PlayerBackendType type) {
    if (Platform.operatingSystem != 'ohos') return;
    switch (type) {
      case PlayerBackendType.avplayer:
        // 已是 AVPlayer 实现则无需重复注册（避免无谓重建 napi 通道）。
        if (VideoPlayerPlatform.instance is! OhosVideoPlayer) {
          OhosVideoPlayer.registerWith();
        }
      case PlayerBackendType.mpv:
        // mpv 不依赖 video_player 体系，无需切换平台实现。
        break;
      case PlayerBackendType.fvp:
      case PlayerBackendType.exo:
      case PlayerBackendType.vlc:
        // 历史设置值（fvp 已移除，exo/vlc 鸿蒙不可用）。create 的归一化会把它们
        // 落到 avplayer（默认后端），故此处必须按 avplayer 准备平台实现。
        if (VideoPlayerPlatform.instance is! OhosVideoPlayer) {
          OhosVideoPlayer.registerWith();
        }
        break;
    }
  }

  static VideoPlayerBackend create(
    PlayerBackendType type, {
    VideoRenderMode? renderMode,
  }) {
    // fvp / exo / vlc 均已不可用于鸿蒙（fvp 已移除、exo/vlc 鸿蒙无运行时），
    // 一律回落到 **avplayer**（默认后端）。归一化须在切换平台实现**之前**完成，
    // 否则会按未回落的type去选错后端。
    final effective = switch (type) {
      PlayerBackendType.fvp || PlayerBackendType.exo || PlayerBackendType.vlc =>
        PlayerBackendType.avplayer,
      _ => type,
    };
    // ⚠️ 顺序关键：先切平台实现，再建后端对象。
    // 后端对象内部的 VideoPlayerController 在 open() 时才读
    // VideoPlayerPlatform.instance，故此处设置必须先于 open()；
    // 放在 create() 里可保证同一后端类型下多次创建（换源、重开）行为一致。
    _ensurePlatformFor(effective);
    final backend = switch (effective) {
      PlayerBackendType.avplayer ||
      PlayerBackendType.fvp ||
      PlayerBackendType.exo ||
      PlayerBackendType.vlc =>
        AvPlayerBackend(),
      PlayerBackendType.mpv => MpvBackend(),
    };
    // 渲染方式（SurfaceView / TextureView）：由 async 入口按场景
    // （点播→vod、直播→live）传入；null 保持默认纹理。
    if (renderMode != null) {
      backend.renderMode = renderMode;
    }
    return backend;
  }

  /// 可用后端：鸿蒙为 `[avplayer, mpv]`。
  ///
  /// 设置页据此渲染选项，「点播设置 / 直播设置」的播放器一栏会出现这两项。
  /// 顺序即 UI 展示顺序：avplayer 在前（**默认**，系统原生、起播快、兼容性最稳）；
  /// mpv 在后（备选，libmpv 硬解、续播语义正确、已真机验证）。
  ///
  /// 🔴 2026-10-23：默认后端改为 avplayer，列表顺序随之调整为 `[avplayer, mpv]`。
  static List<PlayerBackendType> get availableBackends =>
      const [PlayerBackendType.avplayer, PlayerBackendType.mpv];

  /// 各平台默认后端：鸿蒙为 **avplayer**（系统原生 AVPlayer，起播快、兼容性最稳）。
  ///
  /// 🔴 2026-10-23：由 mpv 改为 avplayer。mpv 保留作备选，仅当用户显式切换时使用。
  static PlayerBackendType get platformDefault => PlayerBackendType.avplayer;

  /// 直播默认后端：鸿蒙为 **avplayer**（同上）。
  ///
  /// 🔴 2026-10-23：由 mpv 改为 avplayer。
  static PlayerBackendType get platformLiveDefault => PlayerBackendType.avplayer;

  static Future<VideoPlayerBackend> createDefault() async {
    var type = await UserDataService.getPlayerBackend();
    // 若全局设置中的后端在当前平台不可用，回退到平台默认并更新设置。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackend(type);
    }
    // 点播渲染方式（默认纹理）。
    final renderMode = await UserDataService.getVodRenderMode();
    return create(type, renderMode: renderMode);
  }

  static Future<VideoPlayerBackend> createForLive() async {
    var type = await UserDataService.getLivePlayerBackend();
    // 若直播设置中的后端在当前平台不可用，回退到直播平台默认。
    if (!availableBackends.contains(type)) {
      type = platformLiveDefault;
      await UserDataService.saveLivePlayerBackend(type);
    }
    // 直播渲染方式（默认纹理）。
    final renderMode = await UserDataService.getLiveRenderMode();
    return create(type, renderMode: renderMode);
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
    // 若某个视频单独保存的后端在当前平台不可用，回退到平台默认。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackendForVideo(source, id, type);
    }
    final renderMode = await UserDataService.getVodRenderMode();
    return create(type, renderMode: renderMode);
  }

  /// 点播场景创建后端并应用点播渲染方式（给直接调 [create] 的播放屏使用）。
  ///
  /// 🔴 2026-10-07 新增：tv/player_screen 等直接以 [PlayerBackendType] 建后端，
  ///   需要在这里把点播渲染方式一并带下去，否则 renderMode 恒为默认纹理。
  static Future<VideoPlayerBackend> createForVod(
    PlayerBackendType type,
  ) async {
    final renderMode = await UserDataService.getVodRenderMode();
    return create(type, renderMode: renderMode);
  }
}
