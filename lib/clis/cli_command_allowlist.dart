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

/// Whether [allowlist] grants [namespace] or any descendant command.
bool cliNamespaceVisible(Set<String> allowlist, String namespace) {
  if (allowlist.isEmpty) return true;
  if (allowlist.contains(namespace)) return true;
  final prefix = '$namespace.';
  return allowlist.any((e) => e.startsWith(prefix));
}

/// Namespaces the LLM schema may advertise after intersecting per-agent
/// [enabledCliCommands] with an optional extra allowlist (group members).
///
/// Empty [enabledCliCommands] means no per-agent restriction. A non-null
/// [extraAllowlist] always restricts. Empty intersection falls back to
/// `help` so the model still has a callable namespace.
List<String> cliFilterNamespaces(
  Iterable<String> all, {
  Set<String> enabledCliCommands = const {},
  Set<String>? extraAllowlist,
}) {
  final filtered = all.where((ns) {
    if (enabledCliCommands.isNotEmpty &&
        !cliNamespaceVisible(enabledCliCommands, ns)) {
      return false;
    }
    if (extraAllowlist != null &&
        !cliNamespaceVisible(extraAllowlist, ns)) {
      return false;
    }
    return true;
  }).toList();
  if (filtered.isEmpty) return const ['help'];
  return filtered;
}

/// Restriction line for the shepaw tool description, or null if unrestricted.
String? cliSchemaRestrictionNote({
  Set<String> enabledCliCommands = const {},
  Set<String>? extraAllowlist,
}) {
  final parts = <String>[];
  if (enabledCliCommands.isNotEmpty) {
    final sorted = enabledCliCommands.toList()..sort();
    parts.add('per-agent: ${sorted.join(', ')}');
  }
  if (extraAllowlist != null) {
    final sorted = extraAllowlist.toList()..sort();
    parts.add('role: ${sorted.join(', ')}');
  }
  if (parts.isEmpty) return null;
  return 'Restricted CLI surface (${parts.join('; ')}). Do not call other namespaces.';
}
