import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../focus/focusable.dart';
import '../models/play_record.dart' as models;
import '../models/source_option.dart';
import '../services/lunatv_service.dart';
import '../services/search_service.dart';
import '../theme.dart';
import 'player_screen.dart';

class SourceLoadingScreen extends StatefulWidget {
  final models.PlayRecord record;

  const SourceLoadingScreen({
    super.key,
    required this.record,
  });

  @override
  State<SourceLoadingScreen> createState() => _SourceLoadingScreenState();
}

class _SourceLoadingScreenState extends State<SourceLoadingScreen> {
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadAndPlay();
  }

  Future<void> _loadAndPlay() async {
    setState(() => _error = null);
    try {
      final response = await LunaTVService.getDetail(
        source: widget.record.source,
        id: widget.record.id,
        title: widget.record.title,
      );
      if (!response.success || response.data == null) {
        setState(() => _error = '未找到播放资源');
        return;
      }
      final detail = response.data!;
      final sourceOption = SourceOption(
        source: detail.source,
        sourceName: detail.sourceName,
        id: detail.id,
        title: detail.title,
        poster: detail.poster.isNotEmpty ? detail.poster : null,
        year: detail.year,
        doubanId: detail.doubanId,
      );

      // 同时搜索其他可用源，供播放时切换
      final sources = await SearchService.searchAlternativeSources(
        keyword: detail.title,
        current: sourceOption,
      );

      if (!mounted) return;

      await Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => PlayerScreen(
            videoDetail: detail,
            episodeIndex: widget.record.index > 0 ? widget.record.index - 1 : 0,
            sources: sources,
            initialPositionMs: widget.record.playTime * 1000,
          ),
        ),
      );
    } catch (e) {
      if (mounted) {
        setState(() => _error = '加载失败: $e');
      }
    }
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.goBack ||
        event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _error != null,
      child: Focus(
        autofocus: true,
        onKeyEvent: _handleKeyEvent,
        child: Scaffold(
          backgroundColor: AppColors.bgSurface,
          body: Center(
            child: _error != null ? _buildError() : _buildLoading(),
          ),
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(strokeWidth: 3, color: AppColors.primary),
        SizedBox(height: AppSpacing.lg),
        Text(
          '正在搜索播放源...',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 18,
            color: AppColors.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _buildError() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _error!,
          style: const TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 16,
            color: AppColors.textSecondary,
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        FocusableWidget(
          onTap: _loadAndPlay,
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              color: AppColors.primary,
              borderRadius: BorderRadius.circular(AppRadius.md),
            ),
            child: const Text(
              '重试',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: Colors.white,
                fontSize: 16,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
