import 'package:flutter/material.dart';

import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/screens/tv/settings/data_source_settings_page.dart';
import 'package:hain_tv/screens/tv/settings/live_settings_page.dart';
import 'package:hain_tv/screens/tv/settings/other_settings_page.dart';
import 'package:hain_tv/screens/tv/settings/settings_helpers.dart';
import 'package:hain_tv/screens/tv/settings/theme_settings_page.dart';
import 'package:hain_tv/screens/tv/settings/vod_settings_page.dart';

/// 软件设置：顶层分级菜单。
/// 各分类进入独立子页，避免单页设置项过多。
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '软件设置',
        isWindows: DeviceUtils.isWindows,
      ),
      body: buildSettingsScrollView(
        children: [
          buildActionTile(
            title: '点播设置',
            subtitle: '默认播放器、跳过片头片尾、自动切换源、缓冲模式',
            icon: Icons.play_circle_outline,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const VodSettingsPage()),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          buildActionTile(
            title: '直播设置',
            subtitle: '直播播放器、LunaTV 直播源、EPG、缓存时间',
            icon: Icons.live_tv_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LiveSettingsPage()),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          buildActionTile(
            title: '数据源设置',
            subtitle: '豆瓣数据源、Bangumi 代理',
            icon: Icons.cloud_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const DataSourceSettingsPage(),
              ),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          buildActionTile(
            title: '软件主题设置',
            subtitle: '明亮 / 黑暗主题、跟随系统',
            icon: Icons.palette_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const ThemeSettingsPage()),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          buildActionTile(
            title: '其他',
            subtitle: '清除缓存源、日志与调试、关于',
            icon: Icons.more_horiz_outlined,
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const OtherSettingsPage()),
            ),
          ),
        ],
      ),
    );
  }
}
