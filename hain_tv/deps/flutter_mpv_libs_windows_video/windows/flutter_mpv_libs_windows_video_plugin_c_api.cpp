#include "include/flutter_mpv_libs_windows_video/flutter_mpv_libs_windows_video_plugin_c_api.h"

#include <iostream>

#include <flutter/plugin_registrar_windows.h>

void FlutterMpvLibsWindowsVideoPluginCApiRegisterWithRegistrar(FlutterDesktopPluginRegistrarRef registrar) {
  std::cout << "package:flutter_mpv_libs_windows_video registered." << std::endl;
}
