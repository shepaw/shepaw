import 'dart:async';

import 'event_envelope.dart';

/// Notify-only perception turn scheduler with debounce + busy queue (P1+).
class PerceptionScheduler {
  /// 感知回合回调。**必须返回可 await 的 Future**：`_drain` 会等它结束才释放
  /// running 锁，否则锁只覆盖同步调用瞬间，回合会重叠（见 `_drain`）。
  Future<void> Function(
    String agentId,
    String channelId,
    List<EventEnvelope> events,
  )? onSchedule;

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
      // await：running 锁必须覆盖整个感知回合，否则回合重叠（debounce 队列
      // 也失效）。
      try {
        await onSchedule?.call(
          parts.first,
          parts.length > 1 ? parts[1] : '',
          batch,
        );
      } catch (_) {
        // 回调自会兜异常并记日志（见 EventPerceptionService._onSchedule）；
        // 这里再兜一层，避免回合抛错变成 Timer 中的 unhandled async error。
      }
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
