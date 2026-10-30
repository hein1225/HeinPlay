import 'package:flutter/material.dart';

import 'package:hain_tv/services/glass_style_service.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/screens/tv/settings/settings_helpers.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  late ThemeModePref _pref;
  late bool _followSystem;
  late GlassLevel _glassLevel;

  /// 磨砂玻璃仅 **Android 手机版** 提供（MobileShell / MobileCategoryScreen 接入）。
  /// TV / 桌面版以实体按键/鼠标操作为主，毛玻璃的沉浸收益有限而 Blur 开销实在，
  /// 故整块 UI 对它们隐藏。
  bool get _showGlassSettings => DeviceUtils.isMobile;

  @override
  void initState() {
    super.initState();
    _syncFromService();
    ThemeModeService.instance.addListener(_onServiceChanged);
    GlassStyleService.instance.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    ThemeModeService.instance.removeListener(_onServiceChanged);
    GlassStyleService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _syncFromService() {
    _pref = ThemeModeService.instance.pref;
    _followSystem = ThemeModeService.instance.followSystem;
    _glassLevel = GlassStyleService.instance.level;
  }

  void _onServiceChanged() {
    if (mounted) {
      setState(_syncFromService);
    }
  }

  ThemeModePref get _explicitPref =>
      _pref == ThemeModePref.light ? ThemeModePref.light : ThemeModePref.dark;

  Future<void> _selectExplicit(ThemeModePref pref) async {
    await ThemeModeService.instance.setPref(pref);
    // 切换主题后重启应用，使新主题彻底生效、无残留浅色（原生启动封面在重启时显示）。
    _restartApp();
  }

  Future<void> _setFollowSystem(bool value) async {
    final next = value ? ThemeModePref.system : _explicitPref;
    await ThemeModeService.instance.setPref(next);
    _restartApp();
  }

  /// 主题切换后重启应用（仅 Android 走原生 Activity 重建；Windows / TV / 手机端不重启，
  /// 由各 Shell（WindowsShell/TvShell/MobileShell）监听 ThemeModeService 原地刷新自身，
  /// 返回首页即显示新主题，且不打断播放中的视频页）。
  void _restartApp() {
    ThemeModeService.requestRestart();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '软件主题设置',
        isWindows: DeviceUtils.isComputer,
      ),
      body: buildSettingsScrollView(
        children: [
          buildSectionTitle('软件主题'),
          _buildThemeCard(),
          const SizedBox(height: AppSpacing.md),
          buildSwitchTile(
            context: context,
            title: '跟随系统',
            subtitle: '开启后根据系统亮度自动在明亮/黑暗主题间切换',
            value: _followSystem,
            onChanged: _setFollowSystem,
          ),
          const SizedBox(height: AppSpacing.md),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: Text(
              _followSystem
                  ? '当前跟随系统（明亮/黑暗由系统决定）'
                  : '当前为${_explicitPref == ThemeModePref.light ? "明亮" : "黑暗"}主题',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          // 🔴 2026-10-23：磨砂玻璃档位（仅手机版显示）。
          //    实现与鸿蒙版同源，见 GlassStyleService 与 MobileShell。
          if (_showGlassSettings) ...[
            const SizedBox(height: AppSpacing.md),
            _buildGlassLevelCard(),
          ],
        ],
      ),
    );
  }

  Future<void> _setGlassLevel(GlassLevel level) async {
    await GlassStyleService.instance.setLevel(level);
  }

  /// 磨砂玻璃档位卡片：强 / 中 / 弱 / 关。
  ///
  /// 档位越高磨砂感越强（也越通透、光线透出最多），同时 Blur 计算开销越大。
  /// 默认「关」—— 高斯模糊是持续渲染开销，由用户按设备性能主动开启。
  Widget _buildGlassLevelCard() {
    return buildSettingsCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '沉浸式磨砂玻璃',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          for (final level in GlassLevel.values) ...[
            buildRadioTile<GlassLevel>(
              title: '${level.label}${level == GlassLevel.off ? '（默认）' : ''}',
              subtitle: _glassLevelSubtitle(level),
              value: level,
              groupValue: _glassLevel,
              onChanged: _setGlassLevel,
            ),
            if (level != GlassLevel.values.last)
              Divider(height: 1, color: AppColors.border),
          ],
          Divider(height: 1, color: AppColors.border),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 16, color: AppColors.textMuted),
                const SizedBox(width: AppSpacing.sm),
                Expanded(
                  child: Text(
                    '磨砂玻璃使用高斯模糊实时渲染，档位越高效果越强、'
                    '对 GPU 与电量的占用也越大，可能影响低配设备的使用性能。'
                    '若出现卡顿，建议选择「弱」或「关」。',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.4,
                      color: AppColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _glassLevelSubtitle(GlassLevel level) {
    switch (level) {
      case GlassLevel.strong:
        return '磨砂感最强，最通透、光线透出最多，性能开销最大';
      case GlassLevel.medium:
        return '兼顾磨砂观感与性能，推荐大多数设备';
      case GlassLevel.weak:
        return '磨砂感最弱，最接近纯色背景，最省性能';
      case GlassLevel.off:
        return '关闭磨砂，导航栏恢复纯色背景（默认，零模糊开销）';
    }
  }

  Widget _buildThemeCard() {
    final explicit = _explicitPref;
    final disabled = _followSystem;
    return buildSettingsCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '主题模式',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          Opacity(
            opacity: disabled ? 0.4 : 1.0,
            child: IgnorePointer(
              ignoring: disabled,
              child: buildRadioTile<ThemeModePref>(
                title: '明亮主题',
                subtitle: '背景为白色，文字为黑色',
                value: ThemeModePref.light,
                groupValue: explicit,
                onChanged: _selectExplicit,
              ),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          Opacity(
            opacity: disabled ? 0.4 : 1.0,
            child: IgnorePointer(
              ignoring: disabled,
              child: buildRadioTile<ThemeModePref>(
                title: '黑暗主题（默认）',
                subtitle: '背景为深色，适合暗光环境',
                value: ThemeModePref.dark,
                groupValue: explicit,
                onChanged: _selectExplicit,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
