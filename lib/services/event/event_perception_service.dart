import 'dart:async';

import '../logger_service.dart';
import '../she_service.dart';
import 'event_envelope.dart';
import 'event_bus.dart';
import 'perception_scheduler.dart';

/// Wires [PerceptionScheduler] to agent notify-only turns (P1+).
class EventPerceptionService {
  EventPerceptionService._();
  static final EventPerceptionService instance = EventPerceptionService._();

  static const _tag = 'EventPerception';

  /// Set by [ChatService] after messaging stack is ready.
  Future<void> Function(String agentId, List<EventEnvelope> events)? runNotifyTurn;

  bool _bound = false;

  void ensureBound(PerceptionScheduler scheduler) {
    if (_bound) return;
    _bound = true;
    scheduler.onSchedule = (agentId, events) {
      unawaited(_onSchedule(agentId, events));
    };
  }

  Future<void> _onSchedule(String agentId, List<EventEnvelope> events) async {
    if (events.isEmpty) return;
    final run = runNotifyTurn;
    if (run == null) {
      LoggerService().debug(
        'Event perception skipped (no handler): agent=$agentId types=${events.map((e) => e.type).join(",")}',
        tag: _tag,
      );
      return;
    }
    try {
      await run(agentId, events);
    } catch (e, st) {
      LoggerService().error(
        'Event perception turn failed: $e',
        tag: _tag,
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Default She DM channel id (1:1).
  static String defaultChannelForAgent(String agentId) {
    if (agentId == SheService.sheId) return SheService.sheId;
    return agentId;
  }
}

/// Call once after [EventBus] is registered.
void wireEventPerception() {
  EventPerceptionService.instance
      .ensureBound(EventBus.instance.perceptionScheduler);
}
