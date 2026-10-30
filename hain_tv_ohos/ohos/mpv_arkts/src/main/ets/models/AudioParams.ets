/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

@ObservedV2
export class AudioParams {
  /**
   * The sample format as string. This uses the same names as used in other places of mpv.
   */
  @Trace format: string = "";
  /**
   * Sample rate.
   */
  @Trace sampleRate: number = 0;
  /**
   * The channel layout as a string. This is similar to what the --audio-channels accepts.
   */
  @Trace channels: string = "";
}
