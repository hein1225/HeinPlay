import 'package:flutter/material.dart';
import 'package:hain_tv/app_tv.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/server_latency_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/services/version_migration_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // TV 版显式标记为 TV 模式，确保焦点、遥控及二维码输入逻辑正确生效。
  DeviceUtils.isTvOverride = true;
  // 缓存应用版本与平台信息，供更新检测与设置页读取。
  await AppInfoService.init();
  // 版本升级时自动清理旧缓存（保留用户数据），首次安装仅记录版本号。
  await VersionMigrationService.migrate();
  // v1.2.0：将旧版 username/password/cookies 迁移到主/子账号模型。
  await UserDataService.migrateLegacyAccount();
  // v1.2.0：若开启自动测速，对主/备服务器进行延迟探测并保存最优地址。
  final autoSelectLowLatency =
      await UserDataService.getAutoSelectLowLatencyServer();
  if (autoSelectLowLatency) {
    final primary = await UserDataService.getServerUrl() ?? '';
    final backup = await UserDataService.getBackupServerUrl();
    final serverUrl = primary.isNotEmpty ? primary : backup;
    if (serverUrl.isNotEmpty) {
      try {
        await ServerLatencyService.selectBestServer(
          serverUrl,
          primary.isNotEmpty ? backup : null,
        );
      } catch (e) {
        debugPrint('启动时服务器测速失败: $e');
      }
    }
  }
  // 每次 App 启动后重置首页首次进入标记，确保用云端数据覆盖本地旧缓存。
  await UserDataService.resetHomeFirstEntryCompleted();
  // 异步加载 Bangumi 代理设置到内存缓存，便于后续图片代理同步使用
  BangumiService.loadProxySettings().catchError((_) {});
  runApp(const HainTvApp());
}
