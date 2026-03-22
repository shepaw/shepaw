import 'package:flutter/material.dart';
import 'l10n/app_localizations.dart';
import 'screens/inference_log_screen.dart';
import 'screens/log_viewer_screen.dart';

/// Lightweight [MaterialApp] that runs inside a native sub-window.
///
/// Each sub-window gets its own Flutter engine. This widget provides the
/// minimal setup needed (theme + localization) and routes to the correct
/// screen based on [windowKey].
///
/// No providers, no ACP server, no database initialization.
class SubWindowApp extends StatelessWidget {
  /// The logical key that determines which screen to show
  /// (e.g. 'inference_log', 'system_log').
  final String windowKey;

  /// The title shown in the app bar.
  final String title;

  /// The locale to use (e.g. 'zh', 'en'). If null, follows system.
  final String? localeCode;

  const SubWindowApp({
    Key? key,
    required this.windowKey,
    required this.title,
    this.localeCode,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final locale = localeCode != null ? Locale(localeCode!) : null;

    return MaterialApp(
      title: title,
      debugShowCheckedModeBanner: false,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      localeResolutionCallback: (deviceLocale, supportedLocales) {
        for (final supportedLocale in supportedLocales) {
          if (supportedLocale.languageCode == deviceLocale?.languageCode) {
            return supportedLocale;
          }
        }
        return const Locale('zh');
      },
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: Colors.blue,
          brightness: Brightness.light,
        ),
      ),
      home: _buildScreen(),
    );
  }

  Widget _buildScreen() {
    switch (windowKey) {
      case 'inference_log':
        return const InferenceLogScreen(embedded: false);
      case 'system_log':
        return const LogViewerScreen(embedded: false);
      default:
        return Scaffold(
          appBar: AppBar(title: Text(title)),
          body: const Center(child: Text('Unknown window type')),
        );
    }
  }
}
