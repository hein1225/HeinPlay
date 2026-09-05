import 'dart:io';

import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hain_tv/app_mobile.dart';
import 'package:hain_tv/platform/device_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 鸿蒙手机版显式标记为非 TV 模式，避免被误判为 TV。
  DeviceUtils.isTvOverride = false;
  // 鸿蒙（OHOS）没有 Android 运行时，ExoPlayer / VLC 均不可用，
  // 视频层只用 fvp（libmdk）。关闭 FFmpeg TLS 严格验证以兼容非标准 IPTV 源。
  if (Platform.operatingSystem == 'ohos') {
    fvp.registerWith(options: {
      'platforms': ['ohos'],
      'global': {
        // 关闭 FFmpeg TLS 严格验证，兼容非标准端口/自签证书源。
        // analyzeduration/probesize 调小：缩短组播直播流首次 initialize 的探测窗口，
        // 修复换台慢（默认 5s → <1s）。
        'avformat': 'tls_verify=0,analyzeduration=500000,probesize=2097152',
        'ffmpeg.loglevel': 'info',
      },
    });
  }
  // 鸿蒙手机版复用 MobileApp（竖屏触屏布局），不引入桌面专属的 window_manager /
  // 便携存储 / win32 等依赖。
  runApp(const MobileApp());
}
