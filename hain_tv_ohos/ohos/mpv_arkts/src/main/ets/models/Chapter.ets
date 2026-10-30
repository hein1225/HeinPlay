/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

@ObservedV2
export class Chapter {
  /**
   * Chapter title as stored in the file. Not always available.
   */
  @Trace title: string = "";
  /**
   * Chapter start time in seconds as float.
   */
  @Trace time: number = 0;
}