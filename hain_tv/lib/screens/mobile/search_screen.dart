import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:hain_tv/models/search_result.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/services/local_storage_service.dart';
import 'package:hain_tv/services/search_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/mobile_poster_grid.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

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
      body: SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.md),
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
      style: const TextStyle(color: AppColors.textPrimary),
      onSubmitted: (value) => _search(value),
      decoration: InputDecoration(
        hintText: '输入关键词搜索',
        prefixIcon: const Icon(Icons.search, color: AppColors.textSecondary),
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _controller,
          builder: (context, value, child) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: const Icon(Icons.clear, color: AppColors.textSecondary),
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
            const Icon(Icons.history, color: AppColors.textSecondary, size: 16),
            const SizedBox(width: AppSpacing.xs),
            const Expanded(
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
              child: const Text(
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
              side: const BorderSide(color: AppColors.border),
              label: Text(
                query,
                style: const TextStyle(
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
            const CircularProgressIndicator(color: AppColors.primary),
            const SizedBox(height: AppSpacing.md),
            Text(
              _progressText ?? '正在搜索...',
              style: const TextStyle(color: AppColors.textSecondary),
            ),
          ],
        ),
      );
    }

    if (_error != null && _results.isEmpty) {
      return Center(
        child: Text(
          _error!,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      );
    }

    if (_controller.text.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.search, size: 64, color: AppColors.textMuted),
            SizedBox(height: AppSpacing.md),
            Text(
              '输入关键词开始搜索',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 16,
                color: AppColors.textMuted,
              ),
            ),
          ],
        ),
      );
    }

    if (_results.isEmpty) {
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
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
                const SizedBox(width: AppSpacing.sm),
                Text(
                  _progressText!,
                  style: const TextStyle(
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
