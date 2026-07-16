import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../services/portable_storage_windows.dart';

/// Windows 专用文件日志。
///
/// 仅当 [Platform.isWindows] 为 true 时写入文件，其他平台仅使用 [debugPrint]。
/// 日志文件按天滚动，保存在软件 exe 同级目录 `data/windows_logs/` 下，
/// 文件名为 `hain_tv_YYYY-MM-DD.log`，最多保留最近 1 天的日志。
class WindowsLogger {
  static bool _initialized = false;
  static String? _logDir;
  static final List<String> _pendingLines = [];
  static bool _flushing = false;

  /// 显式初始化日志目录。建议在 main() 中调用，避免首次写入时才异步创建目录。
  /// 返回是否成功完成初始化。
  static Future<bool> initialize() async {
    await _ensureInitialized();
    if (_logDir != null) {
      // 直接写入并等待完成，确保初始化后立即生成日志文件。
      _writeToFile('[${_now()}] [WindowsLogger] 日志初始化成功: $_logDir');
      await _flushPending();
      // release 模式下也通过 print 输出路径，方便用户定位日志文件。
      // ignore: avoid_print
      print('WindowsLogger: 日志路径 ${_logFilePath()}');
      return true;
    }
    // ignore: avoid_print
    print('WindowsLogger: 日志目录初始化失败');
    return false;
  }

  static Future<void> _ensureInitialized() async {
    if (_initialized) return;
    if (Platform.isWindows) {
      try {
        await PortableStorageWindows.initialize();
        _logDir = p.join(PortableStorageWindows.dataDir, 'windows_logs');
        var dir = Directory(_logDir!);
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }
        // 测试目录是否真正可写，若不可写则回退到 %APPDATA%。
        if (!await _isDirectoryWritable(_logDir!)) {
          final appData = Platform.environment['APPDATA'];
          if (appData != null && appData.isNotEmpty) {
            _logDir = p.join(appData, 'com.heinplay', 'hain_tv', 'windows_logs');
            dir = Directory(_logDir!);
            if (!await dir.exists()) {
              await dir.create(recursive: true);
            }
          }
        }
        await _cleanupOldLogs();
      } catch (e) {
        // ignore: avoid_print
        print('WindowsLogger 初始化失败: $e');
      }
    }
    _initialized = true;
  }

  static Future<bool> _isDirectoryWritable(String dir) async {
    try {
      final testFile = File(p.join(dir, '.write_test'));
      await testFile.writeAsString('test', flush: true);
      await testFile.delete();
      return true;
    } catch (_) {
      return false;
    }
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
          if (now.difference(stat.modified).inDays > 1) {
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

  static String _logFilePath() {
    final dt = DateTime.now();
    final name =
        'hain_tv_${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}.log';
    return p.join(_logDir!, name);
  }

  /// 写入日志。非 Windows 仅通过 [debugPrint] 输出。
  static void log(String tag, String message) {
    final line = '[${_now()}] [$tag] $message';
    debugPrint(line);
    if (Platform.isWindows) {
      _pendingLines.add(line);
      // 使用 microtask 尽快异步刷新，避免在 UI 线程同步阻塞文件 IO。
      scheduleMicrotask(_flushPending);
    }
  }

  /// 立即刷新所有待写入日志到文件。建议在应用退出前调用。
  static Future<void> flush() async {
    await _flushPending();
  }

  static void _writeToFile(String line) {
    if (!Platform.isWindows) return;
    _pendingLines.add(line);
    _flushPending();
  }

  static Future<void> _flushPending() async {
    if (_flushing) return;
    if (_pendingLines.isEmpty) return;
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
      print('WindowsLogger 写入失败: $e');
    } finally {
      _flushing = false;
      // 刷新期间可能有新日志加入，继续处理。
      if (_pendingLines.isNotEmpty) {
        _flushPending();
      }
    }
  }
}
