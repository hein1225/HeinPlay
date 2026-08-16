import 'package:flutter/material.dart';

import '../../models/live_source_config.dart';
import '../../services/cache_service.dart';
import '../../services/live_service.dart';
import '../../services/live_source_refresh_notifier.dart';
import '../../services/live_source_storage.dart';
import '../../theme.dart';
import '../live_player_screen.dart';

/// Mobile 直播首页：直播源管理界面。
///
/// 右上角"添加直播源"，列表项右侧有编辑和删除按钮，点击源进入全屏播放。
class MobileLiveScreen extends StatefulWidget {
  const MobileLiveScreen({super.key});

  @override
  State<MobileLiveScreen> createState() => _MobileLiveScreenState();
}

class _MobileLiveScreenState extends State<MobileLiveScreen> {
  List<LiveSourceConfig> _sources = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSources();
    LiveSourceRefreshNotifier.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) _loadSources();
  }

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = await LiveService.getAllSources();
      if (mounted) {
        setState(() {
          _sources = sources;
          _loading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载直播源失败: $e';
          _loading = false;
        });
      }
    }
  }

  void _onSourceTap(LiveSourceConfig source) {
    final index = _sources.indexWhere((s) => s.id == source.id);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LivePlayerScreen(
          source: source,
          allSources: _sources,
          sourceIndex: index >= 0 ? index : 0,
        ),
      ),
    );
  }

  Future<void> _clearSourceCache(LiveSourceConfig config) async {
    if (config.isBuiltin) {
      await LiveService.clearLunaTvCache(key: config.sourceKey);
    } else {
      final cacheKey =
          CacheService().generateLiveChannelsCacheKey(sourceKey: config.id);
      await CacheService().delete(cacheKey);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('「${config.name}」直播源缓存已清除')),
      );
    }
  }

  Future<void> _editSource(LiveSourceConfig source) async {
    final result = await _showSourceDialog(
      title: '编辑直播源',
      initialName: source.name,
      initialUrl: source.url,
    );
    if (result == null) return;
    final updated = source.copyWith(name: result.name, url: result.url);
    await LiveSourceStorage.saveConfig(updated);
    await _loadSources();
  }

  @override
  void dispose() {
    LiveSourceRefreshNotifier.instance.removeListener(_onSettingsChanged);
    super.dispose();
  }

  Future<void> _deleteSource(LiveSourceConfig source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: const Text(
          '删除确认',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textPrimary,
          ),
        ),
        content: Text(
          '确定要删除直播源"${source.name}"吗？',
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textSecondary,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.textSecondary),
            ),
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
    if (confirmed != true) return;
    await LiveSourceStorage.deleteConfig(source.id);
    await _loadSources();
  }

  Widget _buildSourceTag(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 2,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(AppRadius.sm),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Future<({String name, String url})?> _showSourceDialog({
    required String title,
    String initialName = '',
    String initialUrl = '',
  }) async {
    final nameCtrl = TextEditingController(text: initialName);
    final urlCtrl = TextEditingController(text: initialUrl);
    final result = await showDialog<({String name, String url})>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(
          title,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textPrimary,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: '直播源名称',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: urlCtrl,
              decoration: const InputDecoration(
                labelText: '直播源地址（M3U/M3U8/JSON 链接或内容）',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                border: OutlineInputBorder(),
              ),
              style: const TextStyle(color: AppColors.textPrimary),
              maxLines: 3,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ),
          TextButton(
            onPressed: () {
              final name = nameCtrl.text.trim();
              final url = urlCtrl.text.trim();
              if (name.isEmpty || url.isEmpty) return;
              Navigator.of(ctx).pop((name: name, url: url));
            },
            child: const Text(
              '保存',
              style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
    nameCtrl.dispose();
    urlCtrl.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        title: const Text('直播'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: '添加直播源',
            onPressed: () async {
              final result = await _showSourceDialog(title: '添加直播源');
              if (result == null) return;
              final config = LiveSourceConfig(
                id: LiveSourceConfig.generateId(),
                name: result.name,
                url: result.url,
                isLocal: true,
                createTime: DateTime.now(),
              );
              await LiveSourceStorage.saveConfig(config);
              await _loadSources();
            },
          ),
        ],
      ),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            ElevatedButton(
              onPressed: _loadSources,
              child: const Text('重新加载'),
            ),
          ],
        ),
      );
    }

    if (_sources.isEmpty) {
      return _buildEmpty();
    }

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: _sources.length,
      itemBuilder: (context, index) {
        final source = _sources[index];
        return _buildSourceCard(source);
      },
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.live_tv,
            size: 48,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.md),
          const Text(
            '暂无可用直播源',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          ElevatedButton.icon(
            onPressed: () async {
              final result = await _showSourceDialog(title: '添加直播源');
              if (result == null) return;
              final config = LiveSourceConfig(
                id: LiveSourceConfig.generateId(),
                name: result.name,
                url: result.url,
                isLocal: true,
                createTime: DateTime.now(),
              );
              await LiveSourceStorage.saveConfig(config);
              await _loadSources();
            },
            icon: const Icon(Icons.add),
            label: const Text('添加直播源'),
          ),
        ],
      ),
    );
  }

  Widget _buildSourceCard(LiveSourceConfig source) {
    return Card(
      color: AppColors.bgSurface,
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: () => _onSourceTap(source),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: Row(
            children: [
              // 左侧标识
            _buildSourceTag(
              source.isBuiltin ? '服务器' : '本地',
              source.isBuiltin ? AppColors.primary : AppColors.success,
            ),
              const SizedBox(width: AppSpacing.md),
              // 中间信息
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      source.name,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: AppColors.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      source.isBuiltin ? 'LunaTV 服务端直播源' : source.url,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: AppColors.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              // 右侧操作按钮
              IconButton(
                icon: const Icon(Icons.delete_sweep, size: 20),
                color: AppColors.textSecondary,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                tooltip: '清除缓存',
                onPressed: () => _clearSourceCache(source),
              ),
              if (!source.isBuiltin) ...[
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 20),
                  color: AppColors.textSecondary,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () => _editSource(source),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  color: AppColors.error,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                  onPressed: () => _deleteSource(source),
                ),
              ],
              const Icon(
                Icons.chevron_right,
                color: AppColors.textSecondary,
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }
}