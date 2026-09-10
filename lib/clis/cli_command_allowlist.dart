/// Command-id helpers shared by [ShepawCLI] and [CliExecutionGate].
library;

/// `namespace` or `namespace.subcommand`.
String cliCommandId(String namespace, String subcommand) {
  final ns = namespace.trim();
  final sub = subcommand.trim();
  if (sub.isEmpty) return ns;
  return '$ns.$sub';
}

/// [allowlist] entry may be a full command (`store.write`) or a namespace
/// (`store` / `help`) that allows every descendant.
bool cliCommandAllowed(Set<String> allowlist, String commandId) {
  if (allowlist.contains(commandId)) return true;
  final parts = commandId.split('.');
  for (var i = 1; i < parts.length; i++) {
    if (allowlist.contains(parts.take(i).join('.'))) return true;
  }
  return false;
}

/// Read-only / discovery commands that skip `cliRequireApproval`.
///
/// `os.*` non-safe still goes through OS confirmation even when listed here.
const kCliApprovalExemptCommands = {
  'help',
  'store.read',
  'store.list',
  'store.search',
};

/// Whether [commandId] is exempt from the per-agent approval switch.
bool cliCommandApprovalExempt(String commandId) {
  if (commandId.isEmpty) return true;
  if (kCliApprovalExemptCommands.contains(commandId)) return true;
  final parts = commandId.split('.');
  if (parts.first == 'help') return true;
  return false;
}
