import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

import 'log_redactor.dart';

import '../services/portable_storage_windows.dart';
import '../services/user_data_service.dart';

/// 全平台文件日志。
///
/// 日志开关由 [UserDataService.getLogEnabled] 控制，关闭时仅通过 [debugPrint] 输出，
/// 不写入文件；开启后异步写入应用私有日志目录，并按天滚动。
///
/// - Android / TV：保存在应用私有目录 `app_logs/` 下。
/// - Windows：保存在软件 exe 同级目录 `data/app_logs/` 下，若不可写则回退到 `%APPDATA%`。
class AppLogger {
  AppLogger._();

  static bool _initialized = false;
  static bool _enabled = false;
  static String? _logDir;
  static final List<String> _pendingLines = [];
  static bool _flushing = false;

  /// 写盘失败后的连续重试轮数上限（防止 finally 里递归重试变成写盘风暴）。
  static int _flushRounds = 0;
  static DebugPrintCallback? _originalDebugPrint;

  /// 「获取日志」开关的变更监听器。
  ///
  /// 供其它日志源跟随开关同步启停——例如 `MdkLogBridge` 把 fvp 插件内部
  /// libmdk 的日志（`package:logging` 的 `Logger('mdk')`）接入 [log]，
  /// 必须在开关打开/关闭时同步放开/收紧其日志级别。
  static final List<void Function(bool)> _enableListeners = [];

  /// 注册开关变更回调。注册时**立即以当前状态回调一次**，因此调用方无需
  /// 自己先读一次 [isEnabled]，也不依赖 [initialize] 与注册的先后顺序。
  static void addEnableListener(void Function(bool enabled) listener) {
    _enableListeners.add(listener);
    listener(_enabled);
  }

  static void _notifyEnable() {
    for (final listener in _enableListeners) {
      listener(_enabled);
    }
  }

  /// 显式初始化日志目录与开关状态。建议在 main() 中调用。
  /// 返回是否成功完成初始化。
  static Future<bool> initialize() async {
    final ok = await _initialize();
    _notifyEnable();
    return ok;
  }

  static Future<bool> _initialize() async {
    _enabled = await UserDataService.getLogEnabled();
    if (!_enabled) {
      _initialized = true;
      return true;
    }
    await _ensureInitialized();
    if (_logDir != null) {
      _hookDebugPrint();
      _writeToFile('[${_now()}] [AppLogger] 日志初始化成功: $_logDir');
      await _flushPending();
      // ignore: avoid_print
      print('AppLogger: 日志路径 ${_logFilePath()}');
      return true;
    }
    // ignore: avoid_print
    print('AppLogger: 日志目录初始化失败');
    return false;
  }

  /// 动态开启/关闭文件日志。设置变更后立即生效。
  static Future<void> setEnabled(bool enabled) async {
    await _setEnabled(enabled);
    _notifyEnable();
  }

  static Future<void> _setEnabled(bool enabled) async {
    final oldEnabled = _enabled;
    _enabled = enabled;
    await UserDataService.saveLogEnabled(enabled);
    if (enabled && _logDir == null) {
      await _ensureInitialized();
      if (_logDir != null) {
        _hookDebugPrint();
        _writeToFile('[${_now()}] [AppLogger] 日志重新开启: $_logDir');
        await _flushPending();
      }
    } else if (!enabled && oldEnabled) {
      _unhookDebugPrint();
      await _flushPending();
      _logDir = null;
      _initialized = false;
    }
  }

  /// 当前是否启用文件日志。
  static bool get isEnabled => _enabled;

  static void _hookDebugPrint() {
    if (_originalDebugPrint != null) return;
    _originalDebugPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      // 🔒 隐私：控制台与文件统一脱敏（服务器地址 / 用户名 / 密码），
      //    保证「获取日志」导出的内容里不含任何可定位到用户的信息。
      final safe = message == null ? message : LogRedactor.redact(message);
      _originalDebugPrint?.call(safe, wrapWidth: wrapWidth);
      if (safe != null && _enabled) {
        _write(safe);
      }
    };
  }

  static void _unhookDebugPrint() {
    if (_originalDebugPrint == null) return;
    debugPrint = _originalDebugPrint!;
    _originalDebugPrint = null;
  }

  static Future<void> _ensureInitialized() async {
    // 已经初始化且日志目录已创建才直接返回；
    // 否则允许重新初始化（例如启动时日志关闭，_initialized 为 true 但 _logDir 为空，后续开启时需要创建目录）。
    if (_initialized && _logDir != null) return;
    try {
      if (Platform.isWindows) {
        await PortableStorageWindows.initialize();
        // 直接使用 PortableStorageWindows 已经确定好的数据目录，
        // 它已处理可写性检查与 APPDATA 回退，避免二次回退导致路径不一致。
        _logDir = p.join(PortableStorageWindows.dataDir, 'app_logs');
      } else if (Platform.isAndroid) {
        // Android：写到应用专属外部目录 Android/data/<包名>/files（type 省略时
        // path_provider 映射到 Context.getExternalFilesDirs(null)，即该根目录）。
        // 该路径对用户可见（系统文件管理器 / USB / MTP 均可访问），便于用户自己
        // 导出日志排查，而非沙盒 /data/user/0/...（普通用户取不到）。
        try {
          final extDirs = await getExternalStorageDirectories();
          final base = (extDirs != null && extDirs.isNotEmpty)
              ? extDirs.first.path
              : null;
          _logDir = base != null ? p.join(base, 'app_logs') : null;
          if (_logDir != null) {
            debugPrint('AppLogger: 使用 Android 外部目录: $_logDir');
          }
        } catch (e) {
          debugPrint('AppLogger: 获取 Android 外部目录失败: $e');
          _logDir = null;
        }
        if (_logDir == null) {
          // 外部目录不可用时回退到应用私有目录，保证日志仍能写入。
          final dir = await getApplicationDocumentsDirectory();
          _logDir = p.join(dir.path, 'app_logs');
        }
      } else {
        final dir = await getApplicationDocumentsDirectory();
        _logDir = p.join(dir.path, 'app_logs');
      }
      final logDir = Directory(_logDir!);
      if (!await logDir.exists()) {
        await logDir.create(recursive: true);
      }
      await _cleanupOldLogs();
    } catch (e) {
      // ignore: avoid_print
      print('AppLogger 初始化失败: $e');
      _logDir = null;
    }
    _initialized = true;
  }

  static Future<void> _cleanupOldLogs() async {
    if (_logDir == null) return;
    try {
      final dir = Directory(_logDir!);
      final now = DateTime.now();
      final files = await dir
          .list()
          .where(
            (e) =>
                e is File &&
                e.path.endsWith('.log') &&
                e.path.contains('hain_tv_'),
          )
          .cast<File>()
          .toList();
      for (final file in files) {
        try {
          final stat = await file.stat();
          if (now.difference(stat.modified).inDays > 7) {
            await file.delete();
          }
        } catch (_) {
          // 忽略单文件清理错误
        }
      }
    } catch (_) {
      // 忽略清理错误
    }
  }

  static String _now() {
    final dt = DateTime.now();
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')} '
        '${dt.hour.toString().padLeft(2, '0')}:'
        '${dt.minute.toString().padLeft(2, '0')}:'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  /// 当前日志文件绝对路径。未启用或未初始化时返回空字符串。
  static String get logFilePath {
    if (!_enabled || _logDir == null) return '';
    return _logFilePath();
  }

  static String _logFilePath() {
    final dt = DateTime.now();
    final name =
        'hain_tv_${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}.log';
    return p.join(_logDir!, name);
  }

  /// 写入日志。无论是否开启文件日志，都会通过 [debugPrint] 输出。
  ///
  /// 注意：开启文件日志时 [debugPrint] 已被 [_hookDebugPrint] 接管，钩子内部会把
  /// 该行写入文件——因此这里**不能**再 [_write] 一次，否则每条经本方法的日志都
  /// 会落盘两遍（实测历史日志中该情况占全部行的 14.3%，表现为连续两行完全相同）。
  /// 仅当钩子尚未安装时（文件日志已开启但日志目录尚不可用的短暂窗口）才由此处
  /// 兜底写入。
  static void log(String tag, String message) {
    final line = LogRedactor.redact('[${_now()}] [$tag] $message');
    debugPrint(line);
    if (_enabled && _originalDebugPrint == null) {
      _write(line);
    }
  }

  /// 写入日志，且**绕过 [debugPrint] 的节流队列**。供高频日志源使用。
  ///
  /// 与 [log] 的差别只在控制台出口：[log] 走 [debugPrint]，其默认实现
  /// `debugPrintThrottled` 把输出限速在 **12KB/秒**（`_kDebugPrintCapacity`），
  /// 且待输出队列 `Queue<String>` **无上限**——超出的行不会丢，而是排队等
  /// 1 秒后（`_kDebugPrintPauseTime`）继续吐。因此当产生速率持续高于 12KB/秒
  /// （libmdk 在 reader 死锁等异常下可达上千条/秒）时，队列会一路积压：
  /// 日志严重滞后，并带来内存与 GC 压力——反过来加剧正在被诊断的卡顿。
  ///
  /// 本方法直接 `print`（Android 上即 logcat），没有 Dart 侧队列与限速：
  /// 代价是 logcat 的环形缓冲在高频下会滚动丢弃最旧的条目（可用
  /// `adb logcat -G 64M` 扩容），但**不会在应用内积压**。
  ///
  /// 文件出口与 [log] 一致。注意此处**不能**复用 [log] 里
  /// 「`_originalDebugPrint == null` 时兜底写入」的写法：`print` 不经过
  /// [debugPrint]，不会触发 [_hookDebugPrint] 安装的钩子，所以只要开启就必须
  /// 自己写，否则文件里会缺这部分日志。
  static void logDirect(String tag, String message) {
    final line = LogRedactor.redact('[${_now()}] [$tag] $message');
    // ignore: avoid_print
    print(line);
    if (_enabled) {
      _write(line);
    }
  }

  /// 立即刷新所有待写入日志到文件。建议在应用退出前调用。
  static Future<void> flush() async {
    await _flushPending();
  }

  /// **同步**写入一行日志（不排队、不限速）。
  ///
  /// 用途：诊断「应用卡死」。普通日志走 [debugPrint] 的节流队列 + 异步落盘，
  /// 一旦 Dart isolate 卡死（同步阻塞或事件循环停摆），队列里剩下的日志**永远
  /// 写不出去**——表现为「日志在卡死时刻戛然而止」，无法区分是 isolate 被阻塞
  /// 还是别的什么。
  ///
  /// 本方法用 [File.writeAsStringSync] 直接落盘，因此：
  /// - isolate 被同步阻塞时，最后一行心跳仍能落盘 → 可据此判断卡死点；
  /// - isolate 整体停摆（VM 级）时不会落盘 → 同样是一种判据。
  ///
  /// 注意：同步写盘本身会占用主线程，因此只应由**低频心跳**（10 秒级）使用，
  /// 不可用于高频日志。
  static void logSync(String tag, String message) {
    final line = LogRedactor.redact('[${_now()}] [$tag] $message');
    // ignore: avoid_print
    print(line);
    if (!_enabled) return;
    final dir = _logDir;
    if (dir == null) return;
    try {
      File(_logFilePath()).writeAsStringSync(
        '$line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // 心跳写盘失败不影响主流程。
    }
  }

  static void _write(String line) {
    if (!_enabled) return;
    _pendingLines.add(LogRedactor.redact(line));
    scheduleMicrotask(_flushPending);
  }

  static void _writeToFile(String line) {
    _pendingLines.add(LogRedactor.redact(line));
    _flushPending();
  }

  static Future<void> _flushPending() async {
    if (_flushing) return;
    if (_pendingLines.isEmpty) return;
    if (!_enabled) {
      _pendingLines.clear();
      return;
    }
    _flushing = true;
    // 🔴 2026-10-23：_ensureInitialized 也要带超时。
    //   它内部会做目录探测/文件创建，一旦挂起，`_flushing` 就永远保持 true，
    //   之后所有日志被 `if (_flushing) return` 直接丢弃 —— 现象是
    //   「日志写到某处就再也不动了」，下一次复现将完全拿不到证据。
    try {
      await _ensureInitialized().timeout(const Duration(seconds: 3));
    } catch (e) {
      // ignore: avoid_print
      print('AppLogger 初始化超时: $e');
      _pendingLines.clear();
      _flushing = false;
      return;
    }
    if (_logDir == null) {
      _pendingLines.clear();
      _flushing = false;
      return;
    }
    try {
      final file = File(_logFilePath());
      final buffer = StringBuffer();
      for (final line in _pendingLines) {
        buffer.writeln(line);
      }
      _pendingLines.clear();
      // 🔴 2026-10-20：加超时保护。
      //    原实现若 writeAsString 挂起（磁盘慢/文件被占用/权限问题），
      //    `_flushing` 会永远保持 true，后续所有日志被 `if (_flushing) return`
      //    直接丢弃 —— 现象就是「日志文件只有初始化那几行」。
      //    真机实测（192.168.8.78）日志只有 84 字节即此因。
      await file
          .writeAsString(
            buffer.toString(),
            mode: FileMode.append,
            flush: true,
          )
          .timeout(const Duration(seconds: 3));
      _flushRounds = 0;
    } catch (e) {
      // ignore: avoid_print
      print('AppLogger 写入失败: $e');
    } finally {
      _flushing = false;
      // 🔴 2026-10-23：限制重试轮数，避免写盘持续失败时无限递归重试
      //   （finally 里递归调用自身，pendingLines 非空就再来一轮）。
      //   写盘失败通常是磁盘/占用问题，无限重试只会变成写盘风暴拖慢整机。
      if (_pendingLines.isNotEmpty && _flushRounds < 5) {
        _flushRounds++;
        _flushPending();
      } else {
        if (_pendingLines.isNotEmpty) {
          // ignore: avoid_print
          print('AppLogger 连续写入失败，丢弃 ${_pendingLines.length} 行待写日志');
          _pendingLines.clear();
        }
        _flushRounds = 0;
      }
    }
  }
}
