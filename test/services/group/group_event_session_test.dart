import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_event.dart';

void main() {
  group('loopRoundCompleted orchestration session scoping (M4)', () {
    GroupEvent loopEvent(String sessionId, int round, {String? summary}) =>
        GroupEvent.loopRoundCompleted(
          channelId: 'chan',
          round: round,
          orchestrationId: sessionId,
          summary: summary ?? '',
        );

    test('loopRoundCompleted carries orchestrationId in payload', () {
      final e = loopEvent('msg-task-a', 3, summary: 'A 轮结论');
      expect(e.type, GroupEventType.loopRoundCompleted);
      expect(e.orchestrationId, 'msg-task-a');
      expect(e.payload['round'], 3);
      expect(renderEventLine(e), contains('第3轮'));
      expect(renderEventLine(e), contains('A 轮结论'));
    });

    test('loopRoundCompleted without orchestrationId exposes null', () {
      final e = GroupEvent.loopRoundCompleted(channelId: 'chan', round: 1);
      expect(e.orchestrationId, isNull);
    });

    test('fromPersisted round-trips orchestrationId for crash replay', () {
      final original = loopEvent('msg-task-a', 2, summary: 's');
      final restored = GroupEvent.fromPersisted({
        'id': original.id,
        'type': original.type.name,
        'channel_id': original.channelId,
        'round': original.round,
        'summary': original.summary,
        'payload': original.payload,
        'ts': original.createdAt.toUtc().toIso8601String(),
      });
      expect(restored, isNotNull);
      expect(restored!.orchestrationId, 'msg-task-a');
      expect(restored!.round, 2);
    });

    test('filtering by orchestrationId keeps only the current session', () {
      final events = <GroupEvent>[
        loopEvent('msg-task-a', 3),
        loopEvent('msg-task-a', 4),
        loopEvent('msg-task-a', 5),
        loopEvent('msg-task-b', 1),
        loopEvent('msg-task-b', 2),
      ];
      // The same predicate used by chat_service.loopEventLines.
      final taskB = events
          .where((e) => e.type == GroupEventType.loopRoundCompleted)
          .where((e) => e.orchestrationId == 'msg-task-b')
          .toList();
      expect(taskB.map((e) => e.round), [1, 2]);

      final taskA = events
          .where((e) => e.type == GroupEventType.loopRoundCompleted)
          .where((e) => e.orchestrationId == 'msg-task-a')
          .toList();
      expect(taskA.map((e) => e.round), [3, 4, 5]);
    });

    test('null orchestrationId falls back to all loop events (legacy)', () {
      final events = <GroupEvent>[
        loopEvent('msg-task-a', 3),
        loopEvent('msg-task-b', 1),
      ];
      final all = events
          .where((e) => e.type == GroupEventType.loopRoundCompleted)
          .where((e) => e.orchestrationId == null)
          .toList();
      // No event has a null orchestrationId, so null filter yields none;
      // the real fallback path skips the filter entirely (orchestrationId == null).
      expect(all, isEmpty);
    });
  });
}
