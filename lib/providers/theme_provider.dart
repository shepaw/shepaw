import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';

/// Persists the user's appearance preference: system / light / dark.
class ThemeProvider extends ChangeNotifier {
  static const _prefKey = 'app_theme_mode';

  ThemeMode _themeMode = ThemeMode.system;

  ThemeMode get themeMode => _themeMode;

  /// Wire format for native sub-windows: `system`, `light`, or `dark`.
  String get encodedMode => _encode(_themeMode);

  ThemeProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefKey);
    final parsed = _parse(stored);
    if (parsed != _themeMode) {
      _themeMode = parsed;
      notifyListeners();
    }
  }

  Future<void> setThemeMode(ThemeMode mode) async {
    if (_themeMode == mode) return;
    _themeMode = mode;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, _encode(mode));
    notifyListeners();
  }

  String currentLabel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    switch (_themeMode) {
      case ThemeMode.light:
        return l10n.settings_appearanceLight;
      case ThemeMode.dark:
        return l10n.settings_appearanceDark;
      case ThemeMode.system:
        return l10n.settings_languageFollowSystem;
    }
  }

  static String _encode(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.light:
        return 'light';
      case ThemeMode.dark:
        return 'dark';
      case ThemeMode.system:
        return 'system';
    }
  }

  static ThemeMode parseMode(String? value) => _parse(value);

  static ThemeMode _parse(String? value) {
    switch (value) {
      case 'light':
        return ThemeMode.light;
      case 'dark':
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }
}
