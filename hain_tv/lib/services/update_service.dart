import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/update_info.dart';
import '../widgets/update_dialog.dart';
import 'permission_service.dart';
import 'user_data_service.dart';

enum UpdateChannel {
  domestic,
  github,
}

class UpdateService {
  static const String _domesticReleasesUrl =
      'https://gitcode.com/api/v5/repos/gcw_QbmhmbO8/HeinPlay/releases/latest';
  static const String _githubReleasesUrl =
      'https://api.github.com/repos/hein1225/HeinPlay/releases/latest';
  static const String currentVersion = '1.1.2';

  static String _channelName(UpdateChannel channel) {
    switch (channel) {
      case UpdateChannel.domestic:
        return '国内渠道';
      case UpdateChannel.github:
        return 'GitHub 渠道';
    }
  }

  static Future<UpdateInfo?> checkUpdate({
    UpdateChannel channel = UpdateChannel.domestic,
  }) async {
    final url = channel == UpdateChannel.domestic
        ? _domesticReleasesUrl
        : _githubReleasesUrl;
    debugPrint(
        'UpdateService: 开始检查更新，当前版本 $currentVersion，渠道 ${_channelName(channel)}，URL $url');

    final response = await http
        .get(
          Uri.parse(url),
          headers: {
            'Accept': 'application/json',
            'User-Agent': 'HeinPlay-App',
          },
        )
        .timeout(const Duration(seconds: 10));

    debugPrint(
        'UpdateService: ${_channelName(channel)} API 状态码 ${response.statusCode}');
    if (response.statusCode != 200) {
      throw Exception(
          '${_channelName(channel)} API 返回 ${response.statusCode}: ${response.body}');
    }

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final tag = (json['tag_name'] as String? ?? '').trim();
    final latestVersion = tag.toLowerCase().startsWith('v')
        ? tag.substring(1)
        : tag;
    debugPrint('UpdateService: tag=$tag, latestVersion=$latestVersion');

    if (latestVersion.isEmpty) {
      debugPrint('UpdateService: tag 为空，放弃');
      return null;
    }

    final newer = _isNewer(latestVersion, currentVersion);
    debugPrint(
        'UpdateService: latest=$latestVersion, current=$currentVersion, newer=$newer');
    if (!newer) return null;

    String? apkUrl;
    final assets = json['assets'] as List<dynamic>? ?? [];
    debugPrint('UpdateService: assets 数量 ${assets.length}');
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = (asset['name'] as String? ?? '').toLowerCase();
      final url = asset['browser_download_url'] as String?;
      debugPrint('UpdateService: asset=$name, url=$url');
      // TV 版只下载以 tv.apk 结尾的包，避免与手机版、Windows 版混淆
      if (name.endsWith('tv.apk') && url != null && url.isNotEmpty) {
        apkUrl = url;
        break;
      }
    }
    debugPrint('UpdateService: apkUrl=$apkUrl');

    return UpdateInfo(
      version: latestVersion,
      tagName: tag,
      title: json['name'] as String? ?? tag,
      body: json['body'] as String? ?? '',
      htmlUrl: json['html_url'] as String? ??
          'https://github.com/hein1225/HeinPlay/releases',
      apkUrl: apkUrl,
    );
  }

  static bool _isNewer(String latest, String current) {
    final l = latest
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();
    final c = current
        .split('.')
        .map((e) => int.tryParse(e) ?? 0)
        .toList();

    final length = l.length > c.length ? l.length : c.length;
    for (int i = 0; i < length; i++) {
      final lv = i < l.length ? l[i] : 0;
      final cv = i < c.length ? c[i] : 0;
      if (lv > cv) return true;
      if (lv < cv) return false;
    }
    return false;
  }

  static Future<void> openDownloadUrl(UpdateInfo info) async {
    final url = info.apkUrl ?? info.htmlUrl;
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
      );
    }
  }

  /// 下载并安装 APK。
  /// 先请求安装未知应用权限，下载完成后调用系统安装器。
  /// [onProgress] 返回 0.0~1.0 的下载进度。
  static Future<bool> downloadAndInstallApk(
    BuildContext context,
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    if (info.apkUrl == null || info.apkUrl!.isEmpty) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('未找到 APK 下载地址')),
        );
      }
      return false;
    }

    // 1. 请求安装未知应用权限
    if (!await PermissionService.canInstallPackages()) {
      final granted = await PermissionService.requestInstallPackagesPermission();
      if (!granted) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('需要开启“允许安装未知应用”权限才能更新')),
          );
        }
        return false;
      }
    }

    // 2. 下载 APK
    final dir = await getTemporaryDirectory();
    final fileName = 'hain_tv_update_${info.version}.apk';
    final savePath = '${dir.path}/$fileName';

    final dio = Dio();
    try {
      await dio.download(
        info.apkUrl!,
        savePath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress?.call(received / total);
          }
        },
      );
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
      return false;
    }

    // 3. 安装 APK
    if (!File(savePath).existsSync()) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('APK 文件不存在')),
        );
      }
      return false;
    }

    final result = await OpenFilex.open(
      savePath,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type == ResultType.done || result.type == ResultType.noAppToOpen) {
      return true;
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开安装器失败: ${result.message}')),
        );
      }
      return false;
    }
  }

  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool silent = false,
    bool force = false,
    UpdateChannel channel = UpdateChannel.domestic,
  }) async {
    // 非手动检查且 24 小时内已检查过，则跳过，避免每次启动都请求网络
    if (!force) {
      final lastCheck = await UserDataService.getLastUpdateCheckTime();
      if (lastCheck != null &&
          DateTime.now().difference(lastCheck) < const Duration(hours: 24)) {
        debugPrint(
          'UpdateService: 距离上次检查更新不足 24 小时，跳过自动检查',
        );
        return;
      }
    }

    UpdateInfo? info;
    try {
      info = await checkUpdate(channel: channel);
    } catch (e) {
      debugPrint('UpdateService: 检查更新失败: $e');
      if (!silent && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('检查更新失败: $e')),
        );
      }
      // 失败时也记录时间，避免网络异常时频繁重试
      await UserDataService.saveLastUpdateCheckTime(DateTime.now());
      return;
    }
    if (!context.mounted) return;

    // 检查已成功完成，记录本次检查时间
    await UserDataService.saveLastUpdateCheckTime(DateTime.now());

    if (info == null) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('当前已是最新版本')),
        );
      }
      return;
    }

    final skipped = await UserDataService.getSkippedVersion();
    if (skipped == info.version) {
      if (!silent) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已跳过版本 ${info.version}')),
        );
      }
      return;
    }

    await showUpdateDialog(
      context,
      info,
      onDownload: (onProgress) => downloadAndInstallApk(
        context,
        info!,
        onProgress: onProgress,
      ),
    );
  }
}
