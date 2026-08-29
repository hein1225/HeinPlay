import 'package:flutter/material.dart';

import 'services/theme_mode_service.dart';

/// 应用调色板。
///
/// 主色（海蓝）在明暗主题下保持一致；背景与文字在明亮主题下反相，
/// 以保证可读性。所有颜色均为运行时 getter，依据 [ThemeModeService] 的
/// 实际亮度动态返回，因此调用点（如 `AppColors.bgApp`）无需随主题改动。
class AppColors {
  /// 海蓝色主体色，与载入封面海浪/胶片色调保持一致。明暗主题下均不变。
  static const Color primary = Color(0xFF00C8E0);
  static const Color primaryHover = Color(0xFF00E0FF);
  static const Color primaryTint = Color(0x2600C8E0);
  static const Color primaryMuted = Color(0x9900C8E0);

  /// 科技感加载圈默认使用的更鲜亮的海蓝色。
  static const Color loading = Color(0xFF00F0FF);

  // —— 随主题切换的背景与文字 ——
  static Color get bgApp =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF0A0A0F);
  static Color get bgSurface =>
      _light ? const Color(0xFFF4F4F7) : const Color(0xFF14141F);
  static Color get bgElevated =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF1C1C2E);
  static Color get bgOverlay =>
      _light ? const Color(0xD9FFFFFF) : const Color(0xD90A0A0F);

  static Color get textPrimary =>
      _light ? const Color(0xFF0A0A0F) : const Color(0xFFF0F0F5);
  static Color get textSecondary =>
      _light ? const Color(0xFF4B5563) : const Color(0xFF9CA3AF);
  static Color get textMuted =>
      _light ? const Color(0xFF6B7280) : const Color(0xFF6B7280);
  static Color get textInverse =>
      _light ? const Color(0xFFFFFFFF) : const Color(0xFF0A0A0F);

  static Color get border =>
      _light ? const Color(0x1A000000) : const Color(0x14FFFFFF);
  static Color get borderFocus => const Color(0x8000C8E0);

  static const Color success = Color(0xFF22C55E);
  static const Color warning = Color(0xFFF59E0B);
  static const Color error = Color(0xFFEF4444);
  static const Color info = Color(0xFF3B82F6);

  /// 当前是否处于明亮主题，依据 [ThemeModeService] 的实际亮度动态返回。
  static bool get _light => ThemeModeService.instance.effectiveIsLight;

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

/// 根据当前主题模式构建 [ThemeData]。
/// 由 [buildLightTheme] / [buildDarkTheme] 选择亮度，二者配合
/// [MaterialApp.themeMode] 使用。
ThemeData _buildThemeData(Brightness brightness) {
  final isLight = brightness == Brightness.light;
  final colorScheme = isLight
      ? ColorScheme.light(
          primary: AppColors.primary,
          surface: AppColors.bgSurface,
          surfaceContainerHighest: AppColors.bgElevated,
          onSurface: AppColors.textPrimary,
          onSurfaceVariant: AppColors.textSecondary,
          outline: AppColors.border,
        )
      : ColorScheme.dark(
          primary: AppColors.primary,
          surface: AppColors.bgSurface,
          surfaceContainerHighest: AppColors.bgElevated,
          onSurface: AppColors.textPrimary,
          onSurfaceVariant: AppColors.textSecondary,
          outline: AppColors.border,
        );

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    scaffoldBackgroundColor: AppColors.bgApp,
    colorScheme: colorScheme,
    textTheme: TextTheme(
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
    appBarTheme: AppBarTheme(
      backgroundColor: AppColors.bgSurface,
      elevation: 0,
      centerTitle: true,
      titleTextStyle: TextStyle(
        fontFamily: 'NotoSansSC',
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: AppColors.textPrimary,
      ),
      iconTheme: IconThemeData(color: AppColors.textPrimary),
      actionsIconTheme: IconThemeData(color: AppColors.textPrimary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.bgSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: AppColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: AppColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.md),
        borderSide: BorderSide(color: AppColors.borderFocus),
      ),
      hintStyle: TextStyle(color: AppColors.textMuted),
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
    // 全局滚动条样式：细、圆角、半透明。
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

ThemeData buildLightTheme() => _buildThemeData(Brightness.light);

ThemeData buildDarkTheme() => _buildThemeData(Brightness.dark);

/// 兼容旧调用：等价于 [buildDarkTheme]（默认主题）。
@Deprecated('使用 buildLightTheme/buildDarkTheme 配合 themeMode')
ThemeData buildAppTheme() => buildDarkTheme();
