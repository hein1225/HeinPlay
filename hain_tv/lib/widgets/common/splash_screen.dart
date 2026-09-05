import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../services/app_bootstrap.dart';
import '../../services/app_info_service.dart';
import '../../utils/app_logger.dart';
import '../../services/bangumi_service.dart';
import '../../services/home_data_preload.dart';
import '../../services/server_latency_service.dart';
import '../../services/user_data_service.dart';
import '../../services/version_migration_service.dart';
import '../../theme.dart';

/// 应用启动目标平台。
enum SplashTarget {
  /// TV / tvLegacy。
  tv,

  /// Windows 桌面版。
  windows,

  /// Linux 桌面版。
  linux,

  /// 手机版（竖屏与横屏平板）。
  mobile,
}

/// 载入页封面资源路径。
///
/// 按平台与方向返回正确的封面 asset：手机竖屏使用 [splash_mobile]，其余使用
/// [splash_tv]。这样封面与方向严格对应，不会出现“竖屏封面 → 横屏封面”的错乱；
/// 调用方用 [Image.asset] 异步解码并淡入，无需在 [runApp] 前阻塞预解码。
class SplashCover {
  static const _tvAsset = 'assets/images/splash/splash_tv.jpeg';
  static const _mobileAsset = 'assets/images/splash/splash_mobile.jpeg';

  /// 按目标平台与方向返回对应的封面 asset 路径。
  static String assetFor(SplashTarget target, Orientation orientation) {
    if (target == SplashTarget.mobile && orientation == Orientation.portrait) {
      return _mobileAsset;
    }
    return _tvAsset;
  }
}

/// 海因影视全平台统一载入页。
///
/// 根据 [target] 与屏幕方向选择背景：
/// - TV / Windows / 手机横屏 → TV 风格背景 + 水平进度条。
/// - 手机竖屏 → 手机风格背景 + 竖直胶囊进度。
///
/// 进度条覆盖软件初始化（应用信息、日志、版本迁移、账号迁移、服务器测速、
/// 首页数据预加载、Bangumi 代理等）与登录状态判定；完成后自动进入首页或登录页。
class SplashScreen extends StatefulWidget {
  final SplashTarget target;

  const SplashScreen({super.key, required this.target});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with SingleTickerProviderStateMixin {
  /// 是否已释放。主题切换等 MaterialApp 重建时本页 build 会重跑，但 initState
  /// 不会重跑；此处仅作为防御，避免异步初始化在释放后触碰已 dispose 的控制器。
  bool _disposed = false;

  /// 是否已通知原生启动封面收起（仅 Android 使用）。
  bool _coverNotified = false;

  late AnimationController _progressController;
  double _targetProgress = 0.0;
  double _currentProgress = 0.0;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _progressController.addListener(() {
      setState(() {
        _currentProgress =
            _currentProgress +
            (_targetProgress - _currentProgress) * _progressController.value;
      });
    });
    // 载入封面由 Flutter 在 build 中用 Image.asset 按方向直接绘制（assets 内打包的
    // 封面图），不再依赖原生窗口透明；封面异步解码后以 frameBuilder 淡入，与进度条同
    // 帧出现、无硬切闪烁。这里只驱动真实进度。
    _initializeApp();
  }

  @override
  void dispose() {
    _disposed = true;
    _progressController.dispose();
    super.dispose();
  }

  void _setProgress(double value) {
    if (_disposed) return;
    _targetProgress = value.clamp(0.0, 1.0);
    _progressController.forward(from: 0.0);
  }

  /// 通知原生启动封面（Android）封面已就绪、可以移除。
  /// 仅 Android 调用；其它平台（Windows 等）无原生启动封面，直接忽略。
  void _notifyCoverReady() {
    if (_coverNotified) return;
    _coverNotified = true;
    if (!Platform.isAndroid) return;
    try {
      const MethodChannel('hain_tv/splash').invokeMethod<void>('coverReady');
    } catch (e) {
      debugPrint('通知封面就绪失败: $e');
    }
  }

  Future<void> _initializeApp() async {
    try {
      // 1. 应用信息 / 平台 / 版本。
      await AppInfoService.init();
      _setProgress(0.12);

      // 2. 文件日志初始化。
      await AppLogger.initialize();
      _setProgress(0.24);

      // 3. 版本迁移与缓存清理。
      await VersionMigrationService.migrate();
      _setProgress(0.40);

      // 4. 旧账号模型迁移。
      await UserDataService.migrateLegacyAccount();
      _setProgress(0.52);

      // 5. 服务器测速 / 连接确认（如果用户开启自动选优）。
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
      _setProgress(0.60);

      // 6. 重置首页首次进入标记，使本次启动视为“首次进入”并触发服务器同步。
      await UserDataService.resetHomeFirstEntryCompleted();
      _setProgress(0.70);

      // 7. 预加载首页数据（豆瓣热门、继续观看、首次进入时同步服务器记录/收藏），
      //    让进入首页时直接展示内容，不再出现单独加载圈。
      //    双保险超时：preload 内部已对同步/拉取各加 ~10s 硬超时，这里再兜底一层，
      //    确保任何极端情况下 SplashScreen 都不会因首页数据而卡死、进不了首页。
      await HomeDataPreload.preload()
          .timeout(const Duration(seconds: 15), onTimeout: () => false);
      _setProgress(0.90);

      // 8. Bangumi 代理设置加载。
      await BangumiService.loadProxySettings().catchError((_) {});
      _setProgress(0.96);

      // 9. 登录状态判定。
      final loggedIn = await UserDataService.isLoggedIn();
      _setProgress(1.0);

      // 等待进度条动画到达 1.0，给用户“已加载完成”的视觉反馈。
      await Future.delayed(const Duration(milliseconds: 300));

      if (!mounted) return;

      final route = loggedIn ? '/home' : '/login';

      // 标记引导完成并记录跳转目标：运行期切主题重建 Navigator 时，初始路由据此
      // 直接落到 /home 或 /login，而不会重新显示载入页、也不会重复初始化。
      AppBootstrap.markCompleted(route);

      Navigator.of(context).pushReplacementNamed(route);
    } catch (e, s) {
      debugPrint('载入页初始化失败: $e\n$s');
      if (mounted) {
        setState(() {
          _errorMessage = '初始化失败：$e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    // TV / Windows 默认沉浸全屏。
    if (widget.target != SplashTarget.mobile) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }

    final orientation = MediaQuery.of(context).orientation;
    final isLandscape =
        widget.target != SplashTarget.mobile || orientation == Orientation.landscape;

    // 封面由 Flutter 直接绘制（不透明 FlutterView 会盖住原生启动图，封面必须自绘）。
    // 用 Image.asset 按方向选取正确资源，配合 gaplessPlayback + frameBuilder 淡入，
    // 避免出现“黑底加载条 → 封面”的硬切闪烁；解码完成前下方深色背景作为兜底，不露黑底。
    final coverAsset = SplashCover.assetFor(widget.target, orientation);
    final coverWidget = Image.asset(
      coverAsset,
      fit: BoxFit.cover,
      alignment: Alignment.center,
      gaplessPlayback: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        // 封面解码出首帧后，等 250ms 淡入动画完成再通知原生启动封面移除（仅 Android
        // 生效），避免原生 ImageView 刚消失时 Flutter 封面还处于透明状态而露黑底。
        if (frame != null) {
          Future.delayed(const Duration(milliseconds: 250), _notifyCoverReady);
        }
        if (wasSynchronouslyLoaded) return child;
        return AnimatedOpacity(
          opacity: frame == null ? 0.0 : 1.0,
          duration: const Duration(milliseconds: 250),
          child: child,
        );
      },
    );

    // 背景固定深色（与封面底色、原生启动图 #0A0A0F 一致），不用主题相关的
    // AppColors.bgApp：否则明亮主题下会露出浅色底，出现白闪。
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        fit: StackFit.expand,
        children: [
          coverWidget,
          // 底部微渐变，保证进度条与文字在封面上清晰可读（半透明，不遮挡封面主体）。
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: isLandscape ? 200 : 300,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.0),
                    Colors.black.withValues(alpha: 0.40),
                    Colors.black.withValues(alpha: 0.80),
                  ],
                  stops: const [0.0, 0.45, 1.0],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: EdgeInsets.only(
                  left: isLandscape ? 80 : 48,
                  right: isLandscape ? 80 : 48,
                  bottom: isLandscape ? 56 : 100,
                ),
                child: isLandscape
                    ? _buildLandscapeProgress()
                    : _buildPortraitProgress(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLandscapeProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 启动载入只用进度条，不放加载圈（加载圈仅用于页面内数据加载场景）。
        _buildHorizontalProgressBar(_currentProgress),
        const SizedBox(height: 16),
        Text(
          _errorMessage ?? '正在进入精彩视界',
          style: TextStyle(
            fontSize: 16,
            color: AppColors.loading,
            shadows: [
              Shadow(
                color: AppColors.loading.withValues(alpha: 0.6),
                blurRadius: 8,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildPortraitProgress() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 启动载入只用进度条，不放加载圈（加载圈仅用于页面内数据加载场景）。
        _buildVerticalProgressCapsule(_currentProgress),
        const SizedBox(height: 20),
        Text(
          _errorMessage ?? '正在进入精彩视界',
          style: TextStyle(
            fontSize: 14,
            color: AppColors.loading,
            shadows: [
              Shadow(
                color: AppColors.loading.withValues(alpha: 0.6),
                blurRadius: 8,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildHorizontalProgressBar(double progress) {
    const barHeight = 6.0;
    const barWidth = 360.0;
    return SizedBox(
      width: barWidth,
      height: barHeight + 8,
      child: Stack(
        alignment: Alignment.centerLeft,
        children: [
          // 轨道。
          Container(
            width: barWidth,
            height: barHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(barHeight / 2),
              color: Colors.black.withValues(alpha: 0.5),
              border: Border.all(
                color: AppColors.loading.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
          ),
          // 填充。
          Container(
            width: barWidth * progress,
            height: barHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(barHeight / 2),
              gradient: LinearGradient(
                colors: [
                  AppColors.primary.withValues(alpha: 0.8),
                  AppColors.loading,
                ],
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.loading.withValues(alpha: 0.6),
                  blurRadius: 8,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          // 头部光点。
          Positioned(
            left: barWidth * progress - barHeight / 2,
            child: AnimatedOpacity(
              opacity: progress > 0.01 ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 100),
              child: Container(
                width: barHeight,
                height: barHeight,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.white,
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.loading.withValues(alpha: 0.9),
                      blurRadius: 10,
                      spreadRadius: 2,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildVerticalProgressCapsule(double progress) {
    const capsuleWidth = 24.0;
    const capsuleHeight = 80.0;
    return SizedBox(
      width: capsuleWidth + 12,
      height: capsuleHeight + 12,
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          // 外框。
          Container(
            width: capsuleWidth,
            height: capsuleHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(capsuleWidth / 2),
              color: Colors.black.withValues(alpha: 0.4),
              border: Border.all(
                color: AppColors.loading.withValues(alpha: 0.4),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: AppColors.loading.withValues(alpha: 0.3),
                  blurRadius: 10,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
          // 填充。
          Container(
            width: capsuleWidth - 4,
            height: capsuleHeight * progress,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(capsuleWidth / 2),
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [AppColors.loading, AppColors.primary],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
