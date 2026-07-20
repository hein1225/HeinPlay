import 'package:flutter/services.dart';
import 'buffer_profile_config.dart';

/// 通过自定义 MethodChannel 向原生 ExoPlayer 下发分级缓冲参数。
class ExoPlayerBufferConfig {
  static const _channel = MethodChannel('hain_tv/exo_buffer_config');

  static Future<void> apply(BufferProfileConfig config) async {
    await _channel.invokeMethod('setBufferConfig', <String, dynamic>{
      'bufferMode': 1, // 非 0 表示启用自定义参数
      'minBufferMs': config.exoMinBufferMs,
      'maxBufferMs': config.exoMaxBufferMs,
      'bufferForPlaybackMs': config.exoBufferForPlaybackMs,
      'bufferForPlaybackAfterRebufferMs':
          config.exoBufferForPlaybackAfterRebufferMs,
      'backBufferMs': config.exoBackBufferMs,
    });
  }
}
