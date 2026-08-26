import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_event_perception.dart';

void main() {
  group('global admin turn mutex (M2)', () {
    test('tryBegin succeeds when the admin is free, fails when held', () {
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'p-a'),
        isTrue,
      );
      // Same holder is idempotent.
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'p-a'),
        isTrue,
      );
      // A different holder is refused — the admin already has a turn.
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'p-b'),
        isFalse,
      );
      // A different admin is unaffected.
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-2', 'p-b'),
        isTrue,
      );
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', 'p-a');
      GroupEventPerceptionScheduler.endAdminTurn('admin-2', 'p-b');
    });

    test('forceBegin preempts a perception holder and its end does not release', () {
      // Perception turn A starts.
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'percept-a'),
        isTrue,
      );
      // Gate turn force-preempts.
      final gateHolder =
          GroupEventPerceptionScheduler.beginExplicitAdminTurn('admin-1');
      // The preempted perception turn's finally tries to release, but it is no
      // longer the holder — must NOT release the gate's claim.
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', 'percept-a');
      // A perception turn still sees the admin busy.
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'percept-b'),
        isFalse,
      );
      // Gate releases; the admin is free again.
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', gateHolder);
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'percept-c'),
        isTrue,
      );
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', 'percept-c');
    });

    test('endAdminTurn only releases the matching holder', () {
      final h = GroupEventPerceptionScheduler.beginExplicitAdminTurn('admin-1');
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', 'wrong-holder');
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'other'),
        isFalse,
      );
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', h);
      expect(
        GroupEventPerceptionScheduler.tryBeginAdminTurn('admin-1', 'other'),
        isTrue,
      );
      GroupEventPerceptionScheduler.endAdminTurn('admin-1', 'other');
    });
  });
}
