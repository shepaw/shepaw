import 'package:flutter/material.dart';

/// 品牌配色：取自橘猫 logo。
///
/// - 橘色主体 → 主品牌色 [primary]
/// - 深色虎斑纹 → 按下/强调态 [primaryDark]
/// - 奶白肚皮 → 暖色背景 [background]
/// - 粉色肉垫 → 活泼的次要强调色 [accent]
class AppColors {
  AppColors._();

  /// 猫咪身体的橘色，作为主品牌色（与白色文字搭配时对比度足够用于按钮）。
  static const Color primary = Color(0xFFEE7A1E);

  /// 更深的虎斑纹橘色，用于按下/强调状态与渐变收尾。
  static const Color primaryDark = Color(0xFFD9620C);

  /// 明亮的橘色，用于渐变起点与高亮。
  static const Color primaryLight = Color(0xFFFF9F45);

  /// 柔和的橘色填充，用于容器/提示框背景。
  static const Color primaryContainer = Color(0xFFFFE7CC);

  /// 肉垫粉，活泼的次要强调色。
  static const Color accent = Color(0xFFF48FB1);

  /// 柔和的粉色填充。
  static const Color accentContainer = Color(0xFFFCE2EB);

  /// 纯净的全局背景（纯白，类似 QQ 聊天界面）。
  static const Color background = Color(0xFFFFFFFF);

  /// 卡片/表面色。
  static const Color surface = Color(0xFFFFFFFF);

  /// 中性的次级表面填充（浅灰，用于卡片/输入框等容器，避免橘调）。
  static const Color surfaceMuted = Color(0xFFF2F3F5);

  /// 中性的分隔/边框灰。
  static const Color outline = Color(0xFFE3E5E8);

  /// 主品牌色上的前景色。
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// 主要文字色（中性深灰，纯净不偏色）。
  static const Color textPrimary = Color(0xFF1F2329);

  /// 次要文字色（与会话列表预览等 UI 中的 grey[500] 一致）。
  static const Color textSecondary = Color(0xFF9E9E9E);
}

/// 应用主题。统一从 [AppColors] 派生，保证全局风格一致。
class AppTheme {
  AppTheme._();

  static ThemeData get light {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.light,
    ).copyWith(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryContainer: AppColors.primaryContainer,
      secondary: AppColors.accent,
      secondaryContainer: AppColors.accentContainer,
      // 表面与背景统一为纯净的中性白/灰，去掉橘色种子带来的暖色调。
      surface: AppColors.surface,
      onSurface: AppColors.textPrimary,
      onSurfaceVariant: AppColors.textSecondary,
      surfaceContainerLowest: AppColors.surface,
      surfaceContainerLow: const Color(0xFFFAFBFC),
      surfaceContainer: const Color(0xFFF5F6F8),
      surfaceContainerHigh: const Color(0xFFF2F3F5),
      surfaceContainerHighest: AppColors.surfaceMuted,
      surfaceVariant: AppColors.surfaceMuted,
      outline: AppColors.outline,
      outlineVariant: const Color(0xFFEDEEF0),
      // 去掉 M3 海拔叠加的橘色染色。
      surfaceTint: Colors.transparent,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: AppColors.background,
      // 全局禁用 M3 表面海拔叠加的橘色染色，保持纯净。
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.textPrimary,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
      ),
      cardTheme: const CardThemeData(
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: const DialogThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.surface,
      ),
      bottomSheetTheme: const BottomSheetThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.surface,
      ),
      popupMenuTheme: const PopupMenuThemeData(
        surfaceTintColor: Colors.transparent,
        color: AppColors.surface,
      ),
      navigationBarTheme: const NavigationBarThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.surface,
      ),
      drawerTheme: const DrawerThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: AppColors.surface,
      ),
      dividerTheme: const DividerThemeData(
        color: AppColors.outline,
      ),
      // 暖色波纹/选中态
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primary
              : null,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (states) => states.contains(WidgetState.selected)
              ? AppColors.primaryLight
              : null,
        ),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: AppColors.primary,
        foregroundColor: AppColors.onPrimary,
      ),
    );
  }

  /// 启动页 / 引导页的暖橘渐变背景。
  static const LinearGradient brandGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      AppColors.primaryLight,
      AppColors.primary,
      AppColors.primaryDark,
    ],
    stops: [0.0, 0.55, 1.0],
  );
}
