import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';

import '../models/live_channel.dart';
import '../models/live_source_config.dart';
import '../platform/device_utils.dart';
import '../platform/windows_fullscreen_mixin.dart';
import '../platform/windows_window_utils.dart';
import '../services/ad_filter_engine.dart';
import '../services/live_service.dart';
import '../theme.dart';
import '../widgets/live/live_player.dart';

/// 全屏直播播放页。
///
/// 手机端手势：
/// - 向上滑动：上一频道
/// - 向下滑动：下一频道
/// - 向左滑动：切换下一个直播源
/// - 向右滑动：切换上一个直播源
/// - 点击：显示/隐藏选台列表
///
/// TV/Windows 端键盘：
/// - 上下方向键切换频道
/// - 确认键显示/隐藏选台列表
/// - 返回键退出播放
class LivePlayerScreen extends StatefulWidget {
  final LiveSourceConfig source;

  /// 手机端切换直播源时使用，包含所有可用直播源。
  final List<LiveSourceConfig>? allSources;

  /// 当前直播源在 [allSources] 中的索引。
  final int sourceIndex;

  const LivePlayerScreen({
    super.key,
    required this.source,
    this.allSources,
    this.sourceIndex = 0,
  });

  @override
  State<LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends State<LivePlayerScreen>
    with WindowsFullscreenMixin<LivePlayerScreen> {
  bool _loading = true;
  String? _error;
  List<LiveChannel> _channels = [];
  LiveChannel? _currentChannel;
  int _currentIndex = 0;

  bool _showChannelList = false;
  bool _showChannelInfo = false;
  Timer? _channelInfoTimer;

  /// 进入直播播放页前的设备方向，退出时恢复（手机端强制横屏）。
  Orientation? _originalOrientation;

  // 节目单列表
  bool _showEpgList = false;
  /// 当前完整节目单正在显示的频道（非 TV 版通过右侧条幅选择）。
  LiveChannel? _epgListChannel;
  final _epgListScrollController = ScrollController();
  final _epgBannerScrollController = ScrollController();
  final _epgListFocusNode = FocusNode();
  int _selectedEpgIndex = 0;

  // 回放模式
  bool _isReplayMode = false;
  EpgProgram? _currentReplayProgram;
  Duration _replayOffset = Duration.zero;
  bool _isReplayPaused = false;
  bool _isReplaySeeking = false;

  // TV 版确认键长按检测
  DateTime? _selectKeyDownAt;
  Timer? _selectLongPressTimer;

  final _categoryScrollController = ScrollController();
  final _channelListScrollController = ScrollController();
  final _categoryFocusNode = FocusNode();
  final _channelListFocusNode = FocusNode();
  final _rootFocusNode = FocusNode();

  // 分组数据（按源文件中首次出现顺序）
  List<String> _groups = [];
  final Map<String, List<int>> _groupedChannelIndices = {};
  int _selectedGroupIndex = 0;
  int _selectedChannelIndexInGroup = 0;
  bool _focusOnCategories = false;

  // Windows 播放控制栏
  bool _controlsVisible = false;
  Timer? _controlsTimer;
  bool _isMiniPlayer = false;
  bool _isAlwaysOnTop = false;
  Rect? _previousWindowBounds;
  TitleBarStyle _previousTitleBarStyle = TitleBarStyle.normal;
  bool _wasFullScreenBeforeMini = false;
  bool _togglingMiniPlayer = false;

  static const Size _kUnboundedSize = Size(100000, 100000);
  static const Size _kNormalMinSize = Size(900, 600);
  static const Size _kMiniMinSize = Size(320, 180);
  static const double _kChannelListWidth = 480;
  static const double _kCategoryColumnWidth = 100;
  static const double _kChannelItemHeight = 102;
  static const double _kEpgBannerWidth = 56.0;
  static const double _kEpgListWidth = 340.0;

  @override
  void initState() {
    super.initState();
    _loadChannels();
    _channelListScrollController.addListener(_syncEpgBannerScroll);
    if (DeviceUtils.isTv || DeviceUtils.isWindows) {
      HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    }
    if (DeviceUtils.isWindows) {
      initWindowsFullscreen();
      _initWindowsWindowState();
    }
    if (DeviceUtils.isMobile) {
      _enterFullscreenLandscape();
    }
  }

  /// 记录进入直播播放页前的设备方向。
  void _captureOriginalOrientation() {
    final views = WidgetsBinding.instance.platformDispatcher.views;
    if (views.isEmpty) return;
    final view = views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    _originalOrientation = size.width < size.height
        ? Orientation.portrait
        : Orientation.landscape;
  }

  /// 手机端进入直播播放时强制横屏全屏。
  Future<void> _enterFullscreenLandscape() async {
    _captureOriginalOrientation();
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations([
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } catch (e) {
      debugPrint('LivePlayerScreen: 进入横屏失败: $e');
    }
  }

  /// 退出直播播放页时恢复进入前的屏幕方向。
  Future<void> _restoreOrientation() async {
    try {
      final original = _originalOrientation;
      if (original == Orientation.landscape) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      } else if (original == Orientation.portrait) {
        await SystemChrome.setPreferredOrientations([
          DeviceOrientation.portraitUp,
          DeviceOrientation.portraitDown,
        ]);
      } else {
        await SystemChrome.setPreferredOrientations(DeviceOrientation.values);
      }
    } catch (e) {
      debugPrint('LivePlayerScreen: 恢复方向失败: $e');
    }
  }

  Future<void> _initWindowsWindowState() async {
    try {
      final bounds = await windowManager.getBounds();
      if (_isValidNormalBounds(bounds)) {
        _previousWindowBounds = bounds;
      }
      _isAlwaysOnTop = await windowManager.isAlwaysOnTop();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Windows 直播播放页初始化窗口状态失败: $e');
    }
  }

  bool _isValidNormalBounds(Rect? bounds) {
    if (bounds == null) return false;
    return bounds.width >= _kNormalMinSize.width &&
        bounds.height >= _kNormalMinSize.height;
  }

  Future<void> _loadChannels() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    final response = await LiveService.loadChannelsForSource(widget.source);
    if (!mounted) return;

    if (!response.success || response.data == null) {
      setState(() {
        _loading = false;
        _error = response.message ?? '频道加载失败';
      });
      return;
    }

    final channels = response.data!;
    if (channels.isEmpty) {
      setState(() {
        _loading = false;
        _error = '该直播源暂无频道';
      });
      return;
    }

    setState(() {
      _loading = false;
      _channels = channels;
      _currentIndex = 0;
      _currentChannel = channels.first;
    });
    _buildGroups();
    _syncSelectionToCurrentChannel();

    // 异步拉取 EPG 节目单，成功后刷新界面。
    _loadEpgForChannels(channels);
  }

  Future<void> _loadEpgForChannels(List<LiveChannel> channels) async {
    // 若缓存已包含节目单，则按当前时间刷新当前节目信息即可，
    // 避免重复拉取 EPG，减少网络请求与积分消耗。
    final hasCachedPrograms = channels.any((c) => c.programs.isNotEmpty);
    if (hasCachedPrograms) {
      LiveService.refreshCurrentPrograms(channels);
      if (mounted) setState(() {});
      return;
    }

    await LiveService.fetchEpg(channels, epgUrl: widget.source.epgUrl);
    // EPG 拉取成功后，把包含节目单的完整频道数据写回缓存，
    // 下次进入直播页即可直接恢复节目单，无需再次请求。
    await LiveService.cacheChannels(widget.source, channels);
    if (mounted) setState(() {});
  }

  void _playChannel(int index, {bool showInfo = true}) {
    if (index < 0 || index >= _channels.length) return;
    setState(() {
      _currentIndex = index;
      _currentChannel = _channels[index];
      _isReplayMode = false;
      _currentReplayProgram = null;
      _replayOffset = Duration.zero;
      _epgListChannel = null;
    });
    _syncSelectionToCurrentChannel();
    if (showInfo) {
      _showChannelInfoBriefly();
    }
  }

  /// 生成指定节目的回放 URL。
  ///
  /// 支持变量：\${start}、\${stop}、\${timestamp}、\${start_ts}、\${stop_ts}、
  /// \${timestamp_ts}、\${offset}、\${channel}。
  /// \${offset} 表示从节目开始时间到当前回放位置的秒数。
  ///
  /// 若 M3U 中只有 catchup 类型（如 default/append）但没有 catchup-source，
  /// 则尝试在原直播 URL 后追加回放参数作为兜底。
  String? _buildCatchupUrl(LiveChannel channel, EpgProgram program) {
    var template = channel.catchupSource;
    if (template == null || template.isEmpty) {
      final catchupType = channel.catchup?.toLowerCase() ?? '';
      if (catchupType.isEmpty) return null;
      // catchup="append" 时常用相对参数模板。
      if (catchupType == 'append') {
        template = '&start=\${start_ts}&end=\${stop_ts}';
      } else {
        // default / shift 等类型，尝试在原 URL 后追加完整参数。
        template = '?start=\${start_ts}&end=\${stop_ts}';
      }
    }
    // EPG 数据中的 start/stop 为本地时间，直接用于回放模板，避免时区转换导致时间偏差。
    final start = program.start;
    final stop = program.stop;
    // 用户快进/快退后，实际回放起始点应随偏移量变化。
    final playAt = start.add(_replayOffset);

    // 中国 IPTV 源普遍使用北京时间（UTC+8）作为回放参数，
    // 强制使用该时区格式化，避免 OpenClash 代理或设备时区不一致导致时间偏差。
    const chinaOffset = Duration(hours: 8);
    final playAtChina = _toWallClockInOffset(playAt, chinaOffset);
    final stopChina = _toWallClockInOffset(stop, chinaOffset);

    String url = template;
    // 若模板是相对路径/参数，则拼接到原直播 URL。
    // 无论模板以 ? 还是 & 开头，都需要保证最终 URL 只有第一个查询参数以 ? 开始。
    if (url.startsWith('&') || url.startsWith('?')) {
      final baseUrl = channel.currentUrl;
      final hasQuery = baseUrl.contains('?');
      final separator = hasQuery ? '&' : '?';
      url = '$baseUrl$separator${url.substring(1)}';
    }

    // 直播回放中 ${start}/${(b)} 代表用户当前要播放的起始位置，
    // 默认等于节目开始时间；快进后随 _replayOffset 变化。
    url = url.replaceAll('\${start}', _formatXmlTvTime(playAtChina));
    url = url.replaceAll('\${stop}', _formatXmlTvTime(stopChina));
    url = url.replaceAll('\${timestamp}', _formatXmlTvTime(playAtChina));
    url = url.replaceAll('\${start_ts}', (playAt.millisecondsSinceEpoch ~/ 1000).toString());
    url = url.replaceAll('\${stop_ts}', (stop.millisecondsSinceEpoch ~/ 1000).toString());
    url = url.replaceAll('\${timestamp_ts}', (playAt.millisecondsSinceEpoch ~/ 1000).toString());
    url = url.replaceAll('\${offset}', _replayOffset.inSeconds.toString());
    url = url.replaceAll('\${channel}', Uri.encodeComponent(channel.name));
    // 支持 M3U 头中常见的 ${(b)format} / ${(e)format} 变量，
    // 例如 ?playbackbegin=${(b)yyyyMMddHHmmss}&playbackend=${(e)yyyyMMddHHmmss}
    url = _replaceCatchupDateVariable(url, 'b', playAtChina);
    url = _replaceCatchupDateVariable(url, 'e', stopChina);
    debugPrint(
      '回放 URL: $url, program.start=$start, program.stop=$stop, '
      'chinaStart=$playAtChina, chinaStop=$stopChina, offset=${_replayOffset.inSeconds}s',
    );
    return url;
  }

  /// 替换 catchup 模板中的 ${(tag)format} 日期变量。
  ///
  /// tag 为 'b' 时代表节目开始时间，'e' 时代表结束时间。
  String _replaceCatchupDateVariable(
    String url,
    String tag,
    DateTime dt,
  ) {
    // 同时兼容 ${(b)yyyyMMddHHmmss} 和 ${b yyyyMMddHHmmss} 两种写法。
    final pattern = RegExp(r'\$\{(?:\()?(' + RegExp.escape(tag) + r')(?:\))?\s*([^}]+)\}');
    return url.replaceAllMapped(pattern, (match) {
      final format = match.group(2)!.trim();
      return _formatDateTimeByPattern(dt, format);
    });
  }

  /// 按简单日期格式模板格式化本地时间。
  ///
  /// 支持的占位符：yyyy、MM、dd、HH、mm、ss。
  String _formatDateTimeByPattern(DateTime dt, String pattern) {
    var result = pattern;
    result = result.replaceAll('yyyy', dt.year.toString().padLeft(4, '0'));
    result = result.replaceAll('MM', dt.month.toString().padLeft(2, '0'));
    result = result.replaceAll('dd', dt.day.toString().padLeft(2, '0'));
    result = result.replaceAll('HH', dt.hour.toString().padLeft(2, '0'));
    result = result.replaceAll('mm', dt.minute.toString().padLeft(2, '0'));
    result = result.replaceAll('ss', dt.second.toString().padLeft(2, '0'));
    return result;
  }

  String _formatXmlTvTime(DateTime dt) {
    // 使用本地时间，避免时区转换导致回放时间偏差。
    return '${dt.year.toString().padLeft(4, '0')}'
        '${dt.month.toString().padLeft(2, '0')}'
        '${dt.day.toString().padLeft(2, '0')}'
        '${dt.hour.toString().padLeft(2, '0')}'
        '${dt.minute.toString().padLeft(2, '0')}'
        '${dt.second.toString().padLeft(2, '0')}';
  }

  /// 将 [dt] 转换为指定时区偏移下的“墙上时间”DateTime。
  ///
  /// 返回的 DateTime 不代表新的时刻，而是同一时刻在目标时区下的本地表示，
  /// 用于按目标时区格式化日期字符串。
  DateTime _toWallClockInOffset(DateTime dt, Duration offset) {
    final utc = dt.toUtc();
    final shifted = utc.add(offset);
    return DateTime(shifted.year, shifted.month, shifted.day, shifted.hour,
        shifted.minute, shifted.second);
  }

  void _buildGroups() {
    _groups = [];
    _groupedChannelIndices.clear();
    for (var i = 0; i < _channels.length; i++) {
      final group = (_channels[i].group ?? '其他').trim();
      if (!_groupedChannelIndices.containsKey(group)) {
        _groups.add(group);
        _groupedChannelIndices[group] = [];
      }
      _groupedChannelIndices[group]!.add(i);
    }
  }

  void _syncSelectionToCurrentChannel() {
    if (_currentChannel == null || _groups.isEmpty) return;
    final group = (_currentChannel!.group ?? '其他').trim();
    _selectedGroupIndex = _groups.indexOf(group);
    if (_selectedGroupIndex < 0) _selectedGroupIndex = 0;
    final indices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
    _selectedChannelIndexInGroup = indices.indexOf(_currentIndex);
    if (_selectedChannelIndexInGroup < 0) _selectedChannelIndexInGroup = 0;
  }

  void _moveCategory(int delta) {
    final newIndex = (_selectedGroupIndex + delta).clamp(0, _groups.length - 1);
    if (newIndex == _selectedGroupIndex) return;
    setState(() {
      _selectedGroupIndex = newIndex;
      _selectedChannelIndexInGroup = 0;
    });
    _scrollToCategory();
    _scrollToChannelInGroup();
  }

  void _moveChannelInGroup(int delta) {
    final indices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
    if (indices.isEmpty) return;
    final newPos = (_selectedChannelIndexInGroup + delta).clamp(0, indices.length - 1);
    if (newPos == _selectedChannelIndexInGroup) return;
    setState(() => _selectedChannelIndexInGroup = newPos);
    _scrollToChannelInGroup();
  }

  void _focusFirstVisibleChannel() {
    final indices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
    if (indices.isEmpty) return;
    var pos = 0;
    if (_channelListScrollController.hasClients) {
      pos = (_channelListScrollController.offset / _kChannelItemHeight).floor();
    }
    pos = pos.clamp(0, indices.length - 1);
    setState(() => _selectedChannelIndexInGroup = pos);
    _scrollToChannelInGroup();
  }

  void _scrollToCategory() {
    if (!_categoryScrollController.hasClients) return;
    const itemHeight = 48.0;
    final targetOffset = _selectedGroupIndex * itemHeight;
    final viewport = _categoryScrollController.position.viewportDimension;
    final currentOffset = _categoryScrollController.offset;
    if (targetOffset < currentOffset ||
        targetOffset + itemHeight > currentOffset + viewport) {
      _categoryScrollController.animateTo(
        targetOffset.clamp(0.0, _categoryScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _scrollToChannelInGroup() {
    if (!_channelListScrollController.hasClients) return;
    final targetOffset = _selectedChannelIndexInGroup * _kChannelItemHeight;
    final viewport = _channelListScrollController.position.viewportDimension;
    final currentOffset = _channelListScrollController.offset;
    if (targetOffset < currentOffset ||
        targetOffset + _kChannelItemHeight > currentOffset + viewport) {
      _channelListScrollController.animateTo(
        targetOffset.clamp(0.0, _channelListScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  /// 让右侧节目单条幅列跟随频道列表同步滚动。
  void _syncEpgBannerScroll() {
    if (!_epgBannerScrollController.hasClients ||
        !_channelListScrollController.hasClients) {
      return;
    }
    final offset = _channelListScrollController.offset;
    if (_epgBannerScrollController.offset != offset) {
      _epgBannerScrollController.jumpTo(offset);
    }
  }

  void _playPrevChannel() {
    if (_channels.isEmpty) return;
    final newIndex = _currentIndex <= 0 ? _channels.length - 1 : _currentIndex - 1;
    _playChannel(newIndex);
  }

  void _playNextChannel() {
    if (_channels.isEmpty) return;
    final newIndex = _currentIndex >= _channels.length - 1 ? 0 : _currentIndex + 1;
    _playChannel(newIndex);
  }

  /// 切换到当前频道的下一个备选直播源。
  void _switchToNextBackupUrl() {
    final channel = _currentChannel;
    if (channel == null || !channel.hasMultipleUrls) return;
    final nextIndex = (channel.currentBackupIndex + 1) % channel.allUrls.length;
    setState(() {
      channel.currentBackupIndex = nextIndex;
    });
    _showChannelInfoBriefly();
  }

  /// 切换到当前频道的上一个备选直播源。
  void _switchToPrevBackupUrl() {
    final channel = _currentChannel;
    if (channel == null || !channel.hasMultipleUrls) return;
    final prevIndex = channel.currentBackupIndex <= 0
        ? channel.allUrls.length - 1
        : channel.currentBackupIndex - 1;
    setState(() {
      channel.currentBackupIndex = prevIndex;
    });
    _showChannelInfoBriefly();
  }

  void _showChannelInfoBriefly() {
    _channelInfoTimer?.cancel();
    setState(() => _showChannelInfo = true);
    _channelInfoTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _showChannelInfo = false);
    });
  }

  void _toggleChannelList() {
    if (_isMiniPlayer) return;
    final willShow = !_showChannelList;
    setState(() {
      _showChannelList = willShow;
      if (!willShow) {
        _showEpgList = false;
        _epgListChannel = null;
      } else {
        _syncSelectionToCurrentChannel();
        _focusOnCategories = false;
      }
    });
    if (willShow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollToCategory();
        _scrollToChannelInGroup();
        _channelListFocusNode.requestFocus();
      });
    } else {
      _rootFocusNode.requestFocus();
    }
  }

  void _toggleControlsAndChannelList() {
    if (_isMiniPlayer) {
      _toggleControls();
      return;
    }
    if (_showChannelList || _controlsVisible) {
      _hideChannelListAndControls();
    } else {
      _showChannelListAndControls();
    }
  }

  void _showControls() {
    if (!DeviceUtils.isWindows) return;
    _controlsTimer?.cancel();
    setState(() => _controlsVisible = true);
  }

  void _hideControls() {
    if (!DeviceUtils.isWindows) return;
    _controlsTimer?.cancel();
    if (mounted) setState(() => _controlsVisible = false);
  }

  void _toggleControls() {
    if (!DeviceUtils.isWindows) return;
    if (_controlsVisible) {
      _hideControls();
    } else {
      _showControls();
    }
  }

  /// 显示频道列表并将焦点定位到当前播放频道。
  ///
  /// Windows 版会同时显示控制栏，保持控制栏与列表层级融合。
  void _showChannelListAndControls() {
    if (_isMiniPlayer) return;
    setState(() {
      _showChannelList = true;
      if (DeviceUtils.isWindows) _controlsVisible = true;
      _syncSelectionToCurrentChannel();
      _focusOnCategories = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToCategory();
      _scrollToChannelInGroup();
      _channelListFocusNode.requestFocus();
    });
  }

  void _hideChannelListAndControls() {
    if (!DeviceUtils.isWindows) return;
    _controlsTimer?.cancel();
    setState(() {
      _showChannelList = false;
      _controlsVisible = false;
      _showEpgList = false;
      _epgListChannel = null;
    });
    _rootFocusNode.requestFocus();
  }

  Future<void> _toggleMiniPlayer() async {
    if (!DeviceUtils.isWindows || _togglingMiniPlayer) return;
    _togglingMiniPlayer = true;
    try {
      if (_isMiniPlayer) {
        // 恢复窗口
        await windowManager.setMinimumSize(_kNormalMinSize);
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setResizable(true);
        await windowManager.setTitleBarStyle(_previousTitleBarStyle);
        await WindowsWindowUtils.ensureNormalWindowFrame();
        final saved = _previousWindowBounds;
        if (saved != null && _isValidNormalBounds(saved)) {
          await windowManager.setBounds(saved);
        } else {
          await windowManager.setSize(const Size(900, 600));
          await windowManager.center();
        }
        if (_wasFullScreenBeforeMini) {
          await Future.delayed(const Duration(milliseconds: 100));
          await toggleWindowsFullscreen();
        }
        _isMiniPlayer = false;
      } else {
        // 进入小窗
        _wasFullScreenBeforeMini = isWindowsFullScreen;
        if (isWindowsFullScreen) {
          await toggleWindowsFullscreen();
          await Future.delayed(const Duration(milliseconds: 100));
        }
        final bounds = await windowManager.getBounds();
        if (_isValidNormalBounds(bounds)) {
          _previousWindowBounds = bounds;
        }
        _previousTitleBarStyle = TitleBarStyle.normal;
        await windowManager.setMinimumSize(_kMiniMinSize);
        await windowManager.setMaximumSize(_kUnboundedSize);
        await windowManager.setResizable(true);
        await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
        await WindowsWindowUtils.ensureNormalWindowFrame();
        await windowManager.setSize(const Size(400, 225));
        await windowManager.setAlwaysOnTop(true);
        _isMiniPlayer = true;
        _isAlwaysOnTop = true;
      }
      if (mounted) {
        setState(() {});
        // 小窗切换后重新夺回键盘焦点，确保上下键可换台。
        _rootFocusNode.requestFocus();
      }
    } catch (e) {
      debugPrint('Windows 直播小窗切换失败: $e');
    } finally {
      _togglingMiniPlayer = false;
    }
  }

  Future<void> _toggleAlwaysOnTop() async {
    if (!DeviceUtils.isWindows) return;
    try {
      final next = !_isAlwaysOnTop;
      await windowManager.setAlwaysOnTop(next);
      _isAlwaysOnTop = next;
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Windows 直播置顶切换失败: $e');
    }
  }

  Future<void> _onWindowsBack() async {
    if (!DeviceUtils.isWindows) return;
    if (isWindowsFullScreen) {
      await toggleWindowsFullscreen();
    } else if (_isMiniPlayer) {
      await _toggleMiniPlayer();
    } else {
      if (mounted) Navigator.of(context).maybePop();
    }
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;

    // 确认键需要单独处理 KeyDown/KeyUp 以支持长按检测。
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter) {
      return _handleSelectKeyEvent(event);
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return false;

    // 菜单键直接显示频道列表。
    if (event.logicalKey == LogicalKeyboardKey.contextMenu) {
      if (!_showChannelList && !_showEpgList) {
        _showChannelListAndControls();
      }
      return true;
    }

    // 节目单列表打开时，方向键用于选择节目。
    if (_showEpgList) {
      return _handleEpgListKey(event.logicalKey);
    }

    // TV 版在频道列表打开时使用“分类 ←→ 频道”两列焦点导航。
    if (DeviceUtils.isTv && _showChannelList) {
      return _handleTvChannelListKey(event.logicalKey);
    }

    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowUp:
        if (_isReplayMode) return true;
        if (_showChannelList) {
          _moveChannelInGroup(-1);
        } else {
          _playPrevChannel();
        }
        return true;
      case LogicalKeyboardKey.arrowDown:
        if (_isReplayMode) return true;
        if (_showChannelList) {
          _moveChannelInGroup(1);
        } else {
          _playNextChannel();
        }
        return true;
      case LogicalKeyboardKey.arrowLeft:
        if (_isReplayMode) {
          _seekReplay(const Duration(seconds: -30));
          return true;
        }
        if (_showChannelList) {
          if (DeviceUtils.isTv && !_focusOnCategories) {
            setState(() => _focusOnCategories = true);
            _categoryFocusNode.requestFocus();
            return true;
          }
          _toggleChannelList();
          return true;
        }
        _switchToPrevBackupUrl();
        return true;
      case LogicalKeyboardKey.arrowRight:
        if (_isReplayMode) {
          _seekReplay(const Duration(seconds: 30));
          return true;
        }
        if (_showChannelList) {
          if (DeviceUtils.isTv && _focusOnCategories) {
            setState(() => _focusOnCategories = false);
            _focusFirstVisibleChannel();
            _channelListFocusNode.requestFocus();
            return true;
          }
          _openEpgListForCurrentChannel();
          return true;
        }
        _switchToNextBackupUrl();
        return true;
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        if (_showEpgList) {
          _closeEpgList();
          return true;
        }
        if (_showChannelList) {
          if (DeviceUtils.isWindows) {
            _hideChannelListAndControls();
          } else {
            _toggleChannelList();
          }
          return true;
        }
        if (_isReplayMode) {
          _exitReplayMode();
          return true;
        }
        if (DeviceUtils.isWindows) {
          handleWindowsEsc();
          return true;
        }
        // 非 Windows 平台返回 false，让 PopScope/系统返回键处理退出播放。
        return false;
      default:
        return false;
    }
  }

  /// 处理 TV 版确认键（select/enter）的短按/长按。
  ///
  /// - 短按：直播模式显示台标与播放信息；回放模式切换播放/暂停或恢复播放。
  /// - 长按（≥600ms）或菜单键：显示频道列表。
  bool _handleSelectKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      _selectKeyDownAt = DateTime.now();
      _selectLongPressTimer?.cancel();
      _selectLongPressTimer = Timer(const Duration(milliseconds: 600), () {
        _selectKeyDownAt = null;
        _selectLongPressTimer = null;
        // 长按直接显示频道列表（回放模式下先退出回放再显示列表）。
        if (_isReplayMode) {
          _exitReplayMode();
        }
        if (!_showChannelList && !_showEpgList) {
          _showChannelListAndControls();
        }
      });
      return true;
    }

    if (event is KeyUpEvent) {
      _selectLongPressTimer?.cancel();
      _selectLongPressTimer = null;
      final downAt = _selectKeyDownAt;
      _selectKeyDownAt = null;
      if (downAt == null) return true;

      if (_showEpgList) {
        _handleEpgListKey(LogicalKeyboardKey.select);
        return true;
      }

      if (_showChannelList) {
        final indices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
        final globalIndex = indices.isNotEmpty ? indices[_selectedChannelIndexInGroup] : _currentIndex;
        _playChannel(globalIndex);
        if (DeviceUtils.isWindows) {
          _hideChannelListAndControls();
        } else {
          _toggleChannelList();
        }
        return true;
      }

      if (_isReplayMode) {
        _toggleReplayPause();
        return true;
      }

      // 直播模式下短按显示台标与播放信息。
      _showChannelInfoBriefly();
      return true;
    }

    return false;
  }

  /// 切换回放模式播放/暂停状态。
  void _toggleReplayPause() {
    if (!_isReplayMode || _currentReplayProgram == null) return;
    if (_isReplaySeeking) {
      // 快进/快退模式下确认键恢复播放。
      setState(() {
        _isReplaySeeking = false;
        _isReplayPaused = false;
      });
      _showChannelInfoBriefly();
      return;
    }
    final nextPaused = !_isReplayPaused;
    setState(() => _isReplayPaused = nextPaused);
    _showChannelInfoBriefly();
  }

  /// 节目单列表键盘处理。
  bool _handleEpgListKey(LogicalKeyboardKey key) {
    final channel = _epgListChannel ?? _currentChannel;
    if (channel == null) return false;
    final programs = _epgProgramsFor(channel);

    switch (key) {
      case LogicalKeyboardKey.arrowUp:
        if (programs.isNotEmpty) {
          setState(() {
            _selectedEpgIndex =
                (_selectedEpgIndex - 1).clamp(0, programs.length - 1);
          });
          _scrollToEpgItem();
        }
        return true;
      case LogicalKeyboardKey.arrowDown:
        if (programs.isNotEmpty) {
          setState(() {
            _selectedEpgIndex =
                (_selectedEpgIndex + 1).clamp(0, programs.length - 1);
          });
          _scrollToEpgItem();
        }
        return true;
      case LogicalKeyboardKey.arrowLeft:
        _closeEpgList();
        return true;
      case LogicalKeyboardKey.arrowRight:
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
        if (programs.isNotEmpty) {
          _startReplay(programs[_selectedEpgIndex]);
        }
        return true;
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        _closeEpgList();
        return true;
      default:
        return false;
    }
  }

  /// 进入指定节目的回放模式。
  void _startReplay(EpgProgram program) {
    final channel = _epgListChannel ?? _currentChannel;
    if (channel == null) return;
    debugPrint(
      '回放检查: 频道=${channel.name}, catchup=${channel.catchup}, '
      'catchupSource=${channel.catchupSource}, catchupDays=${channel.catchupDays}, '
      'program.stop=${program.stop}, now=${DateTime.now()}',
    );
    final canReplay = _canReplay(channel, program);
    if (!canReplay) {
      _showReplayHint('该节目不支持回放');
      return;
    }
    setState(() {
      // 若回放的是节目单中选中的其他频道，先切换到该频道。
      if (_epgListChannel != null &&
          _currentChannel?.name != _epgListChannel!.name) {
        final index = _channels.indexWhere(
          (c) => c.name == _epgListChannel!.name,
        );
        if (index >= 0) {
          _currentIndex = index;
          _currentChannel = _channels[index];
        }
      }
      _isReplayMode = true;
      _currentReplayProgram = program;
      _replayOffset = Duration.zero;
      _isReplayPaused = false;
      _isReplaySeeking = false;
      _showEpgList = false;
      _showChannelList = false;
      _epgListChannel = null;
    });
    _showChannelInfoBriefly();
  }

  /// 退出回放模式，返回当前频道直播。
  void _exitReplayMode() {
    setState(() {
      _isReplayMode = false;
      _currentReplayProgram = null;
      _replayOffset = Duration.zero;
      _isReplayPaused = false;
      _isReplaySeeking = false;
    });
    _showChannelInfoBriefly();
  }

  /// 回放时快进/快退指定偏移。
  ///
  /// 直接更新回放起始位置并继续播放，无需再按确认键。
  void _seekReplay(Duration delta) {
    if (!_isReplayMode || _currentReplayProgram == null) return;
    final maxOffset = DateTime.now().difference(_currentReplayProgram!.start);
    var newOffset = _replayOffset + delta;
    if (newOffset < Duration.zero) newOffset = Duration.zero;
    if (newOffset > maxOffset) newOffset = maxOffset;
    setState(() {
      _replayOffset = newOffset;
      _isReplaySeeking = false;
      _isReplayPaused = false;
    });
    _showChannelInfoBriefly();
  }

  /// 判断指定节目是否可回放。
  bool _canReplay(LiveChannel channel, EpgProgram program) {
    final hasCatchup =
        (channel.catchupSource != null && channel.catchupSource!.isNotEmpty) ||
            (channel.catchup != null && channel.catchup!.isNotEmpty);
    if (!hasCatchup) return false;
    return program.stop.isBefore(DateTime.now());
  }

  /// 获取频道按时间排序的节目单（当前节目优先，往期倒序）。
  List<EpgProgram> _epgProgramsFor(LiveChannel channel) {
    final list = List<EpgProgram>.from(channel.programs);
    list.sort((a, b) => a.start.compareTo(b.start));
    return list;
  }

  void _openEpgListForCurrentChannel() {
    _openEpgListForChannel(_currentChannel);
  }

  void _openEpgListForChannel(LiveChannel? channel) {
    if (channel == null || channel.programs.isEmpty) return;
    final programs = _epgProgramsFor(channel);
    // 默认选中当前正在播放的节目。
    final now = DateTime.now();
    var initialIndex = 0;
    for (var i = 0; i < programs.length; i++) {
      if (programs[i].start.isBefore(now) && programs[i].stop.isAfter(now)) {
        initialIndex = i;
        break;
      }
    }
    setState(() {
      _showEpgList = true;
      _epgListChannel = channel;
      _selectedEpgIndex = initialIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToEpgItem();
      _epgListFocusNode.requestFocus();
    });
  }

  void _closeEpgList() {
    setState(() {
      _showEpgList = false;
      _epgListChannel = null;
    });
    _channelListFocusNode.requestFocus();
  }

  void _scrollToEpgItem() {
    if (!_epgListScrollController.hasClients) return;
    const itemHeight = 56.0;
    final targetOffset = _selectedEpgIndex * itemHeight;
    final viewport = _epgListScrollController.position.viewportDimension;
    final currentOffset = _epgListScrollController.offset;
    if (targetOffset < currentOffset ||
        targetOffset + itemHeight > currentOffset + viewport) {
      _epgListScrollController.animateTo(
        targetOffset.clamp(0.0, _epgListScrollController.position.maxScrollExtent),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  void _showReplayHint(String message) {
    // TODO: 可替换为 Toast/Snackbar。
    debugPrint(message);
  }

  bool _handleTvChannelListKey(LogicalKeyboardKey key) {
    // 回放模式下频道列表中的上下键禁用，避免与回放逻辑冲突。
    if (_isReplayMode) return true;
    switch (key) {
      case LogicalKeyboardKey.arrowUp:
        if (_focusOnCategories) {
          _moveCategory(-1);
        } else {
          _moveChannelInGroup(-1);
        }
        return true;
      case LogicalKeyboardKey.arrowDown:
        if (_focusOnCategories) {
          _moveCategory(1);
        } else {
          _moveChannelInGroup(1);
        }
        return true;
      case LogicalKeyboardKey.arrowRight:
        if (_focusOnCategories) {
          setState(() => _focusOnCategories = false);
          _focusFirstVisibleChannel();
          _channelListFocusNode.requestFocus();
        } else {
          _openEpgListForCurrentChannel();
        }
        return true;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
        if (_focusOnCategories) {
          setState(() => _focusOnCategories = false);
          _focusFirstVisibleChannel();
          _channelListFocusNode.requestFocus();
        } else {
          final indices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
          if (indices.isNotEmpty) {
            _playChannel(indices[_selectedChannelIndexInGroup]);
          }
          _toggleChannelList();
        }
        return true;
      case LogicalKeyboardKey.arrowLeft:
        if (!_focusOnCategories) {
          setState(() => _focusOnCategories = true);
          _categoryFocusNode.requestFocus();
        } else {
          _toggleChannelList();
        }
        return true;
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        _toggleChannelList();
        return true;
      default:
        return false;
    }
  }

  @override
  void dispose() {
    _channelInfoTimer?.cancel();
    _controlsTimer?.cancel();
    if (DeviceUtils.isTv || DeviceUtils.isWindows) {
      HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    }
    if (DeviceUtils.isWindows) {
      disposeWindowsFullscreen();
    }
    // 释放可能存在的本地代理，避免 Windows 退出时资源未释放导致闪退。
    AdFilterEngine.dispose();
    if (DeviceUtils.isMobile) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(_restoreOrientation());
    }
    _selectLongPressTimer?.cancel();
    _channelListScrollController.removeListener(_syncEpgBannerScroll);
    _categoryScrollController.dispose();
    _channelListScrollController.dispose();
    _epgListScrollController.dispose();
    _epgBannerScrollController.dispose();
    _categoryFocusNode.dispose();
    _channelListFocusNode.dispose();
    _epgListFocusNode.dispose();
    _rootFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 仅在直播模式且列表/节目单均隐藏时返回键退出播放页；
    // 回放模式先退出回放，列表/节目单显示时先关闭它们。
    final canPop = !_isReplayMode && !_showEpgList && !_showChannelList;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_isReplayMode) {
          _exitReplayMode();
        } else if (_showEpgList) {
          _closeEpgList();
        } else if (_showChannelList) {
          if (DeviceUtils.isWindows) {
            _hideChannelListAndControls();
          } else {
            _toggleChannelList();
          }
        }
      },
      child: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildPlayer(),
              _buildGestureLayer(),
              if (_showChannelInfo) _buildChannelInfoOverlay(),
              if (_showChannelList && !_isMiniPlayer) _buildChannelListOverlay(),
            // TV 版使用独立浮层面板；Windows 版使用频道列表内嵌面板。
            if (_showEpgList && DeviceUtils.isTv && !DeviceUtils.isWindows) _buildEpgListOverlay(),
            if (DeviceUtils.isWindows && _controlsVisible && !_showChannelList) _buildWindowsControls(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPlayer() {
    if (_loading) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.primary),
      );
    }

    if (_error != null) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                _error!,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: AppColors.error,
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              ElevatedButton(
                onPressed: _loadChannels,
                child: const Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentChannel == null) {
      return const Center(
        child: Text(
          '请选择频道',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: Colors.white,
          ),
        ),
      );
    }

    // 回放模式下播放生成的 catchup URL。
    String playUrl;
    VideoFormat formatHint;
    if (_isReplayMode && _currentReplayProgram != null) {
      final catchupUrl = _buildCatchupUrl(
        _currentChannel!,
        _currentReplayProgram!,
      );
      if (catchupUrl == null || catchupUrl.isEmpty) {
        return const Center(
          child: Text(
            '无法生成回放地址',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: Colors.white,
            ),
          ),
        );
      }
      playUrl = catchupUrl;
      formatHint = _formatHintFor(playUrl);
    } else {
      // 根据原始频道 URL 判断直播流格式，代理后的 URL 可能丢失格式后缀。
      // IPTV 列表中的频道地址通常为 HLS/M3U8，无明确后缀时默认按 HLS 处理。
      formatHint = _formatHintFor(_currentChannel!.url);
      // LunaTV 与本地直播源均直接播放原始 URL，与 TVBox 行为保持一致。
      playUrl = _currentChannel!.currentUrl;
    }

    return LivePlayer(
      key: ValueKey('${_currentChannel!.name}_$playUrl'),
      url: playUrl,
      formatHint: formatHint,
      paused: _isReplayMode && _isReplayPaused,
    );
  }

  /// 根据 URL 判断直播流格式提示。
  ///
  /// IPTV 源中的频道地址多为 HLS（即便 URL 无 .m3u8 后缀），因此无明确格式
  /// 特征时默认返回 [VideoFormat.hls]；当 URL 明确指向单文件视频、udpxy/RTP
  /// 代理流或原始 RTP/UDP 组播地址时返回 [VideoFormat.other]。
  VideoFormat _formatHintFor(String url) {
    final lower = url.toLowerCase();
    // udpxy 等 RTP over HTTP 代理以及原始 RTP/UDP 组播通常传输 MPEG-TS，
    // 需要按普通媒体源播放，而不是 HLS playlist。
    if (lower.contains('/rtp/') ||
        lower.startsWith('rtp://') ||
        lower.startsWith('udp://') ||
        lower.startsWith('rtsp://')) {
      return VideoFormat.other;
    }
    if (lower.contains('.m3u8') || lower.contains('/hls/')) {
      return VideoFormat.hls;
    }
    if (lower.contains('.mpd')) return VideoFormat.dash;
    if (lower.contains('.ism')) return VideoFormat.ss;
    if (lower.contains('.mp4') ||
        lower.contains('.mkv') ||
        lower.contains('.flv') ||
        lower.contains('.avi') ||
        lower.contains('.mov') ||
        lower.contains('.webm') ||
        lower.contains('.ts')) {
      return VideoFormat.other;
    }
    // IPTV 地址常无明确后缀，默认按 HLS 处理
    return VideoFormat.hls;
  }

  Widget _buildGestureLayer() {
    if (DeviceUtils.isWindows && _isMiniPlayer) {
      return _buildMiniGestureOverlay();
    }
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () {
          if (DeviceUtils.isWindows) {
            _toggleControlsAndChannelList();
          } else if (DeviceUtils.isMobile) {
            // 手机点击屏幕：列表显示时隐藏列表（点击列表外），否则显示信息。
            if (_showChannelList || _showEpgList) {
              _toggleChannelList();
            } else {
              _showChannelInfoBriefly();
            }
          }
        },
        onLongPress: DeviceUtils.isMobile
            ? () {
                // 手机长按仅显示频道列表，不做隐藏。
                if (!_showChannelList) {
                  _showChannelListAndControls();
                }
              }
            : null,
        onDoubleTap: DeviceUtils.isWindows
            ? () => onWindowsDoubleTap()
            : null,
        onVerticalDragEnd: (details) {
          if (!DeviceUtils.isMobile) return;
          // 回放模式下禁用上下滑动换台，避免与回放逻辑冲突。
          if (_isReplayMode) return;
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < -500) {
            // 向上滑动 → 下一频道
            _playNextChannel();
          } else if (details.primaryVelocity! > 500) {
            // 向下滑动 → 上一频道
            _playPrevChannel();
          }
        },
        onHorizontalDragEnd: (details) {
          if (!DeviceUtils.isMobile) return;
          if (details.primaryVelocity == null) return;
          if (_isReplayMode) {
            // 回放模式下左右滑动快进/快退，定位后直接播放。
            if (details.primaryVelocity! < -500) {
              _seekReplay(const Duration(seconds: 30));
            } else if (details.primaryVelocity! > 500) {
              _seekReplay(const Duration(seconds: -30));
            }
            return;
          }
          if (details.primaryVelocity! < -500) {
            // 向左滑动 → 下一个备选直播源
            _switchToNextBackupUrl();
          } else if (details.primaryVelocity! > 500) {
            // 向右滑动 → 上一个备选直播源
            _switchToPrevBackupUrl();
          }
        },
        child: Container(color: Colors.transparent),
      ),
    );
  }

  // Windows 小窗模式拖动与单击/双击识别。
  DateTime? _miniPointerDownAt;
  Offset? _miniPointerDownPosition;
  Offset? _miniDragStartPosition;
  bool _miniIsDragging = false;
  static const double _miniDragThreshold = 6.0;
  static const int _miniDoubleTapMaxMillis = 300;
  static const double _miniDoubleTapMaxDistance = 40.0;
  static const int _miniSingleTapMaxMillis = 400;
  static const double _miniSingleTapMaxDistance = 40.0;

  Widget _buildMiniGestureOverlay() {
    return Positioned.fill(
      child: Listener(
        behavior: HitTestBehavior.translucent,
        onPointerDown: _onMiniPointerDown,
        onPointerMove: _onMiniPointerMove,
        onPointerUp: _onMiniPointerUp,
        child: Container(color: Colors.transparent),
      ),
    );
  }

  void _onMiniPointerDown(PointerDownEvent event) {
    final now = DateTime.now();
    final lastAt = _miniPointerDownAt;
    final lastPos = _miniPointerDownPosition;

    _miniPointerDownAt = now;
    _miniPointerDownPosition = event.position;
    _miniDragStartPosition = event.position;
    _miniIsDragging = false;

    if (lastAt == null || lastPos == null) return;
    if (now.difference(lastAt).inMilliseconds > _miniDoubleTapMaxMillis) return;
    if ((event.position - lastPos).distance > _miniDoubleTapMaxDistance) return;

    _onMiniDoubleTap();
  }

  void _onMiniPointerMove(PointerMoveEvent event) {
    if (_miniDragStartPosition == null || _miniIsDragging) return;
    if ((event.position - _miniDragStartPosition!).distance <= _miniDragThreshold) {
      return;
    }
    _miniIsDragging = true;
    _miniPointerDownAt = null;
    _miniPointerDownPosition = null;
    windowManager.startDragging();
  }

  void _onMiniPointerUp(PointerUpEvent event) {
    if (_miniIsDragging) {
      _miniDragStartPosition = null;
      _miniIsDragging = false;
      return;
    }
    final downAt = _miniPointerDownAt;
    final downPos = _miniPointerDownPosition;
    _miniDragStartPosition = null;
    _miniIsDragging = false;
    _miniPointerDownAt = null;
    _miniPointerDownPosition = null;

    if (downAt == null || downPos == null) return;
    if (DateTime.now().difference(downAt).inMilliseconds > _miniSingleTapMaxMillis) {
      return;
    }
    if ((event.position - downPos).distance > _miniSingleTapMaxDistance) return;

    _rootFocusNode.requestFocus();
    _toggleControls();
  }

  void _onMiniDoubleTap() {
    if (_isMiniPlayer) {
      _toggleMiniPlayer();
    }
  }

  Widget _buildChannelInfoOverlay() {
    final channel = _currentChannel;
    if (channel == null) return const SizedBox.shrink();
    final program = channel.currentProgram;
    final programTitle = program?.title ?? channel.program?.trim();
    final nextProgram = _findNextProgram(channel);
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;

    return Positioned(
      top: AppSpacing.lg,
      left: AppSpacing.lg,
      child: Container(
        width: 520,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(AppRadius.lg),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: 52,
                  height: 52,
                  margin: const EdgeInsets.only(right: AppSpacing.sm),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: channel.logo != null && channel.logo!.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(AppRadius.md),
                          child: Image.network(
                            channel.logo!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                              Icons.tv,
                              size: 28,
                              color: Colors.white70,
                            ),
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(AppRadius.md),
                          ),
                          child: const Icon(
                            Icons.tv,
                            size: 28,
                            color: Colors.white70,
                          ),
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
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (_isReplayMode && _currentReplayProgram != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            _isReplayPaused && _isReplaySeeking
                                ? '回放定位: ${_currentReplayProgram!.title}'
                                : _isReplayPaused
                                    ? '暂停回放: ${_currentReplayProgram!.title}'
                                    : '回放: ${_currentReplayProgram!.title}',
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: AppColors.primary,
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        )
                      else if (programTitle != null && programTitle.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            programTitle,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                        )
                      else if (channel.group != null && channel.group!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            channel.group!,
                            style: const TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: AppColors.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            if (program != null || channel.hasMultipleUrls || _isReplayMode)
              Padding(
                padding: const EdgeInsets.only(top: AppSpacing.sm),
                child: Row(
                  children: [
                    if (_isReplayMode && _currentReplayProgram != null)
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _replayProgressRatio,
                            backgroundColor: Colors.white.withValues(alpha: 0.12),
                            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                            minHeight: 3,
                          ),
                        ),
                      )
                    else if (program != null)
                      Expanded(
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: program.progressRatio,
                            backgroundColor: Colors.white.withValues(alpha: 0.12),
                            valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                            minHeight: 3,
                          ),
                        ),
                      ),
                    if (program != null && !_isReplayMode)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: Text(
                          '${_formatTime(program.start)}-${_formatTime(program.stop)}',
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (_isReplayMode && _currentReplayProgram != null)
                      Padding(
                        padding: const EdgeInsets.only(left: AppSpacing.sm),
                        child: Text(
                          '${_formatDuration(_replayOffset)} / ${_formatDuration(_currentReplayProgram!.stop.difference(_currentReplayProgram!.start))}',
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: Colors.white70,
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (channel.hasMultipleUrls && !_isReplayMode)
                      Container(
                        margin: EdgeInsets.only(
                          left: program != null ? AppSpacing.sm : 0,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          '源 ${channel.currentBackupIndex + 1}/${channel.allUrls.length}',
                          style: const TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            if (nextProgram != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Row(
                children: [
                  const Text(
                    '下一个: ',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white70,
                      fontSize: 12,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${_formatTime(nextProgram.start)} ${nextProgram.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (hasCatchup && !_isReplayMode) ...[
              const SizedBox(height: AppSpacing.sm),
              GestureDetector(
                onTap: _openEpgListForCurrentChannel,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.history, color: Colors.white, size: 14),
                      SizedBox(width: 4),
                      Text(
                        '节目单/回放',
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  EpgProgram? _findNextProgram(LiveChannel channel) {
    final now = DateTime.now();
    final sorted = _epgProgramsFor(channel);
    for (final p in sorted) {
      if (p.start.isAfter(now)) return p;
    }
    return null;
  }

  double get _replayProgressRatio {
    if (_currentReplayProgram == null) return 0;
    final duration = _currentReplayProgram!.stop.difference(_currentReplayProgram!.start);
    if (duration.inSeconds <= 0) return 0;
    return (_replayOffset.inSeconds / duration.inSeconds).clamp(0.0, 1.0);
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);
    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
    return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
  }

  String _formatTime(DateTime dt) {
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  Widget _buildChannelListOverlay() {
    if (_groups.isEmpty) return const SizedBox.shrink();
    final channelIndices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
    // Windows 版也显示右侧节目单条幅（支持鼠标点击），TV 版使用右键展开。
    final showEpgBanner = !DeviceUtils.isTv || DeviceUtils.isWindows;
    final panelWidth = _kChannelListWidth +
        (showEpgBanner ? _kEpgBannerWidth : 0.0) +
        (showEpgBanner && _showEpgList ? _kEpgListWidth : 0.0);

    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: panelWidth,
      child: Container(
        color: Colors.black.withValues(alpha: 0.82),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Windows 版顶部返回与频道信息栏，与频道列表同层级。
            if (DeviceUtils.isWindows) _buildWindowsChannelListHeader(),
            if (!DeviceUtils.isWindows)
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${_channels.length} 个频道',
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            Container(height: 1, color: Colors.white24),
            Expanded(
              child: Row(
                children: [
                  SizedBox(
                    width: _kCategoryColumnWidth,
                    child: Focus(
                      focusNode: _categoryFocusNode,
                      child: ListView.builder(
                        controller: _categoryScrollController,
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                        itemCount: _groups.length,
                        itemBuilder: (context, index) {
                          return _buildCategoryItem(index);
                        },
                      ),
                    ),
                  ),
                  Container(width: 1, color: Colors.white24),
                  Expanded(
                    child: Focus(
                      focusNode: _channelListFocusNode,
                      child: ListView.builder(
                        controller: _channelListScrollController,
                        padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                        itemCount: channelIndices.length,
                        itemExtent: _kChannelItemHeight,
                        itemBuilder: (context, position) {
                          return _buildChannelListItem(channelIndices[position], position);
                        },
                      ),
                    ),
                  ),
                  if (showEpgBanner) ...[
                    Container(width: 1, color: Colors.white24),
                    SizedBox(
                      width: _kEpgBannerWidth,
                      child: _buildEpgBannerColumn(channelIndices),
                    ),
                  ],
                  if (showEpgBanner && _showEpgList) ...[
                    Container(width: 1, color: Colors.white24),
                    Expanded(
                      child: _buildEpgListPanel(),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              alignment: Alignment.centerLeft,
              child: Text(
                DeviceUtils.isTv && !DeviceUtils.isWindows
                    ? '按右键显示完整节目单，确认键换台'
                    : '点击右侧“节目单”条幅查看完整节目单',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
            ),
            // Windows 版底部控制栏，与频道列表同层级同时显示/隐藏。
            if (DeviceUtils.isWindows) _buildWindowsChannelListControls(),
          ],
        ),
      ),
    );
  }

  /// Windows 版频道列表顶部返回与频道信息栏。
  Widget _buildWindowsChannelListHeader() {
    final channel = _currentChannel;
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          IconButton(
            // Windows 频道列表左上角返回直接退出播放。
            onPressed: handleWindowsEsc,
            icon: const Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '退出播放',
          ),
          const SizedBox(width: AppSpacing.sm),
          if (channel != null)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (channel.group != null && channel.group!.isNotEmpty)
                    Text(
                      channel.group!,
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          Text(
            '${_channels.length} 个频道',
            style: const TextStyle(
              fontFamily: 'NotoSansSC',
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  /// Windows 版频道列表底部控制栏。
  Widget _buildWindowsChannelListControls() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            AppColors.bgOverlay,
            Colors.transparent,
          ],
        ),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: AppSpacing.md,
        runSpacing: AppSpacing.sm,
        children: [
          _buildWindowsControlButton(
            onTap: toggleWindowsFullscreen,
            icon: isWindowsFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
            label: isWindowsFullScreen ? '退出全屏' : '全屏',
          ),
          _buildWindowsControlButton(
            onTap: _toggleMiniPlayer,
            icon: _isMiniPlayer
                ? Icons.picture_in_picture_alt
                : Icons.picture_in_picture_alt_outlined,
            label: _isMiniPlayer ? '恢复窗口' : '小窗播放',
          ),
          _buildWindowsControlButton(
            onTap: _toggleAlwaysOnTop,
            icon: _isAlwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
            label: _isAlwaysOnTop ? '取消置顶' : '置顶窗口',
          ),
        ],
      ),
    );
  }

  /// 非 TV 版频道列表右侧的节目单条幅列。
  Widget _buildEpgBannerColumn(List<int> channelIndices) {
    return ListView.builder(
      controller: _epgBannerScrollController,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: channelIndices.length,
      itemExtent: _kChannelItemHeight,
      itemBuilder: (context, position) {
        final index = channelIndices[position];
        final channel = _channels[index];
        final hasPrograms = channel.programs.isNotEmpty;
        final isOpen = _showEpgList && _epgListChannel?.name == channel.name;
        return GestureDetector(
          onTap: hasPrograms
              ? () => _openEpgListForChannel(channel)
              : null,
          child: Container(
            height: _kChannelItemHeight,
            margin: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: isOpen
                  ? AppColors.primary.withValues(alpha: 0.9)
                  : hasPrograms
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
            ),
            alignment: Alignment.center,
            child: hasPrograms
                ? RotatedBox(
                    quarterTurns: 1,
                    child: Text(
                      '节目单',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: isOpen ? Colors.white : AppColors.textSecondary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : const SizedBox.shrink(),
          ),
        );
      },
    );
  }

  /// 非 TV 版嵌入在频道列表中的节目单面板。
  Widget _buildEpgListPanel() {
    final channel = _epgListChannel ?? _currentChannel;
    if (channel == null || channel.programs.isEmpty) return const SizedBox.shrink();
    final programs = _epgProgramsFor(channel);
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;

    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${channel.name} 节目单',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _closeEpgList,
                  icon: const Icon(Icons.close, color: Colors.white, size: 20),
                  tooltip: '关闭',
                ),
              ],
            ),
          ),
          Container(height: 1, color: Colors.white24),
          Expanded(
            child: Focus(
              focusNode: _epgListFocusNode,
              child: ListView.builder(
                controller: _epgListScrollController,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                itemCount: programs.length,
                itemExtent: 56,
                itemBuilder: (context, index) {
                  return _buildEpgListItem(programs, index, hasCatchup);
                },
              ),
            ),
          ),
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            alignment: Alignment.centerLeft,
            child: Text(
              '确认键回放，关闭按钮隐藏节目单',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 12,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEpgListOverlay() {
    final channel = _currentChannel;
    if (channel == null || channel.programs.isEmpty) return const SizedBox.shrink();

    final programs = _epgProgramsFor(channel);
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;

    return Positioned(
      left: _kChannelListWidth,
      top: 0,
      bottom: 0,
      width: 340,
      child: Container(
        color: Colors.black.withValues(alpha: 0.88),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                height: 56,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${channel.name} 节目单',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${programs.length} 个节目',
                      style: const TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: AppColors.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Container(height: 1, color: Colors.white24),
              Expanded(
                child: Focus(
                  focusNode: _epgListFocusNode,
                  child: ListView.builder(
                    controller: _epgListScrollController,
                    padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                    itemCount: programs.length,
                    itemExtent: 56,
                    itemBuilder: (context, index) {
                      return _buildEpgListItem(programs, index, hasCatchup);
                    },
                  ),
                ),
              ),
              Container(
                height: 40,
                padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                alignment: Alignment.centerLeft,
                child: Text(
                  '← 返回频道    确认键回放',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
              ),
            ],
          ),
        ),
    );
  }

  Widget _buildEpgListItem(
    List<EpgProgram> programs,
    int index,
    bool hasCatchup,
  ) {
    final program = programs[index];
    final isSelected = index == _selectedEpgIndex;
    final isCurrent = program.isCurrent;
    final isPast = program.isPast;
    final canReplay = hasCatchup && isPast;

    return GestureDetector(
      onTap: () {
        setState(() => _selectedEpgIndex = index);
        if (canReplay) {
          _startReplay(program);
        }
      },
      child: Container(
        height: 56,
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.9)
              : isCurrent
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.transparent,
          border: Border.all(
            color: isSelected ? Colors.white.withValues(alpha: 0.8) : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 90,
              child: Text(
                '${_formatTime(program.start)}-${_formatTime(program.stop)}',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: 11,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    program.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.9),
                      fontSize: 13,
                      fontWeight: isCurrent ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  Row(
                    children: [
                      if (isCurrent)
                        Text(
                          '正在播放',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.9)
                                : AppColors.primary,
                            fontSize: 11,
                          ),
                        )
                      else if (canReplay)
                        Text(
                          '支持回放',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.9)
                                : AppColors.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryItem(int index) {
    final group = _groups[index];
    final selected = index == _selectedGroupIndex;
    final focused = selected && _focusOnCategories;
    return GestureDetector(
      onTap: () {
        setState(() {
          _selectedGroupIndex = index;
          _selectedChannelIndexInGroup = 0;
          _focusOnCategories = false;
        });
        _scrollToChannelInGroup();
      },
      child: Container(
        height: 44,
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? AppColors.primary.withValues(alpha: 0.9)
              : Colors.transparent,
          border: Border.all(
            color: focused ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: Text(
          group,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: selected ? Colors.white : Colors.white70,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }

  Widget _buildChannelListItem(int index, int position) {
    final channel = _channels[index];
    final isSelected = index == _currentIndex;
    final focused = position == _selectedChannelIndexInGroup && !_focusOnCategories;
    final program = channel.currentProgram;
    final programText = program?.title ?? channel.program?.trim();
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;
    final hasReplayPrograms = hasCatchup &&
        channel.programs.any((p) => p.stop.isBefore(DateTime.now()));

    return GestureDetector(
      onTap: () {
        _playChannel(index);
        if (DeviceUtils.isWindows) {
          _hideChannelListAndControls();
        } else {
          _toggleChannelList();
        }
      },
      child: Container(
        height: _kChannelItemHeight,
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.9)
              : Colors.white.withValues(alpha: 0.06),
          border: Border.all(
            color: focused
                ? Colors.white.withValues(alpha: 0.9)
                : isSelected
                    ? AppColors.primary.withValues(alpha: 0.6)
                    : Colors.transparent,
            width: 2,
          ),
        ),
        child: Row(
          children: [
            if (isSelected)
              Container(
                width: 4,
                height: 40,
                margin: const EdgeInsets.only(right: AppSpacing.sm),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            SizedBox(
              width: 56,
              height: 56,
              child: channel.logo != null && channel.logo!.isNotEmpty
                  ? Image.network(
                      channel.logo!,
                      fit: BoxFit.contain,
                      errorBuilder: (_, __, ___) => const Icon(
                        Icons.tv,
                        size: 30,
                        color: Colors.white70,
                      ),
                    )
                  : const Icon(
                      Icons.tv,
                      size: 30,
                      color: Colors.white70,
                    ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    channel.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.9),
                      fontSize: 15,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (programText != null && programText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: program?.progressRatio ?? 0,
                                backgroundColor: Colors.white.withValues(alpha: 0.12),
                                valueColor: AlwaysStoppedAnimation<Color>(
                                  isSelected ? Colors.white : AppColors.primary,
                                ),
                                minHeight: 3,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '${program?.elapsedMinutes ?? 0}/${program?.durationMinutes ?? 0}分',
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.9)
                                  : AppColors.textSecondary,
                              fontSize: 10,
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (programText != null && programText.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        programText,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: isSelected
                              ? Colors.white.withValues(alpha: 0.95)
                              : AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    )
                  else if (channel.group != null && channel.group!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(
                        channel.group!,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: AppColors.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  if (hasReplayPrograms)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            Icons.history,
                            size: 12,
                            color: isSelected
                                ? Colors.white.withValues(alpha: 0.9)
                                : AppColors.textSecondary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            '支持回放',
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: isSelected
                                  ? Colors.white.withValues(alpha: 0.9)
                                  : AppColors.textSecondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            if (channel.hasMultipleUrls)
              Container(
                margin: const EdgeInsets.only(left: AppSpacing.sm),
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: isSelected
                      ? Colors.white.withValues(alpha: 0.2)
                      : Colors.white.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(AppRadius.sm),
                ),
                child: Text(
                  '${channel.allUrls.length}',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: isSelected ? Colors.white : Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildWindowsControls() {
    final channel = _currentChannel;
    if (_isMiniPlayer) {
      if (!_controlsVisible) return const SizedBox.shrink();
      return Positioned(
        left: 0,
        right: 0,
        bottom: 0,
        child: _buildMiniPlayerControls(),
      );
    }

    // 频道列表打开时，控制栏只显示在列表右侧，避免遮挡列表。
    final leftInset = _showChannelList ? _kChannelListWidth : 0.0;
    return Positioned(
      left: leftInset,
      top: 0,
      right: 0,
      bottom: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _hideControls,
        child: Container(
          color: Colors.black.withValues(alpha: 0.3),
          child: Column(
            children: [
              // 顶部返回与频道信息
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        AppColors.bgOverlay,
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _onWindowsBack,
                        icon: const Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                        ),
                        tooltip: '返回',
                      ),
                      const SizedBox(width: AppSpacing.sm),
                      if (channel != null)
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                channel.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontFamily: 'NotoSansSC',
                                  color: Colors.white,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              if (channel.group != null &&
                                  channel.group!.isNotEmpty)
                                Text(
                                  channel.group!,
                                  style: const TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    color: AppColors.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              const Spacer(),
              // 底部控制栏
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        AppColors.bgOverlay,
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    spacing: AppSpacing.md,
                    runSpacing: AppSpacing.sm,
                    children: [
                      _buildWindowsControlButton(
                        onTap: toggleWindowsFullscreen,
                        icon: isWindowsFullScreen
                            ? Icons.fullscreen_exit
                            : Icons.fullscreen,
                        label: isWindowsFullScreen ? '退出全屏' : '全屏',
                      ),
                      _buildWindowsControlButton(
                        onTap: _toggleMiniPlayer,
                        icon: _isMiniPlayer
                            ? Icons.picture_in_picture_alt
                            : Icons.picture_in_picture_alt_outlined,
                        label: _isMiniPlayer ? '恢复窗口' : '小窗播放',
                      ),
                      _buildWindowsControlButton(
                        onTap: _toggleAlwaysOnTop,
                        icon: _isAlwaysOnTop
                            ? Icons.push_pin
                            : Icons.push_pin_outlined,
                        label: _isAlwaysOnTop ? '取消置顶' : '置顶窗口',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniPlayerControls() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.bottomCenter,
            end: Alignment.topCenter,
            colors: [
              AppColors.bgOverlay.withValues(alpha: 0.9),
              Colors.transparent,
            ],
          ),
        ),
        child: SafeArea(
          child: Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.xs,
            children: [
              _buildMiniControlIconButton(
                onTap: _onWindowsBack,
                icon: Icons.arrow_back,
                tooltip: '返回',
              ),
              _buildMiniControlIconButton(
                onTap: toggleWindowsFullscreen,
                icon: isWindowsFullScreen
                    ? Icons.fullscreen_exit
                    : Icons.fullscreen,
                tooltip: isWindowsFullScreen ? '退出全屏' : '全屏',
              ),
              _buildMiniControlIconButton(
                onTap: _toggleMiniPlayer,
                icon: Icons.open_in_full,
                tooltip: '恢复窗口',
              ),
              _buildMiniControlIconButton(
                onTap: _toggleAlwaysOnTop,
                icon: _isAlwaysOnTop
                    ? Icons.push_pin
                    : Icons.push_pin_outlined,
                tooltip: _isAlwaysOnTop ? '取消置顶' : '窗口置顶',
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniControlIconButton({
    required VoidCallback onTap,
    required IconData icon,
    required String tooltip,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppColors.bgElevated.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Icon(icon, color: AppColors.textPrimary, size: 22),
        ),
      ),
    );
  }

  Widget _buildWindowsControlButton({
    required VoidCallback onTap,
    required IconData icon,
    required String label,
  }) {
    return Tooltip(
      message: label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.md),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: AppColors.bgElevated.withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              const SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: Colors.white,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
