import 'package:flutter/material.dart';
import 'package:fvp/fvp.dart' as fvp;
import 'package:hain_tv/app_linux.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:window_manager/window_manager.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 提升内存图片缓存上限，确保各页面海报在切换页/返回时不重新解码或重新联网，
  // 直到软件重启（配合 CachedNetworkImage 的磁盘缓存，切换页即瞬时显示，不再刷新）。
  PaintingBinding.instance.imageCache
    ..maximumSizeBytes = 256 << 20
    ..maximumSize = 2000;

  // 初始化桌面窗口管理，用于 Linux 全屏/取消全屏等控制。
  // 完整支持原生 Wayland：不强制 GDK_BACKEND，GTK 在 Wayland 会话下原生嵌入，
  // fvp/libmdk 通过 EGL/VA-API 在 Wayland 下正常渲染视频。
  await windowManager.ensureInitialized();
  // 显式设置窗口标题，避免中文在原生标题栏出现乱码。
  await windowManager.setTitle('海因影视');

  // Linux 版使用 FVP 作为 video_player 后端（基于 libmdk，支持 X11 与 Wayland）。
  // 关闭 FFmpeg TLS 严格验证，避免非标准端口/自签证书源被服务器拒绝。
  fvp.registerWith(options: {
    'platforms': ['linux'],
    'lowLatency': 1,
    // 补 KeyFrame(=Fast) 标志：fvp 包默认 seek 标志缺该位会退化为精确 seek
    // （逐帧解码到目标位置），点播续播/拖进度条会长时间卡顿（详见
    // player_backend_factory.dart 中 Android 段的同一说明）。
    'fastSeek': true,
    'global': {
      // 关闭 FFmpeg TLS 严格验证，兼容非标准端口/自签证书源。
      // analyzeduration/probesize 调小：缩短组播直播流首次 initialize 的探测窗口，
      // 修复换台慢（默认 5s → <1s）。
      // reconnect*/http_persistent：HLS 子分片请求偶发连接失败/复用异常时自动重连，
      // 避免“出声无画面→卡死”（与 Windows 端配置一致）。
      'avformat': 'tls_verify=0:analyzeduration=500000:probesize=2097152'
          ':reconnect=1:reconnect_streamed=1:reconnect_delay_max=2:http_persistent=1',
      // 与 Windows 端保持一致：强制 fvp 使用 FFmpeg 内置 IO(demuxer.io=0)，
      // 而非 MDK 自带的 mdkio 模块(demuxer.io=1)。mdkio 对 HLS 子分片请求不继承
      // player 级 avio.headers（UA/Referer/Origin），分片会被 CDN 拒绝→出声无画面；
      // 改用 FFmpeg avio 后子请求继承完整 header，直连即可正常播放，无需退回代理。
      'demuxer.io': '0',
      'ffmpeg.loglevel': 'info',
    },
  });

  // Linux 版复用 TV 版页面布局，标记为 TV 模式以确保焦点、遥控逻辑生效；
  // 配合 Steam Input（手柄 → 方向键/Enter/Esc 映射）即可在 Steam Deck 等掌机上用手柄操作。
  DeviceUtils.isTvOverride = true;

  runApp(const HainLinuxApp());
}
