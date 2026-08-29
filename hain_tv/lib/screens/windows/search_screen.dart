import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/models/search_result.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/local_storage_service.dart';
import 'package:hain_tv/services/remote_input_service.dart';
import 'package:hain_tv/services/search_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/utils/windows_logger.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';
import 'detail_screen.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

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
  final _pageScrollController = ScrollController();
  BoxConstraints? _resultGridConstraints;
  int _resultCrossAxisCount = 4;
  int _historyCrossAxisCount = 3;

  bool _loading = false;
  String? _error;
  String? _progressText;
  List<SearchResult> _results = [];
  List<String> _searchHistory = [];
  http.Client? _searchClient;

  // Windows 电脑版使用键盘输入，不需要手机扫码输入。
  final bool _hasQrInput = !DeviceUtils.isWindows;
  final _remoteInputService = RemoteInputService();
  StreamSubscription<String>? _remoteInputSub;
  bool _qrDialogShowing = false;

  void requestSearchBoxFocus() {
    _focusNode.requestFocus();
  }

  @override
  void initState() {
    super.initState();
    if (_hasQrInput) {
      _setupRemoteInput();
    }
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
    _searchClient?.close();
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
    _pageScrollController.dispose();
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

  void _scrollToTop() {
    if (_pageScrollController.hasClients) {
      _pageScrollController.animateTo(
        0,
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _syncResultFocusNodes() {
    while (_resultFocusNodes.length < _results.length) {
      _resultFocusNodes.add(FocusNode());
    }
    if (_resultFocusNodes.length > _results.length) {
      final removed = _resultFocusNodes.sublist(_results.length);
      _resultFocusNodes.removeRange(_results.length, _resultFocusNodes.length);
      // 延迟释放，避免旧的 FocusableWidget 仍在树上时 dispose 已挂载的节点。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final node in removed) {
          node.dispose();
        }
      });
    }
  }

  Future<void> _search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;

    // 取消上一个未完成的搜索请求
    _searchClient?.close();
    final client = http.Client();
    _searchClient = client;

    setState(() {
      _loading = true;
      _error = null;
      _progressText = '正在搜索...';
      _results = [];
    });

    try {
      WindowsLogger.log('WindowsSearchScreen', '开始保存搜索历史 "$trimmed"');
      await LocalStorageService.addSearchHistory(trimmed);
      WindowsLogger.log('WindowsSearchScreen', '搜索历史保存完成');
      await _loadSearchHistory();
    } catch (e, stack) {
      WindowsLogger.log('WindowsSearchScreen', '搜索历史保存异常 $e\n$stack');
    }

    WindowsLogger.log('WindowsSearchScreen', '开始搜索 "$trimmed"');
    try {
      final response = await SearchService.search(
        keyword: trimmed,
        cancelClient: client,
        fuzzy: true,
        onProgress: (results, progressText) {
          if (mounted && _searchClient == client) {
            _syncResultFocusNodes();
            setState(() {
              _results = results;
              _progressText = progressText;
            });
          }
        },
      );
      WindowsLogger.log(
        'WindowsSearchScreen',
        '搜索 "$trimmed" 结果 success=${response.success}, '
        'count=${response.data?.length ?? 0}, message=${response.message}',
      );
      if (mounted && _searchClient == client) {
        setState(() {
          _loading = false;
          _progressText = null;
          if (response.success) {
            _results = response.data ?? [];
          } else {
            _error = response.message;
          }
          _syncResultFocusNodes();
        });
      }
    } catch (e, stack) {
      WindowsLogger.log('WindowsSearchScreen', '搜索异常 $e\n$stack');
      if (mounted && _searchClient == client) {
        setState(() {
          _loading = false;
          _progressText = null;
          _error = '搜索异常: $e';
        });
      }
    } finally {
      if (_searchClient == client) {
        client.close();
        _searchClient = null;
      }
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
      MaterialPageRoute(builder: (_) => DetailScreen.fromSearchResult(result)),
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
          title: Text(
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
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '或访问 $url',
                    style: TextStyle(
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
                    child: TechLoadingIndicator(strokeWidth: 2),
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

  int get _effectiveResultCrossAxisCount {
    final constraints = _resultGridConstraints;
    if (constraints != null) {
      return _computeCrossAxisCount(constraints.maxWidth);
    }
    return _resultCrossAxisCount;
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
  bool get _focusInQr => _hasQrInput && _qrFocusNode.hasFocus;
  bool get _focusInHistory => _currentHistoryIndex != null;
  bool get _focusInResults => _currentResultIndex != null;
  bool get _focusInSearchPage =>
      _focusInSearchBox || _focusInQr || _focusInHistory || _focusInResults;

  /// 全局硬件按键兜底处理。
  ///
  /// 搜索框（TextField）会消耗方向键事件，外层 Focus 的 onKeyEvent 无法收到，
  /// 因此通过 HardwareKeyboard 层面监听，确保 TV 遥控器方向键能按预期在各个区域移动。
  /// 回车键交给 Focus.onKeyEvent 处理，避免全局与 Focus 重复触发搜索。
  bool _handleHardwareKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    // 仅在本页面获得焦点时处理，避免影响顶部导航栏或其他页面
    if (!_focusInSearchPage) return false;

    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.numpadEnter) {
      return false;
    }

    return _handleDirectionKey(key) == _KeyAction.handled;
  }

  _KeyAction _handleDirectionKey(LogicalKeyboardKey key) {
    final resultCrossAxisCount = _effectiveResultCrossAxisCount;
    final historyCols = _historyCrossAxisCount;

    // 回车：搜索框内执行搜索，避免被外层导航消费。
    if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.numpadEnter) {
      if (_focusInSearchBox) {
        _search(_controller.text);
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按右：搜索框→二维码（TV 版）；搜索框/历史→搜索结果第一项
    if (key == LogicalKeyboardKey.arrowRight) {
      if (_focusInSearchBox) {
        if (_hasQrInput) {
          _qrFocusNode.requestFocus();
          return _KeyAction.handled;
        }
        if (_resultFocusNodes.isNotEmpty) {
          _resultFocusNodes.first.requestFocus();
          return _KeyAction.handled;
        }
        return _KeyAction.ignored;
      }
      if (_focusInHistory) {
        final idx = _currentHistoryIndex!;
        if ((idx + 1) % historyCols != 0 &&
            idx + 1 < _historyFocusNodes.length) {
          _historyFocusNodes[idx + 1].requestFocus();
        }
        return _KeyAction.handled;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        if ((idx + 1) % resultCrossAxisCount != 0 &&
            idx + 1 < _resultFocusNodes.length) {
          _resultFocusNodes[idx + 1].requestFocus();
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按左：二维码→搜索框（TV 版）；结果/历史网格内横向移动（首个海报左键不再回到搜索框）
    if (key == LogicalKeyboardKey.arrowLeft) {
      if (_focusInQr) {
        _focusNode.requestFocus();
        return _KeyAction.handled;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        if (idx % resultCrossAxisCount > 0) {
          _resultFocusNodes[idx - 1].requestFocus();
        }
        return _KeyAction.handled;
      }
      if (_focusInHistory) {
        final idx = _currentHistoryIndex!;
        if (idx % historyCols > 0) {
          _historyFocusNodes[idx - 1].requestFocus();
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按下
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_focusInSearchBox || _focusInQr) {
        if (_historyFocusNodes.isNotEmpty) {
          _historyFocusNodes.first.requestFocus();
          return _KeyAction.handled;
        }
        if (_resultFocusNodes.isNotEmpty) {
          _resultFocusNodes.first.requestFocus();
          return _KeyAction.handled;
        }
        return _KeyAction.ignored;
      }
      if (_focusInHistory) {
        final idx = _currentHistoryIndex!;
        final currentRow = idx ~/ historyCols;
        final lastRow =
            (_historyFocusNodes.length - 1) ~/ historyCols;
        if (currentRow < lastRow) {
          final nextIdx = idx + historyCols;
          if (nextIdx < _historyFocusNodes.length) {
            _historyFocusNodes[nextIdx].requestFocus();
          }
        } else if (_resultFocusNodes.isNotEmpty) {
          _resultFocusNodes.first.requestFocus();
        }
        return _KeyAction.handled;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        final nextIdx = idx + resultCrossAxisCount;
        if (nextIdx < _resultFocusNodes.length) {
          _resultFocusNodes[nextIdx].requestFocus();
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    // 按上
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_focusInSearchBox || _focusInQr) {
        // 将焦点交回顶部导航栏（TvShell 的搜索项）
        return _KeyAction.ignored;
      }
      if (_focusInResults) {
        final idx = _currentResultIndex!;
        if (idx >= resultCrossAxisCount) {
          _resultFocusNodes[idx - resultCrossAxisCount].requestFocus();
        } else {
          // 在结果第一行，按上进入搜索历史第一行第一个
          if (_historyFocusNodes.isNotEmpty) {
            _historyFocusNodes.first.requestFocus();
          } else {
            _focusNode.requestFocus();
          }
          _scrollToTop();
        }
        return _KeyAction.handled;
      }
      if (_focusInHistory) {
        final idx = _currentHistoryIndex!;
        final prevIdx = idx - historyCols;
        if (prevIdx >= 0) {
          _historyFocusNodes[prevIdx].requestFocus();
        } else {
          _focusNode.requestFocus();
          _scrollToTop();
        }
        return _KeyAction.handled;
      }
      return _KeyAction.ignored;
    }

    return _KeyAction.ignored;
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
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
        padding: const EdgeInsets.all(AppSpacing.md),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final historyCols = _computeHistoryCrossAxisCount(
              constraints.maxWidth,
            );
            // 直接同步更新，避免按键处理时读到过期的列数。
            _historyCrossAxisCount = historyCols;
            return SingleChildScrollView(
              controller: _pageScrollController,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 第一行：搜索框 + 手机扫码（TV 版）
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(child: _buildSearchBox()),
                      if (_hasQrInput) ...[
                        const SizedBox(width: AppSpacing.md),
                        _buildQrButton(),
                      ],
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  // 第二行：搜索历史（两行）
                  _buildHistorySection(constraints.maxWidth, historyCols),
                  const SizedBox(height: AppSpacing.md),
                  // 第三行：搜索结果
                  _buildResultsArea(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSearchBox() {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.sm),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            '搜索',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: AppColors.textSecondary,
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: TextField(
              controller: _controller,
              focusNode: _focusNode,
              autofocus: true,
              style: TextStyle(color: AppColors.textPrimary),
              textInputAction: TextInputAction.search,
              onSubmitted: (value) => _search(value),
              decoration: InputDecoration(
                hintText: '输入关键词',
                hintStyle: TextStyle(color: AppColors.textMuted),
                suffixIcon: ValueListenableBuilder<TextEditingValue>(
                  valueListenable: _controller,
                  builder: (context, value, child) {
                    final hasText = value.text.isNotEmpty;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (hasText)
                          IconButton(
                            icon: Icon(
                              Icons.clear,
                              color: AppColors.textSecondary,
                              size: 18,
                            ),
                            onPressed: _clearInput,
                          ),
                        IconButton(
                          icon: Icon(
                            Icons.search,
                            color: AppColors.textSecondary,
                            size: 18,
                          ),
                          onPressed: () => _search(_controller.text),
                        ),
                      ],
                    );
                  },
                ),
                filled: true,
                fillColor: AppColors.bgApp,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  borderSide: BorderSide(
                    color: AppColors.primary,
                    width: 2,
                  ),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: AppSpacing.xs,
                  horizontal: AppSpacing.sm,
                ),
              ),
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
      onKeyEvent: _handleKeyEvent,
      child: Container(
        width: 100,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: AppColors.primaryTint,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: AppColors.primary),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.qr_code_scanner, color: AppColors.primary, size: 24),
            SizedBox(height: AppSpacing.xs),
            Text(
              '手机输入',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.primary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistorySection(double width, int crossAxisCount) {
    const crossSpacing = AppSpacing.sm;
    const mainSpacing = AppSpacing.sm;
    const padding = AppSpacing.sm;
    const targetItemHeight = 40.0;
    const titleWidth = 90.0;
    final availableForItems = width - padding * 2 - titleWidth - AppSpacing.sm;
    final itemWidth =
        (availableForItems - (crossAxisCount - 1) * crossSpacing) /
        crossAxisCount;
    final rowCount = _searchHistory.isEmpty
        ? 1
        : ((_searchHistory.length + crossAxisCount - 1) ~/ crossAxisCount);
    final sectionHeight = padding * 2 +
        rowCount * targetItemHeight +
        (rowCount > 1 ? (rowCount - 1) * mainSpacing : 0);

    return Container(
      height: sectionHeight,
      padding: const EdgeInsets.all(padding),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: titleWidth,
            child: Row(
              children: [
                Icon(
                  Icons.history,
                  color: AppColors.textSecondary,
                  size: 16,
                ),
                const SizedBox(width: AppSpacing.xs),
                Expanded(
                  child: Text(
                    '近期搜索',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          Expanded(
            child: _searchHistory.isEmpty
                ? Center(
                    child: Text(
                      '暂无近期搜索',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        fontSize: 13,
                        color: AppColors.textMuted,
                      ),
                    ),
                  )
                : GridView.builder(
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      crossAxisSpacing: crossSpacing,
                      mainAxisSpacing: mainSpacing,
                      childAspectRatio: itemWidth / targetItemHeight,
                    ),
                    itemCount: _searchHistory.length,
                    itemBuilder: (context, index) {
                      final query = _searchHistory[index];
                      return FocusableWidget(
                        focusNode: _historyFocusNodes[index],
                        onTap: () => _search(query),
                        onKeyEvent: _handleKeyEvent,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: AppSpacing.sm,
                            vertical: AppSpacing.xs,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.bgApp,
                            borderRadius: BorderRadius.circular(AppRadius.sm),
                            border: Border.all(color: AppColors.border),
                          ),
                          child: Center(
                            child: Text(
                              query,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                fontFamily: 'NotoSansSC',
                                fontSize: 13,
                                color: AppColors.textPrimary,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsArea() {
    if (_loading && _results.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TechLoadingIndicator(),
            const SizedBox(height: AppSpacing.md),
            Text(
              _progressText ?? '正在搜索...',
              style: TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_error != null && _results.isEmpty) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    if (_results.isEmpty && _controller.text.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: AppColors.textMuted),
            const SizedBox(height: AppSpacing.md),
            Text(
              '输入关键词开始搜索',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 16,
                color: AppColors.textMuted,
              ),
            ),
            const SizedBox(height: AppSpacing.sm),
            if (_hasQrInput)
              Text(
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
      return Center(
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
        // 直接同步更新，避免按键处理时读到过期的列数。
        _resultCrossAxisCount = count;
        return Column(
          children: [
            if (_loading && _progressText != null)
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: TechLoadingIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    Text(
                      _progressText!,
                      style: TextStyle(
                        color: AppColors.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
            TvPosterGrid(
              shrinkWrap: true,
              items: items,
              crossAxisCount: count,
              itemFocusNodes: _resultFocusNodes.isNotEmpty
                  ? _resultFocusNodes
                  : null,
              autofocusFirstItem: false,
              onKeyEvent: _handleKeyEvent,
            ),
          ],
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

  int _computeHistoryCrossAxisCount(double width) {
    const minItemWidth = 120.0;
    const crossSpacing = AppSpacing.sm;
    const padding = AppSpacing.sm * 2;
    const titleWidth = 90.0;
    const titleSpacing = AppSpacing.sm;
    final available = width - padding - titleWidth - titleSpacing;
    int count = ((available + crossSpacing) / (minItemWidth + crossSpacing))
        .floor();
    // 保证 6 条历史能在两行内完整显示，避免第三行被截断
    return count.clamp(3, 6);
  }
}
