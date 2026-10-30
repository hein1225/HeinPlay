/**
 * Copyright (C) 2026. Bao Han <erbws@qq.com>
 */

import { util } from '@kit.ArkTS';

export class Utils {
  static sanitizeUri(uri: string): string {
    if (!uri.startsWith("file://")) {
      return uri;
    }

    const fileUri = Utils.decode(uri.substring("file://".length));

    if (fileUri.startsWith("docs/storage/Users/currentUser/")) {
      return fileUri.substring("docs".length);
    }

    if (fileUri.startsWith("media/")) {
      return fileUri.replace("media/", "/data/storage/el2/media/");
    }

    const separator = fileUri.indexOf("/");
    if (separator > 0) {
      const bundleName = fileUri.substring(0, separator);
      let sandboxPath = fileUri.substring(separator);
      const sandboxPrefix = "/data/storage/el2/base/";
      if (sandboxPath.startsWith(sandboxPrefix)) {
        sandboxPath = sandboxPath.substring(sandboxPrefix.length);
      }
      const appDataPrefix =
        `/storage/Users/currentUser/appdata/el2/base/${bundleName}`;
      return `${appDataPrefix}/${sandboxPath}`;
    }

    return uri;
  }

  private static hexToDec(value: number): number {
    if (value >= 0x30 && value <= 0x39) {
      return value - 0x30;
    }
    if (value >= 0x61 && value <= 0x66) {
      return value - 0x61 + 10;
    }
    if (value >= 0x41 && value <= 0x46) {
      return value - 0x41 + 10;
    }
    return 0;
  }

  private static decode(value: string): string {
    const decoded: number[] = [];
    const encoder = util.TextEncoder.create("utf-8");
    let segmentStart = 0;
    let index = 0;

    while (index < value.length) {
      if (value.charCodeAt(index) === 0x25) {
        if (index + 2 >= value.length) {
          return value;
        }

        Utils.appendEncoded(decoded, encoder, value.substring(segmentStart, index));
        const high = Utils.hexToDec(value.charCodeAt(index + 1));
        const low = Utils.hexToDec(value.charCodeAt(index + 2));
        decoded.push(high << 4 | low);
        index += 3;
        segmentStart = index;
        continue;
      }
      index++;
    }

    Utils.appendEncoded(decoded, encoder, value.substring(segmentStart));
    return util.TextDecoder.create("utf-8").decodeToString(new Uint8Array(decoded));
  }

  private static appendEncoded(
    target: number[],
    encoder: util.TextEncoder,
    value: string
  ): void {
    if (value.length === 0) {
      return;
    }
    const encoded = encoder.encodeInto(value);
    for (let index = 0; index < encoded.length; index++) {
      target.push(encoded[index]);
    }
  }
}
