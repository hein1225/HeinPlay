import 'package:flutter/material.dart';
import 'package:flutter_mpv/flutter_mpv.dart';
import 'package:hain_tv/app_tv.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/storage_service.dart';
import 'package:hain_tv/services/user_data_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  FlutterMpv.ensureInitialized();
  // 每次 App 启动后重置首页首次进入标记，确保用云端数据覆盖本地旧缓存。
  await UserDataService.resetHomeFirstEntryCompleted();
  // 异步请求存储权限（不阻塞启动）
  StorageService.requestStoragePermission().catchError((_) => false);
  // 异步加载 Bangumi 代理设置到内存缓存，便于后续图片代理同步使用
  BangumiService.loadProxySettings().catchError((_) {});
  runApp(const HainTvApp());
}
