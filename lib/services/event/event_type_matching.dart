/// Returns true when [type] matches [pattern].
///
/// Supports:
/// - exact match: `peer.pairing.inbound`
/// - suffix `.*`: prefix match (`peer.pairing.*` → `peer.pairing.inbound`)
/// - single-segment `*`: same depth wildcard (`peer.*.inbound` — not used in P0)
bool typeMatchesPattern(String pattern, String type) {
  if (pattern == type) return true;

  if (pattern.endsWith('.*')) {
    final prefix = pattern.substring(0, pattern.length - 2);
    return type == prefix || type.startsWith('$prefix.');
  }

  final pParts = pattern.split('.');
  final tParts = type.split('.');
  if (pParts.length != tParts.length) return false;

  for (var i = 0; i < pParts.length; i++) {
    if (pParts[i] == '*') continue;
    if (pParts[i] != tParts[i]) return false;
  }
  return true;
}

bool typeMatchesAny(Iterable<String> patterns, String type) {
  for (final pattern in patterns) {
    if (typeMatchesPattern(pattern, type)) return true;
  }
  return false;
}
