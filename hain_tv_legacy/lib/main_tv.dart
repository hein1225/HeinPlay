import 'package:flutter/material.dart';
import 'package:hain_tv/app_tv.dart';
import 'package:hain_tv/platform/device_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;
  // TV 版显式标记为 TV 模式，确保焦点、遥控及二维码输入逻辑正确生效。
  DeviceUtils.isTvOverride = true;
  // 不在此处阻塞解码封面：不透明 FlutterView 在解码期间会显示黑底 surface，导致
  // “启动黑屏很久”。封面改由 SplashScreen 用 Image.asset 异步解码并淡入，首帧即
  // 为带进度条的品牌色载入页。
  runApp(const HainTvApp());
}
