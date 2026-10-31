import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hain_tv/theme.dart';
import 'package:hain_tv/screens/settings/privacy_policy_screen.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 首启动隐私政策同意弹窗（AppGallery 上架合规要求）。
///
/// 首次启动应用时弹出，说明数据处理方式并要求用户明确同意；
/// 用户同意后写入本地标记，之后不再打扰。不同意则退出应用。
Future<void> ensurePrivacyConsent(BuildContext context) async {
  const key = 'privacy_consent_v1';
  final prefs = await SharedPreferences.getInstance();
  if (prefs.getBool(key) == true) return;

  final accepted = await showDialog<Object>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgSurface,
      title: const Text(
        '隐私政策与用户协议',
        style: TextStyle(fontFamily: 'NotoSansSC'),
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '欢迎使用海因影视。开始使用前，请阅读并同意《隐私政策》与《用户协议》。\n\n'
              '要点：\n'
              '· 本软件为开源客户端，不收集、不上传您的个人信息；\n'
              '· 您填写的服务器地址、账号与播放记录仅保存在本机；\n'
              '· 权限用途：网络访问（连接您配置的服务器与内容接口）、获取网络状态（连接提示）、'
              '后台运行（保持播放不中断）；\n'
              '· 影视内容均由您自行建立的服务器提供。',
              style: TextStyle(
                fontFamily: 'NotoSansSC',
                fontSize: 13,
                height: 1.6,
                color: AppColors.textSecondary,
              ),
            ),
            const SizedBox(height: AppSpacing.md),
            GestureDetector(
              onTap: () => Navigator.of(ctx).pop('policy'),
              child: Text(
                '查看完整条款 >',
                style: TextStyle(
                  fontFamily: 'NotoSansSC',
                  fontSize: 13,
                  color: AppColors.primary,
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: Text(
            '不同意',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(
            '同意并继续',
            style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );

  // 用户选择查看完整条款：打开全文页，返回后再重新征求同意。
  if (accepted == 'policy') {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const PrivacyPolicyScreen()),
    );
    if (context.mounted) {
      await ensurePrivacyConsent(context);
    }
    return;
  }

  if (accepted == true) {
    await prefs.setBool(key, true);
    return;
  }

  // 用户不同意：按合规要求不进入应用，退出。
  await SystemNavigator.pop();
}
