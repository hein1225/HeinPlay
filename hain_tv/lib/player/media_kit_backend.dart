import 'dart:async';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import '../services/user_data_service.dart';
import 'video_player_backend.dart';

const _defaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36'
    ' (KHTML, like Gecko) Chrome/121.0.0.0 Safari/537.36';

Map<String, String> _refererFor(String url) {
  try {
    final uri = Uri.parse(url);
    if (uri.scheme.startsWith('http')) {
      final referer = '${uri.scheme}://${uri.host}/';
      return {
        'Referer': referer,
        'Origin': '${uri.scheme}://${uri.host}',
      };
    }
  } catch (_) {
    // 忽略无效 URL
  }
  return {};
}

class MediaKitBackend implements VideoPlayerBackend {
  late final Player _player;
  late final VideoController _controller;
  Video? _video;
  BoxFit _fit = BoxFit.contain;

  MediaKitBackend() {
    _player = Player();
    _controller = VideoController(_player);
    _player.stream.error.listen((error) {
      debugPrint('MediaKitBackend 播放错误: $error');
    });
    _player.stream.log.listen((log) {
      debugPrint('MediaKitBackend log: $log');
    });
  }

  @override
  BoxFit get fit => _fit;
  @override
  set fit(BoxFit value) {
    _fit = value;
    _video = null;
  }

  @override
  Widget buildVideoWidget() {
    _video ??= Video(controller: _controller, fit: _fit);
    return _video!;
  }

  @override
  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
  }) async {
    String finalUrl = url;
    final proxyUrl = await UserDataService.getM3u8ProxyUrl();
    final lowerUrl = url.toLowerCase();
    final needsProxy = proxyMode ||
        lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('/hls/');
    if (proxyUrl.isNotEmpty && needsProxy) {
      finalUrl = '$proxyUrl${Uri.encodeComponent(url)}';
    }
    debugPrint('MediaKitBackend open: $finalUrl');

    final effectiveHeaders = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ..._refererFor(url),
      ...?headers,
    };

    try {
      await _player.open(
        Media(finalUrl, httpHeaders: effectiveHeaders),
        play: true,
      );
    } catch (e, stackTrace) {
      debugPrint('MediaKitBackend 打开失败: $finalUrl');
      debugPrint('错误: $e');
      debugPrint('$stackTrace');
      rethrow;
    }

    if (startAt != null && startAt > Duration.zero) {
      await seek(startAt);
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Future<void> setSpeed(double speed) => _player.setRate(speed);

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume * 100);

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Future<void> dispose() async {
    await _player.dispose();
  }
}
