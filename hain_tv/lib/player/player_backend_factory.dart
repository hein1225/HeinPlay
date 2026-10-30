import 'dart:io';

import 'package:video_player_android/video_player_android.dart';

import '../services/user_data_service.dart';
import 'exo_player_backend.dart';
import 'mpv_backend.dart';
import 'mpv_desktop_backend.dart';
import 'video_player_backend.dart';
import 'vlc_backend.dart';

class PlayerBackendFactory {
  /// 在 Android 上恢复官方 ExoPlayer 平台实现（mpv 之外的兜底后端）。
  ///
  /// 某些插件可能会全局替换 [VideoPlayerPlatform.instance]，使用 ExoPlayer 前
  /// 显式恢复官方 Android 实现。
  static void _restoreAndroidVideoPlayer() {
    if (Platform.isAndroid) {
      AndroidVideoPlayer.registerWith();
    }
  }

  static VideoPlayerBackend create(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        _restoreAndroidVideoPlayer();
        return ExoPlayerBackend();
      case PlayerBackendType.mpv:
        // 🔴 官方 mpv 内核 + 自写壳。
        //   Android / TV → Kotlin/JNI（MpvBackend + MpvPlayerView.kt）
        //   桌面         → C++ 壳（MpvDesktopBackend + src/mpv_desktop/）
        // 🔴🔴 2026-10-18：桌面端此前选 mpv 会「走空」——默认后端是 mpv，
        //   但 Android 版 MpvBackend 依赖 MethodChannel `hain_tv/mpv` +
        //   PlatformView `heinplay_mpv`，桌面 runner 从未注册，导致无纹理、
        //   无控制、无事件。本分支补上桌面侧载体，让「全平台统一 mpv」落地。
        if (Platform.isWindows || Platform.isLinux) {
          return MpvDesktopBackend();
        }
        return MpvBackend();
      case PlayerBackendType.vlc:
        return VlcBackend();
      case PlayerBackendType.fvp:
        // 🔴 2026-10-16：fvp 实现（FvpBackend）已从工程彻底删除。
        //   枚举值刻意**保留**，因为历史存储值可能仍是 "fvp"；走到此处即回退 mpv。
        //   （另见 UserDataService._resolveStoredBackend 的写入侧/读取侧双保险迁移）
        return MpvBackend();
    }
  }

  /// 各平台默认后端：
  /// - **Android / TV：exo**（官方 ExoPlayer，默认首选；mpv 为备用）
  /// - Windows / Linux：mpv（官方内核 + 自写壳）
  /// - HarmonyOS：见 hain_tv_ohos 工程（mpv-arkts）
  static PlayerBackendType get platformDefault {
    if (Platform.isAndroid) return PlayerBackendType.exo;
    return PlayerBackendType.mpv;
  }

  /// 直播默认后端：
  /// - **Android / TV：exo**（与点播同款，兼容性最佳；mpv 为备用）
  /// - Windows / Linux：mpv
  static PlayerBackendType get platformLiveDefault {
    if (Platform.isAndroid) return PlayerBackendType.exo;
    return PlayerBackendType.mpv;
  }

  /// 当前平台可供用户切换的播放器后端列表。
  /// - Android / TV：**exo（默认首选）**、mpv（备用）
  /// - Windows：mpv（默认）、vlc（兜底）
  /// - Linux：仅 mpv
  /// - HarmonyOS：见 hain_tv_ohos 工程的工厂（mpv + avplayer）
  static List<PlayerBackendType> get availableBackends {
    if (Platform.isWindows) {
      return [PlayerBackendType.mpv, PlayerBackendType.vlc];
    }
    if (Platform.isLinux) {
      return [PlayerBackendType.mpv];
    }
    if (Platform.isAndroid) {
      // 🔴 exo 排第一位 = 默认首选（见 [platformDefault]），mpv 为备用。
      return [PlayerBackendType.exo, PlayerBackendType.mpv];
    }
    return [PlayerBackendType.mpv];
  }

  static Future<VideoPlayerBackend> createDefault() async {
    var type = await UserDataService.getPlayerBackend();
    // 若全局设置中的后端在当前平台不可用，回退到平台默认并更新设置。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackend(type);
    }
    return create(type);
  }

  static Future<VideoPlayerBackend> createForLive() async {
    var type = await UserDataService.getLivePlayerBackend();
    // 若直播设置中的后端在当前平台不可用，回退到直播平台默认。
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
    // 若某个视频单独保存的后端在当前平台不可用，回退到平台默认。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackendForVideo(source, id, type);
    }
    return create(type);
  }
}
