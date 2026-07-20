// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer.platformview;

import android.content.Context;
import androidx.annotation.NonNull;
import androidx.annotation.Nullable;
import androidx.annotation.VisibleForTesting;
import androidx.media3.common.MediaItem;
import androidx.media3.common.util.UnstableApi;
import androidx.media3.exoplayer.DefaultLoadControl;
import androidx.media3.exoplayer.ExoPlayer;
import java.util.Map;
import io.flutter.plugins.videoplayer.ExoPlayerEventListener;
import io.flutter.plugins.videoplayer.VideoAsset;
import io.flutter.plugins.videoplayer.VideoPlayer;
import io.flutter.plugins.videoplayer.VideoPlayerCallbacks;
import io.flutter.plugins.videoplayer.VideoPlayerOptions;
import io.flutter.view.TextureRegistry.SurfaceProducer;

/**
 * A subclass of {@link VideoPlayer} that adds functionality related to platform view as a way of
 * displaying the video in the app.
 */
public class PlatformViewVideoPlayer extends VideoPlayer {
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @VisibleForTesting
  public PlatformViewVideoPlayer(
      @NonNull VideoPlayerCallbacks events,
      @NonNull MediaItem mediaItem,
      @NonNull VideoPlayerOptions options,
      @NonNull ExoPlayerProvider exoPlayerProvider) {
    super(events, mediaItem, options, /* surfaceProducer */ null, exoPlayerProvider);
  }

  /**
   * 通过反射读取 HeinPlay MainActivity 中由 Dart 层下发的分级缓冲配置。
   *
   * <p>video_player_android 插件内部自行创建 ExoPlayer，无法直接注入 LoadControl。
   * 应用在 [com.heinplay.hain_tv.MainActivity] 中通过 MethodChannel 保存配置后，
   * 插件在创建 ExoPlayer 时反射读取并构造对应的 {@link DefaultLoadControl}。
   *
   * @return 自定义缓冲配置对应的 LoadControl；若未配置或读取失败则返回 null。
   */
  @Nullable
  private static DefaultLoadControl createBufferLoadControl() {
    try {
      Class<?> mainActivityClass = Class.forName("com.heinplay.hain_tv.MainActivity");
      java.lang.reflect.Method getter = mainActivityClass.getMethod("getBufferConfig");
      Object result = getter.invoke(null);
      if (result == null) {
        return null;
      }
      Map<?, ?> config = (Map<?, ?>) result;
      Object mode = config.get("bufferMode");
      if (mode == null || ((Number) mode).intValue() == 0) {
        return null;
      }
      int minBufferMs = ((Number) config.get("minBufferMs")).intValue();
      int maxBufferMs = ((Number) config.get("maxBufferMs")).intValue();
      int bufferForPlaybackMs = ((Number) config.get("bufferForPlaybackMs")).intValue();
      int bufferForPlaybackAfterRebufferMs =
          ((Number) config.get("bufferForPlaybackAfterRebufferMs")).intValue();
      int backBufferMs = ((Number) config.get("backBufferMs")).intValue();
      return new DefaultLoadControl.Builder()
          .setBufferDurationsMs(
              minBufferMs, maxBufferMs, bufferForPlaybackMs, bufferForPlaybackAfterRebufferMs)
          .setBackBuffer(backBufferMs, /* retainBackBufferFromKeyframe= */ true)
          .build();
    } catch (Exception e) {
      // 读取失败时保持默认行为，避免影响正常播放。
      return null;
    }
  }

  /**
   * Creates a platform view video player.
   *
   * @param context application context.
   * @param events event callbacks.
   * @param asset asset to play.
   * @param options options for playback.
   * @return a video player instance.
   */
  // TODO: Migrate to stable API, see https://github.com/flutter/flutter/issues/147039.
  @UnstableApi
  @NonNull
  public static PlatformViewVideoPlayer create(
      @NonNull Context context,
      @NonNull VideoPlayerCallbacks events,
      @NonNull VideoAsset asset,
      @NonNull VideoPlayerOptions options) {
    return new PlatformViewVideoPlayer(
        events,
        asset.getMediaItem(),
        options,
        () -> {
          ExoPlayer.Builder builder = new ExoPlayer.Builder(context);

          // 优先读取 Dart 层通过 MainActivity 下发的分级缓冲配置。
          DefaultLoadControl loadControl = createBufferLoadControl();
          if (loadControl == null && options.backBufferDurationMs != null) {
            if (options.backBufferDurationMs < 0) {
              throw new IllegalArgumentException("backBufferDurationMs must be at least 0");
            }
            if (options.backBufferDurationMs > 0) {
              // Clamp the value to ensure it fits within the int range expected by
              // DefaultLoadControl.
              int backBufferInt =
                  (int) Math.min(options.backBufferDurationMs.longValue(), Integer.MAX_VALUE);
              loadControl =
                  new DefaultLoadControl.Builder()
                      .setBackBuffer(backBufferInt, /* retainBackBufferFromKeyframe= */ true)
                      .build();
            }
          }
          if (loadControl != null) {
            builder.setLoadControl(loadControl);
          }

          androidx.media3.exoplayer.trackselection.DefaultTrackSelector trackSelector =
              new androidx.media3.exoplayer.trackselection.DefaultTrackSelector(context);
          builder
              .setTrackSelector(trackSelector)
              .setMediaSourceFactory(asset.getMediaSourceFactory(context));
          return builder.build();
        });
  }

  @NonNull
  @Override
  protected ExoPlayerEventListener createExoPlayerEventListener(
      @NonNull ExoPlayer exoPlayer, @Nullable SurfaceProducer surfaceProducer) {
    return new PlatformViewExoPlayerEventListener(exoPlayer, videoPlayerEvents);
  }
}
