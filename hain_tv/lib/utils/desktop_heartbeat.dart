import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'app_logger.dart';

/// 桌面端（Windows / Linux）卡死诊断心跳。
///
/// ## 为什么需要它
///
/// 「软件卡死」有两种完全不同的成因，处置方式也不同：
///
/// 1. **Dart UI isolate 被同步阻塞**（死循环、同步 native 调用、GPU 设备等待）
///    → 主线程被占住，窗口不响应；
/// 2. **某个 await 永不返回**（网络/存储/原生回调不回来）
///    → 事件循环其实还在转，但那个流程永远走不到下一步。
///
/// 普通日志区分不了这两者：日志本身走 [debugPrint] 的节流队列 + 异步落盘，
/// isolate 一旦被同步阻塞，队列里剩下的日志**永远写不出去**，
/// 表现为「日志在卡死时刻戛然而止」。
///
/// ## 本类怎么区分
///
/// 同时跑两个心跳：
///
/// - **HB-UI**：主 isolate 里的 [Timer]，用 [AppLogger.logSync] **同步**落盘到
///   主日志文件。isolate 被同步阻塞 → 心跳停；只是 await 挂起 → 心跳继续。
/// - **HB-ISO**：独立 [Isolate] 里的定时器，写到单独的 `hb_isolate.log`。
///   它不受主 isolate 阻塞影响（Dart VM 每个 isolate 独占一个 OS 线程），
///   因此能作为「整个 Dart VM 是否还活着」的基准。
///
/// 判读表：
///
/// | HB-UI | HB-ISO | 结论 |
/// |---|---|---|
/// | 停 | 继续 | 主 isolate 被**同步阻塞**（死循环 / 同步 native 调用 / 渲染设备等待） |
/// | 停 | 停 | 整个 Dart VM 停摆（极少见于 native 层全局死锁） |
/// | 继续 | 继续 | 只是某个 **await 永不返回**，主循环仍可运转（看日志断点定位） |
///
/// ## 注意
///
/// 心跳低频（10 秒）且同步写盘，只在桌面端启用。Android 用 logcat 观察即可。
class DesktopHeartbeat {
  static bool _started = false;
  static int _tick = 0;

  /// 启动心跳。重复调用无副作用。
  static void start() {
    if (_started) return;
    _started = true;

    // HB-UI：主 isolate 心跳（同步落盘）。
    Timer.periodic(const Duration(seconds: 10), (_) {
      _tick++;
      AppLogger.logSync('HB-UI', 'tick=$_tick');
    });

    // HB-ISO：独立 isolate 心跳（写独立文件，不依赖主 isolate）。
    final hbDir = _heartbeatDir();
    if (hbDir == null) return;
    try {
      Isolate.spawn(
        _isolateEntry,
        hbDir,
        debugName: 'heinplay-hb',
        errorsAreFatal: false,
      );
    } catch (e) {
      AppLogger.logSync('HB-ISO', '启动失败: $e');
    }
  }

  /// 心跳文件目录：与主日志同目录（exe 同级 data/app_logs）。
  static String? _heartbeatDir() {
    try {
      final exeDir = File(Platform.resolvedExecutable).parent.path;
      return '$exeDir${Platform.pathSeparator}data'
          '${Platform.pathSeparator}app_logs';
    } catch (_) {
      return null;
    }
  }

  /// 独立 isolate 入口：每 10 秒往 `hb_isolate.log` 追加一行。
  static void _isolateEntry(String dir) {
    final file = File(
      '$dir${Platform.pathSeparator}hb_isolate.log',
    );
    var tick = 0;
    Timer.periodic(const Duration(seconds: 10), (_) {
      tick++;
      try {
        file.parent.createSync(recursive: true);
        file.writeAsStringSync(
          '[HB-ISO] tick=$tick ${DateTime.now().toIso8601String()}\n',
          mode: FileMode.append,
          flush: true,
        );
      } catch (_) {
        // 心跳写盘失败不影响主 isolate。
      }
    });
  }
}
