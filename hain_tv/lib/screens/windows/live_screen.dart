import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/live_channel.dart';
import '../../models/live_source_config.dart';
import '../../services/live_service.dart';
import '../../services/live_source_refresh_notifier.dart';
import '../../theme.dart';
import '../../widgets/tv/focusable.dart';
import '../live_player_screen.dart';
import 'live_source_manager_screen.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';
import '../../services/user_data_service.dart';

/// 频道预览缓存条目：保存某直播源已拉取的频道列表及其过期时间。
class _PreviewCacheEntry {
  final List<LiveChannel>? channels;
  final DateTime expiry;
  _PreviewCacheEntry({required this.channels, required this.expiry});
}

/// Windows 直播首页：左侧直播源列表，右侧频道预览，顶部功能选项行。
///
/// 与 TV 版布局一致，但不提供二维码；支持鼠标点击与键盘（含 ESC）操作。
class WindowsLiveScreen extends StatefulWidget {
  const WindowsLiveScreen({super.key});

  @override
  State<WindowsLiveScreen> createState() => WindowsLiveScreenState();
}

class WindowsLiveScreenState extends State<WindowsLiveScreen> {
  List<LiveSourceConfig> _sources = [];
  bool _loading = true;
  String? _error;
  int _focusedIndex = 0;

  // 频道预览
  List<LiveChannel>? _previewChannels;
  bool _loadingPreview = false;
  int? _previewSourceIndex;
  // 频道预览缓存：按“直播源缓存时间”保鲜，切换回已缓存源时不重新拉取。
  final Map<int, _PreviewCacheEntry> _previewCache = {};

  // 焦点与滚动
  final List<FocusNode> _sourceFocusNodes = [];
  final _listScrollController = ScrollController();
  final _previewScrollController = ScrollController();
  final _manageBtnFocusNode = FocusNode();
  final _previewFocusNode = FocusNode();
  bool _focusInPreview = false;

  void requestListFocus() {
    _manageBtnFocusNode.requestFocus();
  }

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
    // 命中有效缓存：直接复用，不再联网拉取。
    final cached = _previewCache[index];
    if (cached != null && cached.expiry.isAfter(DateTime.now())) {
      if (mounted) setState(() {
        _previewSourceIndex = index;
        _previewChannels = cached.channels;
        _loadingPreview = false;
      });
      return;
    }

    setState(() {
      _loadingPreview = true;
      _previewSourceIndex = index;
    });

    final source = _sources[index];
    final response = await LiveService.loadChannelsForSource(source);
    if (!mounted) return;

    final channels = response.success ? (response.data ?? []) : null;
    final hours = await UserDataService.getLiveSourceCacheHours();
    _previewCache[index] = _PreviewCacheEntry(
      channels: channels,
      expiry: DateTime.now().add(Duration(hours: hours)),
    );
    if (mounted) setState(() {
      _loadingPreview = false;
      _previewChannels = channels;
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

  void _navigateToSourceManager() {
    Navigator.of(context)
        .push(
          MaterialPageRoute(
            builder: (_) => const WindowsLiveSourceManagerScreen(),
          ),
        )
        .then((_) => _loadSources());
  }

  KeyEventResult _handleRootKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      if (Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        return KeyEventResult.handled;
      }
      if (_focusInPreview) {
        setState(() => _focusInPreview = false);
        if (_sourceFocusNodes.isNotEmpty) {
          _sourceFocusNodes[_focusedIndex].requestFocus();
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  void dispose() {
    LiveSourceRefreshNotifier.instance.removeListener(_onSettingsChanged);
    for (final node in _sourceFocusNodes) {
      node.dispose();
    }
    _manageBtnFocusNode.dispose();
    _previewFocusNode.dispose();
    _listScrollController.dispose();
    _previewScrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _handleRootKey,
      child: Scaffold(
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
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: 56,
      color: AppColors.bgSurface,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      alignment: Alignment.centerLeft,
      child: Text(
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
      alignment: Alignment.centerRight,
      child: FocusableWidget(
        focusNode: _manageBtnFocusNode,
        onTap: _navigateToSourceManager,
        consumeDirectionalKeys: true,
        onKeyEvent: (node, event) {
          if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
            return KeyEventResult.ignored;
          }
          switch (event.logicalKey) {
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
            default:
              return KeyEventResult.ignored;
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: AppColors.primary,
            borderRadius: BorderRadius.circular(AppRadius.sm),
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.settings, size: 16, color: Colors.white),
              SizedBox(width: AppSpacing.xs),
              Text(
                '源管理',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 13,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(
        child: TechLoadingIndicator(),
      );
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _error!,
              style: TextStyle(
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

    return Row(
      children: [
        SizedBox(
          width: 360,
          child: _buildSourceList(),
        ),
        Container(width: 1, color: AppColors.border),
        Expanded(child: _buildPreview()),
      ],
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.live_tv,
            size: 48,
            color: AppColors.textMuted,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            '暂无可用直播源',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.md),
          ElevatedButton.icon(
            onPressed: _navigateToSourceManager,
            icon: const Icon(Icons.settings_input_antenna, size: 16),
            label: const Text('管理直播源'),
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
    final highlighted = _isSourceHighlighted(index);

    KeyEventResult handleKey(FocusNode n, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      switch (event.logicalKey) {
        case LogicalKeyboardKey.arrowUp:
          if (index == 0) {
            setState(() => _focusInPreview = false);
            _manageBtnFocusNode.requestFocus();
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
        case LogicalKeyboardKey.enter:
        case LogicalKeyboardKey.select:
          _playSource(index);
          return KeyEventResult.handled;
        default:
          return KeyEventResult.ignored;
      }
    }

    return FocusableWidget(
      focusNode: node,
      onTap: () => _loadPreview(index),
      consumeDirectionalKeys: true,
      padding: EdgeInsets.zero,
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
      child: _WindowsSourceItemContent(
        source: source,
        highlighted: highlighted,
        onPlay: () => _playSource(index),
      ),
    );
  }

  bool _isSourceHighlighted(int index) {
    if (index != _focusedIndex) return false;
    return _focusInPreview || _sourceFocusNodes[index].hasFocus;
  }

  Widget _buildPreview() {
    if (_loadingPreview) {
      return const Center(
        child: TechLoadingIndicator(),
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
            !_manageBtnFocusNode.hasFocus) {
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
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.md),
              color: AppColors.bgSurface,
              child: Row(
                children: [
                  Icon(
                    Icons.list_alt,
                    size: 16,
                    color: AppColors.textSecondary,
                  ),
                  const SizedBox(width: AppSpacing.xs),
                  Text(
                    '频道预览 — ${_sources[_focusedIndex].name}',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${channels.length} 个频道',
                    style: TextStyle(
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
        style: TextStyle(
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
              width: 28,
              height: 28,
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
                  errorBuilder: (_, __, ___) => Icon(
                    Icons.tv,
                    size: 14,
                    color: AppColors.textMuted,
                  ),
                ),
              ),
            )
          else
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: AppSpacing.sm),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(4),
                color: AppColors.bgSurface,
              ),
              child: Icon(
                Icons.tv,
                size: 14,
                color: AppColors.textMuted,
              ),
            ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  channel.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 13,
                    color: AppColors.textSecondary,
                  ),
                ),
                if (channel.program != null && channel.program!.isNotEmpty)
                  Text(
                    channel.program!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 11,
                      color: AppColors.textMuted,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _WindowsSourceItemContent extends StatelessWidget {
  final LiveSourceConfig source;
  final bool highlighted;
  final VoidCallback? onPlay;

  const _WindowsSourceItemContent({
    required this.source,
    required this.highlighted,
    this.onPlay,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
      margin: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs,
      ),
      decoration: BoxDecoration(
        color: highlighted
            ? AppColors.primary.withValues(alpha: 0.15)
            : AppColors.bgSurface,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(
          color: AppColors.border,
          width: 1,
        ),
      ),
      child: Row(
        children: [
          _WindowsSourceTag(
            source.isBuiltin ? '服务器' : '本地',
            source.isBuiltin ? AppColors.primary : AppColors.success,
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
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
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: AppColors.textMuted,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          if (onPlay != null)
            IconButton(
              icon: const Icon(Icons.play_arrow, size: 22),
              color: AppColors.primary,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(
                minWidth: 32,
                minHeight: 32,
              ),
              tooltip: '播放',
              onPressed: onPlay,
            ),
        ],
      ),
    );
  }
}

class _WindowsSourceTag extends StatelessWidget {
  final String text;
  final Color color;

  const _WindowsSourceTag(this.text, this.color);

  @override
  Widget build(BuildContext context) {
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
}
