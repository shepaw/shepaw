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
