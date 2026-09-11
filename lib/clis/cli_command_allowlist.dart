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

/// Prefix-aware intersection of two allowlists.
///
/// Plain set intersection is wrong here: entries allow a *subtree*, so
/// `{'store'} ∩ {'store.read'}` must be `{'store.read'}`, not `{}`.
///
/// For `a ∈ A`, `b ∈ B`: if one is a dot-boundary prefix of the other (or they
/// are equal), the longer one is the tighter grant and is contributed;
/// incomparable pairs contribute nothing. This is exact — an entry `x` allows
/// `c` iff `x` is a dot-boundary prefix of `c`, so when `a` and `b` are both
/// prefixes of `c` they are comparable and their longer form allows exactly
/// the same `c`s the pair did together.
///
/// `null` on either side means "that axis imposes no restriction", so the other
/// side passes through unchanged. An empty result means "nothing is allowed".
Set<String>? cliIntersectAllowlists(Set<String>? a, Set<String>? b) {
  if (a == null) return b;
  if (b == null) return a;
  final result = <String>{};
  for (final x in a) {
    for (final y in b) {
      if (x == y) {
        result.add(x);
      } else if (y.startsWith('$x.')) {
        result.add(y);
      } else if (x.startsWith('$y.')) {
        result.add(x);
      }
    }
  }
  return result;
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
///
/// An **empty** [allowlist] grants nothing. "Unrestricted" is expressed by not
/// calling this at all (a null allowlist on the caller's side), never by an
/// empty set — otherwise `{}` means both "no restriction" and "nothing
/// allowed" depending on which primitive reads it.
bool cliNamespaceVisible(Set<String> allowlist, String namespace) {
  if (allowlist.contains(namespace)) return true;
  final prefix = '$namespace.';
  return allowlist.any((e) => e.startsWith(prefix));
}

/// Namespaces the LLM schema may advertise after intersecting the per-agent
/// allowlist with an optional extra allowlist (group members).
///
/// `null` [enabledCliCommands] means no per-agent restriction; `{}` means every
/// command is blocked. Same for [extraAllowlist]. Empty intersection falls back
/// to `help` so the model still has a callable namespace.
List<String> cliFilterNamespaces(
  Iterable<String> all, {
  Set<String>? enabledCliCommands,
  Set<String>? extraAllowlist,
}) {
  final filtered = all.where((ns) {
    if (enabledCliCommands != null &&
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
  Set<String>? enabledCliCommands,
  Set<String>? extraAllowlist,
}) {
  final parts = <String>[];
  if (enabledCliCommands != null) {
    final sorted = enabledCliCommands.toList()..sort();
    parts.add('per-agent: ${sorted.isEmpty ? '(none)' : sorted.join(', ')}');
  }
  if (extraAllowlist != null) {
    final sorted = extraAllowlist.toList()..sort();
    parts.add('role: ${sorted.join(', ')}');
  }
  if (parts.isEmpty) return null;
  return 'Restricted CLI surface (${parts.join('; ')}). '
      'Do not call other namespaces or subcommands.';
}

/// Namespaces commonly invoked with no subcommand (schema may still enum
/// sibling command ids like `store.write`).
const kCliBareNamespaces = {'help'};

/// Allowed `subcommand` strings for the shepaw tool schema.
///
/// Returns null when unrestricted, or when a visible namespace is granted
/// wholesale (e.g. allowlist entry `store`) so every descendant stays valid.
/// Specific ids (`store.write`) become an enum so the model cannot see
/// `store.read` / `store.list` just because `store` is in the namespace list.
List<String>? cliFilterSubcommands({
  required Iterable<String> namespaces,
  Set<String>? enabledCliCommands,
  Set<String>? extraAllowlist,
}) {
  final visible = namespaces.toSet();
  if (visible.isEmpty) return null;

  bool fullyGranted(String ns) {
    final byEnabled =
        enabledCliCommands == null || enabledCliCommands.contains(ns);
    final byExtra = extraAllowlist == null || extraAllowlist.contains(ns);
    return byEnabled && byExtra;
  }

  for (final ns in visible) {
    if (fullyGranted(ns) && !kCliBareNamespaces.contains(ns)) {
      return null;
    }
  }

  final subs = <String>{};
  void collect(Set<String> allow) {
    for (final e in allow) {
      final dot = e.indexOf('.');
      if (dot <= 0) continue;
      final ns = e.substring(0, dot);
      if (visible.contains(ns)) {
        subs.add(e.substring(dot + 1));
      }
    }
  }

  if (enabledCliCommands != null) collect(enabledCliCommands);
  if (extraAllowlist != null) collect(extraAllowlist);
  if (subs.isEmpty) return null;
  return subs.toList()..sort();
}

/// Map a command picker's [selected] set to the persisted three-state value.
///
/// The persisted metadata key has three meanings and they must stay distinct:
/// key absent (`null`, unrestricted), `[]` (block everything), non-empty
/// (explicit allowlist). "Everything selected" therefore maps back to `null`
/// so the picker round-trips an unrestricted agent without pinning it to
/// today's command list.
Set<String>? cliSelectionToAllowlist({
  required Set<String> selected,
  required Set<String> allCommandIds,
}) {
  if (selected.isEmpty) return const <String>{};
  if (allCommandIds.isNotEmpty && selected.length >= allCommandIds.length) {
    return null;
  }
  return selected;
}
