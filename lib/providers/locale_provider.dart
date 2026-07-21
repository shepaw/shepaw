import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../l10n/app_localizations.dart';

class LocaleProvider extends ChangeNotifier {
  static const _prefKey = 'app_locale';

  Locale? _locale;

  /// Current locale. null means follow system.
  Locale? get locale => _locale;

  LocaleProvider() {
    _load();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    final code = prefs.getString(_prefKey);
    if (code != null) {
      _locale = Locale(code);
      notifyListeners();
    }
  }

  /// Set locale. Pass null to follow system.
  Future<void> setLocale(Locale? locale) async {
    if (_locale == locale) return;
    _locale = locale;
    final prefs = await SharedPreferences.getInstance();
    if (locale == null) {
      await prefs.remove(_prefKey);
    } else {
      await prefs.setString(_prefKey, locale.languageCode);
    }
    notifyListeners();
  }

  /// Display label for the current locale selection.
  String currentLabel(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    if (_locale == null) return _followSystemLabel(context);
    switch (_locale!.languageCode) {
      case 'en':
        return l10n.settings_languageEnglish;
      case 'zh':
        return l10n.settings_languageChinese;
      default:
        return _locale!.languageCode;
    }
  }

  String _followSystemLabel(BuildContext context) {
    return AppLocalizations.of(context).settings_languageFollowSystem;
  }
}
