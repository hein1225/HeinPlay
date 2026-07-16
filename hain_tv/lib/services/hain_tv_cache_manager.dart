import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 海因影视自定义图片缓存管理器
/// - 缓存有效期：90 天
/// - 最大缓存对象数：2000 张海报
class HainTvCacheManager extends CacheManager {
  static const key = 'hainTvCache';
  static HainTvCacheManager? _instance;

  factory HainTvCacheManager() {
    return _instance ??= HainTvCacheManager._();
  }

  HainTvCacheManager._()
    : super(
        Config(
          key,
          stalePeriod: const Duration(days: 90),
          maxNrOfCacheObjects: 2000,
        ),
      );
}
