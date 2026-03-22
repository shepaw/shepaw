import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../l10n/app_localizations.dart';
import '../providers/locale_provider.dart';

class LanguageSettingsScreen extends StatelessWidget {
  const LanguageSettingsScreen({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final localeProvider = context.watch<LocaleProvider>();
    final currentLocale = localeProvider.locale;

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.settings_languageDialogTitle),
        centerTitle: true,
      ),
      body: ListView(
        children: [
          const SizedBox(height: 8),
          _LanguageOption(
            label: l10n.settings_languageFollowSystem,
            selected: currentLocale == null,
            onTap: () => localeProvider.setLocale(null),
          ),
          const Divider(height: 1),
          _LanguageOption(
            label: l10n.settings_languageEnglish,
            selected: currentLocale?.languageCode == 'en',
            onTap: () => localeProvider.setLocale(const Locale('en')),
          ),
          const Divider(height: 1),
          _LanguageOption(
            label: l10n.settings_languageChinese,
            selected: currentLocale?.languageCode == 'zh',
            onTap: () => localeProvider.setLocale(const Locale('zh')),
          ),
        ],
      ),
    );
  }
}

class _LanguageOption extends StatelessWidget {
  const _LanguageOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: Text(label),
      trailing: selected
          ? Icon(Icons.check, color: Theme.of(context).colorScheme.primary)
          : null,
      onTap: onTap,
    );
  }
}
