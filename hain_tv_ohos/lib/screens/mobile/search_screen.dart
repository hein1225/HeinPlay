import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:hain_tv/models/search_result.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/services/app_mode_service.dart';
import 'package:hain_tv/services/local_storage_service.dart';
import 'package:hain_tv/services/glass_style_service.dart';
import 'package:hain_tv/services/search_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_poster_grid.dart';
import 'package:hain_tv/widgets/common/video_grid.dart';
import 'package:hain_tv/widgets/common/add_menu_sheet.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class MobileSearchScreen extends StatefulWidget {
  const MobileSearchScreen({super.key});

  @override
  State<MobileSearchScreen> createState() => _MobileSearchScreenState();
}

class _MobileSearchScreenState extends State<MobileSearchScreen> {
  final _controller = TextEditingController();

  bool _loading = false;
  String? _error;
  String? _progressText;
  List<SearchResult> _results = [];
  List<String> _searchHistory = [];
  http.Client? _searchClient;

  @override
  void initState() {
    super.initState();
    _loadSearchHistory();
  }

  @override
  void dispose() {
    _searchClient?.close();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _loadSearchHistory() async {
    final history = await LocalStorageService.getSearchHistory();
    if (mounted) {
      setState(() => _searchHistory = history.take(12).toList());
    }
  }

  /// 游客态（未连接服务器）：搜索依赖服务器内容源，游客态不可用。
  /// 🔴 2026-10-31 上架整改。
  bool get _guest => AppModeService.instance.isGuest;

  Future<void> _search(String keyword) async {
    final trimmed = keyword.trim();
    if (trimmed.isEmpty) return;
    if (_guest) {
      setState(() {
        _error = '搜索需要连接服务器后使用';
        _loading = false;
        _progressText = null;
      });
      return;
    }

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

    await LocalStorageService.addSearchHistory(trimmed);
    _loadSearchHistory();

    try {
      final response = await SearchService.search(
        keyword: trimmed,
        cancelClient: client,
        fuzzy: true,
        onProgress: (results, progressText) {
          if (mounted && _searchClient == client) {
            setState(() {
              _results = results;
              _progressText = progressText;
            });
          }
        },
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
        });
      }
    } catch (e) {
      // 被取消的搜索不需要更新界面
      if (mounted && _searchClient == client) {
        setState(() {
          _loading = false;
          _progressText = null;
          _error = '搜索失败: $e';
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
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromSearchResult(result),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      // bottom:false —— 内容视口延伸至屏幕最底，结果列表可滚到底部磨砂导航栏
      // 之下被真实模糊；底部避让由滚动 padding 承担。
      body: SafeArea(
        bottom: false,
        child: SingleChildScrollView(
          child: Padding(
            // 底部留出浮动磨砂导航栏总高，避免结果列表被永久遮挡。
            padding: EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
              bottom:
                  AppSpacing.md + GlassStyleService.navBarTotalHeight(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildSearchBox(),
                const SizedBox(height: AppSpacing.md),
                _buildHistorySection(),
                const SizedBox(height: AppSpacing.md),
                _buildResultsArea(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSearchBox() {
    return TextField(
      controller: _controller,
      textInputAction: TextInputAction.search,
      style: TextStyle(color: AppColors.textPrimary),
      onSubmitted: (value) => _search(value),
      readOnly: _guest,
      decoration: InputDecoration(
        hintText: _guest ? '搜索需要连接服务器后使用' : '输入关键词搜索',
        prefixIcon: Icon(Icons.search, color: AppColors.textSecondary),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, child) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: Icon(Icons.clear, color: AppColors.textSecondary),
              onPressed: _clearInput,
            );
          },
        ),
      ),
    );
  }

  Widget _buildHistorySection() {
    if (_searchHistory.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.history, color: AppColors.textSecondary, size: 16),
            const SizedBox(width: AppSpacing.xs),
            Expanded(
              child: Text(
                '搜索历史',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            GestureDetector(
              onTap: () async {
                await LocalStorageService.clearSearchHistory();
                _loadSearchHistory();
              },
              child: Text(
                '清空',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 13,
                  color: AppColors.textMuted,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.sm),
        Wrap(
          spacing: AppSpacing.sm,
          runSpacing: AppSpacing.sm,
          children: _searchHistory.map((query) {
            return ActionChip(
              backgroundColor: AppColors.bgElevated,
              side: BorderSide(color: AppColors.border),
              label: Text(
                query,
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 13,
                  color: AppColors.textPrimary,
                ),
              ),
              onPressed: () {
                _controller.text = query;
                _controller.selection = TextSelection.collapsed(
                  offset: query.length,
                );
                _search(query);
              },
            );
          }).toList(),
        ),
      ],
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

    if (_controller.text.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: AppColors.textMuted),
            SizedBox(height: AppSpacing.md),
            Text(
              _guest ? '连接服务器后可搜索影视内容' : '输入关键词开始搜索',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 16,
                color: AppColors.textMuted,
              ),
            ),
            if (_guest) ...[
              const SizedBox(height: AppSpacing.md),
              ElevatedButton.icon(
                onPressed: () => showAddMenuSheet(context),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加服务器'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.primary,
                  foregroundColor: Colors.white,
                ),
              ),
            ],
          ],
        ),
      );
    }

    if (_results.isEmpty) {
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
        posterUrl: result.poster.isNotEmpty ? result.poster : null,
        year: result.year,
        subtitle: result.sourceName.isNotEmpty
            ? result.sourceName
            : result.source,
        onTap: () => _openDetail(result),
      );
    }).toList();

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
        MobilePosterGrid(
          items: items,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: EdgeInsets.zero,
        ),
      ],
    );
  }
}
