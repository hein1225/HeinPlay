import 'package:flutter/material.dart';
import 'package:hain_tv/services/app_mode_service.dart';
import 'package:hain_tv/services/home_data_preload.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

/// 「添加服务器」对话框。
///
/// 供应用内「加号」入口使用（AppGallery 上架整改：服务器登录改为非必需，
/// 审核员可在应用内自行添加服务器）。
///
/// 行为：
/// - 只填地址、不填密码 → 仅保存服务器地址（不登录），提示用户可稍后登录。
/// - 填了地址与密码 → 立即登录；成功后写入账号与 Cookie，并广播
///   [AppModeService] 切到服务器态（首页随即刷新出海报）。
/// - 登录失败 → 保留已填内容并提示错误，不阻塞应用其它功能。
Future<void> showAddServerDialog(BuildContext context) async {
  final serverCtrl = TextEditingController();
  final backupCtrl = TextEditingController();
  final userCtrl = TextEditingController();
  final pwdCtrl = TextEditingController();

  // 回填已保存的服务器与账号，用户不必重填。
  final savedServer = await UserDataService.getServerUrl();
  if (savedServer != null && savedServer.isNotEmpty) {
    serverCtrl.text = savedServer;
  }
  final savedBackup = await UserDataService.getBackupServerUrl();
  if (savedBackup.isNotEmpty) backupCtrl.text = savedBackup;
  final account = await UserDataService.getCurrentAccount();
  if (account != null) {
    userCtrl.text = account.username;
    pwdCtrl.text = account.password;
  }

  if (!context.mounted) {
    serverCtrl.dispose();
    backupCtrl.dispose();
    userCtrl.dispose();
    pwdCtrl.dispose();
    return;
  }

  await showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _AddServerDialog(
      serverController: serverCtrl,
      backupController: backupCtrl,
      usernameController: userCtrl,
      passwordController: pwdCtrl,
    ),
  );

  serverCtrl.dispose();
  backupCtrl.dispose();
  userCtrl.dispose();
  pwdCtrl.dispose();
}

class _AddServerDialog extends StatefulWidget {
  final TextEditingController serverController;
  final TextEditingController backupController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;

  const _AddServerDialog({
    required this.serverController,
    required this.backupController,
    required this.usernameController,
    required this.passwordController,
  });

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  bool _loading = false;
  bool _obscure = true;
  String? _error;

  Future<void> _submit() async {
    final primary = widget.serverController.text.trim();
    final backup = widget.backupController.text.trim();
    final username = widget.usernameController.text.trim();
    final password = widget.passwordController.text.trim();

    if (primary.isEmpty && backup.isEmpty) {
      setState(() => _error = '请至少填写一个服务器地址');
      return;
    }

    FocusScope.of(context).unfocus();
    setState(() {
      _loading = true;
      _error = null;
    });

    // 未填密码：只保存地址，用户可稍后登录（服务器登录为可选）。
    if (password.isEmpty) {
      final normalized = UserDataService.classifyServerUrls(primary, backup);
      await UserDataService.saveServerUrl(normalized.internet);
      await UserDataService.saveBackupServerUrl(normalized.lan);
      await UserDataService.clearLastSelectedServerUrl();
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务器地址已保存，填写账号密码后可加载影视内容')),
        );
      }
      return;
    }

    final serverUrl = primary.isNotEmpty ? primary : backup;
    final response = await LunaTVService.login(
      serverUrl: serverUrl,
      username: username,
      password: password,
    );

    if (!mounted) return;

    if (response.success) {
      final normalized = UserDataService.classifyServerUrls(primary, backup);
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
      // 登录成功后从服务器同步播放记录与收藏，并清除上一次预加载快照，
      // 使首页能立即呈现当前账号的本地缓存内容。
      await HomeDataPreload.syncAllUserData();
      HomeDataPreload.clear();
      // 切到服务器态：各页面据此刷新出海报与分类。
      await AppModeService.instance.refresh();
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('服务器连接成功')),
        );
      }
    } else {
      setState(() {
        _loading = false;
        final message = response.message ?? '';
        _error = message.isEmpty ? '连接失败，请检查服务器地址与账号' : message;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.bgSurface,
      title: const Text(
        '添加服务器',
        style: TextStyle(fontFamily: 'NotoSansSC'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: widget.serverController,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: '互联网服务器地址（可选）',
                hintText: 'https://your-server.com',
                hintStyle: TextStyle(color: AppColors.textMuted),
                labelStyle: TextStyle(color: AppColors.textSecondary),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: widget.backupController,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: '局域网服务器地址（可选）',
                hintText: 'http://192.168.1.100:3000',
                hintStyle: TextStyle(color: AppColors.textMuted),
                labelStyle: TextStyle(color: AppColors.textSecondary),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: widget.usernameController,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: '用户名（可选）',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: widget.passwordController,
              obscureText: _obscure,
              style: TextStyle(color: AppColors.textPrimary),
              decoration: InputDecoration(
                labelText: '密码（填写则立即连接）',
                labelStyle: TextStyle(color: AppColors.textSecondary),
                border: const OutlineInputBorder(),
                suffixIcon: IconButton(
                  icon: Icon(
                    _obscure ? Icons.visibility_off : Icons.visibility,
                    color: AppColors.textSecondary,
                    size: 20,
                  ),
                  onPressed: () => setState(() => _obscure = !_obscure),
                ),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: AppSpacing.md),
              Text(
                _error!,
                style: TextStyle(color: AppColors.error, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _loading ? null : () => Navigator.of(context).pop(),
          child: Text(
            '取消',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: _loading ? null : _submit,
          child: _loading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: TechLoadingIndicator(strokeWidth: 2),
                )
              : Text(
                  '保存',
                  style: TextStyle(
                    color: AppColors.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
        ),
      ],
    );
  }
}
