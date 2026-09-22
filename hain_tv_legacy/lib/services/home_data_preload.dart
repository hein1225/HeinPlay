import 'package:flutter/foundation.dart';

import '../models/api_response.dart';
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

  /// 启动期预加载首页数据的整体超时（秒）。超过此阈值强制降级，绝不让 SplashScreen
  /// 因网络 hang 而卡死、进不了首页。
  static const int _syncTimeoutMs = 10000;
  static const int _hotTimeoutMs = 10000;

  /// 预加载首页数据，供 [SplashScreen] 在进度条阶段调用。
  ///
  /// 设计要点：
  /// - 首次启动（或未登录）时的播放记录/收藏同步与豆瓣热门拉取**各自带硬超时**，
  ///   任何一路网络异常/挂起都不会让本方法无限等待 —— 从根上杜绝「首页卡死」。
  /// - 本地已有缓存数据时，即便远程同步失败也会保留 [hotMovies] 等本地结果，
  ///   让首页能用缓存渲染，而不是空白或加载圈。
  /// - 失败/超时仅打印日志并清理本次结果，不影响进入首页。
  static Future<bool> preload() async {
    try {
      final isFirstEntry = !(await UserDataService.isHomeFirstEntryCompleted());

      // 同步与热门拉取并发启动；两者内部都带独立硬超时，互不阻塞对方。
      final syncFuture = isFirstEntry ? _syncAllUserData() : Future.value(true);
      final resultsFuture = _fetchHot();

      final syncSucceeded = await syncFuture;
      if (isFirstEntry && syncSucceeded) {
        await UserDataService.markHomeFirstEntryCompleted();
      }

      // 本地继续观看永远取自本地缓存，不依赖服务器，保证离线也能显示历史记录。
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

  /// 拉取首页四组豆瓣热门（并发）。分项各自带硬超时，超时/失败以「成功但空列表」
  /// 兜底，避免单个分类接口异常拖累整体或抛出未捕获异常卡住 SplashScreen。
  static Future<List<ApiResponse<List<DoubanMovie>>>> _fetchHot() async {
    const pageLimit = 18;
    ApiResponse<List<DoubanMovie>> empty() =>
        ApiResponse.success(const <DoubanMovie>[]);
    return Future.wait([
      DoubanService.getHotMovies(pageLimit: pageLimit).timeout(
            const Duration(milliseconds: _hotTimeoutMs),
            onTimeout: empty,
          ),
      DoubanService.getHotTvShows(pageLimit: pageLimit).timeout(
            const Duration(milliseconds: _hotTimeoutMs),
            onTimeout: empty,
          ),
      DoubanService.getHotShows(pageLimit: pageLimit).timeout(
            const Duration(milliseconds: _hotTimeoutMs),
            onTimeout: empty,
          ),
      DoubanService.getHotAnimes(pageLimit: pageLimit).timeout(
            const Duration(milliseconds: _hotTimeoutMs),
            onTimeout: empty,
          ),
    ]);
  }

  /// 公开封装：从服务器同步播放记录与收藏夹到本地缓存。
  /// 供登录页在登录成功后调用，确保首页“首次进入”标记被置位前本地已是最新数据。
  static Future<bool> syncAllUserData() => _syncAllUserData();

  static Future<bool> _syncAllUserData() async {
    try {
      final results = await Future.wait([
        PlayRecordService.syncFromRemote(),
        FavoriteService.syncFromRemote(),
      ]).timeout(const Duration(milliseconds: _syncTimeoutMs));
      return results.every((r) => r);
    } catch (e) {
      debugPrint('HomeDataPreload: 首次全量同步失败/超时: $e');
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
