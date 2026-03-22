import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/os_tool_config_card.dart';

/// Full-page screen for configuring OS tools.
///
/// Receives the current set of enabled tools and returns the updated set
/// via [Navigator.pop].
class OsToolSelectScreen extends StatefulWidget {
  final Set<String> enabledTools;

  const OsToolSelectScreen({super.key, required this.enabledTools});

  @override
  State<OsToolSelectScreen> createState() => _OsToolSelectScreenState();
}

class _OsToolSelectScreenState extends State<OsToolSelectScreen> {
  late Set<String> _enabledTools;

  @override
  void initState() {
    super.initState();
    _enabledTools = Set<String>.from(widget.enabledTools);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.addAgent_configureTools),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _enabledTools),
            child: Text(l10n.common_save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: OsToolConfigCard(
          enabledTools: _enabledTools,
          onChanged: (tools) {
            setState(() {
              _enabledTools = tools;
            });
          },
        ),
      ),
    );
  }
}
