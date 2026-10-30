import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/app_mobile.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/utils/app_logger.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ⚠️⚠️ 鸿蒙引擎的 SystemChrome.setEnabledSystemUIMode 是一个**永不回复**的
  // channel 调用，绝不能 await 在 runApp() 之前——实测会导致白屏。
  //
  // 根因（flutter_ohos 引擎缺陷）：oh_modules/@ohos/flutter_ohos 的
  // embedding/engine/systemchannels/PlatformChannel.ets 第 500 行
  // `case "SystemChrome.setEnabledSystemUIMode":` 分支里，try 块只调用了
  // platformMessageHandler.showSystemUiMode(mode)，**漏了 result.success(null)**，
  // 只有 catch 分支才回 result.error。对比同文件相邻的
  // setEnabledSystemUIOverlays / setSystemUIChangeListener 分支都有 result.success(null)。
  // 于是平台侧正常执行但不回消息，Dart 侧 await 永久挂起。
  // 若把它放在 runApp 之前，Dart 入口直接卡死 → 应用白屏、无崩溃日志、
  // 引擎侧却一切正常（实测 release HAP 启动后 30 秒内零 Dart 输出）。
  //
  // 处理：改为「不 await + 兜底超时」，既拿到 edge-to-edge 效果，
  // 又保证任何情况下都不会阻塞启动。失败/超时仅打印，不影响后续流程。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge).timeout(
    const Duration(milliseconds: 300),
    onTimeout: () {
      debugPrint('SystemChrome.setEnabledSystemUIMode 超时（鸿蒙引擎不回消息，已忽略）');
    },
  ).catchError((Object e) {
    debugPrint('SystemChrome.setEnabledSystemUIMode 失败（已忽略）: $e');
  });

  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;
  // 鸿蒙手机版显式标记为非 TV 模式，避免被误判为 TV。
  DeviceUtils.isTvOverride = false;

  // 与安卓版 main.dart 对齐：在 runApp 之前完成应用信息与文件日志初始化。
  // 此前这两步只由 SplashScreen 触发，插件缺失时会在启动早期反复抛
  // MissingPluginException（实测 554 次）且日志目录不可用。
  //
  // ⚠️ 两处都必须带超时兜底：runApp() 之前的任何 await 一旦永久挂起，
  // 结果都是「白屏 + 无崩溃日志」，极难排查（edgeToEdge 那次就是这么踩的）。
  // 这两个初始化只是锦上添花，绝不能成为启动的单点故障。
  try {
    await AppInfoService.init().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('AppInfoService 初始化失败（已忽略，不阻塞启动）: $e');
  }
  try {
    await AppLogger.initialize().timeout(const Duration(seconds: 3));
  } catch (e) {
    debugPrint('AppLogger 初始化失败（已忽略，不阻塞启动）: $e');
  }

  // 🔴 2026-10-06：fvp（libmdk）已从鸿蒙侧移除，mpv 接管全部播放角色。
  // 非标准源/自签证书兼容现由 mpv 的 tls_verify=0 等价项 + 去广告代理承担，
  // 不再需要此处 fvp.registerWith 注册。
  //
  // 鸿蒙（OHOS）没有 Android 运行时，ExoPlayer / VLC 均不可用；
  // 现仅保留 mpv（默认）与系统原生 avplayer（兜底）。
  // 鸿蒙手机版复用 MobileApp（竖屏触屏布局），不引入桌面专属的 window_manager /
  // 便携存储 / win32 等依赖。
  runApp(const MobileApp());
}
