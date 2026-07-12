import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists which group-chat message bodies the user has collapsed.
///
/// Keys are scoped by [channelId] so each conversation keeps its own set.
class MessageCollapsePreference extends ChangeNotifier {
  static const _keyPrefix = 'chat_collapsed_msg_ids_';

  String? _channelId;
  Set<String> _collapsedIds = {};
  bool _loaded = false;

  String? get channelId => _channelId;
  Set<String> get collapsedIds => _collapsedIds;
  bool get isLoaded => _loaded;

  bool isCollapsed(String messageId) => _collapsedIds.contains(messageId);

  /// Load (or switch to) collapsed ids for [channelId].
  Future<void> loadForChannel(String channelId) async {
    if (_channelId == channelId && _loaded) return;
    _channelId = channelId;
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    final ids = prefs.getStringList('$_keyPrefix$channelId') ?? const [];
    _collapsedIds = ids.toSet();
    _loaded = true;
    notifyListeners();
  }

  Future<void> toggle(String messageId) async {
    if (_collapsedIds.contains(messageId)) {
      _collapsedIds.remove(messageId);
    } else {
      _collapsedIds.add(messageId);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> setCollapsed(String messageId, bool collapsed) async {
    final currently = _collapsedIds.contains(messageId);
    if (currently == collapsed) return;
    if (collapsed) {
      _collapsedIds.add(messageId);
    } else {
      _collapsedIds.remove(messageId);
    }
    notifyListeners();
    await _persist();
  }

  /// Drop ids that no longer exist in the conversation to bound prefs growth.
  Future<void> pruneTo(Iterable<String> existingIds) async {
    final existing = existingIds is Set<String>
        ? existingIds
        : existingIds.toSet();
    final before = _collapsedIds.length;
    _collapsedIds.removeWhere((id) => !existing.contains(id));
    if (_collapsedIds.length == before) return;
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final channelId = _channelId;
    if (channelId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      '$_keyPrefix$channelId',
      _collapsedIds.toList(growable: false),
    );
  }
}
