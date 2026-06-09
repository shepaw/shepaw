import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/cli_namespace_registry.dart';
import '../widgets/cli_command_config_card.dart';
import '../widgets/form_bottom_bar.dart';

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
    // When enabledCommands is empty, it means "all allowed" in storage.
    // Pre-populate with all commands so the UI shows all switches ON.
    if (widget.enabledCommands.isEmpty) {
      _enabledCommands = Set<String>.from(
        CliNamespaceRegistry.instance.allCommandIds,
      );
    } else {
      _enabledCommands = Set<String>.from(widget.enabledCommands);
    }
  }

  void _save() {
    final allIds = CliNamespaceRegistry.instance.allCommandIds;
    final result = _enabledCommands.length >= allIds.length
        ? <String>{}
        : _enabledCommands;
    Navigator.pop(context, result);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Configure CLI Commands'),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
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
          ),
          FormBottomBar(
            child: FormPrimaryButton(
              onPressed: _save,
              icon: Icons.save,
              label: l10n.common_save,
            ),
          ),
        ],
      ),
    );
  }
}
