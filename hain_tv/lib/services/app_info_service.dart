import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:win32/win32.dart';

/// 应用版本信息缓存，避免在多处重复异步读取 [PackageInfo]。
class AppInfoService {
  /// 兜底版本号，与 pubspec.yaml 的 version 主版本保持一致。
  /// 当 package_info_plus 与 Windows EXE 均读取失败时，至少保证 UI 能显示版本。
  static const String _fallbackVersion = '1.2.0';

  static String _version = '';
  static String _rawVersion = '';
  static String _platform = '';
  static String _userAgent = '';

  /// 应用版本号（例如 1.1.6），读取失败时返回兜底版本号。
  static String get version => _version.isEmpty ? _fallbackVersion : _version;

  /// 原始版本名（可能包含 flavor 后缀，例如 "1.1.6-tvlegacy"）。
  static String get rawVersion => _rawVersion.isEmpty ? _fallbackVersion : _rawVersion;

  /// 当前平台标识，用于更新检测匹配对应 APK：
  /// - windows
  /// - tvLegacy（versionName 包含 -tvlegacy）
  /// - mobile（versionName 包含 -mobile）
  /// - tv（默认）
  static String get platform {
    if (_platform.isNotEmpty) return _platform;
    if (Platform.isWindows) return 'windows';
    return 'tv';
  }

  /// 用于 HTTP 请求的 User-Agent。
  static String get userAgent => _userAgent.isEmpty ? 'HainTV/$_fallbackVersion Flutter' : _userAgent;

  /// 在应用启动时初始化，仅首次调用会真正读取平台信息。
  /// 版本号会规范化为 major.minor.patch 格式，去掉 package_info_plus
  /// 可能附带的 +buildNumber 后缀以及 Windows EXE 的第四版本号。
  static Future<void> init() async {
    if (_version.isNotEmpty) return;
    try {
      String? rawVersion;
      if (Platform.isWindows) {
        rawVersion = await _readWindowsExeVersion();
        debugPrint('AppInfoService: Windows EXE 版本=$rawVersion');
      }
      if (rawVersion == null || rawVersion.isEmpty) {
        final info = await PackageInfo.fromPlatform();
        rawVersion = info.version;
        debugPrint(
          'AppInfoService: PackageInfo version=${info.version}, buildNumber=${info.buildNumber}',
        );
      }
      _rawVersion = rawVersion;
      _version = _normalizeVersion(_rawVersion);
      if (_version.isEmpty) {
        _version = _fallbackVersion;
        debugPrint('AppInfoService: 所有读取方式均失败，使用兜底版本=$_version');
      }
      _platform = _resolvePlatform(_rawVersion);
      _userAgent = 'HainTV/$_version Flutter';
      debugPrint('AppInfoService: 最终版本=$_version, platform=$_platform');
    } catch (e) {
      debugPrint('AppInfoService 初始化失败: $e');
      _version = _fallbackVersion;
      _platform = Platform.isWindows ? 'windows' : 'tv';
      _userAgent = 'HainTV/$_version Flutter';
    }
  }

  /// 根据原始版本名后缀解析平台标识。
  static String _resolvePlatform(String rawVersion) {
    if (Platform.isWindows) return 'windows';
    final lower = rawVersion.toLowerCase();
    if (lower.contains('-tvlegacy')) return 'tvLegacy';
    if (lower.contains('-mobile')) return 'mobile';
    return 'tv';
  }

  /// 规范化版本号为 major.minor.patch：
  /// - 去掉 +buildNumber 后缀，例如 "1.1.6+11" -> "1.1.6"。
  /// - 去掉 Windows EXE 常见的第四版本号，例如 "1.1.6.11" -> "1.1.6"。
  /// - 去掉 Android flavor 后缀，例如 "1.1.6-tv" / "1.1.6-mobile" -> "1.1.6"。
  /// - 不足 3 段补 0，例如 "1.1" -> "1.1.0"。
  static String _normalizeVersion(String version) {
    if (version.isEmpty) return '';
    final withoutBuild = version.split('+')[0];
    // 仅保留开头的数字和点，去掉 -tv/-mobile 等 flavor 后缀。
    final clean = withoutBuild.replaceFirst(RegExp(r'[^\d.].*$'), '');
    final parts = clean.split('.');
    final normalized = <int>[];
    for (int i = 0; i < 3; i++) {
      normalized.add(i < parts.length ? int.tryParse(parts[i]) ?? 0 : 0);
    }
    return normalized.join('.');
  }

  /// 通过 Win32 API 读取当前 Windows 可执行文件的版本信息。
  /// 优先从 StringFileInfo 的 FileVersion 字段取值。
  static Future<String?> _readWindowsExeVersion() async {
    try {
      final exePath = Platform.resolvedExecutable;
      final pPath = exePath.toPcwstr(allocator: calloc);

      final handle = calloc<Uint32>();
      final sizeResult = GetFileVersionInfoSize(pPath, handle);
      final size = sizeResult.value;
      if (size == 0) {
        free(pPath);
        free(handle);
        return null;
      }

      final data = calloc<Uint8>(size);
      final infoResult = GetFileVersionInfo(pPath, size, data);
      free(pPath);
      free(handle);

      if (!infoResult.value) {
        free(data);
        return null;
      }

      final pBuffer = calloc<Pointer>();
      final pLen = calloc<Uint32>();

      final translationQuery = r'\VarFileInfo\Translation'.toPcwstr(
        allocator: calloc,
      );
      if (!VerQueryValue(data, translationQuery, pBuffer, pLen)) {
        free(translationQuery);
        free(pBuffer);
        free(pLen);
        free(data);
        return null;
      }
      free(translationQuery);

      final translation = pBuffer.value.cast<Uint16>();
      final lang = translation[0].toRadixString(16).padLeft(4, '0');
      final codepage = translation[1].toRadixString(16).padLeft(4, '0');

      final fileVersionQuery =
          '\\StringFileInfo\\$lang$codepage\\FileVersion'.toPcwstr(
            allocator: calloc,
          );
      if (!VerQueryValue(data, fileVersionQuery, pBuffer, pLen)) {
        free(fileVersionQuery);
        free(pBuffer);
        free(pLen);
        free(data);
        return null;
      }
      free(fileVersionQuery);

      final versionPtr = pBuffer.value.cast<Utf16>();
      final version = versionPtr.toDartString();

      free(pBuffer);
      free(pLen);
      free(data);

      return version;
    } catch (e) {
      debugPrint('AppInfoService: 读取 Windows EXE 版本失败: $e');
      return null;
    }
  }
}
