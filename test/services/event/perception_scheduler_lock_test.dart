import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/event/event_envelope.dart';
import 'package:shepaw/services/event/event_scope.dart';
import 'package:shepaw/services/event/perception_scheduler.dart';

EventEnvelope _event(int seq) => EventEnvelope(
      id: 'e$seq',
      type: 'peer.pairing.inbound',
      source: 'system:peer',
      seq: seq,
      at: DateTime.now(),
      payload: const {},
      scope: const EventScope(),
    );

void main() {
  test('running lock spans the async turn (no overlapping perception turns)',
      () async {
    final scheduler = PerceptionScheduler()
      ..debounce = const Duration(milliseconds: 1);

    var concurrent = 0;
    var maxConcurrent = 0;
    final batches = <int>[];

    scheduler.onSchedule = (agentId, channelId, events) async {
      concurrent++;
      if (concurrent > maxConcurrent) maxConcurrent = concurrent;
      batches.add(events.length);
      await Future<void>.delayed(const Duration(milliseconds: 120));
      concurrent--;
    };

    scheduler.schedule(agentId: 'a', channelId: 'ch', events: [_event(1)]);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    // 第一回合仍在进行中 → 第二批只排队，不得并发开启新回合。
    scheduler.schedule(agentId: 'a', channelId: 'ch', events: [_event(2)]);
    await Future<void>.delayed(const Duration(milliseconds: 500));

    expect(maxConcurrent, 1, reason: 'running 锁必须覆盖整个异步回合');
    // 第二批没有被丢弃：回合结束后作为独立批次 drain。
    expect(batches, [1, 1]);
  });
}
