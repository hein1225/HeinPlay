import 'dart:async';

import '../utils/app_logger.dart';

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
///
/// 🔴🔴 2026-10-23 修复「部分源换源后软件卡死」：
/// 原实现有一个**队列中毒**缺陷——本闸门是 Future 链式串行，链条上的每一个
/// completer 都必须被 complete 才能让后继动作开始。若某个动作内部有 await
/// 永久挂起（网络层/存储层/原生回调任一处不返回），它的 completer 就**永远不会
/// 完成**，于是：
///   ① 该动作永远占着闸门，后续所有切源 / 切集请求全部排队等一个永不完成的
///      Future → 用户看到「怎么点都没反应」；
///   ② 闸门后面的动作一个都执行不了 → 整个播放页的切源 / 切集功能一起失效。
/// 这就是「只有部分源会卡死」的形态：源本身能不能把流程走完，决定了闸门会不会
/// 被毒死。
///
/// 修法：给每个动作加**超时熔断**——超过 [defaultTimeout] 仍未完成，就判定该
/// 动作已挂起：强制完成 completer（放行队列），并回调 [onTimeout] 让调用方复位
/// UI 状态（否则「切换中」遮罩会永久停留，同样表现为卡死）。原始 Future 继续
/// 挂着也无妨：它不再阻塞闸门，且其未捕获异常已被吞掉。
class PlayerSwitchGate {
  Future<void>? _last;
  int _token = 0;

  /// 动作超时上限。正常切源 / 切集（含等待起播就绪）在 30 秒内完成，
  /// 90 秒仍未返回基本可以判定为挂起。
  static const Duration defaultTimeout = Duration(seconds: 90);

  /// 串行执行一次切集 / 切源动作，返回该动作的 Future。
  ///
  /// 若 [action] 执行期间有更新的请求进入，则更早的请求会被取消（不再执行），
  /// 仅保留最新一次。这样用户高频连点“下一集”时不会触发并发 open()。
  ///
  /// [timeout] 超过后熔断该动作并放行队列；[onTimeout] 用于让调用方复位 UI
  /// 状态（「切换中」遮罩、错误提示等）。[label] 只用于日志定位。
  Future<void> run(
    Future<void> Function() action, {
    Duration? timeout,
    void Function()? onTimeout,
    String label = '',
  }) {
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
          await action().timeout(timeout ?? defaultTimeout).catchError((Object e) {
            // 🔴 熔断：动作挂起超时，释放闸门队列并通知调用方复位 UI。
            AppLogger.logDirect(
              'SwitchGate',
              '动作超时熔断，已释放队列: label=$label error=$e',
            );
            try {
              onTimeout?.call();
            } catch (_) {
              // 复位回调自身出错不影响闸门。
            }
          });
        } catch (e) {
          // 切集 / 切源失败由调用方在内部处理（设置 _error 等），此处仅兜底，
          // 避免单个动作异常中断后续串行队列。
          AppLogger.logDirect('SwitchGate', '动作异常: label=$label error=$e');
        }
      }().whenComplete(() {
        if (!completer.isCompleted) completer.complete();
      });
    });

    return completer.future;
  }
}
