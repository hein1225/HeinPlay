import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;
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

  /// 在 Android 上注册 fvp（libmdk/ffmpeg 网络栈），替代 ExoPlayer。
  ///
  /// fvp 用 ffmpeg 网络栈，能连部分 ExoPlayer(OkHttp) 无法连通的 IPTV 域名。
  static void _restoreAndroidFvp() {
    if (Platform.isAndroid) {
      fvp.registerWith(options: {
        'platforms': ['android'],
        'lowLatency': 1,
        // MDK 全局选项。avformat 值语法为 key1=val1:key2=val2...（冒号分隔），
        // 之前误用逗号导致选项未生效。lowLatency=1 已由 fvp 内部自动设置
        // avformat.fflags=+nobuffer、fpsprobesize=0、analyzeduration=100000，
        // 这里只保留 TLS 校验关闭（兼容自签/非标准端口 IPTV 源）。
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    }
  }

  /// 在 HarmonyOS 上注册 fvp（libmdk/ffmpeg 网络栈），作为唯一播放后端。
  ///
  /// 鸿蒙（OHOS）没有 Android 运行时，ExoPlayer/VLC 均不可用，视频层只用 fvp。
  /// fvp 官方支持 HarmonyOS 5.0+，经 OpenGL 渲染。
  static void _restoreOhosFvp() {
    if (Platform.operatingSystem == 'ohos') {
      fvp.registerWith(options: {
        'platforms': ['ohos'],
        'lowLatency': 1,
        // MDK 全局选项。avformat 值语法为 key1=val1:key2=val2...（冒号分隔），
        // 之前误用逗号导致选项未生效。lowLatency=1 已由 fvp 内部自动设置
        // avformat.fflags=+nobuffer、fpsprobesize=0、analyzeduration=100000。
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    }
  }

  static VideoPlayerBackend create(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        _restoreAndroidVideoPlayer();
        return ExoPlayerBackend();
      case PlayerBackendType.fvp:
        _restoreAndroidFvp();
        _restoreOhosFvp();
        return FvpBackend();
      case PlayerBackendType.vlc:
        return VlcBackend();
    }
  }

  /// 各平台默认后端：
  /// - Android / TV：ExoPlayer
  /// - Windows / Linux / HarmonyOS：fvp
  static PlayerBackendType get platformDefault {
    if (Platform.isWindows || Platform.isLinux || Platform.operatingSystem == 'ohos') {
      return PlayerBackendType.fvp;
    }
    return PlayerBackendType.exo;
  }

  /// 直播默认后端：Android / TV 与 Windows 默认 ExoPlayer（Android/TV 点播同款，
  /// 兼容性最佳）；HarmonyOS / Linux 无 ExoPlayer 运行时，仍用 fvp。
  /// 见 [UserDataService.getLivePlayerBackend] 的默认值说明。
  static PlayerBackendType get platformLiveDefault {
    if (Platform.operatingSystem == 'ohos' || Platform.isLinux) {
      return PlayerBackendType.fvp;
    }
    return PlayerBackendType.exo;
  }

  /// 当前平台可供用户切换的播放器后端列表。
  /// - Android / TV：ExoPlayer、fvp
  /// - Windows：fvp、vlc
  /// - Linux / HarmonyOS：仅 fvp（鸿蒙无 ExoPlayer/VLC 运行时）
  static List<PlayerBackendType> get availableBackends {
    if (Platform.isWindows) {
      return [PlayerBackendType.fvp, PlayerBackendType.vlc];
    }
    if (Platform.isLinux || Platform.operatingSystem == 'ohos') {
      return [PlayerBackendType.fvp];
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
