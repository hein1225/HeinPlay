import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:video_player/video_player.dart';
import 'package:window_manager/window_manager.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/live_channel.dart';
import '../models/live_source_config.dart';
import '../platform/device_utils.dart';
import '../platform/windows_fullscreen_mixin.dart';
import '../platform/windows_window_utils.dart';
import '../services/ad_filter_engine.dart';
import '../services/live_service.dart';
import '../services/user_data_service.dart';
import '../theme.dart';
import '../utils/windows_logger.dart';
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
  /// 当前已加载回放流对应的起始偏移（用于计算流内实时定位）。
  Duration _replayBaseOffset = Duration.zero;
  /// 回放按住快进/快退定时器。
  Timer? _replayHoldTimer;
  /// 回放按住是否为快进。
  bool _replayHoldForward = false;
  /// 回放快进/快退手势标识是否显示。
  bool _replayGestureVisible = false;
  /// 回放手势标识是否为快进。
  bool _replayGestureForward = false;
  /// 回放手势标识类型：'seek' 快进/快退，'pause' 暂停/播放。
  String _replayGestureKind = 'seek';
  /// 回放手势标识自动隐藏定时器。
  Timer? _replayGestureTimer;
  /// 直播播放器控制器（用于回放流内实时定位画面）。
  final LivePlayerController _livePlayerController = LivePlayerController();

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

  /// 是否正在执行 Windows 退出播放流程（暂停渲染后延迟 pop），防止重复触发。
  bool _exitingWindowsPlayback = false;

  // Windows 全屏鼠标自动隐藏（仅全屏时启用）
  /// 鼠标无操作自动隐藏定时器。
  Timer? _mouseInactivityTimer;
  /// 当前光标是否已隐藏。
  bool _isCursorHidden = false;
  /// 鼠标无操作多少秒后自动隐藏光标。
  static const Duration _kMouseHideDelay = Duration(seconds: 5);

  static const Size _kUnboundedSize = Size(100000, 100000);
  static const Size _kNormalMinSize = Size(900, 600);
  static const Size _kMiniMinSize = Size(320, 180);
  static const double _kChannelListWidth = 480;
  static const double _kCategoryColumnWidth = 100;
  static const double _kChannelItemHeight = 102;
  static const double _kEpgBannerWidth = 56.0;
  static const double _kEpgListWidth = 340.0;

  // 手机版紧凑布局参数
  static const double _kMobileChannelListMargin = 8.0;
  static const double _kMobileCategoryColumnWidth = 72.0;
  static const double _kMobileChannelItemHeight = 64.0;
  static const double _kMobileEpgBannerWidth = 36.0;

  double get _channelItemHeight =>
      DeviceUtils.isMobile ? _kMobileChannelItemHeight : _kChannelItemHeight;

  double get _categoryColumnWidth => DeviceUtils.isMobile
      ? _kMobileCategoryColumnWidth
      : _kCategoryColumnWidth;

  double get _epgBannerWidth =>
      DeviceUtils.isMobile ? _kMobileEpgBannerWidth : _kEpgBannerWidth;

  double _channelListWidth(BuildContext context) {
    if (DeviceUtils.isMobile) {
      return MediaQuery.sizeOf(context).width - _kMobileChannelListMargin * 2;
    }
    final showEpgBanner = !DeviceUtils.isTv || DeviceUtils.isWindows;
    return _kChannelListWidth +
        (showEpgBanner ? _kEpgBannerWidth : 0.0) +
        (showEpgBanner && _showEpgList ? _kEpgListWidth : 0.0);
  }

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
      _resetMouseTimer();
    }
    if (DeviceUtils.isMobile) {
      _enterFullscreenLandscape();
    }
    _initWakelock();
  }

  /// 直播 / 回拨模式播放期间保持屏幕常亮，避免手机自动休眠。
  Future<void> _initWakelock() async {
    try {
      await WakelockPlus.enable();
      debugPrint('LivePlayerScreen: 已启用屏幕常亮');
    } catch (e) {
      debugPrint('LivePlayerScreen: 启用屏幕常亮失败: $e');
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

    // 直播优先：进入播放页先只拉频道列表并立即开播，catchup / EPG 补全与
    // 节目单拉取放到播放开始后的后台任务（_loadEpgForChannels）中，避免阻塞首帧。
    final response = await LiveService.loadChannelsForSource(
      widget.source,
      fillCatchup: false,
    );
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
    // 直播优先：进入播放页后频道列表已就绪并立即开播，
    // 节目单/时移元数据在后台加载，绝不在首屏路径上阻塞。
    // 若用户在"软件设置→直播设置"中关闭了 EPG 加载，则完全跳过，进一步提速。
    final epgEnabled = await UserDataService.getEpgLoadEnabled();
    if (!epgEnabled) return;

    // 首屏为追求速度跳过了 catchup 补全（fillCatchup=false），
    // 这里在后台补齐，确保稍后打开回放时可用。
    final needCatchupFill = channels.any(
      (c) =>
          (c.catchup == null || c.catchup!.isEmpty) &&
          (c.catchupSource == null || c.catchupSource!.isEmpty),
    );
    if (needCatchupFill) {
      final fillUrl =
          LiveService.extractSourceUrlFromChannels(channels) ?? widget.source.url;
      if (fillUrl.isNotEmpty) {
        await LiveService.fillEpgAndCatchupFromM3uUrl(channels, fillUrl);
        await LiveService.cacheChannels(widget.source, channels);
      }
    }

    // 节目单刷新周期固定（12 小时），节目单每天内容都会变化需定期更新。
    // 缓存内节目单仍在刷新周期内时复用，并按当前时间刷新当前节目信息，
    // 避免重复拉取 EPG，减少网络请求与积分消耗。
    final hasCachedPrograms = channels.any((c) => c.programs.isNotEmpty);
    if (hasCachedPrograms && await LiveService.isEpgCacheFresh(widget.source)) {
      LiveService.refreshCurrentPrograms(channels);
      if (mounted) setState(() {});
      return;
    }

    // 拉取最新 EPG；解析失败时不修改频道（保留已有节目单），不影响正常显示。
    final ok = await LiveService.fetchEpg(channels, epgUrl: widget.source.epgUrl);
    // EPG 拉取后，把包含节目单的完整频道数据写回缓存，
    // 下次进入直播页即可直接恢复节目单，无需再次请求。
    await LiveService.cacheChannels(widget.source, channels);
    // 仅当本次成功解析后才刷新节目单时间戳；失败时不进入"新鲜"状态，
    // 下次进入仍会重新尝试拉取。
    if (ok) {
      await LiveService.markEpgCached(widget.source);
    }
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
    // 回放流起点固定为当前已加载流的起始偏移，避免快进快退时每次重建播放器；
    // 用户当前播放位置由 _replayOffset 表示，流内定位走 seek 而非重建。
    final playAt = start.add(_replayBaseOffset);

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
      pos = (_channelListScrollController.offset / _channelItemHeight).floor();
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
    final targetOffset = _selectedChannelIndexInGroup * _channelItemHeight;
    final viewport = _channelListScrollController.position.viewportDimension;
    final currentOffset = _channelListScrollController.offset;
    if (targetOffset < currentOffset ||
        targetOffset + _channelItemHeight > currentOffset + viewport) {
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

  /// Windows 退出播放：先暂停直播渲染（停止 mdk 推帧），再延迟执行 pop。
  ///
  /// 直播流渲染期间直接 pop，route 动画/页面销毁会与 mdk 渲染线程竞争
  /// 纹理与窗口资源，偶发死锁导致软件卡死闪退（日志表现为 pop 前页面未销毁）。
  /// 先暂停停止推帧，等渲染线程空闲后再 pop 可规避该竞态。
  void _exitWindowsPlayback() {
    if (!DeviceUtils.isWindows || _exitingWindowsPlayback) return;
    _exitingWindowsPlayback = true;
    WindowsLogger.log('LivePlayerScreen', 'Windows 退出播放：暂停渲染后 pop');
    unawaited(_livePlayerController.pause());
    Future<void>.delayed(const Duration(milliseconds: 150), () {
      if (mounted) {
        // 直接 pop 绕过 canPop（Windows 下 canPop 恒 false），
        // 避免再次进入 onPopInvoked 导致死循环。
        Navigator.of(context).pop();
      }
    });
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    // 页面销毁后 handler 可能仍在收到按键（如 ESC 的 KeyUp 落在 pop 销毁窗口），
    // 访问 defunct context 会抛异常导致闪退，先做 mounted 防护。
    if (!mounted) return false;
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
            // Windows：频道列表显示时返回键直接退出播放（返回直播管理页），
            // 返回 false 交给全局 handler（app_windows._handleEscKey）执行 pop。
            return false;
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
          // Windows：ESC 统一交给全局 handler（app_windows._handleEscKey）执行
          // maybePop，由本页 PopScope 决定：全屏先退出全屏、否则返回直播管理页。
          // HardwareKeyboard 会调用所有注册的 handler，若这里也处理 ESC 会与全局
          // handler 同时触发异步窗口操作导致并发卡死/闪退，因此返回 false 不消费。
          return false;
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
    // 与点播模式一致：双击暂停/播放时显示手势标识反馈。
    _showReplayPauseIndicator(!nextPaused);
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
      'program.stop=${program.stop}, channelNow=${channel.channelNow}',
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
      _replayBaseOffset = Duration.zero;
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
    _replayHoldTimer?.cancel();
    _replayHoldTimer = null;
    setState(() {
      _isReplayMode = false;
      _currentReplayProgram = null;
      _replayOffset = Duration.zero;
      _replayBaseOffset = Duration.zero;
      _isReplayPaused = false;
      _isReplaySeeking = false;
    });
    _showChannelInfoBriefly();
  }

  /// 回放时快进/快退指定偏移。
  ///
  /// 直接更新回放起始位置并继续播放，无需再按确认键。
  void _seekReplay(Duration delta) {
    if (!_isReplayMode || _currentReplayProgram == null || _currentChannel == null) return;
    final maxOffset = _currentChannel!.channelNow
        .difference(_currentChannel!.toChannelTimezone(_currentReplayProgram!.start));
    var newOffset = _replayOffset + delta;
    if (newOffset < Duration.zero) newOffset = Duration.zero;
    if (newOffset > maxOffset) newOffset = maxOffset;
    setState(() {
      _replayOffset = newOffset;
      // 重建回放流后，流起点即新偏移。
      _replayBaseOffset = newOffset;
      _isReplaySeeking = false;
      _isReplayPaused = false;
    });
    _showReplayGestureIndicator(delta >= Duration.zero);
    _showChannelInfoBriefly();
  }

  /// 显示回放快进/快退手势标识。
  ///
  /// [persistent] 为 true 时（手机版长按）持续显示直至手动隐藏；
  /// 为 false 时（TV/Windows 按键）1 秒后自动隐藏。
  void _showReplayGestureIndicator(bool forward, {bool persistent = false}) {
    _replayGestureTimer?.cancel();
    setState(() {
      _replayGestureVisible = true;
      _replayGestureKind = 'seek';
      _replayGestureForward = forward;
    });
    if (!persistent) {
      _replayGestureTimer = Timer(const Duration(seconds: 1), () {
        if (mounted) {
          setState(() => _replayGestureVisible = false);
        }
      });
    }
  }

  /// 显示回放暂停/播放手势标识（样式与点播模式一致），1 秒后自动隐藏。
  ///
  /// [playing] 为 true 表示切换后处于播放状态，显示"播放"；否则显示"暂停"。
  void _showReplayPauseIndicator(bool playing) {
    _replayGestureTimer?.cancel();
    setState(() {
      _replayGestureVisible = true;
      _replayGestureKind = 'pause';
      _replayGestureForward = playing;
    });
    _replayGestureTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() => _replayGestureVisible = false);
      }
    });
  }

  /// 隐藏回放快进/快退手势标识（手机版长按结束时调用）。
  void _hideReplayGestureIndicator() {
    _replayGestureTimer?.cancel();
    _replayGestureTimer = null;
    if (_replayGestureVisible && mounted) {
      setState(() => _replayGestureVisible = false);
    }
  }

  /// 手机端回放模式：按住屏幕左侧半屏持续快退，右侧半屏持续快进。
  void _startReplayHoldSeek(bool forward) {
    if (!_isReplayMode || _currentReplayProgram == null || _currentChannel == null) return;
    _replayHoldForward = forward;
    _replayHoldTimer?.cancel();
    _replayHoldTimer = null;
    // 快进快退期间保持信息卡（含进度条）一直显示，取消自动隐藏。
    _channelInfoTimer?.cancel();
    _channelInfoTimer = null;
    setState(() {
      _showChannelInfo = true;
      _isReplaySeeking = true;
      // 与点播模式一致：长按期间保持播放状态，通过持续 seek 定位画面实现快进快退，
      // 不暂停播放，避免"暂停 + 连续 seek"导致底层播放器状态异常卡死、松手无法恢复。
    });
    // 先标记正在快进快退，再执行首次定位，避免被 _replayHoldTick 的防御检查拦截。
    _replayHoldTick();
    _replayHoldTimer = Timer.periodic(
      const Duration(milliseconds: 250),
      (_) => _replayHoldTick(),
    );
    // 长按期间持续显示快进/快退手势标识。
    _showReplayGestureIndicator(forward, persistent: true);
  }

  void _replayHoldTick() {
    // 防御检查：松手/退出回放后即使定时器有残余触发也直接忽略，避免继续快进快退。
    if (!_isReplaySeeking || !_isReplayMode) return;
    if (_currentReplayProgram == null || _currentChannel == null) return;
    final maxOffset = _currentChannel!.channelNow
        .difference(_currentChannel!.toChannelTimezone(_currentReplayProgram!.start));
    var newOffset =
        _replayOffset + Duration(seconds: _replayHoldForward ? 5 : -5);
    if (newOffset < Duration.zero) newOffset = Duration.zero;
    if (newOffset > maxOffset) newOffset = maxOffset;
    setState(() {
      _replayOffset = newOffset;
      // 与 TV/Windows 版按键逻辑一致：重建回放流，流起点即新偏移。
      // 部分播放器后端（如 fvp/libmdk）对 catchup 流的相对 seek 无效，
      // 会导致画面持续快进无法定位，因此手机版长按同样采用重建流方式。
      _replayBaseOffset = newOffset;
    });
    // 长按期间持续显示快进/快退手势标识（每次 tick 重置，保持常显）。
    _showReplayGestureIndicator(_replayHoldForward, persistent: true);
  }

  void _stopReplayHoldSeek() {
    // 无论回放模式状态如何都先取消定时器，确保松手后快进快退停止。
    final wasSeeking = _isReplaySeeking || _replayHoldTimer != null;
    _replayHoldTimer?.cancel();
    _replayHoldTimer = null;
    if (!_isReplayMode || !wasSeeking) return;
    setState(() {
      _isReplaySeeking = false;
      // 长按期间保持播放状态，松手后无需恢复播放，直接继续自动播放。
    });
    // 松手结束长按，隐藏手势标识，并重新启动信息卡自动隐藏。
    _hideReplayGestureIndicator();
    _channelInfoTimer?.cancel();
    _channelInfoTimer = Timer(const Duration(seconds: 5), () {
      if (mounted && !_isReplaySeeking) {
        setState(() => _showChannelInfo = false);
      }
    });
  }

  /// 判断指定节目是否可回放。
  bool _canReplay(LiveChannel channel, EpgProgram program) {
    final hasCatchup =
        (channel.catchupSource != null && channel.catchupSource!.isNotEmpty) ||
            (channel.catchup != null && channel.catchup!.isNotEmpty);
    if (!hasCatchup) return false;
    return channel.isProgramPast(program);
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
    // 默认选中频道所在时区当前正在播放的节目。
    final now = channel.channelNow;
    var initialIndex = 0;
    for (var i = 0; i < programs.length; i++) {
      final start = channel.toChannelTimezone(programs[i].start);
      final stop = channel.toChannelTimezone(programs[i].stop);
      if (start.isBefore(now) && stop.isAfter(now)) {
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
    WindowsLogger.log('LivePlayerScreen', 'dispose 开始');
    _channelInfoTimer?.cancel();
    _controlsTimer?.cancel();
    _replayGestureTimer?.cancel();
    _replayHoldTimer?.cancel();
    if (DeviceUtils.isTv || DeviceUtils.isWindows) {
      HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    }
    if (DeviceUtils.isWindows) {
      disposeWindowsFullscreen();
      _mouseInactivityTimer?.cancel();
      _mouseInactivityTimer = null;
      // 页面销毁时确保光标恢复可见，避免鼠标隐藏状态泄漏到其它页面。
      WindowsWindowUtils.setCursorVisible(true);
    }
    // 释放可能存在的本地代理，避免 Windows 退出时资源未释放导致闪退。
    AdFilterEngine.dispose();
    if (DeviceUtils.isMobile) {
      unawaited(SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge));
      unawaited(_restoreOrientation());
    }
    _selectLongPressTimer?.cancel();
    WakelockPlus.disable().catchError((Object e) {
      debugPrint('LivePlayerScreen: 关闭屏幕常亮失败: $e');
    });
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
    WindowsLogger.log('LivePlayerScreen', 'dispose 结束');
  }

  @override
  Widget build(BuildContext context) {
    // 仅在直播模式且列表/节目单均隐藏时返回键退出播放页；
    // 回放模式先退出回放，节目单显示时先关闭节目单，全屏时先退出全屏。
    // Windows：canPop 恒为 false，所有退出统一由 onPopInvoked 处理——
    // 先暂停直播渲染（停止 mdk 推帧）再 pop，避免 pop 动画与直播渲染线程
    // 偶发死锁导致退出卡死；TV/手机保持"列表显示时先关列表"的原行为。
    // 全屏切换过程中禁止 pop，避免销毁与窗口操作并发导致卡死。
    final canPop = !isWindowsFullScreen &&
        !isTogglingWindowsFullscreen &&
        !_isReplayMode &&
        !_showEpgList &&
        (DeviceUtils.isWindows ? false : !_showChannelList);
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (isWindowsFullScreen) {
          handleWindowsEsc();
        } else if (_isReplayMode) {
          _exitReplayMode();
        } else if (_showEpgList) {
          _closeEpgList();
        } else if (_showChannelList) {
          if (DeviceUtils.isWindows) {
            // Windows：频道列表显示时返回键直接退出播放。
            _exitWindowsPlayback();
          } else {
            _toggleChannelList();
          }
        } else if (DeviceUtils.isWindows) {
          _exitWindowsPlayback();
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
              // 回放快进/快退手势标识（居中显示）。
              _buildReplayGestureIndicator(),
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

    // 若当前直播源配置了播放代理，通过特殊请求头传递给播放器底层。
    // 内部键以 x-heinplay- 前缀标识，原生层构造数据源时会剥离，不会发送到上游。
    final sourceProxy = widget.source.proxyUrl;
    final extraHeaders = (sourceProxy != null && sourceProxy.isNotEmpty)
        ? <String, String>{'x-heinplay-proxy-url': sourceProxy}
        : null;

    return LivePlayer(
      key: ValueKey('${_currentChannel!.name}_$playUrl'),
      url: playUrl,
      formatHint: formatHint,
      paused: _isReplayMode && _isReplayPaused,
      controller: _livePlayerController,
      headers: extraHeaders,
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

  /// 重置鼠标无操作定时器（仅 Windows 全屏时生效）。
  ///
  /// 每次鼠标移动都会触发本方法：取消旧的隐藏定时器，若光标已隐藏则先恢复
  /// 显示，再重新启动 [._kMouseHideDelay] 后的自动隐藏。非全屏时仅确保光标
  /// 可见并取消定时器，不启用自动隐藏。
  void _resetMouseTimer() {
    if (!DeviceUtils.isWindows) return;
    _mouseInactivityTimer?.cancel();
    _mouseInactivityTimer = null;
    if (!isWindowsFullScreen) {
      // 非全屏不启用自动隐藏，并确保光标恢复可见。
      if (_isCursorHidden) {
        WindowsWindowUtils.setCursorVisible(true);
        _isCursorHidden = false;
      }
      return;
    }
    if (_isCursorHidden) {
      _showCursor();
    }
    _mouseInactivityTimer = Timer(_kMouseHideDelay, _hideCursor);
  }

  /// 隐藏鼠标光标（仅 Windows 全屏时生效）。
  void _hideCursor() {
    if (!DeviceUtils.isWindows || !isWindowsFullScreen) return;
    if (!mounted || _isCursorHidden) return;
    WindowsWindowUtils.setCursorVisible(false);
    _isCursorHidden = true;
    debugPrint('LivePlayerScreen: 全屏鼠标无操作，已自动隐藏光标');
  }

  /// 显示鼠标光标。
  void _showCursor() {
    if (!DeviceUtils.isWindows || !mounted) return;
    if (!_isCursorHidden) return;
    WindowsWindowUtils.setCursorVisible(true);
    _isCursorHidden = false;
  }

  @override
  void onWindowEnterFullScreen() {
    super.onWindowEnterFullScreen();
    // 进入全屏后启动鼠标无操作自动隐藏。
    _resetMouseTimer();
  }

  @override
  void onWindowLeaveFullScreen() {
    super.onWindowLeaveFullScreen();
    // 退出全屏后恢复光标显示并停用自动隐藏。
    _resetMouseTimer();
  }

  Widget _buildGestureLayer() {
    if (DeviceUtils.isWindows && _isMiniPlayer) {
      return _buildMiniGestureOverlay();
    }
    return Positioned.fill(
      child: MouseRegion(
        // 鼠标移动时重置无操作定时器（Windows 全屏自动隐藏光标）。
        onHover: (_) => _resetMouseTimer(),
        onExit: (_) => _resetMouseTimer(),
        child: Listener(
        behavior: HitTestBehavior.translucent,
        // 兜底：手势竞技场中 onLongPressEnd/onLongPressCancel 可能不被触发，
        // 监听指针抬起确保手机端松手后一定停止快进快退（_stopReplayHoldSeek 幂等）。
        onPointerUp:
            DeviceUtils.isMobile ? (_) => _stopReplayHoldSeek() : null,
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
        onLongPressStart: DeviceUtils.isMobile
            ? (details) {
                if (_isReplayMode) {
                  // 回放模式：按住屏幕左边持续快退，右边持续快进。
                  final width = MediaQuery.sizeOf(context).width;
                  _startReplayHoldSeek(details.localPosition.dx >= width / 2);
                } else if (!_showChannelList) {
                  // 直播模式长按仅显示频道列表，不做隐藏。
                  _showChannelListAndControls();
                }
              }
            : null,
        onLongPressEnd: DeviceUtils.isMobile ? (_) => _stopReplayHoldSeek() : null,
        onLongPressCancel: DeviceUtils.isMobile ? _stopReplayHoldSeek : null,
        onDoubleTap: DeviceUtils.isWindows
            ? () => onWindowsDoubleTap()
            : (DeviceUtils.isMobile && _isReplayMode)
                ? () => _toggleReplayPause()
                : null,
        onVerticalDragEnd: (details) {
          if (!DeviceUtils.isMobile) return;
          // 回放模式下禁用上下滑动换台，避免与回放逻辑冲突。
          if (_isReplayMode) return;
          if (details.primaryVelocity == null) return;
          if (details.primaryVelocity! < -500) {
            // 向上滑动 → 上一频道
            _playPrevChannel();
          } else if (details.primaryVelocity! > 500) {
            // 向下滑动 → 下一频道
            _playNextChannel();
          }
        },
        onHorizontalDragEnd: (details) {
          if (!DeviceUtils.isMobile) return;
          // 回放模式使用长按左/右半屏快退快进，不再响应左右滑动。
          if (_isReplayMode) return;
          if (details.primaryVelocity == null) return;
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
      ),
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

  /// 回放快进/快退与暂停/播放手势标识浮层（居中显示，样式与点播模式一致）。
  Widget _buildReplayGestureIndicator() {
    if (!_replayGestureVisible) return const SizedBox.shrink();
    final bool isPauseKind = _replayGestureKind == 'pause';
    final IconData icon;
    final String text;
    if (isPauseKind) {
      // 暂停/播放标识（双击触发，与点播模式一致）。
      icon = _replayGestureForward ? Icons.play_arrow : Icons.pause;
      text = _replayGestureForward ? '播放' : '暂停';
    } else {
      // 快进/快退标识（长按或按键触发）。
      icon = _replayGestureForward ? Icons.fast_forward : Icons.fast_rewind;
      text = _replayGestureForward ? '快进中' : '快退中';
    }
    return Center(
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppColors.bgOverlay,
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: AppColors.textPrimary,
              size: 32,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              text,
              style: const TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                color: AppColors.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelInfoOverlay() {
    final channel = _currentChannel;
    if (channel == null) return const SizedBox.shrink();
    final program = channel.currentProgram;
    final programTitle = program?.title ?? channel.program?.trim();
    final nextProgram = _findNextProgram(channel);
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;
    final isMobile = DeviceUtils.isMobile;
    final screenWidth = MediaQuery.sizeOf(context).width;
    // 手机版换台信息卡更短更窄，避免遮挡画面。
    final cardWidth = isMobile
        ? min(240.0, screenWidth - AppSpacing.md * 2)
        : 520.0;
    final showProgress = program != null || _isReplayMode;

    return Positioned(
      top: isMobile ? AppSpacing.sm : AppSpacing.lg,
      left: isMobile ? AppSpacing.sm : AppSpacing.lg,
      child: Container(
        width: cardWidth,
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(isMobile ? AppRadius.md : AppRadius.lg),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        child: Stack(
          children: [
            // 节目进度条作为背景显示在底部，不单独占一行。
            if (showProgress)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: _isReplayMode
                      ? _replayProgressRatio
                      : (program != null ? channel.programProgressRatio(program) : 0),
                  backgroundColor: Colors.white.withValues(alpha: 0.1),
                  valueColor: const AlwaysStoppedAnimation<Color>(AppColors.primary),
                  minHeight: 3,
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isMobile ? AppSpacing.sm : AppSpacing.md,
                vertical: isMobile ? AppSpacing.xs : AppSpacing.sm,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Container(
                  width: isMobile ? 36 : 52,
                  height: isMobile ? 36 : 52,
                  margin: EdgeInsets.only(
                    right: isMobile ? AppSpacing.xs : AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(
                      isMobile ? AppRadius.sm : AppRadius.md,
                    ),
                  ),
                  child: channel.logo != null && channel.logo!.isNotEmpty
                      ? ClipRRect(
                          borderRadius: BorderRadius.circular(
                            isMobile ? AppRadius.sm : AppRadius.md,
                          ),
                          child: Image.network(
                            channel.logo!,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => Icon(
                              Icons.tv,
                              size: isMobile ? 20 : 28,
                              color: Colors.white70,
                            ),
                          ),
                        )
                      : Container(
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.08),
                            borderRadius: BorderRadius.circular(
                              isMobile ? AppRadius.sm : AppRadius.md,
                            ),
                          ),
                          child: Icon(
                            Icons.tv,
                            size: isMobile ? 20 : 28,
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
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: isMobile ? 14 : 18,
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
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: AppColors.primary,
                              fontSize: isMobile ? 11 : 12,
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
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: Colors.white70,
                              fontSize: isMobile ? 11 : 13,
                            ),
                          ),
                        )
                      else if (channel.group != null && channel.group!.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            channel.group!,
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: AppColors.textSecondary,
                              fontSize: isMobile ? 10 : 12,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
            // 回放/节目时间信息（进度条已在背景中显示）。
            if (_isReplayMode && _currentReplayProgram != null)
              Padding(
                padding: EdgeInsets.only(top: isMobile ? 2 : AppSpacing.sm),
                child: Text(
                  '${_formatDuration(_replayOffset)} / ${_formatDuration(_currentReplayProgram!.stop.difference(_currentReplayProgram!.start))}',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    color: Colors.white70,
                    fontSize: isMobile ? 10 : 11,
                  ),
                ),
              )
            else if (program != null)
              Padding(
                padding: EdgeInsets.only(top: isMobile ? 2 : AppSpacing.sm),
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        '${_formatTime(channel.toChannelTimezone(program.start))}-${_formatTime(channel.toChannelTimezone(program.stop))}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white70,
                          fontSize: isMobile ? 10 : 11,
                        ),
                      ),
                    ),
                    if (channel.hasMultipleUrls)
                      Container(
                        margin: const EdgeInsets.only(left: AppSpacing.xs),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
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
              SizedBox(height: isMobile ? 2 : AppSpacing.sm),
              Row(
                children: [
                  Text(
                    '下一个: ',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white70,
                      fontSize: isMobile ? 10 : 12,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${_formatTime(channel.toChannelTimezone(nextProgram.start))} ${nextProgram.title}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Colors.white,
                        fontSize: isMobile ? 10 : 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ],
            if (hasCatchup && !_isReplayMode) ...[
              SizedBox(height: isMobile ? 2 : AppSpacing.sm),
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
        ],
      ),
      ),
    );
  }

  EpgProgram? _findNextProgram(LiveChannel channel) {
    final now = channel.channelNow;
    final sorted = _epgProgramsFor(channel);
    for (final p in sorted) {
      if (channel.toChannelTimezone(p.start).isAfter(now)) return p;
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
    final isMobile = DeviceUtils.isMobile;
    // Windows 版也显示右侧节目单条幅（支持鼠标点击），TV 版使用右键展开。
    // 手机版显示完整节目单时隐藏“节目单”条幅，由完整节目单替换其位置。
    final showEpgBanner = (!DeviceUtils.isTv || DeviceUtils.isWindows) &&
        !(isMobile && _showEpgList);
    final showEpgPanel = _showEpgList && (!DeviceUtils.isTv || DeviceUtils.isWindows);
    final panelWidth = _channelListWidth(context);
    final left = isMobile ? _kMobileChannelListMargin : 0.0;
    // 手机端字体自适应：以 360 逻辑宽度为基准，叠加系统字体缩放，随屏幕大小与字体设置自动调整。
    final fontScale = DeviceUtils.isMobile
        ? (MediaQuery.sizeOf(context).width / 360).clamp(0.9, 1.15) *
            MediaQuery.textScalerOf(context).scale(1.0)
        : 1.0;

    return Positioned(
      left: left,
      top: 0,
      bottom: 0,
      width: panelWidth,
      child: MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(fontScale),
        ),
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
                    width: _categoryColumnWidth,
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
                        itemExtent: _channelItemHeight,
                        itemBuilder: (context, position) {
                          return _buildChannelListItem(channelIndices[position], position);
                        },
                      ),
                    ),
                  ),
                  if (showEpgBanner) ...[
                    Container(width: 1, color: Colors.white24),
                    SizedBox(
                      width: _epgBannerWidth,
                      child: _buildEpgBannerColumn(channelIndices),
                    ),
                  ],
                  if (showEpgPanel) ...[
                    Container(width: 1, color: Colors.white24),
                    SizedBox(
                      width: isMobile
                          ? MediaQuery.sizeOf(context).width / 3
                          : _kEpgListWidth,
                      child: _buildEpgListPanel(),
                    ),
                  ],
                ],
              ),
            ),
            Container(
              height: isMobile ? 32 : 40,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
              alignment: Alignment.centerLeft,
              child: Text(
                DeviceUtils.isTv && !DeviceUtils.isWindows
                    ? '按右键显示完整节目单，确认键换台'
                    : isMobile
                        ? '点击“节目单”查看完整节目单'
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
    final isMobile = DeviceUtils.isMobile;
    return ListView.builder(
      controller: _epgBannerScrollController,
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      itemCount: channelIndices.length,
      itemExtent: _channelItemHeight,
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
            height: _channelItemHeight,
            margin: EdgeInsets.symmetric(
              horizontal: isMobile ? 2 : AppSpacing.xs,
              vertical: AppSpacing.xs,
            ),
            decoration: BoxDecoration(
              color: isOpen
                  ? AppColors.primary.withValues(alpha: 0.9)
                  : hasPrograms
                      ? Colors.white.withValues(alpha: 0.08)
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(isMobile ? 2 : AppRadius.sm),
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
                        fontSize: isMobile ? 10 : 11,
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
    final isMobile = DeviceUtils.isMobile;

    return Container(
      color: isMobile ? AppColors.bgApp : Colors.black.withValues(alpha: 0.88),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            height: isMobile ? 44 : 56,
            padding: EdgeInsets.symmetric(horizontal: isMobile ? AppSpacing.sm : AppSpacing.md),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '${channel.name} 节目单',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white,
                      fontSize: isMobile ? 14 : 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: _closeEpgList,
                  icon: Icon(Icons.close, color: Colors.white, size: isMobile ? 18 : 20),
                  tooltip: '关闭',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
                itemExtent: isMobile ? 44 : 56,
                itemBuilder: (context, index) {
                  return _buildEpgListItem(channel, programs, index, hasCatchup);
                },
              ),
            ),
          ),
          Container(
            height: isMobile ? 32 : 40,
            padding: EdgeInsets.symmetric(horizontal: isMobile ? AppSpacing.sm : AppSpacing.md),
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
                      return _buildEpgListItem(channel, programs, index, hasCatchup);
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
    LiveChannel channel,
    List<EpgProgram> programs,
    int index,
    bool hasCatchup,
  ) {
    final program = programs[index];
    final isSelected = index == _selectedEpgIndex;
    final isCurrent = channel.isProgramCurrent(program);
    final isPast = channel.isProgramPast(program);
    final canReplay = hasCatchup && isPast;
    final isMobile = DeviceUtils.isMobile;

    return GestureDetector(
      onTap: () {
        setState(() => _selectedEpgIndex = index);
        if (canReplay) {
          _startReplay(program);
        }
      },
      child: Container(
        height: isMobile ? 44 : 56,
        margin: EdgeInsets.symmetric(
          horizontal: isMobile ? AppSpacing.xs : AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
        padding: EdgeInsets.symmetric(horizontal: isMobile ? AppSpacing.sm : AppSpacing.md),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.9)
              : isCurrent
                  ? Colors.white.withValues(alpha: 0.1)
                  : Colors.transparent,
          border: Border.all(
            color: isSelected ? Colors.white.withValues(alpha: 0.8) : Colors.transparent,
            width: isMobile ? 1 : 2,
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: isMobile ? 72 : 90,
              child: Text(
                '${_formatTime(channel.toChannelTimezone(program.start))}-${_formatTime(channel.toChannelTimezone(program.stop))}',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: isSelected ? Colors.white : Colors.white70,
                  fontSize: isMobile ? 10 : 11,
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
                      fontSize: isMobile ? 12 : 13,
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
                            fontSize: isMobile ? 10 : 11,
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
                            fontSize: isMobile ? 10 : 11,
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
    final isMobile = DeviceUtils.isMobile;
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
        height: isMobile ? 36 : 44,
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
            width: isMobile ? 1 : 2,
          ),
        ),
        child: Text(
          group,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: selected ? Colors.white : Colors.white70,
            fontSize: isMobile ? 12 : 13,
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
    final nextProgram = _findNextProgram(channel);
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;
    final hasReplayPrograms = hasCatchup &&
        channel.programs.any((p) => channel.isProgramPast(p));
    final isMobile = DeviceUtils.isMobile;

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
        height: _channelItemHeight,
        margin: const EdgeInsets.symmetric(
          horizontal: AppSpacing.sm,
          vertical: AppSpacing.xs,
        ),
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
            width: isMobile ? 1 : 2,
          ),
        ),
        child: Stack(
          fit: StackFit.expand,
          children: [
            // 节目进度条作为背景的一部分，显示在项底部。
            // 只要频道有节目标题即显示背景条；currentProgram 缺失时进度为 0。
            if (programText != null && programText.isNotEmpty)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: LinearProgressIndicator(
                  value: program != null ? channel.programProgressRatio(program) : 0,
                  backgroundColor: isSelected
                      ? Colors.white.withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.08),
                  valueColor: AlwaysStoppedAnimation<Color>(
                    isSelected ? Colors.white.withValues(alpha: 0.85) : AppColors.primary,
                  ),
                  minHeight: 3,
                ),
              ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: isMobile ? AppSpacing.sm : AppSpacing.md),
              child: Row(
                children: [
                  if (isSelected)
                    Container(
                      width: isMobile ? 3 : 4,
                      height: isMobile ? 28 : 40,
                      margin: const EdgeInsets.only(right: AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  if (!isMobile)
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
                  if (!isMobile) const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: isMobile
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 第一列：频道名
                              SizedBox(
                                width: 76,
                                child: Text(
                                  channel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.9),
                                    fontSize: 14,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              // 第二列：节目信息（当前节目 + 下一个节目）
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  children: [
                                    if (programText != null && programText.isNotEmpty)
                                      Text(
                                        programText,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontFamily: 'NotoSansSC',
                                          color: isSelected
                                              ? Colors.white.withValues(alpha: 0.95)
                                              : AppColors.textSecondary,
                                          fontSize: 11,
                                        ),
                                      ),
                                    if (nextProgram != null)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          '下一个: ${nextProgram.title}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: isSelected
                                                ? Colors.white.withValues(alpha: 0.75)
                                                : AppColors.textMuted,
                                            fontSize: 10,
                                          ),
                                        ),
                                      )
                                    else if (channel.group != null && channel.group!.isNotEmpty)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 2),
                                        child: Text(
                                          channel.group!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: AppColors.textMuted,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm),
                              // 第三列：支持回放、时间、源数量
                              Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  if (hasReplayPrograms)
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.history,
                                          size: 10,
                                          color: isSelected
                                              ? Colors.white.withValues(alpha: 0.9)
                                              : AppColors.textSecondary,
                                        ),
                                        const SizedBox(width: 2),
                                        Text(
                                          '支持回放',
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
                                  if (program != null)
                                    Text(
                                      '${channel.programElapsedMinutes(program)}/${channel.programDurationMinutes(program)}分',
                                      style: TextStyle(
                                        fontFamily: 'NotoSansSC',
                                        color: isSelected
                                            ? Colors.white.withValues(alpha: 0.9)
                                            : AppColors.textSecondary,
                                        fontSize: 10,
                                      ),
                                    ),
                                  if (channel.hasMultipleUrls)
                                    Container(
                                      margin: const EdgeInsets.only(top: 2),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                        vertical: 1,
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
                                          fontSize: 10,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ],
                          )
                        : Column(
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
                                  padding: const EdgeInsets.only(top: 2),
                                  child: Row(
                                    children: [
                                      Expanded(
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
                                      ),
                                      if (program != null) ...[
                                        const SizedBox(width: 6),
                                        Text(
                                          '${channel.programElapsedMinutes(program)}/${channel.programDurationMinutes(program)}分',
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: isSelected
                                                ? Colors.white.withValues(alpha: 0.9)
                                                : AppColors.textSecondary,
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ],
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
                  if (!isMobile && channel.hasMultipleUrls)
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
