import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'services/storage_service.dart';

void main() {
  MediaKit.ensureInitialized();
  // 异步请求存储权限（不阻塞启动）
  StorageService.requestStoragePermission();
  runApp(const HainTvApp());
}
