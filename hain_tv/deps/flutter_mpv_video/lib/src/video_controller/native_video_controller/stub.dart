/// This file is a part of flutter_mpv (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
import 'package:flutter_mpv/flutter_mpv.dart';

import 'package:flutter_mpv_video/src/video_controller/platform_video_controller.dart';

// Stub declaration for avoiding compilation errors on Dart JS using conditional imports.

class NativeVideoController extends PlatformVideoController {
  static const bool supported = false;

  NativeVideoController._(
    super.player,
    super.configuration,
  );

  static Future<PlatformVideoController> create(
    Player player,
    VideoControllerConfiguration configuration,
  ) =>
      throw UnimplementedError();

  @override
  Future<void> setSize({int? width, int? height}) => throw UnimplementedError();
}
