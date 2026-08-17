import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_group_turn_gate.dart';

void main() {
  group('GroupTurnGate', () {
    test('epoch is current right after beginTurn', () {
      final gate = GroupTurnGate();
      final epoch = gate.beginTurn();
      expect(gate.isCurrent(epoch), isTrue);
    });

    test('invalidate supersedes the current epoch', () {
      final gate = GroupTurnGate();
      final epoch = gate.beginTurn();
      gate.invalidate();
      expect(gate.isCurrent(epoch), isFalse);
    });

    test('beginTurn after invalidate supersedes the old epoch', () {
      final gate = GroupTurnGate();
      final oldEpoch = gate.beginTurn();
      gate.invalidate();
      final newEpoch = gate.beginTurn();

      expect(gate.isCurrent(oldEpoch), isFalse);
      expect(gate.isCurrent(newEpoch), isTrue);
    });

    test('a newer turn supersedes the previous one without invalidate', () {
      final gate = GroupTurnGate();
      final first = gate.beginTurn();
      final second = gate.beginTurn();

      expect(gate.isCurrent(first), isFalse);
      expect(gate.isCurrent(second), isTrue);
    });

    test('invalidate without a turn does not break subsequent turns', () {
      final gate = GroupTurnGate();
      gate.invalidate();
      final epoch = gate.beginTurn();
      expect(gate.isCurrent(epoch), isTrue);
    });
  });
}
