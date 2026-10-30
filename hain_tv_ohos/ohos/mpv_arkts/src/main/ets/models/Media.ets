/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

export interface MediaOptions {
  /**
   * HTTP headers.
   */
  httpHeaders?: Map<string, string>;
  /**
   * Media start position.
   */
  start?: number;
  /**
   * Media end position.
   */
  end?: number;
}

export class Media {
  /**
   * Media uri.
   */
  uri: string;
  /**
   * HTTP headers.
   */
  httpHeaders?: Map<string, string>;
  /**
   * Media start position.
   */
  start?: number;
  /**
   * Media end position.
   */
  end?: number;

  /**
   * Creates a media for playback.
   *
   * @param uri           Media uri.
   * @param options       HTTP headers, start position and end position, optional.
   */
  constructor(uri: string, options: MediaOptions = {}) {
    this.uri = uri;
    this.httpHeaders = options.httpHeaders;
    this.start = options.start;
    this.end = options.end;
  }
}
