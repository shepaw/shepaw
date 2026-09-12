import 'dart:async';

import '../models/message.dart';
import 'cli_approval_coordinator.dart';

/// In-memory handle for one CLI / OS confirmation waiting on a chat card.
class CliApprovalHandle {
  final String confirmationId;
  final String toolName;
  final String? channelId;
  final Completer<bool> completer;
  Timer? timeoutTimer;

  CliApprovalHandle({
    required this.confirmationId,
    required this.toolName,
    required this.channelId,
    required this.completer,
  });
}

/// Process-wide registry of CLI approvals, keyed by [confirmationId].
///
/// Survives channel navigation (the Completer stays alive) so the user can
/// leave the chat and tap the card later. Does **not** survive process death —
/// [expireStaleCards] marks leftover unanswered cards after a cold start.
class CliApprovalService {
  CliApprovalService._();
  static final instance = CliApprovalService._();

  final Map<String, CliApprovalHandle> _pending = {};

  /// Unanswered cards deny themselves so a backgrounded app cannot freeze
  /// a group turn for tens of minutes (snake session, 2026-09-12).
  static const defaultTimeout = Duration(minutes: 2);

  /// Register (or reuse) a pending approval and wait for [complete] / [cancel].
  ///
  /// [timeout] defaults to [defaultTimeout]. `Duration.zero` waits forever
  /// (tests / explicit no-timeout callers).
  Future<bool> awaitApproval({
    required String confirmationId,
    required String toolName,
    String? channelId,
    Duration? timeout,
  }) {
    final existing = _pending[confirmationId];
    if (existing != null && !existing.completer.isCompleted) {
      return existing.completer.future;
    }
    final handle = CliApprovalHandle(
      confirmationId: confirmationId,
      toolName: toolName,
      channelId: channelId,
      completer: Completer<bool>(),
    );
    _pending[confirmationId] = handle;
    final limit = timeout ?? defaultTimeout;
    if (limit > Duration.zero) {
      handle.timeoutTimer = Timer(limit, () {
        if (!handle.completer.isCompleted) {
          complete(confirmationId, approved: false);
        }
      });
    }
    return handle.completer.future;
  }

  bool hasLive(String confirmationId) {
    final handle = _pending[confirmationId];
    return handle != null && !handle.completer.isCompleted;
  }

  /// Live confirmation ids for [channelId] (empty channel matches null too).
  Iterable<String> liveIdsForChannel(String channelId) => _pending.entries
      .where((e) =>
          !e.value.completer.isCompleted && e.value.channelId == channelId)
      .map((e) => e.key);

  void complete(
    String confirmationId, {
    required bool approved,
    bool rememberSession = false,
    String? toolName,
  }) {
    final handle = _pending.remove(confirmationId);
    handle?.timeoutTimer?.cancel();
    final name = (toolName ?? handle?.toolName ?? '').trim();
    if (approved && rememberSession && name.isNotEmpty) {
      CliApprovalCoordinator.instance.grantForSession(name);
    }
    if (handle != null && !handle.completer.isCompleted) {
      handle.completer.complete(approved);
    }
  }

  void cancel(String confirmationId) =>
      complete(confirmationId, approved: false);

  /// Deny every live approval on [channelId] (user stopped the turn).
  void cancelForChannel(String channelId) {
    for (final id in liveIdsForChannel(channelId).toList()) {
      cancel(id);
    }
  }

  /// Unanswered `confirmation_context: cli` cards with no live Completer.
  ///
  /// Returns message ids whose metadata should be persisted as expired.
  List<String> expireStaleCards(Iterable<Message> messages) {
    final expired = <String>[];
    for (final msg in messages) {
      final ac = msg.metadata?['action_confirmation'];
      if (ac is! Map) continue;
      if (ac['confirmation_context'] != 'cli') continue;
      if (ac['selected_action_id'] != null) continue;
      final id = (ac['confirmation_id'] as String?)?.trim() ?? '';
      if (id.isEmpty || hasLive(id)) continue;
      expired.add(msg.id);
    }
    return expired;
  }

  void resetForTest() {
    for (final handle in _pending.values) {
      handle.timeoutTimer?.cancel();
    }
    _pending.clear();
  }
}
