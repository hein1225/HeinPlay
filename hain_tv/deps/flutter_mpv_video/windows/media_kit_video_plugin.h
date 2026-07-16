// This file is a part of flutter_mpv
// (https://github.com/media-kit/media-kit).
//
// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
// All rights reserved.
// Use of this source code is governed by MIT license that can be found in the
// LICENSE file.
#ifndef MEDIA_KIT_VIDEO_PLUGIN_H_
#define MEDIA_KIT_VIDEO_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <Windows.h>
#include <functional>
#include <queue>
#include <mutex>

#include "video_output_manager.h"

namespace flutter_mpv_video {

class FlutterMpvVideoPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  FlutterMpvVideoPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~FlutterMpvVideoPlugin();

  FlutterMpvVideoPlugin(const FlutterMpvVideoPlugin&) = delete;
  FlutterMpvVideoPlugin& operator=(const FlutterMpvVideoPlugin&) = delete;

 private:
  static constexpr UINT kMainThreadTaskMessage = WM_USER + 1001;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  void RunOnMainThread(std::function<void()> task);
  static LRESULT CALLBACK WindowProcDelegate(HWND hwnd, UINT message, WPARAM wParam, LPARAM lParam);
  void ProcessMainThreadTasks();
  
  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_ =
      nullptr;
  std::unique_ptr<VideoOutputManager> video_output_manager_ = nullptr;
  HWND flutter_window_ = nullptr;
  WNDPROC original_window_proc_ = nullptr;
  std::queue<std::function<void()>> main_thread_tasks_;
  std::mutex main_thread_tasks_mutex_;
  static FlutterMpvVideoPlugin* instance_;
};

}  // namespace flutter_mpv_video

#endif  // MEDIA_KIT_VIDEO_PLUGIN_H_
