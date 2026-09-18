import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/utils/message_utils.dart';

Message _msg({
  required String id,
  required String senderId,
  required DateTime timestamp,
  String name = 'Alice',
  String senderType = 'agent',
}) {
  return Message.simple(
    id: id,
    channelId: 'ch',
    senderId: senderId,
    senderName: name,
    senderType: senderType,
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

  group('defaultExpandedGroupMessageId', () {
    test('returns last non-my collapsible message', () {
      final messages = [
        _msg(id: '1', senderId: 'agent-a', timestamp: t0, name: 'A'),
        _msg(
          id: '2',
          senderId: 'local-user',
          senderType: 'user',
          timestamp: t1,
          name: 'Me',
        ),
        _msg(id: '3', senderId: 'agent-b', timestamp: t1, name: 'B'),
      ];
      expect(
        MessageUtils.defaultExpandedGroupMessageId(messages),
        '3',
      );
    });

    test('returns null when latest message is from me', () {
      final messages = [
        _msg(id: '1', senderId: 'agent-a', timestamp: t0, name: 'A'),
        _msg(
          id: '2',
          senderId: 'local-user',
          senderType: 'user',
          timestamp: t1,
          name: 'Me',
        ),
      ];
      expect(MessageUtils.defaultExpandedGroupMessageId(messages), isNull);
    });

    test('skips system messages at the tail', () {
      final messages = [
        _msg(id: '1', senderId: 'agent-a', timestamp: t0, name: 'A'),
        Message.simple(
          id: 'sys',
          channelId: 'ch',
          senderId: 'system',
          senderName: 'System',
          content: 'joined',
          timestamp: t1,
          type: MessageType.system,
        ),
      ];
      expect(
        MessageUtils.defaultExpandedGroupMessageId(messages),
        '1',
      );
    });
  });
}
