import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:shepaw/providers/theme_provider.dart';
import 'package:shepaw/theme/app_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ThemeProvider', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('defaults to system and persists dark', () async {
      final provider = ThemeProvider();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(provider.themeMode, ThemeMode.system);
      expect(provider.encodedMode, 'system');

      await provider.setThemeMode(ThemeMode.dark);
      expect(provider.themeMode, ThemeMode.dark);
      expect(provider.encodedMode, 'dark');

      final reloaded = ThemeProvider();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(reloaded.themeMode, ThemeMode.dark);
    });

    test('parseMode maps stored strings', () {
      expect(ThemeProvider.parseMode(null), ThemeMode.system);
      expect(ThemeProvider.parseMode('system'), ThemeMode.system);
      expect(ThemeProvider.parseMode('light'), ThemeMode.light);
      expect(ThemeProvider.parseMode('dark'), ThemeMode.dark);
      expect(ThemeProvider.parseMode('unknown'), ThemeMode.system);
    });
  });

  group('AppTheme', () {
    test('light and dark expose matching brand primary', () {
      expect(AppTheme.light.brightness, Brightness.light);
      expect(AppTheme.dark.brightness, Brightness.dark);
      expect(AppTheme.light.colorScheme.primary, AppColors.primary);
      expect(AppTheme.dark.colorScheme.primary, AppColors.primary);
      expect(AppTheme.dark.scaffoldBackgroundColor, AppColors.darkBackground);
    });
  });
}
