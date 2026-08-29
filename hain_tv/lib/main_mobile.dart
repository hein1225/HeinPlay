import 'package:flutter/material.dart';
import 'package:hain_tv/app_mobile.dart';
import 'package:hain_tv/platform/device_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 手机版显式标记为非 TV 模式，避免被误判为 TV。
  DeviceUtils.isTvOverride = false;
  // 不在此处阻塞解码封面：避免不透明 FlutterView 在解码期间显示黑底 surface 造成
  // “启动黑屏很久”。封面由 SplashScreen 用 Image.asset 异步解码并淡入。
  runApp(const MobileApp());
}
