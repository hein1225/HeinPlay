/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

import {
  EventObserver, LogObserver, MpvEvent, MpvFormat, MpvLib, MpvNode
} from './MpvLib'
import { PlayerState } from './models/PlayerState';
import { image } from '@kit.ImageKit';
import { Chapter } from './models/Chapter';
import {
  AudioTrack, Track, Tracks, SubtitleTrack, VideoTrack
} from './models/Track';
import { Media } from './models/Media';
import { Playlist } from './models/Playlist';
import { PlayerStream } from './models/PlayerStream';
import { PlayerLog } from './models/PlayerLog';
import { AudioParams } from './models/AudioParams';
import { VideoParams } from './models/VideoParams';
import { MpvLogLevel, PlayerConfig } from './models/PlayerConfig';
import { PlaylistMode } from './models/PlaylistMode';
import { hilog } from '@kit.PerformanceAnalysisKit';
import BuildProfile from '../../../BuildProfile';
import { Utils } from './utils/Utils';

interface RawTrack {
  id: number;
  codec: string;
  lang: string;
  title: string;
  type: string;
  selected: boolean;
}

@ObservedV2
export class Player extends XComponentController implements EventObserver, LogObserver {
  native: MpvLib = new MpvLib();
  private config: PlayerConfig;
  /**
   * Current player state.
   */
  @Trace state: PlayerState = new PlayerState();
  /**
   * Player event streams.
   */
  stream: PlayerStream = new PlayerStream();

  /**
   * Initializes mpv player.
   *
   * ```
   * const player = new Player(new PlayerConfig({
   *   vo: "gpu-next"
   * }));
   * ```
   *
   * @param config    Player configuration, optional.
   */
  constructor(config: PlayerConfig = new PlayerConfig()) {
    super();
    this.config = config;

    this.native.addEventObserver(this);
    this.native.addLogObserver(this);
    this.native.registerEventCallback();
    this.native.registerLogCallback();
    this.native.create();

    let level = ""
    switch (this.config.logLevel) {
      case MpvLogLevel.Fatal:
        level = "fatal";
        break;
      case MpvLogLevel.Error:
        level = "error";
        break;
      case MpvLogLevel.Warn:
        level = "warn";
        break;
      case MpvLogLevel.Info:
        level = "info";
        break;
      case MpvLogLevel.V:
        level = "v";
        break;
      case MpvLogLevel.Debug:
        level = "debug";
        break;
      case MpvLogLevel.Trace:
        level = "trace";
        break;
    }
    this.native.requestLogMessages(level);

    // Basic
    this.native.setOptionString("config", "yes");
    this.native.setOptionString("config-dir", this.config.configDir);
    this.native.setOptionString("profile", "fast");
    this.native.setOptionString("idle", "yes");
    this.native.setOptionString("keep-open", "yes");
    this.native.setOptionString("input-ime", "no");
    this.native.setOptionString("input-builtin-bindings", "no");
    this.native.setOptionString("watch-later-options", "start,vid,aid,sid");
    this.native.setOptionString("osc", this.config.osc ? "yes" : "no");
    this.native.setOptionString("osd-level", this.config.osd ? "1" : "0");

    // Render backend
    this.native.setOptionString("vo", this.config.vo);
    this.native.setOptionString("gpu-context", this.config.gpuContext);
    this.native.setOptionString("hwdec", this.config.hwdec ? "ohcodec" : "no");
    this.native.setOptionString("hwdec-codecs", "h264,hevc,mpeg2video,mpeg4,h263,vvc");
    this.native.setOptionString("hwdec-software-fallback", "yes");
    if (this.config.gpuContext === "ohos") {
      this.native.setOptionString("opengl-es", "yes");
      this.native.setOptionString("egl-output-format", "rgba8");
    }

    // Video
    this.native.setOptionString("video-sync", "display-resample");
    this.native.setOptionString("target-colorspace-hint", "yes");
    this.native.setOptionString("interpolation", "yes");
    this.native.setOptionString("correct-downscaling", "no");
    this.native.setOptionString("sigmoid-upscaling", "no");
    this.native.setOptionString("dither-depth", "no");
    this.native.setOptionString("deinterlace", this.config.deinterlace ? "yes" : "no");
    this.native.setOptionString("demuxer-max-bytes", "1024MiB");
    this.native.setOptionString("demuxer-max-back-bytes", "512MiB");

    // Audio
    this.native.setOptionString("volume", "100");
    this.native.setOptionString("alang", this.config.alang);

    // Subtitle and OSD
    this.native.setOptionString("sub-scale-with-window", "no");
    this.native.setOptionString("sub-use-margins", "no");
    this.native.setOptionString("sub-auto", "fuzzy");
    this.native.setOptionString("sub-file-paths", "sub:subtitles");
    this.native.setOptionString("subs-fallback", "yes");
    this.native.setOptionString("slang", this.config.slang);
    this.native.setOptionString("osd-font", "HarmonyOS Sans");

    // Custom Subtitle
    this.native.setOptionString("sub-font-size", "38");
    this.native.setOptionString("sub-color", "#ffffffff");
    this.native.setOptionString("sub-outline-size", "2");
    this.native.setOptionString("sub-outline-color", "#ff000000");
    this.native.setOptionString("sub-bold", "yes");
    this.native.setOptionString("sub-italic", "no");
    this.native.setOptionString("sub-blur", "2");

    this.native.initialize();

    const properties: Map<string, MpvFormat> = new Map([
      ["time-pos/full", MpvFormat.MPV_FORMAT_DOUBLE],
      ["duration/full", MpvFormat.MPV_FORMAT_DOUBLE],
      ["playlist-playing-pos", MpvFormat.MPV_FORMAT_INT64],
      ["track-list", MpvFormat.MPV_FORMAT_NODE],
      ["chapter-list", MpvFormat.MPV_FORMAT_NODE],
      ["video-params", MpvFormat.MPV_FORMAT_NODE],
      ["audio-params", MpvFormat.MPV_FORMAT_NODE],
      ["video-bitrate", MpvFormat.MPV_FORMAT_DOUBLE],
      ["audio-bitrate", MpvFormat.MPV_FORMAT_DOUBLE],
      ["pause", MpvFormat.MPV_FORMAT_FLAG],
      ["paused-for-cache", MpvFormat.MPV_FORMAT_FLAG],
      ["volume", MpvFormat.MPV_FORMAT_DOUBLE],
      ["speed", MpvFormat.MPV_FORMAT_DOUBLE],
      ["media-title", MpvFormat.MPV_FORMAT_STRING],
      ["eof-reached", MpvFormat.MPV_FORMAT_FLAG],
      ["cache-buffering-state", MpvFormat.MPV_FORMAT_DOUBLE],
      ["demuxer-cache-time", MpvFormat.MPV_FORMAT_INT64],
    ]);

    properties.forEach((fmt: MpvFormat, prop: string) => {
      this.native.observeProperty(prop, fmt);
    });
  }

  /**
   * Opens a media or playlist.
   *
   * ```
   * player.open(new Media("file://media/Photo/1310/VID_1/VID_1.mp4"));
   * ```
   *
   * ```
   * player.open(new Playlist([
   *   new Media("file://media/Photo/1310/VID_1/VID_1.mp4"),
   *   new Media("https://www.example.com/sample1.mp4"),
   *   new Media("https://www.example.com/sample2.mp4")
   * ], 0));
   * ```
   *
   * @param files     Media item or playlist to open.
   * @param play      Whether to start playback immediately, optional.
   */
  open(files: Media | Playlist, play: boolean = true): void {
    const playlist = files instanceof Media ?
      new Playlist([files]) :
      files;

    if (playlist.medias.length == 0) {
      return;
    }

    this.state.playlist = playlist;
    this.stream.playlist.add(playlist);

    this.native.command(["stop"]);
    this.native.command(["playlist-clear"]);
    this.native.command(["playlist-play-index", "none"]);
    this.native.setProperty("pause", true);

    playlist.medias.forEach((media: Media) => {
      const options = new Map<string, string>();
      if (media.httpHeaders && media.httpHeaders.size > 0) {
        const headers: string[] = [];
        media.httpHeaders.forEach((value: string, name: string) => {
          const header = `${name}: ${value}`;
          headers.push(`%${header.length}%${header}`);
        });
        options.set("http-header-fields", headers.join(","));
      }
      if (media.start !== undefined) {
        options.set("start", media.start.toString());
      }
      if (media.end !== undefined) {
        options.set("end", media.end.toString());
      }

      const url = Utils.sanitizeUri(media.uri);
      this.native.loadFile(url, options)
    });

    this.native.setProperty("playlist-pos", playlist.index);

    if (play) {
      this.native.setProperty("pause", false);
    }
  }

  /**
   * Stops playback.
   */
  stop(): void {
    this.native.command(["stop"]);
    this.native.command(["playlist-clear"]);
    this.native.command(["playlist-play-index", "none"]);

    const previous = this.state;
    const reset = new PlayerState();
    reset.volume = previous.volume;
    reset.speed = previous.speed;
    reset.playlistMode = previous.playlistMode;
    reset.buffering = false;
    this.state = reset;

    this.stream.playlist.add(reset.playlist);
    this.stream.playing.add(reset.playing);
    this.stream.eof.add(reset.eof);
    this.stream.duration.add(reset.duration);
    this.stream.position.add(reset.position);
    this.stream.buffering.add(reset.buffering);
    this.stream.bufferingPercentage.add(reset.bufferingPercentage);
    this.stream.buffer.add(reset.buffer);
    this.stream.track.add(reset.track);
    this.stream.tracks.add(reset.tracks);
    this.stream.chapters.add(reset.chapters);
    this.stream.videoParams.add(reset.videoParams);
    this.stream.videoBitrate.add(reset.videoBitrate);
    this.stream.audioParams.add(reset.audioParams);
    this.stream.audioBitrate.add(reset.audioBitrate);
  }

  /**
   * Destroys mpv player.
   */
  destroy(): void {
    this.stop();
    this.native.removeEventObserver(this);
    this.native.removeLogObserver(this);
    this.native.removeEventCallbacks();
    this.native.removeLogCallback();
    this.native.destroy();
    this.stream.destroy();
  }

  /**
   * Starts or resumes playback.
   */
  play(): void {
    if (this.state.eof) {
      this.seek(0);
      this.native.setProperty("playlist-pos", 0);
    }
    this.native.setProperty("pause", false);
  }

  /**
   * Pauses playback.
   */
  pause(): void {
    this.native.setProperty("pause", true);
  }

  /**
   * Toggles between playing and paused states.
   */
  playOrPause(): void {
    this.native.command(["cycle", "pause"]);
  }

  /**
   * Seeks to an absolute playback position.
   *
   * @param seconds   Absolute playback position in seconds.
   */
  seek(seconds: number): void {
    this.native.command(["seek", seconds.toFixed(3), "absolute"]);
    this.state.eof = false;
    this.stream.eof.add(false);
  }

  /**
   * Advances to the next playlist item.
   */
  next(): void {
    this.play();
    this.native.command(["playlist-next"]);
  }

  /**
   * Returns to the previous playlist item.
   */
  previous(): void {
    this.play();
    this.native.command(["playlist-prev"]);
  }

  /**
   * Jumps to the the specified playlist item.
   *
   * @param index     Playlist item index.
   */
  jump(index: number): void {
    if (index < 0 || index >= this.state.playlist.medias.length) {
      return;
    }
    this.play();
    this.native.setProperty("playlist-pos", index);
  }

  /**
   * Sets the playback volume.
   *
   * @param volume    Playback volume.
   */
  setVolume(volume: number): void {
    this.native.setProperty("volume", volume);
  }

  /**
   * Sets the playback speed.
   *
   * @param speed     Playback speed.
   */
  setSpeed(speed: number): void {
    if (speed <= 0) {
      return;
    }
    this.native.setProperty("speed", speed);
  }

  /**
   * Selects the video track.
   *
   * @param track     Video track.
   */
  setVideoTrack(track: VideoTrack): void {
    this.native.setProperty("vid", track.id);
    this.state.track.video = track;
    this.stream.track.add(this.state.track);
  }

  disableVideoTrack(): void {
    this.setVideoTrack(VideoTrack.no());
  }

  loadExternalVideoTrack(url: string): void {
    this.native.command(["video-add", url]);
  }

  /**
   * Selects the audio track or loads an external audio track.
   *
   * ```
   * player.setAudioTrack(
   *   AudioTrack.uri(
   *     "https://www.iandevlin.com/html5test/webvtt/v/upc-tobymanley.mp4",
   *     "",
   *     "chi",
   *     "external"
   *   )
   * );
   * ```
   *
   * @param track     Audio track.
   */
  setAudioTrack(track: AudioTrack): void {
    if (track.isUri) {
      this.native.command([
        "audio-add",
        track.id,
        "select",
        track.title.length > 0 ? track.title : "external",
        track.lang.length > 0 ? track.lang : "auto"
      ]);
    } else {
      this.native.setProperty("aid", track.id);
    }
    this.state.track.audio = track;
    this.stream.track.add(this.state.track);
  }

  disableAudioTrack(): void {
    this.setAudioTrack(AudioTrack.no());
  }

  loadExternalAudioTrack(url: string, lang: string = "", title: string = ""): void {
    this.setAudioTrack(AudioTrack.uri(url, "", lang, title));
  }

  /**
   * Selects the subtitle track or loads an external subtitle track.
   *
   * ```
   * player.setSubtitleTrack(
   *   SubtitleTrack.uri(
   *     "https://www.iandevlin.com/html5test/webvtt/upc-video-subtitles-en.vtt",
   *     "",
   *     "chi",
   *     "external"
   *   )
   * );
   * ```
   *
   * @param track     Subtitle track.
   */
  setSubtitleTrack(track: SubtitleTrack): void {
    if (track.isUri) {
      this.native.command([
        "sub-add",
        track.id,
        "select",
        track.title.length > 0 ? track.title : "external",
        track.lang.length > 0 ? track.lang : "auto"
      ]);
    } else {
      this.native.setProperty("sid", track.id);
    }
    this.state.track.subs = track;
    this.stream.track.add(this.state.track);
  }

  disableSubtitleTrack(): void {
    this.setSubtitleTrack(SubtitleTrack.no());
  }

  loadExternalSubtitleTrack(url: string, lang: string = "", title: string = ""): void {
    this.setSubtitleTrack(SubtitleTrack.uri(url, "", lang, title));
  }

  /**
   * Sets the playlist playback mode.
   *
   * @param mode  Playlist playback mode.
   */
  setPlaylistMode(mode: PlaylistMode): void {
    switch (mode) {
      case PlaylistMode.None:
        this.native.command(["playlist-unshuffle"]);
        this.native.setProperty("loop-file", "no");
        this.native.setProperty("loop-playlist", "no");
        break;
      case PlaylistMode.File:
        this.native.command(["playlist-unshuffle"]);
        this.native.setProperty("loop-file", "inf");
        this.native.setProperty("loop-playlist", "no");
        break;
      case PlaylistMode.Playlist:
        this.native.command(["playlist-unshuffle"]);
        this.native.setProperty("loop-file", "no");
        this.native.setProperty("loop-playlist", "inf");
        break;
      case PlaylistMode.Random:
        this.native.setProperty("loop-file", "no");
        this.native.setProperty("loop-playlist", "no");
        this.native.command(["playlist-shuffle"]);
        break;
    }

    this.state.playlistMode = mode;
    this.stream.playlistMode.add(mode);
  }

  setLoopMode(mode: PlaylistMode): void {
    this.setPlaylistMode(mode);
  }

  /**
   * Captures the current video frame as a PixelMap.
   *
   * @param withSub   Whether to include subtitles.
   *
   * @return Captured video frame.
   */
  screenshot(withSub: boolean = true): PixelMap {
    const raw = this.native.commandWithReturn([
      "screenshot-raw",
      withSub ? "subtitles" : "video",
      "bgra"
    ]) as Map<string, MpvNode>;
    const imageOptions: image.InitializationOptions = {
      size: { width: raw["w"], height: raw["h"] },
    }
    return image.createPixelMapSync(raw["data"], imageOptions);
  }

  onSurfaceCreated(surfaceId: string): void {
    this.native.attachSurface(surfaceId);
    this.config.onReady();
  }

  onSurfaceChanged(_: string, rect: SurfaceRect): void {
    this.native.setProperty("ohos-surface-size", `${rect.surfaceWidth}x${rect.surfaceHeight}`);
  }

  onSurfaceDestroyed(_: string): void {
    this.native.detachSurface();
  }

  onPropertyChanged(property: string, value?: string | number | boolean): void {
    switch (typeof value) {
      case "number":
        if (property == "time-pos/full") {
          this.state.position = parseFloat(value.toFixed(3));
          this.stream.position.add(this.state.position);
        } else if (property == "duration/full") {
          this.state.duration = parseFloat(value.toFixed(3));
          this.stream.duration.add(this.state.duration);
        } else if (property == "playlist-playing-pos") {
          this.state.playlist.index = value;
          this.stream.playlist.add(this.state.playlist);
        } else if (property == "volume") {
          this.state.volume = value;
          this.stream.volume.add(value);
        } else if (property == "speed") {
          this.state.speed = value;
          this.stream.speed.add(value);
        } else if (property == "cache-buffering-state") {
          this.state.bufferingPercentage = value;
          this.stream.bufferingPercentage.add(value);
        } else if (property == "demuxer-cache-time") {
          this.state.buffer = value;
          this.stream.buffer.add(value);
        } else if (property == "video-bitrate") {
          this.state.videoBitrate = value;
          this.stream.videoBitrate.add(value);
        } else if (property == "audio-bitrate") {
          this.state.audioBitrate = value;
          this.stream.audioBitrate.add(value);
        }
        break;
      case "string":
        if (property == "media-title") {
          this.state.title = value;
        } else if (property == "track-list") {
          this.loadTracks(value);
        } else if (property == "video-params") {
          this.loadVideoParams(value);
        } else if (property == "audio-params") {
          this.loadAudioParams(value);
        } else if (property == "chapter-list") {
          this.loadChapters(value);
        }
        break;
      case "boolean":
        if (property == "pause") {
          this.state.playing = !value;
          this.stream.playing.add(this.state.playing);
        } else if (property == "paused-for-cache") {
          this.state.buffering = value;
          this.stream.buffering.add(value);
        } else if (property == "eof-reached") {
          this.state.eof = value;
          this.stream.eof.add(value);
          if (value) {
            this.state.playing = false;
            this.state.buffering = false;
            this.state.track = new Track();
            this.state.tracks = new Tracks();
            this.stream.playing.add(false);
            this.stream.buffering.add(false);
            this.stream.track.add(this.state.track);
            this.stream.tracks.add(this.state.tracks);
          }
        }
        break;
      default:
        break;
    }
  }

  onEvent(id: number, name: string): void {
    if (id === MpvEvent.MPV_EVENT_START_FILE) {
      this.state.playing = true;
      this.state.eof = false;
      this.state.buffering = true;
      this.stream.playing.add(true);
      this.stream.eof.add(false);
      this.stream.buffering.add(true);
    }
    if (BuildProfile.DEBUG) {
      hilog.debug(0, "mpv", `[event] ${name}`)
    }
  }

  onLogMessage(prefix: string, level: string, msg: string): void {
    const log = new PlayerLog(prefix, level, msg);
    if (BuildProfile.DEBUG) {
      switch (level) {
        case "fatal":
          hilog.fatal(0, "mpv", log.toString());
          break;
        case "error":
          hilog.error(0, "mpv", log.toString());
          break;
        case "warn":
          hilog.warn(0, "mpv", log.toString());
          break;
        default:
          hilog.debug(0, "mpv", log.toString());
          break;
      }
    }
    this.stream.log.add(log);
    if (level == "error") {
      this.stream.error.add(msg);
    }
  }

  private loadTracks(json: string): void {
    const tracks = new Tracks();
    const selected = new Track();
    let raw = JSON.parse(json) as RawTrack[];

    raw.map((track) => {
      switch (track.type) {
        case "audio":
          const audio = new AudioTrack(track.id, track.codec, track.lang, track.title);
          tracks.audio.push(audio);
          if (track.selected) {
            selected.audio = audio;
          }
          break;
        case "video":
          const video = new VideoTrack(track.id, track.codec, track.lang, track.title);
          tracks.video.push(video);
          if (track.selected) {
            selected.video = video;
          }
          break;
        case "sub":
          const subtitle = new SubtitleTrack(track.id, track.codec, track.lang, track.title);
          tracks.subs.push(subtitle);
          if (track.selected) {
            selected.subs = subtitle;
          }
          break;
      }
    });
    this.state.tracks = tracks;
    this.state.track = selected;
    this.stream.tracks.add(tracks);
    this.stream.track.add(selected);
  }

  private loadChapters(json: string): void {
    this.state.chapters = JSON.parse(json) as Chapter[];
    this.stream.chapters.add(this.state.chapters);
  }

  private loadVideoParams(json: string): void {
    let raw = JSON.parse(json) as Map<string, Object>;
    const params = new VideoParams();
    params.pixelFormat = raw["pixelformat"] ?? "";
    params.hwPixelFormat = raw["hw-pixelformat"] ?? "";
    params.w = raw["w"] ?? 0;
    params.h = raw["h"] ?? 0;
    params.dw = raw["dw"] ?? 0;
    params.dh = raw["dh"] ?? 0;
    params.aspect = raw["aspect"] ?? 0;
    params.par = raw["par"] ?? 0;
    params.sar = raw["sar"] ?? 0;
    params.colormatrix = raw["colormatrix"] ?? "";
    params.colorLevels = raw["colorlevels"] ?? "";
    params.primaries = raw["primaries"] ?? "";
    params.gamma = raw["gamma"] ?? "";
    params.light = raw["light"] ?? "";
    params.chromaLocation = raw["chroma-location"] ?? "";
    params.rotate = raw["rotate"] ?? 0;
    params.stereoIn = raw["stereo-in"] ?? "";
    params.averageBpp = raw["average-bpp"] ?? 0;
    params.alpha = raw["alpha"] ?? "";
    this.state.videoParams = params;
    this.stream.videoParams.add(params);
  }

  private loadAudioParams(json: string): void {
    const raw = JSON.parse(json) as Map<string, Object>;
    const params = new AudioParams();
    params.format = raw["format"] ?? "";
    params.sampleRate = raw["samplerate"] ?? 0;
    params.channels = raw["channels"] ?? "";
    this.state.audioParams = params;
    this.stream.audioParams.add(params);
  }
}
