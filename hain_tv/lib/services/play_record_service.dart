import 'dart:async';
import 'package:flutter/material.dart';
import '../models/douban_movie.dart';
import '../models/play_record.dart' as models;
import 'douban_service.dart';
import 'local_storage_service.dart' as local;
import 'lunatv_service.dart';
import 'play_record_refresh_notifier.dart';

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
        doubanId: record.doubanId,
        year: record.year.isNotEmpty ? record.year : null,
      ),
    );

    // 本地保存后立即通知各页面刷新，无需等待远程上传
    PlayRecordRefreshNotifier.instance.notify();

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

  static String _mergeKey(String title, String year) {
    return '${_normalize(title)}|${year.trim()}';
  }

  /// 判断两条记录是否属于同一部影视。
  /// 标题高度相似（如“阿甘正传”与“阿甘正传国语”），且年份相同或至少一方年份为空时视为同一部。
  static bool _isSameVideo(models.PlayRecord a, models.PlayRecord b) {
    if (_titleSimilarity(a.title, b.title) < 0.9) return false;
    final yearA = a.year.trim();
    final yearB = b.year.trim();
    if (yearA.isEmpty || yearB.isEmpty) return true;
    return yearA == yearB;
  }

  /// 将多条记录按影视标题合并为一条，同一影视保留更新时间最晚的记录。
  /// 对年份缺失的记录会按标题兜底合并，避免同一影视因年份字段不齐而重复显示。
  static Map<String, models.PlayRecord> _mergeByTitle(
    Iterable<models.PlayRecord> records,
  ) {
    final groups = <_MergeGroup>[];

    for (final r in records) {
      _MergeGroup? matched;
      for (final group in groups) {
        if (_isSameVideo(r, group.representative)) {
          matched = group;
          break;
        }
      }
      if (matched == null) {
        groups.add(_MergeGroup(representative: r));
      } else {
        matched.add(r);
      }
    }

    final merged = <String, models.PlayRecord>{};
    for (final group in groups) {
      final key = _mergeKey(group.representative.title, group.representative.year);
      merged[key] = group.representative;
    }
    return merged;
  }

  /// 仅获取本地播放记录列表，按保存时间降序。
  /// 不请求远程服务器，不 enrich 豆瓣海报，用于快速刷新 UI。
  static Future<List<models.PlayRecord>> getAllLocal() async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    final merged = _mergeByTitle(localRecords.map(_localToModel));
    return merged.values.toList()
      ..sort((a, b) => b.saveTime.compareTo(a.saveTime));
  }

  /// 获取合并后的播放记录列表（本地 + 远程），按保存时间降序。
  /// 同一影视的不同播放源记录会合并为一条，保留最近一次的播放源。
  static Future<List<models.PlayRecord>> getAll() async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    final merged = _mergeByTitle(localRecords.map(_localToModel));

    try {
      final response = await LunaTVService.getPlayRecords();
      if (response.success && response.data != null) {
        final remoteMerged = _mergeByTitle(response.data!.values);
        for (final entry in remoteMerged.entries) {
          final existing = merged[entry.key];
          // 同一影片以更新时间更晚的为准
          if (existing == null || entry.value.saveTime > existing.saveTime) {
            merged[entry.key] = entry.value;
          }
        }
      }
    } catch (e) {
      debugPrint('获取远程播放记录失败: $e');
    }

    final result = merged.values.toList()
      ..sort((a, b) => b.saveTime.compareTo(a.saveTime));

    // 并发匹配豆瓣海报，原播放源海报失效时仍可使用豆瓣海报
    return await _enrichAllWithDoubanPosters(result);
  }

  /// 获取指定标题的最新播放记录。
  ///
  /// 当 [localOnly] 为 true 时只读取本地记录，不请求远程服务器，
  /// 用于播放退出后快速刷新详情页继续播放按钮。
  static Future<models.PlayRecord?> getByTitle(
    String title, {
    String year = '',
    bool localOnly = false,
  }) async {
    final all = localOnly ? await getAllLocal() : await getAll();
    final key = _mergeKey(title, year);
    return all.cast<models.PlayRecord?>().firstWhere(
          (r) => _mergeKey(r!.title, r.year) == key,
          orElse: () => null,
        );
  }

  /// 仅读取本地指定标题的最新播放记录，不请求远程服务器。
  static Future<models.PlayRecord?> getLatestLocalByTitle(
    String title, {
    String year = '',
  }) async {
    return getByTitle(title, year: year, localOnly: true);
  }

  /// 将本地记录模型转换为统一模型。
  static models.PlayRecord _localToModel(local.PlayRecord r) {
    return models.PlayRecord(
      id: r.id,
      source: r.source,
      title: r.title,
      sourceName: r.source,
      cover: r.posterUrl ?? '',
      year: r.year ?? '',
      index: r.episodeIndex,
      totalEpisodes: 0,
      playTime: r.position.inSeconds,
      totalTime: r.duration.inSeconds,
      saveTime: r.updatedAt.millisecondsSinceEpoch,
      searchTitle: r.title,
      doubanId: r.doubanId,
    );
  }

  static bool _isDoubanUrl(String url) {
    final lower = url.toLowerCase();
    return lower.contains('douban') || lower.contains('doubanio');
  }

  static String _normalize(String text) {
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^\w\s\u4e00-\u9fff]+'), '')
        .replaceAll(RegExp(r'\s+'), '')
        .trim();
  }

  static double _titleSimilarity(String a, String b) {
    final na = _normalize(a);
    final nb = _normalize(b);
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;
    if (na.contains(nb) || nb.contains(na)) return 0.9;
    return 0.0;
  }

  /// 尝试为播放记录匹配豆瓣海报。
  static Future<models.PlayRecord> _enrichWithDoubanPoster(
    models.PlayRecord record,
  ) async {
    // 已有豆瓣海报则跳过
    if (_isDoubanUrl(record.cover)) return record;

    // 优先通过豆瓣 ID 获取
    final doubanId = record.doubanId;
    if (doubanId != null && doubanId.isNotEmpty) {
      try {
        final response = await DoubanService.getDetails(doubanId: doubanId)
            .timeout(const Duration(seconds: 5));
        if (response.success &&
            response.data != null &&
            response.data!.poster.isNotEmpty) {
          return record.copyWith(cover: response.data!.poster);
        }
      } catch (e) {
        debugPrint('通过豆瓣ID获取海报失败: $e');
      }
    }

    // 无豆瓣 ID 时通过标题搜索匹配
    if (record.title.isNotEmpty) {
      try {
        final response = await DoubanService.search(
          keyword: record.title,
          limit: 5,
        ).timeout(const Duration(seconds: 5));
        if (response.success && response.data != null) {
          DoubanMovie? bestMatch;
          var bestScore = 0.0;
          for (final candidate in response.data!) {
            var score = _titleSimilarity(record.title, candidate.title);
            if (record.year.isNotEmpty &&
                candidate.year.isNotEmpty &&
                record.year == candidate.year) {
              score += 0.2;
            }
            if (score > bestScore) {
              bestScore = score;
              bestMatch = candidate;
            }
          }
          if (bestMatch != null &&
              bestScore >= 0.6 &&
              bestMatch.poster.isNotEmpty) {
            return record.copyWith(cover: bestMatch.poster);
          }
        }
      } catch (e) {
        debugPrint('通过标题搜索豆瓣海报失败: $e');
      }
    }

    return record;
  }

  /// 并发为所有记录匹配豆瓣海报，单条超时 6 秒，避免阻塞 UI。
  static Future<List<models.PlayRecord>> _enrichAllWithDoubanPosters(
    List<models.PlayRecord> records,
  ) async {
    final futures = records.map((record) async {
      try {
        return await _enrichWithDoubanPoster(record)
            .timeout(const Duration(seconds: 6));
      } catch (e) {
        return record;
      }
    }).toList();
    return await Future.wait(futures);
  }

  /// 删除多条播放记录（本地 + 远程）。
  /// [keys] 为影视标题（与 UI 中 [PlayRecord.title] 一致）。
  static Future<void> deleteByKeys(List<String> keys) async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    // 使用标题相似度匹配，确保删除合并记录时能清除所有来源的原始记录
    final remaining = localRecords
        .where(
          (r) => !keys.any((key) => _titleSimilarity(r.title, key) >= 0.9),
        )
        .toList();
    await local.LocalStorageService.setPlayHistory(remaining);

    try {
      final response = await LunaTVService.getPlayRecords();
      if (response.success && response.data != null) {
        for (final entry in response.data!.entries) {
          final record = entry.value;
          if (keys.any((key) => _titleSimilarity(record.title, key) >= 0.9)) {
            unawaited(_deleteRemote(entry.key));
          }
        }
      }
    } catch (e) {
      debugPrint('删除远程播放记录时获取列表失败: $e');
    }
  }

  /// 清空所有播放记录（本地 + 远程）。
  static Future<void> clear() async {
    await local.LocalStorageService.clearPlayHistory();

    try {
      final response = await LunaTVService.getPlayRecords();
      if (response.success && response.data != null) {
        for (final key in response.data!.keys) {
          unawaited(_deleteRemote(key));
        }
      }
    } catch (e) {
      debugPrint('清空远程播放记录失败: $e');
    }
  }

  static Future<void> _deleteRemote(String key) async {
    try {
      final response = await LunaTVService.deletePlayRecord(key);
      if (!response.success) {
        debugPrint('删除远程播放记录失败: ${response.message}');
      }
    } catch (e) {
      debugPrint('删除远程播放记录异常: $e');
    }
  }
}

/// 合并组：保留更新时间最晚的代表记录，并在有非空年份时优先采用该年份。
/// 展示标题优先使用组内最短的相似标题（如“阿甘正传”而非“阿甘正传国语”）。
class _MergeGroup {
  models.PlayRecord representative;

  _MergeGroup({required this.representative});

  void add(models.PlayRecord record) {
    models.PlayRecord newRep = record.saveTime > representative.saveTime
        ? record
        : representative;

    // 若新记录标题更短且与代表标题高度相似，采用更短的标题用于展示和搜索
    if (record.title.isNotEmpty &&
        record.title.length < newRep.title.length &&
        PlayRecordService._titleSimilarity(record.title, newRep.title) >= 0.9) {
      newRep = newRep.copyWith(title: record.title);
    }

    // 若代表记录年份为空而新记录有年份，则补全年份
    if (newRep.year.trim().isEmpty && record.year.trim().isNotEmpty) {
      newRep = newRep.copyWith(year: record.year.trim());
    }

    representative = newRep;
  }
}
