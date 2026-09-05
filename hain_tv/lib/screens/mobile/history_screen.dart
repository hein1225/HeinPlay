import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/services/play_record_refresh_notifier.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/record_manage_view.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class MobileHistoryScreen extends StatefulWidget {
  final List<PlayRecord> initialRecords;

  const MobileHistoryScreen({super.key, this.initialRecords = const []});

  @override
  State<MobileHistoryScreen> createState() => _MobileHistoryScreenState();
}

class _MobileHistoryScreenState extends State<MobileHistoryScreen> {
  List<PlayRecord> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    PlayRecordRefreshNotifier.instance.addListener(_onRefresh);
    if (widget.initialRecords.isNotEmpty) {
      // 首页已加载完整记录，直接展示。
      // 与“我的”播放记录共用同一份本地缓存：不单独向服务器同步，
      // 统一在启动/登录时同步一次（HomeDataPreload + LoginScreen），
      // 避免多模块各自拉取导致首页“继续播放”与“查看更多”数据/海报不一致。
      setState(() {
        _history = List.from(widget.initialRecords);
        _loading = false;
      });
      unawaited(_loadHistory());
    } else {
      _loadData();
    }
  }

  @override
  void dispose() {
    PlayRecordRefreshNotifier.instance.removeListener(_onRefresh);
    super.dispose();
  }

  void _onRefresh() {
    if (mounted) _loadData();
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    // 仅读本地缓存（与首页“继续播放”、“我的”播放记录同源），
    // 不再向服务器同步；播放后的增量更新由 PlayRecordRefreshNotifier 通知刷新。
    await _loadHistory();
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadHistory() async {
    List<PlayRecord> records = [];
    try {
      records = await PlayRecordService.getAllLocal();
    } catch (e) {
      // 忽略加载失败
    }
    if (!mounted) return;
    setState(() => _history = records);
  }

  Future<void> _openRecord(PlayRecord record) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => MobileDetailScreen.fromPlayRecord(record),
      ),
    );
    if (mounted) await _loadData();
  }

  PosterItem _toPosterItem(PlayRecord record) {
    return PosterItem(
      id: record.id,
      title: record.title,
      posterUrl: record.cover.isNotEmpty ? record.cover : null,
      subtitle: record.sourceName.isNotEmpty
          ? record.sourceName
          : record.source,
      onTap: () => _openRecord(record),
    );
  }

  Future<void> _deleteByKeys(List<String> keys) async {
    await PlayRecordService.deleteByKeys(keys);
  }

  Future<void> _clear() async {
    await PlayRecordService.clear();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: AppColors.bgApp,
        elevation: 0,
        centerTitle: true,
        title: Text(
          '播放记录',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: TechLoadingIndicator(),
              )
            : Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: RecordManageView<PlayRecord>(
                  title: '',
                  items: _history,
                  emptyMessage: '暂无播放记录',
                  toKey: (r) => r.title,
                  toPosterItem: _toPosterItem,
                  onDeleteKeys: _deleteByKeys,
                  onClear: _clear,
                  onItemsChanged: (remaining) {
                    setState(() => _history = remaining);
                    PlayRecordRefreshNotifier.instance.notify();
                  },
                ),
              ),
      ),
    );
  }
}
