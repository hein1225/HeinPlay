import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/live_source_config.dart';
import '../../services/cache_service.dart';
import '../../services/live_service.dart';
import '../../services/live_source_storage.dart';
import '../../services/remote_input_service.dart';
import '../../theme.dart';
import '../../widgets/tv/focusable.dart';

class TvLiveSourceManagerScreen extends StatefulWidget {
  const TvLiveSourceManagerScreen({super.key});

  @override
  State<TvLiveSourceManagerScreen> createState() =>
      _TvLiveSourceManagerScreenState();
}

class _TvLiveSourceManagerScreenState
    extends State<TvLiveSourceManagerScreen> {
  List<LiveSourceConfig> _allConfigs = [];
  bool _loading = true;

  List<LiveSourceConfig> get _userConfigs =>
      _allConfigs.where((c) => !c.isBuiltin).toList();

  final _remoteInputService = RemoteInputService();
  StreamSubscription<void>? _liveSourcesChangedSub;
  bool _qrDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _liveSourcesChangedSub =
        _remoteInputService.onLiveSourcesChanged.listen((_) {
      if (mounted) _loadConfigs();
    });
    _loadConfigs();
  }

  Future<void> _loadConfigs() async {
    final configs = await LiveService.getAllSources();
    if (!mounted) return;
    setState(() {
      _allConfigs = configs;
      _loading = false;
    });
  }

  Future<void> _reorderConfigs(int oldIndex, int newIndex) async {
    // 内置源固定置顶，不参与排序。
    if (oldIndex == 0) return;
    final userOld = oldIndex - 1;
    final userNew = newIndex <= 0 ? 0 : newIndex - 1;
    final userList = List<LiveSourceConfig>.from(_userConfigs);
    final item = userList.removeAt(userOld);
    userList.insert(userNew, item);
    await LiveSourceStorage.reorderConfigs(userList);
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
      barrierDismissible: false,
      builder: (ctx) {
        return _TvSourceEditDialog(
          config: config,
          onSave: (newConfig) async {
            await LiveSourceStorage.saveConfig(newConfig);
            await _loadConfigs();
            if (ctx.mounted) Navigator.of(ctx).pop();
          },
          onDelete: config != null
              ? () async {
                  await LiveSourceStorage.deleteConfig(config.id);
                  await _loadConfigs();
                  if (ctx.mounted) Navigator.of(ctx).pop();
                }
              : null,
        );
      },
    );
  }

  Future<void> _showQrManageDialog() async {
    if (_qrDialogShowing) return;
    setState(() => _qrDialogShowing = true);

    String? url;
    String? error;
    try {
      final baseUrl = await _remoteInputService.startServer();
      url = '$baseUrl?mode=live_sources';
    } catch (e) {
      error = '启动失败，请检查网络权限';
    }

    if (!mounted) return;
    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: const Text(
            '手机扫码管理直播源',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 240,
            height: 260,
            child: error != null
                ? Center(
                    child: Text(
                      error,
                      style: const TextStyle(color: AppColors.error),
                    ),
                  )
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(AppRadius.md),
                        ),
                        child: QrImageView(
                          data: url!,
                          version: QrVersions.auto,
                          size: 180,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      const Text(
                        '使用手机扫描二维码，在网页上添加、编辑或删除直播源',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          fontSize: 13,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
          ),
          actions: [
            FocusableWidget(
              autofocus: true,
              onTap: () => Navigator.of(ctx).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  border: Border.all(color: AppColors.border),
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '取消',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.textSecondary,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (mounted) {
      setState(() => _qrDialogShowing = false);
    }
  }

  @override
  void dispose() {
    _liveSourcesChangedSub?.cancel();
    _remoteInputService.dispose();
    super.dispose();
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
          const Expanded(
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
          FocusableWidget(
            onTap: _showQrManageDialog,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.bgSurface,
                border: Border.all(color: AppColors.border),
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.qr_code_scanner,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  SizedBox(width: AppSpacing.xs),
                  Text(
                    '手机管理',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: AppColors.textSecondary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          FocusableWidget(
            onTap: () => _showEditDialog(),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add, size: 16, color: Colors.white),
                  SizedBox(width: AppSpacing.xs),
                  Text(
                    '添加',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_userConfigs.isEmpty) {
      return _buildEmpty();
    }

    return ReorderableListView.builder(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: _allConfigs.length,
      onReorderItem: _reorderConfigs,
      itemBuilder: (context, index) {
        final config = _allConfigs[index];
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
          FocusableWidget(
            onTap: () => _showEditDialog(),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.lg,
                vertical: AppSpacing.sm,
              ),
              decoration: BoxDecoration(
                color: AppColors.primary,
                borderRadius: BorderRadius.circular(AppRadius.md),
              ),
              child: const Text(
                '添加直播源',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
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
      ),
      child: Row(
        children: [
          Expanded(
            child: FocusableWidget(
              onTap: config.isBuiltin
                  ? null
                  : () => _showEditDialog(config: config),
              padding: EdgeInsets.zero,
              child: Row(
                children: [
                  if (config.isBuiltin)
                    Container(
                      margin: const EdgeInsets.only(right: AppSpacing.md),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AppSpacing.sm,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.primary.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(AppRadius.sm),
                      ),
                      child: const Text(
                        '服务器',
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: AppColors.primary,
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          config.name,
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: AppColors.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 15,
                          ),
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          config.isBuiltin
                              ? 'LunaTV 服务端直播源'
                              : (config.url.length > 60
                                  ? '${config.url.substring(0, 60)}...'
                                  : config.url),
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
                  if (!config.isBuiltin)
                    Padding(
                      padding: const EdgeInsets.only(left: AppSpacing.sm),
                      child: Text(
                        config.enabled ? '已启用' : '已禁用',
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: config.enabled
                              ? AppColors.success
                              : AppColors.error,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          FocusableWidget(
            onTap: () => _clearSourceCache(config),
            padding: const EdgeInsets.all(AppSpacing.xs),
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.sm,
                vertical: AppSpacing.xs,
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.delete_sweep,
                    size: 18,
                    color: AppColors.textSecondary,
                  ),
                  SizedBox(width: 4),
                  Text(
                    '清除缓存',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: AppColors.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TvSourceEditDialog extends StatefulWidget {
  final LiveSourceConfig? config;
  final ValueChanged<LiveSourceConfig> onSave;
  final VoidCallback? onDelete;

  const _TvSourceEditDialog({
    this.config,
    required this.onSave,
    this.onDelete,
  });

  @override
  State<_TvSourceEditDialog> createState() => _TvSourceEditDialogState();
}

class _TvSourceEditDialogState extends State<_TvSourceEditDialog> {
  late final TextEditingController _nameController;
  late final TextEditingController _urlController;
  late bool _enabled;

  // 可聚焦项顺序：名称(0) -> URL(1) -> 启用(2) -> 取消(3) -> [删除(4)] -> 保存(末尾)
  final List<FocusNode> _focusNodes = [];
  int _focusIndex = 0;

  static const int _nameIndex = 0;
  static const int _urlIndex = 1;
  static const int _enabledIndex = 2;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.config?.name ?? '');
    _urlController = TextEditingController(text: widget.config?.url ?? '');
    _enabled = widget.config?.enabled ?? true;
    // 名称、URL、启用、取消、保存，若有删除再追加一个。
    _focusNodes.addAll(List.generate(widget.onDelete != null ? 6 : 5, (_) => FocusNode()));
  }

  @override
  void dispose() {
    _nameController.dispose();
    _urlController.dispose();
    for (final node in _focusNodes) {
      node.dispose();
    }
    super.dispose();
  }

  int get _saveIndex => _focusNodes.length - 1;
  int get _deleteIndex => widget.onDelete != null ? _focusNodes.length - 2 : -1;
  int get _cancelIndex => widget.onDelete != null ? _focusNodes.length - 3 : _focusNodes.length - 2;
  int get _firstActionIndex => _cancelIndex;

  void _moveFocus(int delta) {
    final newIndex = (_focusIndex + delta).clamp(0, _focusNodes.length - 1);
    if (newIndex != _focusIndex) {
      setState(() => _focusIndex = newIndex);
      _focusNodes[newIndex].requestFocus();
    }
  }

  void _toggleEnabled() => setState(() => _enabled = !_enabled);

  Future<void> _save() async {
    final name = _nameController.text.trim();
    final url = _urlController.text.trim();
    if (name.isEmpty || url.isEmpty) return;

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

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        // 在首个输入框按上键循环到底部保存按钮。
        if (_focusIndex == 0) {
          setState(() => _focusIndex = _saveIndex);
          _focusNodes[_saveIndex].requestFocus();
        } else {
          _moveFocus(-1);
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowDown:
        _moveFocus(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowLeft:
      case LogicalKeyboardKey.arrowRight:
        // 仅在底部操作按钮间左右切换。
        if (_focusIndex >= _firstActionIndex) {
          final delta = event.logicalKey == LogicalKeyboardKey.arrowLeft ? -1 : 1;
          final newIndex = (_focusIndex + delta).clamp(_firstActionIndex, _saveIndex);
          if (newIndex != _focusIndex) {
            setState(() => _focusIndex = newIndex);
            _focusNodes[newIndex].requestFocus();
          }
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
        if (_focusIndex == _enabledIndex) {
          _toggleEnabled();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      default:
        return KeyEventResult.ignored;
    }
  }

  Widget _buildTextField({
    required int index,
    required TextEditingController controller,
    required String label,
    int? maxLines,
    int? minLines,
    String? hint,
  }) {
    final focused = _focusIndex == index;
    return FocusableWidget(
      focusNode: _focusNodes[index],
      autofocus: index == 0,
      padding: EdgeInsets.zero,
      consumeDirectionalKeys: true,
      onKeyEvent: _handleKey,
      onFocusChange: (hasFocus) {
        if (hasFocus) setState(() => _focusIndex = index);
      },
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: focused ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
        child: TextField(
          controller: controller,
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: InputBorder.none,
          ),
          style: const TextStyle(color: AppColors.textPrimary),
          maxLines: maxLines,
          minLines: minLines,
        ),
      ),
    );
  }

  Widget _buildActionButton({
    required int index,
    required String label,
    required VoidCallback onTap,
    Color? foregroundColor,
    Color? backgroundColor,
    Color? borderColor,
  }) {
    final focused = _focusIndex == index;
    return FocusableWidget(
      focusNode: _focusNodes[index],
      padding: EdgeInsets.zero,
      consumeDirectionalKeys: true,
      onKeyEvent: _handleKey,
      onFocusChange: (hasFocus) {
        if (hasFocus) setState(() => _focusIndex = index);
      },
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.lg,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: backgroundColor ?? AppColors.bgSurface,
          border: Border.all(
            color: focused
                ? AppColors.primary
                : (borderColor ?? Colors.transparent),
            width: 2,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: foregroundColor ?? AppColors.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }

  Widget _buildEnabledSwitch() {
    final focused = _focusIndex == _enabledIndex;
    return FocusableWidget(
      focusNode: _focusNodes[_enabledIndex],
      padding: EdgeInsets.zero,
      consumeDirectionalKeys: true,
      onKeyEvent: _handleKey,
      onFocusChange: (hasFocus) {
        if (hasFocus) setState(() => _focusIndex = _enabledIndex);
      },
      onTap: _toggleEnabled,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: focused ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
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
              onChanged: (_) {},
              activeThumbColor: AppColors.primary,
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FocusScope(
      canRequestFocus: true,
      child: AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(
          widget.config == null ? '添加直播源' : '编辑直播源',
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            color: AppColors.textPrimary,
          ),
        ),
        content: SizedBox(
          width: 400,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
            _buildTextField(
              index: _nameIndex,
              controller: _nameController,
              label: '源名称',
            ),
            const SizedBox(height: AppSpacing.md),
            _buildTextField(
              index: _urlIndex,
              controller: _urlController,
              label: 'M3U/M3U8/JSON 地址或内容',
              hint: '支持网络地址或粘贴文本内容',
              maxLines: 4,
              minLines: 2,
            ),
            const SizedBox(height: AppSpacing.sm),
            _buildEnabledSwitch(),
          ],
        ),
      ),
      actions: [
        _buildActionButton(
          index: _cancelIndex,
          label: '取消',
          onTap: () => Navigator.of(context).pop(),
          foregroundColor: AppColors.textSecondary,
          borderColor: AppColors.border,
        ),
        if (widget.onDelete != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            child: _buildActionButton(
              index: _deleteIndex,
              label: '删除',
              onTap: widget.onDelete!,
              foregroundColor: AppColors.error,
              borderColor: AppColors.error,
            ),
          ),
        _buildActionButton(
          index: _saveIndex,
          label: '保存',
          onTap: _save,
          foregroundColor: Colors.white,
          backgroundColor: AppColors.primary,
        ),
      ],
      ),
    );
  }
}
