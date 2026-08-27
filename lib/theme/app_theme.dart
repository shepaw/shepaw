import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

  /// 深色模式：页面底色。
  static const Color darkBackground = Color(0xFF111318);

  /// 深色模式：卡片/AppBar/输入栏表面。
  static const Color darkSurface = Color(0xFF1A1C20);

  /// 深色模式：次级表面（对方气泡、输入框填充）。
  static const Color darkSurfaceMuted = Color(0xFF2C2E34);

  /// 深色模式：分隔/边框。
  static const Color darkOutline = Color(0xFF3E4148);

  /// 深色模式：橘色容器填充。
  static const Color darkPrimaryContainer = Color(0xFF5C3A14);

  /// 深色模式：粉色容器填充。
  static const Color darkAccentContainer = Color(0xFF4A2A38);

  /// 深色模式：主要文字。
  static const Color darkTextPrimary = Color(0xFFE8EAED);

  /// 深色模式：次要文字。
  static const Color darkTextSecondary = Color(0xFF9AA0A6);
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
      onPrimaryContainer: AppColors.primaryDark,
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
      outline: AppColors.outline,
      outlineVariant: const Color(0xFFEDEEF0),
      // 去掉 M3 海拔叠加的橘色染色。
      surfaceTint: Colors.transparent,
    );

    return _fromScheme(scheme, scaffoldBackground: AppColors.background);
  }

  static ThemeData get dark {
    final scheme = ColorScheme.fromSeed(
      seedColor: AppColors.primary,
      brightness: Brightness.dark,
    ).copyWith(
      primary: AppColors.primary,
      onPrimary: AppColors.onPrimary,
      primaryContainer: AppColors.darkPrimaryContainer,
      onPrimaryContainer: AppColors.primaryLight,
      secondary: AppColors.accent,
      secondaryContainer: AppColors.darkAccentContainer,
      surface: AppColors.darkSurface,
      onSurface: AppColors.darkTextPrimary,
      onSurfaceVariant: AppColors.darkTextSecondary,
      surfaceContainerLowest: AppColors.darkBackground,
      surfaceContainerLow: const Color(0xFF16181C),
      surfaceContainer: const Color(0xFF1F2126),
      surfaceContainerHigh: const Color(0xFF26282E),
      surfaceContainerHighest: AppColors.darkSurfaceMuted,
      outline: AppColors.darkOutline,
      outlineVariant: const Color(0xFF2E3138),
      surfaceTint: Colors.transparent,
    );

    return _fromScheme(scheme, scaffoldBackground: AppColors.darkBackground);
  }

  static ThemeData _fromScheme(
    ColorScheme scheme, {
    required Color scaffoldBackground,
  }) {
    final isDark = scheme.brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      primaryColor: AppColors.primary,
      scaffoldBackgroundColor: scaffoldBackground,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        systemOverlayStyle:
            isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      ),
      cardTheme: const CardThemeData(
        surfaceTintColor: Colors.transparent,
      ),
      dialogTheme: DialogThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: scheme.surface,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: scheme.surface,
      ),
      popupMenuTheme: PopupMenuThemeData(
        surfaceTintColor: Colors.transparent,
        color: scheme.surface,
      ),
      navigationBarTheme: NavigationBarThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: scheme.surface,
      ),
      drawerTheme: DrawerThemeData(
        surfaceTintColor: Colors.transparent,
        backgroundColor: scheme.surface,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outline,
      ),
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
