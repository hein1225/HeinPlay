import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/services/home_data_preload.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/remote_input_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _serverController = TextEditingController();
  final _backupServerController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _serverFocusNode = FocusNode();
  final _backupServerFocusNode = FocusNode();
  final _usernameFocusNode = FocusNode();
  final _passwordFocusNode = FocusNode();
  final _loginButtonFocusNode = FocusNode();
  final _qrButtonFocusNode = FocusNode();
  bool _loading = false;
  String? _error;
  // 电脑版（Windows / Linux）不需要二维码登录；TV 版默认焦点在扫码登录，
  // 电脑版默认焦点在服务器地址输入框。
  final bool _hasQrLogin = !DeviceUtils.isComputer;
  late int _focusedIndex = _hasQrLogin ? 0 : 1;

  final _remoteInputService = RemoteInputService();
  StreamSubscription<Map<String, String>>? _qrLoginSub;
  bool _qrDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _loadSavedData();
    if (_hasQrLogin) {
      _setupQrLogin();
    }
    // 首帧渲染后设置唯一初始焦点，避免多个 FocusableWidget 同时 autofocus 导致双焦点。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      switch (_focusedIndex) {
        case 0:
          _qrButtonFocusNode.requestFocus();
        case 1:
          _serverFocusNode.requestFocus();
        case 2:
          _backupServerFocusNode.requestFocus();
        case 3:
          _usernameFocusNode.requestFocus();
        case 4:
          _passwordFocusNode.requestFocus();
        case 5:
          _loginButtonFocusNode.requestFocus();
      }
    });
  }

  void _setupQrLogin() {
    _qrLoginSub = _remoteInputService.onLogin.listen((data) {
      if (!mounted) return;
      final serverUrl = data['serverUrl'] ?? '';
      final backupServerUrl = data['backupServerUrl'] ?? '';
      final username = data['username'] ?? '';
      final password = data['password'] ?? '';
      if ((serverUrl.isEmpty && backupServerUrl.isEmpty) || password.isEmpty) return;

      _serverController.text = serverUrl;
      _backupServerController.text = backupServerUrl;
      _usernameController.text = username;
      _passwordController.text = password;
      setState(() => _focusedIndex = 5);

      if (_qrDialogShowing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        setState(() => _qrDialogShowing = false);
      }

      _login();
    });
  }

  Future<void> _loadSavedData() async {
    final serverUrl = await UserDataService.getServerUrl();
    if (serverUrl != null && serverUrl.isNotEmpty) {
      _serverController.text = serverUrl;
    }
    final backupServerUrl = await UserDataService.getBackupServerUrl();
    if (backupServerUrl.isNotEmpty) {
      _backupServerController.text = backupServerUrl;
    }
    final account = await UserDataService.getCurrentAccount();
    if (account != null) {
      _usernameController.text = account.username;
      _passwordController.text = account.password;
    }
  }

  @override
  void dispose() {
    _qrLoginSub?.cancel();
    _remoteInputService.dispose();
    _serverController.dispose();
    _backupServerController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _serverFocusNode.dispose();
    _backupServerFocusNode.dispose();
    _usernameFocusNode.dispose();
    _passwordFocusNode.dispose();
    _loginButtonFocusNode.dispose();
    _qrButtonFocusNode.dispose();
    super.dispose();
  }

  void _moveFocus(int direction) {
    final minIndex = _hasQrLogin ? 0 : 1;
    final newIndex = (_focusedIndex + direction).clamp(minIndex, 5);
    setState(() => _focusedIndex = newIndex);

    // 请求对应焦点
    switch (newIndex) {
      case 0:
        if (_hasQrLogin) _qrButtonFocusNode.requestFocus();
      case 1:
        _serverFocusNode.requestFocus();
      case 2:
        _backupServerFocusNode.requestFocus();
      case 3:
        _usernameFocusNode.requestFocus();
      case 4:
        _passwordFocusNode.requestFocus();
      case 5:
        _loginButtonFocusNode.requestFocus();
    }
  }

  void _onConfirm() {
    switch (_focusedIndex) {
      case 0:
        if (_hasQrLogin) _showQrLoginDialog();
      case 1:
        _serverFocusNode.requestFocus();
      case 2:
        _backupServerFocusNode.requestFocus();
      case 3:
        _usernameFocusNode.requestFocus();
      case 4:
        _passwordFocusNode.requestFocus();
      case 5:
        if (!_loading) _login();
    }
  }

  Future<void> _login() async {
    final primaryUrl = _serverController.text.trim();
    final backupUrl = _backupServerController.text.trim();
    final username = _usernameController.text.trim();
    final password = _passwordController.text.trim();

    if (primaryUrl.isEmpty && backupUrl.isEmpty) {
      setState(() => _error = '请至少填写一个服务器地址');
      return;
    }
    if (password.isEmpty) {
      setState(() => _error = '请输入密码');
      return;
    }

    // 优先使用互联网服务器（主服务器），未填写时使用局域网服务器。
    final serverUrl = primaryUrl.isNotEmpty ? primaryUrl : backupUrl;

    setState(() {
      _loading = true;
      _error = null;
    });

    final response = await LunaTVService.login(
      serverUrl: serverUrl,
      username: username,
      password: password,
    );

    if (response.success) {
      final normalized = UserDataService.classifyServerUrls(primaryUrl, backupUrl);
      await UserDataService.saveServerUrl(normalized.internet);
      await UserDataService.saveBackupServerUrl(normalized.lan);
      await UserDataService.clearLastSelectedServerUrl();
      LunaTVService.resetSharedClient();
      await UserDataService.saveUserData(
        serverUrl: normalized.internet,
        username: username,
        password: password,
        cookies: response.data ?? '',
      );
      // 登录页入口不经过 SplashScreen，首页“首次进入”标记不会被重置；
      // 此处主动从服务器同步播放记录与收藏夹到本地缓存，并据此处理标记，
      // 确保登录后首页能加载“继续观看/播放记录/收藏夹”。
      final synced = await HomeDataPreload.syncAllUserData();
      // 清除可能残留的上一次预加载数据，避免首页直接消费旧账号/旧会话快照；
      // 无残留时首页会走自身 _loadData 兜底，用当前账号的本地缓存渲染。
      HomeDataPreload.clear();
      if (synced) {
        await UserDataService.markHomeFirstEntryCompleted();
      } else {
        await UserDataService.resetHomeFirstEntryCompleted();
      }
      if (mounted) {
        Navigator.of(context).pushReplacementNamed('/home');
      }
    } else {
      setState(() {
        _loading = false;
        _error = response.message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      // 仅用于拦截方向键/回车键，不自获取焦点；初始焦点由 initState 统一设置。
      autofocus: false,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent) {
          switch (event.logicalKey) {
            case LogicalKeyboardKey.arrowUp:
              _moveFocus(-1);
              return KeyEventResult.handled;
            case LogicalKeyboardKey.arrowDown:
              _moveFocus(1);
              return KeyEventResult.handled;
            case LogicalKeyboardKey.select:
            case LogicalKeyboardKey.enter:
              _onConfirm();
              return KeyEventResult.handled;
            case LogicalKeyboardKey.goBack:
            case LogicalKeyboardKey.escape:
              // TV/Android 返回键会触发系统返回手势，此处直接消费 KeyEvent，
              // 避免与系统返回重复响应导致连退两层。Windows ESC 需要主动 pop。
              if (DeviceUtils.isWindows) {
                Navigator.of(context).pop();
              }
              return KeyEventResult.handled;
          }
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: AppColors.bgApp,
        body: Stack(
          fit: StackFit.expand,
          children: [
            Positioned.fill(
              child: Container(
                decoration: BoxDecoration(
                  gradient: RadialGradient(
                    center: const Alignment(0, -0.3),
                    radius: 0.8,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.15),
                      AppColors.bgApp,
                    ],
                  ),
                ),
              ),
            ),
            Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(AppSpacing.xl),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildLogo(),
                      const SizedBox(height: AppSpacing.xl),
                      if (_hasQrLogin) ...[
                        _buildQrLoginButton(),
                        const SizedBox(height: AppSpacing.lg),
                      ],
                      _buildForm(),
                      const SizedBox(height: AppSpacing.lg),
                      _buildLoginButton(),
                      if (_error != null) ...[
                        const SizedBox(height: AppSpacing.md),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: AppColors.primary,
                            fontSize: 14,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                      const SizedBox(height: AppSpacing.lg),
                      Text(
                        '后续可在“我的-设置”中补充或修改服务器地址。',
                        style: TextStyle(
                          color: AppColors.textMuted,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          child: Icon(
            Icons.play_circle_fill,
            color: AppColors.primary,
            size: 40,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '海因影视',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: AppColors.textPrimary,
          ),
        ),
        const SizedBox(height: AppSpacing.xs),
        Text(
          DeviceUtils.isComputer ? '电脑版' : 'TV 版',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildForm() {
    // 索引与 _focusedIndex 对齐：0=扫码, 1=主服务器, 2=备用服务器, 3=用户名, 4=密码, 5=登录
    return Column(
      children: [
        _buildTvInputField(
          index: 1,
          controller: _serverController,
          focusNode: _serverFocusNode,
          label: '互联网服务器地址',
          hint: 'https://your-lunatv-server.com（建议填写公网可访问域名）',
          icon: Icons.link,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          '至少填写一个服务器地址，主域名建议公网域名，备用域名建议局域网地址',
          style: TextStyle(
            color: AppColors.textMuted,
            fontSize: 12,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.sm),
        _buildTvInputField(
          index: 2,
          controller: _backupServerController,
          focusNode: _backupServerFocusNode,
          label: '局域网服务器地址',
          hint: '例如 http://192.168.1.100:3000（局域网地址）',
          icon: Icons.link_outlined,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildTvInputField(
          index: 3,
          controller: _usernameController,
          focusNode: _usernameFocusNode,
          label: '用户名',
          hint: 'LunaTV 登录用户名',
          icon: Icons.person_outline,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildTvInputField(
          index: 4,
          controller: _passwordController,
          focusNode: _passwordFocusNode,
          label: '密码',
          hint: 'LunaTV 登录密码',
          icon: Icons.lock_outline,
          obscureText: true,
        ),
      ],
    );
  }

  Widget _buildTvInputField({
    required int index,
    required TextEditingController controller,
    required FocusNode focusNode,
    required String label,
    required String hint,
    required IconData icon,
    bool obscureText = false,
  }) {
    final isFocused = _focusedIndex == index;

    return FocusableWidget(
      // 统一由 initState 中的 postFrameCallback 设置唯一初始焦点，
      // 避免此处 autofocus 与扫码登录按钮冲突导致双焦点。
      autofocus: false,
      onTap: () {
        setState(() => _focusedIndex = index);
        focusNode.requestFocus();
      },
      padding: EdgeInsets.zero,
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: isFocused ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          obscureText: obscureText,
          style: TextStyle(color: AppColors.textPrimary),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            hintStyle: TextStyle(color: AppColors.textMuted),
            labelStyle: TextStyle(color: AppColors.textSecondary),
            prefixIcon: Icon(icon, color: AppColors.textSecondary),
            filled: true,
            fillColor: AppColors.bgElevated,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide.none,
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide.none,
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(AppRadius.md),
              borderSide: BorderSide.none,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildLoginButton() {
    final isFocused = _focusedIndex == 5;

    return FocusableWidget(
      focusNode: _loginButtonFocusNode,
      // 统一由 initState 设置初始焦点，避免 autofocus 冲突。
      autofocus: false,
      onTap: _loading ? null : _login,
      child: Container(
        width: double.infinity,
        height: 48,
        decoration: BoxDecoration(
          color: _loading
              ? AppColors.primary.withValues(alpha: 0.5)
              : AppColors.primary,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isFocused ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: Center(
          child: _loading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: TechLoadingIndicator(strokeWidth: 2, color: Colors.white),
                )
              : const Text(
                  '登录',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
        ),
      ),
    );
  }

  Widget _buildQrLoginButton() {
    final isFocused = _focusedIndex == 0;

    return FocusableWidget(
      focusNode: _qrButtonFocusNode,
      // 统一由 initState 中的 postFrameCallback 设置唯一初始焦点。
      autofocus: false,
      onTap: _loading ? null : _showQrLoginDialog,
      child: Container(
        width: double.infinity,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(
            color: isFocused ? AppColors.primary : AppColors.border,
            width: isFocused ? 2 : 1,
          ),
        ),
        child: Center(
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.qr_code_scanner,
                color: isFocused ? AppColors.primary : AppColors.textSecondary,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.xs),
              Text(
                '扫码登录',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: isFocused
                      ? AppColors.primary
                      : AppColors.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showQrLoginDialog() async {
    if (_qrDialogShowing) return;
    setState(() => _qrDialogShowing = true);

    String? url;
    String? error;
    try {
      final baseUrl = await _remoteInputService.startServer();
      url = '$baseUrl?mode=login';
    } catch (e) {
      error = '启动失败，请检查网络权限';
    }

    if (!mounted) return;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          backgroundColor: AppColors.bgSurface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.lg),
          ),
          title: Text(
            '手机扫码登录',
            style: TextStyle(
              fontFamily: 'NotoSansSC',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: AppColors.textPrimary,
            ),
          ),
          content: SizedBox(
            width: 280,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Text(
                    error,
                    style: const TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: Colors.redAccent,
                    ),
                  )
                else if (url != null) ...[
                  Container(
                    width: 200,
                    height: 200,
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(AppRadius.md),
                    ),
                    child: QrImageView(
                      data: url,
                      version: QrVersions.auto,
                      size: 180,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Text(
                    '使用手机扫描上方二维码',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 14,
                      color: AppColors.textSecondary,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    '或访问 $url',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    '在手机页面输入服务器、用户名和密码后，电视将自动登录',
                    style: TextStyle(
                      fontFamily: 'NotoSansSC',
                      fontSize: 12,
                      color: AppColors.textMuted,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ] else
                  const SizedBox(
                    width: 40,
                    height: 40,
                    child: TechLoadingIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
          actions: [
            FocusableWidget(
              autofocus: true,
              onTap: () => Navigator.of(ctx).pop(),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.lg,
                  vertical: AppSpacing.sm,
                ),
                decoration: BoxDecoration(
                  color: AppColors.primary,
                  borderRadius: BorderRadius.circular(AppRadius.md),
                ),
                child: const Text(
                  '关闭',
                  style: TextStyle(
                    fontFamily: 'NotoSansSC',
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (mounted) {
      setState(() => _qrDialogShowing = false);
    }
  }
}
