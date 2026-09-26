import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;
import 'package:video_player_android/video_player_android.dart';

import '../services/user_data_service.dart';
import '../utils/mdk_log_bridge.dart';
import 'exo_player_backend.dart';
import 'fvp_backend.dart';
import 'video_player_backend.dart';
import 'vlc_backend.dart';

class PlayerBackendFactory {
  /// 将 video_player 平台实现恢复为 Android 原生 ExoPlayer。
  ///
  /// 某些插件可能会全局替换 [VideoPlayerPlatform.instance]，
  /// 使用 ExoPlayer 前显式恢复官方 Android 实现。
  static void _restoreAndroidVideoPlayer() {
    if (Platform.isAndroid) {
      AndroidVideoPlayer.registerWith();
    }
  }

  /// 在 Android 上注册 fvp（libmdk/ffmpeg 网络栈），替代 ExoPlayer。
  ///
  /// fvp 用 ffmpeg 网络栈，能连部分 ExoPlayer(OkHttp) 无法连通的 IPTV 域名。
  static void _restoreAndroidFvp() {
    if (Platform.isAndroid) {
      fvp.registerWith(options: {
        'platforms': ['android'],
        // ⚠️ lowLatency 置 0（2026-09-22 候选修复，**未证实为充分原因**）：
        // lowLatency=1 会在 player 创建时（prepare 之前）写入三个 player 级属性
        // （video_player_mdk.dart:314-322），其中 `avformat.fflags=+nobuffer`
        // 按 mdk 源码自注「+nobuffer: the 1st key-frame packet is dropped」，
        // 且这些属性 open 之后无法覆盖。**但 22:21 日志实测：置 0 后 fvp 症状
        // 完全不变**（position 仍在 seek 目标附近冻结、buffered 恒等于 position），
        // 因此 nobuffer 只是可疑项、不是充分原因。保留 0 的理由：VOD 本就不该
        // 用低延迟语义，且缓冲区完全由 BufferProfileConfig 在 initialize 后下发；
        // 直播低延迟走运行时低延迟档（min=0/max=1000/drop=true）。
        'lowLatency': 0,
        // 保留「快速起播探测」：fpsprobesize=0 / analyzeduration 只影响 open 时的
        // 流探测时长（起播/换台速度），不影响播放期缓冲，故经 'player' 级选项保留
        // （create() 内、prepare 之前应用，与 mdk lowLatency 路径同机制）。
        // fflags=+nobuffer 绝不能恢复——那是 fvp 缓冲失效/冻结的根因。
        //
        // ⚠️ analyzeduration 100000(0.1s) → 500000(0.5s)：**代码级根因修复**
        // （2026-09-26 定案）。0.1s 探测窗口对部分点播源不足以让 ffmpeg 解析出
        // AAC 流参数，mdk 侧表现为：
        //   1. `[FFmpeg:hls] Could not find codec parameters for stream 1
        //      (Audio: aac, 0 channels, fltp): unspecified sample rate`
        //      → `stream#1 ... f32p empty(0) @0Hz`（无采样率/声道、无 extradata）
        //   2. AudioRenderer 退回默认 44100Hz 猜测值，ao 时钟**恒为 0** 不动
        //      （`>>>>>>>>1st audio frame (after seek) rendered: 1, ao: 0`）
        //   3. mdk 以音频为主时钟（`seek end audio frame ... sync_ao_ 1`），
        //      ao 不走 → 主时钟冻结 → 视频同步永不推进 → **画面定格、点播播不了**
        //      （伴随 `seekTo(...) found audio stream#1 packet at -9223372036854775808
        //      in [nan, nan] s`：音频包时间戳 NaN，索引不可用）
        // 实测证据（真机模拟器日志 + ffprobe 离线复现，2026-09-26）：
        //   - 同一源站 URL：`-analyzeduration 100000` → 0ch/0Hz（复现）；
        //     默认 5s / 300000 / 500000 → 44100Hz 2ch（正常）
        //   - 经本地解密代理链路：100000 → 0ch/0Hz（复现）；500000 → 44100Hz 2ch（修复）
        //   - 源站数据、AES-128 解密、代理重写均已离线验证正确（明文分片 ffprobe
        //     直接分析 = 44100Hz 2ch），故与本参数无关。
        // 起播速度权衡：analyzeduration 是**上限**，ffmpeg 一旦取齐流参数即提前结束
        // 探测，故对参数易解析的源（原先 0.1s 就够的）无额外耗时；桌面端
        // (main_windows/linux/ohos.dart) 一直用 500000 且未报起播变慢，此处对齐。
        'player': {
          'avformat.fpsprobesize': '0',
          'avformat.analyzeduration': '500000',
        },
        // ⚠️ 让 seek 走「快速定位」（2026-09-20 定稿根因，2026-09-22 补齐）：
        // fvp 包内部 `_seekFlags` 默认 = fromStart|inCache（1026），**缺少
        // KeyFrame(=Fast, 256) 标志**（video_player_mdk.dart:136），于是 libmdk
        // 退化为「精确 seek」——必须从关键帧起逐帧解码到目标位置才停。对 HLS
        // 远距离 seek（点播续播定位到第 21 分钟）等于要下载+解码前 21 分钟全部
        // 内容，表现为长时间冻结或 0.2x 龟速推进（`FVP_DECODE_STALL` 刷屏）。
        // 实证（2026-09-22 20:42 日志）：seek 1295000ms 后 position 冻结该值
        // 达 51 秒不动、buffered 同步不涨；另一次 seek 1295000ms 只落到 91023ms。
        // 该标志由 registerVideoPlayerPlatformsWith 消费（video_player_mdk.dart:166
        // `if (options['fastSeek'] ?? false) _seekFlags |= keyFrame`），必须在此处传。
        // 代价：定位精度为一个 GOP（1~4s），对续播/拖进度条可接受。
        'fastSeek': true,
        // MDK 全局选项。avformat 值语法为 key1=val1:key2=val2...（冒号分隔），
        // 之前误用逗号导致选项未生效。快速探测已改由上方 'player' 级选项
        // 承担（lowLatency 已归零，fvp 不再自动设置探测参数），
        // 这里只保留 TLS 校验关闭（兼容自签/非标准端口 IPTV 源）。
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    }
  }

  /// 在 HarmonyOS 上注册 fvp（libmdk/ffmpeg 网络栈），作为唯一播放后端。
  ///
  /// 鸿蒙（OHOS）没有 Android 运行时，ExoPlayer/VLC 均不可用，视频层只用 fvp。
  /// fvp 官方支持 HarmonyOS 5.0+，经 OpenGL 渲染。
  static void _restoreOhosFvp() {
    if (Platform.operatingSystem == 'ohos') {
      fvp.registerWith(options: {
        'platforms': ['ohos'],
        // 同 Android：lowLatency=0（详见 Android 分支注释），不开启 nobuffer。
        'lowLatency': 0,
        // 保留「快速起播探测」（仅影响 open 探测时长，不影响播放期缓冲）。
        // analyzeduration 100000→500000 的根因与实测证据详见 Android 分支注释
        // （0.1s 探测窗口会漏掉部分点播源的 AAC 参数 → ao 时钟恒 0 → 画面定格）。
        // ⚠️ main_ohos.dart 里 global `avformat` 用的是**逗号**分隔，按 mdk 语法
        // （key1=val1:key2=val2）该写法很可能整体未生效，故不能依赖它兜底，
        // player 级这里必须给足。
        'player': {
          'avformat.fpsprobesize': '0',
          'avformat.analyzeduration': '500000',
        },
        // 同 Android：补 KeyFrame(=Fast) 标志，避免 libmdk 精确 seek 逐帧解码卡死。
        'fastSeek': true,
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    }
  }

  static VideoPlayerBackend create(PlayerBackendType type) {
    switch (type) {
      case PlayerBackendType.exo:
        _restoreAndroidVideoPlayer();
        return ExoPlayerBackend();
      case PlayerBackendType.fvp:
        _restoreAndroidFvp();
        _restoreOhosFvp();
        // 把 fvp 插件内部 libmdk 的日志（package:logging 的 Logger('mdk')）接入
        // AppLogger。fvp 插件早已 `setLogHandler` + `log=all`，但 logging 包在
        // **无 listener** 时会把日志静默丢弃、且 root 默认 INFO 级别会过滤掉
        // debug/all——导致 libmdk 的内部决策日志在 App 侧完全不可见。
        // 桥接受设置中「获取日志」开关控制，幂等，全平台共用此处（Windows/Linux
        // 的播放页同样经本工厂创建后端）。详见 utils/mdk_log_bridge.dart。
        MdkLogBridge.install();
        return FvpBackend();
      case PlayerBackendType.vlc:
        return VlcBackend();
    }
  }

  /// 各平台默认后端：
  /// - Android / TV：ExoPlayer
  /// - Windows / Linux / HarmonyOS：fvp
  static PlayerBackendType get platformDefault {
    if (Platform.isWindows || Platform.isLinux || Platform.operatingSystem == 'ohos') {
      return PlayerBackendType.fvp;
    }
    return PlayerBackendType.exo;
  }

  /// 直播默认后端：Android / TV 默认 ExoPlayer（Android/TV 点播同款，
  /// 起播与换台速度更快）；Windows / HarmonyOS / Linux 无 ExoPlayer 运行时，仍用 fvp。
  /// 见 [UserDataService.getLivePlayerBackend] 的默认值说明。
  static PlayerBackendType get platformLiveDefault {
    if (Platform.isWindows ||
        Platform.operatingSystem == 'ohos' ||
        Platform.isLinux) {
      return PlayerBackendType.fvp;
    }
    return PlayerBackendType.exo;
  }

  /// 当前平台可供用户切换的播放器后端列表。
  /// - Android / TV：ExoPlayer、fvp
  /// - Windows：fvp、vlc
  /// - Linux / HarmonyOS：仅 fvp（鸿蒙无 ExoPlayer/VLC 运行时）
  static List<PlayerBackendType> get availableBackends {
    if (Platform.isWindows) {
      return [PlayerBackendType.fvp, PlayerBackendType.vlc];
    }
    if (Platform.isLinux || Platform.operatingSystem == 'ohos') {
      return [PlayerBackendType.fvp];
    }
    return [PlayerBackendType.exo, PlayerBackendType.fvp];
  }

  static Future<VideoPlayerBackend> createDefault() async {
    var type = await UserDataService.getPlayerBackend();
    // 若全局设置中的后端在当前平台不可用，回退到平台默认并更新设置。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackend(type);
    }
    return create(type);
  }

  static Future<VideoPlayerBackend> createForLive() async {
    var type = await UserDataService.getLivePlayerBackend();
    // 若直播设置中的后端在当前平台不可用，回退到直播平台默认。
    if (!availableBackends.contains(type)) {
      type = platformLiveDefault;
      await UserDataService.saveLivePlayerBackend(type);
    }
    return create(type);
  }

  static Future<VideoPlayerBackend> createForVideo(
    String source,
    String id,
  ) async {
    final fallback = await UserDataService.getPlayerBackend();
    var type = await UserDataService.getPlayerBackendForVideo(
      source,
      id,
      fallback: fallback,
    );
    // 若某个视频单独保存的后端在当前平台不可用，回退到平台默认。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackendForVideo(source, id, type);
    }
    return create(type);
  }
}
