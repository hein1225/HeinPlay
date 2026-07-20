import 'dart:io';

import 'package:video_player_android/video_player_android.dart';

import '../services/user_data_service.dart';
import 'exo_player_backend.dart';
import 'fvp_backend.dart';
import 'video_player_backend.dart';
import 'vlc_backend.dart';

class PlayerBackendFactory {
  /// 将 video_player 平台实现恢复为 Android 原生 ExoPlayer。
  ///
  /// 某些插件可能会全局替换 [VideoPlayerPlatform.instance]，
  /// 使用 ExoPlayer 前显式恢复官方 Android 实现。
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
      case PlayerBackendType.fvp:
        return FvpBackend();
      case PlayerBackendType.vlc:
        return VlcBackend();
    }
  }

  /// 各平台默认后端：
  /// - Android / TV：ExoPlayer
  /// - Windows：fvp
  static PlayerBackendType get platformDefault {
    if (Platform.isWindows) return PlayerBackendType.fvp;
    return PlayerBackendType.exo;
  }

  /// 当前平台可供用户切换的播放器后端列表。
  /// - Android / TV：ExoPlayer、fvp
  /// - Windows：fvp、vlc
  static List<PlayerBackendType> get availableBackends {
    if (Platform.isWindows) {
      return [PlayerBackendType.fvp, PlayerBackendType.vlc];
    }
    return [PlayerBackendType.exo, PlayerBackendType.fvp];
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
