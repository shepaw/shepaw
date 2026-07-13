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

  group('shouldCollapseSenderChrome', () {
    test('always false — consecutive group messages stay independent', () {
      final prev = _msg(id: '1', senderId: 'a', timestamp: t0);
      final curr = _msg(id: '2', senderId: 'a', timestamp: t1);
      expect(
        MessageUtils.shouldCollapseSenderChrome(
          isGroupMode: true,
          previousMessage: prev,
          currentMessage: curr,
          showDateSeparator: false,
        ),
        isFalse,
      );
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

    test('shown for others in group', () {
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

    test('shown in group for every message', () {
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
    test('false when chrome is not collapsed', () {
      expect(
        MessageUtils.shouldReserveAvatarSpace(
          isGroupMode: true,
          collapseSenderChrome: false,
        ),
        isFalse,
      );
    });
  });
}
