// Copyright 2013 The Flutter Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

package io.flutter.plugins.videoplayer;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

public class VideoPlayerOptions {
  public boolean mixWithOthers;

  /**
   * The duration of the back buffer in milliseconds, used to configure ExoPlayer's load control.
   */
  @Nullable public Long backBufferDurationMs;

  /**
   * 直播路径专用：为 true 时，ExoPlayer 构建启用 ffmpeg 音频软解渲染器回退
   * （解 MediaCodec 硬解不了的 mp2 等）。仅当 Dart 直播请求带
   * `x-heinplay-soft-audio: 1` 且原生据此设置本标志时置 true；点播保持 false → 纯硬解。
   */
  public boolean enableFfmpegAudioSoftDecode;

  public VideoPlayerOptions() {}

  /** Copy constructor to ensure all options are reliably copied. */
  public VideoPlayerOptions(@NonNull VideoPlayerOptions other) {
    this.mixWithOthers = other.mixWithOthers;
    this.backBufferDurationMs = other.backBufferDurationMs;
    this.enableFfmpegAudioSoftDecode = other.enableFfmpegAudioSoftDecode;
  }
}
