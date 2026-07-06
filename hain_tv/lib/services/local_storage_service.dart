import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';

class PlayRecord {
  final String source;
  final String id;
  final String title;
  final String? posterUrl;
  final String? episodeName;
  final int episodeIndex;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  const PlayRecord({
    required this.source,
    required this.id,
    required this.title,
    this.posterUrl,
    this.episodeName,
    this.episodeIndex = 0,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    required this.updatedAt,
  });

  factory PlayRecord.fromJson(Map<String, dynamic> json) {
    return PlayRecord(
      source: json['source']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString(),
      episodeName: json['episodeName']?.toString(),
      episodeIndex: json['episodeIndex'] ?? 0,
      position: Duration(milliseconds: json['position'] ?? 0),
      duration: Duration(milliseconds: json['duration'] ?? 0),
      updatedAt: DateTime.tryParse(json['updatedAt'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'id': id,
      'title': title,
      if (posterUrl != null) 'posterUrl': posterUrl,
      if (episodeName != null) 'episodeName': episodeName,
      'episodeIndex': episodeIndex,
      'position': position.inMilliseconds,
      'duration': duration.inMilliseconds,
      'updatedAt': updatedAt.toIso8601String(),
    };
  }
}

class FavoriteRecord {
  final String source;
  final String id;
  final String title;
  final String? posterUrl;
  final String? year;
  final DateTime createdAt;

  const FavoriteRecord({
    required this.source,
    required this.id,
    required this.title,
    this.posterUrl,
    this.year,
    required this.createdAt,
  });

  factory FavoriteRecord.fromJson(Map<String, dynamic> json) {
    return FavoriteRecord(
      source: json['source']?.toString() ?? '',
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      posterUrl: json['posterUrl']?.toString(),
      year: json['year']?.toString(),
      createdAt: DateTime.tryParse(json['createdAt'] ?? '') ?? DateTime.now(),
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'source': source,
      'id': id,
      'title': title,
      if (posterUrl != null) 'posterUrl': posterUrl,
      if (year != null) 'year': year,
      'createdAt': createdAt.toIso8601String(),
    };
  }
}

class LocalStorageService {
  static const String _playHistoryKey = 'play_history';
  static const String _favoritesKey = 'favorites';
  static const String _searchHistoryKey = 'search_history';

  static Future<SharedPreferences> _prefs() async {
    return SharedPreferences.getInstance();
  }

  static Future<List<PlayRecord>> getPlayHistory() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_playHistoryKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list
          .map((e) => PlayRecord.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    } catch (_) {
      return [];
    }
  }

  static Future<void> savePlayRecord(PlayRecord record) async {
    final prefs = await _prefs();
    final history = await getPlayHistory();
    final index = history.indexWhere(
      (r) => r.source == record.source && r.id == record.id,
    );
    if (index >= 0) {
      history[index] = record;
    } else {
      history.add(record);
    }
    final limited = history.take(200).toList();
    await prefs.setString(
      _playHistoryKey,
      json.encode(limited.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> clearPlayHistory() async {
    final prefs = await _prefs();
    await prefs.remove(_playHistoryKey);
  }

  static Future<List<FavoriteRecord>> getFavorites() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_favoritesKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list
          .map((e) => FavoriteRecord.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) => b.createdAt.compareTo(a.createdAt));
    } catch (_) {
      return [];
    }
  }

  static Future<bool> isFavorite(String source, String id) async {
    final favorites = await getFavorites();
    return favorites.any((f) => f.source == source && f.id == id);
  }

  static Future<void> addFavorite(FavoriteRecord record) async {
    final prefs = await _prefs();
    final favorites = await getFavorites();
    if (favorites.any((f) => f.source == record.source && f.id == record.id)) {
      return;
    }
    favorites.add(record);
    await prefs.setString(
      _favoritesKey,
      json.encode(favorites.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> removeFavorite(String source, String id) async {
    final prefs = await _prefs();
    final favorites = await getFavorites()
      ..removeWhere((f) => f.source == source && f.id == id);
    await prefs.setString(
      _favoritesKey,
      json.encode(favorites.map((e) => e.toJson()).toList()),
    );
  }

  static Future<void> toggleFavorite(FavoriteRecord record) async {
    if (await isFavorite(record.source, record.id)) {
      await removeFavorite(record.source, record.id);
    } else {
      await addFavorite(record);
    }
  }

  static Future<List<String>> getSearchHistory() async {
    final prefs = await _prefs();
    final raw = prefs.getString(_searchHistoryKey);
    if (raw == null || raw.isEmpty) return [];
    try {
      final list = json.decode(raw) as List<dynamic>;
      return list.map((e) => e.toString()).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> addSearchHistory(String query) async {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return;
    final prefs = await _prefs();
    final history = await getSearchHistory()
      ..remove(trimmed)
      ..insert(0, trimmed);
    final limited = history.take(50).toList();
    await prefs.setString(_searchHistoryKey, json.encode(limited));
  }

  static Future<void> clearSearchHistory() async {
    final prefs = await _prefs();
    await prefs.remove(_searchHistoryKey);
  }

  static Future<void> clearAllCache() async {
    await clearPlayHistory();
    await clearSearchHistory();
    // 收藏不被清除，如需清除可单独调用
  }
}
