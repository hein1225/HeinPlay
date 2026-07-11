import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import '../focus/focusable.dart';
import '../services/ad_filter_service.dart';
import '../services/bangumi_service.dart';
import '../services/cache_service.dart';
import '../services/hain_tv_cache_manager.dart';
import '../services/user_data_service.dart';
import '../theme.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  PlayerBackendType _playerBackend = PlayerBackendType.exo;
  DoubanDataSource _doubanSource = DoubanDataSource.direct;
  bool _autoSkipOpeningEnding = true;
  bool _autoPlayNextEpisode = true;
  bool _autoSwitchSource = true;
  int _autoSwitchSourceTimeout = 15;
  String _m3u8ProxyUrl = '';
  bool _adFilterEnabled = false;
  bool _hardwareDecoding = true;
  BangumiApiProxyType _bangumiApiProxyType = BangumiApiProxyType.cmliussss;
  String _bangumiApiProxyUrl = '';
  BangumiImageProxyType _bangumiImageProxyType = BangumiImageProxyType.cmliussss;
  String _bangumiImageProxyUrl = '';

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final backend = await UserDataService.getPlayerBackend();
    final douban = await UserDataService.getDoubanDataSource();
    final skip = await UserDataService.getAutoSkipOpeningEnding();
    final next = await UserDataService.getAutoPlayNextEpisode();
    final autoSwitchSource = await UserDataService.getAutoSwitchSource();
    final autoSwitchSourceTimeout = await UserDataService.getAutoSwitchSourceTimeout();
    final m3u8ProxyUrl = await UserDataService.getM3u8ProxyUrl();
    final adFilterEnabled = await AdFilterService.isEnabled();
    final hardwareDecoding = await UserDataService.getHardwareDecoding();
    final bangumiApiProxyType = await UserDataService.getBangumiApiProxyType();
    final bangumiApiProxyUrl = await UserDataService.getBangumiApiProxyUrl();
    final bangumiImageProxyType = await UserDataService.getBangumiImageProxyType();
    final bangumiImageProxyUrl = await UserDataService.getBangumiImageProxyUrl();
    await BangumiService.loadProxySettings();
    setState(() {
      _playerBackend = backend;
      _doubanSource = douban;
      _autoSkipOpeningEnding = skip;
      _autoPlayNextEpisode = next;
      _autoSwitchSource = autoSwitchSource;
      _autoSwitchSourceTimeout = autoSwitchSourceTimeout;
      _m3u8ProxyUrl = m3u8ProxyUrl;
      _adFilterEnabled = adFilterEnabled;
      _hardwareDecoding = hardwareDecoding;
      _bangumiApiProxyType = bangumiApiProxyType;
      _bangumiApiProxyUrl = bangumiApiProxyUrl;
      _bangumiImageProxyType = bangumiImageProxyType;
      _bangumiImageProxyUrl = bangumiImageProxyUrl;
    });
  }

  Future<void> _setDoubanSource(DoubanDataSource value) async {
    try {
      await UserDataService.saveDoubanDataSource(value);
      // 验证保存是否成功
      final verified = await UserDataService.getDoubanDataSource();
      if (verified != value) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('数据源保存验证失败，请重试'),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      setState(() => _doubanSource = value);
      try {
        final cache = CacheService();
        await cache.init();
        await cache.clearPrefix('douban_');
      } catch (e) {
        // 缓存清除失败不影响设置保存
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已切换为 ${_doubanSourceLabel(value)}，豆瓣缓存已清除',
              style: const TextStyle(color: Colors.white),
            ),
            backgroundColor: AppColors.bgElevated,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('切换失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  String _doubanSourceLabel(DoubanDataSource source) {
    switch (source) {
      case DoubanDataSource.cdnTencent:
        return '腾讯云 CDN';
      case DoubanDataSource.cdnAliyun:
        return '阿里云 CDN';
      case DoubanDataSource.corsProxy:
        return 'CORS 代理';
      case DoubanDataSource.direct:
        return '直连';
    }
  }

  Future<void> _setPlayerBackend(PlayerBackendType value) async {
    await UserDataService.savePlayerBackend(value);
    setState(() => _playerBackend = value);
  }

  Future<void> _setAutoSkip(bool value) async {
    await UserDataService.saveAutoSkipOpeningEnding(value);
    setState(() => _autoSkipOpeningEnding = value);
  }

  Future<void> _setAutoNext(bool value) async {
    await UserDataService.saveAutoPlayNextEpisode(value);
    setState(() => _autoPlayNextEpisode = value);
  }

  Future<void> _setAutoSwitchSource(bool value) async {
    await UserDataService.saveAutoSwitchSource(value);
    setState(() => _autoSwitchSource = value);
  }

  Future<void> _setM3u8ProxyUrl(String url) async {
    await UserDataService.saveM3u8ProxyUrl(url);
    setState(() => _m3u8ProxyUrl = url.trim());
  }

  Future<void> _setAdFilterEnabled(bool value) async {
    await AdFilterService.setEnabled(value);
    setState(() => _adFilterEnabled = value);
  }

  Future<void> _setHardwareDecoding(bool value) async {
    await UserDataService.saveHardwareDecoding(value);
    setState(() => _hardwareDecoding = value);
  }

  Future<void> _setBangumiApiProxyType(BangumiApiProxyType value) async {
    await UserDataService.saveBangumiApiProxyType(value);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiApiProxyType = value);
  }

  Future<void> _setBangumiApiProxyUrl(String url) async {
    await UserDataService.saveBangumiApiProxyUrl(url);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiApiProxyUrl = url.trim());
  }

  Future<void> _setBangumiImageProxyType(BangumiImageProxyType value) async {
    await UserDataService.saveBangumiImageProxyType(value);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiImageProxyType = value);
  }

  Future<void> _setBangumiImageProxyUrl(String url) async {
    await UserDataService.saveBangumiImageProxyUrl(url);
    await BangumiService.loadProxySettings();
    setState(() => _bangumiImageProxyUrl = url.trim());
  }

  Future<void> _setAutoSwitchSourceTimeout(int seconds) async {
    await UserDataService.saveAutoSwitchSourceTimeout(seconds);
    setState(() => _autoSwitchSourceTimeout = seconds);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('切换源超时时间已设为 $seconds 秒'),
          backgroundColor: AppColors.bgElevated,
        ),
      );
    }
  }

  Future<void> _requestStoragePermission() async {
    final status = await Permission.storage.request();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            status.isGranted ? '已获取存储权限' : '存储权限被拒绝',
          ),
          backgroundColor: status.isGranted ? Colors.green : Colors.orange,
        ),
      );
    }
  }

  Future<void> _clearCache() async {
    final cacheService = CacheService();
    await cacheService.init();
    await cacheService.clearPrefix('douban_');
    await HainTvCacheManager().emptyCache();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            '图片与豆瓣数据缓存已清除',
            style: TextStyle(color: Colors.white),
          ),
          backgroundColor: AppColors.bgElevated,
        ),
      );
    }
  }

  Future<void> _logout() async {
    await UserDataService.clearUserData();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/login', (_) => false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      appBar: AppBar(
        backgroundColor: AppColors.bgSurface,
        elevation: 0,
        title: const Text('软件设置'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _buildSectionTitle('播放器'),
          _buildPlayerBackendTile(),
          _buildSwitchTile(
            title: '自动跳过片头片尾',
            subtitle: '到达片头/片尾区域时自动跳转',
            value: _autoSkipOpeningEnding,
            onChanged: _setAutoSkip,
          ),
          _buildSwitchTile(
            title: '自动播放下一集',
            subtitle: '片尾结束后自动播放下一集',
            value: _autoPlayNextEpisode,
            onChanged: _setAutoNext,
          ),
          _buildAutoSwitchSourceTile(),
          _buildM3u8ProxyTile(),
          _buildSwitchTile(
            title: 'M3U8 去广告（本地过滤）',
            subtitle: '播放 M3U8 时使用本地规则过滤片头贴片广告',
            value: _adFilterEnabled,
            onChanged: _setAdFilterEnabled,
          ),
          _buildSwitchTile(
            title: '硬件解码',
            subtitle: 'media_kit 播放器生效；关闭后使用软件解码',
            value: _hardwareDecoding,
            onChanged: _setHardwareDecoding,
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('Bangumi 数据源'),
          _buildBangumiApiProxyTile(),
          const SizedBox(height: AppSpacing.md),
          _buildBangumiImageProxyTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('豆瓣数据源'),
          _buildDoubanSourceTile(),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('存储与权限'),
          _buildActionTile(
            title: '获取存储权限',
            subtitle: '授权应用访问设备存储以缓存图片和数据',
            icon: Icons.storage_outlined,
            onTap: _requestStoragePermission,
          ),
          _buildActionTile(
            title: '清除缓存',
            subtitle: '清除海报、图片与豆瓣数据缓存，保留播放记录、搜索记录、跳过设置等数据',
            icon: Icons.cleaning_services_outlined,
            onTap: _clearCache,
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('账户'),
          _buildActionTile(
            title: '退出登录',
            subtitle: '清除本地登录信息并返回登录页',
            icon: Icons.logout_outlined,
            onTap: _logout,
            danger: true,
          ),
          const SizedBox(height: AppSpacing.lg),
          _buildSectionTitle('关于'),
          _buildInfoTile(
            title: '版本',
            value: '1.1.2',
          ),
          _buildInfoTile(
            title: '作者',
            value: '海因茨',
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(
        left: AppSpacing.md,
        bottom: AppSpacing.md,
      ),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textMuted,
        ),
      ),
    );
  }

  Widget _buildPlayerBackendTile() {
    return _buildCard(
      child: Column(
        children: [
          _buildRadioTile<PlayerBackendType>(
            title: 'ExoPlayer（默认）',
            subtitle: 'Android 原生播放器，硬解能力强',
            value: PlayerBackendType.exo,
            groupValue: _playerBackend,
            onChanged: _setPlayerBackend,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<PlayerBackendType>(
            title: 'media_kit',
            subtitle: '兼容性强，支持 HLS/DASH/MKV',
            value: PlayerBackendType.mediaKit,
            groupValue: _playerBackend,
            onChanged: _setPlayerBackend,
          ),
        ],
      ),
    );
  }

  Widget _buildDoubanSourceTile() {
    return _buildCard(
      child: Column(
        children: [
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.sm,
            ),
            child: Text(
              '当前：${_doubanSourceLabel(_doubanSource)}',
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.textMuted,
              ),
            ),
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: '直连（默认）',
            subtitle: '直接访问豆瓣官方接口',
            value: DoubanDataSource.direct,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: '腾讯云 CDN',
            subtitle: '通过腾讯云 CDN 加速访问',
            value: DoubanDataSource.cdnTencent,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: '阿里云 CDN',
            subtitle: '通过阿里云 CDN 加速访问',
            value: DoubanDataSource.cdnAliyun,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
          const Divider(height: 1, color: AppColors.border),
          _buildRadioTile<DoubanDataSource>(
            title: 'CORS 代理',
            subtitle: '通过 CORS 代理服务器访问',
            value: DoubanDataSource.corsProxy,
            groupValue: _doubanSource,
            onChanged: _setDoubanSource,
          ),
        ],
      ),
    );
  }

  Widget _buildAutoSwitchSourceTile() {
    return _buildCard(
      child: Column(
        children: [
          Builder(
            builder: (context) => FocusableWidget(
              onTap: () => _setAutoSwitchSource(!_autoSwitchSource),
              onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
              child: SwitchListTile(
                title: const Text(
                  '播放失败自动切换播放源',
                  style: TextStyle(color: AppColors.textPrimary),
                ),
                subtitle: const Text(
                  '当前源无法播放时按测速顺序自动尝试其他源',
                  style: TextStyle(
                    color: AppColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
                value: _autoSwitchSource,
                onChanged: _setAutoSwitchSource,
                activeThumbColor: AppColors.primary,
                inactiveThumbColor: AppColors.textMuted,
              ),
            ),
          ),
          if (_autoSwitchSource) ...[
            const Divider(height: 1, color: AppColors.border),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm,
              ),
              child: Text(
                '当前：$_autoSwitchSourceTimeout 秒',
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
            _buildRadioTile<int>(
              title: '10 秒',
              subtitle: '默认较短等待时间',
              value: 10,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
            const Divider(height: 1, color: AppColors.border),
            _buildRadioTile<int>(
              title: '15 秒',
              subtitle: '适中等待时间',
              value: 15,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
            const Divider(height: 1, color: AppColors.border),
            _buildRadioTile<int>(
              title: '30 秒',
              subtitle: '较长等待时间，适合弱网或源响应慢的环境',
              value: 30,
              groupValue: _autoSwitchSourceTimeout,
              onChanged: _setAutoSwitchSourceTimeout,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildM3u8ProxyTile() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () async {
            final controller = TextEditingController(text: _m3u8ProxyUrl);
            final confirmed = await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                backgroundColor: AppColors.bgSurface,
                title: const Text('M3U8 代理地址'),
                content: TextField(
                  controller: controller,
                  autofocus: true,
                  style: const TextStyle(color: AppColors.textPrimary),
                  decoration: const InputDecoration(
                    hintText: '例如 http://127.0.0.1:8080/proxy?url=',
                    hintStyle: TextStyle(color: AppColors.textMuted),
                    border: OutlineInputBorder(),
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('取消'),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    child: const Text('保存'),
                  ),
                ],
              ),
            );
            if (confirmed == true) {
              await _setM3u8ProxyUrl(controller.text);
            }
            controller.dispose();
          },
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.md,
              vertical: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'M3U8 代理地址',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  _m3u8ProxyUrl.isEmpty ? '未配置' : _m3u8ProxyUrl,
                  style: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '配置后 M3U8/HLS 播放地址将通过代理请求，用于解决跨域或 Referer 限制',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBangumiApiProxyTile() {
    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bangumi 数据代理',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '选择获取 Bangumi 番剧数据的方式，服务器无法访问 api.bgm.tv 时可切换反代',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _buildRadioTile<BangumiApiProxyType>(
            title: '直连（直接访问 api.bgm.tv）',
            value: BangumiApiProxyType.direct,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          _buildRadioTile<BangumiApiProxyType>(
            title: 'Bangumi 反代 By CMLiussss（解决服务器被墙）',
            value: BangumiApiProxyType.cmliussss,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          _buildRadioTile<BangumiApiProxyType>(
            title: '自定义反代地址',
            value: BangumiApiProxyType.custom,
            groupValue: _bangumiApiProxyType,
            onChanged: _setBangumiApiProxyType,
          ),
          if (_bangumiApiProxyType == BangumiApiProxyType.custom)
            Builder(
              builder: (context) => FocusableWidget(
                onTap: () => _showBangumiProxyUrlInput(
                  title: 'Bangumi 反代地址',
                  hint: '例如 https://api.example.com',
                  current: _bangumiApiProxyUrl,
                  onSave: _setBangumiApiProxyUrl,
                ),
                onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bangumiApiProxyUrl.isEmpty ? '点击输入反代地址' : _bangumiApiProxyUrl,
                        style: TextStyle(
                          fontSize: 13,
                          color: _bangumiApiProxyUrl.isEmpty
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      const Text(
                        '与官方 api.bgm.tv 路径兼容的反代地址，不含末尾斜杠',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_bangumiApiProxyType == BangumiApiProxyType.cmliussss)
            const Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Thanks to @CMLiussss',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBangumiImageProxyTile() {
    return _buildCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
              left: AppSpacing.md,
              right: AppSpacing.md,
              top: AppSpacing.md,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Bangumi 图片代理',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                const Text(
                  '选择获取 Bangumi 封面图片的方式，服务器无法访问 lain.bgm.tv 时可切换',
                  style: TextStyle(
                    fontSize: 12,
                    color: AppColors.textSecondary,
                  ),
                ),
              ],
            ),
          ),
          _buildRadioTile<BangumiImageProxyType>(
            title: '直连（直接请求 lain.bgm.tv）',
            value: BangumiImageProxyType.direct,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          _buildRadioTile<BangumiImageProxyType>(
            title: 'Bangumi 图片 CDN By CMLiussss',
            value: BangumiImageProxyType.cmliussss,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          _buildRadioTile<BangumiImageProxyType>(
            title: '自定义代理',
            value: BangumiImageProxyType.custom,
            groupValue: _bangumiImageProxyType,
            onChanged: _setBangumiImageProxyType,
          ),
          if (_bangumiImageProxyType == BangumiImageProxyType.custom)
            Builder(
              builder: (context) => FocusableWidget(
                onTap: () => _showBangumiProxyUrlInput(
                  title: 'Bangumi 图片代理地址',
                  hint: '例如 https://img.example.com/proxy?url=',
                  current: _bangumiImageProxyUrl,
                  onSave: _setBangumiImageProxyUrl,
                ),
                onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _bangumiImageProxyUrl.isEmpty ? '点击输入图片代理地址' : _bangumiImageProxyUrl,
                        style: TextStyle(
                          fontSize: 13,
                          color: _bangumiImageProxyUrl.isEmpty
                              ? AppColors.textMuted
                              : AppColors.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      const Text(
                        '接收原始图片 URL 并返回图片的代理地址',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (_bangumiImageProxyType == BangumiImageProxyType.cmliussss)
            const Padding(
              padding: EdgeInsets.only(
                left: AppSpacing.md,
                right: AppSpacing.md,
                bottom: AppSpacing.md,
              ),
              child: Text(
                'Thanks to @CMLiussss',
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.textMuted,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showBangumiProxyUrlInput({
    required String title,
    required String hint,
    required String current,
    required ValueChanged<String> onSave,
  }) async {
    final controller = TextEditingController(text: current);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppColors.bgSurface,
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            hintText: hint,
            hintStyle: const TextStyle(color: AppColors.textMuted),
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      onSave(controller.text);
    }
    controller.dispose();
  }

  void _ensureVisibleOnFocus(BuildContext context, bool focused) {
    if (focused) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (context.mounted) {
          Scrollable.ensureVisible(
            context,
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOut,
            alignment: 0.5,
          );
        }
      });
    }
  }

  Widget _buildSwitchTile({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () => onChanged(!value),
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: SwitchListTile(
            title: Text(
              title,
              style: const TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              subtitle,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.primary,
            inactiveThumbColor: AppColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildActionTile({
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    bool danger = false,
  }) {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: onTap,
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              icon,
              color: danger ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(
              title,
              style: TextStyle(
                color: danger ? AppColors.primary : AppColors.textPrimary,
              ),
            ),
            subtitle: Text(
              subtitle,
              style: const TextStyle(color: AppColors.textSecondary, fontSize: 12),
            ),
            trailing: const Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoTile({required String title, required String value}) {
    return _buildCard(
      child: ListTile(
        title: Text(
          title,
          style: const TextStyle(color: AppColors.textPrimary),
        ),
        trailing: Text(
          value,
          style: const TextStyle(color: AppColors.textSecondary),
        ),
      ),
    );
  }

  Widget _buildRadioTile<T>({
    required String title,
    String? subtitle,
    required T value,
    required T groupValue,
    required ValueChanged<T> onChanged,
  }) {
    final selected = value == groupValue;
    return Builder(
      builder: (context) => FocusableWidget(
        onTap: () => onChanged(value),
        onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
        child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.sm,
        ),
        child: Row(
          children: [
            Container(
              width: 22,
              height: 22,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: selected ? AppColors.primary : AppColors.textMuted,
                  width: 2,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: AppColors.primary,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: selected ? AppColors.primary : AppColors.textPrimary,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: const TextStyle(
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
  );
}

  Widget _buildCard({required Widget child}) {
    return Container(
      margin: const EdgeInsets.only(bottom: AppSpacing.md),
      decoration: BoxDecoration(
        color: AppColors.bgElevated,
        borderRadius: BorderRadius.circular(AppRadius.md),
        border: Border.all(color: AppColors.border),
      ),
      child: child,
    );
  }
}
