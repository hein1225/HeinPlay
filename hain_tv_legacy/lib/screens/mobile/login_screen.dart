import 'package:flutter/material.dart';
import 'package:hain_tv/services/home_data_preload.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class MobileLoginScreen extends StatefulWidget {
  const MobileLoginScreen({super.key});

  @override
  State<MobileLoginScreen> createState() => _MobileLoginScreenState();
}

class _MobileLoginScreenState extends State<MobileLoginScreen> {
  final _serverController = TextEditingController();
  final _backupServerController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _loading = false;
  bool _obscurePassword = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadSavedData();
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
    _serverController.dispose();
    _backupServerController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
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

    FocusScope.of(context).unfocus();
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
    return Scaffold(
      backgroundColor: AppColors.bgApp,
      body: SafeArea(
        child: Stack(
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
          '手机版',
          style: TextStyle(fontSize: 14, color: AppColors.textSecondary),
        ),
      ],
    );
  }

  Widget _buildForm() {
    return Column(
      children: [
        _buildInputField(
          controller: _serverController,
          label: '互联网服务器地址',
          hint: 'https://your-lunatv-server.com（建议公网域名）',
          icon: Icons.link,
          textInputAction: TextInputAction.next,
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
        _buildInputField(
          controller: _backupServerController,
          label: '局域网服务器地址',
          hint: '例如 http://192.168.1.100:3000（局域网地址）',
          icon: Icons.link_outlined,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildInputField(
          controller: _usernameController,
          label: '用户名',
          hint: 'LunaTV 登录用户名',
          icon: Icons.person_outline,
          textInputAction: TextInputAction.next,
        ),
        const SizedBox(height: AppSpacing.md),
        _buildInputField(
          controller: _passwordController,
          label: '密码',
          hint: 'LunaTV 登录密码',
          icon: Icons.lock_outline,
          obscureText: _obscurePassword,
          textInputAction: TextInputAction.done,
          onSubmitted: (_) => _login(),
          suffixIcon: IconButton(
            icon: Icon(
              _obscurePassword ? Icons.visibility_off : Icons.visibility,
              color: AppColors.textSecondary,
              size: 20,
            ),
            onPressed: () {
              setState(() => _obscurePassword = !_obscurePassword);
            },
          ),
        ),
      ],
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    bool obscureText = false,
    TextInputAction? textInputAction,
    ValueChanged<String>? onSubmitted,
    Widget? suffixIcon,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscureText,
      textInputAction: textInputAction,
      onSubmitted: onSubmitted,
      style: TextStyle(color: AppColors.textPrimary),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: TextStyle(color: AppColors.textMuted),
        labelStyle: TextStyle(color: AppColors.textSecondary),
        prefixIcon: Icon(icon, color: AppColors.textSecondary),
        suffixIcon: suffixIcon,
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
          borderSide: BorderSide(color: AppColors.primary, width: 2),
        ),
      ),
    );
  }

  Widget _buildLoginButton() {
    return SizedBox(
      width: double.infinity,
      height: 48,
      child: ElevatedButton(
        onPressed: _loading ? null : _login,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: Colors.white,
          disabledBackgroundColor: AppColors.primary.withValues(alpha: 0.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.md),
          ),
          textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        ),
        child: _loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: TechLoadingIndicator(strokeWidth: 2, color: Colors.white),
              )
            : const Text('登录'),
      ),
    );
  }
}
