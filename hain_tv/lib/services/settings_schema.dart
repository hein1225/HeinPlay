import 'package:hain_tv/player/buffer_profile_config.dart';
import 'package:hain_tv/player/player_backend_factory.dart';
import 'package:hain_tv/services/ad_filter_service.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/app_info_service.dart';
import 'package:hain_tv/services/theme_mode_service.dart';
import 'package:hain_tv/services/user_data_service.dart';

/// 手机控制页的“设置结构”来源。
///
/// 关键点：手机设置页不再手写一套独立的设置项，而是**完全由本结构驱动渲染**，
/// 从而保证与 TV 端 [VodSettingsPage] / [LiveSettingsPage] / [DataSourceSettingsPage] /
/// [ThemeSettingsPage] / [OtherSettingsPage] 等页面显示的内容、选项、当前值一致。
///
/// 播放器后端等“随平台变化”的选项直接取自 [PlayerBackendFactory.availableBackends]，
/// TV（Android）只有 exo / fvp，因此手机页不会出现 TV 上没有的 VLC 等选项。
class SettingsSchema {
  static Future<Map<String, dynamic>> build() async {
    final vodBackends = _backendOptions(
      PlayerBackendFactory.availableBackends,
      PlayerBackendFactory.platformDefault,
    );
    final liveBackends = _backendOptions(
      PlayerBackendFactory.availableBackends,
      PlayerBackendFactory.platformLiveDefault,
    );

    // 点播
    final vodBackend = await UserDataService.getPlayerBackend();
    final autoSkip = await UserDataService.getAutoSkipOpeningEnding();
    final autoNext = await UserDataService.getAutoPlayNextEpisode();
    final autoSwitchSource = await UserDataService.getAutoSwitchSource();
    final autoSwitchTimeout = await UserDataService.getAutoSwitchSourceTimeout();
    final autoSpeedTest = await UserDataService.getAutoSpeedTest();
    final m3u8Proxy = await UserDataService.getM3u8ProxyUrl();
    final adFilter = await AdFilterService.isEnabled();
    final hardware = await UserDataService.getHardwareDecoding();
    final bufferProfile = await UserDataService.getBufferProfile();

    // 直播
    final liveBackend = await UserDataService.getLivePlayerBackend();
    final luna = await UserDataService.getLunaTvLiveEnabled();
    final epg = await UserDataService.getEpgLoadEnabled();
    final localProxy = await UserDataService.getLocalProxyEnabled();
    final seamless = await UserDataService.getSeamlessChannelSwitch();
    final fcc = await UserDataService.getFccFastSwitch();
    final cacheHours = await UserDataService.getLiveSourceCacheHours();

    // 数据源
    final douban = await UserDataService.getDoubanDataSource();
    final bangumiApi = await UserDataService.getBangumiApiProxyType();
    final bangumiApiUrl = await UserDataService.getBangumiApiProxyUrl();
    final bangumiImg = await UserDataService.getBangumiImageProxyType();
    final bangumiImgUrl = await UserDataService.getBangumiImageProxyUrl();

    // 主题
    final themePref = ThemeModeService.instance.pref;
    final followSystem = ThemeModeService.instance.followSystem;

    // 其他
    final logEnabled = await UserDataService.getLogEnabled();
    final windowsFullscreenAlwaysOnTop =
        await UserDataService.getWindowsFullscreenAlwaysOnTop();
    final version = AppInfoService.version;

    // 账号
    final main = await UserDataService.getMainAccount();
    final sub = await UserDataService.getSubAccount();
    final active = await UserDataService.getActiveAccount();

    // 服务器
    final internet = await UserDataService.getServerUrl() ?? '';
    final lan = await UserDataService.getBackupServerUrl();
    final autoSelectLowLatency =
        await UserDataService.getAutoSelectLowLatencyServer();
    final dnsPref = await UserDataService.getInternetServerDnsPreference();

    final categories = <Map<String, dynamic>>[
      {
        'id': 'search',
        'title': '搜索',
        'kind': 'command',
      },
      {
        'id': 'account',
        'title': '账号管理',
        'kind': 'account',
        'account': {
          'mainUsername': main?.username ?? '',
          'subUsername': sub?.username ?? '',
          'active': active,
        },
      },
      {
        'id': 'server',
        'title': '服务器管理',
        'kind': 'server',
        'server': {'internet': internet, 'lan': lan},
        'items': [
          _text(
            'server',
            'internetUrl',
            '互联网服务器地址',
            '电视通过此地址访问云端影视服务，例如 https://your-lunatv-server.com',
            internet,
            'https://your-lunatv-server.com',
          ),
          _text(
            'server',
            'backupUrl',
            '局域网服务器地址（选填）',
            '局域网部署时填写，优先于互联网地址，例如 http://192.168.1.100:3000',
            lan,
            'http://192.168.1.100:3000',
          ),
          _switch(
            'server',
            'autoSelectLowLatency',
            '启动时自动测速并切换',
            '每次启动时自动选择互联网/局域网服务器中延迟最低的地址',
            autoSelectLowLatency,
          ),
          _switch(
            'server',
            'preferIpv6',
            '互联网服务器地址优先解析 IPv6',
            '优先解析 IPv6 地址（关闭则优先解析 IPv4）',
            dnsPref == InternetServerDnsPreference.ipv6,
          ),
          _action(
            'server_speedtest',
            '立即测速并切换',
            '手动触发一次服务器延迟测速并切换到最优地址',
          ),
        ],
      },
      {
        'id': 'vod',
        'title': '点播设置',
        'kind': 'settings',
        'items': [
          _section('点播设置'),
          _radio('vod', 'playerBackend', '点播源默认播放器', vodBackends,
              vodBackend.name),
          _switch('vod', 'autoSkip', '自动跳过片头片尾',
              '到达片头/片尾区域时自动跳转', autoSkip),
          _switch('vod', 'autoPlayNext', '自动播放下一集',
              '片尾结束后自动播放下一集', autoNext),
          _switch('vod', 'autoSpeedTest', '进入详情页自动测速',
              '多源时自动测试各源速度并排序，关闭后仍支持手动测速',
              autoSpeedTest),
          _switch('vod', 'autoSwitchSource', '播放失败自动切换播放源',
              '当前源无法播放时按测速顺序自动尝试其他源', autoSwitchSource),
          _radio(
            'vod',
            'autoSwitchSourceTimeout',
            '切换源超时时间',
            _timeoutOptions(),
            autoSwitchTimeout,
            showIf: {'group': 'vod', 'key': 'autoSwitchSource', 'value': true},
          ),
          _text(
            'vod',
            'm3u8ProxyUrl',
            'M3U8 代理地址',
            '配置后 M3U8/HLS 播放地址将通过代理请求，用于解决跨域或 Referer 限制',
            m3u8Proxy,
            '例如 http://127.0.0.1:8080/proxy?url=',
          ),
          _switch('vod', 'adFilter', 'M3U8 去广告（本地过滤）',
              '播放 M3U8 时使用本地规则过滤片头贴片广告', adFilter),
          _switch('vod', 'hardwareDecoding', '硬件解码',
              '关闭后可能解决部分花屏问题', hardware),
          _radio('vod', 'bufferProfile', '缓冲模式', _bufferOptions(),
              bufferProfile.name),
        ],
      },
      {
        'id': 'live',
        'title': '直播设置',
        'kind': 'settings',
        'items': [
          _section('换台优化'),
          _switch(
            'live',
            'seamlessSwitch',
            '无缝换台',
            '开启后换台时当前画面继续播放，目标频道在后台预载，就绪后再切换。默认关闭',
            seamless,
          ),
          _switch(
            'live',
            'fcc',
            'FCC 快速换台',
            '开启后优先使用直播源提供的 FCC 地址拉流，缩短换台等待；源未提供则使用普通地址。默认关闭',
            fcc,
          ),
          _section('直播设置'),
          _switch(
            'live',
            'localProxy',
            '本地 M3U8 代理',
            '开启后直播 M3U8 经本地代理转发，用于排查/兼容个别直播源（如神盾TV）；关闭则直播直连原始地址。默认关闭',
            localProxy,
          ),
          _radio('live', 'livePlayerBackend', '直播默认播放器', liveBackends,
              liveBackend.name),
          _switch('live', 'lunaTvEnabled', '启用 LunaTV 服务器直播源',
              '关闭后将不再获取 LunaTV 服务端提供的直播频道', luna),
          _switch('live', 'epgEnabled', '加载 EPG 节目单',
              '关闭后不拉取节目单与时移信息，直播连接更快；开启时频道就绪后立即开播',
              epg),
          _radio('live', 'cacheHours', '直播源缓存时间', _cacheHoursOptions(),
              cacheHours),
        ],
      },
      {
        'id': 'data',
        'title': '数据源设置',
        'kind': 'settings',
        'items': [
          _section('豆瓣数据源'),
          _radio('data', 'doubanSource', '豆瓣数据源', _doubanOptions(),
              douban.name),
          _section('Bangumi 数据源'),
          _radio('data', 'bangumiProxyType', 'Bangumi 数据代理',
              _bangumiApiOptions(), bangumiApi.name),
          _text(
            'data',
            'bangumiProxyUrl',
            'Bangumi 反代地址',
            '与官方路径兼容的代理地址，不含末尾斜杠',
            bangumiApiUrl,
            '例如 https://api.example.com',
            showIf: {
              'group': 'data',
              'key': 'bangumiProxyType',
              'value': 'custom'
            },
          ),
          _radio('data', 'bangumiImageProxyType', 'Bangumi 图片代理',
              _bangumiImgOptions(), bangumiImg.name),
          _text(
            'data',
            'bangumiImageProxyUrl',
            'Bangumi 图片代理地址',
            '与官方路径兼容的代理地址，不含末尾斜杠',
            bangumiImgUrl,
            '例如 https://img.example.com/proxy?url=',
            showIf: {
              'group': 'data',
              'key': 'bangumiImageProxyType',
              'value': 'custom'
            },
          ),
        ],
      },
      {
        'id': 'theme',
        'title': '软件主题设置',
        'kind': 'settings',
        'items': [
          _section('软件主题'),
          _switch('theme', 'followSystem', '跟随系统',
              '开启后根据系统亮度自动在明亮/黑暗主题间切换', followSystem),
          _radio(
            'theme',
            'mode',
            '主题模式',
            _themeOptions(),
            followSystem ? 'system' : themePref.name,
            showIf: {'group': 'theme', 'key': 'followSystem', 'value': false},
          ),
        ],
      },
      {
        'id': 'other',
        'title': '其他',
        'kind': 'settings',
        'items': [
          _section('其他'),
          _action('clear_cache', '清除缓存源',
              '清除海报、图片与豆瓣数据缓存，保留播放记录、搜索记录、跳过设置等数据'),
          _section('日志与调试'),
          _switch('other', 'logEnabled', '获取日志',
              '作为调试核查问题使用，正常情况下请关闭选项，避免影响性能',
              logEnabled),
          if (DeviceUtils.isWindows) ...[
            _section('Windows'),
            _switch('other', 'windowsFullscreenAlwaysOnTop', '全屏时窗口置顶',
                '全屏播放时自动将窗口置顶', windowsFullscreenAlwaysOnTop),
          ],
          _section('关于'),
          _info('版本', version.isEmpty ? '-' : version),
          _info('作者', '海因茨'),
        ],
      },
    ];

    return {'categories': categories};
  }

  static List<Map<String, dynamic>> _backendOptions(
    List<PlayerBackendType> backends,
    PlayerBackendType platformDefault,
  ) {
    return backends.map((t) {
      final isDefault = t == platformDefault;
      String title;
      String subtitle;
      switch (t) {
        case PlayerBackendType.exo:
          title = isDefault ? 'ExoPlayer（默认）' : 'ExoPlayer';
          subtitle = 'Android 原生播放器，硬解能力强';
        case PlayerBackendType.fvp:
          title = isDefault ? 'FVP（默认）' : 'FVP';
          subtitle = '基于 libmdk，兼容性较好';
        case PlayerBackendType.vlc:
          title = isDefault ? 'VLC（默认）' : 'VLC';
          subtitle = '基于 libvlc，格式兼容性最强';
      }
      return {
        'value': t.name,
        'title': title,
        'subtitle': subtitle,
        'isDefault': isDefault,
      };
    }).toList();
  }

  static List<Map<String, dynamic>> _timeoutOptions() => [
        {'value': 10, 'title': '10 秒', 'subtitle': '默认较短等待时间'},
        {'value': 15, 'title': '15 秒', 'subtitle': '适中等待时间'},
        {'value': 30, 'title': '30 秒', 'subtitle': '较长等待时间，适合弱网'},
      ];

  static List<Map<String, dynamic>> _cacheHoursOptions() => [
        {'value': 24, 'title': '1 天', 'subtitle': '默认缓存时间'},
        {'value': 48, 'title': '2 天', 'subtitle': '48 小时缓存'},
        {'value': 72, 'title': '3 天', 'subtitle': '72 小时缓存'},
        {'value': 168, 'title': '7 天', 'subtitle': '最长缓存时间'},
      ];

  static List<Map<String, dynamic>> _bufferOptions() =>
      BufferProfile.values.map((p) {
        return {
          'value': p.name,
          'title': bufferProfileLabel(p),
          'subtitle': bufferProfileSubtitle(p),
        };
      }).toList();

  static List<Map<String, dynamic>> _doubanOptions() => [
        {'value': 'direct', 'title': '直连（默认）', 'subtitle': '直接访问豆瓣官方接口'},
        {'value': 'cdnTencent', 'title': '腾讯云 CDN', 'subtitle': '通过腾讯云 CDN 加速访问'},
        {'value': 'cdnAliyun', 'title': '阿里云 CDN', 'subtitle': '通过阿里云 CDN 加速访问'},
        {'value': 'corsProxy', 'title': 'CORS 代理', 'subtitle': '通过 CORS 代理服务器访问'},
      ];

  static List<Map<String, dynamic>> _bangumiApiOptions() => [
        {'value': 'direct', 'title': '直连（直接访问 api.bgm.tv）', 'subtitle': ''},
        {'value': 'cmliussss', 'title': 'Bangumi 反代 By CMLiussss（解决服务器被墙）', 'subtitle': ''},
        {'value': 'custom', 'title': '自定义反代地址', 'subtitle': ''},
      ];

  static List<Map<String, dynamic>> _bangumiImgOptions() => [
        {'value': 'direct', 'title': '直连（直接请求 lain.bgm.tv）', 'subtitle': ''},
        {'value': 'cmliussss', 'title': 'Bangumi 图片 CDN By CMLiussss', 'subtitle': ''},
        {'value': 'custom', 'title': '自定义代理', 'subtitle': ''},
      ];

  static List<Map<String, dynamic>> _themeOptions() => [
        {'value': 'light', 'title': '明亮主题', 'subtitle': '背景为白色，文字为黑色'},
        {'value': 'dark', 'title': '黑暗主题（默认）', 'subtitle': '背景为深色，适合暗光环境'},
      ];

  static Map<String, dynamic> _section(String title) => {
        'type': 'section',
        'title': title,
      };

  static Map<String, dynamic> _switch(
    String group,
    String key,
    String title,
    String subtitle,
    bool value,
  ) =>
      {
        'type': 'switch',
        'group': group,
        'key': key,
        'title': title,
        'subtitle': subtitle,
        'value': value,
      };

  static Map<String, dynamic> _radio(
    String group,
    String key,
    String title,
    List<Map<String, dynamic>> options,
    dynamic value, {
    Map<String, dynamic>? showIf,
  }) =>
      {
        'type': 'radio',
        'group': group,
        'key': key,
        'title': title,
        'options': options,
        'value': value,
        if (showIf != null) 'showIf': showIf,
      };

  static Map<String, dynamic> _text(
    String group,
    String key,
    String title,
    String subtitle,
    dynamic value,
    String ph, {
    Map<String, dynamic>? showIf,
  }) =>
      {
        'type': 'text',
        'group': group,
        'key': key,
        'title': title,
        'subtitle': subtitle,
        'value': value ?? '',
        'ph': ph,
        if (showIf != null) 'showIf': showIf,
      };

  static Map<String, dynamic> _info(String title, String value) => {
        'type': 'info',
        'title': title,
        'value': value,
      };

  static Map<String, dynamic> _action(String id, String title, String subtitle) => {
        'type': 'action',
        'id': id,
        'title': title,
        'subtitle': subtitle,
      };
}
