import { FlutterAbility, FlutterEngine, MethodChannel, MethodCall, MethodResult } from '@ohos/flutter_ohos';
import { GeneratedPluginRegistrant } from '../plugins/GeneratedPluginRegistrant';
import { MpvPlugin } from '@mpv-ohos/mpv-arkts/MpvBridge';
import common from '@ohos.app.ability.common';
import window from '@ohos.window';
import audio from '@ohos.multimedia.audio';
import { picker, fileIo as fs } from '@kit.CoreFileKit';

/// 与安卓 MainActivity.kt 中 SPLASH_CHANNEL 完全一致的 channel 名。
/// Dart 侧 SplashScreen._notifyCoverReady 用同一名字调用，无需按平台分支。
const SPLASH_CHANNEL = 'hain_tv/splash';

/// eventHub 事件名。必须与 pages/Index.ets 中监听的名称严格一致。
/// EntryAbility 持有 FlutterEngine（能注册 channel），Index 页面持有
/// 「是否显示覆盖层」的 UI 状态，用 eventHub 在两者之间中转解耦。
const EVENT_SPLASH_COVER_READY = 'heinplay_splash_cover_ready';

/// 屏幕常亮通道。Dart 侧 ScreenWakeOhos 用同一名字调用。
/// 鸿蒙没有 wakelock_plus 的原生实现（仅 android/ios/web/win/linux/macos），
/// 故用原生 window.setWindowKeepScreenOn 实现；参数 { keep: bool }。
const SCREEN_WAKE_CHANNEL = 'hain_tv/screen_wake';

/// 🔴 2026-10-06 新增：应用级音量通道。
///
/// 【为什么需要它】Dart 侧手势音量用的是 `volume_controller` 插件，但该插件的
/// plugin.platforms **只有 android/ios/macos/linux/windows，没有 ohos**
/// （实测 volume_controller 3.5.0 的 pubspec 已确认）。于是鸿蒙上
/// `VolumeController.instance.setVolume()` 走的是**默认空实现** —— 只改了 Dart
/// 本地变量、不调用任何系统 API，表现为「音量提示条在动、实际音量不变」。
/// 安卓因有原生实现而正常，故鸿蒙需自建等价通道。
///
/// 【为什么用 setAppVolumePercentage 而非系统音量】
/// 鸿蒙当前 SDK（compatibleSdkVersion 6.1.0(23)）里 `AudioVolumeGroupManager`
/// **只有 getVolume* 读接口、没有 setVolume**（编译期已实测报错
/// "Property 'setVolume' does not exist on type 'AudioVolumeGroupManager'"）；
/// 旧版 `AudioVolumeManager.setVolume` 自 API 9 起已废弃且标注 @systemapi。
/// 系统音量写入属系统应用能力，三方应用不可用。
/// 因此改用 **应用级音量** `AudioVolumeManager.setAppVolumePercentage`
/// （0..100，Promise）：只调整本应用输出音量，三方应用可用，且对用户而言
/// 「滑动调音量生效」的体验一致。
///
/// 【语义】Dart 侧传 0..1 归一化音量；原生侧换算为 0..100 百分比。
const VOLUME_CHANNEL = 'hain_tv/volume';

/// 🔴 2026-10-31 新增：本地视频选择通道。
///
/// 【用途】让用户在**无服务器**（游客态）下也能添加本机视频文件并播放。
///   本应用为单机使用工具，不接入任何第三方服务，本地媒体是核心能力之一。
///
/// 【实现】用系统 DocumentViewPicker 让用户从「文件管理」中选一个视频文件，
///   选中后把文件**复制到应用私有目录**（filesDir/local_media/），
///   再把沙箱内绝对路径回传给 Dart —— 这样播放器（AVPlayer / mpv）
///   可以直接按普通文件路径读取，不依赖任何临时授权或第三方库。
///
/// 【为什么不申请 READ_IMAGEVIDEO 等媒体权限】
///   系统文件选择器对用户明确选中的单个文件授予一次性访问权，
///   本应用不需要长期读取相册/媒体库，因此不申请任何媒体读取权限，
///   也就不需要在隐私政策里声明敏感权限（保持单机工具的最小权限面）。
const LOCAL_MEDIA_CHANNEL = 'hain_tv/local_media';

export default class EntryAbility extends FlutterAbility {
  configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    GeneratedPluginRegistrant.registerWith(flutterEngine)

    // ── mpv 播放内核注册（2026-09-30 新增）────────────────────────────
    //
    // ⚠️ 必须在这里注册，不能写进 GeneratedPluginRegistrant.ets：
    //    该文件由 `flutter build hap` 依据 pubspec.yaml 的 plugins 自动生成
    //    （文件头即写着 "Generated file. Do not edit."），手工加的注册会被
    //    下次构建直接覆盖掉。
    //    mpv-arkts 是原生 har 模块（不是 Flutter 插件，无 pubspec 声明），
    //    因此只能在此手动注册。
    //
    // MpvPlugin 负责：
    //   1) 注册 PlatformView 工厂（viewType = 'heinplay_mpv'）
    //   2) 建立控制通道 hain_tv/mpv（Dart 侧 MpvBackend 按 viewId 路由调用）
    //   3) 每个视图建立独立事件通道 hain_tv/mpv_events_<viewId>
    flutterEngine.getPlugins()?.add(new MpvPlugin());

    // ── 启动封面交接通道（2026-09-28 新增，修复「打开先闪全屏大图标」）──────
    //
    // 对齐安卓 MainActivity.kt 的 SPLASH_CHANNEL 处理：
    //   Dart 侧「Flutter 封面已解码完成」→ 原生移除全屏启动封面覆盖层。
    //
    // 鸿蒙侧多一步 eventHub 中转，原因见 Index.ets 顶部说明：
    // 覆盖层的显示状态归 Index 页面（@State），而 channel 必须挂在引擎上。
    //
    // ⚠️ result.success(null) 绝不能漏：flutter_ohos 引擎的 PlatformChannel.ets
    // 就有因漏掉 success 导致 Dart 侧 await 永久挂起的先例
    // （SystemChrome.setEnabledSystemUIMode，见 main_ohos.dart 注释）。
    // 这里即使 Dart 侧不 await，也按规范回执。
    const splashChannel = new MethodChannel(flutterEngine.dartExecutor, SPLASH_CHANNEL);

    splashChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult) => {
        if (call.method === 'coverReady') {
          const ctx = this.context as common.UIAbilityContext;
          ctx.eventHub.emit(EVENT_SPLASH_COVER_READY);
          console.info('[HeinPlay] 收到 coverReady，已通知 Index 移除启动封面');
          result.success(null);
        } else {
          result.notImplemented();
        }
      }
    });

    // ── 屏幕常亮通道 ───────────────────────────────────────────────
    //
    // 鸿蒙上 wakelock_plus 无原生实现（只覆盖 android/ios/web/win/linux/macos），
    // 其 enable() 在 ohos 会抛 PlatformException 失败，屏幕不会常亮。
    // 这里用原生 window.setWindowKeepScreenOn 实现。
    //
    // ⚠️ result.success(null) 必须回执（见上方 SPLASH_CHANNEL 注释，
    //   漏 success 会让 Dart 侧 await 永久挂起）。
    const wakeChannel = new MethodChannel(flutterEngine.dartExecutor, SCREEN_WAKE_CHANNEL);

    wakeChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult) => {
        if (call.method === 'setKeepScreenOn') {
          const keep: boolean = call.argument('keep') as boolean;
          const ctx = this.context as common.UIAbilityContext;
          window.getLastWindow(ctx).then((win) => {
            return win.setWindowKeepScreenOn(keep);
          }).then(() => {
            console.info(`[HeinPlay] setWindowKeepScreenOn(${keep}) 成功`);
            result.success(null);
          }).catch((err: Error) => {
            console.error(`[HeinPlay] setWindowKeepScreenOn(${keep}) 失败: ${err}`);
            result.error('KEEP_SCREEN_ON_FAILED', err?.message ?? 'unknown', null);
          });
        } else {
          result.notImplemented();
        }
      }
    });

    // ── 本地视频选择通道（2026-10-31 新增）────────────────────────
    //
    // 方法：
    //   pickVideo  → 弹出系统文件选择器，选中视频后复制进沙箱，
    //                 返回 { path, name, size }；用户取消返回 null。
    //   deleteFile → 删除沙箱内已复制的视频文件（参数 path）。
    //
    // ⚠️ result.success(null) / result.error(...) 必须回执，
    //    漏掉回执会让 Dart 侧 await 永久挂起（见上方 SPLASH_CHANNEL 注释）。
    const localMediaChannel = new MethodChannel(flutterEngine.dartExecutor, LOCAL_MEDIA_CHANNEL);

    localMediaChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult) => {
        if (call.method === 'pickVideo') {
          const ctx = this.context as common.UIAbilityContext;
          const docPicker = new picker.DocumentViewPicker();
          const options: picker.DocumentSelectOptions = {
            maxSelectNumber: 1,
            fileSuffixFilters: ['Video|.mp4,.mkv,.mov,.avi,.ts,.flv,.wmv,.webm,.m4v,.3gp,.rmvb']
          };
          docPicker.select(options).then((uris: string[]) => {
            if (!uris || uris.length === 0) {
              result.success(null);
              return;
            }
            const uri = uris[0];
            // 取文件名（URI 末段，可能带百分号编码）
            let rawName = uri.substring(uri.lastIndexOf('/') + 1);
            let fileName = 'local_video.mp4';
            try {
              fileName = decodeURIComponent(rawName);
            } catch (e) {
              fileName = rawName;
            }
            if (!fileName || fileName.length === 0) {
              fileName = 'local_video.mp4';
            }
            try {
              const dir = `${ctx.filesDir}/local_media`;
              if (!fs.accessSync(dir)) {
                fs.mkdirSync(dir, true);
              }
              // 加时间戳避免同名覆盖
              const stamp = Date.now();
              const destPath = `${dir}/${stamp}_${fileName}`;
              const src = fs.openSync(uri, fs.OpenMode.READ_ONLY);
              try {
                fs.copyFileSync(src.fd, destPath, 0);
              } finally {
                fs.closeSync(src);
              }
              const stat = fs.statSync(destPath);
              console.info(`[HeinPlay] 已复制本地视频到沙箱: ${destPath}`);
              result.success({ path: destPath, name: fileName, size: stat.size });
            } catch (err) {
              const e = err as Error;
              console.error(`[HeinPlay] 复制本地视频失败: ${e?.message ?? e}`);
              result.error('COPY_LOCAL_VIDEO_FAILED', e?.message ?? 'unknown', null);
            }
          }).catch((err: Error) => {
            // 用户取消选择也走这里（Picker 取消会 reject）
            console.info(`[HeinPlay] 用户取消选择本地视频: ${err?.message ?? err}`);
            result.success(null);
          });
        } else if (call.method === 'deleteFile') {
          const path = call.argument('path') as string;
          try {
            if (path && fs.accessSync(path)) {
              fs.unlinkSync(path);
            }
            result.success(null);
          } catch (err) {
            const e = err as Error;
            console.error(`[HeinPlay] 删除本地视频失败: ${e?.message ?? e}`);
            result.success(null);
          }
        } else {
          result.notImplemented();
        }
      }
    });

    // ── 应用级音量通道（2026-10-06 新增）────────────────────────────
    //
    // 修复「鸿蒙播放页右侧上下滑动调音量只显示提示、实际不生效」：
    // volume_controller 插件无 ohos 实现，这里用 @ohos.multimedia.audio 补上。
    //
    // 两个方法：
    //   · getVolume → 返回 0..1 归一化当前应用音量（供手势起点读取）
    //   · setVolume → 入参 0..1，换算为 0..100 百分比后设置应用音量
    //
    // ⚠️ 全部走 Promise 回执，绝不能漏 success/error（漏了 Dart 侧 await 永久挂起，
    //    与本文件其它通道同一教训）。
    const volumeChannel = new MethodChannel(flutterEngine.dartExecutor, VOLUME_CHANNEL);

    volumeChannel.setMethodCallHandler({
      onMethodCall: (call: MethodCall, result: MethodResult) => {
        if (call.method === 'getVolume') {
          try {
            const am: audio.AudioManager = audio.getAudioManager();
            am.getVolumeManager().getAppVolumePercentage().then((pct: number) => {
              // 0..100 → 0..1
              result.success(pct / 100.0);
            }).catch((err: Error) => {
              console.error(`[HeinPlay] getVolume 失败: ${err?.message ?? err}`);
              result.error('GET_VOLUME_FAILED', err?.message ?? 'unknown', null);
            });
          } catch (err) {
            const e = err as Error;
            console.error(`[HeinPlay] getVolume 异常: ${e?.message ?? e}`);
            result.error('GET_VOLUME_FAILED', e?.message ?? 'unknown', null);
          }
        } else if (call.method === 'setVolume') {
          const v: number = (call.argument('volume') as number) ?? 0;
          try {
            const clamped = v < 0 ? 0 : (v > 1 ? 1 : v);
            const pct = clamped * 100.0;
            const am: audio.AudioManager = audio.getAudioManager();
            am.getVolumeManager().setAppVolumePercentage(pct).then(() => {
              result.success(null);
            }).catch((err: Error) => {
              console.error(`[HeinPlay] setVolume(${v}) 失败: ${err?.message ?? err}`);
              result.error('SET_VOLUME_FAILED', err?.message ?? 'unknown', null);
            });
          } catch (err) {
            const e = err as Error;
            console.error(`[HeinPlay] setVolume(${v}) 异常: ${e?.message ?? e}`);
            result.error('SET_VOLUME_FAILED', e?.message ?? 'unknown', null);
          }
        } else {
          result.notImplemented();
        }
      }
    });
  }
}
