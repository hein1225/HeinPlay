/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

import { Chapter } from "./Chapter";
import { AudioParams } from "./AudioParams";
import { Track, Tracks } from "./Track";
import { Playlist } from "./Playlist";
import { VideoParams } from "./VideoParams";
import { PlaylistMode } from "./PlaylistMode";

@ObservedV2
export class PlayerState {
  /**
   * Currently opened files.
   */
  @Trace playlist: Playlist = new Playlist([]);
  /**
   * Whether player is playing.
   */
  @Trace playing: boolean = false;
  /**
   * Whether end of file reached.
   */
  @Trace eof: boolean = false;
  /**
   * File title.
   */
  @Trace title: string = "";
  /**
   * Current playback duration in seconds (0.000).
   */
  @Trace duration: number = 0;
  /**
   * Current playback position in seconds (0.000).
   */
  @Trace position: number = 0;
  /**
   * Current volume (0-130).
   */
  @Trace volume: number = 100.0;
  /**
   * Current playback speed.
   */
  @Trace speed: number = 1.0;
  /**
   * Whether playback is paused because of waiting for the cache.
   */
  @Trace buffering: boolean = true;
  /**
   * The percentage (0-100) of the cache fill status until the player will unpause. (related to buffering).
   */
  @Trace bufferingPercentage: number = 0;
  /**
   * Current buffer position in seconds.
   */
  @Trace buffer: number = 0;
  /**
   * Current playlist or file loop mode.
   */
  @Trace playlistMode: PlaylistMode = PlaylistMode.None;
  /**
   * Currently selected video, audio and subtitle track.
   */
  @Trace track: Track = new Track();
  /**
   * Available video, audio and subtitle tracks.
   */
  @Trace tracks: Tracks = new Tracks();
  /**
   * Available chapters.
   */
  @Trace chapters: Chapter[] = [];
  /**
   * Video params.
   */
  @Trace videoParams: VideoParams = new VideoParams();
  /**
   * Video bitrate.
   */
  @Trace videoBitrate: number = 0;
  /**
   * Audio params.
   */
  @Trace audioParams: AudioParams = new AudioParams();
  /**
   * Audio bitrate.
   */
  @Trace audioBitrate: number = 0;
}
