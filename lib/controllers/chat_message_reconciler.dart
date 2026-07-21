import '../models/message.dart';

/// Result of reconciling in-memory group placeholders with DB rows.
class GroupReconcileResult {
  final List<Message> messages;

  /// Temp streaming ids that were replaced by a DB message id.
  /// Callers should migrate pending Completer keys accordingly.
  final Map<String, String> pendingKeyMigrations;

  const GroupReconcileResult({
    required this.messages,
    required this.pendingKeyMigrations,
  });
}

/// Pure helpers for merging temporary group / DM streaming bubbles with DB rows.
class ChatMessageReconciler {
  ChatMessageReconciler._();

  static bool isGroupTempId(String id) =>
      id.startsWith('group_streaming_') ||
      id.startsWith('wf_streaming_') ||
      id.startsWith('group_peer_approval_') ||
      id.startsWith('temp_user_');

  static bool isDmStreamingId(String id) => id.startsWith('streaming_');

  static bool hasVisibleAgentContent(Message m) {
    if (!m.from.isAgent) return false;
    if (m.content.trim().isNotEmpty) return true;
    final progress = m.metadata?['progress_content'];
    return progress is String && progress.trim().isNotEmpty;
  }

  static bool hasVisibleTempContent(Message m) {
    if (m.content.trim().isNotEmpty) return true;
    final progress = m.metadata?['progress_content'];
    return progress is String && progress.trim().isNotEmpty;
  }

  /// Whether [m] is an in-flight streaming flush row (`status: streaming`).
  static bool isFlushedStreamingPartial(Message m) =>
      m.from.isAgent && m.metadata?['status'] == 'streaming';

  /// Find a DB / in-memory host bubble to reuse when reattaching a live DM task.
  ///
  /// Prefers [partialMessageId] (the ActiveTask flush row), then the latest
  /// same-agent message still marked `status: streaming`. Returns null when
  /// reattach should create a fresh `streaming_*` placeholder.
  static Message? findReusableDmStreamingHost({
    required List<Message> messages,
    required String agentId,
    String? partialMessageId,
  }) {
    final partialId = partialMessageId;
    if (partialId != null && partialId.isNotEmpty) {
      for (final m in messages) {
        if (m.id == partialId) return m;
      }
    }
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m.from.id != agentId) continue;
      if (isFlushedStreamingPartial(m)) return m;
    }
    return null;
  }

  /// Merge in-memory DM `streaming_*` placeholders with [dbMessages].
  ///
  /// Keep the placeholder when it still has visible content and no usable DB
  /// agent message exists yet (e.g. peer cancel before answer text).
  ///
  /// When a flushed partial (`status: streaming`) already exists for the same
  /// agent — even if it already has visible text — fold the live temp into
  /// that row so switch-back does not show two near-duplicate bubbles.
  static List<Message> mergeDmStreamingPlaceholders({
    required List<Message> current,
    required List<Message> dbMessages,
  }) {
    final streamingTemps = current.where((m) => isDmStreamingId(m.id)).toList();
    if (streamingTemps.isEmpty) return dbMessages;

    final messages = List<Message>.from(dbMessages);

    for (final temp in streamingTemps) {
      if (!hasVisibleTempContent(temp)) continue;

      final sameSenderDb = messages
          .where((m) => m.from.isAgent && m.from.id == temp.from.id)
          .toList();

      if (sameSenderDb.isEmpty) {
        messages.add(temp);
        continue;
      }

      // Prefer the in-flight flush row (may already contain text); fall back to
      // an empty shell left by a prior reconcile.
      Message? adoptTarget;
      for (final m in sameSenderDb.reversed) {
        if (isFlushedStreamingPartial(m)) {
          adoptTarget = m;
          break;
        }
      }
      if (adoptTarget == null) {
        for (final m in sameSenderDb.reversed) {
          if (!hasVisibleAgentContent(m)) {
            adoptTarget = m;
            break;
          }
        }
      }
      if (adoptTarget == null) continue;

      final idx = messages.indexWhere((m) => m.id == adoptTarget!.id);
      if (idx == -1) continue;

      // Live temp is usually ahead of the last flush — prefer it when non-empty.
      final content = temp.content.trim().isNotEmpty
          ? temp.content
          : adoptTarget.content;

      messages[idx] = Message(
        id: adoptTarget.id,
        content: content,
        timestampMs: adoptTarget.timestampMs,
        from: adoptTarget.from,
        to: adoptTarget.to ?? temp.to,
        type: adoptTarget.type,
        replyTo: adoptTarget.replyTo ?? temp.replyTo,
        channelId: adoptTarget.channelId ?? temp.channelId,
        metadata: {
          ...?adoptTarget.metadata,
          ...?temp.metadata,
          'status': adoptTarget.metadata?['status'] ?? 'streaming',
        },
      );
    }

    messages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return messages;
  }

  /// Reconcile in-memory group temps with [dbMessages].
  ///
  /// Pass 1 matches exact content; pass 2 matches unique sender. Unmatched
  /// streaming temps with content are kept when no DB row exists for that
  /// sender (DB save may have failed).
  static GroupReconcileResult reconcileGroupMessages({
    required List<Message> current,
    required List<Message> dbMessages,
  }) {
    final tempMessages = <String, int>{};
    for (int i = 0; i < current.length; i++) {
      final id = current[i].id;
      if (isGroupTempId(id)) tempMessages[id] = i;
    }

    if (tempMessages.isEmpty) {
      return GroupReconcileResult(
        messages: List<Message>.from(dbMessages),
        pendingKeyMigrations: const {},
      );
    }

    final messages = List<Message>.from(current);
    final matchedDbIds = <String>{};
    final usedTempIds = <String>{};
    final pendingKeyMigrations = <String, String>{};

    void adopt(String tempId, Message dbMsg) {
      final idx = tempMessages[tempId]!;
      messages[idx] = dbMsg;
      matchedDbIds.add(dbMsg.id);
      usedTempIds.add(tempId);
      pendingKeyMigrations[tempId] = dbMsg.id;
    }

    // Pass 1: exact content match
    for (final dbMsg in dbMessages) {
      if (matchedDbIds.contains(dbMsg.id)) continue;
      String? matchedTempId;
      for (final entry in tempMessages.entries) {
        if (usedTempIds.contains(entry.key)) continue;
        final tempMsg = messages[entry.value];
        if (tempMsg.from.id == dbMsg.from.id &&
            tempMsg.content.trim() == dbMsg.content.trim()) {
          matchedTempId = entry.key;
          break;
        }
      }
      if (matchedTempId != null) adopt(matchedTempId, dbMsg);
    }

    // Pass 2: unique remaining temp from the same sender
    for (final dbMsg in dbMessages) {
      if (matchedDbIds.contains(dbMsg.id)) continue;
      final candidates = tempMessages.entries
          .where((e) =>
              !usedTempIds.contains(e.key) &&
              messages[e.value].from.id == dbMsg.from.id)
          .toList();
      if (candidates.length == 1) {
        adopt(candidates.first.key, dbMsg);
      }
    }

    final dbSenderIds = dbMessages.map((m) => m.from.id).toSet();
    messages.removeWhere((m) {
      if (!isGroupTempId(m.id)) return false;
      if (usedTempIds.contains(m.id)) return false;
      if (m.id.startsWith('group_streaming_') &&
          m.content.trim().isNotEmpty &&
          !dbSenderIds.contains(m.from.id)) {
        return false;
      }
      if ((m.id.startsWith('wf_streaming_') ||
              m.id.startsWith('group_peer_approval_')) &&
          !dbSenderIds.contains(m.from.id)) {
        return false;
      }
      return true;
    });

    final existingIds = messages.map((m) => m.id).toSet();
    for (final dbMsg in dbMessages) {
      if (!existingIds.contains(dbMsg.id) && !matchedDbIds.contains(dbMsg.id)) {
        messages.add(dbMsg);
      }
    }

    messages.sort((a, b) => a.timestampMs.compareTo(b.timestampMs));
    return GroupReconcileResult(
      messages: messages,
      pendingKeyMigrations: pendingKeyMigrations,
    );
  }
}
