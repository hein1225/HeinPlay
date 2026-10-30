// Copyright (c) 2023 Hunan OpenValley Digital Industry Development Co., Ltd.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE_ODID file.

import StandardMessageCodec from '@ohos/flutter_ohos/src/main/ets/plugin/common/StandardMessageCodec';
import { CreateMessage} from './Messages';
import { ByteBuffer } from '@ohos/flutter_ohos/src/main/ets/util/ByteBuffer';
import Log from '@ohos/flutter_ohos/src/main/ets/util/Log';

const TAG = "VideoPlayerApiCodec";

export class VideoPlayerApiCodec extends StandardMessageCodec {
  static INSTANCE: VideoPlayerApiCodec = new VideoPlayerApiCodec();

  getByte(n: number): number {
    let byteArray = new Uint8Array(1);
    byteArray[0] = n;
    return byteArray[0] as number;
  }

  readValueOfType(type: number, buffer: ByteBuffer): ESObject {
    switch (type) {
      case this.getByte(128):
        return CreateMessage.fromList(super.readValue(buffer));
      default:
        return super.readValueOfType(type, buffer);
    }
  }

  writeValue(stream: ByteBuffer, value: ESObject): ESObject {
    if (value instanceof CreateMessage) {
      stream.writeUint8(this.getByte(128));
      this.writeValue(stream, (value as CreateMessage).toList());
    } else {
      super.writeValue(stream, value);
    }
  }
}