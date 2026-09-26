import 'dart:io';

import 'package:fvp/fvp.dart' as fvp;

import '../services/user_data_service.dart';
import '../utils/mdk_log_bridge.dart';
import 'fvp_backend.dart';
import 'video_player_backend.dart';

/// tvLegacy 专用播放后端工厂：**唯一后端为 fvp（libmdk/ffmpeg）**。
///
/// 与主工程（hain_tv）的差异——本副本已摘除另外两个后端：
/// - **ExoPlayer**（`video_player_android` + media3）：media3 的 AAR 声明 minSdk 23，
///   而 tvLegacy 目标是 Android 5.0(API 21)+，是运行时 NoClassDefFoundError 的风险源；
/// - **VLC**（`vlc_player`）：只有 Windows 实现，Android 构建无意义。
///
/// [PlayerBackendType] 枚举仍保留 `exo` / `vlc` 两个值，用途仅为：
/// 1. 兼容用户历史保存的设置字符串（`PlayerBackendType.values.firstWhere` 解析）；
/// 2. 让既有 UI / 远端控制页面的 switch 分支无需改动即可编译。
/// 但 [create] 一律返回 fvp，[availableBackends] 恒为 `[fvp]`，
/// 因此旧设置项会在首次启动时被自动纠正并写回（见 [createDefault]）。
class PlayerBackendFactory {
  /// 注册 fvp（libmdk/ffmpeg 网络栈）为唯一播放平台实现。
  ///
  /// fvp 用 ffmpeg 网络栈，能连部分 ExoPlayer(OkHttp) 无法连通的 IPTV 域名。
  /// 调用后 `VideoPlayerPlatform.instance` 即被替换为 MDK 实现，
  /// 所有基于 `video_player` 的控制器（点播 / 直播 / 回放）都走 fvp。
  static void _registerFvp() {
    if (Platform.isAndroid) {
      fvp.registerWith(options: {
        'platforms': ['android'],
        // ⚠️ lowLatency 置 0（2026-09-22 修复）：lowLatency>0 会在 player 创建时
        // （prepare 之前）写入三个 player 级属性，其中 `avformat.fflags=+nobuffer`
        // 按 mdk 源码自注是「第 1 个关键帧包被丢弃」，且这些属性 open 之后无法覆盖
        // → 缓冲条恒等于 position、seek 后 reader 不预取。VOD 本就不该用低延迟语义；
        // 直播低延迟改由 BufferProfileConfig 的低延迟档（min=0/max=1000/drop=true）
        // 经 setBufferRange 在 initialize() **之后**下发。
        'lowLatency': 0,
        // 「快速起播探测」只影响 open 时的流探测时长（起播/换台速度），不影响播放期
        // 缓冲，故经 'player' 级选项保留（create() 内、prepare 之前应用）。
        // fflags=+nobuffer 绝不能恢复 —— 那是 fvp 缓冲失效/冻结的根因之一。
        //
        // ⚠️ analyzeduration 100000(0.1s) → 500000(0.5s)：**代码级根因修复**
        // （2026-09-26 定案）。0.1s 探测窗口对部分点播源不足以让 ffmpeg 解析出 AAC
        // 音频参数：ffmpeg 报 `Could not find codec parameters for stream 1
        // (Audio: aac, 0 channels): unspecified sample rate`，音频流退化为
        // `@0Hz, empty(0)`、无 extradata → mdk 的 AudioRenderer 用猜测值、
        // **音频主时钟 ao 恒为 0 不推进** → mdk 以音频为主时钟（sync_ao_ 1）
        // → 主时钟冻结 → 画面定格（点播「能出画面但卡住」）。
        // 实测证据（真机日志 + ffprobe 离线复现，2026-09-26）：
        //   - 同一源 URL：`-analyzeduration 100000` → 0ch/0Hz（复现）；
        //     300000 / 500000 → 44100Hz 2ch（正常）
        //   - 经本地 AES 解密代理链路：100000 → 0ch/0Hz；500000 → 44100Hz 2ch
        //   - 源站分片解密后的明文直接喂 ffprobe = 44100Hz 2ch，故与解密/代理无关
        // 起播速度不受影响：analyzeduration 是**上限**，ffmpeg 取齐流参数即提前结束
        // 探测，原先 0.1s 就够的源仍会提前结束（实测探测期 HTTP 请求 5 次 vs 62 次）。
        'player': {
          'avformat.fpsprobesize': '0',
          'avformat.analyzeduration': '500000',
        },
        // ⚠️ 让 seek 走「快速定位」（2026-09-20 定稿根因）：
        // fvp 包内部 `_seekFlags` 默认 = fromStart|inCache（1026），**缺少
        // KeyFrame(=Fast, 256) 标志**，于是 libmdk 退化为「精确 seek」——必须
        // 从关键帧起逐帧解码到目标位置才停。对 HLS 远距离 seek（点播续播定位到
        // 第 109 秒）等于要下载+解码前 109 秒全部内容，表现为长时间冻结。
        // 实证：16:34 日志中 seek 到 109560ms 后，8.8 秒只推进 620ms。
        // libmdk 默认标志 MDK_SeekFlag_Default=1282 本就含 KeyFrame，这里补上，
        // seek 会跳到目标附近的关键帧即刻可播。代价：定位精度为一个 GOP（1~4s）。
        'fastSeek': true,
        // MDK 全局选项。avformat 值语法为 key1=val1:key2=val2...（冒号分隔），
        // 之前误用逗号导致选项未生效。快速探测已改由上方 'player' 级选项承担
        // （lowLatency 已归零，fvp 不再自动设置探测参数），这里只保留 TLS 校验
        // 关闭（兼容自签/非标准端口 IPTV 源）。
        'global': {
          'avformat': 'tls_verify=0',
          'ffmpeg.loglevel': 'info',
        },
      });
    } else if (Platform.operatingSystem == 'ohos') {
      // 鸿蒙（OHOS）没有 Android 运行时，视频层同样只用 fvp（官方支持 OHOS 5.0+，
      // 经 OpenGL 渲染）。tvLegacy 不构建鸿蒙，此处保留以兼容共享代码路径。
      fvp.registerWith(options: {
        'platforms': ['ohos'],
        // 同 Android：lowLatency=0（详见 Android 分支注释），不开启 nobuffer。
        'lowLatency': 0,
        // analyzeduration 100000→500000 的根因与实测证据详见 Android 分支注释。
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

  /// 创建播放后端。**恒返回 fvp**；`type` 仅用于兼容调用方签名。
  static VideoPlayerBackend create(PlayerBackendType type) {
    _registerFvp();
    // 把 fvp 插件内部 libmdk 的日志（`package:logging` 的 `Logger('mdk')`）接入
    // AppLogger。fvp 插件早已 `setLogHandler` + 设了 `log=all`，但 logging 包在
    // **无 listener** 时会把日志静默丢弃、且 root 默认 INFO 级别会过滤掉 FINE/ALL
    // —— 结果就是 libmdk 的内部决策日志在 App 侧一条都看不到，遇到
    // 「fvp 卡住但 App 层全链路日志正常」时无从下手（2026-09-26 定位点播卡死
    // 根因正是靠这套日志：`ao` 主时钟恒 0 / `Could not find codec parameters`）。
    // 桥接受设置中「获取日志」开关控制，install() 幂等，重复调用安全。
    MdkLogBridge.install();
    return FvpBackend();
  }

  /// 平台默认后端：恒为 fvp（本工程不再有 ExoPlayer / VLC 运行时）。
  static PlayerBackendType get platformDefault => PlayerBackendType.fvp;

  /// 直播默认后端：恒为 fvp。
  static PlayerBackendType get platformLiveDefault => PlayerBackendType.fvp;

  /// 可供用户切换的播放后端列表：恒为 `[fvp]`。
  ///
  /// 设置页据此渲染选项，因此「点播设置 / 直播设置」的播放器一栏
  /// 会自动收敛为只剩 FVP 一项，无需改动页面代码。
  static List<PlayerBackendType> get availableBackends =>
      const [PlayerBackendType.fvp];

  static Future<VideoPlayerBackend> createDefault() async {
    var type = await UserDataService.getPlayerBackend();
    // 若全局设置中的后端在本工程不可用（历史残留的 exo / vlc），
    // 回退到 fvp 并把设置写回，避免每次启动都命中这条分支。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackend(type);
    }
    return create(type);
  }

  static Future<VideoPlayerBackend> createForLive() async {
    var type = await UserDataService.getLivePlayerBackend();
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
    // 若某个视频单独保存的后端在本工程不可用，回退到 fvp。
    if (!availableBackends.contains(type)) {
      type = platformDefault;
      await UserDataService.savePlayerBackendForVideo(source, id, type);
    }
    return create(type);
  }
}
