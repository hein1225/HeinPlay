import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../models/live_channel.dart';
import '../../models/live_source_config.dart';
import '../../services/live_service.dart';
import '../../services/live_source_refresh_notifier.dart';
import '../../services/remote_input_service.dart';
import '../../theme.dart';
import '../../widgets/tv/focusable.dart';
import '../live_player_screen.dart';
import 'live_source_manager_screen.dart';

/// TV 直播首页：左侧直播源列表，右侧频道预览，顶部功能选项行。
class TvLiveScreen extends StatefulWidget {
  final VoidCallback? onRequestNavFocus;

  const TvLiveScreen({super.key, this.onRequestNavFocus});

  @override
  State<TvLiveScreen> createState() => TvLiveScreenState();
}

class TvLiveScreenState extends State<TvLiveScreen> {
  List<LiveSourceConfig> _sources = [];
  bool _loading = true;
  String? _error;
  int _focusedIndex = 0;

  // 频道预览
  List<LiveChannel>? _previewChannels;
  bool _loadingPreview = false;
  int? _previewSourceIndex;

  // 焦点节点
  final List<FocusNode> _sourceFocusNodes = [];
  final _listScrollController = ScrollController();
  final _previewScrollController = ScrollController();
  final _addBtnFocusNode = FocusNode();
  final _mobileBtnFocusNode = FocusNode();
  final _previewFocusNode = FocusNode();
  bool _focusInPreview = false;

  // 远程输入服务（手机管理二维码）
  final _remoteInputService = RemoteInputService();

  @override
  void initState() {
    super.initState();
    _loadSources();
    LiveSourceRefreshNotifier.instance.addListener(_onSettingsChanged);
  }

  void _onSettingsChanged() {
    if (mounted) _loadSources();
  }

  void requestListFocus() {
    // 从顶部导航栏按下键，焦点先移动到功能行"添加直播源"。
    _addBtnFocusNode.requestFocus();
  }

  /// 直播页内部是否持有焦点（供 tv_shell 判断 UP 导航目标）。
  bool get hasInternalFocus {
    if (_addBtnFocusNode.hasFocus) return true;
    if (_mobileBtnFocusNode.hasFocus) return true;
    if (_previewFocusNode.hasFocus) return true;
    if (_focusInPreview) return true;
    for (final node in _sourceFocusNodes) {
      if (node.hasFocus) return true;
    }
    return false;
  }

  Future<void> _loadSources() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final sources = await LiveService.getAllSources();
      if (!mounted) return;
      setState(() {
        _sources = sources;
        _loading = false;
        _focusedIndex = 0;
      });
      _syncFocusNodes();
      if (sources.isNotEmpty) {
        _loadPreview(0);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '加载直播源失败: $e';
        _loading = false;
      });
    }
  }

  void _syncFocusNodes() {
    while (_sourceFocusNodes.length < _sources.length) {
      _sourceFocusNodes.add(FocusNode());
    }
    while (_sourceFocusNodes.length > _sources.length) {
      _sourceFocusNodes.removeLast().dispose();
    }
  }

  Future<void> _loadPreview(int index) async {
    if (index < 0 || index >= _sources.length) return;
    if (_previewSourceIndex == index && _previewChannels != null) return;

    setState(() {
      _loadingPreview = true;
      _previewSourceIndex = index;
    });

    final source = _sources[index];
    final response = await LiveService.loadChannelsForSource(source);
    if (!mounted) return;

    setState(() {
      _loadingPreview = false;
      _previewChannels = response.success ? (response.data ?? []) : null;
    });
  }

  void _playSource(int index) {
    if (index < 0 || index >= _sources.length) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LivePlayerScreen(source: _sources[index]),
      ),
    );
  }

  void _moveFocus(int delta) {
    final newIndex = (_focusedIndex + delta).clamp(0, _sources.length - 1);
    if (newIndex != _focusedIndex) {
      setState(() {
        _focusedIndex = newIndex;
        _focusInPreview = false;
      });
      _sourceFocusNodes[newIndex].requestFocus();
      _scrollToFocused();
      _loadPreview(newIndex);
    }
  }

  void _scrollPreviewBy(int direction) {
    if (!_previewScrollController.hasClients) return;
    final viewport = _previewScrollController.position.viewportDimension;
    final maxExtent = _previewScrollController.position.maxScrollExtent;
    final current = _previewScrollController.offset;
    final target = (current + direction * viewport * 0.8).clamp(0.0, maxExtent);
    _previewScrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  void _scrollToFocused() {
    if (!_listScrollController.hasClients) return;
    const itemHeight = 64.0;
    final targetOffset = _focusedIndex * itemHeight;
    final viewport = _listScrollController.position.viewportDimension;
    final currentOffset = _listScrollController.offset;
    if (targetOffset < currentOffset ||
        targetOffset + itemHeight > currentOffset + viewport) {
      _listScrollController.animateTo(
        targetOffset.clamp(
          0.0,
          _listScrollController.position.maxScrollExtent,
        ),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _navigateToSourceManager() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const TvLiveSourceManagerScreen(),
          ),
        )
        .then((_) => _loadSources());
  }

  Future<void> _showQrManageDialog() async {
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
                      if (url != null)
                        Container(
                          padding: const EdgeInsets.all(AppSpacing.sm),
                          decoration: BoxDecoration(
                            color: Colors.white,
                            borderRadius:
                                BorderRadius.circular(AppRadius.md),
                          ),
                          child: QrImageView(
                            data: url,
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
                  '关闭',
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
  }

  @override
  void dispose() {
    LiveSourceRefreshNotifier.instance.removeListener(_onSettingsChanged);
    for (final node in _sourceFocusNodes) {
      node.dispose();
    }
    _addBtnFocusNode.dispose();
    _mobileBtnFocusNode.dispose();
    _previewFocusNode.dispose();
    _listScrollController.dispose();
    _previewScrollController.dispose();
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
          _buildFunctionRow(),
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
      alignment: Alignment.centerLeft,
      child: const Text(
        '直播源',
        style: TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }

  Widget _buildFunctionRow() {
    return Container(
      height: 56,
      color: AppColors.bgSurface,
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      child: Row(
        children: [
          _buildFunctionRowButton(
            focusNode: _addBtnFocusNode,
            nextFocusNode: _mobileBtnFocusNode,
            prevFocusNode: null,
            backgroundColor: AppColors.primary,
            foregroundColor: Colors.white,
            borderColor: null,
            icon: Icons.settings,
            label: '管理直播源',
            onTap: _navigateToSourceManager,
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildFunctionRowButton(
            focusNode: _mobileBtnFocusNode,
            nextFocusNode: null,
            prevFocusNode: _addBtnFocusNode,
            backgroundColor: AppColors.bgSurface,
            foregroundColor: AppColors.textSecondary,
            borderColor: AppColors.border,
            icon: Icons.qr_code_scanner,
            label: '手机管理',
            onTap: _showQrManageDialog,
          ),
        ],
      ),
    );
  }

  Widget _buildFunctionRowButton({
    required FocusNode focusNode,
    required FocusNode? nextFocusNode,
    required FocusNode? prevFocusNode,
    required Color backgroundColor,
    required Color foregroundColor,
    required Color? borderColor,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    KeyEventResult handleKey(FocusNode node, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowRight:
          if (nextFocusNode != null) nextFocusNode.requestFocus();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowLeft:
          if (prevFocusNode != null) prevFocusNode.requestFocus();
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          if (_sourceFocusNodes.isNotEmpty) {
            setState(() {
              _focusedIndex = 0;
              _focusInPreview = false;
            });
            _sourceFocusNodes[0].requestFocus();
            _loadPreview(0);
          }
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowUp:
          widget.onRequestNavFocus?.call();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    }

    return FocusableWidget(
      focusNode: focusNode,
      onTap: onTap,
      consumeDirectionalKeys: true,
      onKeyEvent: handleKey,
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: borderColor != null ? Border.all(color: borderColor) : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 16, color: foregroundColor),
            const SizedBox(width: AppSpacing.xs),
            Text(
              label,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                color: foregroundColor,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
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
            FocusableWidget(
              onTap: _loadSources,
              padding: EdgeInsets.zero,
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
                  '重新加载',
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

    if (_sources.isEmpty) {
      return _buildEmpty();
    }

    return Row(
      children: [
        // 左侧：直播源列表
        SizedBox(
          width: 360,
          child: _buildSourceList(),
        ),
        Container(width: 1, color: AppColors.border),
        // 右侧：频道预览
        Expanded(child: _buildPreview()),
      ],
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
          FocusableWidget(
            onTap: _navigateToSourceManager,
            padding: EdgeInsets.zero,
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
                '管理直播源',
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

  Widget _buildSourceList() {
    return ListView.builder(
      controller: _listScrollController,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: _sources.length,
      itemBuilder: (context, index) {
        return _buildSourceItem(_sources[index], index);
      },
    );
  }

  Widget _buildSourceItem(LiveSourceConfig source, int index) {
    final node = _sourceFocusNodes[index];

    KeyEventResult handleKey(FocusNode n, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          if (index == 0) {
            setState(() => _focusInPreview = false);
            _addBtnFocusNode.requestFocus();
            return KeyEventResult.handled;
          }
          _moveFocus(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _moveFocus(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowRight:
          setState(() => _focusInPreview = true);
          _previewFocusNode.requestFocus();
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    }

    return FocusableWidget(
      focusNode: node,
      onTap: () => _playSource(index),
      consumeDirectionalKeys: true,
      onKeyEvent: handleKey,
      onFocusChange: (hasFocus) {
        if (hasFocus) {
          setState(() {
            _focusedIndex = index;
            _focusInPreview = false;
          });
          _loadPreview(index);
        }
      },
      child: _SourceItemContent(
        source: source,
        highlighted: _isSourceHighlighted(index),
      ),
    );
  }

  bool _isSourceHighlighted(int index) {
    if (index != _focusedIndex) return false;
    // 焦点在预览区时，仍高亮当前源；
    // 焦点在源列表项本身时，也高亮当前源；
    // 焦点在功能行或顶部导航时，不高亮源列表项，避免双焦点框。
    return _focusInPreview || _sourceFocusNodes[index].hasFocus;
  }

  Widget _buildPreview() {
    if (_loadingPreview) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    final channels = _previewChannels;
    if (channels == null || channels.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.tv,
              size: 48,
              color: _focusInPreview
                  ? AppColors.textSecondary
                  : AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            Text(
              channels == null ? '暂无频道数据' : '该直播源暂无频道',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: _focusInPreview
                    ? AppColors.textSecondary
                    : AppColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    // 分组展示，保持源文件中的分组顺序，频道使用 Wrap 多列布局
    final grouped = LiveService.groupChannels(channels);
    final groupKeys = grouped.keys.toList();

    KeyEventResult handlePreviewKey(FocusNode node, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          _scrollPreviewBy(-1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowDown:
          _scrollPreviewBy(1);
          return KeyEventResult.handled;
        case LogicalKeyboardKey.arrowLeft:
          setState(() => _focusInPreview = false);
          if (_sourceFocusNodes.isNotEmpty) {
            _sourceFocusNodes[_focusedIndex].requestFocus();
          }
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    }

    return Focus(
      focusNode: _previewFocusNode,
      canRequestFocus: true,
      skipTraversal: true,
      onKeyEvent: handlePreviewKey,
      onFocusChange: (hasFocus) {
        if (hasFocus) {
          setState(() => _focusInPreview = true);
        } else if (!_sourceFocusNodes.any((n) => n.hasFocus) &&
            !_addBtnFocusNode.hasFocus &&
            !_mobileBtnFocusNode.hasFocus) {
          // 焦点离开预览区且不在源列表或功能行时，重置状态
          setState(() => _focusInPreview = false);
        }
      },
      child: Container(
        decoration: BoxDecoration(
          border: _focusInPreview
              ? Border.all(color: AppColors.primary, width: 2)
              : null,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 预览标题
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              color: AppColors.bgSurface,
              child: Row(
                children: [
                  const Icon(
                    Icons.list_alt,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '频道预览 — ${_sources[_focusedIndex].name}',
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${channels.length} 个频道',
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Container(height: 1, color: AppColors.border),
            Expanded(
              child: ListView(
                controller: _previewScrollController,
                padding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.sm,
                  horizontal: AppSpacing.md,
                ),
                children: [
                  for (final group in groupKeys) ...[
                    _buildPreviewHeader(group),
                    Wrap(
                      spacing: AppSpacing.sm,
                      runSpacing: AppSpacing.xs,
                      children: [
                        for (final channel in grouped[group]!)
                          SizedBox(
                            width: 160,
                            child: _buildPreviewChannel(channel),
                          ),
                      ],
                    ),
                    const SizedBox(height: AppSpacing.sm),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPreviewHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(top: AppSpacing.sm, bottom: AppSpacing.xs),
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: AppColors.primary,
        ),
      ),
    );
  }

  Widget _buildPreviewChannel(LiveChannel channel) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          if (channel.logo != null && channel.logo!.isNotEmpty)
            Container(
              width: 24,
              height: 24,
              margin: const EdgeInsets.only(right: AppSpacing.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: AppColors.bgSurface,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: Image.network(
                  channel.logo!,
                  fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => const Icon(
                    Icons.tv,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            ),
          Expanded(
            child: Text(
              channel.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                color: AppColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 直播源列表项的视觉内容，独立成 StatelessWidget 避免焦点状态变化时多余重绘。
class _SourceItemContent extends StatelessWidget {
  final LiveSourceConfig source;
  final bool highlighted;

  const _SourceItemContent({
    required this.source,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.primary.withValues(alpha: 0.15)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(AppRadius.sm),
        border: Border(
          left: BorderSide(
            color: highlighted ? AppColors.primary : Colors.transparent,
            width: 3,
          ),
        ),
      ),
      child: Row(
        children: [
          if (source.isBuiltin)
            _TvLiveScreenTag('服务器', AppColors.primary)
          else
            _TvLiveScreenTag('本地', AppColors.success),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  source.name,
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    color: highlighted
                        ? AppColors.textPrimary
                        : AppColors.textSecondary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  source.isBuiltin
                      ? 'LunaTV 服务端直播源'
                      : (source.url.length > 50
                          ? '${source.url.substring(0, 50)}...'
                          : source.url),
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
          if (highlighted)
            const Padding(
              padding: EdgeInsets.only(left: AppSpacing.xs),
              child: Icon(
                Icons.chevron_right,
                size: 18,
                color: AppColors.primary,
              ),
            ),
        ],
      ),
    );
  }
}

/// 源标签（服务器 / 本地）。
class _TvLiveScreenTag extends StatelessWidget {
  final String text;
  final Color color;

  const _TvLiveScreenTag(this.text, this.color);

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(right: AppSpacing.sm),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.xs,
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
          fontSize: 10,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
