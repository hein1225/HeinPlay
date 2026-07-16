import 'dart:convert';
import 'dart:io';
import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:open_filex/open_filex.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import '../models/update_info.dart';
import 'package:hain_tv/widgets/tv/update_dialog.dart';
import 'permission_service.dart';
import 'user_data_service.dart';

enum UpdateChannel { domestic, github }

class UpdateService {
  static const String _domesticReleasesUrl =
      'https://gitcode.com/api/v5/repos/gcw_QbmhmbO8/HeinPlay/releases/latest';
  static const String _githubReleasesUrl =
      'https://api.github.com/repos/hein1225/HeinPlay/releases/latest';
  static const String currentVersion = '1.1.4';

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
    String platform = 'tv',
  }) async {
    final url = channel == UpdateChannel.domestic
        ? _domesticReleasesUrl
        : _githubReleasesUrl;
    debugPrint(
      'UpdateService: 开始检查更新，当前版本 $currentVersion，平台 $platform，渠道 ${_channelName(channel)}，URL $url',
    );

    final response = await http
        .get(
          Uri.parse(url),
          headers: {'Accept': 'application/json', 'User-Agent': 'HeinPlay-App'},
        )
        .timeout(const Duration(seconds: 10));

    debugPrint(
      'UpdateService: ${_channelName(channel)} API 状态码 ${response.statusCode}',
    );
    if (response.statusCode != 200) {
      throw Exception(
        '${_channelName(channel)} API 返回 ${response.statusCode}: ${response.body}',
      );
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
      'UpdateService: latest=$latestVersion, current=$currentVersion, newer=$newer',
    );
    if (!newer) return null;

    String? downloadUrl;
    final assets = json['assets'] as List<dynamic>? ?? [];
    debugPrint('UpdateService: assets 数量 ${assets.length}');
    for (final asset in assets) {
      if (asset is! Map<String, dynamic>) continue;
      final name = (asset['name'] as String? ?? '').toLowerCase();
      final url = asset['browser_download_url'] as String?;
      debugPrint('UpdateService: asset=$name, url=$url');
      // Windows 版优先匹配便携版 zip，其次回退到 .exe / .msix
      if (platform.toLowerCase() == 'windows') {
        if (name.endsWith('windows-portable.zip') &&
            url != null &&
            url.isNotEmpty) {
          downloadUrl = url;
          break;
        }
      } else {
        // 根据平台下载对应 APK：tv 版匹配 tv.apk，手机版匹配 mobile.apk
        if (name.endsWith('${platform.toLowerCase()}.apk') &&
            url != null &&
            url.isNotEmpty) {
          downloadUrl = url;
          break;
        }
      }
    }
    // Windows 未找到 zip 时回退到 .exe / .msix（此时走浏览器下载，不支持自动替换）
    if (platform.toLowerCase() == 'windows' && downloadUrl == null) {
      for (final asset in assets) {
        if (asset is! Map<String, dynamic>) continue;
        final name = (asset['name'] as String? ?? '').toLowerCase();
        final url = asset['browser_download_url'] as String?;
        if ((name.endsWith('.exe') || name.endsWith('.msix')) &&
            url != null &&
            url.isNotEmpty) {
          downloadUrl = url;
          break;
        }
      }
    }

    debugPrint('UpdateService: downloadUrl=$downloadUrl');

    return UpdateInfo(
      version: latestVersion,
      tagName: tag,
      title: json['name'] as String? ?? tag,
      body: json['body'] as String? ?? '',
      htmlUrl:
          json['html_url'] as String? ??
          'https://github.com/hein1225/HeinPlay/releases',
      apkUrl: downloadUrl,
    );
  }

  static bool _isNewer(String latest, String current) {
    final l = latest.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final c = current.split('.').map((e) => int.tryParse(e) ?? 0).toList();

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
      await launchUrl(uri, mode: LaunchMode.externalApplication);
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('未找到 APK 下载地址')));
      }
      return false;
    }

    // 1. 请求安装未知应用权限
    if (!await PermissionService.canInstallPackages()) {
      final granted =
          await PermissionService.requestInstallPackagesPermission();
      if (!granted) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('需要开启“允许安装未知应用”权限才能更新')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('下载失败: $e')));
      }
      return false;
    }

    // 3. 安装 APK
    if (!File(savePath).existsSync()) {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('APK 文件不存在')));
      }
      return false;
    }

    final result = await OpenFilex.open(
      savePath,
      type: 'application/vnd.android.package-archive',
    );
    if (result.type == ResultType.done ||
        result.type == ResultType.noAppToOpen) {
      return true;
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('打开安装器失败: ${result.message}')));
      }
      return false;
    }
  }

  /// Windows 便携版自动更新脚本。
  /// 等待主进程退出后解压 zip 并替换应用目录内文件，保留 data 目录。
  static const String _windowsUpdaterScript = r'''
param(
    [Parameter(Mandatory=$true)]
    [int]$ParentPid,
    [Parameter(Mandatory=$true)]
    [string]$AppDir,
    [Parameter(Mandatory=$true)]
    [string]$ExeName
)

$ErrorActionPreference = 'Stop'

# 等待主进程退出
while ($true) {
    $parent = Get-Process -Id $ParentPid -ErrorAction SilentlyContinue
    if (-not $parent) { break }
    Start-Sleep -Milliseconds 500
}

$updateDir = Join-Path $AppDir 'update'
$extractedDir = Join-Path $updateDir 'extracted'
$zipPath = Join-Path $updateDir 'download.zip'

try {
    if (-not (Test-Path $zipPath)) {
        throw "未找到更新包: $zipPath"
    }

    if (Test-Path $extractedDir) {
        Remove-Item -Recurse -Force $extractedDir
    }
    Expand-Archive -Path $zipPath -DestinationPath $extractedDir -Force

    # 如果压缩包内只有一个文件夹且根目录没有文件，则视为外层包装目录
    $newRoot = $extractedDir
    $files = Get-ChildItem $extractedDir -File
    $dirs = Get-ChildItem $extractedDir -Directory
    if ($files.Count -eq 0 -and $dirs.Count -eq 1) {
        $newRoot = $dirs[0].FullName
    }

    # 复制新文件到应用目录，保留 data 与 update 目录
    $exclude = @('data', 'update')
    Get-ChildItem $newRoot | Where-Object { $exclude -notcontains $_.Name } | ForEach-Object {
        $dest = Join-Path $AppDir $_.Name
        if (Test-Path $dest) {
            Remove-Item -Recurse -Force $dest
        }
        Copy-Item -Path $_.FullName -Destination $dest -Recurse -Force
    }
} finally {
    if (Test-Path $updateDir) {
        Remove-Item -Recurse -Force $updateDir -ErrorAction SilentlyContinue
    }
}

# 重启应用
$exePath = Join-Path $AppDir $ExeName
if (Test-Path $exePath) {
    Start-Process -FilePath $exePath -WorkingDirectory $AppDir
}
''';

  /// Windows 便携版自动更新。
  ///
  /// 下载新版 zip，生成 PowerShell 更新脚本，启动脚本后退出当前应用，
  /// 由脚本完成文件替换并自动重启。
  static Future<void> downloadAndUpdateWindows(
    UpdateInfo info, {
    required void Function(double progress) onProgress,
  }) async {
    final downloadUrl = info.apkUrl;
    if (downloadUrl == null || downloadUrl.isEmpty) {
      throw Exception('未找到 Windows 更新包下载地址');
    }

    final exeFile = File(Platform.resolvedExecutable);
    final appDir = exeFile.parent.path;
    final updateDir = Directory(p.join(appDir, 'update'));

    if (await updateDir.exists()) {
      await updateDir.delete(recursive: true);
    }
    await updateDir.create(recursive: true);

    final zipPath = p.join(updateDir.path, 'download.zip');
    final scriptPath = p.join(updateDir.path, 'update.ps1');

    final dio = Dio();
    try {
      await dio.download(
        downloadUrl,
        zipPath,
        onReceiveProgress: (received, total) {
          if (total > 0) {
            onProgress(received / total);
          }
        },
      );
    } catch (e) {
      throw Exception('下载更新包失败: $e');
    }

    await File(scriptPath).writeAsString(_windowsUpdaterScript);

    final exeName = p.basename(Platform.resolvedExecutable);
    await Process.start(
      'powershell.exe',
      [
        '-ExecutionPolicy',
        'Bypass',
        '-WindowStyle',
        'Hidden',
        '-File',
        scriptPath,
        '-ParentPid',
        pid.toString(),
        '-AppDir',
        appDir,
        '-ExeName',
        exeName,
      ],
      workingDirectory: appDir,
    );

    // 等待 PowerShell 启动后退出当前应用，让脚本接管更新。
    await Future.delayed(const Duration(seconds: 1));
    exit(0);
  }

  static Future<void> checkAndPrompt(
    BuildContext context, {
    bool silent = false,
    bool force = false,
    UpdateChannel channel = UpdateChannel.domestic,
    String platform = 'tv',
  }) async {
    // 非手动检查且 24 小时内已检查过，则跳过，避免每次启动都请求网络
    if (!force) {
      final lastCheck = await UserDataService.getLastUpdateCheckTime();
      if (lastCheck != null &&
          DateTime.now().difference(lastCheck) < const Duration(hours: 24)) {
        debugPrint('UpdateService: 距离上次检查更新不足 24 小时，跳过自动检查');
        return;
      }
    }

    UpdateInfo? info;
    try {
      info = await checkUpdate(channel: channel, platform: platform);
    } catch (e) {
      debugPrint('UpdateService: 检查更新失败: $e');
      if (!silent && context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('检查更新失败: $e')));
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('当前已是最新版本')));
      }
      return;
    }

    final skipped = await UserDataService.getSkippedVersion();
    if (skipped == info.version) {
      if (!silent) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('已跳过版本 ${info.version}')));
      }
      return;
    }

    if (platform.toLowerCase() == 'windows') {
      await showUpdateDialog(
        context,
        info,
        onDownload: (onProgress) =>
            downloadAndUpdateWindows(info!, onProgress: onProgress),
      );
      return;
    }

    await showUpdateDialog(
      context,
      info,
      onDownload: (onProgress) =>
          downloadAndInstallApk(context, info!, onProgress: onProgress),
    );
  }
}
