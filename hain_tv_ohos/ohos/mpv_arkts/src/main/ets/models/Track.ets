/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

@ObservedV2
class _Track {
  /**
   * Track id, could be sid/aid/vid, auto, no or uri.
   */
  @Trace id: string = "auto";
  /**
   * The codec name used by this track, for example h264. Unavailable in some rare cases.
   */
  @Trace codec: string = "";
  /**
   * Track language as identified by the file. Not always available.
   */
  @Trace lang: string = "";
  /**
   * Track title as it is stored in the file. Not always available.
   */
  @Trace title: string = "";

  constructor(
    id: number | string = "auto",
    codec: string = "",
    lang: string = "",
    title: string = ""
  ) {
    this.id = id.toString();
    this.codec = codec;
    this.lang = lang;
    this.title = title;
  }
}

export class VideoTrack extends _Track {
  static auto(): VideoTrack {
    return new VideoTrack("auto");
  }

  static no(): VideoTrack {
    return new VideoTrack("no");
  }
}

export class AudioTrack extends _Track {
  isUri: boolean;

  constructor(
    id: number | string = "auto",
    codec: string = "",
    lang: string = "",
    title: string = "",
    isUri: boolean = false
  ) {
    super(id, codec, lang, title);
    this.isUri = isUri;
  }

  static auto(): AudioTrack {
    return new AudioTrack("auto");
  }

  static no(): AudioTrack {
    return new AudioTrack("no");
  }

  static uri(
    uri: string,
    codec: string = "",
    lang: string = "",
    title: string = ""
  ): AudioTrack {
    return new AudioTrack(uri, codec, lang, title, true);
  }
}

export class SubtitleTrack extends _Track {
  isUri: boolean;

  constructor(
    id: number | string = "auto",
    codec: string = "",
    lang: string = "",
    title: string = "",
    isUri: boolean = false
  ) {
    super(id, codec, lang, title);
    this.isUri = isUri;
  }

  static auto(): SubtitleTrack {
    return new SubtitleTrack("auto");
  }

  static no(): SubtitleTrack {
    return new SubtitleTrack("no");
  }

  static uri(
    uri: string,
    codec: string = "",
    lang: string = "",
    title: string = ""
  ): SubtitleTrack {
    return new SubtitleTrack(uri, codec, lang, title, true);
  }
}

@ObservedV2
export class Track {
  /**
   * Currently selected video track.
   */
  @Trace video: VideoTrack = VideoTrack.auto();
  /**
   * Currently selected audio track.
   */
  @Trace audio: AudioTrack = AudioTrack.auto();
  /**
   * Currently selected subtitle track.
   */
  @Trace subs: SubtitleTrack = SubtitleTrack.auto();
}

@ObservedV2
export class Tracks {
  /**
   * Available video tracks.
   */
  @Trace video: VideoTrack[] = [];
  /**
   * Available audio tracks.
   */
  @Trace audio: AudioTrack[] = [];
  /**
   * Available subtitle tracks.
   */
  @Trace subs: SubtitleTrack[] = [];
}
