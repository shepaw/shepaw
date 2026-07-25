import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/session/history_compactor.dart';

Message _msg({
  required String id,
  required String content,
  required bool isAgent,
  String name = 'X',
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: DateTime.now().millisecondsSinceEpoch,
    from: MessageFrom(
      id: isAgent ? 'agent' : 'user',
      type: isAgent ? 'agent' : 'user',
      name: name,
    ),
    type: MessageType.text,
  );
}

void main() {
  group('HistoryCompactor.plan', () {
    test('keeps all messages when under budget', () {
      final messages = [
        _msg(id: '1', content: 'hi', isAgent: false),
        _msg(id: '2', content: 'hello', isAgent: true),
      ];
      final plan = HistoryCompactor.plan(messages: messages, maxChars: 1000);
      expect(plan.needsCompaction, isFalse);
      expect(plan.older, isEmpty);
      expect(plan.recent, hasLength(2));
    });

    test('splits older vs recent when over budget', () {
      final messages = List.generate(
        20,
        (i) => _msg(
          id: '$i',
          content: 'm' * 200, // 20 * 200 = 4000 > 500
          isAgent: i.isEven,
        ),
      );
      final plan = HistoryCompactor.plan(
        messages: messages,
        maxChars: 500,
        keepRecentCount: 4,
        keepRecentChars: 900,
      );
      expect(plan.needsCompaction, isTrue);
      expect(plan.recent, isNotEmpty);
      expect(plan.older, isNotEmpty);
      expect(plan.older.length + plan.recent.length, messages.length);
      // Recent is a suffix of the original list.
      expect(
        plan.recent.map((m) => m.id).toList(),
        messages.sublist(messages.length - plan.recent.length).map((m) => m.id),
      );
    });
  });

  group('HistoryCompactor.buildTranscript', () {
    test('formats roles and truncates from the head when too long', () {
      final messages = [
        _msg(id: '1', content: 'AAAA', isAgent: false, name: 'U'),
        _msg(id: '2', content: 'BBBB', isAgent: true, name: 'A'),
        _msg(id: '3', content: 'CCCC', isAgent: false, name: 'U'),
      ];
      final full = HistoryCompactor.buildTranscript(messages, maxChars: 10000);
      expect(full, contains('User (U): AAAA'));
      expect(full, contains('Assistant (A): BBBB'));

      final clipped = HistoryCompactor.buildTranscript(messages, maxChars: 40);
      expect(clipped, contains('[earlier omitted]'));
      expect(clipped, contains('CCCC'));
    });
  });

  group('HistoryCompactor.summaryMessage', () {
    test('wraps summary as user context block', () {
      final msg = HistoryCompactor.summaryMessage('User prefers dark mode.');
      expect(msg['role'], 'user');
      expect(msg['content'], contains('Earlier conversation summary'));
      expect(msg['content'], contains('User prefers dark mode.'));
    });
  });

  group('HistoryCompactor.fifoTruncate', () {
    test('keeps all messages when under budget', () {
      final messages = [
        _msg(id: '1', content: 'aaa', isAgent: false),
        _msg(id: '2', content: 'bbb', isAgent: true),
      ];
      final kept = HistoryCompactor.fifoTruncate(messages, 1000);
      expect(kept.map((m) => m.id), ['1', '2']);
    });

    test('drops oldest until under budget', () {
      final messages = [
        _msg(id: '1', content: 'a' * 100, isAgent: false),
        _msg(id: '2', content: 'b' * 100, isAgent: true),
        _msg(id: '3', content: 'c' * 100, isAgent: false),
      ];
      final kept = HistoryCompactor.fifoTruncate(messages, 150);
      expect(kept.map((m) => m.id), ['3']);
      expect(kept.fold<int>(0, (s, m) => s + m.content.length), 100);
    });
  });

  group('HistoryCompactor.plan group-scale budget', () {
    test('splits with larger keepRecent for group chats', () {
      final messages = List.generate(
        40,
        (i) => _msg(
          id: '$i',
          content: 'g' * 2000, // 80k total
          isAgent: i.isEven,
        ),
      );
      final plan = HistoryCompactor.plan(
        messages: messages,
        maxChars: 60000,
        keepRecentCount: 24,
        keepRecentChars: 24000,
      );
      expect(plan.needsCompaction, isTrue);
      expect(plan.recent.length, lessThanOrEqualTo(24));
      expect(
        plan.recent.fold<int>(0, (s, m) => s + m.content.length),
        lessThanOrEqualTo(24000),
      );
    });
  });
}
