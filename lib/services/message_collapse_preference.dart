import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Persists user overrides for group-chat message body collapse.
///
/// Default (no override): every message is collapsed except
/// [defaultExpandedMessageId]. Keys are scoped by [channelId].
class MessageCollapsePreference extends ChangeNotifier {
  static const _collapsedKeyPrefix = 'chat_collapsed_msg_ids_';
  static const _expandedKeyPrefix = 'chat_expanded_msg_ids_';

  String? _channelId;
  /// User explicitly collapsed (overrides default expanded latest).
  Set<String> _userCollapsedIds = {};
  /// User explicitly expanded (overrides default collapsed history).
  Set<String> _userExpandedIds = {};
  bool _loaded = false;

  String? get channelId => _channelId;
  Set<String> get collapsedIds => _userCollapsedIds;
  Set<String> get expandedIds => _userExpandedIds;
  bool get isLoaded => _loaded;

  /// Whether [messageId] should render in collapsed list-tile mode.
  ///
  /// [defaultExpandedMessageId] is the chronologically last collapsible
  /// message in the channel (see [MessageUtils.defaultExpandedGroupMessageId]).
  bool isCollapsed(
    String messageId, {
    String? defaultExpandedMessageId,
  }) {
    if (_userExpandedIds.contains(messageId)) return false;
    if (_userCollapsedIds.contains(messageId)) return true;
    if (defaultExpandedMessageId == null) return true;
    return messageId != defaultExpandedMessageId;
  }

  /// Load (or switch to) override sets for [channelId].
  Future<void> loadForChannel(String channelId) async {
    if (_channelId == channelId && _loaded) return;
    _channelId = channelId;
    _loaded = false;
    final prefs = await SharedPreferences.getInstance();
    final collapsed =
        prefs.getStringList('$_collapsedKeyPrefix$channelId') ?? const [];
    final expanded =
        prefs.getStringList('$_expandedKeyPrefix$channelId') ?? const [];
    _userCollapsedIds = collapsed.toSet();
    _userExpandedIds = expanded.toSet();
    _loaded = true;
    notifyListeners();
  }

  Future<void> toggle(
    String messageId, {
    String? defaultExpandedMessageId,
  }) async {
    final collapsed = isCollapsed(
      messageId,
      defaultExpandedMessageId: defaultExpandedMessageId,
    );
    if (collapsed) {
      _userCollapsedIds.remove(messageId);
      _userExpandedIds.add(messageId);
    } else {
      _userExpandedIds.remove(messageId);
      _userCollapsedIds.add(messageId);
    }
    notifyListeners();
    await _persist();
  }

  Future<void> setCollapsed(String messageId, bool collapsed) async {
    if (collapsed) {
      if (_userCollapsedIds.contains(messageId) &&
          !_userExpandedIds.contains(messageId)) {
        return;
      }
      _userExpandedIds.remove(messageId);
      _userCollapsedIds.add(messageId);
    } else {
      if (_userExpandedIds.contains(messageId) &&
          !_userCollapsedIds.contains(messageId)) {
        return;
      }
      _userCollapsedIds.remove(messageId);
      _userExpandedIds.add(messageId);
    }
    notifyListeners();
    await _persist();
  }

  /// Drop ids that no longer exist in the conversation to bound prefs growth.
  Future<void> pruneTo(Iterable<String> existingIds) async {
    final existing = existingIds is Set<String>
        ? existingIds
        : existingIds.toSet();
    final beforeCollapsed = _userCollapsedIds.length;
    final beforeExpanded = _userExpandedIds.length;
    _userCollapsedIds.removeWhere((id) => !existing.contains(id));
    _userExpandedIds.removeWhere((id) => !existing.contains(id));
    if (_userCollapsedIds.length == beforeCollapsed &&
        _userExpandedIds.length == beforeExpanded) {
      return;
    }
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() async {
    final channelId = _channelId;
    if (channelId == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      '$_collapsedKeyPrefix$channelId',
      _userCollapsedIds.toList(growable: false),
    );
    await prefs.setStringList(
      '$_expandedKeyPrefix$channelId',
      _userExpandedIds.toList(growable: false),
    );
  }
}
