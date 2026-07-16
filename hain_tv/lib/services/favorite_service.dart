import 'dart:async';
import 'package:flutter/material.dart';
import '../models/favorite.dart';
import 'favorite_refresh_notifier.dart';
import 'lunatv_service.dart';
import 'local_storage_service.dart' as local;

/// 收藏夹统一管理服务。
///
/// 删除/清空时会同步清理本地 SharedPreferences 与 LunaTV 后端。
class FavoriteService {
  /// 获取本地收藏列表（如需强制刷新请先调用 [syncFromRemote]）。
  static Future<List<Favorite>> getAll() async {
    final localFavorites = await local.LocalStorageService.getFavorites();
    return localFavorites
        .map(
          (f) => Favorite(
            source: f.source,
            id: f.id,
            title: f.title,
            cover: f.posterUrl ?? '',
            sourceName: '',
            saveTime: f.createdAt.millisecondsSinceEpoch,
          ),
        )
        .toList();
  }

  /// 强制从服务器全量同步收藏夹并覆盖本地缓存。
  /// 返回是否成功完成同步。
  static Future<bool> syncFromRemote() async {
    try {
      final response = await LunaTVService.getFavorites(forceRefresh: true);
      if (response.success && response.data != null) {
        final records = response.data!
            .map(
              (f) => local.FavoriteRecord(
                source: f.source,
                id: f.id,
                title: f.title,
                posterUrl: f.cover.isNotEmpty ? f.cover : null,
                createdAt: DateTime.fromMillisecondsSinceEpoch(
                  f.saveTime ?? DateTime.now().millisecondsSinceEpoch,
                ),
              ),
            )
            .toList();
        await local.LocalStorageService.setFavorites(records);
        FavoriteRefreshNotifier.instance.notify();
      }
      return true;
    } catch (e) {
      debugPrint('FavoriteService.syncFromRemote 失败: $e');
      return false;
    }
  }

  /// 删除多条收藏（本地 + 远程）。
  static Future<void> deleteByKeys(List<String> keys) async {
    for (final key in keys) {
      final parts = key.split('+');
      final source = parts.isNotEmpty ? parts[0] : '';
      final id = parts.length > 1 ? parts[1] : '';
      if (source.isEmpty || id.isEmpty) continue;

      await local.LocalStorageService.removeFavorite(source, id);
      unawaited(_deleteRemote(key));
    }
  }

  /// 清空所有收藏（本地 + 远程）。
  static Future<void> clear() async {
    await local.LocalStorageService.clearFavorites();

    try {
      final response = await LunaTVService.getFavorites(forceRefresh: true);
      if (response.success && response.data != null) {
        for (final f in response.data!) {
          final key = '${f.source}+${f.id}';
          unawaited(_deleteRemote(key));
        }
      }
    } catch (e) {
      debugPrint('清空远程收藏失败: $e');
    }
  }

  static Future<void> _deleteRemote(String key) async {
    try {
      final response = await LunaTVService.deleteFavorite(key);
      if (!response.success) {
        debugPrint('删除远程收藏失败: ${response.message}');
      }
    } catch (e) {
      debugPrint('删除远程收藏异常: $e');
    }
  }
}
