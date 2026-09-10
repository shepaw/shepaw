import 'dart:async';

import 'event_envelope.dart';
import 'event_scope.dart';
import 'event_type_matching.dart';

/// Temporary RPC wait contract (`events wait --correlation`).
class WaitLease {
  final String leaseId;
  final String agentId;
  final String? correlationId;
  final List<String> typePatterns;
  final EventScope? scopeFilter;
  final int seqAtOpen;
  final DateTime expiresAt;
  final Completer<EventEnvelope> completer;

  bool completed = false;
  bool cancelled = false;

  WaitLease({
    required this.leaseId,
    required this.agentId,
    this.correlationId,
    required this.typePatterns,
    this.scopeFilter,
    required this.seqAtOpen,
    required this.expiresAt,
    Completer<EventEnvelope>? completer,
  }) : completer = completer ?? Completer<EventEnvelope>();

  bool get isExpired => DateTime.now().isAfter(expiresAt);

  bool matches(EventEnvelope event) {
    if (completed || cancelled || isExpired) return false;
    if (event.seq < seqAtOpen) return false;

    if (correlationId != null && event.correlationId != correlationId) {
      return false;
    }
    if (!typeMatchesAny(typePatterns, event.type)) return false;
    if (scopeFilter != null && !scopeFilter!.contains(event.scope)) {
      return false;
    }
    return true;
  }

  void complete(EventEnvelope event) {
    if (completed || cancelled) return;
    completed = true;
    if (!completer.isCompleted) {
      completer.complete(event);
    }
  }

  void cancel() {
    if (completed) return;
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(WaitCancelledException(leaseId));
    }
  }

  void timeout() {
    if (completed || cancelled) return;
    cancelled = true;
    if (!completer.isCompleted) {
      completer.completeError(WaitTimeoutException(leaseId));
    }
  }
}

class WaitTimeoutException implements Exception {
  final String leaseId;
  WaitTimeoutException(this.leaseId);

  @override
  String toString() => 'WaitLease timeout: $leaseId';
}

class WaitCancelledException implements Exception {
  final String leaseId;
  WaitCancelledException(this.leaseId);

  @override
  String toString() => 'WaitLease cancelled: $leaseId';
}

class CorrelationAlreadyWaitedException implements Exception {
  final String correlationId;
  CorrelationAlreadyWaitedException(this.correlationId);

  @override
  String toString() =>
      'correlation already waited: $correlationId';
}
