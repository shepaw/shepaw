import 'package:flutter/foundation.dart';

/// In-memory composer drafts keyed by conversation.
///
/// Survives leaving and re-entering a chat within the same app session.
/// Primary keys are preferably [channelId]; list tiles also look up
/// [agentListKey] / [groupListKey] aliases written alongside.
///
/// Call [publish] after leaving a chat (or clearing a draft) so the
/// conversation list can refresh WeChat-style `[Draft]` previews and sorting.
class ComposerDraftService extends ChangeNotifier {
  final Map<String, String> _drafts = {};
  final Map<String, DateTime> _updatedAt = {};

  /// Returns the saved draft for [key], or empty string if none.
  String getDraft(String key) {
    if (key.isEmpty) return '';
    return _drafts[key] ?? '';
  }

  /// When the draft for [key] was last written, if any.
  DateTime? draftUpdatedAt(String key) {
    if (key.isEmpty) return null;
    return _updatedAt[key];
  }

  bool hasDraft(String key) => getDraft(key).isNotEmpty;

  /// Saves [text] for [key] and optional list aliases.
  ///
  /// Empty / whitespace-only text removes the draft(s).
  /// Does not notify listeners unless [notify] is true — keystroke saves stay
  /// silent; call [publish] when leaving the chat so the list updates once.
  void setDraft(
    String key,
    String text, {
    String? agentId,
    String? groupFamilyId,
    bool notify = false,
  }) {
    final keys = _keysFor(
      key: key,
      agentId: agentId,
      groupFamilyId: groupFamilyId,
    );
    if (keys.isEmpty) return;

    final trimmed = text.trimRight();
    if (trimmed.isEmpty) {
      _removeKeys(keys);
      if (notify) notifyListeners();
      return;
    }

    final now = DateTime.now();
    for (final k in keys) {
      _drafts[k] = text;
      _updatedAt[k] = now;
    }
    if (notify) notifyListeners();
  }

  /// Removes drafts for [key] and optional list aliases.
  void clearDraft(
    String key, {
    String? agentId,
    String? groupFamilyId,
    bool notify = true,
  }) {
    final keys = _keysFor(
      key: key,
      agentId: agentId,
      groupFamilyId: groupFamilyId,
    );
    if (keys.isEmpty) return;
    _removeKeys(keys);
    if (notify) notifyListeners();
  }

  /// Moves a draft from [fromKey] to [toKey] when the conversation identity
  /// resolves. Keeps [toKey]'s existing draft if both exist. Does not notify.
  void migrate({required String fromKey, required String toKey}) {
    if (fromKey.isEmpty || toKey.isEmpty || fromKey == toKey) return;
    final fromDraft = _drafts.remove(fromKey);
    final fromAt = _updatedAt.remove(fromKey);
    if (fromDraft == null || fromDraft.isEmpty) return;
    final existing = _drafts[toKey];
    if (existing == null || existing.isEmpty) {
      _drafts[toKey] = fromDraft;
      if (fromAt != null) _updatedAt[toKey] = fromAt;
    }
  }

  /// Notifies listeners (conversation list) that drafts changed.
  void publish() => notifyListeners();

  /// Builds a stable draft key. Prefers [channelId], else `agent:<agentId>`.
  static String? keyFor({String? channelId, String? agentId}) {
    if (channelId != null && channelId.isNotEmpty) return channelId;
    if (agentId != null && agentId.isNotEmpty) return agentListKey(agentId);
    return null;
  }

  static String agentListKey(String agentId) => 'agent:$agentId';

  static String groupListKey(String groupFamilyId) => 'group:$groupFamilyId';

  Set<String> _keysFor({
    required String key,
    String? agentId,
    String? groupFamilyId,
  }) {
    return {
      if (key.isNotEmpty) key,
      if (agentId != null && agentId.isNotEmpty) agentListKey(agentId),
      if (groupFamilyId != null && groupFamilyId.isNotEmpty)
        groupListKey(groupFamilyId),
    };
  }

  void _removeKeys(Set<String> keys) {
    for (final k in keys) {
      _drafts.remove(k);
      _updatedAt.remove(k);
    }
  }
}
