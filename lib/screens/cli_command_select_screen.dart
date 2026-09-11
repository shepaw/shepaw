import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../clis/cli_command_allowlist.dart';
import '../services/cli_namespace_registry.dart';
import '../widgets/cli_command_config_card.dart';
import '../widgets/form_bottom_bar.dart';

/// Result of [CliCommandSelectScreen].
///
/// The screen can express three distinct outcomes, but `Navigator.push` already
/// spends `null` on "the user went back without saving". If "unrestricted"
/// also popped `null`, cancelling the picker would silently widen a restricted
/// agent to unrestricted — so the saved outcome is always wrapped.
class CliCommandSelection {
  /// `null` = unrestricted (drop the metadata key);
  /// `{}` = block every CLI command;
  /// non-empty = explicit allowlist.
  final Set<String>? commands;

  const CliCommandSelection(this.commands);
}

/// Full-page screen for configuring CLI commands for an agent.
///
/// Receives the current allowlist and returns the updated one via
/// [Navigator.pop] as a [CliCommandSelection].
///
/// This is parallel to [OsToolSelectScreen] but for CLI commands.
class CliCommandSelectScreen extends StatefulWidget {
  /// Current per-agent allowlist: `null` = unrestricted, `{}` = block all.
  final Set<String>? enabledCommands;

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
    // Unrestricted (`null`) shows every switch ON: that is what "the agent may
    // run anything" looks like. Block-all (`{}`) is the opposite and must stay
    // visually distinct, otherwise the user cannot tell the two states apart.
    _enabledCommands = widget.enabledCommands == null
        ? Set<String>.from(CliNamespaceRegistry.instance.allCommandIds)
        : Set<String>.from(widget.enabledCommands!);
  }

  void _save() {
    final result = cliSelectionToAllowlist(
      selected: _enabledCommands,
      allCommandIds: CliNamespaceRegistry.instance.allCommandIds.toSet(),
    );
    Navigator.pop(context, CliCommandSelection(result));
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
