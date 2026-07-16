import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_mpv/flutter_mpv.dart';
import 'package:flutter_mpv_video/flutter_mpv_video.dart';
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
      return {'Referer': referer, 'Origin': '${uri.scheme}://${uri.host}'};
    }
  } catch (_) {
    // 忽略无效 URL
  }
  return {};
}

bool _isLocalProxyUrl(String url) {
  try {
    final uri = Uri.parse(url);
    return uri.scheme.startsWith('http') &&
        (uri.host == '127.0.0.1' || uri.host == 'localhost');
  } catch (_) {
    return false;
  }
}

/// 基于 flutter_mpv 的播放器后端。
///
/// Android / TV 端作为 ExoPlayer 的备选，Windows 端作为默认播放器。
class FlutterMpvBackend implements VideoPlayerBackend {
  late final Player _player;
  late final VideoController _controller;
  Video? _video;
  BoxFit _fit = BoxFit.contain;

  FlutterMpvBackend() {
    _player = Player();
    _controller = VideoController(_player);
    _player.stream.error.listen((error) {
      debugPrint('FlutterMpvBackend 播放错误: $error');
    });
    _player.stream.log.listen((log) {
      debugPrint('FlutterMpvBackend log: $log');
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
    final isLocalProxy = _isLocalProxyUrl(url);
    final isM3u8 = lowerUrl.contains('.m3u8') || lowerUrl.contains('/hls/');
    // 统一逻辑：仅当源本身声明 proxyMode，或用户配置了全局 M3U8 代理且当前是 M3U8 时，
    // 才走全局代理；否则直接播放原始 URL（参照 Selene）。
    final needsProxy =
        !isLocalProxy && (proxyMode || (proxyUrl.isNotEmpty && isM3u8));
    if (needsProxy) {
      finalUrl = '$proxyUrl${Uri.encodeComponent(url)}';
    }
    debugPrint('FlutterMpvBackend open: $finalUrl');

    final hardwareDecoding = await UserDataService.getHardwareDecoding();
    // Android 端 flutter_mpv 直接渲染到 Surface 的机制不完善，
    // 使用 mediacodec-copy 在保持硬件解码的同时避免 surface/native_window 为空错误。
    final hwdecValue = hardwareDecoding
        ? (Platform.isAndroid ? 'mediacodec-copy' : 'auto')
        : 'no';
    debugPrint('FlutterMpvBackend hwdec: $hwdecValue');
    final isHls = lowerUrl.contains('.m3u8') ||
        lowerUrl.contains('/hls/') ||
        finalUrl.contains('.m3u8') ||
        finalUrl.contains('/hls/');
    if (_player.platform is NativePlayer) {
      final native = _player.platform as NativePlayer;
      await native.setProperty('hwdec', hwdecValue);
      // 部分 HTTPS 源使用非标准端口或自签证书，关闭 TLS 严格验证避免被服务器拒绝。
      await native.setProperty('tls-verify', 'no');
      // HLS/M3U8 经本地代理后 mpv 可能无法自动识别为可 seek，
      // 强制标记为可 seek，避免只能加载开头几十秒/进度条异常。
      if (isHls) {
        await native.setProperty('force-seekable', 'yes');
        // 本地代理后的 HLS 不应使用本地文件优化（demuxer-readahead-secs=0），
        // 恢复合理的预读时长，避免只缓冲开头几十秒就停止。
        await native.setProperty('demuxer-readahead-secs', '60');
        await native.setProperty('cache-secs', '120');
      }
    }

    final effectiveHeaders = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ..._refererFor(url),
      ...?headers,
    };

    try {
      await _player.open(
        Media(
          finalUrl,
          httpHeaders: effectiveHeaders,
          start: (startAt != null && startAt > Duration.zero) ? startAt : null,
        ),
        play: true,
      );
    } catch (e, stackTrace) {
      debugPrint('FlutterMpvBackend 打开失败: $finalUrl');
      debugPrint('错误: $e');
      debugPrint('$stackTrace');
      rethrow;
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
