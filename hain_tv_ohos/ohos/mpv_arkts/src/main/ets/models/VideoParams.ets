/**
 * Copyright (C) 2025 Bao Han <erbws@qq.com>
 */

@ObservedV2
export class VideoParams {
  /**
   * The pixel format as string. This uses the same names as used in other places of mpv.
   */
  @Trace pixelFormat: string = "";
  /**
   * The underlying pixel format as string. This is relevant for some cases of hardware decoding and unavailable otherwise.
   */
  @Trace hwPixelFormat: string = "";
  /**
   * Video size as integers, with no aspect correction applied.
   */
  @Trace w: number = 0;
  /**
   * Video size as integers, with no aspect correction applied.
   */
  @Trace h: number = 0;
  /**
   * Video size as integers, scaled for correct aspect ratio.
   */
  @Trace dw: number = 0;
  /**
   * Video size as integers, scaled for correct aspect ratio.
   */
  @Trace dh: number = 0;
  /**
   * Display aspect ratio as double.
   */
  @Trace aspect: number = 0;
  /**
   * Pixel aspect ratio.
   */
  @Trace par: number = 0;
  /**
   * Storage aspect ratio.
   */
  @Trace sar: number = 0;
  /**
   * The colormatrix in use as string. (Exact values subject to change.)
   */
  @Trace colormatrix: string = "";
  /**
   * The color levels as string. (Exact values subject to change.)
   */
  @Trace colorLevels: string = "";
  /**
   * The primaries in use as string. (Exact values subject to change.)
   */
  @Trace primaries: string = "";
  /**
   * The gamma function in use as string. (Exact values subject to change.)
   */
  @Trace gamma: string = "";
  /**
   * The light type in use as a string. (Exact values subject to change.)
   */
  @Trace light: string = "";
  /**
   * Chroma location as string. (Exact values subject to change.)
   */
  @Trace chromaLocation: string = "";
  /**
   * Intended display rotation in degrees (clockwise).
   */
  @Trace rotate: number = 0;
  /**
   * Source file stereo 3D mode.
   */
  @Trace stereoIn: string = "";
  /**
   * Average bits-per-pixel as integer. Subsampled planar formats use a different resolution, which is the reason this value can sometimes be odd or confusing. Can be unavailable with some formats.
   */
  @Trace averageBpp: number = 0;
  /**
   * Alpha type. If the format has no alpha channel, this will be unavailable (but in future releases, it could change to no). If alpha is present, this is set to straight or premul.
   */
  @Trace alpha: string = "";
}