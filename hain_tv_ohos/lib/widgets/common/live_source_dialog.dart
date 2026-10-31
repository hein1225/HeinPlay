import 'package:flutter/material.dart';
import 'package:hain_tv/theme.dart';

/// 直播源编辑对话框（新增 / 编辑共用）。
///
/// 从 [MobileLiveScreen] 抽出，供「添加」菜单与直播页复用，避免两处重复实现。
/// 返回 null 表示用户取消；返回记录包含名称与地址。
Future<({String name, String url})?> showLiveSourceDialog(
  BuildContext context, {
  required String title,
  String initialName = '',
  String initialUrl = '',
}) async {
  final nameCtrl = TextEditingController(text: initialName);
  final urlCtrl = TextEditingController(text: initialUrl);
  final result = await showDialog<({String name, String url})>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: AppColors.bgSurface,
      title: Text(
        title,
        style: TextStyle(fontFamily: 'NotoSansSC', color: AppColors.textPrimary),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: nameCtrl,
            decoration: InputDecoration(
              labelText: '直播源名称',
              labelStyle: TextStyle(color: AppColors.textSecondary),
              border: OutlineInputBorder(),
            ),
            style: TextStyle(color: AppColors.textPrimary),
          ),
          const SizedBox(height: AppSpacing.md),
          TextField(
            controller: urlCtrl,
            decoration: InputDecoration(
              labelText: '直播源地址（M3U/M3U8/JSON 链接或内容）',
              labelStyle: TextStyle(color: AppColors.textSecondary),
              border: OutlineInputBorder(),
            ),
            style: TextStyle(color: AppColors.textPrimary),
            maxLines: 3,
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text(
            '取消',
            style: TextStyle(color: AppColors.textSecondary),
          ),
        ),
        TextButton(
          onPressed: () {
            final name = nameCtrl.text.trim();
            final url = urlCtrl.text.trim();
            if (name.isEmpty || url.isEmpty) return;
            Navigator.of(ctx).pop((name: name, url: url));
          },
          child: Text(
            '保存',
            style: TextStyle(color: AppColors.primary, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    ),
  );
  nameCtrl.dispose();
  urlCtrl.dispose();
  return result;
}
