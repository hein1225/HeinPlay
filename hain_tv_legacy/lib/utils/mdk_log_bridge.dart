import 'package:logging/logging.dart';

import 'app_logger.dart';

/// 把 fvp 插件内部 libmdk 的日志接入应用日志（`AppLogger`）。
///
/// ## 为什么需要它
///
/// fvp 0.37.0 的 `MdkVideoPlayerPlatform._setupMdk()`
/// （`fvp/lib/src/video_player_mdk.dart:219`）已经做过两件事：
///
/// 1. `mdk.setLogHandler(...)` —— 把 libmdk 的原生日志转发成 `package:logging`
///    的记录：`Logger('mdk')` = libmdk 内部日志（reader/demuxer/解码决策等），
///    `Logger('fvp')` = fvp 插件自身日志；
/// 2. `mdk.setGlobalOption('log', 'all')` —— 把 libmdk 日志级别开到最详细。
///
/// 但 `package:logging` 的语义是：**没有任何 listener 时日志被静默丢弃**；
/// 且 `Logger.root.level` 默认为 `Level.INFO`，会把 mdk 的详细级别
/// （debug/all → `FINE`/`FINEST`）在 `isLoggable` 阶段就过滤掉。
///
/// 本项目此前完全没用过 `package:logging`，于是 **libmdk 的内部日志一条都到不了
/// App 侧**。这正是「fvp 画面卡住，但 App 层全链路日志（代理、AES 解密、playlist
/// 重写、seek、buffered/position）看起来全部正常」这类问题长期无法定位的根本
/// 原因——真正出问题的那一层根本没有日志出口。
///
/// ## 行为
///
/// - 仅当设置中「获取日志」开关打开（`AppLogger.isEnabled`）时才转发；关闭时把
///   `Logger.root.level` 置为 `Level.OFF`，logging 包连 `LogRecord` 都不会构造，
///   零性能开销。
/// - 转发时经 `AppLogger.logDirect` 直接 `print`（Android 上即 logcat）并落盘，与其它
///   日志同格式、同文件（`app_logs/hain_tv_YYYY-MM-DD.log`），可直接对照时间线。
///   用 `logDirect` 而非 `log`：`log` 走 `debugPrint`，其默认实现有 **12KB/秒**限速且
///   待输出队列无上限，libmdk 异常刷屏时会造成日志滞后与内存/GC 积压（反过来加剧卡顿）。
///   日志 tag：`MDK`（libmdk）/ `FVP`（fvp 插件）。
/// - 跟随「获取日志」开关变化自动启停，无需重启应用。
///
/// ## 用法
///
/// `install()` 是幂等的，在 fvp 后端创建处调用一次即可
/// （见 `lib/player/player_backend_factory.dart` 的 fvp 分支）。
/// 桌面端（Windows/Linux）同样走该工厂创建后端，因此一处即覆盖全平台。
class MdkLogBridge {
  MdkLogBridge._();

  static bool _installed = false;
  static bool _active = false;

  /// 因开关关闭（或时序窗口）被丢弃的日志条数，开启时告知用户，避免误判。
  static int _discarded = 0;

  /// 每秒最多转发的日志条数。
  ///
  /// `package:logging` 的 broadcast 流是 `sync: true`——每条都在投递它的线程上
  /// **同步**执行本回调；而 `logDirect` 走 `print`，在 Android 上最终是一次
  /// logcat 写入 syscall。libmdk 在异常状态（reader 疯狂重试、解码器反复丢弃）
  /// 下每秒可达上千条，无上限转发会白白吃掉主线程时间并刷爆 logcat 缓冲
  /// （把 App 其它关键日志挤掉）。
  ///
  /// 取值 300：日志行（含 `[时间] [tag] [级别] ` 前缀）约 165 字符，
  /// 300 条/秒 ≈ 50KB/秒，高于正常播放（每秒个位数到几十条），能覆盖异常
  /// 爆发期的大部分现场；同时远低于 logcat 与 Android Studio 面板被刷爆的量级。
  /// **该值属经验取值，待「疯狂刷日志」源实测后校准。**
  static const int _kMaxPerSecond = 300;

  static int _windowStartMs = 0;
  static int _windowCount = 0;
  static int _windowDiscarded = 0;

  /// 安装桥接。可重复调用，只有首次生效。
  static void install() {
    if (_installed) return;
    _installed = true;

    // logging 默认非层级模式：所有 Logger 的 record 都会沿 parent 冒泡到 root，
    // 因此监听 root 即可同时拿到 Logger('mdk') 与 Logger('fvp')。
    Logger.root.onRecord.listen(_onRecord);

    // 跟随「获取日志」开关。addEnableListener 注册时会立即以当前状态回调一次，
    // 所以本调用不依赖它与 AppLogger.initialize() 的先后顺序。
    AppLogger.addEnableListener(_applyEnabled);
  }

  static void _applyEnabled(bool enabled) {
    _active = enabled;
    // 关闭时置 OFF：logging 在 isLoggable 阶段直接短路，不构造 LogRecord。
    Logger.root.level = enabled ? Level.ALL : Level.OFF;
    if (enabled) {
      AppLogger.log(
        'MDK',
        '[MDK-BRIDGE] libmdk 内部日志已接入应用日志，tag=MDK/FVP'
        '（此前丢弃 $_discarded 条）',
      );
      _discarded = 0;
    }
  }

  static void _onRecord(LogRecord record) {
    if (!_active) {
      // 正常路径下 root.level=OFF 时不会走到这里；保留计数以覆盖 level 切换
      // 与 native 线程投递之间的瞬时时序窗口。
      _discarded++;
      return;
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _windowStartMs >= 1000) {
      if (_windowDiscarded > 0) {
        AppLogger.log(
          'MDK',
          '[MDK-BRIDGE] 上一秒因限流（上限 $_kMaxPerSecond 条/秒）丢弃 '
          '$_windowDiscarded 条 libmdk 日志',
        );
        _windowDiscarded = 0;
      }
      _windowStartMs = nowMs;
      _windowCount = 0;
    }
    if (_windowCount >= _kMaxPerSecond) {
      _windowDiscarded++;
      return;
    }
    _windowCount++;

    var message = record.message;
    // libmdk 的日志自带结尾换行，去掉以免落盘出现空行。
    while (message.endsWith('\n') || message.endsWith('\r')) {
      message = message.substring(0, message.length - 1);
    }
    if (message.isEmpty) return;

    final tag = record.loggerName == 'mdk' ? 'MDK' : 'FVP';
    // 用 logDirect 而非 log：libmdk 是高频日志源，而 log 走 debugPrint，其默认
    // 实现 debugPrintThrottled 限速 12KB/秒且待输出队列无上限——异常刷屏时会
    // 一路积压（日志滞后 + 内存/GC 压力，反过来加剧卡顿）。logDirect 直接 print
    // 到 logcat，无队列无积压。
    AppLogger.logDirect(tag, '[${record.level.name}] $message');
  }
}
