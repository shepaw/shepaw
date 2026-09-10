import 'dart:async';

import 'event_envelope.dart';

/// Notify-only perception turn scheduler with debounce + busy queue (P1+).
class PerceptionScheduler {
  void Function(String agentId, List<EventEnvelope> events)? onSchedule;

  Duration debounce = const Duration(seconds: 3);
  Duration busyDefer = const Duration(seconds: 60);

  final Map<String, _ChannelState> _channels = {};

  void schedule({
    required String agentId,
    required String channelId,
    required List<EventEnvelope> events,
    Set<String>? allowedTools,
  }) {
    if (events.isEmpty) return;
    final key = '$agentId::$channelId';
    final state = _channels.putIfAbsent(key, _ChannelState.new);

    state.pending.addAll(events);
    state.lastEventAt = DateTime.now();

    if (state.running) {
      state.queued = true;
      return;
    }

    state.debounceTimer?.cancel();
    state.debounceTimer = Timer(debounce, () {
      unawaited(_drain(key));
    });
  }

  Future<void> _drain(String key) async {
    final state = _channels[key];
    if (state == null || state.running) return;

    final batch = List<EventEnvelope>.from(state.pending);
    state.pending.clear();
    if (batch.isEmpty) return;

    state.running = true;
    try {
      final parts = key.split('::');
      onSchedule?.call(parts.first, batch);
    } finally {
      state.running = false;
      if (state.pending.isNotEmpty || state.queued) {
        state.queued = false;
        state.debounceTimer?.cancel();
        state.debounceTimer = Timer(debounce, () {
          unawaited(_drain(key));
        });
      }
    }
  }

  void reset() {
    for (final s in _channels.values) {
      s.debounceTimer?.cancel();
    }
    _channels.clear();
    onSchedule = null;
  }
}

class _ChannelState {
  final List<EventEnvelope> pending = [];
  Timer? debounceTimer;
  bool running = false;
  bool queued = false;
  DateTime lastEventAt = DateTime.now();
}
