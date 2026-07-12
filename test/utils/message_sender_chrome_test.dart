import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/utils/message_utils.dart';

Message _msg({
  required String id,
  required String senderId,
  required DateTime timestamp,
  String name = 'Alice',
}) {
  return Message.simple(
    id: id,
    channelId: 'ch',
    senderId: senderId,
    senderName: name,
    content: 'hi',
    timestamp: timestamp,
    type: MessageType.text,
  );
}

void main() {
  final t0 = DateTime(2026, 7, 12, 10, 0);
  final t1 = DateTime(2026, 7, 12, 10, 1);
  final tFar = DateTime(2026, 7, 12, 10, 5);
  final nextDay = DateTime(2026, 7, 13, 9, 0);

  group('shouldCollapseSenderChrome', () {
    test('false in DM even for consecutive same sender', () {
      final prev = _msg(id: '1', senderId: 'a', timestamp: t0);
      final curr = _msg(id: '2', senderId: 'a', timestamp: t1);
      expect(
        MessageUtils.shouldCollapseSenderChrome(
          isGroupMode: false,
          previousMessage: prev,
          currentMessage: curr,
          showDateSeparator: false,
        ),
        isFalse,
      );
    });

    test('true in group for consecutive same sender within 2 minutes', () {
      final prev = _msg(id: '1', senderId: 'a', timestamp: t0);
      final curr = _msg(id: '2', senderId: 'a', timestamp: t1);
      expect(
        MessageUtils.shouldCollapseSenderChrome(
          isGroupMode: true,
          previousMessage: prev,
          currentMessage: curr,
          showDateSeparator: false,
        ),
        isTrue,
      );
    });

    test('false when sender changes', () {
      final prev = _msg(id: '1', senderId: 'a', timestamp: t0);
      final curr = _msg(id: '2', senderId: 'b', timestamp: t1, name: 'Bob');
      expect(
        MessageUtils.shouldCollapseSenderChrome(
          isGroupMode: true,
          previousMessage: prev,
          currentMessage: curr,
          showDateSeparator: false,
        ),
        isFalse,
      );
    });

    test('false when date separator is shown', () {
      final prev = _msg(id: '1', senderId: 'a', timestamp: t0);
      final curr = _msg(id: '2', senderId: 'a', timestamp: nextDay);
      expect(
        MessageUtils.shouldCollapseSenderChrome(
          isGroupMode: true,
          previousMessage: prev,
          currentMessage: curr,
          showDateSeparator: true,
        ),
        isFalse,
      );
    });

    test('false when gap exceeds 2 minutes', () {
      final prev = _msg(id: '1', senderId: 'a', timestamp: t0);
      final curr = _msg(id: '2', senderId: 'a', timestamp: tFar);
      expect(
        MessageUtils.shouldCollapseSenderChrome(
          isGroupMode: true,
          previousMessage: prev,
          currentMessage: curr,
          showDateSeparator: false,
        ),
        isFalse,
      );
    });
  });

  group('shouldShowSenderName', () {
    test('hidden in DM', () {
      expect(
        MessageUtils.shouldShowSenderName(
          isGroupMode: false,
          isMyMessage: false,
          collapseSenderChrome: false,
        ),
        isFalse,
      );
    });

    test('shown for others in group when not collapsed', () {
      expect(
        MessageUtils.shouldShowSenderName(
          isGroupMode: true,
          isMyMessage: false,
          collapseSenderChrome: false,
        ),
        isTrue,
      );
    });

    test('hidden for my messages in group', () {
      expect(
        MessageUtils.shouldShowSenderName(
          isGroupMode: true,
          isMyMessage: true,
          collapseSenderChrome: false,
        ),
        isFalse,
      );
    });

    test('hidden when consecutive chrome collapsed', () {
      expect(
        MessageUtils.shouldShowSenderName(
          isGroupMode: true,
          isMyMessage: false,
          collapseSenderChrome: true,
        ),
        isFalse,
      );
    });
  });

  group('shouldShowAvatar', () {
    test('hidden in DM to widen bubbles', () {
      expect(
        MessageUtils.shouldShowAvatar(
          isGroupMode: false,
          collapseSenderChrome: false,
        ),
        isFalse,
      );
    });

    test('hidden in group when collapsed', () {
      expect(
        MessageUtils.shouldShowAvatar(
          isGroupMode: true,
          collapseSenderChrome: true,
        ),
        isFalse,
      );
    });

    test('shown in group when not collapsed', () {
      expect(
        MessageUtils.shouldShowAvatar(
          isGroupMode: true,
          collapseSenderChrome: false,
        ),
        isTrue,
      );
    });
  });

  group('shouldReserveAvatarSpace', () {
    test('false in DM', () {
      expect(
        MessageUtils.shouldReserveAvatarSpace(
          isGroupMode: false,
          collapseSenderChrome: true,
        ),
        isFalse,
      );
    });

    test('true in group when collapsed', () {
      expect(
        MessageUtils.shouldReserveAvatarSpace(
          isGroupMode: true,
          collapseSenderChrome: true,
        ),
        isTrue,
      );
    });
  });
}
