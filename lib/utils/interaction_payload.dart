/// Parsing helpers for interactive UI payloads (`single_select`,
/// `multi_select`, `form`) carried in message metadata.
///
/// The same card reaches the app from several producers — local agents, the
/// ACP bridge, and the Hub's `interaction.pending` events — and they do not
/// agree on key names: local tools emit `{"id": ..., "label": ...}` while the
/// Hub forwards `{"value": ..., "label": ...}`. Reading a single key leaves
/// every option with an empty id, which makes one tap look like "select all"
/// and sends an empty id back to the agent. Resolve identity through
/// [interactionOptions] instead of reading `id` directly.
library;

/// One selectable entry, with the identity the app echoes back to the agent.
class InteractionOption {
  const InteractionOption({required this.id, required this.label});

  /// Value reported to the agent when this option is chosen.
  final String id;

  /// Text shown to the user.
  final String label;
}

/// Keys that can carry an option's identity, in priority order.
const List<String> _idKeys = ['id', 'value', 'name', 'key'];

/// Keys that can carry an option's display text, in priority order.
const List<String> _labelKeys = ['label', 'text', 'title', 'name'];

/// Normalises a payload's `options` list into [InteractionOption]s.
///
/// Tolerates the shapes seen in the wild: `{id, label}`, `{value, label}`,
/// `{name}`, and bare strings. Ids are guaranteed to be non-empty and unique
/// within the returned list, since both properties are what make a radio list
/// behave as a radio list.
List<InteractionOption> interactionOptions(dynamic raw) {
  if (raw is! List) return const [];

  final options = <InteractionOption>[];
  final usedIds = <String>{};

  for (var i = 0; i < raw.length; i++) {
    final entry = raw[i];
    if (entry is String) {
      options.add(InteractionOption(id: _uniqueId(entry, i, usedIds), label: entry));
      continue;
    }
    if (entry is! Map) continue;

    final map = entry.map((key, value) => MapEntry(key.toString(), value));
    final label = _firstString(map, _labelKeys) ?? '';
    final id = _firstString(map, _idKeys) ??
        (label.isNotEmpty ? label : 'option_$i');
    options.add(InteractionOption(id: _uniqueId(id, i, usedIds), label: label));
  }

  return options;
}

/// The `select_id` an option list belongs to.
///
/// Falls back to the ids Hub interactions carry (`confirmation_id` /
/// `interaction_id`) so responses can still be matched to their card.
String interactionSelectId(Map<String, dynamic> data) {
  return _firstString(data, const [
        'select_id',
        'confirmation_id',
        'interaction_id',
        'form_id',
        'id',
      ]) ??
      '';
}

String _uniqueId(String candidate, int index, Set<String> used) {
  var id = candidate;
  if (id.isEmpty) id = 'option_$index';
  if (used.add(id)) return id;
  // Duplicate identity: keep the first occurrence untouched (it is the one the
  // agent knows about) and disambiguate the rest so taps stay independent.
  var suffix = index;
  while (!used.add('$id#$suffix')) {
    suffix++;
  }
  return '$id#$suffix';
}

String? _firstString(Map<String, dynamic> map, List<String> keys) {
  for (final key in keys) {
    final value = map[key];
    if (value is String && value.trim().isNotEmpty) return value;
    if (value is num) return value.toString();
  }
  return null;
}
