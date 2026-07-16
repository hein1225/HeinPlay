// This file is a part of flutter_mpv
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#include "include/flutter_mpv_video/flutter_mpv_video_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#ifndef MEDIA_KIT_LIBS_NOT_FOUND

#include "media_kit_video_plugin.h"

void FlutterMpvVideoPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  flutter_mpv_video::FlutterMpvVideoPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}

#else

#include <iostream>

void FlutterMpvVideoPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  std::cout << "flutter_mpv: WARNING: package:flutter_mpv_libs_*** not found."
            << std::endl;
}

#endif
