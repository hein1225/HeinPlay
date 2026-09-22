import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// 海因影视自定义图片缓存管理器。
///
/// - 缓存有效期：**7 天**（未被使用即淘汰），与便携目录内其余可再生成数据
///   （派生缓存条目、日志）保持同一滚动口径。
/// - 最大缓存对象数：2000 张海报。
///
/// 目录：Windows 便携版把 `getTemporaryDirectory()` 映射到 `data/cache`，
/// 于是海报文件落在 `data/cache/hainTvCache/`，与派生缓存条目
/// （`data/cache/entries/`）一起构成一个可以整目录删除的缓存区，且不含任何
/// 用户数据。其他平台沿用系统默认缓存目录。
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
          stalePeriod: const Duration(days: 7),
          maxNrOfCacheObjects: 2000,
        ),
      );
}
