import 'dart:async';

import '../models/message.dart';

/// Shared shape for pending group / workflow interaction Completers.
abstract interface class PendingInteractionLike {
  String get agentId;
  Map<String, dynamic> get data;
  Completer<Map<String, dynamic>?> get result;
}

/// Minimal slot for tests / standalone Completer tracking.
class PendingInteractionSlot implements PendingInteractionLike {
  @override
  final String agentId;
  @override
  final Map<String, dynamic> data;
  @override
  final Completer<Map<String, dynamic>?> result;

  PendingInteractionSlot({
    required this.agentId,
    required this.data,
    required this.result,
  });
}

/// Pure helpers for completing in-flight peer / group approval Completers.
class PeerApprovalCompleterResolver {
  PeerApprovalCompleterResolver._();

  static Map<String, dynamic> submittedResponse({
    required String actionId,
    required String actionLabel,
  }) =>
      {
        'selected_action_id': actionId,
        'selected_action_label': actionLabel,
        '_approval_submitted': true,
      };

  /// Complete the first matching pending slot. Returns true when a Completer
  /// was completed and removed from [pending].
  static bool completePending<T extends PendingInteractionLike>(
    Map<String, T> pending, {
    required Message originalMessage,
    required String actionId,
    required String actionLabel,
    String? confirmationId,
  }) {
    final response = submittedResponse(
      actionId: actionId,
      actionLabel: actionLabel,
    );
    final keys = <String>{
      if (confirmationId != null && confirmationId.isNotEmpty) confirmationId,
      originalMessage.id,
      originalMessage.from.id,
    };
    for (final key in keys) {
      final slot = pending[key];
      if (slot != null && !slot.result.isCompleted) {
        slot.result.complete(response);
        pending.remove(key);
        return true;
      }
    }
    for (final entry in pending.entries.toList()) {
      if (entry.value.agentId == originalMessage.from.id &&
          !entry.value.result.isCompleted) {
        final pendingCid = entry.value.data['confirmation_id'] as String?;
        if (confirmationId != null &&
            confirmationId.isNotEmpty &&
            pendingCid != null &&
            pendingCid != confirmationId) {
          continue;
        }
        entry.value.result.complete(response);
        pending.remove(entry.key);
        return true;
      }
    }
    return false;
  }
}
