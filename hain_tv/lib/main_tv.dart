import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:hain_tv/app_tv.dart';
import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/storage_service.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  // 异步请求存储权限（不阻塞启动）
  StorageService.requestStoragePermission().catchError((_) => false);
  // 异步加载 Bangumi 代理设置到内存缓存，便于后续图片代理同步使用
  BangumiService.loadProxySettings().catchError((_) {});
  runApp(const HainTvApp());
}
