import 'package:flutter/material.dart';

class AppColors {
  static const Color primary = Color(0xFFE50914);
  static const Color primaryHover = Color(0xFFF40612);
  static const Color primaryTint = Color(0x26E50914);
  static const Color primaryMuted = Color(0x99E50914);

  static const Color bgApp = Color(0xFF0A0A0F);
  static const Color bgSurface = Color(0xFF14141F);
  static const Color bgElevated = Color(0xFF1C1C2E);
  static const Color bgOverlay = Color(0xD90A0A0F);

  static const Color textPrimary = Color(0xFFF0F0F5);
  static const Color textSecondary = Color(0xFF9CA3AF);
  static const Color textMuted = Color(0xFF6B7280);
  static const Color textInverse = Color(0xFF0A0A0F);

  static const Color border = Color(0x14FFFFFF);
  static const Color borderFocus = Color(0x80E50914);

  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);

  /// 根据评分返回标签背景色，用于豆瓣/Bangumi 评分徽章。
  /// - ≥ 9.0：蓝色
  /// - ≥ 8.0：绿色
  /// - ≥ 6.0：黄色
  /// - ＜ 6.0：红色
  /// - 无法解析：灰色
  static Color ratingColor(String? rate) {
    final score = double.tryParse(rate ?? '');
    if (score == null) return textMuted;
    if (score >= 9.0) return const Color(0xFF3B82F6);
    if (score >= 8.0) return const Color(0xFF22C55E);
    if (score >= 6.0) return const Color(0xFFEAB308);
    return const Color(0xFFEF4444);
  }
}

class AppRadius {
  static const double sm = 4;
  static const double md = 8;
  static const double lg = 12;
  static const double full = 9999;
}

class AppSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 32;
  static const double xxl = 48;
}

ThemeData buildAppTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    scaffoldBackgroundColor: AppColors.bgApp,
    colorScheme: const ColorScheme.dark(
      primary: AppColors.primary,
      surface: AppColors.bgSurface,
      surfaceContainerHighest: AppColors.bgElevated,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      outline: AppColors.border,
    ),
    textTheme: const TextTheme(
      bodyLarge: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 16,
        color: AppColors.textPrimary,
      ),
      bodyMedium: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 14,
        color: AppColors.textSecondary,
      ),
      titleLarge: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: AppColors.textPrimary,
      ),
      titleMedium: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 16,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      labelLarge: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 14,
        fontWeight: FontWeight.w500,
        color: AppColors.textPrimary,
      ),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.bgSurface,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bgSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: const BorderSide(color: AppColors.borderFocus),
      ),
      hintStyle: const TextStyle(color: AppColors.textMuted),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.sm,
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: AppColors.primary,
        foregroundColor: Colors.white,
        minimumSize: const Size(120, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
        ),
        textStyle: const TextStyle(
          fontFamily: 'NotoSansSC',
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
    // 全局滚动条样式：细、圆角、半透明，适配深色主题。
    scrollbarTheme: ScrollbarThemeData(
      thickness: WidgetStateProperty.all(4.0),
      radius: const Radius.circular(AppRadius.full),
      thumbVisibility: WidgetStateProperty.all(true),
      trackVisibility: WidgetStateProperty.all(false),
      thumbColor: WidgetStateProperty.all(
        AppColors.textMuted.withValues(alpha: 0.4),
      ),
    ),
  );
}
