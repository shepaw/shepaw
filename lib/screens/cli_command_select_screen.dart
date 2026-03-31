import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../widgets/cli_command_config_card.dart';

/// Full-page screen for configuring CLI commands for an agent.
///
/// Receives the current set of enabled commands and returns the updated set
/// via [Navigator.pop].
///
/// This is parallel to [OsToolSelectScreen] but for CLI commands.
class CliCommandSelectScreen extends StatefulWidget {
  final Set<String> enabledCommands;

  const CliCommandSelectScreen({
    super.key,
    required this.enabledCommands,
  });

  @override
  State<CliCommandSelectScreen> createState() => _CliCommandSelectScreenState();
}

class _CliCommandSelectScreenState extends State<CliCommandSelectScreen> {
  late Set<String> _enabledCommands;

  @override
  void initState() {
    super.initState();
    _enabledCommands = Set<String>.from(widget.enabledCommands);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configure CLI Commands'),
        centerTitle: true,
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _enabledCommands),
            child: Text(l10n.common_save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: CliCommandConfigCard(
          enabledCommands: _enabledCommands,
          onChanged: (commands) {
            setState(() {
              _enabledCommands = commands;
            });
          },
        ),
      ),
    );
  }
}
