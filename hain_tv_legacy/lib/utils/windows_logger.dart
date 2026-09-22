import 'app_logger.dart';

/// 兼容旧代码的 Windows 日志入口。
///
/// 实际日志逻辑已迁移到 [AppLogger]，本类保留旧 API 以尽量减少历史调用处修改。
/// 所有方法最终委托给 [AppLogger]，并受设置中「获取日志」开关控制。
@Deprecated('请优先使用 AppLogger')
class WindowsLogger {
  /// 初始化日志。返回是否成功完成初始化。
  static Future<bool> initialize() => AppLogger.initialize();

  /// 写入日志。
  static void log(String tag, String message) => AppLogger.log(tag, message);

  /// 立即刷新所有待写入日志到文件。建议在应用退出前调用。
  static Future<void> flush() => AppLogger.flush();
}
