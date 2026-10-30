/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

import { Media } from "./Media";

@ObservedV2
export class Playlist {
  /**
   * Media list.
   */
  @Trace medias: Media[];
  /**
   * Currently playing Media index.
   */
  @Trace index: number;

  /**
   * Creates a media playlist for playback.
   *
   * @param medias    Medias.
   * @param index     Start playback from customized index, optional.
   */
  constructor(medias: Media[], index: number = 0) {
    this.medias = medias;
    this.index = index;
  }
}
