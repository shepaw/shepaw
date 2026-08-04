import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory composer drafts keyed by conversation, persisted to disk so drafts
/// survive leaving a chat or restarting the app within the same install.
///
/// Primary keys are preferably [channelId]; list tiles also look up
/// [agentListKey] / [groupListKey] aliases written alongside.
///
/// Call [publish] after leaving a chat (or clearing a draft) so the
/// conversation list can refresh WeChat-style `[Draft]` previews and sorting.
class ComposerDraftService extends ChangeNotifier {
  static const _storageKey = 'composer_drafts_v1';

  final Map<String, String> _drafts = {};
  final Map<String, DateTime> _updatedAt = {};
  bool _restoredFromDisk = false;

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

  /// Loads drafts saved in a previous app session.
  Future<void> restoreFromDisk() async {
    if (_restoredFromDisk) return;
    _restoredFromDisk = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_storageKey);
      if (raw == null || raw.isEmpty) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map) return;

      final draftsRaw = decoded['drafts'];
      if (draftsRaw is Map) {
        for (final entry in draftsRaw.entries) {
          final key = entry.key?.toString();
          final text = entry.value?.toString();
          if (key == null || key.isEmpty || text == null || text.isEmpty) {
            continue;
          }
          _drafts[key] = text;
        }
      }

      final timesRaw = decoded['updatedAt'];
      if (timesRaw is Map) {
        for (final entry in timesRaw.entries) {
          final key = entry.key?.toString();
          final rawTime = entry.value?.toString();
          if (key == null || key.isEmpty || rawTime == null) continue;
          final parsed = DateTime.tryParse(rawTime);
          if (parsed != null) {
            _updatedAt[key] = parsed;
          }
        }
      }
    } catch (_) {
      // Corrupt snapshot — start fresh in memory.
    }
  }

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
      _persistToDisk();
      return;
    }

    var changed = false;
    final now = DateTime.now();
    for (final k in keys) {
      if (_drafts[k] == text) continue;
      _drafts[k] = text;
      _updatedAt[k] = now;
      changed = true;
    }
    if (!changed) return;
    if (notify) notifyListeners();
    _persistToDisk();
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
    _persistToDisk();
  }

  /// Copies a draft from [fromKey] to [toKey] when the conversation identity
  /// resolves. Keeps [toKey]'s existing draft if both exist.
  ///
  /// List aliases (`agent:` / `group:`) are preserved so the conversation
  /// list can keep finding the draft after channelId resolves.
  void migrate({required String fromKey, required String toKey}) {
    if (fromKey.isEmpty || toKey.isEmpty || fromKey == toKey) return;
    final fromDraft = _drafts[fromKey];
    final fromAt = _updatedAt[fromKey];
    if (fromDraft == null || fromDraft.isEmpty) return;

    final existing = _drafts[toKey];
    if (existing == null || existing.isEmpty) {
      _drafts[toKey] = fromDraft;
      if (fromAt != null) _updatedAt[toKey] = fromAt;
    }

    // Drop only non-list keys (e.g. a temporary key). Keep agent:/group: aliases.
    if (!_isListAliasKey(fromKey)) {
      _drafts.remove(fromKey);
      _updatedAt.remove(fromKey);
    }
    _persistToDisk();
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

  static bool _isListAliasKey(String key) =>
      key.startsWith('agent:') || key.startsWith('group:');

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

  void _persistToDisk() {
    () async {
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          _storageKey,
          jsonEncode({
            'drafts': _drafts,
            'updatedAt': {
              for (final e in _updatedAt.entries)
                e.key: e.value.toIso8601String(),
            },
          }),
        );
      } catch (_) {
        // Best-effort — in-memory draft still works for this session.
      }
    }();
  }
}
