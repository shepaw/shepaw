import 'dart:async';

import 'event_envelope.dart';

/// Notify-only perception turn scheduler with debounce + busy queue (P1+).
class PerceptionScheduler {
  void Function(String agentId, String channelId, List<EventEnvelope> events)?
      onSchedule;

  Duration debounce = const Duration(seconds: 3);

  final Map<String, _ChannelState> _channels = {};

  void schedule({
    required String agentId,
    required String channelId,
    required List<EventEnvelope> events,
  }) {
    if (events.isEmpty) return;
    final key = '$agentId::$channelId';
    final state = _channels.putIfAbsent(key, _ChannelState.new);

    state.pending.addAll(events);

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
      onSchedule?.call(
        parts.first,
        parts.length > 1 ? parts[1] : '',
        batch,
      );
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

  /// 取消所有待触发的批次（保留 [onSchedule] 绑定）。
  void cancelPending() {
    for (final s in _channels.values) {
      s.debounceTimer?.cancel();
    }
    _channels.clear();
  }

  /// 完全重置（含解绑 [onSchedule]；重绑需再调 `ensureBound`）。
  void reset() {
    cancelPending();
    onSchedule = null;
  }
}

class _ChannelState {
  final List<EventEnvelope> pending = [];
  Timer? debounceTimer;
  bool running = false;
  bool queued = false;
}
