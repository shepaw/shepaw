import '../models/mention_entry.dart';
import '../models/message.dart';
import 'chat_streaming_text.dart';
import 'chat_workflow_coordinator.dart';

/// Pure helpers for group-chat interaction cards and optimistic UI.
class GroupInteractionPlanner {
  GroupInteractionPlanner._();

  /// Interaction types that complete immediately (non-blocking Completer).
  static const nonBlockingTypes = {
    'form',
    'file_upload',
    'action_confirmation',
    'single_select',
    'multi_select',
    'plan_approval',
  };

  static bool isNonBlocking(String interactionType) =>
      nonBlockingTypes.contains(interactionType);

  static Map<String, dynamic> nonBlockingResult() =>
      const {'_non_blocking': true};

  /// Workflow id embedded in a plan_approval payload, if any.
  static String? workflowIdFromPlanApproval(
    String interactionType,
    Map<String, dynamic> data,
  ) {
    if (interactionType != 'plan_approval') return null;
    return data['_workflowId'] as String?;
  }

  /// Prefer live streaming id; else a reconciled DB message id.
  ///
  /// When [preferSaved] is true (workflow reattach path), a saved DB id wins
  /// over the in-flight streaming placeholder.
  static String? resolvePreferredSid({
    required String? streamingSid,
    required String? savedMessageId,
    required bool Function(String id) hasMessage,
    bool preferSaved = false,
  }) {
    if (preferSaved) {
      if (savedMessageId != null && hasMessage(savedMessageId)) {
        return savedMessageId;
      }
      return streamingSid;
    }
    if (streamingSid != null) return streamingSid;
    if (savedMessageId != null && hasMessage(savedMessageId)) {
      return savedMessageId;
    }
    return null;
  }

  /// Take and remove `_savedMessageId` from [data] (mutates).
  static String? takeSavedMessageId(Map<String, dynamic> data) =>
      data.remove('_savedMessageId') as String?;

  static String pendingKey({
    required String interactionType,
    required Map<String, dynamic> data,
    required String? sid,
    required String agentId,
  }) =>
      ChatWorkflowCoordinator.interactionPendingKey(
        interactionType: interactionType,
        data: data,
        sid: sid,
        agentId: agentId,
      );

  /// Metadata map to persist after attaching an interaction card.
  static Map<String, dynamic> metadataForPersist({
    required Map<String, dynamic>? existing,
    required String interactionType,
    required Map<String, dynamic> data,
  }) {
    final meta = Map<String, dynamic>.from(existing ?? {});
    meta[interactionType] = data;
    return meta;
  }

  /// Whether to create a peer-approval host bubble when preferred sid is missing.
  static bool needsPeerApprovalFallback({
    required String? preferredSid,
    required bool preferredExists,
    required String interactionType,
    required Map<String, dynamic> data,
    required bool hasChannel,
  }) {
    if (preferredSid != null && preferredExists) return false;
    return interactionType == 'action_confirmation' &&
        data['confirmation_context'] == 'peer' &&
        hasChannel;
  }

  static bool shouldDropSkippedPlaceholder({
    required bool skipped,
    required String? sid,
  }) =>
      skipped && sid != null;

  /// Optimistic user bubble for a group send.
  static Message buildOptimisticUserMessage({
    required String content,
    required String userId,
    required String userName,
    String? replyToId,
    int? nowMs,
  }) {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    return Message(
      id: 'temp_user_$now',
      content: content,
      timestampMs: now,
      from: MessageFrom(id: userId, type: 'user', name: userName),
      type: MessageType.text,
      replyTo: replyToId,
    );
  }

  static Message buildAgentStreamingPlaceholder({
    required String sid,
    required String agentId,
    required String agentName,
    required String userId,
    required String userName,
    int? timestampMs,
  }) {
    return ChatStreamingText.placeholder(
      id: sid,
      from: MessageFrom(id: agentId, type: 'agent', name: agentName),
      to: MessageFrom(id: userId, type: 'user', name: userName),
      timestampMs: timestampMs ?? DateTime.now().millisecondsSinceEpoch + 1,
    );
  }

  static String groupStreamingId(String agentId, {int? nowMs}) =>
      'group_streaming_${agentId}_${nowMs ?? DateTime.now().millisecondsSinceEpoch}';

  /// Mentions metadata persisted on the user message, if any.
  static Map<String, dynamic>? userMessageMentionsMetadata(
    List<MentionEntry> mentions,
  ) {
    if (mentions.isEmpty) return null;
    return {'mentions': mentions.map((m) => m.toJson()).toList()};
  }
}
