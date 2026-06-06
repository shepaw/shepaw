import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/window_title_service.dart';

/// Keeps the native desktop window title aligned with [AppLocalizations.appTitle].
class WindowTitleSync extends StatefulWidget {
  final Widget child;

  const WindowTitleSync({super.key, required this.child});

  @override
  State<WindowTitleSync> createState() => _WindowTitleSyncState();
}

class _WindowTitleSyncState extends State<WindowTitleSync> {
  Locale? _lastLocale;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleSync();
  }

  void _scheduleSync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final locale = Localizations.localeOf(context);
      if (_lastLocale == locale) return;
      _lastLocale = locale;
      final title = AppLocalizations.of(context).appTitle;
      WindowTitleService.setTitle(title);
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
