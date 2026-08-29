import 'package:flutter/material.dart';

import '../../models/live_source_config.dart';
import '../../services/cache_service.dart';
import '../../services/live_service.dart';
import '../../services/live_source_storage.dart';
import '../../theme.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

/// Windows 直播源管理页。
///
/// LunaTV 内置源置顶展示，只读不可编辑删除；下方为用户自定义源，
/// 支持启用/禁用、编辑、删除、拖拽排序。
class WindowsLiveSourceManagerScreen extends StatefulWidget {
  const WindowsLiveSourceManagerScreen({super.key});

  @override
  State<WindowsLiveSourceManagerScreen> createState() =>
      _WindowsLiveSourceManagerScreenState();
}

class _WindowsLiveSourceManagerScreenState
    extends State<WindowsLiveSourceManagerScreen> {
  List<LiveSourceConfig> _userConfigs = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final configs = await LiveSourceStorage.getConfigs();
    setState(() {
      _userConfigs = configs;
      _loading = false;
    });
  }

  Future<void> _deleteConfig(LiveSourceConfig config) async {
    if (config.isBuiltin) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: const Text('删除直播源'),
        content: Text('确定删除「${config.name}」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              '删除',
              style: TextStyle(color: AppColors.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await LiveSourceStorage.deleteConfig(config.id);
      await _loadConfigs();
    }
  }

  Future<void> _toggleEnabled(LiveSourceConfig config) async {
    if (config.isBuiltin) return;
    final updated = config.copyWith(enabled: !config.enabled);
    await LiveSourceStorage.saveConfig(updated);
    await _loadConfigs();
  }

  Future<void> _reorderConfigs(int oldIndex, int newIndex) async {
    final item = _userConfigs.removeAt(oldIndex);
    _userConfigs.insert(newIndex, item);
    await LiveSourceStorage.reorderConfigs(_userConfigs);
    await _loadConfigs();
  }

  Future<void> _clearSourceCache(LiveSourceConfig config) async {
    if (config.isBuiltin) {
      await LiveService.clearLunaTvCache(key: config.sourceKey);
    } else {
      final cacheKey = CacheService()
          .generateLiveChannelsCacheKey(sourceKey: config.id);
      await CacheService().delete(cacheKey);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${config.name}」直播源缓存已清除')),
      );
    }
  }

  void _showEditDialog({LiveSourceConfig? config}) {
    if (config != null && config.isBuiltin) return;
    showDialog(
      context: context,
      builder: (ctx) => _SourceEditDialog(
        config: config,
        onSave: (newConfig) async {
          await LiveSourceStorage.saveConfig(newConfig);
          await _loadConfigs();
          if (ctx.mounted) Navigator.of(ctx).pop();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: Column(
        children: [
          _buildHeader(),
          Container(height: 1, color: AppColors.border),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      color: AppColors.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
            tooltip: '返回',
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Text(
              '直播源管理',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: AppColors.textPrimary,
              ),
            ),
          ),
          ElevatedButton.icon(
            onPressed: () => _showEditDialog(),
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: TechLoadingIndicator(),
      );
    }

    final allItems = [LiveService.lunaTvBuiltinSource, ..._userConfigs];

    if (allItems.length <= 1) {
      return _buildEmpty();
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: allItems.length,
      buildDefaultDragHandles: false,
      onReorderItem: (oldIndex, newIndex) {
        if (oldIndex == 0) return;
        final userOldIndex = oldIndex - 1;
        final userNewIndex = newIndex <= 0 ? 0 : newIndex - 1;
        _reorderConfigs(userOldIndex, userNewIndex);
      },
      itemBuilder: (context, index) {
        final config = allItems[index];
        return _buildConfigCard(config, index);
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.settings_input_antenna,
            size: 48,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '暂无本地直播源',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          ElevatedButton(
            onPressed: () => _showEditDialog(),
            child: const Text('添加直播源'),
          ),
        ],
      ),
    );
  }

  Widget _buildConfigCard(LiveSourceConfig config, int index) {
    return Container(
      key: ValueKey(config.id),
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      decoration: BoxDecoration(
        color: AppColors.bgSurface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: AppColors.border,
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 排序图标 / 内置源标签放在源框内首位
          if (config.isBuiltin)
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(
                '服务器',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: AppColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: EdgeInsets.only(right: AppSpacing.xs),
                child: Icon(Icons.drag_handle, size: 20, color: AppColors.textMuted),
              ),
            ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  config.name,
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  config.isBuiltin ? 'LunaTV 服务端直播源' : config.url,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton.icon(
                onPressed: () => _clearSourceCache(config),
                icon: Icon(
                  Icons.delete_sweep,
                  size: 18,
                  color: AppColors.textSecondary,
                ),
                label: Text(
                  '清除缓存',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              if (!config.isBuiltin)
                Switch(
                  value: config.enabled,
                  onChanged: (_) => _toggleEnabled(config),
                  activeThumbColor: AppColors.primary,
                ),
              if (!config.isBuiltin)
                IconButton(
                  icon: Icon(Icons.edit, size: 20, color: AppColors.textSecondary),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () => _showEditDialog(config: config),
                ),
              if (!config.isBuiltin)
                IconButton(
                  icon: Icon(Icons.delete, size: 20, color: AppColors.error),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 32,
                    minHeight: 32,
                  ),
                  onPressed: () => _deleteConfig(config),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _SourceEditDialog extends StatefulWidget {
  final LiveSourceConfig? config;
  final ValueChanged<LiveSourceConfig> onSave;

  const _SourceEditDialog({this.config, required this.onSave});

  @override
  State<_SourceEditDialog> createState() => _SourceEditDialogState();
}

class _SourceEditDialogState extends State<_SourceEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late final TextEditingController _proxyController;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.config?.name ?? '');
    _urlController = TextEditingController(text: widget.config?.url ?? '');
    _proxyController =
        TextEditingController(text: widget.config?.proxyUrl ?? '');
    _enabled = widget.config?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    _proxyController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) return;

    final proxyText = _proxyController.text.trim();
    final proxyUrl = proxyText.isEmpty ? null : proxyText;

    final config = widget.config?.copyWith(
          name: name,
          url: url,
          proxyUrl: proxyUrl,
          enabled: _enabled,
        ) ??
        LiveSourceConfig(
          id: LiveSourceConfig.generateId(),
          name: name,
          url: url,
          proxyUrl: proxyUrl,
          isLocal: true,
          enabled: _enabled,
          createTime: DateTime.now(),
        );

    widget.onSave(config);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgSurface,
      title: Text(
        widget.config == null ? '添加直播源' : '编辑直播源',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: AppColors.textPrimary,
        ),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _nameController,
              decoration: const InputDecoration(labelText: '源名称'),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _urlController,
              maxLines: 5,
              minLines: 3,
              decoration: const InputDecoration(
                labelText: 'M3U/M3U8/JSON 地址或内容',
                hintText: '支持网络地址或粘贴文本内容',
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _proxyController,
              decoration: const InputDecoration(
                labelText: '播放代理地址（可选）',
                hintText: '如 http://127.0.0.1:7890',
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Row(
              children: [
                Text(
                  '启用',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.textSecondary,
                  ),
                ),
                Switch(
                  value: _enabled,
                  onChanged: (v) => setState(() => _enabled = v),
                  activeThumbColor: AppColors.primary,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        ElevatedButton(
          onPressed: _save,
          child: const Text('保存'),
        ),
      ],
    );
  }
}
