import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;

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
  static DebugPrintCallback? _originalDebugPrint;

  /// 显式初始化日志目录与开关状态。建议在 main() 中调用。
  /// 返回是否成功完成初始化。
  static Future<bool> initialize() async {
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
    final oldEnabled = _enabled;
    _enabled = enabled;
    await UserDataService.saveLogEnabled(enabled);
    if (enabled && !oldEnabled) {
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
      _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
      if (message != null && _enabled) {
        _write(message);
      }
    };
  }

  static void _unhookDebugPrint() {
    if (_originalDebugPrint == null) return;
    debugPrint = _originalDebugPrint!;
    _originalDebugPrint = null;
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      if (Platform.isWindows) {
        await PortableStorageWindows.initialize();
        // 直接使用 PortableStorageWindows 已经确定好的数据目录，
        // 它已处理可写性检查与 APPDATA 回退，避免二次回退导致路径不一致。
        _logDir = p.join(PortableStorageWindows.dataDir, 'app_logs');
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
  static void log(String tag, String message) {
    final line = '[${_now()}] [$tag] $message';
    debugPrint(line);
    if (_enabled) {
      _write(line);
    }
  }

  /// 立即刷新所有待写入日志到文件。建议在应用退出前调用。
  static Future<void> flush() async {
    await _flushPending();
  }

  static void _write(String line) {
    if (!_enabled) return;
    _pendingLines.add(line);
    scheduleMicrotask(_flushPending);
  }

  static void _writeToFile(String line) {
    _pendingLines.add(line);
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
    await _ensureInitialized();
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
      await file.writeAsString(
        buffer.toString(),
        mode: FileMode.append,
        flush: true,
      );
    } catch (e) {
      // ignore: avoid_print
      print('AppLogger 写入失败: $e');
    } finally {
      _flushing = false;
      if (_pendingLines.isNotEmpty) {
        _flushPending();
      }
    }
  }
}
