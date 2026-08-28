import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/queued_message_ops.dart';
import 'package:shepaw/models/queued_message.dart';

QueuedMessage _msg(String id, String content) =>
    QueuedMessage(id: id, content: content);

void main() {
  group('QueuedMessageOps.edit', () {
    test('hits by id and trims content', () {
      final q = [_msg('a', 'hello'), _msg('b', 'world')];
      expect(QueuedMessageOps.edit(q, 'a', '  edited  '), isTrue);
      expect(q.first.content, 'edited');
      expect(q.last.content, 'world');
    });

    test('rejects empty trimmed content (returns false, unchanged)', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.edit(q, 'a', '   '), isFalse);
      expect(q.first.content, 'hello');
    });

    test('returns false when id not found', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.edit(q, 'nope', 'x'), isFalse);
      expect(q.first.content, 'hello');
    });
  });

  group('QueuedMessageOps.remove', () {
    test('removes by id', () {
      final q = [_msg('a', 'hello'), _msg('b', 'world')];
      expect(QueuedMessageOps.remove(q, 'a'), isTrue);
      expect(q.map((m) => m.id), ['b']);
    });

    test('returns false when id not found', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.remove(q, 'nope'), isFalse);
      expect(q.length, 1);
    });

    test('removing the last element works', () {
      final q = [_msg('a', 'hello')];
      expect(QueuedMessageOps.remove(q, 'a'), isTrue);
      expect(q, isEmpty);
    });
  });

  group('QueuedMessageOps.move', () {
    test('moves up (delta -1)', () {
      final q = [_msg('a', '1'), _msg('b', '2'), _msg('c', '3')];
      expect(QueuedMessageOps.move(q, 'b', -1), isTrue);
      expect(q.map((m) => m.id), ['b', 'a', 'c']);
    });

    test('moves down (delta +1)', () {
      final q = [_msg('a', '1'), _msg('b', '2'), _msg('c', '3')];
      expect(QueuedMessageOps.move(q, 'a', 1), isTrue);
      expect(q.map((m) => m.id), ['b', 'a', 'c']);
    });

    test('clamps at boundaries (returns false)', () {
      final q = [_msg('a', '1'), _msg('b', '2')];
      expect(QueuedMessageOps.move(q, 'a', -1), isFalse);
      expect(q.map((m) => m.id), ['a', 'b']);
      expect(QueuedMessageOps.move(q, 'b', 1), isFalse);
      expect(q.map((m) => m.id), ['a', 'b']);
    });

    test('returns false when id not found', () {
      final q = [_msg('a', '1')];
      expect(QueuedMessageOps.move(q, 'nope', -1), isFalse);
    });

    test('returns false when delta is 0', () {
      final q = [_msg('a', '1'), _msg('b', '2')];
      expect(QueuedMessageOps.move(q, 'a', 0), isFalse);
      expect(q.map((m) => m.id), ['a', 'b']);
    });
  });
}
