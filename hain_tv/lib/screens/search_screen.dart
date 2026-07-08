import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import '../focus/focusable.dart';
import '../models/search_result.dart';
import '../services/local_storage_service.dart';
import '../services/remote_input_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import '../widgets/tv_grid.dart';
import 'detail_screen.dart';

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});

  @override
  State<SearchScreen> createState() => SearchScreenState();
}

enum _KeyAction { handled, ignored }

class SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _qrFocusNode = FocusNode();
  final List<FocusNode> _historyFocusNodes = [];
  final List<FocusNode> _resultFocusNodes = [];
  final _resultScrollController = ScrollController();
  BoxConstraints? _resultGridConstraints;
  int _resultCrossAxisCount = 4;

  bool _loading = false;
  String? _error;
  List<SearchResult> _results = [];
  List<String> _searchHistory = [];

  final _remoteInputService = RemoteInputService();
  StreamSubscription<String>? _remoteInputSub;
  bool _qrDialogShowing = false;

  void requestSearchBoxFocus() {
    _focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    _setupRemoteInput();
    _loadSearchHistory();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
      }
    });
  }

  void _setupRemoteInput() {
    _remoteInputSub = _remoteInputService.onMessage.listen((message) {
      if (mounted) {
        _controller.text = message;
        _controller.selection = TextSelection.collapsed(
          offset: _controller.text.length,
        );
        _search(message);
        if (_qrDialogShowing && Navigator.of(context).canPop()) {
          Navigator.of(context).pop();
          setState(() => _qrDialogShowing = false);
        }
      }
    });
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    _controller.dispose();
    _focusNode.dispose();
    _qrFocusNode.dispose();
    for (final node in _historyFocusNodes) {
      node.dispose();
    }
    for (final node in _resultFocusNodes) {
      node.dispose();
    }
    _resultScrollController.dispose();
    _remoteInputSub?.cancel();
    _remoteInputService.dispose();
    super.dispose();
  }

  Future<void> _loadSearchHistory() async {
    final history = await LocalStorageService.getSearchHistory();
    setState(() => _searchHistory = history.take(6).toList());
    _syncHistoryFocusNodes();
  }

  void _syncHistoryFocusNodes() {
    while (_historyFocusNodes.length < _searchHistory.length) {
      _historyFocusNodes.add(FocusNode());
    }
    while (_historyFocusNodes.length > _searchHistory.length) {
      _historyFocusNodes.removeLast().dispose();
    }
  }

  void _syncResultFocusNodes() {
    while (_resultFocusNodes.length < _results.length) {
      _resultFocusNodes.add(FocusNode());
    }
    while (_resultFocusNodes.length > _results.length) {
      _resultFocusNodes.removeLast().dispose();
    }
  }

  Future<void> _search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;

    setState(() {
      _loading = true;
      _error = null;
      _results = [];
    });

    await LocalStorageService.addSearchHistory(trimmed);
    _loadSearchHistory();

    final response = await SearchService.search(keyword: trimmed);
    if (mounted) {
      setState(() {
        _loading = false;
        if (response.success) {
          _results = response.data ?? [];
        } else {
          _error = response.message;
        }
        _syncResultFocusNodes();
      });
    }
  }

  void _clearInput() {
    setState(() {
      _controller.clear();
      _results = [];
      _error = null;
    });
  }

  Future<void> _openDetail(SearchResult result) async {
    await LocalStorageService.addSearchHistory(result.title);
    _loadSearchHistory();
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DetailScreen.fromSearchResult(result),
      ),
    );
  }

  Future<void> _showQrDialog() async {
    if (_qrDialogShowing) return;
    setState(() => _qrDialogShowing = true);

    String? url;
    String? error;
    try {
      url = await _remoteInputService.startServer();
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
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: const Text(
            '手机扫码输入',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Text(
                    error,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: Colors.redAccent,
                    ),
                  )
                else if (url != null) ...[
                  Container(
                    width: 200,
                    height: 200,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: QrImageView(
                      data: url,
                      version: QrVersions.auto,
                      size: 180,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '使用手机扫描上方二维码',
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '或访问 $url',
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ] else
                  const SizedBox(
                    width: 40,
                    height: 40,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
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
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '关闭',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
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

  int? get _currentHistoryIndex {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return null;
    for (int i = 0; i < _historyFocusNodes.length; i++) {
      if (_historyFocusNodes[i] == focus) return i;
    }
    return null;
  }

  int? get _currentResultIndex {
    final focus = FocusManager.instance.primaryFocus;
    if (focus == null) return null;
    for (int i = 0; i < _resultFocusNodes.length; i++) {
      if (_resultFocusNodes[i] == focus) return i;
    }
    return null;
  }

  bool get _focusInSearchBox => _focusNode.hasFocus;
  bool get _focusInQr => _qrFocusNode.hasFocus;
  bool get _focusInHistory => _currentHistoryIndex != null;
  bool get _focusInResults => _currentResultIndex != null;
  bool get _focusInSearchPage =>
      _focusInSearchBox ||
      _focusInQr ||
      _focusInHistory ||
      _focusInResults;

  /// 全局硬件按键兜底处理。
  ///
  /// 搜索框（TextField）会消耗方向键事件，外层 Focus 的 onKeyEvent 无法收到，
  /// 因此通过 HardwareKeyboard 层面监听，确保 TV 遥控器方向键能按预期在各个区域移动。
  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return false;

    // 仅在本页面获得焦点时处理，避免影响顶部导航栏或其他页面
    if (!_focusInSearchPage) return false;

    return _handleDirectionKey(event.logicalKey) == _KeyAction.handled;
  }

  _KeyAction _handleDirectionKey(LogicalKeyboardKey key) {
    // 按右：左侧任意位置移动到搜索结果第一项（有结果时）
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_focusInSearchBox || _focusInQr || _focusInHistory) {
        if (_resultFocusNodes.isNotEmpty) {
          _resultFocusNodes.first.requestFocus();
          return _KeyAction.handled;
        }
        return _KeyAction.ignored;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        if (idx % _resultCrossAxisCount != _resultCrossAxisCount - 1 &&
            idx + 1 < _resultFocusNodes.length) {
          _focusResultIndex(idx + 1, _resultCrossAxisCount);
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按左：搜索结果任意行最左列回到搜索框
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        if (idx % _resultCrossAxisCount == 0) {
          _focusNode.requestFocus();
        } else {
          _focusResultIndex(idx - 1, _resultCrossAxisCount);
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按下
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focusInSearchBox) {
        _qrFocusNode.requestFocus();
        return _KeyAction.handled;
      }
      if (_focusInQr) {
        if (_historyFocusNodes.isNotEmpty) {
          _historyFocusNodes.first.requestFocus();
          return _KeyAction.handled;
        }
        return _KeyAction.ignored;
      }
      if (_focusInHistory) {
        final idx = _currentHistoryIndex!;
        if (idx < _historyFocusNodes.length - 1) {
          _historyFocusNodes[idx + 1].requestFocus();
        } else if (_resultFocusNodes.isNotEmpty) {
          _resultFocusNodes.first.requestFocus();
        }
        return _KeyAction.handled;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        final next = idx + _resultCrossAxisCount;
        if (next < _resultFocusNodes.length) {
          _focusResultIndex(next, _resultCrossAxisCount);
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按上
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_focusInQr) {
        _focusNode.requestFocus();
        return _KeyAction.handled;
      }
      if (_focusInHistory) {
        final idx = _currentHistoryIndex!;
        if (idx > 0) {
          _historyFocusNodes[idx - 1].requestFocus();
        } else {
          _qrFocusNode.requestFocus();
        }
        return _KeyAction.handled;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        if (idx >= _resultCrossAxisCount) {
          _focusResultIndex(idx - _resultCrossAxisCount, _resultCrossAxisCount);
          return _KeyAction.handled;
        }
        // 位于结果网格第一行，把回到顶部导航栏交给 TvShell 处理
        return _KeyAction.ignored;
      }
      return _KeyAction.ignored;
    }

    return _KeyAction.ignored;
  }

  void _focusResultIndex(int target, int crossAxisCount) {
    if (target < 0 || target >= _resultFocusNodes.length) return;

    final constraints = _resultGridConstraints;
    if (constraints != null && _resultScrollController.hasClients) {
      const horizontalPadding = AppSpacing.lg * 2;
      const crossSpacing = AppSpacing.md;
      const mainSpacing = AppSpacing.lg;
      const aspectRatio = 0.55;

      final availableWidth = constraints.maxWidth - horizontalPadding;
      final itemWidth =
          (availableWidth - (crossAxisCount - 1) * crossSpacing) / crossAxisCount;
      final itemHeight = itemWidth / aspectRatio;
      final rowHeight = itemHeight + mainSpacing;

      final targetRow = target ~/ crossAxisCount;
      final targetTop = AppSpacing.lg + targetRow * rowHeight;
      final targetBottom = targetTop + itemHeight;

      final viewportHeight = constraints.maxHeight;
      final currentOffset = _resultScrollController.offset;
      final viewportBottom = currentOffset + viewportHeight;

      double? targetOffset;
      if (targetTop < currentOffset) {
        targetOffset = targetTop;
      } else if (targetBottom > viewportBottom) {
        targetOffset = targetBottom - viewportHeight;
      }

      if (targetOffset != null) {
        _resultScrollController.animateTo(
          targetOffset.clamp(
            _resultScrollController.position.minScrollExtent,
            _resultScrollController.position.maxScrollExtent,
          ),
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    }

    _resultFocusNodes[target].requestFocus();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final action = _handleDirectionKey(event.logicalKey);
    return action == _KeyAction.handled
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 左列：搜索框 + 手机扫码 + 搜索历史
            SizedBox(
              width: 320,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _buildSearchBox(),
                  const SizedBox(height: AppSpacing.lg),
                  _buildQrButton(),
                  const SizedBox(height: AppSpacing.lg),
                  Expanded(child: _buildHistorySection()),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            // 右列：搜索结果
            Expanded(child: _buildResultsArea()),
          ],
        ),
      ),
    );
  }

  Widget _buildSearchBox() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '搜索',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            style: const TextStyle(color: AppColors.textPrimary),
            textInputAction: TextInputAction.search,
            onSubmitted: (value) => _search(value),
            decoration: InputDecoration(
              hintText: '输入关键词',
              hintStyle: const TextStyle(color: AppColors.textMuted),
              prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
              suffixIcon: _controller.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(Icons.clear, color: AppColors.textSecondary),
                      onPressed: _clearInput,
                    )
                  : null,
              filled: true,
              fillColor: AppColors.bgApp,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: BorderSide.none,
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AppRadius.md),
                borderSide: const BorderSide(color: AppColors.primary, width: 2),
              ),
              contentPadding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQrButton() {
    return FocusableWidget(
      focusNode: _qrFocusNode,
      onTap: _showQrDialog,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.primaryTint,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.primary),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.qr_code_scanner,
              color: AppColors.primary,
              size: 40,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              '手机扫码输入',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
            const SizedBox(height: AppSpacing.xs),
            Text(
              '扫描二维码后用手机输入搜索',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 12,
                color: AppColors.textSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection() {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.md),
        decoration: BoxDecoration(
          color: AppColors.bgElevated,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
          Row(
            children: [
              const Icon(Icons.history, color: AppColors.textSecondary, size: 16),
              const SizedBox(width: AppSpacing.xs),
              const Text(
                '近期搜索',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),
          Expanded(
            child: _searchHistory.isEmpty
                ? const Center(
                    child: Text(
                      '暂无近期搜索',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (int index = 0;
                            index < _searchHistory.length;
                            index++) ...[
                          Builder(
                            builder: (context) {
                              final query = _searchHistory[index];
                              return FocusableWidget(
                                focusNode: _historyFocusNodes[index],
                                onTap: () => _search(query),
                                onKeyEvent: _handleKeyEvent,
                                onFocusChange: (focused) {
                                  if (focused) {
                                    WidgetsBinding.instance
                                        .addPostFrameCallback((_) {
                                      if (context.mounted) {
                                        Scrollable.ensureVisible(
                                          context,
                                          duration: const Duration(
                                              milliseconds: 200),
                                          curve: Curves.easeOut,
                                          alignment: 0.5,
                                        );
                                      }
                                    });
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.md,
                                    vertical: AppSpacing.sm,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppColors.bgApp,
                                    borderRadius:
                                        BorderRadius.circular(AppRadius.sm),
                                    border:
                                        Border.all(color: AppColors.border),
                                  ),
                                  child: Text(
                                    query,
                                    style: const TextStyle(
                                      fontFamily: 'NotoSansSC',
                                      fontSize: 13,
                                      color: AppColors.textPrimary,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                          if (index < _searchHistory.length - 1)
                            const SizedBox(height: AppSpacing.sm),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
  }

  Widget _buildResultsArea() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    if (_results.isEmpty && _controller.text.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.search,
              size: 64,
              color: AppColors.textMuted,
            ),
            const SizedBox(height: AppSpacing.md),
            const Text(
              '输入关键词开始搜索',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 16,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            const Text(
              '或使用手机扫码输入',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty && !_loading) {
      return const Center(
        child: Text(
          '未找到相关结果',
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    final items = _results.map((result) {
      return PosterItem(
        id: result.id,
        title: result.title,
        posterUrl: result.poster,
        year: result.year,
        onTap: () => _openDetail(result),
      );
    }).toList();

    return LayoutBuilder(
      builder: (context, constraints) {
        _resultGridConstraints = constraints;
        final count = _computeCrossAxisCount(constraints.maxWidth);
        if (count != _resultCrossAxisCount) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) setState(() => _resultCrossAxisCount = count);
          });
        }
        return TvPosterGrid(
          controller: _resultScrollController,
          items: items,
          crossAxisCount: count,
          itemFocusNodes: _resultFocusNodes.isNotEmpty ? _resultFocusNodes : null,
          autofocusFirstItem: false,
          onKeyEvent: _handleKeyEvent,
        );
      },
    );
  }

  int _computeCrossAxisCount(double width) {
    if (width > 1600) return 8;
    if (width > 1400) return 7;
    if (width > 1100) return 6;
    if (width > 800) return 5;
    if (width > 500) return 4;
    return 3;
  }
}
