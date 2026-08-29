import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:hain_tv/services/bangumi_service.dart';
import 'package:hain_tv/services/cache_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/screens/tv/settings/settings_helpers.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';

class DataSourceSettingsPage extends StatefulWidget {
  const DataSourceSettingsPage({super.key});

  @override
  State<DataSourceSettingsPage> createState() => _DataSourceSettingsPageState();
}

class _DataSourceSettingsPageState extends State<DataSourceSettingsPage> {
  DoubanDataSource _doubanSource = DoubanDataSource.direct;
  BangumiApiProxyType _bangumiApiProxyType = BangumiApiProxyType.cmliussss;
  String _bangumiApiProxyUrl = '';
  BangumiImageProxyType _bangumiImageProxyType =
      BangumiImageProxyType.cmliussss;
  String _bangumiImageProxyUrl = '';

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final douban = await UserDataService.getDoubanDataSource();
    final bangumiApiProxyType = await UserDataService.getBangumiApiProxyType();
    final bangumiApiProxyUrl = await UserDataService.getBangumiApiProxyUrl();
    final bangumiImageProxyType =
        await UserDataService.getBangumiImageProxyType();
    final bangumiImageProxyUrl =
        await UserDataService.getBangumiImageProxyUrl();
    await BangumiService.loadProxySettings();
    if (!mounted) return;
    setState(() {
      _doubanSource = douban;
      _bangumiApiProxyType = bangumiApiProxyType;
      _bangumiApiProxyUrl = bangumiApiProxyUrl;
      _bangumiImageProxyType = bangumiImageProxyType;
      _bangumiImageProxyUrl = bangumiImageProxyUrl;
    });
  }

  String _doubanSourceLabel(DoubanDataSource source) {
    switch (source) {
      case DoubanDataSource.cdnTencent:
        return '腾讯云 CDN';
      case DoubanDataSource.cdnAliyun:
        return '阿里云 CDN';
      case DoubanDataSource.corsProxy:
        return 'CORS 代理';
      case DoubanDataSource.direct:
        return '直连';
    }
  }

  Future<void> _setDoubanSource(DoubanDataSource value) async {
    try {
      await UserDataService.saveDoubanDataSource(value);
      final verified = await UserDataService.getDoubanDataSource();
      if (verified != value) {
        showSettingsSnackBar(context, '数据源保存验证失败，请重试',
            backgroundColor: AppColors.error);
        return;
      }
      setState(() => _doubanSource = value);
      try {
        final cache = CacheService();
        await cache.init();
        await cache.clearPrefix('douban_');
      } catch (e) {
        // 缓存清除失败不影响设置保存
      }
      showSettingsSnackBar(
        context,
        '已切换为 ${_doubanSourceLabel(value)}，豆瓣缓存已清除',
      );
    } catch (e) {
      showSettingsSnackBar(context, '切换失败: $e',
          backgroundColor: AppColors.error);
    }
  }

  Future<void> _setBangumiApiProxyType(BangumiApiProxyType value) async {
    await UserDataService.saveBangumiApiProxyType(value);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiApiProxyType = value);
  }

  Future<void> _setBangumiApiProxyUrl(String url) async {
    await UserDataService.saveBangumiApiProxyUrl(url);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiApiProxyUrl = url.trim());
  }

  Future<void> _setBangumiImageProxyType(BangumiImageProxyType value) async {
    await UserDataService.saveBangumiImageProxyType(value);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiImageProxyType = value);
  }

  Future<void> _setBangumiImageProxyUrl(String url) async {
    await UserDataService.saveBangumiImageProxyUrl(url);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiImageProxyUrl = url.trim());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: buildSettingsAppBar(
        context: context,
        title: '数据源设置',
        isWindows: DeviceUtils.isWindows,
      ),
      body: buildSettingsScrollView(
        children: [
          buildSectionTitle('豆瓣数据源'),
          _buildDoubanSourceCard(),
          const SizedBox(height: AppSpacing.lg),
          buildSectionTitle('Bangumi 数据源'),
          _buildBangumiApiProxyCard(),
          const SizedBox(height: AppSpacing.md),
          _buildBangumiImageProxyCard(),
        ],
      ),
    );
  }

  Widget _buildDoubanSourceCard() {
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
              '当前：${_doubanSourceLabel(_doubanSource)}',
              style: TextStyle(fontSize: 12, color: AppColors.textMuted),
            ),
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<DoubanDataSource>(
            title: '直连（默认）',
            subtitle: '直接访问豆瓣官方接口',
            value: DoubanDataSource.direct,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<DoubanDataSource>(
            title: '腾讯云 CDN',
            subtitle: '通过腾讯云 CDN 加速访问',
            value: DoubanDataSource.cdnTencent,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<DoubanDataSource>(
            title: '阿里云 CDN',
            subtitle: '通过阿里云 CDN 加速访问',
            value: DoubanDataSource.cdnAliyun,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          Divider(height: 1, color: AppColors.border),
          buildRadioTile<DoubanDataSource>(
            title: 'CORS 代理',
            subtitle: '通过 CORS 代理服务器访问',
            value: DoubanDataSource.corsProxy,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
        ],
      ),
    );
  }

  Widget _buildBangumiApiProxyCard() {
    return buildSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bangumi 数据代理',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '选择获取 Bangumi 番剧数据的方式，服务器无法访问 api.bgm.tv 时可切换反代',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          buildRadioTile<BangumiApiProxyType>(
            title: '直连（直接访问 api.bgm.tv）',
            value: BangumiApiProxyType.direct,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          buildRadioTile<BangumiApiProxyType>(
            title: 'Bangumi 反代 By CMLiussss（解决服务器被墙）',
            value: BangumiApiProxyType.cmliussss,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          buildRadioTile<BangumiApiProxyType>(
            title: '自定义反代地址',
            value: BangumiApiProxyType.custom,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          if (_bangumiApiProxyType == BangumiApiProxyType.custom)
            _buildProxyUrlTile(
              title: 'Bangumi 反代地址',
              hint: '例如 https://api.example.com',
              current: _bangumiApiProxyUrl,
              onSave: _setBangumiApiProxyUrl,
            ),
          if (_bangumiApiProxyType == BangumiApiProxyType.cmliussss)
            Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Thanks to @CMLiussss',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBangumiImageProxyCard() {
    return buildSettingsCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Bangumi 图片代理',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  '选择获取 Bangumi 封面图片的方式，服务器无法访问 lain.bgm.tv 时可切换',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          buildRadioTile<BangumiImageProxyType>(
            title: '直连（直接请求 lain.bgm.tv）',
            value: BangumiImageProxyType.direct,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          buildRadioTile<BangumiImageProxyType>(
            title: 'Bangumi 图片 CDN By CMLiussss',
            value: BangumiImageProxyType.cmliussss,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          buildRadioTile<BangumiImageProxyType>(
            title: '自定义代理',
            value: BangumiImageProxyType.custom,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          if (_bangumiImageProxyType == BangumiImageProxyType.custom)
            _buildProxyUrlTile(
              title: 'Bangumi 图片代理地址',
              hint: '例如 https://img.example.com/proxy?url=',
              current: _bangumiImageProxyUrl,
              onSave: _setBangumiImageProxyUrl,
            ),
          if (_bangumiImageProxyType == BangumiImageProxyType.cmliussss)
            Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Thanks to @CMLiussss',
                style: TextStyle(fontSize: 12, color: AppColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildProxyUrlTile({
    required String title,
    required String hint,
    required String current,
    required ValueChanged<String> onSave,
  }) {
    return Builder(
      builder: (ctx) => FocusableWidget(
        onTap: () => _showProxyUrlInput(
          title: title,
          hint: hint,
          current: current,
          onSave: onSave,
        ),
        onFocusChange: (focused) => ensureVisibleOnFocus(ctx, focused),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                current.isEmpty ? '点击输入代理地址' : current,
                style: TextStyle(
                  fontSize: 13,
                  color: current.isEmpty
                      ? AppColors.textMuted
                      : AppColors.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: AppSpacing.xs),
              Text(
                '与官方路径兼容的代理地址，不含末尾斜杠',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showProxyUrlInput({
    required String title,
    required String hint,
    required String current,
    required ValueChanged<String> onSave,
  }) async {
    final controller = TextEditingController(text: current);
    final fieldNode = FocusNode();
    final cancelNode = FocusNode();
    final saveNode = FocusNode();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        void closeDialog(bool value) {
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop(value);
          }
        }

        return FocusScope(
          child: AlertDialog(
            backgroundColor: AppColors.bgSurface,
            title: Text(title),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent &&
                        event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      cancelNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.escape) {
                      closeDialog(false);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: controller,
                    focusNode: fieldNode,
                    autofocus: true,
                    style: TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: hint,
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _buildDialogButton(
                      node: cancelNode,
                      fieldNode: fieldNode,
                      label: '取消',
                      color: AppColors.textPrimary,
                      onClose: () => closeDialog(false),
                    ),
                    _buildDialogButton(
                      node: saveNode,
                      fieldNode: fieldNode,
                      label: '保存',
                      color: AppColors.primary,
                      onClose: () => closeDialog(true),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
    fieldNode.dispose();
    cancelNode.dispose();
    saveNode.dispose();
    if (confirmed == true) {
      onSave(controller.text);
    }
    controller.dispose();
  }

  Widget _buildDialogButton({
    required FocusNode node,
    required FocusNode fieldNode,
    required String label,
    required Color color,
    required VoidCallback onClose,
  }) {
    return FocusableWidget(
      focusNode: node,
      onTap: onClose,
      onKeyEvent: (n, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final key = event.logicalKey;
        if (key == LogicalKeyboardKey.arrowUp) {
          fieldNode.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.goBack || key == LogicalKeyboardKey.escape) {
          onClose();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: color,
          ),
        ),
      ),
    );
  }
}
