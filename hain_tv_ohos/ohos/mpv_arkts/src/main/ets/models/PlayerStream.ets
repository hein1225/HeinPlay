/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

import { AudioParams } from "./AudioParams";
import { Chapter } from "./Chapter";
import { PlayerLog } from "./PlayerLog";
import { Track, Tracks } from "./Track";
import { Playlist } from "./Playlist";
import { PlaylistMode } from "./PlaylistMode";
import { VideoParams } from "./VideoParams";
import { Stream } from "../utils/Stream";

function samePlaylist(first: Playlist, second: Playlist): boolean {
  if (first.index !== second.index || first.medias.length !== second.medias.length) {
    return false;
  }
  for (let index = 0; index < first.medias.length; index++) {
    if (first.medias[index].uri !== second.medias[index].uri) {
      return false;
    }
  }
  return true;
}

function sameTrack(first: Track, second: Track): boolean {
  return first.video.id === second.video.id &&
    first.video.codec === second.video.codec &&
    first.video.lang === second.video.lang &&
    first.video.title === second.video.title &&
    first.audio.id === second.audio.id &&
    first.audio.codec === second.audio.codec &&
    first.audio.lang === second.audio.lang &&
    first.audio.title === second.audio.title &&
    first.subs.id === second.subs.id &&
    first.subs.codec === second.subs.codec &&
    first.subs.lang === second.subs.lang &&
    first.subs.title === second.subs.title;
}

function sameTracks(first: Tracks, second: Tracks): boolean {
  if (
    first.video.length !== second.video.length ||
    first.audio.length !== second.audio.length ||
    first.subs.length !== second.subs.length
  ) {
    return false;
  }
  for (let index = 0; index < first.video.length; index++) {
    if (
      first.video[index].id !== second.video[index].id ||
      first.video[index].codec !== second.video[index].codec ||
      first.video[index].lang !== second.video[index].lang ||
      first.video[index].title !== second.video[index].title
    ) {
      return false;
    }
  }
  for (let index = 0; index < first.audio.length; index++) {
    if (
      first.audio[index].id !== second.audio[index].id ||
      first.audio[index].codec !== second.audio[index].codec ||
      first.audio[index].lang !== second.audio[index].lang ||
      first.audio[index].title !== second.audio[index].title
    ) {
      return false;
    }
  }
  for (let index = 0; index < first.subs.length; index++) {
    if (
      first.subs[index].id !== second.subs[index].id ||
      first.subs[index].codec !== second.subs[index].codec ||
      first.subs[index].lang !== second.subs[index].lang ||
      first.subs[index].title !== second.subs[index].title
    ) {
      return false;
    }
  }
  return true;
}

function sameChapters(first: Chapter[], second: Chapter[]): boolean {
  if (first.length !== second.length) {
    return false;
  }
  for (let index = 0; index < first.length; index++) {
    if (
      first[index].title !== second[index].title ||
      first[index].time !== second[index].time
    ) {
      return false;
    }
  }
  return true;
}

function sameLog(first: PlayerLog, second: PlayerLog): boolean {
  return first.prefix === second.prefix &&
    first.level === second.level &&
    first.text === second.text;
}

export class PlayerStream {
  /**
   * Currently opened files.
   */
  playlist: Stream<Playlist> = new Stream<Playlist>(samePlaylist);
  /**
   * Whether player is playing.
   */
  playing: Stream<boolean> = new Stream<boolean>((first: boolean, second: boolean) => first === second);
  /**
   * Whether end of file reached.
   */
  eof: Stream<boolean> = new Stream<boolean>((first: boolean, second: boolean) => first === second);
  /**
   * Current playback duration in seconds (0.000).
   */
  duration: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * Current playback position in seconds (0.000).
   */
  position: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * 🔴 HeinPlay 新增（2026-10-08）：在途 seek 计数（0 = 空闲）。
   *
   * 【为什么需要】mpv 的 `time-pos` 在 seek 期间并不可信：它会先吐出**上一次
   *   播放位置的残留值**，再逐步收敛到新落点。若把这期间的采样直接上报给
   *   Flutter，就会出现「定位好了又往后跳一段」——因为残留值被当成了真位置。
   *
   * 【对标 AVP】AVP 插件在原生侧用 `if (this.isSeeking) return this.seekPosition;`
   *   屏蔽了 seek 期间的原始时钟（见 video_player_ohos/VideoPlayer.ets getPosition）。
   *   本字段即 mpv 侧的等价物，语义完全对齐。
   *
   * 🔴 2026-10-08 修订（关键）：由 `Stream<boolean>` 改为 `Stream<number>` 世代计数。
   *
   * 【为什么不能用 boolean】`Stream.add()` 有值去重（utils/Stream.ets L37-43）：
   *   相同值直接 return，**不通知监听者**。而 seek 是可重入的 ——
   *   用户连按快进时，上一次 seek 尚未收到 PLAYBACK_RESTART（值仍为 true），
   *   第二次 `add(true)` 被去重丢弃；但上一次的 PLAYBACK_RESTART 到达时
   *   会把值置回 false，于是**第二次 seek 的整个定位期处于无守卫状态**，
   *   残留 time-pos 直接污染 Dart 的 `_position` → 用户感知「定位后又往后跳」。
   *   真机佐证（h12）：20:12:35.269 / 36.159 / 37.108 三次 seek 间隔 0.9s，
   *   而单次 seek 需 5-6s，playback-restart 仅在 42.873 出现一次。
   *
   * 【世代计数为什么正确】每次 seek 自增，数值**永不重复**，去重失效 →
   *   监听者必然收到每次置位。MPV_EVENT_PLAYBACK_RESTART 到达时**递减**，
   *   归零才表示「所有在途 seek 都已完成」，与可重入语义严格对应。
   *
   * 置位：发出 seek 命令时自增；复位：收到 MPV_EVENT_PLAYBACK_RESTART 时递减。
   * `seekingCount > 0` 等价于 AVP 的 `isSeeking`。
   */
  seekingCount: Stream<number> = new Stream<number>();
  /**
   * Current volume (0-130).
   */
  volume: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * Current playback speed.
   */
  speed: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * Whether playback is paused because of waiting for the cache.
   */
  buffering: Stream<boolean> = new Stream<boolean>((first: boolean, second: boolean) => first === second);
  /**
   * The percentage (0-100) of the cache fill status until the player will unpause. (related to buffering).
   */
  bufferingPercentage: Stream<number> =
    new Stream<number>((first: number, second: number) => first === second);
  /**
   * Current buffer position in seconds.
   */
  buffer: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * Current playlist or file loop mode.
   */
  playlistMode: Stream<PlaylistMode> = new Stream<PlaylistMode>();
  /**
   * Currently selected video, audio and subtitle track.
   */
  track: Stream<Track> = new Stream<Track>(sameTrack);
  /**
   * Available video, audio and subtitle tracks.
   */
  tracks: Stream<Tracks> = new Stream<Tracks>(sameTracks);
  /**
   * Available chapters.
   */
  chapters: Stream<Chapter[]> = new Stream<Chapter[]>(sameChapters);
  /**
   * Video params.
   */
  videoParams: Stream<VideoParams> = new Stream<VideoParams>();
  /**
   * Video bitrate.
   */
  videoBitrate: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * Audio params.
   */
  audioParams: Stream<AudioParams> = new Stream<AudioParams>();
  /**
   * Audio bitrate.
   */
  audioBitrate: Stream<number> = new Stream<number>((first: number, second: number) => first === second);
  /**
   * Stream of mpv log.
   */
  log: Stream<PlayerLog> = new Stream<PlayerLog>(sameLog);
  /**
   * Internal error stream.
   */
  error: Stream<string> = new Stream<string>();

  /**
   * Cancel all listeners
   */
  destroy(): void {
    this.playlist.close();
    this.playing.close();
    this.eof.close();
    this.duration.close();
    this.position.close();
    this.seekingCount.close();
    this.volume.close();
    this.speed.close();
    this.buffering.close();
    this.bufferingPercentage.close();
    this.buffer.close();
    this.playlistMode.close();
    this.track.close();
    this.tracks.close();
    this.chapters.close();
    this.videoParams.close();
    this.videoBitrate.close();
    this.audioParams.close();
    this.audioBitrate.close();
    this.log.close();
    this.error.close();
  }
}
