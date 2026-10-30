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
  /// 标题、源或 ID 为空时不保存，避免产生无法删除、无法进入详情的脏记录。
  static Future<void> save(models.PlayRecord record) async {
    if (record.title.trim().isEmpty ||
        record.source.trim().isEmpty ||
        record.id.trim().isEmpty) {
      debugPrint(
        'PlayRecordService: 跳过保存无效播放记录 title="${record.title}" source="${record.source}" id="${record.id}"',
      );
      return;
    }

    // 🔴🔴 2026-10-23 修复：playTime=0 的记录**不得**覆盖同一集的正常进度。
    //   换源/换集后新后端起播慢（Windows VLC 实测 16 秒才出画面），这期间
    //   `_position` 一直是 0；若此时落盘，合并规则（更新时间最晚者为准）会让这条
    //   「0 进度」记录盖掉旧进度（本地 131s、远程 1298s 都被盖），
    //   详情页「继续播放」于是每次都读到 0 → 表现为「播放记录读不到」。
    //   判据：同一 source+id 且**同一集**，且已有进度 > 0 → 跳过本次写入。
    //   （换集不受影响：新的一集 index 不同，属于合法的「从头播」。）
    //
    // 🔴🔴 2026-10-23 追加：这段本地读取**必须**带超时。
    //   实测（Windows 12:55:13 换源到 iqiyizyapi.com）整个 UI 就卡在这里：
    //   「切换操作开始」打印后再无任何日志，进程最终被强杀。本地读取一旦挂起
    //   （存储层异常/插件回调不返回），保存流程不结束 → 切源流程整体挂死，
    //   并进一步毒死 PlayerSwitchGate 的串行队列（后续切源/切集全部失效）。
    //   读本地进度只是「保护性判断」，读不到就按「无已有进度」处理即可，
    //   绝不能因此挡住播放记录的保存。
    if (record.playTime <= 0) {
      final existing = await _findLocalProgress(
        source: record.source,
        id: record.id,
        index: record.index,
      );
      if (existing != null && existing > 0) {
        debugPrint(
          'PlayRecordService: 跳过 0 进度覆盖（保留已有进度 ${existing}s '
          'source=${record.source} id=${record.id} index=${record.index}）',
        );
        return;
      }
    }

    // 🔴 2026-10-23：写入也带超时 + 失败不阻断上层（换源/退出）。
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
    ).timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        debugPrint(
          'PlayRecordService: 本地写入超时（已放弃，播放流程继续） '
          'source=${record.source} id=${record.id} index=${record.index}',
        );
      },
    );

    // 本地保存后立即通知各页面刷新，无需等待远程上传。
    // 🔴 2026-10-23：监听器抛错不得中断保存流程（否则切源流程挂死在此）。
    try {
      PlayRecordRefreshNotifier.instance.notify();
    } catch (e) {
      debugPrint('PlayRecordService: 刷新通知异常（已忽略）: $e');
    }

    // 异步上传，不阻塞播放与退出
    unawaited(_uploadToLunaTV(record));
  }

  /// 查找本地同一「源 + ID + 集数」已保存的进度（秒）。
  ///
  /// 用于 [save] 的 0 进度保护：只有**同一集**的已有进度才会被 0 覆盖保护，
  /// 换集（index 不同）属于合法的「从头播」，不受限制。
  static Future<int?> _findLocalProgress({
    required String source,
    required String id,
    required int index,
  }) async {
    try {
      // 🔴 2026-10-23：5 秒超时。读本地进度只是保护性判断，
      //   读不到就当「无已有进度」，绝不能挂住整个保存流程。
      final records = await local.LocalStorageService.getPlayHistory().timeout(
        const Duration(seconds: 5),
      );
      for (final r in records) {
        if (r.source == source && r.id == id && r.episodeIndex == index) {
          return r.position.inSeconds;
        }
      }
    } catch (e) {
      debugPrint('PlayRecordService: 读取本地进度失败: $e');
    }
    return null;
  }

  static Future<void> _uploadToLunaTV(models.PlayRecord record) async {
    final key = '${record.source}+${record.id}';
    try {
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
      final key = _mergeKey(
        group.representative.title,
        group.representative.year,
      );
      merged[key] = group.representative;
    }
    return merged;
  }

  /// 清理本地播放记录中的脏数据（空标题、空源、空 ID）。
  static Future<List<local.PlayRecord>> _cleanInvalidLocalRecords(
    List<local.PlayRecord> records,
  ) async {
    final cleaned = records.where((r) {
      return r.title.trim().isNotEmpty &&
          r.source.trim().isNotEmpty &&
          r.id.trim().isNotEmpty;
    }).toList();
    if (cleaned.length != records.length) {
      await local.LocalStorageService.setPlayHistory(cleaned);
      debugPrint(
        'PlayRecordService: 已清理 ${records.length - cleaned.length} 条无效本地播放记录',
      );
    }
    return cleaned;
  }

  /// 仅获取本地播放记录列表，按保存时间降序。
  /// 不请求远程服务器，不 enrich 豆瓣海报，用于快速刷新 UI。
  /// 会自动清理无效记录。
  static Future<List<models.PlayRecord>> getAllLocal() async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    final cleaned = await _cleanInvalidLocalRecords(localRecords);
    final merged = _mergeByTitle(cleaned.map(_localToModel));
    return merged.values.toList()
      ..sort((a, b) => b.saveTime.compareTo(a.saveTime));
  }

  /// 获取合并后的播放记录列表（本地 + 远程），按保存时间降序。
  /// 同一影视的不同播放源记录会合并为一条，保留最近一次的播放源。
  /// 会自动清理本地无效记录。
  /// [forceRefresh] 为 true 时跳过远程缓存直接请求服务器，并将合并结果写回本地缓存。
  static Future<List<models.PlayRecord>> getAll({bool forceRefresh = false}) async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    final cleaned = await _cleanInvalidLocalRecords(localRecords);
    final merged = _mergeByTitle(cleaned.map(_localToModel));

    try {
      final response = await LunaTVService.getPlayRecords(forceRefresh: forceRefresh);
      if (response.success && response.data != null) {
        final remoteMerged = _mergeByTitle(response.data!.values);
        for (final entry in remoteMerged.entries) {
          final existing = merged[entry.key];
          // 同一影片以更新时间更晚的为准
          if (existing == null || entry.value.saveTime > existing.saveTime) {
            // 🔴 2026-10-23：同一集时，远程这条若为 0 进度，不得盖掉本地已有的正常进度。
            if (existing != null &&
                entry.value.index == existing.index &&
                entry.value.playTime == 0 &&
                existing.playTime > 0) {
              continue;
            }
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
    final enriched = await _enrichAllWithDoubanPosters(result);

    // 强制刷新时把合并后的结果（含豆瓣海报）写回本地缓存，供首页/我的离线读取。
    if (forceRefresh) {
      await _persistModelRecords(enriched);
    }

    return enriched;
  }

  /// 将统一模型列表持久化到本地 SharedPreferences。
  static Future<void> _persistModelRecords(List<models.PlayRecord> records) async {
    final localRecords = records.map(_modelToLocal).toList();
    await local.LocalStorageService.setPlayHistory(localRecords);
  }

  /// 获取指定标题的最新播放记录。
  ///
  /// 当 [localOnly] 为 true 时只读取本地记录，不请求远程服务器，
  /// 用于播放退出后快速刷新详情页继续播放按钮。
  /// 使用 [_isSameVideo] 进行语义匹配，避免 Bangumi/动漫条目因年份为空
  /// 或标题带后缀而无法命中已保存的播放记录。
  static Future<models.PlayRecord?> getByTitle(
    String title, {
    String year = '',
    bool localOnly = false,
  }) async {
    final all = localOnly ? await getAllLocal() : await getAll();
    final reference = models.PlayRecord(
      id: '',
      source: '',
      title: title,
      sourceName: '',
      cover: '',
      year: year,
      index: 0,
      totalEpisodes: 0,
      playTime: 0,
      totalTime: 0,
      saveTime: 0,
      searchTitle: title,
    );
    models.PlayRecord? best;
    for (final r in all) {
      if (_isSameVideo(r, reference)) {
        if (best == null || r.saveTime > best.saveTime) {
          best = r;
        }
      }
    }
    return best;
  }

  /// 根据多个候选标题查找最新播放记录。
  /// 返回与任一候选标题匹配且时间最近的一条记录。
  static Future<models.PlayRecord?> findByTitles(
    List<String> titles, {
    String year = '',
    bool localOnly = false,
  }) async {
    if (titles.isEmpty) return null;
    final all = localOnly ? await getAllLocal() : await getAll();
    models.PlayRecord? best;
    for (final r in all) {
      for (final title in titles) {
        final reference = models.PlayRecord(
          id: '',
          source: '',
          title: title,
          sourceName: '',
          cover: '',
          year: year,
          index: 0,
          totalEpisodes: 0,
          playTime: 0,
          totalTime: 0,
          saveTime: 0,
          searchTitle: title,
        );
        if (_isSameVideo(r, reference)) {
          if (best == null || r.saveTime > best.saveTime) {
            best = r;
          }
          break;
        }
      }
    }
    return best;
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

  /// 将统一模型转换为本地记录模型。
  static local.PlayRecord _modelToLocal(models.PlayRecord r) {
    return local.PlayRecord(
      source: r.source,
      id: r.id,
      title: r.title,
      posterUrl: r.cover.isNotEmpty ? r.cover : null,
      episodeName: r.index > 1 ? '第${r.index}集' : null,
      episodeIndex: r.index,
      position: Duration(seconds: r.playTime),
      duration: Duration(seconds: r.totalTime),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r.saveTime),
      doubanId: r.doubanId,
      year: r.year.isNotEmpty ? r.year : null,
    );
  }

  /// 强制从服务器全量同步播放记录并覆盖本地缓存。
  /// 返回是否成功完成同步。
  static Future<bool> syncFromRemote() async {
    try {
      // 先清空本地旧数据，确保用云端数据完整覆盖，避免软件更新后旧缓存残留。
      await local.LocalStorageService.clearPlayHistory();
      await getAll(forceRefresh: true);
      // getAll(forceRefresh: true) 内部已将远程结果写回本地缓存。
      PlayRecordRefreshNotifier.instance.notify();
      return true;
    } catch (e) {
      debugPrint('PlayRecordService.syncFromRemote 失败: $e');
      return false;
    }
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
    String normalize(String s) {
      var result = s
          .toLowerCase()
          .replaceAll(RegExp(r'[^\w\s\u4e00-\u9fff]+'), '')
          .replaceAll(RegExp(r'\s+'), '')
          .trim();
      // 将罗马数字/圈数字归一为阿拉伯数字，提升含“Ⅲ”“①”等标题的匹配率
      const digitMap = {
        'ⅰ': '1', 'ⅱ': '2', 'ⅲ': '3', 'ⅳ': '4', 'ⅴ': '5',
        'ⅵ': '6', 'ⅶ': '7', 'ⅷ': '8', 'ⅸ': '9', 'ⅹ': '10',
        '①': '1', '②': '2', '③': '3', '④': '4', '⑤': '5',
        '⑥': '6', '⑦': '7', '⑧': '8', '⑨': '9', '⑩': '10',
        'Ⅰ': '1', 'Ⅱ': '2', 'Ⅲ': '3', 'Ⅳ': '4', 'Ⅴ': '5',
        'Ⅵ': '6', 'Ⅶ': '7', 'Ⅷ': '8', 'Ⅸ': '9', 'Ⅹ': '10',
      };
      digitMap.forEach((k, v) {
        result = result.replaceAll(k, v);
      });
      return result;
    }

    final na = normalize(a);
    final nb = normalize(b);
    if (na.isEmpty || nb.isEmpty) return 0.0;
    if (na == nb) return 1.0;
    if (na.contains(nb) || nb.contains(na)) return 0.9;

    final matchedChars = na.split('').where(nb.contains).length;
    return matchedChars / na.length;
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
        final response = await DoubanService.getDetails(
          doubanId: doubanId,
        ).timeout(const Duration(seconds: 5));
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
            return record.copyWith(
              cover: bestMatch.poster,
              doubanId: bestMatch.id,
            );
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
        return await _enrichWithDoubanPoster(
          record,
        ).timeout(const Duration(seconds: 6));
      } catch (e) {
        return record;
      }
    }).toList();
    return await Future.wait(futures);
  }

  /// 删除多条播放记录（本地 + 远程）。
  /// [keys] 为影视标题（与 UI 中 [PlayRecord.title] 一致）。
  /// 空标题 key 会匹配并删除本地所有无效（空标题/空源/空 ID）记录。
  static Future<void> deleteByKeys(List<String> keys) async {
    final localRecords = await local.LocalStorageService.getPlayHistory();
    // 使用标题相似度匹配，确保删除合并记录时能清除所有来源的原始记录。
    // 如果 key 为空，则删除本地无效记录。
    final remaining = localRecords
        .where(
          (r) => !keys.any((key) {
            if (key.trim().isEmpty) {
              return r.title.trim().isEmpty ||
                  r.source.trim().isEmpty ||
                  r.id.trim().isEmpty;
            }
            return _titleSimilarity(r.title, key) >= 0.9;
          }),
        )
        .toList();
    await local.LocalStorageService.setPlayHistory(remaining);

    try {
      final response = await LunaTVService.getPlayRecords(forceRefresh: true);
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
      final response = await LunaTVService.getPlayRecords(forceRefresh: true);
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

    // 🔴🔴 2026-10-23 修复：**同一集**的进度必须取较大值，不能只看 saveTime。
    //   换源/换集后新后端起播慢（Windows VLC 实测 16 秒），期间 `_position` 仍为 0，
    //   会落盘一条「0 进度」记录；它 saveTime 最新，于是把正常进度整体盖掉
    //   （本地 131s、远程 1298s 都被盖）→ 详情页「继续播放」每次都读到 0。
    //   规则：同集 → 进度取 max；不同集 → 仍以 saveTime 最新为准（换集要归零）。
    //
    //   注意不能只判 `representative.playTime > newRep.playTime`：当两条都是
    //   「同集、一条 0 一条非 0」且 0 那条 saveTime 更晚时，比较基准已切换，
    //   会漏判。正确做法是同集时对两条的进度直接取 max。
    if (record.index == representative.index) {
      final maxPlay = record.playTime > newRep.playTime
          ? record.playTime
          : newRep.playTime;
      if (maxPlay != newRep.playTime) {
        newRep = newRep.copyWith(playTime: maxPlay);
      }
      final maxTotal = record.totalTime > newRep.totalTime
          ? record.totalTime
          : newRep.totalTime;
      if (maxTotal != newRep.totalTime) {
        newRep = newRep.copyWith(totalTime: maxTotal);
      }
    }

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
