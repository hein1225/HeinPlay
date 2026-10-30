/**
 * Copyright (C) 2026. Bao Han <erbws@qq.com>
 */

export type StreamListener<T> = (value: T) => void;

export class Stream<T> {
  private listeners: StreamListener<T>[] = [];
  private equal?: (first: T, second: T) => boolean;
  private lastValue?: T;
  private hasLastValue: boolean = false;
  private closed: boolean = false;

  constructor(equal?: (first: T, second: T) => boolean) {
    this.equal = equal;
  }

  get isClosed(): boolean {
    return this.closed;
  }

  close(): void {
    this.closed = true;
    this.listeners = [];
  }

  listen(callback: StreamListener<T>): void {
    if (!this.closed) {
      this.listeners.push(callback);
    }
  }

  add(value: T): void {
    if (this.closed || this.listeners.length === 0) {
      return;
    }
    if (
      this.equal !== undefined &&
      this.hasLastValue &&
      this.equal(this.lastValue as T, value)
    ) {
      return;
    }
    this.lastValue = value;
    this.hasLastValue = true;

    this.listeners.slice().forEach((callback: StreamListener<T>) => {
      callback(value);
    });
  }
}
