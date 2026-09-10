import 'dart:convert';

import '../clis/cli_command_allowlist.dart';
import '../clis/shepaw/os/os_executor.dart' as os_exec;
import '../clis/shepaw/os/os_tool_registry.dart';
import '../clis/shepaw/shepaw_cli.dart';
import '../models/peer_boundary_config.dart';
import 'location_access_policy.dart';

/// Shared pre-execute checks for shepaw CLI.
///
/// Local LLM tool calls, group turns, and (later) ACP `hub.cli.execute`
/// all go through here. Identity is She vs non-She + per-agent allowlist;
/// deployment (local/remote) is not a permission axis.
class CliExecutionGate {
  CliExecutionGate._();
  static final instance = CliExecutionGate._();

  /// `namespace` or `namespace.subcommand`.
  static String commandId(String namespace, String subcommand) =>
      cliCommandId(namespace, subcommand);

  /// [allowlist] entry may be a full command (`store.write`) or a namespace
  /// (`store` / `help`) that allows every descendant.
  static bool isCommandAllowed(Set<String> allowlist, String commandId) =>
      cliCommandAllowed(allowlist, commandId);

  /// Run permission / boundary / OS confirmation, then [ShepawCLI.execute].
  Future<String> execute({
    required Map<String, dynamic> args,
    required String agentId,
    String? channelId,
    String? runtimeOwnerId,
    bool isUiOperation = false,
    Set<String> enabledCliCommands = const {},
    Set<String>? extraAllowlist,
    PeerBoundaryConfig peerBoundary = PeerBoundaryConfig.open,
    Future<bool> Function(
      String toolName,
      Map<String, dynamic> flags,
      os_exec.RiskLevel risk,
    )? onOsConfirmation,
  }) async {
    final namespace = (args['namespace'] as String?)?.trim() ?? '';
    final subcommand = (args['subcommand'] as String?)?.trim() ?? '';
    final id = commandId(namespace, subcommand);

    if (!isUiOperation &&
        enabledCliCommands.isNotEmpty &&
        !isCommandAllowed(enabledCliCommands, id)) {
      return jsonEncode({
        'error':
            'CLI command "$id" is not allowed for this agent. Enabled commands: ${enabledCliCommands.join(", ")}',
        'command': id,
      });
    }

    if (!isUiOperation &&
        extraAllowlist != null &&
        !isCommandAllowed(extraAllowlist, id)) {
      return jsonEncode({
        'error': 'Command not allowed: $id',
        'command': id,
        'allowed_commands': extraAllowlist.toList()..sort(),
      });
    }

    if (!isUiOperation &&
        peerBoundary.blocksCli(
          namespace: namespace,
          subcommand: subcommand,
        )) {
      return jsonEncode({
        'error':
            'CLI command "$id" is blocked in peer external-serving mode.',
        'command': id,
        'peer_boundary': true,
      });
    }

    if (!isUiOperation && namespace == 'os' && subcommand.isNotEmpty) {
      final osDenied = await _denyOsIfUnconfirmed(
        agentId: agentId,
        args: args,
        commandId: id,
        onOsConfirmation: onOsConfirmation,
      );
      if (osDenied != null) return osDenied;
    }

    return ShepawCLI.instance.execute(
      args,
      agentId: agentId,
      isUiOperation: isUiOperation,
      channelId: channelId,
      runtimeOwnerId: runtimeOwnerId,
      cliAllowlist: extraAllowlist,
    );
  }

  Future<String?> _denyOsIfUnconfirmed({
    required String agentId,
    required Map<String, dynamic> args,
    required String commandId,
    Future<bool> Function(
      String toolName,
      Map<String, dynamic> flags,
      os_exec.RiskLevel risk,
    )? onOsConfirmation,
  }) async {
    final flagsRaw = args['flags'];
    final flags = <String, dynamic>{};
    if (flagsRaw is Map) {
      flags.addAll(Map<String, dynamic>.from(flagsRaw));
    }

    final toolName = OsToolRegistry.instance.resolveToolName(commandId);
    final risk = os_exec.classifyRisk(toolName, flags);
    if (risk == os_exec.RiskLevel.safe) return null;

    if (await LocationAccessPolicy.shouldSkipOsConfirmationFor(
      agentId: agentId,
      toolName: toolName,
    )) {
      return null;
    }

    final approved = onOsConfirmation == null
        ? false
        : await onOsConfirmation(toolName, flags, risk);
    if (approved) return null;

    return jsonEncode({
      'error':
          'OS tool "$commandId" was denied by the user (risk: ${risk.name}).',
      'tool': toolName,
      'risk': risk.name,
    });
  }
}

/// Default extra allowlist for non-admin group members (namespace-level).
const kGroupMemberCliAllowlist = {'store', 'help'};
