import '../services/user_data_service.dart';
import 'exo_player_backend.dart';
import 'media_kit_backend.dart';
import 'video_player_backend.dart';
import 'video_player_backend_impl.dart';

class PlayerBackendFactory {
  static VideoPlayerBackend create(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.mediaKit:
        return MediaKitBackend();
      case PlayerBackendType.videoPlayer:
        return VideoPlayerBackendImpl();
      case PlayerBackendType.exo:
        return ExoPlayerBackend();
    }
  }

  static Future<VideoPlayerBackend> createDefault() async {
    final type = await UserDataService.getPlayerBackend();
    return create(type);
  }

  static Future<VideoPlayerBackend> createForVideo(
    String source,
    String id,
  ) async {
    final fallback = await UserDataService.getPlayerBackend();
    final type = await UserDataService.getPlayerBackendForVideo(
      source,
      id,
      fallback: fallback,
    );
    return create(type);
  }
}
