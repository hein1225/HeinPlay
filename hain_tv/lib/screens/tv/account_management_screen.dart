import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:hain_tv/models/account_info.dart';
import 'package:hain_tv/services/home_data_preload.dart';
import 'package:hain_tv/services/lunatv_service.dart';
import 'package:hain_tv/services/remote_input_service.dart';
import 'package:hain_tv/services/user_data_service.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/platform/device_utils.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';
import 'package:hain_tv/widgets/common/tech_loading_indicator.dart';

class AccountManagementScreen extends StatefulWidget {
  const AccountManagementScreen({super.key});

  @override
  State<AccountManagementScreen> createState() =>
      _AccountManagementScreenState();
}

class _AccountManagementScreenState extends State<AccountManagementScreen> {
  AccountInfo? _mainAccount;
  AccountInfo? _subAccount;
  String _activeAccount = 'main';

  final _remoteInputService = RemoteInputService();
  StreamSubscription<Map<String, String>>? _subAccountQrSub;
  bool _qrSubAccountDialogShowing = false;

  @override
  void initState() {
    super.initState();
    _loadAccounts();
    _setupSubAccountQr();
  }

  @override
  void dispose() {
    _subAccountQrSub?.cancel();
    _remoteInputService.dispose();
    super.dispose();
  }

  Future<void> _loadAccounts() async {
    final mainAccount = await UserDataService.getMainAccount();
    final subAccount = await UserDataService.getSubAccount();
    final activeAccount = await UserDataService.getActiveAccount();
    if (mounted) {
      setState(() {
        _mainAccount = mainAccount;
        _subAccount = subAccount;
        _activeAccount = activeAccount;
      });
    }
  }

  void _showSnackBar(
    String message, {
    Color? backgroundColor,
    Duration duration = const Duration(seconds: 2),
  }) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white),
        ),
        backgroundColor: backgroundColor ?? AppColors.bgElevated,
        duration: duration,
      ),
    );
  }

  Future<void> _switchAccount(String type) async {
    final target = type == 'sub' ? _subAccount : _mainAccount;
    if (target == null || target.password.isEmpty) {
      _showSnackBar('目标账号未配置', backgroundColor: Colors.red);
      return;
    }
    if (_activeAccount == type) {
      _showSnackBar('当前已经是该账号');
      return;
    }

    final serverUrl = await UserDataService.getLastSelectedServerUrl() ??
        await UserDataService.getServerUrl() ??
        await UserDataService.getBackupServerUrl();
    if (serverUrl.isEmpty) {
      _showSnackBar('服务器地址为空，无法切换', backgroundColor: Colors.red);
      return;
    }

    _showSnackBar('正在切换到${type == 'sub' ? '子' : '主'}账号...');
    final response = await LunaTVService.login(
      serverUrl: serverUrl,
      username: target.username,
      password: target.password,
    );

    if (response.success) {
      final updated = target.copyWith(cookies: response.data ?? '');
      if (type == 'sub') {
        await UserDataService.saveSubAccount(updated);
      } else {
        await UserDataService.saveMainAccount(updated);
      }
      await UserDataService.setActiveAccount(type);
      setState(() {
        if (type == 'sub') {
          _subAccount = updated;
        } else {
          _mainAccount = updated;
        }
        _activeAccount = type;
      });
      _showSnackBar('已切换到${type == 'sub' ? '子' : '主'}账号');
      await _refreshHomeAfterAccountSwitch();
    } else {
      _showSnackBar(
        '切换失败: ${response.message}',
        backgroundColor: Colors.red,
      );
    }
  }

  Future<void> _refreshHomeAfterAccountSwitch() async {
    // 清除残留的预加载快照，避免新账号首页消费旧账号缓存数据；标记已重置，
    // 首页重建时会以当前账号为准重新同步/拉取。
    HomeDataPreload.clear();
    await UserDataService.resetHomeFirstEntryCompleted();
    if (mounted) {
      Navigator.of(context).pushNamedAndRemoveUntil('/home', (_) => false);
    }
  }

  Future<void> _configureSubAccount({AccountInfo? initial}) async {
    final isEditing = initial != null;
    final usernameController = TextEditingController(
      text: initial?.username ?? '',
    );
    final passwordController = TextEditingController(
      text: initial?.password ?? '',
    );
    final usernameNode = FocusNode();
    final passwordNode = FocusNode();
    final cancelNode = FocusNode();
    final saveNode = FocusNode();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        void closeDialog(bool value) {
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop(value);
          }
        }

        return FocusScope(
          child: AlertDialog(
            backgroundColor: AppColors.bgSurface,
            title: Text(isEditing ? '修改子账号' : '配置子账号'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      passwordNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.escape) {
                      closeDialog(false);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: usernameController,
                    focusNode: usernameNode,
                    autofocus: true,
                    style: TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '用户名（数据库模式需填写）',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowUp) {
                      usernameNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      cancelNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.escape) {
                      closeDialog(false);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: passwordController,
                    focusNode: passwordNode,
                    obscureText: true,
                    style: TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '密码',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FocusableWidget(
                      focusNode: cancelNode,
                      onTap: () => closeDialog(false),
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowUp) {
                          passwordNode.requestFocus();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    FocusableWidget(
                      focusNode: saveNode,
                      onTap: () => closeDialog(true),
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowUp) {
                          passwordNode.requestFocus();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        child: Text(
                          isEditing ? '保存' : '保存并切换',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    usernameNode.dispose();
    passwordNode.dispose();
    cancelNode.dispose();
    saveNode.dispose();

    if (confirmed == true) {
      final username = usernameController.text.trim();
      final password = passwordController.text.trim();
      if (password.isEmpty) {
        usernameController.dispose();
        passwordController.dispose();
        _showSnackBar('密码不能为空', backgroundColor: Colors.red);
        return;
      }

      final account = AccountInfo(username: username, password: password);
      await UserDataService.saveSubAccount(account);
      setState(() => _subAccount = account);
      _showSnackBar(isEditing ? '子账号已修改' : '子账号已保存，尝试切换...');

      usernameController.dispose();
      passwordController.dispose();

      if (isEditing) {
        // 如果当前正在使用子账号，用新凭据重新登录并刷新。
        if (_activeAccount == 'sub') {
          await _switchAccount('sub');
        }
        return;
      }

      await _switchAccount('sub');
    } else {
      usernameController.dispose();
      passwordController.dispose();
    }
  }

  Future<void> _deleteSubAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => FocusScope(
        child: AlertDialog(
          backgroundColor: AppColors.bgSurface,
          title: const Text('删除子账号'),
          content: const Text('确定要删除本地保存的子账号信息吗？'),
          actions: [
          FocusableWidget(
            autofocus: true,
            onTap: () => Navigator.of(dialogContext).pop(false),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text(
                '取消',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
          ),
          FocusableWidget(
            onTap: () => Navigator.of(dialogContext).pop(true),
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
              child: Text(
                '删除',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: AppColors.primary,
                ),
              ),
            ),
          ),
        ],
      ),
    ),
    );

    if (confirmed != true) return;

    final wasActiveSub = _activeAccount == 'sub';
    await UserDataService.saveSubAccount(
      AccountInfo(username: '', password: ''),
    );
    if (wasActiveSub) {
      await UserDataService.setActiveAccount('main');
    }

    if (mounted) {
      setState(() {
        _subAccount = null;
        if (wasActiveSub) _activeAccount = 'main';
      });
    }
    _showSnackBar('子账号已删除');

    if (wasActiveSub) {
      await _refreshHomeAfterAccountSwitch();
    }
  }

  Future<void> _configureMainAccount() async {
    final usernameController = TextEditingController();
    final passwordController = TextEditingController();
    final usernameNode = FocusNode();
    final passwordNode = FocusNode();
    final cancelNode = FocusNode();
    final saveNode = FocusNode();

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        void closeDialog(bool value) {
          if (Navigator.of(dialogContext).canPop()) {
            Navigator.of(dialogContext).pop(value);
          }
        }

        return FocusScope(
          child: AlertDialog(
            backgroundColor: AppColors.bgSurface,
            title: const Text('配置主账号'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      passwordNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.escape) {
                      closeDialog(false);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: usernameController,
                    focusNode: usernameNode,
                    autofocus: true,
                    style: TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '用户名（数据库模式需填写）',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                Focus(
                  onKeyEvent: (node, event) {
                    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                      return KeyEventResult.ignored;
                    }
                    final key = event.logicalKey;
                    if (key == LogicalKeyboardKey.arrowUp) {
                      usernameNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.arrowDown ||
                        key == LogicalKeyboardKey.select ||
                        key == LogicalKeyboardKey.enter ||
                        key == LogicalKeyboardKey.numpadEnter) {
                      cancelNode.requestFocus();
                      return KeyEventResult.handled;
                    }
                    if (key == LogicalKeyboardKey.goBack ||
                        key == LogicalKeyboardKey.escape) {
                      closeDialog(false);
                      return KeyEventResult.handled;
                    }
                    return KeyEventResult.ignored;
                  },
                  child: TextField(
                    controller: passwordController,
                    focusNode: passwordNode,
                    obscureText: true,
                    style: TextStyle(color: AppColors.textPrimary),
                    decoration: InputDecoration(
                      hintText: '密码',
                      hintStyle: TextStyle(color: AppColors.textMuted),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(height: AppSpacing.lg),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    FocusableWidget(
                      focusNode: cancelNode,
                      onTap: () => closeDialog(false),
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowUp) {
                          passwordNode.requestFocus();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        child: Text(
                          '取消',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            color: AppColors.textPrimary,
                          ),
                        ),
                      ),
                    ),
                    FocusableWidget(
                      focusNode: saveNode,
                      onTap: () => closeDialog(true),
                      onKeyEvent: (node, event) {
                        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
                          return KeyEventResult.ignored;
                        }
                        final key = event.logicalKey;
                        if (key == LogicalKeyboardKey.arrowUp) {
                          passwordNode.requestFocus();
                          return KeyEventResult.handled;
                        }
                        if (key == LogicalKeyboardKey.goBack ||
                            key == LogicalKeyboardKey.escape) {
                          closeDialog(false);
                          return KeyEventResult.handled;
                        }
                        return KeyEventResult.ignored;
                      },
                      child: Padding(
                        padding: EdgeInsets.symmetric(horizontal: AppSpacing.md),
                        child: Text(
                          '保存',
                          style: TextStyle(
                            fontFamily: 'NotoSansSC',
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: AppColors.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );

    usernameNode.dispose();
    passwordNode.dispose();
    cancelNode.dispose();
    saveNode.dispose();

    if (confirmed == true) {
      final username = usernameController.text.trim();
      final password = passwordController.text.trim();
      if (password.isEmpty) {
        usernameController.dispose();
        passwordController.dispose();
        _showSnackBar('密码不能为空', backgroundColor: Colors.red);
        return;
      }

      final account = AccountInfo(
        username: username,
        password: password,
      );
      await UserDataService.saveMainAccount(account);
      setState(() => _mainAccount = account);
      _showSnackBar('主账号已保存');
    }
    usernameController.dispose();
    passwordController.dispose();
  }

  void _setupSubAccountQr() {
    _subAccountQrSub = _remoteInputService.onSubAccount.listen((data) async {
      if (!mounted) return;
      final username = data['username'] ?? '';
      final password = data['password'] ?? '';
      if (username.isEmpty || password.isEmpty) return;

      await UserDataService.saveSubAccount(AccountInfo(
        username: username,
        password: password,
      ));
      setState(() => _subAccount = AccountInfo(
            username: username,
            password: password,
          ));

      if (_qrSubAccountDialogShowing && Navigator.of(context).canPop()) {
        Navigator.of(context).pop();
        setState(() => _qrSubAccountDialogShowing = false);
      }
      _showSnackBar('子账号已保存，尝试切换...');
      await _switchAccount('sub');
    });
  }

  Future<void> _showSubAccountQrDialog() async {
    if (_qrSubAccountDialogShowing) return;
    setState(() => _qrSubAccountDialogShowing = true);

    String? url;
    String? error;
    try {
      final baseUrl = await _remoteInputService.startServer();
      url = '$baseUrl?mode=sub_account';
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
            '扫码输入子账号',
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
                    '在手机页面输入用户名和密码后，电视将保存并切换到子账号',
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
      setState(() => _qrSubAccountDialogShowing = false);
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
        title: const Text('账号管理'),
        leading: DeviceUtils.isWindows
            ? IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: () => Navigator.of(context).pop(),
              )
            : null,
      ),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          _buildSectionTitle('账户'),
          _buildMainAccountTile(),
          _buildSubAccountSection(),
          if (DeviceUtils.isTv && !DeviceUtils.isWindows)
            _buildQrInputSubAccountButton(),
          const SizedBox(height: AppSpacing.md),
          _buildActionTile(
            title: '退出登录',
            subtitle: '清除本地登录信息并返回登录页',
            icon: Icons.logout_outlined,
            onTap: _logout,
            danger: true,
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
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: AppColors.textMuted,
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
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMainAccountTile() {
    final active = _activeAccount == 'main';
    final configured = _mainAccount != null && _mainAccount!.password.isNotEmpty;
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: active
              ? null
              : () => configured
                  ? _switchAccount('main')
                  : _configureMainAccount(),
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              Icons.person_outline,
              color: active ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(
              '主账号${active ? '（当前使用）' : ''}',
              style: TextStyle(
                color: active ? AppColors.primary : AppColors.textPrimary,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            subtitle: Text(
              configured
                  ? (_mainAccount!.username.isEmpty
                      ? '已配置'
                      : _mainAccount!.username)
                  : '未配置，点击填写',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: active
                ? Icon(Icons.check_circle, color: AppColors.primary)
                : Icon(
                    Icons.chevron_right,
                    color: AppColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildSubAccountSection() {
    final configured = _subAccount != null && _subAccount!.password.isNotEmpty;
    return Column(
      children: [
        _buildSubAccountTile(),
        if (configured) ...[
          const SizedBox(height: AppSpacing.sm),
          _buildActionTile(
            title: '修改子账号',
            subtitle: '重新设置子账号的用户名和密码',
            icon: Icons.edit_outlined,
            onTap: () => _configureSubAccount(initial: _subAccount),
          ),
          const SizedBox(height: AppSpacing.sm),
          _buildActionTile(
            title: '删除子账号',
            subtitle: '清除本地保存的子账号信息',
            icon: Icons.delete_outline,
            onTap: _deleteSubAccount,
            danger: true,
          ),
        ],
      ],
    );
  }

  Widget _buildSubAccountTile() {
    final active = _activeAccount == 'sub';
    final configured = _subAccount != null && _subAccount!.password.isNotEmpty;
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: () {
            if (active) return;
            if (configured) {
              _switchAccount('sub');
            } else {
              _configureSubAccount();
            }
          },
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              Icons.people_outline,
              color: active ? AppColors.primary : AppColors.textSecondary,
            ),
            title: Text(
              '子账号${active ? '（当前使用）' : ''}',
              style: TextStyle(
                color: active ? AppColors.primary : AppColors.textPrimary,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
            subtitle: Text(
              configured
                  ? (_subAccount!.username.isEmpty
                      ? '已配置'
                      : _subAccount!.username)
                  : '未配置，点击填写',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: active
                ? Icon(Icons.check_circle, color: AppColors.primary)
                : Icon(
                    Icons.chevron_right,
                    color: AppColors.textSecondary,
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildQrInputSubAccountButton() {
    return _buildCard(
      child: Builder(
        builder: (context) => FocusableWidget(
          onTap: _showSubAccountQrDialog,
          onFocusChange: (focused) => _ensureVisibleOnFocus(context, focused),
          child: ListTile(
            leading: Icon(
              Icons.qr_code_scanner,
              color: AppColors.textSecondary,
            ),
            title: Text(
              '扫码输入子账号',
              style: TextStyle(color: AppColors.textPrimary),
            ),
            subtitle: Text(
              '使用手机扫码填写子账号用户名和密码',
              style: TextStyle(
                color: AppColors.textSecondary,
                fontSize: 12,
              ),
            ),
            trailing: Icon(
              Icons.chevron_right,
              color: AppColors.textSecondary,
            ),
          ),
        ),
      ),
    );
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
