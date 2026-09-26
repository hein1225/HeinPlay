import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/app_mobile.dart';
import 'package:hain_tv/platform/device_utils.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // 显式进入「边到边」(edge-to-edge) 模式：应用背景铺满系统状态栏与导航栏区域。
  // 不能依赖引擎默认 —— 只有 Android 15+ 会由系统对高 targetSdk 应用强制生效；
  // Android 14 及以下必须自行声明，否则 FlutterView 不延伸到导航栏下方，底部会
  // 露出系统导航栏（浅色系统主题下即一条白边，2026-09-22 用户实测）。
  // 手机版各页面均已用 SafeArea 处理系统栏内边距，故切换后内容位置不变，
  // 只是把背景铺满整屏（进入过播放页再返回也会被重置为 edgeToEdge，行为一致）。
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;
  // 手机版显式标记为非 TV 模式，避免被误判为 TV。
  DeviceUtils.isTvOverride = false;
  // 不在此处阻塞解码封面：避免不透明 FlutterView 在解码期间显示黑底 surface 造成
  // “启动黑屏很久”。封面由 SplashScreen 用 Image.asset 异步解码并淡入。
  runApp(const MobileApp());
}
