/// This file is a part of flutter_mpv (https://github.com/media-kit/media-kit).
///
/// Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
/// All rights reserved.
/// Use of this source code is governed by MIT license that can be found in the LICENSE file.
// ignore_for_file: non_constant_identifier_names, camel_case_types
import 'dart:io';
import 'dart:ffi';

import 'package:flutter_mpv/ffi/ffi.dart';

/// {@template android_helper}
///
/// AndroidHelper
/// -------------
///
/// Learn more: https://github.com/media-kit/media-kit-android-helper
///
/// {@endtemplate}
abstract class AndroidHelper {
  /// {@macro android_helper}
  static void ensureInitialized() {
    try {
      if (Platform.isAndroid) {
        // Load the required shared libraries:
        // * libmpv.so
        // * libavcodec.so
        // * libmediakitandroidhelper.so.
        DynamicLibrary? libmpv, libavcodec, libmediakitandroidhelper;
        try {
          libmpv = DynamicLibrary.open(
            'libmpv.so',
          );
        } catch (_) {}
        try {
          libavcodec = DynamicLibrary.open(
            'libavcodec.so',
          );
        } catch (_) {}
        try {
          libmediakitandroidhelper = DynamicLibrary.open(
            'libmediakitandroidhelper.so',
          );
        } catch (_) {}
        // Look for the required symbols.
        try {
          _mpv_lavc_set_java_vm = libmpv?.lookupFunction<
              mpv_lavc_set_java_vmCXX, mpv_lavc_set_java_vmDart>(
            'mpv_lavc_set_java_vm',
          );
        } catch (_) {}
        try {
          _av_jni_set_java_vm = libavcodec
              ?.lookupFunction<av_jni_set_java_vmCXX, av_jni_set_java_vmDart>(
            'av_jni_set_java_vm',
          );
        } catch (_) {}
        _FlutterMpvAndroidHelperGetJavaVM = _lookupJavaVm(
          libmediakitandroidhelper,
        );
        FlutterMpvAndroidHelperGetFilesDir = _lookupFilesDir(
          libmediakitandroidhelper,
        );
        _FlutterMpvAndroidHelperIsEmulator = _lookupIsEmulator(
          libmediakitandroidhelper,
        );
        _FlutterMpvAndroidHelperGetAPILevel = _lookupApiLevel(
          libmediakitandroidhelper,
        );

        if ((_mpv_lavc_set_java_vm ?? _av_jni_set_java_vm) == null) {
          throw UnsupportedError(
            'Cannot load mpv_lavc_set_java_vm (libmpv.so) or av_jni_set_java_vm (libavcodec.so).',
          );
        }
        if (_FlutterMpvAndroidHelperGetJavaVM == null) {
          throw UnsupportedError(
            'Cannot load FlutterMpvAndroidHelperGetJavaVM (libmediakitandroidhelper.so).',
          );
        }

        Pointer<Void>? vm;
        while (true) {
          // Invoke av_jni_set_java_vm to set reference to JavaVM*.
          // It is important to call av_jni_set_java_vm so that libavcodec can access JNI environment & thus, mediacodec APIs.
          vm = _FlutterMpvAndroidHelperGetJavaVM?.call();
          if (vm != null) {
            if (vm != nullptr) {
              // FFmpeg may be statically linked with libmpv, in that case libavcodec.so will not be available.
              // Following patch exposes mpv_lavc_set_java_vm which internally calls av_jni_set_java_vm.
              // https://github.com/media-kit/libmpv-android-video-build/blob/main/buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch
              // https://github.com/media-kit/libmpv-android-audio-build/blob/main/buildscripts/patches/mpv/mpv_lavc_set_java_vm.patch
              final fn = _mpv_lavc_set_java_vm ?? _av_jni_set_java_vm;
              if (fn != null) {
                fn(vm);
                break;
              }
            }
          }
          sleep(const Duration(milliseconds: 20));
        }
      }
    } catch (_) {}
  }

  static String? get filesDir {
    if (Platform.isAndroid) {
      final filesDir = FlutterMpvAndroidHelperGetFilesDir?.call();
      if (filesDir != null) {
        if (filesDir != nullptr) {
          return filesDir.toDartString();
        }
      }
    }
    return null;
  }

  static bool get isEmulator {
    if (Platform.isAndroid) {
      return _FlutterMpvAndroidHelperIsEmulator?.call() == 1;
    }
    return false;
  }

  static bool get isPhysicalDevice {
    if (Platform.isAndroid) {
      return !isEmulator;
    }
    return false;
  }

  static int get APILevel {
    if (Platform.isAndroid) {
      return _FlutterMpvAndroidHelperGetAPILevel?.call() ?? -1;
    }
    return -1;
  }

  static av_jni_set_java_vmDart? _av_jni_set_java_vm;
  static mpv_lavc_set_java_vmDart? _mpv_lavc_set_java_vm;
  static FlutterMpvAndroidHelperGetJavaVMDart?
      _FlutterMpvAndroidHelperGetJavaVM;
  static FlutterMpvAndroidHelperGetFilesDirDart?
      FlutterMpvAndroidHelperGetFilesDir;
  static FlutterMpvAndroidHelperIsEmulatorDart?
      _FlutterMpvAndroidHelperIsEmulator;
  static FlutterMpvAndroidHelperGetAPILevelDart?
      _FlutterMpvAndroidHelperGetAPILevel;

  static FlutterMpvAndroidHelperGetJavaVMDart? _lookupJavaVm(
    DynamicLibrary? library,
  ) {
    if (library == null) return null;
    for (final symbol in const [
      'FlutterMpvAndroidHelperGetJavaVM',
      'MediaKitAndroidHelperGetJavaVM',
    ]) {
      try {
        return library.lookupFunction<FlutterMpvAndroidHelperGetJavaVMCXX,
            FlutterMpvAndroidHelperGetJavaVMDart>(symbol);
      } catch (_) {}
    }
    return null;
  }

  static FlutterMpvAndroidHelperGetFilesDirDart? _lookupFilesDir(
    DynamicLibrary? library,
  ) {
    if (library == null) return null;
    for (final symbol in const [
      'FlutterMpvAndroidHelperGetFilesDir',
      'MediaKitAndroidHelperGetFilesDir',
    ]) {
      try {
        return library.lookupFunction<FlutterMpvAndroidHelperGetFilesDirCXX,
            FlutterMpvAndroidHelperGetFilesDirDart>(symbol);
      } catch (_) {}
    }
    return null;
  }

  static FlutterMpvAndroidHelperIsEmulatorDart? _lookupIsEmulator(
    DynamicLibrary? library,
  ) {
    if (library == null) return null;
    for (final symbol in const [
      'FlutterMpvAndroidHelperIsEmulator',
      'MediaKitAndroidHelperIsEmulator',
    ]) {
      try {
        return library.lookupFunction<FlutterMpvAndroidHelperIsEmulatorCXX,
            FlutterMpvAndroidHelperIsEmulatorDart>(symbol);
      } catch (_) {}
    }
    return null;
  }

  static FlutterMpvAndroidHelperGetAPILevelDart? _lookupApiLevel(
    DynamicLibrary? library,
  ) {
    if (library == null) return null;
    for (final symbol in const [
      'FlutterMpvAndroidHelperGetAPILevel',
      'MediaKitAndroidHelperGetAPILevel',
    ]) {
      try {
        return library.lookupFunction<FlutterMpvAndroidHelperGetAPILevelCXX,
            FlutterMpvAndroidHelperGetAPILevelDart>(symbol);
      } catch (_) {}
    }
    return null;
  }
}

typedef av_jni_set_java_vmCXX = Int32 Function(Pointer<Void> vm);
typedef av_jni_set_java_vmDart = int Function(Pointer<Void> vm);

typedef mpv_lavc_set_java_vmCXX = Int32 Function(Pointer<Void> vm);
typedef mpv_lavc_set_java_vmDart = int Function(Pointer<Void> vm);

typedef FlutterMpvAndroidHelperGetJavaVMCXX = Pointer<Void> Function();
typedef FlutterMpvAndroidHelperGetJavaVMDart = Pointer<Void> Function();

typedef FlutterMpvAndroidHelperGetFilesDirCXX = Pointer<Utf8> Function();
typedef FlutterMpvAndroidHelperGetFilesDirDart = Pointer<Utf8> Function();

typedef FlutterMpvAndroidHelperIsEmulatorCXX = Int8 Function();
typedef FlutterMpvAndroidHelperIsEmulatorDart = int Function();

typedef FlutterMpvAndroidHelperGetAPILevelCXX = Int32 Function();
typedef FlutterMpvAndroidHelperGetAPILevelDart = int Function();
