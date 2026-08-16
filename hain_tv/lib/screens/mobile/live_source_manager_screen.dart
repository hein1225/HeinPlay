import 'package:flutter/material.dart';

import '../../models/live_source_config.dart';
import '../../services/cache_service.dart';
import '../../services/live_service.dart';
import '../../services/live_source_storage.dart';
import '../../theme.dart';

/// Mobile 直播源管理页。
///
/// LunaTV 内置源置顶展示，只读不可编辑删除；下方为用户自定义源，
/// 支持启用/禁用、编辑、删除、拖拽排序。
class MobileLiveSourceManagerScreen extends StatefulWidget {
  const MobileLiveSourceManagerScreen({super.key});

  @override
  State<MobileLiveSourceManagerScreen> createState() =>
      _MobileLiveSourceManagerScreenState();
}

class _MobileLiveSourceManagerScreenState
    extends State<MobileLiveSourceManagerScreen> {
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
            child: const Text(
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

  void _showEditDialog({LiveSourceConfig? config}) {
    if (config != null && config.isBuiltin) return;
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppColors.bgSurface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.lg)),
      ),
      builder: (ctx) => _SourceEditSheet(
        config: config,
        onSave: (newConfig) async {
          await LiveSourceStorage.saveConfig(newConfig);
          await _loadConfigs();
          if (ctx.mounted) Navigator.of(ctx).pop();
        },
      ),
    );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        title: const Text('直播源管理'),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: AppColors.primary),
            )
          : _buildBody(),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showEditDialog(),
        backgroundColor: AppColors.primary,
        child: const Icon(Icons.add, color: Colors.white),
      ),
    );
  }

  Widget _buildBody() {
    final allItems = [LiveService.lunaTvBuiltinSource, ..._userConfigs];
    if (allItems.length <= 1) {
      return _buildEmpty();
    }
    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: allItems.length,
      onReorderItem: (oldIndex, newIndex) {
        // 内置源固定置顶，不参与排序。
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
          const Icon(
            Icons.settings_input_antenna,
            size: 48,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
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
    return Card(
      key: ValueKey(config.id),
      color: AppColors.bgSurface,
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        leading: config.isBuiltin
            ? Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.sm,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: const Text(
                  '系统',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.primary,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              )
            : const Icon(Icons.drag_handle, color: AppColors.textMuted),
        title: Text(
          config.name,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        subtitle: Text(
          config.isBuiltin ? 'LunaTV 服务端直播源' : config.url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textMuted,
            fontSize: 12,
          ),
        ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!config.isBuiltin)
              Switch(
                value: config.enabled,
                onChanged: (_) => _toggleEnabled(config),
                activeThumbColor: AppColors.primary,
              ),
            TextButton.icon(
              onPressed: () => _clearSourceCache(config),
              icon: const Icon(
                Icons.delete_sweep,
                color: AppColors.textSecondary,
                size: 20,
              ),
              label: const Text(
                '清除缓存',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: AppColors.textSecondary,
                  fontSize: 13,
                ),
              ),
            ),
            if (!config.isBuiltin)
              IconButton(
                icon: const Icon(Icons.edit, color: AppColors.textSecondary),
                onPressed: () => _showEditDialog(config: config),
              ),
            if (!config.isBuiltin)
              IconButton(
                icon: const Icon(Icons.delete, color: AppColors.error),
                onPressed: () => _deleteConfig(config),
              ),
          ],
        ),
      ),
    );
  }
}

class _SourceEditSheet extends StatefulWidget {
  final LiveSourceConfig? config;
  final ValueChanged<LiveSourceConfig> onSave;

  const _SourceEditSheet({this.config, required this.onSave});

  @override
  State<_SourceEditSheet> createState() => _SourceEditSheetState();
}

class _SourceEditSheetState extends State<_SourceEditSheet> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late bool _enabled;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.config?.name ?? '');
    _urlController = TextEditingController(text: widget.config?.url ?? '');
    _enabled = widget.config?.enabled ?? true;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('名称和地址不能为空')),
      );
      return;
    }

    final isTextContent =
        url.startsWith('#EXTM3U') || url.startsWith('{');
    if (!isTextContent &&
        !url.startsWith('http://') &&
        !url.startsWith('https://') &&
        !url.endsWith('.m3u') &&
        !url.endsWith('.m3u8') &&
        !url.endsWith('.json')) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请输入有效的 M3U/M3U8/JSON 地址或内容')),
      );
      return;
    }

    final config = widget.config?.copyWith(
          name: name,
          url: url,
          enabled: _enabled,
        ) ??
        LiveSourceConfig(
          id: LiveSourceConfig.generateId(),
          name: name,
          url: url,
          isLocal: true,
          enabled: _enabled,
          createTime: DateTime.now(),
        );

    widget.onSave(config);
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(
        left: AppSpacing.md,
        right: AppSpacing.md,
        top: AppSpacing.lg,
        bottom: bottom + AppSpacing.lg,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            widget.config == null ? '添加直播源' : '编辑直播源',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(labelText: '源名称'),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: _urlController,
            maxLines: 4,
            minLines: 2,
            decoration: const InputDecoration(
              labelText: 'M3U/M3U8/JSON 地址或内容',
              hintText: '支持网络地址或粘贴文本内容',
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Row(
            children: [
              const Text(
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
          const SizedBox(height: AppSpacing.md),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _save,
              child: const Text('保存'),
            ),
          ),
          const SizedBox(height: AppSpacing.md),
        ],
      ),
    );
  }
}
