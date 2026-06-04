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

  /// 奶白肚皮色，温暖的全局背景。
  static const Color background = Color(0xFFFFF8F0);

  /// 卡片/表面色。
  static const Color surface = Color(0xFFFFFFFF);

  /// 主品牌色上的前景色。
  static const Color onPrimary = Color(0xFFFFFFFF);

  /// 主要文字色（暖棕，呼应猫咪轮廓）。
  static const Color textPrimary = Color(0xFF3D2C1E);

  /// 次要文字色。
  static const Color textSecondary = Color(0xFF8A7763);
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
      surface: AppColors.surface,
    );

    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: AppColors.background,
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
