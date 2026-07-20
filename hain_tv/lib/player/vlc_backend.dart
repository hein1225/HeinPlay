import 'dart:async';

import 'package:flutter/material.dart';
import 'package:vlc_player/vlc_player.dart';

import '../services/ad_filter_service.dart';
import '../services/user_data_service.dart';
import '../utils/windows_logger.dart';
import 'buffer_profile_config.dart';
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

/// 基于 vlc_player 的 VLC 播放器后端（仅 Windows 可用）。
class VlcBackend implements VideoPlayerBackend {
  VlcPlayerController? _controller;
  final _positionController = StreamController<Duration>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  VoidCallback? _valueListener;
  BoxFit _fit = BoxFit.contain;

  @override
  BoxFit get fit => _fit;

  @override
  set fit(BoxFit value) => _fit = value;

  /// 将 [BoxFit] 映射到 vlc_player 的 [VlcVideoFit]。
  VlcVideoFit _mapFit(BoxFit fit) {
    switch (fit) {
      case BoxFit.fill:
        return VlcVideoFit.fill;
      case BoxFit.cover:
        return VlcVideoFit.cover;
      case BoxFit.none:
        return VlcVideoFit.none;
      case BoxFit.contain:
      default:
        return VlcVideoFit.contain;
    }
  }

  @override
  Widget buildVideoWidget() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return VlcPlayer(
      controller: controller,
      fit: _mapFit(_fit),
      backgroundColor: Colors.black,
    );
  }

  @override
  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
    BufferProfileConfig? bufferConfig,
  }) async {
    await dispose();

    debugPrint('VlcBackend open: $url');
    WindowsLogger.log('VlcBackend', 'open url=$url proxyMode=$proxyMode');

    // 与 FVP 后端保持一致：源声明 proxyMode 或去广告+M3U8 代理配置时走全局代理。
    final lowerUrl = url.toLowerCase();
    String finalUrl = url;
    final proxyUrl = await UserDataService.getM3u8ProxyUrl();
    final adFilterEnabled = await AdFilterService.isEnabled();
    final isLocalProxy = _isLocalProxyUrl(url);
    final isM3u8 = lowerUrl.contains('.m3u8') || lowerUrl.contains('/hls/');
    final needsProxy = !isLocalProxy &&
        (proxyMode || (adFilterEnabled && proxyUrl.isNotEmpty && isM3u8));
    if (needsProxy) {
      finalUrl = '$proxyUrl${Uri.encodeComponent(url)}';
      debugPrint('VlcBackend 使用全局代理: $finalUrl');
      WindowsLogger.log('VlcBackend', '全局代理: $finalUrl');
    }

    // vlc_player 通过 httpHeaders 传递请求头，补齐与 FVP 一致的默认值。
    final httpHeaders = <String, String>{
      'User-Agent': _defaultUserAgent,
      'Accept': '*/*',
      'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
      ..._refererFor(finalUrl),
      ...?headers,
    };

    // vlc_player 暂未接入分级缓冲配置，使用固定默认值。
    const networkCaching = 3000;
    const fileCaching = 3000;

    final mediaOptions = [
      ':network-caching=$networkCaching',
      ':file-caching=$fileCaching',
    ];

    final vlcOptions = <String>[
      '--network-caching=$networkCaching',
      '--file-caching=$fileCaching',
      '--http-user-agent=${httpHeaders['User-Agent']}',
      if (httpHeaders.containsKey('Referer'))
        '--http-referrer=${httpHeaders['Referer']}',
    ];

    try {
      final controller = VlcPlayerController(
        options: vlcOptions,
      );
      _controller = controller;

      _valueListener = () {
        final value = controller.value;
        _positionController.add(value.position);
        _durationController.add(value.duration);
        _playingController.add(value.isPlaying);
      };
      controller.addListener(_valueListener!);

      final source = VlcMediaSource(
        uri: Uri.parse(finalUrl),
        httpHeaders: httpHeaders,
        mediaOptions: mediaOptions,
        startPosition: startAt ?? Duration.zero,
      );
      await controller.setMedia(source, autoPlay: true);
      WindowsLogger.log('VlcBackend', 'open 成功: $finalUrl');
    } catch (e, stack) {
      debugPrint('VlcBackend open error: $e');
      debugPrint('$stack');
      WindowsLogger.log('VlcBackend', 'open 失败: $e');
      WindowsLogger.log('VlcBackend', 'stack: $stack');
      rethrow;
    }
  }

  @override
  Future<void> play() async {
    await _controller?.play();
    _playingController.add(true);
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
    _playingController.add(false);
  }

  @override
  Future<void> seek(Duration position) async {
    await _controller?.seekTo(position);
    _positionController.add(position);
  }

  @override
  Future<void> setSpeed(double speed) async {
    await _controller?.setPlaybackSpeed(speed);
  }

  @override
  Future<void> setVolume(double volume) async {
    // VLC 音量范围 0..200，100 为正常音量。
    await _controller?.setVolume((volume * 100).round().clamp(0, 200));
  }

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Future<void> dispose() async {
    final listener = _valueListener;
    _valueListener = null;
    if (listener != null) {
      _controller?.removeListener(listener);
    }
    _controller?.dispose();
    _controller = null;
  }
}
