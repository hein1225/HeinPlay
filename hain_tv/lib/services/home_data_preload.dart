import 'package:flutter/foundation.dart';

import '../models/douban_movie.dart';
import '../models/play_record.dart';
import 'douban_service.dart';
import 'favorite_service.dart';
import 'play_record_service.dart';
import 'user_data_service.dart';

/// 首页数据预加载缓存。
///
/// 在 [SplashScreen] 初始化阶段提前拉取首页所需的豆瓣热门数据、继续观看记录以及
/// 首次进入时的服务器同步，避免进入首页后出现单独的加载圈。
class HomeDataPreload {
  HomeDataPreload._();

  static List<DoubanMovie>? hotMovies;
  static List<DoubanMovie>? hotTvShows;
  static List<DoubanMovie>? hotShows;
  static List<DoubanMovie>? hotAnimes;
  static List<PlayRecord>? continueWatching;
  static List<PlayRecord>? allContinueWatching;

  static bool get hasData => hotMovies != null;

  /// 预加载首页数据，供 [SplashScreen] 在进度条阶段调用。
  /// 失败时仅打印日志，不影响进入首页（首页会自己重试）。
  static Future<bool> preload() async {
    try {
      const pageLimit = 18;
      final isFirstEntry = !(await UserDataService.isHomeFirstEntryCompleted());
      final syncFuture = isFirstEntry ? _syncAllUserData() : Future.value(true);

      final resultsFuture = Future.wait([
        DoubanService.getHotMovies(pageLimit: pageLimit),
        DoubanService.getHotTvShows(pageLimit: pageLimit),
        DoubanService.getHotShows(pageLimit: pageLimit),
        DoubanService.getHotAnimes(pageLimit: pageLimit),
      ]);

      final syncSucceeded = await syncFuture;
      if (isFirstEntry && syncSucceeded) {
        await UserDataService.markHomeFirstEntryCompleted();
      }

      final allRecords = await PlayRecordService.getAllLocal();
      final results = await resultsFuture;

      hotMovies = results[0].success ? results[0].data ?? [] : [];
      hotTvShows = results[1].success ? results[1].data ?? [] : [];
      hotShows = results[2].success ? results[2].data ?? [] : [];
      hotAnimes = results[3].success ? results[3].data ?? [] : [];
      allContinueWatching = allRecords;
      continueWatching = allRecords.take(12).toList();
      return true;
    } catch (e, s) {
      debugPrint('首页数据预加载失败: $e\n$s');
      clear();
      return false;
    }
  }

  static Future<bool> _syncAllUserData() async {
    try {
      final results = await Future.wait([
        PlayRecordService.syncFromRemote(),
        FavoriteService.syncFromRemote(),
      ]);
      return results.every((r) => r);
    } catch (e) {
      debugPrint('HomeDataPreload: 首次全量同步失败: $e');
      return false;
    }
  }

  static void clear() {
    hotMovies = null;
    hotTvShows = null;
    hotShows = null;
    hotAnimes = null;
    continueWatching = null;
    allContinueWatching = null;
  }
}
