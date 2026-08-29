import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  @override
  void initState() {
    super.initState();
    _syncFromService();
    ThemeModeService.instance.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    ThemeModeService.instance.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _syncFromService() {
    _pref = ThemeModeService.instance.pref;
    _followSystem = ThemeModeService.instance.followSystem;
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

  /// 主题切换后重启应用（仅 Android 走原生 Activity 重建；其它平台依赖各 App 根的
  /// setState 原地刷新，由 ThemeModeService 的监听驱动）。
  void _restartApp() {
    if (Platform.isAndroid) {
      try {
        const MethodChannel('hain_tv/app').invokeMethod<void>('restart');
      } catch (e) {
        debugPrint('请求重启应用失败: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '软件主题设置',
        isWindows: DeviceUtils.isWindows,
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
        ],
      ),
    );
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
