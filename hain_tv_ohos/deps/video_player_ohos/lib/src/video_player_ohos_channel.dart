// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/services.dart';

class VideoPlayerOhosChannel {
  static final channel = MethodChannel('plugins.flutter.io/video_player_ohos');

  static Future<int> getFileFdByPath(String? path) async {
    int fileFd = -1;
    if (path == null) {
      return fileFd;
    }
    fileFd = await channel.invokeMethod('getFileFdByPath', {
      'filePath': path,
    });
    return fileFd;
  }
}
