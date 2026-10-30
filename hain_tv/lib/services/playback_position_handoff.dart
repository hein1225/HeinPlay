import 'package:flutter/foundation.dart';

import '../models/play_record.dart';
import 'play_record_service.dart';

/// 切换播放器 / 换源 时的**播放位置交接**。
///
/// 🔴🔴 2026-10-17 用户明确要求：全平台（TV / 手机 / 桌面）的换源与换播放器
///   逻辑必须一致，链路固定为：
///   **保存播放记录 → 停止播放 → 切换 → 读取播放记录 → 恢复播放**
///
/// 为什么不能直接用当前 `_position` 起始播点：
///   真机日志（XiaoPaiTech BA001 2026101720，exo→mpv 切换）显示，
///   `_position`、`startAt`、mpv 的 `file-loaded` 都拿到了正确的 279.469s，
///   但 mpv 实际起播在 91.023s（= 片头段 end 90.723 + 0.3）。
///   即「值正确」不等于「能定位」：mpv 对带广告裁剪的 HLS 用 `start=`
///   会落到片头段边界，而首个 `time-pos` 是 `start=` 的**回显**，
///   任何「读到目标值就认为已到位」的校验都会被这个回显骗过。
///
///   把位置写进播放记录再读回，好处是：
///   ① 位置来自持久化的单一可信源，不依赖旧后端在 dispose 过程中的瞬时状态；
///   ② 切换前后同源，不会出现「exo 记 278s、mpv 起在 91s」的割裂；
///   ③ 播放记录本身就是「上次看到哪」的语义，与用户预期一致。
class PlaybackPositionHandoff {
  /// 采集切换前的播放位置，并把它落盘为播放记录。
  ///
  /// 调用时机：**旧后端仍在正常播放时**（dispose 之前）。
  ///
  /// [livePositionMs]   旧后端当前上报的毫秒位置（调用方传 `_position`）
  /// [canSaveRecord]    当前是否满足落盘条件（调用方传 `_isPlaybackReadyForRecord`）
  /// [title]/[year]     用于定位播放记录
  /// [source]/[sourceName]/[id]/[cover]/[index]/[totalEpisodes]/[doubanId]
  ///                    透传给播放记录的其余字段
  /// [durationMs]       片长，用于校验记录值是否离谱
  ///
  /// 返回切换后应当恢复的毫秒位置；无法取得时返回 0（从头播放）。
  static Future<int> capture({
    required int livePositionMs,
    required bool canSaveRecord,
    required String title,
    required String year,
    String source = '',
    String sourceName = '',
    String id = '',
    String cover = '',
    int index = 0,
    int totalEpisodes = 0,
    String? doubanId,
    int durationMs = 0,
  }) async {
    final hasLive = canSaveRecord && livePositionMs > 0;

    // ① 保存播放记录（作为切换后的权威来源）
    if (hasLive) {
      try {
        final totalSec = durationMs > 0 ? (durationMs / 1000).round() : 0;
        final rawPos = (livePositionMs / 1000).round();
        final playSec =
            rawPos < 0 ? 0 : (totalSec > 0 && rawPos > totalSec ? totalSec : rawPos);
        await PlayRecordService.save(
          PlayRecord(
            id: id,
            source: source,
            title: title,
            sourceName: sourceName.isEmpty ? source : sourceName,
            cover: cover,
            year: year,
            index: index,
            totalEpisodes: totalEpisodes,
            playTime: playSec,
            totalTime: totalSec,
            saveTime: DateTime.now().millisecondsSinceEpoch,
            searchTitle: title,
            doubanId: doubanId,
          ),
        );
      } catch (e) {
        debugPrint('切换交接：保存播放记录失败（沿用实时位置）: $e');
      }
    }

    // ② 读取播放记录（读回即恢复点）
    var restoredMs = hasLive ? livePositionMs : 0;
    try {
      final saved = await PlayRecordService.getByTitle(
        title,
        year: year,
        localOnly: true,
      );
      if (saved != null && saved.playTime > 0) {
        final fromRecord = saved.playTime * 1000;
        // 记录值超出片长太多则视为脏数据，丢弃
        final sane = durationMs <= 0 || fromRecord <= durationMs + 60000;
        if (sane) {
          // 实时值缺失（后端已停/未就绪）时用记录值兜底
          final adopted = restoredMs > 0 ? restoredMs : fromRecord;
          debugPrint('切换交接：实时=${livePositionMs}ms 记录=${fromRecord}ms → 采用 ${adopted}ms');
          restoredMs = adopted;
        } else {
          debugPrint('切换交接：记录值 ${fromRecord}ms 超出片长 ${durationMs}ms，忽略');
        }
      }
    } catch (e) {
      debugPrint('切换交接：读取播放记录失败（沿用实时位置）: $e');
    }

    debugPrint('切换交接：最终恢复点=${restoredMs}ms');
    return restoredMs;
  }
}
