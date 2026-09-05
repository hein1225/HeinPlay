import 'dart:async';

/// 串行化播放器的“切集 / 切源”动作，避免复用同一个播放后端实例时并发调用
/// [open] / [dispose] 导致 fvp / ExoPlayer 原生层“切集卡死”。
///
/// 同时对连续请求做合并：若已有更新的切集请求进入（例如用户连点“下一集”），
/// 过期请求会被丢弃，最终只执行最新一次，避免多次切集叠加触发并发 open()。
///
/// 设计要点（避免出现死锁）：
/// - 本类内部用 Future 链式串行，而非简单的布尔锁，因此即使 A 动作内部又发起了
///   B 动作（如切集失败计时器再触发自动换源），也不会自锁。
/// - 调用方在“入口包装方法”里走 [run]，真正的实现（如 _openEpisodeImpl）内部
///   直接调用后端，不再二次进入本闸门。
class PlayerSwitchGate {
  Future<void>? _last;
  int _token = 0;

  /// 串行执行一次切集 / 切源动作，返回该动作的 Future。
  ///
  /// 若 [action] 执行期间有更新的请求进入，则更早的请求会被取消（不再执行），
  /// 仅保留最新一次。这样用户高频连点“下一集”时不会触发并发 open()。
  Future<void> run(Future<void> Function() action) {
    final myToken = ++_token;
    final prev = _last ?? Future<void>.value();
    final completer = Completer<void>();
    _last = completer.future;

    prev.whenComplete(() {
      // 已有更新的切集请求进入：放弃本次执行，避免过期的并发 open()。
      if (myToken != _token) {
        if (!completer.isCompleted) completer.complete();
        return;
      }
      () async {
        try {
          await action();
        } catch (_) {
          // 切集 / 切源失败由调用方在内部处理（设置 _error 等），此处仅兜底，
          // 避免单个动作异常中断后续串行队列。
        }
      }().whenComplete(() {
        if (!completer.isCompleted) completer.complete();
      });
    });

    return completer.future;
  }
}
