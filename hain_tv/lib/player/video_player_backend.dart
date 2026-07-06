import 'dart:async';
import 'package:flutter/material.dart';

abstract class VideoPlayerBackend {
  Widget buildVideoWidget();

  BoxFit get fit;
  set fit(BoxFit value);

  Future<void> open(
    String url, {
    Duration? startAt,
    Map<String, String>? headers,
    bool proxyMode = false,
  });

  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);
  Future<void> setSpeed(double speed);
  Future<void> setVolume(double volume);

  Stream<Duration> get positionStream;
  Stream<Duration> get durationStream;
  Stream<bool> get playingStream;

  Future<void> dispose();
}
