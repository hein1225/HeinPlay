/// This file is a part of flutter_mpv (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.

import 'package:universal_platform/universal_platform.dart';

import 'package:flutter_mpv/src/player/native/player/player.dart';
import 'package:flutter_mpv/src/player/web/player/player.dart';

/// {@template flutter_mpv}
///
/// package:flutter_mpv
/// -----------------
/// A complete video & audio library for Flutter & Dart.
///
/// {@endtemplate}
abstract class FlutterMpv {
  static bool _initialized = false;

  /// {@macro flutter_mpv}
  static void ensureInitialized({String? libmpv}) {
    if (_initialized) return;

    try {
      if (UniversalPlatform.isWindows) {
        nativeEnsureInitialized(libmpv: libmpv);
      } else if (UniversalPlatform.isLinux) {
        nativeEnsureInitialized(libmpv: libmpv);
      } else if (UniversalPlatform.isMacOS) {
        nativeEnsureInitialized(libmpv: libmpv);
      } else if (UniversalPlatform.isIOS) {
        nativeEnsureInitialized(libmpv: libmpv);
      } else if (UniversalPlatform.isAndroid) {
        nativeEnsureInitialized(libmpv: libmpv);
      } else if (UniversalPlatform.isWeb) {
        webEnsureInitialized(libmpv: libmpv);
      }
      _initialized = true;
    } catch (_) {
      print(
        '\n'
        '${'-' * 80}\n'
        'flutter_mpv: ERROR: FlutterMpv.ensureInitialized\n'
        'This indicates that one or more required dependencies could not be located.\n'
        '\n'
        'Refer to "Installation" section of the README for further details:\n'
        'GitHub  : https://github.com/mohammedbakri123/MPx-Player#installation\n'
        'pub.dev : https://pub.dev/packages/flutter_mpv#installation\n'
        '\n'
        'TIP: Copy-paste required packages from the above link to your pubspec.yaml.\n'
        '\n'
        'If you recently added the packages, make sure to re-run the project ("hot-restart" & "hot-reload" is not sufficient for native plugins).\n'
        '${'-' * 80}\n',
      );
      rethrow;
    }
  }
}

/// Backward compatibility alias for FlutterMpv
@Deprecated('Use FlutterMpv instead. This will be removed in a future version.')
typedef MediaKit = FlutterMpv;
