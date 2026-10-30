/**
 * Copyright (C) 2026 Bao Han <erbws@qq.com>
 */

export class PlayerLog {
  /**
   * The module prefix, identifies the sender of the message.
   */
  prefix: string;
  /**
   * The log level as string.
   */
  level: string;
  /**
   * The log message.
   */
  text: string;

  /**
   * Log message from mpv. You should NEVER create a PlayerLog yourself
   */
  constructor(prefix: string, level: string, text: string) {
    this.prefix = prefix;
    this.level = level;
    this.text = text;
  }

  toString(): string {
    return `[${this.prefix}:${this.level}] ${this.text}`;
  }
}
