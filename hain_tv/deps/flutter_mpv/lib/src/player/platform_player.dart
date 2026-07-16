/// This file is a part of flutter_mpv (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'dart:async';
import 'dart:typed_data';
import 'package:meta/meta.dart';
import 'package:collection/collection.dart';

import 'package:flutter_mpv/src/models/track.dart';
import 'package:flutter_mpv/src/models/playable.dart';
import 'package:flutter_mpv/src/models/playlist.dart';
import 'package:flutter_mpv/src/models/player_log.dart';
import 'package:flutter_mpv/src/models/media/media.dart';
import 'package:flutter_mpv/src/models/audio_device.dart';
import 'package:flutter_mpv/src/models/audio_params.dart';
import 'package:flutter_mpv/src/models/video_params.dart';
import 'package:flutter_mpv/src/models/player_state.dart';
import 'package:flutter_mpv/src/models/playlist_mode.dart';
import 'package:flutter_mpv/src/models/player_stream.dart';

/// {@template platform_player}
/// PlatformPlayer
/// --------------
///
/// This class provides the interface for platform specific [Player] implementations.
/// The platform specific implementations are expected to implement the methods accordingly.
///
/// The subclasses are then used in composition with the [Player] class, based on the platform the application is running on.
///
/// {@endtemplate}
abstract class PlatformPlayer {
  /// {@macro platform_player}
  PlatformPlayer({required this.configuration});

  /// User defined configuration for [Player].
  final PlayerConfiguration configuration;

  /// Current state of the player.
  late PlayerState state = PlayerState();

  /// Current state of the player available as listenable [Stream]s.
  late PlayerStream stream = PlayerStream(
    playlistController.stream.distinct(
      (previous, current) => previous == current,
    ),
    playingController.stream.distinct(
      (previous, current) => previous == current,
    ),
    completedController.stream.distinct(
      (previous, current) => previous == current,
    ),
    positionController.stream.distinct(
      (previous, current) => previous == current,
    ),
    durationController.stream.distinct(
      (previous, current) => previous == current,
    ),
    volumeController.stream.distinct(
      (previous, current) => previous == current,
    ),
    rateController.stream.distinct(
      (previous, current) => previous == current,
    ),
    pitchController.stream.distinct(
      (previous, current) => previous == current,
    ),
    bufferingController.stream.distinct(
      (previous, current) => previous == current,
    ),
    bufferingPercentageController.stream.distinct(
      (previous, current) => previous == current,
    ),
    bufferController.stream.distinct(
      (previous, current) => previous == current,
    ),
    playlistModeController.stream.distinct(
      (previous, current) => previous == current,
    ),
    shuffleController.stream.distinct(
      (previous, current) => previous == current,
    ),
    /* AUDIO-PARAMS STREAM SHOULD NOT BE DISTINCT */
    audioParamsController.stream,
    /* VIDEO-PARAMS STREAM SHOULD NOT BE DISTINCT */
    videoParamsController.stream,
    audioBitrateController.stream.distinct(
      (previous, current) => previous == current,
    ),
    audioDeviceController.stream.distinct(
      (previous, current) => previous == current,
    ),
    audioDevicesController.stream.distinct(
      (previous, current) => ListEquality().equals(previous, current),
    ),
    trackController.stream.distinct(
      (previous, current) => previous == current,
    ),
    tracksController.stream.distinct(
      (previous, current) => previous == current,
    ),
    widthController.stream.distinct(
      (previous, current) => previous == current,
    ),
    heightController.stream.distinct(
      (previous, current) => previous == current,
    ),
    subtitleController.stream.distinct(
      (previous, current) => ListEquality().equals(previous, current),
    ),
    logController.stream.distinct(
      (previous, current) => previous == current,
    ),
    /* ERROR STREAM SHOULD NOT BE DISTINCT */
    errorController.stream,
  );

  @mustCallSuper
  Future<void> dispose() async {
    await Future.wait(
      [
        playlistController.close(),
        playingController.close(),
        completedController.close(),
        positionController.close(),
        durationController.close(),
        volumeController.close(),
        rateController.close(),
        pitchController.close(),
        bufferingController.close(),
        bufferingPercentageController.close(),
        bufferController.close(),
        playlistModeController.close(),
        shuffleController.close(),
        audioParamsController.close(),
        videoParamsController.close(),
        audioBitrateController.close(),
        audioDeviceController.close(),
        audioDevicesController.close(),
        trackController.close(),
        tracksController.close(),
        widthController.close(),
        heightController.close(),
        subtitleController.close(),
        logController.close(),
        errorController.close(),
      ],
    );
    for (final callback in release) {
      try {
        await callback.call();
      } catch (exception, stacktrace) {
        print(exception.toString());
        print(stacktrace.toString());
      }
    }
  }

  Future<void> open(
    Playable playable, {
    bool play = true,
  }) {
    throw UnimplementedError(
      '[PlatformPlayer.open] is not implemented',
    );
  }

  Future<void> stop() {
    throw UnimplementedError(
      '[PlatformPlayer.stop] is not implemented',
    );
  }

  Future<void> play() {
    throw UnimplementedError(
      '[PlatformPlayer.play] is not implemented',
    );
  }

  Future<void> pause() {
    throw UnimplementedError(
      '[PlatformPlayer.pause] is not implemented',
    );
  }

  Future<void> playOrPause() {
    throw UnimplementedError(
      '[PlatformPlayer.playOrPause] is not implemented',
    );
  }

  Future<void> add(Media media) {
    throw UnimplementedError(
      '[PlatformPlayer.add] is not implemented',
    );
  }

  Future<void> remove(int index) {
    throw UnimplementedError(
      '[PlatformPlayer.remove] is not implemented',
    );
  }

  Future<void> next() {
    throw UnimplementedError(
      '[PlatformPlayer.next] is not implemented',
    );
  }

  Future<void> previous() {
    throw UnimplementedError(
      '[PlatformPlayer.previous] is not implemented',
    );
  }

  Future<void> jump(int index) {
    throw UnimplementedError(
      '[PlatformPlayer.jump] is not implemented',
    );
  }

  Future<void> move(int from, int to) {
    throw UnimplementedError(
      '[PlatformPlayer.move] is not implemented',
    );
  }

  Future<void> seek(Duration duration) {
    throw UnimplementedError(
      '[PlatformPlayer.seek] is not implemented',
    );
  }

  Future<void> setPlaylistMode(PlaylistMode playlistMode) {
    throw UnimplementedError(
      '[PlatformPlayer.setPlaylistMode] is not implemented',
    );
  }

  Future<void> setVolume(double volume) {
    throw UnimplementedError(
      '[PlatformPlayer.volume] is not implemented',
    );
  }

  Future<void> setRate(double rate) {
    throw UnimplementedError(
      '[PlatformPlayer.rate] is not implemented',
    );
  }

  Future<void> setPitch(double pitch) {
    throw UnimplementedError(
      '[PlatformPlayer.pitch] is not implemented',
    );
  }

  Future<void> setShuffle(bool shuffle) {
    throw UnimplementedError(
      '[PlatformPlayer.shuffle] is not implemented',
    );
  }

  Future<void> setAudioDevice(AudioDevice audioDevice) {
    throw UnimplementedError(
      '[PlatformPlayer.setAudioDevice] is not implemented',
    );
  }

  Future<void> setVideoTrack(VideoTrack track) {
    throw UnimplementedError(
      '[PlatformPlayer.setVideoTrack] is not implemented',
    );
  }

  Future<void> setAudioTrack(AudioTrack track) {
    throw UnimplementedError(
      '[PlatformPlayer.setAudioTrack] is not implemented',
    );
  }

  Future<void> setSubtitleTrack(SubtitleTrack track) {
    throw UnimplementedError(
      '[PlatformPlayer.setSubtitleTrack] is not implemented',
    );
  }

  Future<void> setOption(String option, dynamic value) {
    throw UnimplementedError(
      '[PlatformPlayer.setOption] is not implemented',
    );
  }

  Future<void> setProperty(String property, String value) {
    throw UnimplementedError(
      '[PlatformPlayer.setProperty] is not implemented',
    );
  }

  Future<Uint8List?> screenshot(
      {String? format = 'image/jpeg',
      bool includeLibassSubtitles = false}) async {
    throw UnimplementedError(
      '[PlatformPlayer.screenshot] is not implemented',
    );
  }

  Future<int> get handle {
    throw UnimplementedError(
      '[PlatformPlayer.handle] is not implemented',
    );
  }

  @protected
  final StreamController<Playlist> playlistController =
      StreamController<Playlist>.broadcast();

  @protected
  final StreamController<bool> playingController =
      StreamController<bool>.broadcast();

  @protected
  final StreamController<bool> completedController =
      StreamController<bool>.broadcast();

  @protected
  final StreamController<Duration> positionController =
      StreamController<Duration>.broadcast();

  @protected
  final StreamController<Duration> durationController =
      StreamController.broadcast();

  @protected
  final StreamController<double> volumeController =
      StreamController.broadcast();

  @protected
  final StreamController<double> rateController =
      StreamController<double>.broadcast();

  @protected
  final StreamController<double> pitchController =
      StreamController<double>.broadcast();

  @protected
  final StreamController<bool> bufferingController =
      StreamController<bool>.broadcast();
  @protected
  final StreamController<double> bufferingPercentageController =
      StreamController<double>.broadcast();
  @protected
  final StreamController<Duration> bufferController =
      StreamController<Duration>.broadcast();

  @protected
  final StreamController<PlaylistMode> playlistModeController =
      StreamController<PlaylistMode>.broadcast();

  @protected
  final StreamController<bool> shuffleController =
      StreamController<bool>.broadcast();

  @protected
  final StreamController<PlayerLog> logController =
      StreamController<PlayerLog>.broadcast();

  @protected
  final StreamController<String> errorController =
      StreamController<String>.broadcast();

  @protected
  final StreamController<AudioParams> audioParamsController =
      StreamController<AudioParams>.broadcast();

  @protected
  final StreamController<VideoParams> videoParamsController =
      StreamController<VideoParams>.broadcast();

  @protected
  final StreamController<double?> audioBitrateController =
      StreamController<double?>.broadcast();

  @protected
  final StreamController<AudioDevice> audioDeviceController =
      StreamController<AudioDevice>.broadcast();

  @protected
  final StreamController<List<AudioDevice>> audioDevicesController =
      StreamController<List<AudioDevice>>.broadcast();

  @protected
  final StreamController<Track> trackController =
      StreamController<Track>.broadcast();

  @protected
  final StreamController<Tracks> tracksController =
      StreamController<Tracks>.broadcast();

  @protected
  final StreamController<int?> widthController =
      StreamController<int?>.broadcast();

  @protected
  final StreamController<int?> heightController =
      StreamController<int?>.broadcast();

  @protected
  final StreamController<List<String>> subtitleController =
      StreamController<List<String>>.broadcast();

  // --------------------------------------------------

  /// [Completer] to wait for initialization of this instance.
  final Completer<void> completer = Completer<void>();

  /// [Future<void>] to wait for initialization of this instance.
  Future<void> get waitForPlayerInitialization => completer.future;

  // --------------------------------------------------

  /// [bool] for signaling [VideoController] (from `package:flutter_mpv_video`) initialization.
  bool isVideoControllerAttached = false;

  /// [Completer] for signaling [VideoController] (from `package:flutter_mpv_video`) initialization.
  final Completer<void> videoControllerCompleter = Completer<void>();

  /// [Future<void>] to wait for [VideoController] (from `package:flutter_mpv_video`) initialization.
  Future<void> get waitForVideoControllerInitializationIfAttached {
    if (isVideoControllerAttached) {
      return videoControllerCompleter.future;
    }
    return Future.value(null);
  }

  // --------------------------------------------------

  /// Publicly defined clean-up [Function]s which must be called before [dispose].
  final List<Future<void> Function()> release = [];
}

/// {@template video_performance_configuration}
///
/// VideoPerformanceConfiguration
/// ------------------------------
/// Configuration for video decoding and rendering performance.
///
/// {@endtemplate}
class VideoPerformanceConfiguration {
  /// Hardware decoding method.
  ///
  /// Controls how video is decoded:
  /// - `null`: Auto-detect (mpv default)
  /// - `'auto'`: Try hardware, fallback to software
  /// - `'auto-copy'`: Auto with surface upload
  /// - `'yes'`: Force hardware (fail if unavailable)
  /// - `'no'`: Force software decoding
  /// - Platform-specific: `'mediacodec'` (Android), `'videotoolbox'` (iOS/macOS),
  ///   `'d3d11va'` (Windows), `'vaapi'` (Linux)
  ///
  /// Default: `null` (auto-detect)
  ///
  /// See: https://mpv.io/manual/master/#options-hwdec
  final String? hardwareDecoding;

  /// Number of threads for video decoding.
  ///
  /// - `null`: Auto-detect based on CPU cores
  /// - `1-16`: Explicit thread count
  ///
  /// Higher values improve decoding speed but use more CPU.
  /// Most videos decode fine with 2-4 threads.
  ///
  /// Default: `null` (auto)
  ///
  /// See: https://mpv.io/manual/master/#options-vd-lavc-threads
  final int? decoderThreads;

  /// Frame dropping strategy.
  ///
  /// Controls when frames can be dropped to maintain A/V sync:
  /// - `'no'`: Never drop frames (may cause stuttering)
  /// - `'decoder'`: Drop during decoding only (default)
  /// - `'decoder+vo'`: Drop during decoding and video output
  ///
  /// Use `'no'` for quality-critical applications.
  /// Use `'decoder+vo'` for smooth playback on slow devices.
  ///
  /// Default: `'decoder'`
  ///
  /// See: https://mpv.io/manual/master/#options-framedrop
  final String? frameDropping;

  /// Audio/video synchronization method.
  ///
  /// Controls how video syncs to audio:
  /// - `'audio'`: Default, simple sync
  /// - `'display-resample'`: Resample to display refresh rate (smoothest)
  /// - `'display-resample-vdrop'`: Resample with frame dropping
  /// - `'display-adrop'`: Drop/duplicate audio samples
  ///
  /// Use `'display-resample'` for high-end devices.
  /// Use `'audio'` for compatibility.
  ///
  /// Default: `null` (uses mpv default: `'audio'`)
  ///
  /// See: https://mpv.io/manual/master/#options-video-sync
  final String? videoSync;

  /// Video scaling algorithm.
  ///
  /// Controls quality when upscaling video:
  /// - `'bilinear'`: Fast, low quality (default)
  /// - `'bicubic'`: Balanced quality/speed
  /// - `'lanczos'`: High quality, slower
  /// - `'spline36'`: Very high quality
  ///
  /// Use `'bilinear'` for low-end devices.
  /// Use `'lanczos'` or `'spline36'` for high-quality playback.
  ///
  /// Default: `null` (uses current: `'bilinear'`)
  ///
  /// See: https://mpv.io/manual/master/#options-scale
  final String? scaler;

  /// Video downscaling algorithm.
  ///
  /// Same options as [scaler] but for downscaling.
  ///
  /// Default: `null` (uses current: `'bilinear'`)
  ///
  /// See: https://mpv.io/manual/master/#options-dscale
  final String? downScaler;

  /// Enable frame interpolation.
  ///
  /// Interpolates frames to match display refresh rate.
  /// Creates smoother motion but increases CPU/GPU usage.
  ///
  /// Requires `video-sync` to be `'display-resample'` or similar.
  ///
  /// Default: `false`
  ///
  /// See: https://mpv.io/manual/master/#options-interpolation
  final bool interpolation;

  /// Interpolation algorithm.
  ///
  /// - `'linear'`: Simple interpolation
  /// - `'cosine'`: Smooth interpolation
  /// - `'oversample'`: High quality (default)
  ///
  /// Default: `'oversample'`
  ///
  /// See: https://mpv.io/manual/master/#options-tscale
  final String? temporalScaler;

  /// Enable deinterlacing.
  ///
  /// Controls how interlaced video is handled:
  /// - `'no'`: Disable deinterlacing
  /// - `'yes'`: Always deinterlace
  /// - `'auto'`: Deinterlace only when needed
  ///
  /// Default: `'auto'`
  ///
  /// See: https://mpv.io/manual/master/#options-deinterlace
  final String? deinterlacing;

  /// GPU backend for rendering.
  ///
  /// - `null`: Auto-detect
  /// - `'opengl'`: OpenGL (most compatible)
  /// - `'vulkan'`: Vulkan (best performance on supported devices)
  /// - `'direct3d'`: Direct3D (Windows only)
  ///
  /// Default: `null` (auto)
  ///
  /// See: https://mpv.io/manual/master/#options-gpu-backend
  final String? gpuBackend;

  /// Optimize for local file playback.
  ///
  /// When enabled, configures mpv for optimal local file seeking:
  /// - Disables network readahead
  /// - Increases back buffer for fast seeking
  /// - Reduces initial buffering time
  /// - Optimizes cache for local storage
  ///
  /// Default: `true` (optimized for local files)
  ///
  /// Set to `false` for network/streaming content.
  final bool optimizeForLocalFiles;

  /// Maximum cache size for demuxer (in bytes).
  ///
  /// Controls the maximum amount of memory used for demuxing.
  /// Accepts a string value (e.g., '150MB', '1GB').
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-demuxer-max-bytes
  final String? demuxerMaxBytes;

  /// Maximum back buffer size for demuxer.
  ///
  /// Controls how much data is kept in the back buffer for seeking.
  /// Accepts a string value (e.g., '150MB', '1GB').
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-demuxer-max-back-bytes
  final String? demuxerMaxBackBytes;

  /// Hardware decoding profile.
  ///
  /// Specifies a profile for hardware decoding.
  /// Accepts profile names like 'baseline', 'main', 'high', etc.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-profile
  final String? profile;

  /// Enable or disable caching.
  ///
  /// Controls whether caching is enabled.
  /// Accepts 'yes' or 'no'.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-cache
  final String? cache;

  /// Cache duration in seconds.
  ///
  /// Specifies how many seconds of content to cache.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-cache-secs
  final int? cacheSecs;

  /// Cache back buffer duration.
  ///
  /// Controls how much cached data is kept for backward seeking.
  /// Accepts a string value (e.g., '10s', '30s').
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-cache-back
  final String? cacheBack;

  /// Enable high-resolution seeking.
  ///
  /// When enabled, allows for more precise seeking.
  /// Accepts 'yes' or 'no'.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-hr-seek
  final String? hrSeek;

  /// Direct rendering for software decoding.
  ///
  /// Can significantly improve performance by decoding directly to video memory.
  ///
  /// Default: `null` (uses mpv default, usually 'yes')
  ///
  /// See: https://mpv.io/manual/master/#options-vd-lavc-dr
  final String? softwareDecodingDirectRendering;

  /// Enable faster, lower-quality decoding for software decoders.
  ///
  /// Set to 'yes' to drop some quality for speed.
  ///
  /// Default: `null` (uses mpv default, 'no')
  ///
  /// See: https://mpv.io/manual/master/#options-vd-lavc-fast
  final String? fastDecoding;

  /// Allow OpenGL to use PBOs (Pixel Buffer Objects) for faster texture uploads.
  ///
  /// Can improve performance when using OpenGL.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-opengl-pbo
  final String? openglPbo;

  /// Enable latency hacks to reduce video latency.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-video-latency-hacks
  final String? videoLatencyHacks;

  /// Force a specific graphics API.
  ///
  /// Options: 'opengl', 'vulkan', 'd3d11'
  ///
  /// Default: `null` (uses mpv default based on backend)
  ///
  /// See: https://mpv.io/manual/master/#options-gpu-api
  final String? gpuApi;

  /// Provide specific options to ffmpeg decoder.
  ///
  /// Key/value pairs separated by commas.
  ///
  /// Default: `null`
  ///
  /// See: https://mpv.io/manual/master/#options-vd-lavc-o
  final String? decoderOptions;

  /// Restrict hardware decoding to specific codecs.
  ///
  /// e.g. 'h264,hevc' or 'all'.
  ///
  /// Default: `null` (uses mpv default)
  ///
  /// See: https://mpv.io/manual/master/#options-hwdec-codecs
  final String? hwdecCodecs;

  /// Allow frame dropping during high-resolution seeking.
  ///
  /// Setting this to 'yes' significantly speeds up seeking locally and online.
  ///
  /// Default: `null`
  ///
  /// See: https://mpv.io/manual/master/#options-hr-seek-framedrop
  final String? hrSeekFramedrop;

  /// Whether to allow jumping to keyframes when seeking.
  ///
  /// Setting this to 'yes' improves seeking speed tremendously.
  ///
  /// Default: `null`
  ///
  /// See: https://mpv.io/manual/master/#options-hr-seek
  final String? fastSeek;

  /// Enable instant-seeking behavior on top of the current configuration.
  ///
  /// This mode is intended for local scrubbing, thumbnails, previews, and
  /// repeated seek jumps. It applies a small set of seek-focused overrides
  /// without forcing you to replace the rest of your playback preset.
  ///
  /// Typical changes include:
  /// - preferring keyframe seeking over precise seek
  /// - allowing framedrop while seeking
  /// - increasing back-buffering for repeated jumps
  ///
  /// Default: `false`
  final bool instantSeeking;

  /// {@macro video_performance_configuration}
  const VideoPerformanceConfiguration({
    this.hardwareDecoding,
    this.decoderThreads,
    this.frameDropping,
    this.videoSync,
    this.scaler,
    this.downScaler,
    this.interpolation = false,
    this.temporalScaler,
    this.deinterlacing,
    this.gpuBackend,
    this.optimizeForLocalFiles = true,
    this.demuxerMaxBytes,
    this.demuxerMaxBackBytes,
    this.profile,
    this.cache,
    this.cacheSecs,
    this.cacheBack,
    this.hrSeek,
    this.softwareDecodingDirectRendering,
    this.fastDecoding,
    this.openglPbo,
    this.videoLatencyHacks,
    this.gpuApi,
    this.decoderOptions,
    this.hwdecCodecs,
    this.hrSeekFramedrop,
    this.fastSeek,
    this.instantSeeking = false,
  });
}

/// {@template player_configuration}
///
/// PlayerConfiguration
/// --------------------
/// Configurable options for customizing the [Player] behavior.
///
/// {@endtemplate}
class PlayerConfiguration {
  /// Sets the video output driver for native backend.
  ///
  /// Default: `null`.
  final String? vo;

  /// Enables on-screen controls for native backend.
  ///
  /// Default: `false`.
  final bool osc;

  /// Enables or disables pitch shift control for native backend.
  ///
  /// Enabling this option may result in de-syncing of audio & video.
  /// Thus, usage in audio only applications is recommended.
  /// This uses `scaletempo` under the hood & disables `audio-pitch-correction`.
  ///
  /// See: https://github.com/media-kit/media-kit/issues/45
  ///
  /// Default: `false`.
  final bool pitch;

  /// Sets the name of the underlying window & process for native backend.
  /// This is visible inside the Windows' volume mixer.
  ///
  /// Default: `null`.
  final String title;

  /// Optional callback invoked when the internals of the [Player] are initialized & ready for playback.
  ///
  /// Default: `null`.
  final void Function()? ready;

  /// Whether [Player] must be started in muted state.
  ///
  /// Default: `false`.
  final bool muted;

  /// Whether to use the async API for native backend.
  ///
  /// Default: `true`.
  final bool async;

  /// Whether to use [libass](https://github.com/libass/libass) based subtitle rendering for native backend.
  ///
  /// By default, subtitles rendering is Flutter `Widget` based.
  ///
  /// On Android, this option requires [libassAndroidFont] to be set.
  final bool libass;

  /// Asset name of the `.ttf` font file to be used for [libass](https://github.com/libass/libass) based subtitle rendering on Android.
  ///
  /// e.g. `assets/fonts/subtitle.ttf`
  final String? libassAndroidFont;

  /// Font name of the `.ttf` font file to be used for [libass](https://github.com/libass/libass) based subtitle rendering on Android.
  ///
  /// e.g. `Droid Sans Fallback`
  ///
  /// NOTE: The font name is required, not the file name.
  final String? libassAndroidFontName;

  /// Sets the log level on native backend.
  /// Default: `none`.
  final MPVLogLevel logLevel;

  /// Sets the demuxer cache size (in bytes) for native backend.
  ///
  /// Default: `32` MB or `32 * 1024 * 1024` bytes.
  final int bufferSize;

  /// Sets the list of allowed protocols for native backend.
  ///
  /// Default: `['file', 'tcp', 'tls', 'http', 'https', 'crypto', 'data']`.
  ///
  /// Learn more: https://ffmpeg.org/ffmpeg-protocols.html#Protocol-Options
  final List<String> protocolWhitelist;

  /// Video performance and decoding configuration.
  ///
  /// Provides fine-grained control over video decoding, rendering, and performance.
  /// Includes hardware acceleration, frame dropping, scaling algorithms, and more.
  ///
  /// Default: `null` (uses mpv defaults)
  final VideoPerformanceConfiguration? videoPerformance;

  /// {@macro player_configuration}
  const PlayerConfiguration({
    this.vo = 'null',
    this.osc = false,
    this.pitch = false,
    this.title = 'package:flutter_mpv',
    this.ready,
    this.muted = false,
    this.async = true,
    this.libass = false,
    this.libassAndroidFont,
    this.libassAndroidFontName,
    this.logLevel = MPVLogLevel.error,
    this.bufferSize = 32 * 1024 * 1024,
    this.protocolWhitelist = const [
      'udp',
      'rtp',
      'tcp',
      'tls',
      'data',
      'file',
      'http',
      'https',
      'crypto',
    ],
    this.videoPerformance,
    this.options = const {},
  });

  /// Additional options for the underlying player backend.
  ///
  /// These are set before initialization.
  final Map<String, String> options;
}

/// {@template mpv_log_level}
///
/// MPVLogLevel
/// --------------------
/// Options to customise the [Player] native backend log level.
///
/// {@endtemplate}
enum MPVLogLevel {
  /// Disable absolutely all messages.
  /* none, */

  /// Critical/aborting errors.
  /* fatal, */

  // package:flutter_mpv internally consumes logs of level error.

  /// Simple errors.
  error,

  /// Possible problems.
  warn,

  /// Informational message.
  info,

  /// Noisy informational message.
  v,

  /// Very noisy technical information.
  debug,

  /// Extremely noisy.
  trace,
}
