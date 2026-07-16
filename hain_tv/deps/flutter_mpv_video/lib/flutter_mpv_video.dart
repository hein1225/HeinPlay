/// This file is a part of flutter_mpv (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

export 'package:flutter_mpv_video/src/video_controller/platform_video_controller.dart';
export 'package:flutter_mpv_video/src/video_controller/video_controller.dart';
export 'package:flutter_mpv_video/src/video_view_parameters.dart';
export 'package:flutter_mpv_video/src/video/video.dart';

export 'package:flutter_mpv_video/src/subtitle/subtitle_view.dart';

export 'package:flutter_mpv_video/flutter_mpv_video_controls/flutter_mpv_video_controls.dart';

/// Backward compatibility export
@Deprecated(
    'Use flutter_mpv_video instead. This will be removed in a future version.')
export 'package:flutter_mpv_video/flutter_mpv_video.dart'
    show Video, VideoController, SubtitleView;
