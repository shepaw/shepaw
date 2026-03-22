import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  final bool showTerms;

  const PrivacyPolicyScreen({Key? key, this.showTerms = false})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(showTerms ? l10n.terms_title : l10n.privacy_title),
        centerTitle: true,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          showTerms ? l10n.terms_content : l10n.privacy_content,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
      ),
    );
  }
}
