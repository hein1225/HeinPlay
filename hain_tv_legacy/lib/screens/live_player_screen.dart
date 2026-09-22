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
import '../platform/desktop_fullscreen_mixin.dart';
import '../platform/windows_window_utils.dart';
import '../services/live_service.dart';
import '../services/live_source_storage.dart';
import '../services/user_data_service.dart';
import '../theme.dart';
import '../utils/windows_logger.dart';
import '../widgets/common/tech_loading_indicator.dart';
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

  LivePlayerScreen({
    super.key,
    required this.source,
    this.allSources,
    this.sourceIndex = 0,
  });

  @override
  State<LivePlayerScreen> createState() => _LivePlayerScreenState();
}

class _LivePlayerScreenState extends State<LivePlayerScreen>
    with DesktopFullscreenMixin<LivePlayerScreen>, WidgetsBindingObserver {
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
  /// 节目单内用确认键（回车/select）进入回放后，标记需吞掉随后的 KeyUp，
  /// 避免回车抬起被 [_handleSelectKeyEvent] 误判为“回放暂停切换”而立即暂停
  /// 刚启动的回放（与鼠标点击进入回放的行为保持一致）。
  bool _epgConfirmPendingRelease = false;

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
  /// 回放按住快进/快退的起始时刻（用于按按住时长递增步长）。
  DateTime? _replayHoldStartAt;
  /// 回放快进/快退“真实重建流”节流时间戳：两次重建之间至少间隔
  /// [_replaySeekRebuildInterval]，避免长按/遥控器连发每 250ms 全量重建播放器
  /// 导致 fvp/libmdk 反复 open() 卡死。
  DateTime? _replayLastRebuildAt;
  /// 直播播放器控制器（用于回放流内实时定位画面）。
  final LivePlayerController _livePlayerController = LivePlayerController();

  /// 用于强制重挂 LivePlayer 的计数：后台关闭播放后，用户点击/确认键恢复时自增，
  /// 触发一个全新的 LivePlayer 实例（等同于首开），可靠地避开“在同一 State 内重建
  /// 后端”在 Android/Linux fvp 上引起的直播“一直加载/黑屏”脆弱性问题。
  int _livePlayerNonce = 0;

  /// 是否因进入后台（最小化/待机）而处于“已停止”状态。此时 LivePlayer 已被卸载，
  /// 回到前台后停留在“已停止”浮层，由用户点击屏幕/确认键重挂全新实例继续播放。
  bool _liveStopped = false;

  // ===== 无缝换台 / FCC 快速换台 =====

  /// 无缝换台开关（软件设置→直播设置），默认关闭。
  bool _seamlessSwitchEnabled = false;

  /// FCC 快速换台开关（软件设置→直播设置），默认关闭。
  bool _fccFastSwitchEnabled = false;

  /// 无缝换台期间暂时保留在最上层继续播放的“旧画面”。
  ///
  /// 换台时新频道的播放器立刻在下层静音预载，旧频道画面与声音留在上层，
  /// 直到新频道首帧就绪（或预载超时/失败）才移除，从而避免换台黑屏。
  _HoldoverPlayerSpec? _holdoverPlayer;

  /// 无缝换台预载超时定时器：超时后无论是否就绪都立即切换画面。
  Timer? _seamlessTimeoutTimer;

  // TV 版确认键长按检测
  DateTime? _selectKeyDownAt;
  Timer? _selectLongPressTimer;

  ScrollController _categoryScrollController = ScrollController();
  ScrollController _channelListScrollController = ScrollController();
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
  bool _isAlwaysOnTop = false;

  /// 是否正在执行 Windows 退出播放流程（暂停渲染后延迟 pop），防止重复触发。
  bool _exitingWindowsPlayback = false;

  // Windows 全屏鼠标自动隐藏（仅全屏时启用）
  /// 鼠标无操作自动隐藏定时器。
  Timer? _mouseInactivityTimer;
  /// 当前光标是否已隐藏。
  bool _isCursorHidden = false;
  /// 鼠标无操作多少秒后自动隐藏光标。
  static Duration _kMouseHideDelay = Duration(seconds: 5);

  static const double _kChannelListWidth = 480;
  static const double _kCategoryColumnWidth = 100;
  static const double _kChannelItemHeight = 102;
  static const double _kEpgBannerWidth = 56.0;
  static const double _kEpgListWidth = 340.0;

  // 手机版紧凑布局参数
  static const double _kMobileChannelListMargin = 8.0;
  static const double _kMobileCategoryColumnWidth = 88.0;
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
    final showEpgBanner = !DeviceUtils.isTv || DeviceUtils.isDesktop;
    return _kChannelListWidth +
        (showEpgBanner ? _kEpgBannerWidth : 0.0) +
        (showEpgBanner && _showEpgList ? _kEpgListWidth : 0.0);
  }

  @override
  void initState() {
    super.initState();
    _loadChannels();
    _channelListScrollController.addListener(_syncEpgBannerScroll);
    if (DeviceUtils.isTv || DeviceUtils.isDesktop) {
      HardwareKeyboard.instance.addHandler(_handleHardwareKeyEvent);
    }
    if (DeviceUtils.isDesktop) {
      initWindowsFullscreen();
      _initWindowsWindowState();
      _resetMouseTimer();
    }
    if (DeviceUtils.isMobile) {
      _enterFullscreenLandscape();
    }
    _initWakelock();
    _loadSwitchPreferences();
    WidgetsBinding.instance.addObserver(this);
  }

  /// 读取无缝换台 / FCC 快速换台开关。
  Future<void> _loadSwitchPreferences() async {
    final seamless = await UserDataService.getSeamlessChannelSwitch();
    final fcc = await UserDataService.getFccFastSwitch();
    if (!mounted) return;
    setState(() {
      _seamlessSwitchEnabled = seamless;
      _fccFastSwitchEnabled = fcc;
    });
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
      _isAlwaysOnTop = await windowManager.isAlwaysOnTop();
      if (mounted) setState(() {});
    } catch (e) {
      debugPrint('Windows 直播播放页初始化窗口状态失败: $e');
    }
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

    // 恢复上次退出直播模式时观看的频道：按 url / name 在频道列表中匹配，匹配到则定位到
    // 该频道，否则回退到列表第一个。下次进入同一直播源即自动续播上次频道。
    int initialIndex = 0;
    String restoredInfo;
    final last = await LiveSourceStorage.getLastChannel(widget.source.id);
    if (last != null) {
      final lastUrl = last['url'] ?? '';
      final lastName = last['name'] ?? '';
      for (int i = 0; i < channels.length; i++) {
        final c = channels[i];
        if ((lastUrl.isNotEmpty && c.currentUrl == lastUrl) ||
            (lastName.isNotEmpty && c.name == lastName)) {
          initialIndex = i;
          break;
        }
      }
      restoredInfo = 'found url=$lastUrl name=$lastName -> index=$initialIndex';
    } else {
      restoredInfo = 'none';
    }
    debugPrint(
      '[LiveLastChannel] restore sourceId=${widget.source.id} $restoredInfo',
    );

    setState(() {
      _loading = false;
      _channels = channels;
      _currentIndex = initialIndex;
      _currentChannel = channels[initialIndex];
    });
    // 即便本次未手动切台，也把恢复到的频道重新持久化，保证该源的“上次频道”始终有效。
    unawaited(_saveCurrentChannel());
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

    // 判断缓存内节目单是否还能覆盖“当前时间”。
    // 仅看时间戳（12h TTL）是不够的：频道缓存本身有 24h TTL，EPG 可能在写入时
    // 只包含到当天为止的节目，之后节目单会整体“过期”——此时节目单里没有任何
    // 正在播放的节目，打开节目单就无法定位到当前节目（表现为停在列表最顶端）。
    final hasCachedPrograms = channels.any((c) => c.programs.isNotEmpty);
    final coversNow = channels.any(
      (c) => c.programs.any((p) => c.isProgramCurrent(p)),
    );
    final epgFresh = await LiveService.isEpgCacheFresh(widget.source);
    final needEpgRefresh = !hasCachedPrograms || !epgFresh || !coversNow;

    // 无可用 EPG 地址时，先拉一次 M3U 头部拿到 url-tvg（内置源通常不单独配置
    // epgUrl，EPG 地址只能从 M3U 头解析），否则下面的 fetchEpg 会因没有地址
    // 直接返回 false，节目单将永远停留在缓存里的旧数据上。
    final hasEpgUrl = (widget.source.epgUrl ?? '').trim().isNotEmpty ||
        (LiveService.lastEpgUrl ?? '').trim().isNotEmpty;
    if (needCatchupFill || (needEpgRefresh && !hasEpgUrl)) {
      final fillUrl =
          LiveService.extractSourceUrlFromChannels(channels) ?? widget.source.url;
      if (fillUrl.isNotEmpty) {
        await LiveService.fillEpgAndCatchupFromM3uUrl(channels, fillUrl);
        await LiveService.cacheChannels(widget.source, channels);
      }
    }

    // 节目单刷新周期固定（12 小时），节目单每天内容都会变化需定期更新。
    // 缓存内节目单仍在刷新周期内、且仍能覆盖当前时间时复用，并按当前时间刷新
    // 当前节目信息，避免重复拉取 EPG，减少网络请求与积分消耗。
    if (hasCachedPrograms && epgFresh && coversNow) {
      LiveService.refreshCurrentPrograms(channels);
      if (mounted) setState(() {});
      return;
    }

    // 节目单需要刷新、但近期刚尝试过（多为 EPG 地址不可用导致失败）：
    // 本次不再重复拉取，直接用现有节目单（打开节目单时会退化为定位到
    // 最接近当前时间的一条），避免每次进入直播页都拉一次 M3U/EPG。
    if (hasCachedPrograms && LiveService.epgAttemptThrottled()) {
      LiveService.refreshCurrentPrograms(channels);
      if (mounted) setState(() {});
      return;
    }

    // 拉取最新 EPG；解析失败时不修改频道（保留已有节目单），不影响正常显示。
    LiveService.lastEpgAttemptAt = DateTime.now();
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

  /// 持久化“当前直播源当前观看的频道”，用于退出直播模式后下次进入自动续播。
  /// 每次切换频道、以及退出播放页（dispose）时都会调用。带 try/catch 与诊断日志，
  /// 便于在无原生日志时通过 flutter 日志确认存储是否成功、key 是否正确。
  Future<void> _saveCurrentChannel() async {
    final ch = _currentChannel;
    if (ch == null) return;
    try {
      await LiveSourceStorage.saveLastChannel(
        widget.source.id,
        ch.currentUrl,
        ch.name,
      );
      debugPrint(
        '[LiveLastChannel] save sourceId=${widget.source.id} '
        'name=${ch.name} url=${ch.currentUrl}',
      );
    } catch (e, st) {
      debugPrint('[LiveLastChannel] save ERROR: $e\n$st');
    }
  }

  /// 无缝换台：在切换播放地址前，把“当前正在播放的画面”冻结到最上层保留。
  ///
  /// 调用方需保证本次操作确实会改变播放地址（否则新播放器不会重建，
  /// 就绪回调也不会触发，只能等预载超时）。
  void _beginSeamlessHandoff() {
    if (!_seamlessSwitchEnabled) return;
    // 回放模式、后台已停止、尚未开播时不做无缝处理。
    if (_isReplayMode || _liveStopped || _loading || _error != null) return;
    if (_currentChannel == null) return;

    // 连续换台时保留最早那一份旧画面，避免叠加出多路播放器；
    // 中间被跳过的频道播放器会随 key 变化被正常释放。
    if (_holdoverPlayer == null) {
      final spec = _computeActivePlayerSpec();
      if (spec == null) return;
      _holdoverPlayer = spec;
    }

    _seamlessTimeoutTimer?.cancel();
    _seamlessTimeoutTimer = Timer(
      Duration(milliseconds: UserDataService.seamlessSwitchTimeoutMs),
      () => _commitSeamlessSwitch('timeout'),
    );
  }

  /// 结束无缝换台：移除保留的旧画面，让新频道接管画面与声音。
  ///
  /// [reason] 仅用于日志：ready 首帧就绪 / timeout 预载超时 / failed 预载失败
  /// / cancel 主动取消（进入回放、退出页面等）。
  void _commitSeamlessSwitch(String reason) {
    _seamlessTimeoutTimer?.cancel();
    _seamlessTimeoutTimer = null;
    if (_holdoverPlayer == null) return;
    debugPrint('[SeamlessSwitch] 切换画面（$reason）');
    if (!mounted) {
      _holdoverPlayer = null;
      return;
    }
    setState(() => _holdoverPlayer = null);
  }

  void _playChannel(int index, {bool showInfo = true}) {
    if (index < 0 || index >= _channels.length) return;
    // 记住该直播源当前观看的频道；每次切换即持久化，退出直播模式后下次进入可自动续播。
    unawaited(_saveCurrentChannel());
    // 无缝换台：仅在确实换到别的频道（播放地址会变）时才冻结旧画面。
    if (index != _currentIndex) {
      _beginSeamlessHandoff();
    }
    setState(() {
      _currentIndex = index;
      _currentChannel = _channels[index];
      if (_isReplayMode) {
        // 换台会退出回放；若回放刚进入就被换台打断，这行日志会指认出来源。
        WindowsLogger.log(
          'LivePlayerScreen',
          '换台重置回放 index=$index ← '
              '${StackTrace.current.toString().split('\n').take(5).join(' | ')}',
        );
      }
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

  /// 打开频道列表前调用：重建滚动控制器并定位到当前频道位置，
  /// 使列表首帧即停在当前频道，避免打开时选框/滚动从顶部跳到当前频道。
  void _prepareChannelListScroll() {
    _syncSelectionToCurrentChannel();
    const catItemHeight = 48.0;
    final catTarget = _selectedGroupIndex * catItemHeight;
    final chTarget = _selectedChannelIndexInGroup * _channelItemHeight;
    _categoryScrollController.dispose();
    _channelListScrollController.dispose();
    _categoryScrollController = ScrollController(initialScrollOffset: catTarget);
    _channelListScrollController = ScrollController(initialScrollOffset: chTarget);
    _channelListScrollController.addListener(_syncEpgBannerScroll);
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
        duration: Duration(milliseconds: 200),
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
        duration: Duration(milliseconds: 200),
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
    _beginSeamlessHandoff();
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
    _beginSeamlessHandoff();
    setState(() {
      channel.currentBackupIndex = prevIndex;
    });
    _showChannelInfoBriefly();
  }

  void _showChannelInfoBriefly() {
    _channelInfoTimer?.cancel();
    setState(() => _showChannelInfo = true);
    // 直播播放页不再提供「切换播放器」入口（播放器后端在设置页统一配置），
    // 信息卡（换台台标）浮层保持轻量，仅展示频道信息。
    _channelInfoTimer = Timer(Duration(seconds: 5), () {
      if (mounted) setState(() => _showChannelInfo = false);
    });
  }

  void _toggleChannelList() {
    final willShow = !_showChannelList;
    setState(() {
      _showChannelList = willShow;
      if (!willShow) {
        _showEpgList = false;
        _epgListChannel = null;
      } else {
        _prepareChannelListScroll();
        _focusOnCategories = false;
      }
    });
    if (willShow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_epgBannerScrollController.hasClients &&
            _channelListScrollController.hasClients) {
          _epgBannerScrollController.jumpTo(_channelListScrollController.offset);
        }
        _channelListFocusNode.requestFocus();
      });
    } else {
      _rootFocusNode.requestFocus();
    }
  }

  void _toggleControlsAndChannelList() {
    if (_showChannelList || _controlsVisible) {
      _hideChannelListAndControls();
    } else {
      _showChannelListAndControls();
    }
  }

  /// 控制栏自动隐藏倒计时（Windows）。
  ///
  /// 此前 `_controlsTimer` 只有 cancel、从未被赋值启动过，所以控制栏一旦显示就
  /// 永久驻留（用户反馈「进入回放后控制栏不会自动消失，必须鼠标点击」）。
  /// 频道列表打开时控制栏属于列表的附属控件，不参与自动隐藏。
  void _startControlsTimer() {
    if (!DeviceUtils.isDesktop) return;
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (_showChannelList || !_controlsVisible) return;
    _controlsTimer = Timer(const Duration(seconds: 5), () {
      _controlsTimer = null;
      if (mounted) _hideControls();
    });
  }

  void _hideControls() {
    if (!DeviceUtils.isDesktop) return;
    _controlsTimer?.cancel();
    _controlsTimer = null;
    if (mounted) setState(() => _controlsVisible = false);
  }

  /// 显示频道列表并将焦点定位到当前播放频道。
  ///
  /// Windows 版会同时显示控制栏，保持控制栏与列表层级融合。
  void _showChannelListAndControls() {
    setState(() {
      _showChannelList = true;
      if (DeviceUtils.isDesktop) _controlsVisible = true;
      _prepareChannelListScroll();
      _focusOnCategories = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_epgBannerScrollController.hasClients &&
          _channelListScrollController.hasClients) {
        _epgBannerScrollController.jumpTo(_channelListScrollController.offset);
      }
      _channelListFocusNode.requestFocus();
    });
    // 列表已打开时计时器内部会直接跳过；此处只是保证「控制栏被单独显示」的
    // 任何路径都不会漏掉自动隐藏（见 _startControlsTimer 说明）。
    _startControlsTimer();
  }

  void _hideChannelListAndControls() {
    if (!DeviceUtils.isDesktop) return;
    _controlsTimer?.cancel();
    setState(() {
      _showChannelList = false;
      _controlsVisible = false;
      _showEpgList = false;
      _epgListChannel = null;
    });
    _rootFocusNode.requestFocus();
  }

  Future<void> _toggleAlwaysOnTop() async {
    if (!DeviceUtils.isDesktop) return;
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
    if (!DeviceUtils.isDesktop) return;
    if (isWindowsFullScreen) {
      await toggleWindowsFullscreen();
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
    if (!DeviceUtils.isDesktop || _exitingWindowsPlayback) return;
    _exitingWindowsPlayback = true;
    WindowsLogger.log('LivePlayerScreen', 'Windows 退出播放：暂停渲染后 pop');
    unawaited(_livePlayerController.pause());
    Future<void>.delayed(Duration(milliseconds: 150), () {
      if (mounted) {
        // 直接 pop 绕过 canPop（Windows 下 canPop 恒 false），
        // 避免再次进入 onPopInvoked 导致死循环。
        Navigator.of(context).pop();
      }
    });
  }

  /// 直播页按键绑定：把回车/小键盘回车/ESC 改绑到本页 Intent，避免被 Flutter
  /// 默认的 ActivateIntent / DismissIntent 拿去「激活焦点上的任意按钮」
  /// （频道列表返回按钮 = 退出播放，正是「回车把回放秒退」的元凶）。
  static const Map<ShortcutActivator, Intent> _liveKeyShortcuts =
      <ShortcutActivator, Intent>{
    SingleActivator(LogicalKeyboardKey.enter): _LiveConfirmIntent(),
    SingleActivator(LogicalKeyboardKey.numpadEnter): _LiveConfirmIntent(),
    SingleActivator(LogicalKeyboardKey.escape): _LiveBackIntent(),
  };

  Map<Type, Action<Intent>> get _liveKeyActions => <Type, Action<Intent>>{
        _LiveConfirmIntent: CallbackAction<_LiveConfirmIntent>(
          onInvoke: (_) {
            _onShortcutConfirm();
            return null;
          },
        ),
        _LiveBackIntent: CallbackAction<_LiveBackIntent>(
          onInvoke: (_) {
            _onShortcutBack();
            return null;
          },
        ),
      };

  /// 这里**故意不执行任何动作**，只消费回车。
  ///
  /// [HardwareKeyboard] 的 handler（[_handleHardwareKeyEvent] → [_handleSelectKeyEvent]）
  /// 在焦点树之前收到按键，确认逻辑已在那里完成（含长按/短按区分）。
  /// 本 Shortcuts 仅用于把回车从 Flutter 默认的 `ActivateIntent` 上摘掉
  /// （否则回车会去激活焦点上的返回按钮，表现为“一按回车就退出播放”）。
  ///
  /// 若此处再确认一次，长按弹出频道列表后，按住不放产生的按键重复
  /// （SingleActivator 默认响应 repeat）会立刻再走一遍“播放选中频道并关闭列表”，
  /// 即用户看到的「频道列表刚出来就被关掉、还顺带切了台」。
  void _onShortcutConfirm() {
    // 仅消费，不执行动作。
  }

  /// 这里**故意不执行任何动作**，只消费 ESC（与 [_onShortcutConfirm] 同源）。
  ///
  /// ESC 的返回动作由 [app_windows] 的全局 handler 统一发起
  /// （`HardwareKeyboard` handler 在焦点树之前收到按键 → `maybePop` →
  /// 本页 `PopScope.onPopInvokedWithResult` 按优先级决策）。
  ///
  /// 若此处再调一次 `maybePop`，同一次 ESC 就会连退两层：日志实证——回放模式
  /// 按一次 ESC 出现**两条** `PopScope 被触发`，第一条 `回放=true` 执行
  /// `_exitReplayMode()`，紧接着第二条 `回放=false` 直接走 `_exitWindowsPlayback()`
  /// 退出播放页（用户看到的就是「回放模式按 ESC 直接退回到直播源列表」）。
  void _onShortcutBack() {
    // 仅消费，不执行动作。
  }

  bool _handleHardwareKeyEvent(KeyEvent event) {
    // 页面销毁后 handler 可能仍在收到按键（如 ESC 的 KeyUp 落在 pop 销毁窗口），
    // 访问 defunct context 会抛异常导致闪退，先做 mounted 防护。
    if (!mounted) return false;
    final route = ModalRoute.of(context);
    if (route == null || !route.isCurrent) return false;

    // 节目单（回放列表）打开时，所有按键优先交给节目单处理（含回车/小键盘回车/
    // select），确保键盘确认键能稳定激活回放，不依赖长按/KeyUp 计时，也不受后续
    // 直播模式确认键逻辑干扰。放在最顶端，覆盖下面所有按键分支。
    if (_showEpgList) {
      // 只在 KeyDown 执行一次：KeyRepeat（按住不放）与 KeyUp（松手）都必须吞掉，
      // 否则长按回车会在节目单里连续触发多次“进入回放”。
      if (event is KeyUpEvent || event is KeyRepeatEvent) {
        if (event is KeyRepeatEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.numpadEnter)) {
          // 长按期间保持静默（计时器/长按语义在节目单里不适用）。
        }
        return true;
      }
      if (event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter ||
          event.logicalKey == LogicalKeyboardKey.numpadEnter) {
        debugPrint('节目单确认键触发回放: key=${event.logicalKey}');
        _handleEpgListKey(LogicalKeyboardKey.enter);
        return true;
      }
      return _handleEpgListKey(event.logicalKey);
    }

    // 确认键需要单独处理 KeyDown/KeyUp 以支持长按检测。
    // 同时覆盖 Enter（主键盘/小键盘）与 select，避免 Windows 桌面端回车键无响应。
    //
    // Windows 与 TV 使用同一套「长按/短按」语义（用户设定，两端一致）：
    //   长按 ≥600ms → 显示频道列表（与鼠标左键点击画面等价）
    //   短按        → 显示当前频道的台标与播放信息
    // 因此这里不做桌面端特例分支；桌面端过去的“立即执行”分支会吃掉长按语义。
    if (event.logicalKey == LogicalKeyboardKey.select ||
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
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
        // 频道列表可见时方向键用于列表导航，不再做回放快退（即使处于回放模式）。
        if (_showChannelList) {
          if (DeviceUtils.isTv && !_focusOnCategories) {
            setState(() => _focusOnCategories = true);
            _categoryFocusNode.requestFocus();
            return true;
          }
          _toggleChannelList();
          return true;
        }
        if (_isReplayMode) {
          _seekReplay(Duration(seconds: -30));
          return true;
        }
        _switchToPrevBackupUrl();
        return true;
      case LogicalKeyboardKey.arrowRight:
        // 频道列表可见时方向键用于列表导航，不再做回放快进（即使处于回放模式）。
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
        if (_isReplayMode) {
          _seekReplay(Duration(seconds: 30));
          return true;
        }
        _switchToNextBackupUrl();
        return true;
      case LogicalKeyboardKey.escape:
      case LogicalKeyboardKey.goBack:
        // ESC 统一交给全局 handler（app_windows._handleEscKey）→ navigator.maybePop
        // → 本页 PopScope.onPopInvokedWithResult，按“全屏→回放→节目单→频道列表→退出播放”
        // 的优先级决策。本页不再重复消费 ESC，避免与全局 handler 并发触发双动作/卡死。
        return false;
      default:
        return false;
    }
  }

  /// 处理确认键（select/enter/小键盘回车）的短按/长按。
  ///
  /// Windows 与 TV 使用同一套语义（用户设定，两端一致）：
  /// - 短按：直播模式显示台标与播放信息；回放模式切换播放/暂停或恢复播放。
  /// - 长按（≥600ms）：显示频道列表（与鼠标左键点击画面等价）。
  bool _handleSelectKeyEvent(KeyEvent event) {
    // 后台关闭播放后，确认键/OK 键直接继续播放。
    if (_liveStopped) {
      // 重挂 LivePlayer（全新实例）重新开播，规避同 State 内重建后端的脆弱性。
      setState(() {
        _liveStopped = false;
        _livePlayerNonce++;
      });
      return true;
    }

    // 按住不放产生的按键重复必须在此消费：绝不能漏到焦点树，否则 Shortcuts 里的
    // SingleActivator 默认响应 repeat，会在长按弹出频道列表后立刻再执行一遍
    // 「播放选中频道并关闭列表」——表现为「列表刚出来就被关掉、还顺带切了台」。
    if (event is KeyRepeatEvent) {
      return true;
    }

    if (event is KeyDownEvent) {
      _selectKeyDownAt = DateTime.now();
      _selectLongPressTimer?.cancel();
      _selectLongPressTimer = Timer(Duration(milliseconds: 600), () {
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

      // 节目单确认回放后的 KeyUp：吞掉，避免刚进入回放就被误暂停
      // （与鼠标点击进入回放的行为保持一致）。
      if (_epgConfirmPendingRelease) {
        _epgConfirmPendingRelease = false;
        return true;
      }

      if (_showEpgList) {
        _handleEpgListKey(LogicalKeyboardKey.select);
        return true;
      }

      if (_showChannelList) {
        final indices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
        final globalIndex = indices.isNotEmpty ? indices[_selectedChannelIndexInGroup] : _currentIndex;
        _playChannel(globalIndex);
        if (DeviceUtils.isDesktop) {
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
        // 节目单内右键不进入回放/快进：快进快退只在“回放模式”才可用。
        // 右键保持节目单停留在浏览状态（左键/Esc 关闭列表，确认键播放选中节目）。
        return true;
      case LogicalKeyboardKey.select:
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (programs.isNotEmpty) {
          _epgConfirmPendingRelease = true;
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
  Future<void> _startReplay(EpgProgram program) async {
    final channel = _epgListChannel ?? _currentChannel;
    if (channel == null) return;
    WindowsLogger.log(
      'LivePlayerScreen',
      '回放检查: 频道=${channel.name}, catchup=${channel.catchup}, '
          'catchupSource=${channel.catchupSource}, catchupDays=${channel.catchupDays}, '
          'program.start=${program.start}, program.stop=${program.stop}, '
          'channelNow=${channel.channelNow}',
    );
    final canReplay = _canReplay(channel, program);
    WindowsLogger.log('LivePlayerScreen', '回放可播判定 canReplay=$canReplay');
    if (!canReplay) {
      WindowsLogger.log('LivePlayerScreen', '该节目不支持回放，已中止进入回放');
      _showReplayHint('该节目不支持回放');
      return;
    }
    // 进入回放会整体切换播放地址，不适合保留直播旧画面。
    _commitSeamlessSwitch('cancel');
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
      _replayLastRebuildAt = null;
      _replayHoldStartAt = null;
      _showEpgList = false;
      _showChannelList = false;
      _epgListChannel = null;
      // 必须显式收起控制栏：长按回车打开频道列表时会把 _controlsVisible 置 true，
      // 若不清掉，确认进入回放后控制栏会残留显示（且无人给它计时隐藏）——
      // 正是用户看到的「回车进入回放后控制栏一直挡在画面上」。
      _controlsVisible = false;
    });
    _controlsTimer?.cancel();
    _controlsTimer = null;
    WindowsLogger.log(
      'LivePlayerScreen',
      '[_startReplay] 完成 isReplayMode=$_isReplayMode '
          'replayProg=${_currentReplayProgram?.title} curCh=${_currentChannel?.name}',
    );
    _showChannelInfoBriefly();
  }

  /// 退出回放模式，返回当前频道直播。
  void _exitReplayMode() {
    // 记录调用来源：回放刚进入就被退回直播，通常是这里被某个非预期路径触发。
    // 取前几帧堆栈即可定位（AppLogger 落盘，不受 debugPrint 节流影响）。
    WindowsLogger.log(
      'LivePlayerScreen',
      '退出回放模式 ← ${StackTrace.current.toString().split('\n').take(6).join(' | ')}',
    );
    _replayHoldTimer?.cancel();
    _replayHoldTimer = null;
    _commitSeamlessSwitch('cancel');
    setState(() {
      _isReplayMode = false;
      _currentReplayProgram = null;
      _replayOffset = Duration.zero;
      _replayBaseOffset = Duration.zero;
      _isReplayPaused = false;
      _isReplaySeeking = false;
      _replayLastRebuildAt = null;
      _replayHoldStartAt = null;
    });
    _showChannelInfoBriefly();
  }

  /// 回放时快进/快退指定偏移。
  ///
  /// 逻辑位置 [_replayOffset] 立即更新（驱动进度条），但“真实重建流”按
  /// [_replaySeekRebuildInterval] 节流，避免遥控器连发/长按每 250ms 全量重建播放器。
  void _seekReplay(Duration delta) {
    if (!_isReplayMode || _currentReplayProgram == null || _currentChannel == null) return;
    _applyReplayOffset(delta);
    // 按键快进/快退即视为恢复播放（与原行为一致）。
    if (_isReplayPaused) {
      setState(() => _isReplayPaused = false);
    }
    _showReplayGestureIndicator(delta >= Duration.zero);
    _showChannelInfoBriefly();
  }

  /// 回放快进/快退重建节流间隔：长按/连发时两次真实重建流的最小间隔。
  ///
  /// 低于该间隔的连续 seek 只更新逻辑位置（进度条），不重建播放器，
  /// 从而消除 fvp/libmdk 反复 open() 引发的卡死。
  static const Duration _replaySeekRebuildInterval = Duration(milliseconds: 800);

  /// 根据按住时长返回本次快进/快退步长（秒）：按住越久步长越大。
  ///
  /// 既让长按时快进/快退更快，也减少需要重建流的总次数，缓解卡死。
  int _replaySeekStepSeconds(Duration held) {
    final s = held.inSeconds;
    if (s < 1) return 5;
    if (s < 2) return 10;
    if (s < 3) return 20;
    if (s < 4) return 30;
    if (s < 6) return 60;
    if (s < 10) return 120;
    return 300;
  }

  /// 计算并应用回放偏移：更新逻辑位置 [_replayOffset]（驱动进度条），
  /// 仅在距离上次重建达到 [_replaySeekRebuildInterval] 时才更新 [_replayBaseOffset]
  /// 触发真实重建流，从而节流连发/长按的重建风暴。
  void _applyReplayOffset(Duration delta) {
    if (!_isReplayMode || _currentReplayProgram == null || _currentChannel == null) return;
    final maxOffset = _currentChannel!.channelNow
        .difference(_currentChannel!.toChannelTimezone(_currentReplayProgram!.start));
    var newOffset = _replayOffset + delta;
    if (newOffset < Duration.zero) newOffset = Duration.zero;
    if (newOffset > maxOffset) newOffset = maxOffset;
    final now = DateTime.now();
    final needRebuild = _replayLastRebuildAt == null ||
        now.difference(_replayLastRebuildAt!) >= _replaySeekRebuildInterval;
    setState(() {
      _replayOffset = newOffset;
      // 仅节流到达时才重建流（流起点即新偏移），否则仅更新进度条显示。
      if (needRebuild) _replayBaseOffset = newOffset;
    });
    if (needRebuild) _replayLastRebuildAt = now;
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
      _replayGestureTimer = Timer(Duration(seconds: 1), () {
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
    _replayGestureTimer = Timer(Duration(seconds: 1), () {
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
    // 记录按住起点并清空重建节流，确保本次长按的步长从最小开始、重建不被上次残留节流。
    _replayHoldStartAt = DateTime.now();
    _replayLastRebuildAt = null;
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
      Duration(milliseconds: 250),
      (_) => _replayHoldTick(),
    );
    // 长按期间持续显示快进/快退手势标识。
    _showReplayGestureIndicator(forward, persistent: true);
  }

  void _replayHoldTick() {
    // 防御检查：松手/退出回放后即使定时器有残余触发也直接忽略，避免继续快进快退。
    if (!_isReplaySeeking || !_isReplayMode) return;
    if (_currentReplayProgram == null || _currentChannel == null) return;
    final now = DateTime.now();
    final held =
        _replayHoldStartAt != null ? now.difference(_replayHoldStartAt!) : Duration.zero;
    // 步长随按住时长递增：刚开始每 tick ±5s，按住越久步长越大（最高 ±300s），
    // 既让长按时快进更快，也减少需要重建流的总次数。
    final step = _replaySeekStepSeconds(held);
    _applyReplayOffset(Duration(seconds: _replayHoldForward ? step : -step));
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
      // 松手时把流起点对齐到最终逻辑位置：仅当与当前起点不同才重建（单次，安全），
      // 让画面精确停到快进/快退的目标位置。
      if (_replayBaseOffset != _replayOffset) {
        _replayBaseOffset = _replayOffset;
      }
    });
    _replayHoldStartAt = null;
    // 松手结束长按，隐藏手势标识，并重新启动信息卡自动隐藏。
    _hideReplayGestureIndicator();
    _channelInfoTimer?.cancel();
    _channelInfoTimer = Timer(Duration(seconds: 5), () {
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
    // 已结束或正在播放的节目均可回放：catchup=append/default 等类型支持从节目
    // 起点回拖，因此“正在播放”的节目也应允许回放（与安卓端行为一致）。
    return channel.isProgramPast(program) || channel.isProgramCurrent(program);
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
    var initialIndex = -1;
    for (var i = 0; i < programs.length; i++) {
      final start = channel.toChannelTimezone(programs[i].start);
      final stop = channel.toChannelTimezone(programs[i].stop);
      if (start.isBefore(now) && stop.isAfter(now)) {
        initialIndex = i;
        break;
      }
    }
    // 节目单是否覆盖了“当前时间”。为 false 说明 EPG 数据已过期/未刷新，
    // 此时无法定位到真正的当前节目，只能退化为最接近的一条。
    final coveredNow = initialIndex >= 0;
    if (!coveredNow) {
      // 节目单数据未覆盖当前时间（EPG 尚未刷新或已过期，如缓存里只有昨天及之前的
      // 节目）。此时不能退回 0 —— 那会让节目单每次都停在列表最顶端（最早的一条），
      // 表现为「没有定位到当前正确时间的节目单」。
      // 退化为定位到时间上最接近 now 的一条：最后一个已结束的节目（列表按开始时间
      // 升序，故取最后一个 stop <= now）；若全部节目都在未来，则取第一条。
      initialIndex = 0;
      for (var i = 0; i < programs.length; i++) {
        if (!channel.toChannelTimezone(programs[i].stop).isAfter(now)) {
          initialIndex = i;
        } else {
          break;
        }
      }
    }
    // 落盘定位结果：节目单定位是否正确可由此行直接判定（debugPrint 会被节流丢弃）。
    WindowsLogger.log(
      'LivePlayerScreen',
      '打开节目单：频道=${channel.name} 节目数=${programs.length} '
          '选中index=$initialIndex 覆盖当前时间=$coveredNow '
          '频道当前时间=${now.toString().substring(0, 16)}',
    );
    setState(() {
      _showEpgList = true;
      _epgListChannel = channel;
      _selectedEpgIndex = initialIndex;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scrollToEpgItem(animate: false);
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

  void _scrollToEpgItem({bool animate = true}) {
    if (!_epgListScrollController.hasClients) return;
    final itemHeight = DeviceUtils.isMobile ? 44.0 : 56.0;
    final targetOffset = _selectedEpgIndex * itemHeight;
    final viewport = _epgListScrollController.position.viewportDimension;
    final currentOffset = _epgListScrollController.offset;
    if (targetOffset < currentOffset ||
        targetOffset + itemHeight > currentOffset + viewport) {
      if (animate) {
        // 列表内方向键导航时平滑滚动，保持选中项可见。
        _epgListScrollController.animateTo(
          targetOffset.clamp(0.0, _epgListScrollController.position.maxScrollExtent),
          duration: Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      } else {
        // 打开节目单时直接定位（无跳转动画），与频道列表 _prepareChannelListScroll
        // 用 initialScrollOffset 直接定位的做法一致，焦点落在正在播放的节目。
        _epgListScrollController.jumpTo(
          targetOffset.clamp(0.0, _epgListScrollController.position.maxScrollExtent),
        );
      }
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
      case LogicalKeyboardKey.numpadEnter:
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
    WidgetsBinding.instance.removeObserver(this);
    WindowsLogger.log('LivePlayerScreen', 'dispose 开始');
    // 退出直播播放页时持久化当前观看的频道（覆盖“退出直播模式”的语义）；
    // 与每次切台的保存共同保证各直播源的最后观看频道不丢失。
    unawaited(_saveCurrentChannel());
    _channelInfoTimer?.cancel();
    _controlsTimer?.cancel();
    _replayGestureTimer?.cancel();
    _replayHoldTimer?.cancel();
    _seamlessTimeoutTimer?.cancel();
    _seamlessTimeoutTimer = null;
    if (DeviceUtils.isTv || DeviceUtils.isDesktop) {
      HardwareKeyboard.instance.removeHandler(_handleHardwareKeyEvent);
    }
    if (DeviceUtils.isDesktop) {
      disposeWindowsFullscreen();
      _mouseInactivityTimer?.cancel();
      _mouseInactivityTimer = null;
      // 页面销毁时确保光标恢复可见，避免鼠标隐藏状态泄漏到其它页面。
      WindowsWindowUtils.setCursorVisible(true);
    }
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // 全安卓平台（手机 / Android TV / tvLegacy）需要：最小化/待机时直接关闭直播播放。
    // 桌面端（Windows / Linux）无此生命周期，跳过。
    if (!DeviceUtils.isAndroid) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 直播流无法暂停。进入后台时卸载 LivePlayer 组件（而非在组件仍挂载时手动
        // dispose 后端），由 Flutter 走正常的平台视图拆除流程：先释放 fvp 视频纹理
        // 与 SurfaceView，再延迟释放后端，规避“原生 surface 回调打在已释放后端上
        // 导致的 nativeSetSurface SIGSEGV 闪退”。回到前台后停留在“已停止”浮层，
        // 由用户手动点击屏幕/确认键重挂全新实例继续播放。
        if (mounted && !_liveStopped) {
          setState(() => _liveStopped = true);
        }
        break;
      case AppLifecycleState.inactive:
        // 瞬时失焦（如来电、下拉通知栏）不关闭播放，避免误停。
        break;
      case AppLifecycleState.resumed:
      case AppLifecycleState.detached:
        // 不自动续播：停留于“已停止”浮层，等待用户手动继续。
        break;
    }
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
        !_controlsVisible &&
        (DeviceUtils.isDesktop ? false : !_showChannelList);
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, result) {
        // 记录每一次返回请求及其当时的状态：回放模式若被误退回直播，日志能直接指认。
        WindowsLogger.log(
          'LivePlayerScreen',
          'PopScope 被触发 didPop=$didPop 全屏=$isWindowsFullScreen '
              '回放=$_isReplayMode 节目单=$_showEpgList 频道列表=$_showChannelList '
              '控制栏=$_controlsVisible',
        );
        if (didPop) return;
        // 返回键优先级（与用户约定一致，由外到内逐层收起）：
        //   全屏 → 退出全屏
        //   节目单 → 关闭节目单
        //   频道列表 → 关闭频道列表（同时收起控制栏）
        //   控制栏 → 收起控制栏
        //   回放 → 退回直播
        //   都没有 → 退出播放页返回直播源列表
        // 注意顺序：回放必须排在控制栏之后——回放模式先按一次 ESC 只收控制栏，
        // 再按一次才退回直播，而不是一次 ESC 直接退出回放并连带退出播放页。
        if (isWindowsFullScreen) {
          handleWindowsEsc();
        } else if (_showEpgList) {
          _closeEpgList();
        } else if (_showChannelList) {
          if (DeviceUtils.isDesktop) {
            _hideChannelListAndControls();
          } else {
            _toggleChannelList();
          }
        } else if (_controlsVisible) {
          _hideControls();
        } else if (_isReplayMode) {
          _exitReplayMode();
        } else if (DeviceUtils.isDesktop) {
          _exitWindowsPlayback();
        }
      },
      // 关键修复（与点播页同源）：把回车/小键盘回车/ESC 从 Flutter 默认的
      // ActivateIntent / DismissIntent 中摘出来，改绑为本页 Intent。
      //
      // 直播页「频道列表左上角返回」按钮的 onPressed 就是 handleWindowsEsc（退出
      // 播放）。用户点过它之后焦点会停在该按钮上，此后按回车会被默认 ActivateIntent
      // 当成「点击退出播放」——日志实证：回车进入回放后立刻出现
      // `NavigatorState.maybePop` → PopScope → `_exitReplayMode()`，回放被秒退。
      // 覆盖后回车不再产生 ActivateIntent，任何按钮都不会被回车误激活。
      child: Shortcuts(
        shortcuts: _liveKeyShortcuts,
        child: Actions(
          actions: _liveKeyActions,
          child: Focus(
        focusNode: _rootFocusNode,
        autofocus: true,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: [
              _buildPlayerLayer(),
              _buildGestureLayer(),
              // 回放快进/快退手势标识（居中显示）。
              _buildReplayGestureIndicator(),
              if (_showChannelInfo) _buildChannelInfoOverlay(),
              if (_showChannelList) _buildChannelListOverlay(),
            // TV 版使用独立浮层面板；Windows 版使用频道列表内嵌面板。
            if (_showEpgList && DeviceUtils.isTv && !DeviceUtils.isDesktop) _buildEpgListOverlay(),
            if (DeviceUtils.isDesktop && _controlsVisible && !_showChannelList) _buildWindowsControls(),
            ],
          ),
        ),
      ),
          ),
        ),
    );
  }

  /// 播放器层：始终为固定结构的 Stack。
  ///
  /// 子项 0 恒为主播放器，子项 1 为无缝换台期间保留的旧频道画面（带 key）。
  /// 外层结构保持不变是关键——旧画面在 Stack 中从子项 0 迁移到子项 1 时，
  /// Flutter 的带 key 复用会保留其 Element/State，底层解码器与视频纹理不会重建。
  Widget _buildPlayerLayer() {
    final holdover = _holdoverPlayer;
    return Stack(
      fit: StackFit.expand,
      children: [
        _buildPlayer(),
        if (holdover != null)
          LivePlayer(
            key: ValueKey(holdover.playerKey),
            url: holdover.url,
            formatHint: holdover.formatHint,
            controller: _livePlayerController,
            headers: holdover.headers,
          ),
      ],
    );
  }

  Widget _buildPlayer() {
    // 进入后台后已卸载 LivePlayer，停留在“已停止”浮层，等待用户手动点击继续。
    if (_liveStopped) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.play_circle_outline,
                color: AppColors.primary,
                size: 48,
              ),
              SizedBox(height: AppSpacing.md),
              Text(
                DeviceUtils.isTv
                    ? '已停止播放，按确认键继续'
                    : '已停止播放，点击屏幕继续',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: Color(0xFFF0F0F5),
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (_loading) {
      return Center(
        child: TechLoadingIndicator(),
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
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  color: AppColors.error,
                  fontSize: 14,
                ),
              ),
              SizedBox(height: AppSpacing.md),
              ElevatedButton(
                onPressed: _loadChannels,
                child: Text('重新加载'),
              ),
            ],
          ),
        ),
      );
    }

    if (_currentChannel == null) {
      return Center(
        child: Text(
          '请选择频道',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: Colors.white,
          ),
        ),
      );
    }

    final spec = _computeActivePlayerSpec();
    if (spec == null) {
      return Center(
        child: Text(
          '无法生成回放地址',
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: Colors.white,
          ),
        ),
      );
    }

    // 无缝换台预载期间：新频道在下层静音解码，且不显示自身加载/错误遮罩，
    // 由上层保留的旧画面继续呈现，直到就绪/超时才接管画面与声音。
    final preloading = _holdoverPlayer != null;

    return LivePlayer(
      key: ValueKey(spec.playerKey),
      url: spec.url,
      formatHint: spec.formatHint,
      paused: _isReplayMode && _isReplayPaused,
      controller: _livePlayerController,
      headers: spec.headers,
      muted: preloading,
      showOverlay: !preloading,
      onReady: preloading ? () => _commitSeamlessSwitch('ready') : null,
      onFailed: preloading ? (_) => _commitSeamlessSwitch('failed') : null,
    );
  }

  /// 计算当前状态下主播放器应使用的播放参数。
  ///
  /// 返回 null 表示回放模式下无法生成回放地址。
  _HoldoverPlayerSpec? _computeActivePlayerSpec() {
    final channel = _currentChannel;
    if (_isReplayMode || _currentReplayProgram != null) {
      WindowsLogger.log(
        'LivePlayerScreen',
        '[_spec] isReplayMode=$_isReplayMode '
            'replayProg=${_currentReplayProgram?.title} ch=${channel?.name}',
      );
    }
    if (channel == null) return null;

    String playUrl;
    VideoFormat formatHint;
    if (_isReplayMode && _currentReplayProgram != null) {
      final catchupUrl = _buildCatchupUrl(channel, _currentReplayProgram!);
      if (catchupUrl == null || catchupUrl.isEmpty) return null;
      playUrl = catchupUrl;
      formatHint = _formatHintFor(playUrl);
    } else {
      // FCC 快速换台：开关开启且源提供了 FCC 地址时优先用 FCC 地址拉流。
      playUrl = channel.livePlaybackUrl(preferFcc: _fccFastSwitchEnabled);
      // 根据原始频道 URL 判断直播流格式，代理后的 URL 可能丢失格式后缀。
      // IPTV 列表中的频道地址通常为 HLS/M3U8，无明确后缀时默认按 HLS 处理。
      // 走 FCC 地址时按 FCC 地址本身判断，两者协议/后缀可能不同。
      formatHint = _formatHintFor(
        playUrl == channel.currentUrl ? channel.url : playUrl,
      );
    }

    // 若当前直播源配置了播放代理，通过特殊请求头传递给播放器底层。
    // 内部键以 x-heinplay- 前缀标识，原生层构造数据源时会剥离，不会发送到上游。
    final sourceProxy = widget.source.proxyUrl;
    final extraHeaders = (sourceProxy != null && sourceProxy.isNotEmpty)
        ? <String, String>{'x-heinplay-proxy-url': sourceProxy}
        : null;

    WindowsLogger.log(
      'LivePlayerScreen',
      '[_spec] 产出 isReplay=${_isReplayMode && _currentReplayProgram != null} '
          'url=$playUrl',
    );
    return _HoldoverPlayerSpec(
      playerKey: '${channel.name}_$playUrl#$_livePlayerNonce',
      url: playUrl,
      formatHint: formatHint,
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
        lower.contains('/rtsp/') ||
        lower.startsWith('rtp://') ||
        lower.startsWith('udp://') ||
        lower.startsWith('rtsp://')) {
      return VideoFormat.other;
    }
    if (lower.contains('.smil')) {
      // LunaTV 等运营商代理把 RTSP/组播流包装成 http://.../rtsp/...xxx.smil?fcc=...
      // 实际返回 MPEG-TS 流，不能按 HLS/Smooth 解析，需让 ExoPlayer 自动探测。
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
    if (!DeviceUtils.isDesktop) return;
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
    if (!DeviceUtils.isDesktop || !isWindowsFullScreen) return;
    if (!mounted || _isCursorHidden) return;
    WindowsWindowUtils.setCursorVisible(false);
    _isCursorHidden = true;
    debugPrint('LivePlayerScreen: 全屏鼠标无操作，已自动隐藏光标');
  }

  /// 显示鼠标光标。
  void _showCursor() {
    if (!DeviceUtils.isDesktop || !mounted) return;
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
          // 后台关闭播放后，任意点击屏幕即继续播放。
          if (_liveStopped) {
            // 重挂 LivePlayer（全新实例）重新开播。fvp 原生 surface 闪退问题已通过
            // “进入后台即卸载 LivePlayer 组件（由 Flutter 走正常平台视图拆除流程释放
            // 视频纹理），而非在组件仍挂载时手动 dispose 后端”解决。
            setState(() {
              _liveStopped = false;
              _livePlayerNonce++;
            });
            return;
          }
          if (DeviceUtils.isDesktop) {
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
        onDoubleTap: DeviceUtils.isDesktop
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

  /// 回放快进/快退与暂停/播放手势标识浮层（居中显示，样式与点播模式一致）。
  Widget _buildReplayGestureIndicator() {
    if (!_replayGestureVisible) return SizedBox.shrink();
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
        padding: EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: Color(0xD90A0A0F),
          borderRadius: BorderRadius.circular(AppRadius.lg),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              color: Color(0xFFF0F0F5),
              size: 32,
            ),
            SizedBox(height: AppSpacing.sm),
            Text(
              text,
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 14,
                color: Color(0xFFF0F0F5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelInfoOverlay() {
    final channel = _currentChannel;
    if (channel == null) return SizedBox.shrink();
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
                  valueColor: AlwaysStoppedAnimation<Color>(AppColors.primary),
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
                          padding: EdgeInsets.only(top: 2),
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
                          padding: EdgeInsets.only(top: 2),
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
                          padding: EdgeInsets.only(top: 2),
                          child: Text(
                            channel.group!,
                            style: TextStyle(
                              fontFamily: 'NotoSansSC',
                              color: Color(0xFF9CA3AF),
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
                        margin: EdgeInsets.only(left: AppSpacing.xs),
                        padding: EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.primary.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(AppRadius.sm),
                        ),
                        child: Text(
                          '源 ${channel.currentBackupIndex + 1}/${channel.allUrls.length}',
                          style: TextStyle(
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
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.sm,
                    vertical: AppSpacing.xs,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.primary.withValues(alpha: 0.85),
                    borderRadius: BorderRadius.circular(AppRadius.md),
                  ),
                  child: Row(
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
    if (_groups.isEmpty) return SizedBox.shrink();
    final channelIndices = _groupedChannelIndices[_groups[_selectedGroupIndex]] ?? [];
    final isMobile = DeviceUtils.isMobile;
    // Windows 版也显示右侧节目单条幅（支持鼠标点击），TV 版使用右键展开。
    // 手机版显示完整节目单时隐藏“节目单”条幅，由完整节目单替换其位置。
    final showEpgBanner = (!DeviceUtils.isTv || DeviceUtils.isDesktop) &&
        !(isMobile && _showEpgList);
    final showEpgPanel = _showEpgList && (!DeviceUtils.isTv || DeviceUtils.isDesktop);
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
            if (DeviceUtils.isDesktop) _buildWindowsChannelListHeader(),
            if (!DeviceUtils.isDesktop)
              Container(
                height: 56,
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                alignment: Alignment.centerLeft,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.source.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'NotoSansSC',
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${_channels.length} 个频道',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Color(0xFF9CA3AF),
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
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
                        padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
              alignment: Alignment.centerLeft,
              child: Text(
                DeviceUtils.isTv && !DeviceUtils.isDesktop
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
            if (DeviceUtils.isDesktop) _buildWindowsChannelListControls(),
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
      padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
      alignment: Alignment.centerLeft,
      child: Row(
        children: [
          IconButton(
            // Windows 频道列表左上角返回直接退出播放。
            onPressed: () {
              // 落盘诊断：若日志出现本行，说明「回车/确认」被焦点树误激活到本
              // 返回按钮上（表现为回放刚进入就被秒退）。修复后不应再出现。
              WindowsLogger.log('LivePlayerScreen', '频道列表返回按钮被激活：退出播放');
              handleWindowsEsc();
            },
            icon: Icon(Icons.arrow_back, color: Colors.white),
            tooltip: '退出播放',
          ),
          SizedBox(width: AppSpacing.sm),
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
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (channel.group != null && channel.group!.isNotEmpty)
                    Text(
                      channel.group!,
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Color(0xFF9CA3AF),
                        fontSize: 12,
                      ),
                    ),
                ],
              ),
            ),
          Text(
            '${_channels.length} 个频道',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              color: Color(0xFF9CA3AF),
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
      padding: EdgeInsets.all(AppSpacing.md),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            Color(0xD90A0A0F),
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
      padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
                        color: isOpen ? Colors.white : Color(0xFF9CA3AF),
                        fontSize: isMobile ? 10 : 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  )
                : SizedBox.shrink(),
          ),
        );
      },
    );
  }

  /// 非 TV 版嵌入在频道列表中的节目单面板。
  Widget _buildEpgListPanel() {
    final channel = _epgListChannel ?? _currentChannel;
    if (channel == null || channel.programs.isEmpty) return SizedBox.shrink();
    final programs = _epgProgramsFor(channel);
    final hasCatchup = channel.catchupSource != null && channel.catchupSource!.isNotEmpty;
    final isMobile = DeviceUtils.isMobile;

    return Container(
      color: isMobile ? Color(0xFF0A0A0F) : Colors.black.withValues(alpha: 0.88),
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
                  constraints: BoxConstraints(minWidth: 32, minHeight: 32),
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
                padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
    if (channel == null || channel.programs.isEmpty) return SizedBox.shrink();

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
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
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
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${programs.length} 个节目',
                      style: TextStyle(
                        fontFamily: 'NotoSansSC',
                        color: Color(0xFF9CA3AF),
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
                    padding: EdgeInsets.symmetric(vertical: AppSpacing.sm),
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
                padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
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

    // 鼠标悬停同步选中态：节目单项默认无键盘焦点机制，鼠标移到某项时把
    // _selectedEpgIndex 同步到该项并滚动到可见，使“回车确认键”回放的始终是
    // 鼠标所在的那一项（回车 = 鼠标左键 = 确认，全局语义一致）。
    return MouseRegion(
      onEnter: (_) {
        if (mounted) setState(() => _selectedEpgIndex = index);
        _scrollToEpgItem();
      },
      onHover: (_) {
        if (mounted) setState(() => _selectedEpgIndex = index);
      },
      child: GestureDetector(
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
                                : Color(0xFF9CA3AF),
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
        margin: EdgeInsets.symmetric(
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
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontFamily: 'NotoSansSC',
            color: selected ? Colors.white : Colors.white70,
            fontSize: isMobile ? 11 : 13,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            height: isMobile ? 1.1 : null,
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
        if (DeviceUtils.isDesktop) {
          _hideChannelListAndControls();
        } else {
          _toggleChannelList();
        }
      },
      child: Container(
        height: _channelItemHeight,
        margin: EdgeInsets.symmetric(
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
                      margin: EdgeInsets.only(right: AppSpacing.sm),
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
                              errorBuilder: (_, __, ___) => Icon(
                                Icons.tv,
                                size: 30,
                                color: Colors.white70,
                              ),
                            )
                          : Icon(
                              Icons.tv,
                              size: 30,
                              color: Colors.white70,
                            ),
                    ),
                  if (!isMobile) SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: isMobile
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              // 第一列：频道名（手机端加宽 + 字体略小，避免 CCTV 等长频道名被截断）
                              SizedBox(
                                width: isMobile ? 144 : 76,
                                child: Text(
                                  channel.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.9),
                                    fontSize: isMobile ? 13 : 14,
                                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                                  ),
                                ),
                              ),
                              SizedBox(width: AppSpacing.sm),
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
                                              : Color(0xFF9CA3AF),
                                          fontSize: 11,
                                        ),
                                      ),
                                    if (nextProgram != null)
                                      Padding(
                                        padding: EdgeInsets.only(top: 2),
                                        child: Text(
                                          '下一个: ${nextProgram.title}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: isSelected
                                                ? Colors.white.withValues(alpha: 0.75)
                                                : Color(0xFF6B7280),
                                            fontSize: 10,
                                          ),
                                        ),
                                      )
                                    else if (channel.group != null && channel.group!.isNotEmpty)
                                      Padding(
                                        padding: EdgeInsets.only(top: 2),
                                        child: Text(
                                          channel.group!,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: Color(0xFF6B7280),
                                            fontSize: 10,
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              SizedBox(width: AppSpacing.sm),
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
                                              : Color(0xFF9CA3AF),
                                        ),
                                        SizedBox(width: 2),
                                        Text(
                                          '支持回放',
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: isSelected
                                                ? Colors.white.withValues(alpha: 0.9)
                                                : Color(0xFF9CA3AF),
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
                                            : Color(0xFF9CA3AF),
                                        fontSize: 10,
                                      ),
                                    ),
                                  if (channel.hasMultipleUrls)
                                    Container(
                                      margin: EdgeInsets.only(top: 2),
                                      padding: EdgeInsets.symmetric(
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
                                  padding: EdgeInsets.only(top: 2),
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
                                                : Color(0xFF9CA3AF),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                      if (program != null) ...[
                                        SizedBox(width: 6),
                                        Text(
                                          '${channel.programElapsedMinutes(program)}/${channel.programDurationMinutes(program)}分',
                                          style: TextStyle(
                                            fontFamily: 'NotoSansSC',
                                            color: isSelected
                                                ? Colors.white.withValues(alpha: 0.9)
                                                : Color(0xFF9CA3AF),
                                            fontSize: 10,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                )
                              else if (channel.group != null && channel.group!.isNotEmpty)
                                Padding(
                                  padding: EdgeInsets.only(top: 3),
                                  child: Text(
                                    channel.group!,
                                    style: TextStyle(
                                      fontFamily: 'NotoSansSC',
                                      color: Color(0xFF9CA3AF),
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              if (hasReplayPrograms)
                                Padding(
                                  padding: EdgeInsets.only(top: 4),
                                  child: Row(
                                    children: [
                                      Icon(
                                        Icons.history,
                                        size: 12,
                                        color: isSelected
                                            ? Colors.white.withValues(alpha: 0.9)
                                            : Color(0xFF9CA3AF),
                                      ),
                                      SizedBox(width: 4),
                                      Text(
                                        '支持回放',
                                        style: TextStyle(
                                          fontFamily: 'NotoSansSC',
                                          color: isSelected
                                              ? Colors.white.withValues(alpha: 0.9)
                                              : Color(0xFF9CA3AF),
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
                      margin: EdgeInsets.only(left: AppSpacing.sm),
                      padding: EdgeInsets.symmetric(
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
                  padding: EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Color(0xD90A0A0F),
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    children: [
                      IconButton(
                        onPressed: _onWindowsBack,
                        icon: Icon(
                          Icons.arrow_back,
                          color: Colors.white,
                        ),
                        tooltip: '返回',
                      ),
                      SizedBox(width: AppSpacing.sm),
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
                                style: TextStyle(
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
                                  style: TextStyle(
                                    fontFamily: 'NotoSansSC',
                                    color: Color(0xFF9CA3AF),
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
              Spacer(),
              // 底部控制栏
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: Container(
                  width: double.infinity,
                  padding: EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Color(0xD90A0A0F),
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
          padding: EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: Color(0xFF1C1C2E).withValues(alpha: 0.8),
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 20),
              SizedBox(width: AppSpacing.xs),
              Text(
                label,
                style: TextStyle(
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

/// 一路直播播放器的构建参数。
///
/// 既用于描述当前主播放器，也用于在无缝换台期间“冻结”旧频道播放器的参数，
/// 让它在新频道预载完成前继续以完全相同的配置留在画面最上层播放。
class _HoldoverPlayerSpec {
  /// 播放器 widget 的稳定 key。无缝换台依赖它在 Stack 中做带 key 的位置迁移，
  /// 从而保留播放器 State（底层解码器与视频纹理不重建）。
  final String playerKey;
  final String url;
  final VideoFormat formatHint;
  final Map<String, String>? headers;

  const _HoldoverPlayerSpec({
    required this.playerKey,
    required this.url,
    required this.formatHint,
    this.headers,
  });
}

/// 直播页「确认键」Intent（回车 / 小键盘回车）。
///
/// 唯一目的：把回车从 Flutter 默认的 `ActivateIntent` 上摘下来，使其不会去
/// 激活「当前拥有焦点的按钮」（频道列表的返回按钮 = 退出播放）。
class _LiveConfirmIntent extends Intent {
  const _LiveConfirmIntent();
}

/// 直播页「返回键」Intent（ESC）。同理摘掉默认 `DismissIntent`。
class _LiveBackIntent extends Intent {
  const _LiveBackIntent();
}
