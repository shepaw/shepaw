/// In-memory composer drafts keyed by conversation.
///
/// Survives leaving and re-entering a chat within the same app session.
/// Keys are preferably [channelId]; before a channel exists, callers may use
/// an `agent:<id>` fallback and later [migrate] to the channel key.
class ComposerDraftService {
  final Map<String, String> _drafts = {};

  /// Returns the saved draft for [key], or empty string if none.
  String getDraft(String key) {
    if (key.isEmpty) return '';
    return _drafts[key] ?? '';
  }

  /// Saves [text] for [key]. Empty / whitespace-only text removes the draft.
  void setDraft(String key, String text) {
    if (key.isEmpty) return;
    final trimmed = text.trimRight();
    if (trimmed.isEmpty) {
      _drafts.remove(key);
      return;
    }
    _drafts[key] = text;
  }

  /// Removes any draft for [key].
  void clearDraft(String key) {
    if (key.isEmpty) return;
    _drafts.remove(key);
  }

  /// Moves a draft from [fromKey] to [toKey] when the conversation identity
  /// resolves (e.g. agent fallback → channelId). Does nothing if [fromKey]
  /// has no draft. Prefer keeping [toKey]'s existing draft if both exist.
  void migrate({required String fromKey, required String toKey}) {
    if (fromKey.isEmpty || toKey.isEmpty || fromKey == toKey) return;
    final fromDraft = _drafts.remove(fromKey);
    if (fromDraft == null || fromDraft.isEmpty) return;
    final existing = _drafts[toKey];
    if (existing == null || existing.isEmpty) {
      _drafts[toKey] = fromDraft;
    }
  }

  /// Builds a stable draft key. Prefers [channelId], else `agent:<agentId>`.
  static String? keyFor({String? channelId, String? agentId}) {
    if (channelId != null && channelId.isNotEmpty) return channelId;
    if (agentId != null && agentId.isNotEmpty) return 'agent:$agentId';
    return null;
  }
}
