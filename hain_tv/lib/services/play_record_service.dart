import 'dart:async';
import 'package:flutter/material.dart';
import '../models/play_record.dart' as models;
import 'local_storage_service.dart' as local;
import 'lunatv_service.dart';

/// 播放记录统一管理服务。
///
/// 保存时先写入本地 SharedPreferences，确保首页/我的页面能立即看到；
/// 然后再异步上传到 LunaTV 后端，失败不影响本地记录。
/// 读取时合并本地与远程记录，以更新时间最晚者为准。
class PlayRecordService {
  /// 保存播放记录：先本地、后异步上传。
  static Future<void> save(models.PlayRecord record) async {
    await local.LocalStorageService.savePlayRecord(
      local.PlayRecord(
        source: record.source,
        id: record.id,
        title: record.title,
        posterUrl: record.cover.isNotEmpty ? record.cover : null,
        episodeName: record.index > 1 ? '第${record.index}集' : null,
        episodeIndex: record.index,
        position: Duration(seconds: record.playTime),
        duration: Duration(seconds: record.totalTime),
        updatedAt: DateTime.fromMillisecondsSinceEpoch(record.saveTime),
      ),
    );

    // 异步上传，不阻塞播放与退出
    unawaited(_uploadToLunaTV(record));
  }

  static Future<void> _uploadToLunaTV(models.PlayRecord record) async {
    try {
      final key = '${record.source}+${record.id}';
      final response = await LunaTVService.savePlayRecord(
        key: key,
        record: record,
      );
      if (!response.success) {
        debugPrint('上传播放记录到 LunaTV 失败: ${response.message}');
      }
    } catch (e) {
      debugPrint('上传播放记录到 LunaTV 异常: $e');
    }
  }

  /// 获取合并后的播放记录列表（本地 + 远程），按保存时间降序。
  static Future<List<models.PlayRecord>> getAll() async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    final merged = <String, models.PlayRecord>{};

    for (final r in localRecords) {
      merged['${r.source}+${r.id}'] = _localToModel(r);
    }

    try {
      final response = await LunaTVService.getPlayRecords();
      if (response.success && response.data != null) {
        for (final entry in response.data!.entries) {
          final key = entry.key;
          final remote = entry.value;
          final existing = merged[key];
          // 同一影片以更新时间更晚的为准
          if (existing == null || remote.saveTime > existing.saveTime) {
            merged[key] = remote;
          }
        }
      }
    } catch (e) {
      debugPrint('获取远程播放记录失败: $e');
    }

    final result = merged.values.toList()
      ..sort((a, b) => b.saveTime.compareTo(a.saveTime));
    return result;
  }

  /// 将本地记录模型转换为统一模型。
  static models.PlayRecord _localToModel(local.PlayRecord r) {
    return models.PlayRecord(
      id: r.id,
      source: r.source,
      title: r.title,
      sourceName: r.source,
      cover: r.posterUrl ?? '',
      year: '',
      index: r.episodeIndex,
      totalEpisodes: 0,
      playTime: r.position.inSeconds,
      totalTime: r.duration.inSeconds,
      saveTime: r.updatedAt.millisecondsSinceEpoch,
      searchTitle: r.title,
    );
  }
}
