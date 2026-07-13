import 'dart:async';

import 'package:flutter/material.dart';
import 'package:hain_tv/models/play_record.dart';
import 'package:hain_tv/screens/mobile/detail_screen.dart';
import 'package:hain_tv/services/play_record_refresh_notifier.dart';
import 'package:hain_tv/services/play_record_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/mobile/record_manage_view.dart';
import 'package:hain_tv/widgets/tv/tv_grid.dart';

class MobileHistoryScreen extends StatefulWidget {
  final List<PlayRecord> initialRecords;

  const MobileHistoryScreen({
    super.key,
    this.initialRecords = const [],
  });

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
      // 首页已加载完整记录，直接展示并后台刷新
      setState(() {
        _history = List.from(widget.initialRecords);
        _loading = false;
      });
      unawaited(_loadHistory(localOnly: false));
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
    // 先读本地立即展示，再后台同步远程
    await _loadHistory(localOnly: true);
    unawaited(_loadHistory(localOnly: false));
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadHistory({bool localOnly = false}) async {
    List<PlayRecord> records = [];
    try {
      records = localOnly
          ? await PlayRecordService.getAllLocal()
          : await PlayRecordService.getAll();
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
      subtitle: record.sourceName.isNotEmpty ? record.sourceName : record.source,
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
        title: const Text(
          '播放记录',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.textPrimary,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppColors.textPrimary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: SafeArea(
        child: _loading
            ? const Center(
                child: CircularProgressIndicator(color: AppColors.primary),
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
