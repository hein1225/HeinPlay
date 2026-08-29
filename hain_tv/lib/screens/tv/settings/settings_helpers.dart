import 'package:flutter/material.dart';

import 'package:hain_tv/theme.dart';
import 'package:hain_tv/widgets/tv/focusable.dart';

/// 设置页共享的 tile / 卡片 / 提示工具，供各分级子页复用。

void showSettingsSnackBar(
  BuildContext context,
  String message, {
  Color? backgroundColor,
  Duration duration = const Duration(seconds: 2),
}) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: backgroundColor ?? AppColors.bgElevated,
      duration: duration,
    ),
  );
}

void ensureVisibleOnFocus(BuildContext context, bool focused) {
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

Widget buildSettingsCard({required Widget child}) {
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

Widget buildSectionTitle(String title) {
  return Padding(
    padding: const EdgeInsets.only(left: AppSpacing.md, bottom: AppSpacing.md),
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

Widget buildSwitchTile({
  required BuildContext context,
  required String title,
  required String subtitle,
  required bool value,
  required ValueChanged<bool> onChanged,
}) {
  return buildSettingsCard(
    child: Builder(
      builder: (ctx) => FocusableWidget(
        onTap: () => onChanged(!value),
        onFocusChange: (focused) => ensureVisibleOnFocus(ctx, focused),
        child: SwitchListTile(
          title: Text(title, style: TextStyle(color: AppColors.textPrimary)),
          subtitle: Text(
            subtitle,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
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

Widget buildRadioTile<T>({
  required String title,
  String? subtitle,
  required T value,
  required T groupValue,
  required ValueChanged<T> onChanged,
}) {
  final selected = value == groupValue;
  return Builder(
    builder: (ctx) => FocusableWidget(
      onTap: () => onChanged(value),
      onFocusChange: (focused) => ensureVisibleOnFocus(ctx, focused),
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
                        decoration: BoxDecoration(
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
                      fontWeight:
                          selected ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: TextStyle(
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

Widget buildActionTile({
  required String title,
  required String subtitle,
  required IconData icon,
  required VoidCallback onTap,
  bool danger = false,
}) {
  return buildSettingsCard(
    child: Builder(
      builder: (ctx) => FocusableWidget(
        onTap: onTap,
        onFocusChange: (focused) => ensureVisibleOnFocus(ctx, focused),
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
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
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

Widget buildInfoTile({required String title, required String value}) {
  return buildSettingsCard(
    child: ListTile(
      title: Text(title, style: TextStyle(color: AppColors.textPrimary)),
      trailing: Text(value, style: TextStyle(color: AppColors.textSecondary)),
    ),
  );
}

/// 设置页通用的 AppBar，Windows 端带返回按钮。
PreferredSizeWidget buildSettingsAppBar({
  required BuildContext context,
  required String title,
  required bool isWindows,
}) {
  return AppBar(
    backgroundColor: AppColors.bgSurface,
    elevation: 0,
    title: Text(title),
    leading: isWindows
        ? IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: () => Navigator.of(context).pop(),
          )
        : null,
  );
}

/// 在子页中包裹滚动内容。
Widget buildSettingsScrollView({required List<Widget> children}) {
  return ListView(
    padding: const EdgeInsets.all(AppSpacing.lg),
    children: children,
  );
}
