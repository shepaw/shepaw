import '../models/message.dart';

/// Pure helpers for attaching in-band action-confirmation cards to a host bubble.
class StreamingActionConfirmation {
  StreamingActionConfirmation._();

  static const fallbackPrompt = '需要您的确认';

  static String promptContent(Map<String, dynamic> actionData) {
    final prompt = (actionData['prompt'] as String?)?.trim();
    return prompt != null && prompt.isNotEmpty ? prompt : fallbackPrompt;
  }

  /// Prefer [preferredId] when present in [messageIdMap]; else latest agent bubble.
  static String? resolveHostMessageId({
    required String? preferredId,
    required Map<String, Message> messageIdMap,
    required List<Message> messages,
  }) {
    if (preferredId != null && messageIdMap.containsKey(preferredId)) {
      return preferredId;
    }
    for (final msg in messages.reversed) {
      if (msg.from.isAgent) return msg.id;
    }
    return null;
  }

  static String dmFallbackId(String agentId, {int? nowMs}) =>
      'peer_approval_${agentId}_${nowMs ?? DateTime.now().millisecondsSinceEpoch}';

  static String groupFallbackId(String agentId, {int? nowMs}) =>
      'group_peer_approval_${agentId}_${nowMs ?? DateTime.now().millisecondsSinceEpoch}';

  /// Build a dedicated peer-approval host when no streaming bubble exists.
  static Message buildFallbackBubble({
    required String id,
    required String agentId,
    required String agentName,
    required String userId,
    required String userName,
    required Map<String, dynamic> actionData,
    int? timestampMs,
    String metadataKey = 'action_confirmation',
  }) {
    return Message(
      id: id,
      content: promptContent(actionData),
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch + 1,
      from: MessageFrom(id: agentId, type: 'agent', name: agentName),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      metadata: {
        metadataKey: Map<String, dynamic>.from(actionData),
      },
    );
  }

  /// Attach / replace `action_confirmation` on an existing host bubble.
  static Message attachToHost({
    required Message host,
    required Map<String, dynamic> actionData,
    String? contentOverride,
  }) {
    final existingMetadata =
        Map<String, dynamic>.from(host.metadata ?? {});
    existingMetadata['action_confirmation'] =
        Map<String, dynamic>.from(actionData);
    existingMetadata['approval_seq'] =
        (existingMetadata['approval_seq'] as int? ?? 0) + 1;
    final content = (contentOverride != null && contentOverride.isNotEmpty)
        ? contentOverride
        : host.content;
    return Message(
      id: host.id,
      content: content,
      timestampMs: host.timestampMs,
      from: host.from,
      to: host.to,
      channelId: host.channelId,
      type: host.type,
      replyTo: host.replyTo,
      metadata: existingMetadata,
    );
  }

  /// Whether a new confirmation replaces a prior card (for logging / tests).
  static bool replacesPrior({
    required Map<String, dynamic>? existingMetadata,
    required String confirmationId,
  }) {
    final prev = existingMetadata?['action_confirmation'];
    if (prev is! Map) return false;
    final prevId = prev['confirmation_id'];
    return prevId != null && prevId != confirmationId;
  }
}
