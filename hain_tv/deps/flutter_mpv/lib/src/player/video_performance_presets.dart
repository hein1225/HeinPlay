/// This file is a part of flutter_mpv (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'package:flutter_mpv/src/player/platform_player.dart';

/// {@template video_performance_presets}
///
/// VideoPerformancePresets
/// ------------------------
/// Pre-configured video performance settings for common use cases.
///
/// These presets provide optimized configurations for different scenarios:
/// - `powerSaver`: lowest CPU/GPU usage, lowest quality
/// - `balanced`: recommended default for most playback
/// - `instantSeeking`: fastest local scrubbing and keyframe seeking
/// - `quality`: sharper output on capable devices
/// - `smoothMotion`: interpolation for 24fps/animation-heavy content
/// - `streaming`: larger cache and buffering for network playback
/// - `softwareDecoding`: compatibility fallback when hardware decode misbehaves
///
/// {@endtemplate}
class VideoPerformancePresets {
  /// Lowest resource usage preset for weak or hot devices.
  ///
  /// This is the clearest "make it play" option.
  /// It drops quality aggressively to reduce stutter, heat, and battery drain.
  ///
  /// Features:
  /// - Hardware decoding (auto-detect)
  /// - Minimal decoder threads (2)
  /// - Aggressive frame dropping to maintain smoothness
  /// - Simple video sync
  /// - Fast bilinear scaling
  /// - Fast decoding enabled
  /// - Small cache for low latency
  static const VideoPerformanceConfiguration powerSaver =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'auto',
    decoderThreads: 2,
    frameDropping: 'decoder+vo',
    videoSync: 'audio',
    scaler: 'bilinear',
    downScaler: 'bilinear',
    interpolation: false,
    deinterlacing: 'auto',
    fastDecoding: 'yes',
    softwareDecodingDirectRendering: 'yes',
    openglPbo: 'yes',
    videoLatencyHacks: 'yes',
    hrSeek: 'yes',
    hrSeekFramedrop: 'yes',
    fastSeek: 'yes',
    cacheSecs: 15,
    profile: 'fast',
  );

  /// Recommended default preset for most users.
  ///
  /// Keeps quality decent without becoming too expensive.
  /// This is the safest preset when you do not know the device yet.
  ///
  /// Features:
  /// - Hardware decoding (auto)
  /// - Auto decoder threads
  /// - Moderate frame dropping
  /// - Simple video sync
  /// - Bicubic scaling
  /// - Tuned for local files
  static const VideoPerformanceConfiguration balanced =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'auto',
    decoderThreads: null,
    frameDropping: 'decoder',
    videoSync: 'audio',
    scaler: 'bicubic',
    downScaler: 'bicubic',
    interpolation: false,
    deinterlacing: 'auto',
    optimizeForLocalFiles: true,
    openglPbo: 'yes',
    cacheSecs: 45,
  );

  /// Fastest local seeking preset.
  ///
  /// This preset is built for scrubbing, previews, and repeated jumps.
  /// It favors responsiveness over image quality and seek precision.
  ///
  /// If you want the same behavior with another preset, prefer setting
  /// `instantSeeking: true` in your own [VideoPerformanceConfiguration].
  ///
  /// Features:
  /// - Hardware decoding (auto)
  /// - Aggressive frame dropping during seek
  /// - Fast keyframe seeking enabled
  /// - Large demuxer back buffer for repeated jumps
  /// - Fast profile and low cache latency
  static const VideoPerformanceConfiguration instantSeeking =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'auto',
    decoderThreads: 4,
    frameDropping: 'decoder+vo',
    videoSync: 'audio',
    scaler: 'bilinear',
    downScaler: 'bilinear',
    interpolation: false,
    deinterlacing: 'no',
    optimizeForLocalFiles: true,
    demuxerMaxBytes: '64M',
    demuxerMaxBackBytes: '256M',
    profile: 'fast',
    cache: 'yes',
    cacheSecs: 8,
    cacheBack: '256M',
    fastDecoding: 'yes',
    openglPbo: 'yes',
    videoLatencyHacks: 'yes',
    instantSeeking: true,
  );

  /// Quality-first playback for capable devices.
  ///
  /// This preset aims for a visibly sharper result than `balanced`.
  /// It avoids frame dropping and uses higher quality scaling.
  ///
  /// Features:
  /// - Hardware decoding with surface upload
  /// - More decoder threads
  /// - No frame dropping (best quality)
  /// - Display-resample sync for stable presentation
  /// - Lanczos scaling (high quality)
  /// - No interpolation, keeps original motion intact
  /// - Vulkan GPU backend (if available)
  /// - Large cache for high bitrate content
  static const VideoPerformanceConfiguration quality =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'auto-copy',
    decoderThreads: 6,
    frameDropping: 'no',
    videoSync: 'display-resample',
    scaler: 'lanczos',
    downScaler: 'lanczos',
    interpolation: false,
    deinterlacing: 'auto',
    gpuBackend: 'vulkan',
    gpuApi: 'vulkan',
    openglPbo: 'yes',
    hrSeek: 'yes',
    hrSeekFramedrop: 'no',
    fastSeek: 'no',
    cacheSecs: 120,
  );

  /// Software decoding configuration for debugging or compatibility.
  ///
  /// Forces software decoding regardless of hardware capabilities.
  /// Useful for:
  /// - Debugging video issues
  /// - Testing codec compatibility
  /// - Working around hardware decoder bugs
  ///
  /// Features:
  /// - Software decoding (no hardware)
  /// - More decoder threads (needed for SW)
  /// - Direct rendering enabled
  /// - Fast decoding for speed
  /// - Simple bilinear scaling
  static const VideoPerformanceConfiguration softwareDecoding =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'no',
    decoderThreads: 6,
    frameDropping: 'decoder',
    videoSync: 'audio',
    scaler: 'bilinear',
    downScaler: 'bilinear',
    interpolation: false,
    deinterlacing: 'auto',
    softwareDecodingDirectRendering: 'yes',
    fastDecoding: 'yes',
    openglPbo: 'yes',
    cacheSecs: 45,
  );

  /// Smooth motion configuration for 24fps content (movies, anime).
  ///
  /// Interpolates frames to match display refresh rate.
  /// Creates smoother motion but increases CPU/GPU usage.
  ///
  /// Best for:
  /// - 24fps movies and TV shows
  /// - Anime content
  /// - High refresh rate displays (60Hz, 120Hz, 144Hz)
  ///
  /// Features:
  /// - Hardware decoding
  /// - Display-resample sync
  /// - Frame interpolation enabled
  /// - Oversample temporal scaling
  /// - No frame dropping for smooth motion
  /// - Vulkan backend
  static const VideoPerformanceConfiguration smoothMotion =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'auto-copy',
    decoderThreads: 4,
    frameDropping: 'no',
    videoSync: 'display-resample',
    scaler: 'lanczos',
    downScaler: 'lanczos',
    interpolation: true,
    temporalScaler: 'oversample',
    deinterlacing: 'auto',
    gpuBackend: 'vulkan',
    openglPbo: 'yes',
    cacheSecs: 90,
  );

  /// Streaming optimization for network playback.
  ///
  /// Optimized for streaming content over network.
  /// Prioritizes smooth playback and buffer management.
  ///
  /// Features:
  /// - Hardware decoding
  /// - Aggressive frame dropping
  /// - Simple sync and scaling
  /// - Optimized for streaming (not local files)
  /// - Large cache for network buffering
  ///
  /// Note: Use with larger buffer size in PlayerConfiguration:
  /// ```dart
  /// PlayerConfiguration(
  ///   bufferSize: 128 * 1024 * 1024, // 128MB for streaming
  ///   videoPerformance: VideoPerformancePresets.streaming,
  /// )
  /// ```
  static const VideoPerformanceConfiguration streaming =
      VideoPerformanceConfiguration(
    hardwareDecoding: 'auto',
    decoderThreads: null,
    frameDropping: 'decoder+vo',
    videoSync: 'audio',
    scaler: 'bilinear',
    downScaler: 'bilinear',
    interpolation: false,
    deinterlacing: 'auto',
    optimizeForLocalFiles: false,
    demuxerMaxBytes: '256M',
    cache: 'yes',
    cacheSecs: 120,
    cacheBack: '64M',
    hrSeekFramedrop: 'yes',
    fastSeek: 'yes',
  );

  @Deprecated(
    'Use VideoPerformancePresets.powerSaver. Presets were simplified to clearer tiers.',
  )
  static const VideoPerformanceConfiguration lowEndDevice = powerSaver;

  @Deprecated(
    'Use VideoPerformancePresets.instantSeeking. Presets were simplified to clearer tiers.',
  )
  static const VideoPerformanceConfiguration fastSeeking = instantSeeking;

  @Deprecated(
    'Use VideoPerformancePresets.powerSaver. Presets were simplified to clearer tiers.',
  )
  static const VideoPerformanceConfiguration maximumPerformance = powerSaver;

  @Deprecated(
    'Use VideoPerformancePresets.quality. Presets were simplified to clearer tiers.',
  )
  static const VideoPerformanceConfiguration highQuality = quality;

  @Deprecated(
    'Use VideoPerformancePresets.quality. Presets were simplified to clearer tiers.',
  )
  static const VideoPerformanceConfiguration qualityFirst = quality;

  @Deprecated(
    'Use VideoPerformancePresets.quality. Presets were simplified to clearer tiers.',
  )
  static const VideoPerformanceConfiguration animation = quality;

  @Deprecated(
    'Use VideoPerformancePresets.smoothMotion for interpolation-focused playback or VideoPerformancePresets.quality for sharp output.',
  )
  static const VideoPerformanceConfiguration referenceQuality = smoothMotion;

  /// {@macro video_performance_presets}
  const VideoPerformancePresets();
}
