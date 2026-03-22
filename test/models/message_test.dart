import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';

void main() {
  group('MessageFrom Tests', () {
    test('fromJson should create MessageFrom correctly', () {
      final json = {'id': 'user-1', 'type': 'user', 'name': 'Alice'};
      final from = MessageFrom.fromJson(json);

      expect(from.id, 'user-1');
      expect(from.type, 'user');
      expect(from.name, 'Alice');
    });

    test('fromJson should handle missing fields with defaults', () {
      final from = MessageFrom.fromJson({});

      expect(from.id, '');
      expect(from.type, 'user');
      expect(from.name, '');
    });

    test('isAgent should return true for agent type', () {
      final from = MessageFrom(id: 'agent-1', type: 'agent', name: 'Bot');
      expect(from.isAgent, true);
      expect(from.isUser, false);
      expect(from.isSystem, false);
    });

    test('isUser should return true for user type', () {
      final from = MessageFrom(id: 'user-1', type: 'user', name: 'Alice');
      expect(from.isUser, true);
      expect(from.isAgent, false);
    });

    test('isSystem should return true when id is system', () {
      final from = MessageFrom(id: 'system', type: 'system', name: 'System');
      expect(from.isSystem, true);
    });
  });

  group('MessageType Tests', () {
    test('should contain all expected values', () {
      expect(MessageType.values, contains(MessageType.text));
      expect(MessageType.values, contains(MessageType.image));
      expect(MessageType.values, contains(MessageType.file));
      expect(MessageType.values, contains(MessageType.audio));
      expect(MessageType.values, contains(MessageType.system));
      expect(MessageType.values, contains(MessageType.permissionAudit));
      expect(MessageType.values.length, 6);
    });
  });

  group('Message Tests', () {
    late Message textMessage;
    late int nowMs;

    setUp(() {
      nowMs = DateTime.now().millisecondsSinceEpoch;
      textMessage = Message(
        id: 'msg-1',
        from: MessageFrom(id: 'user-1', type: 'user', name: 'Alice'),
        channelId: 'channel-1',
        type: MessageType.text,
        content: 'Hello, world!',
        timestampMs: nowMs,
      );
    });

    test('should create a message with required fields', () {
      expect(textMessage.id, 'msg-1');
      expect(textMessage.from.id, 'user-1');
      expect(textMessage.channelId, 'channel-1');
      expect(textMessage.type, MessageType.text);
      expect(textMessage.content, 'Hello, world!');
      expect(textMessage.timestampMs, nowMs);
    });

    test('should have null optional fields by default', () {
      expect(textMessage.to, isNull);
      expect(textMessage.replyTo, isNull);
      expect(textMessage.metadata, isNull);
    });

    test('backward compatibility: senderId and senderName', () {
      expect(textMessage.senderId, 'user-1');
      expect(textMessage.senderName, 'Alice');
    });

    test('timestamp should convert correctly', () {
      final dt = textMessage.timestamp;
      expect(dt.millisecondsSinceEpoch, nowMs);
      expect(textMessage.dateTime.millisecondsSinceEpoch, nowMs);
    });

    test('isSystemMessage should return false for user messages', () {
      expect(textMessage.isSystemMessage, false);
    });

    test('isSystemMessage should return true for system messages', () {
      final sysMsg = Message(
        id: 'sys-1',
        from: MessageFrom(id: 'system', type: 'system', name: 'System'),
        type: MessageType.system,
        content: 'User joined',
        timestampMs: nowMs,
      );
      expect(sysMsg.isSystemMessage, true);
    });

    group('timeString', () {
      test('should show HH:mm for today messages', () {
        final now = DateTime.now();
        final msg = Message(
          id: 'msg-t',
          from: MessageFrom(id: 'u', type: 'user', name: 'U'),
          type: MessageType.text,
          content: '',
          timestampMs: now.millisecondsSinceEpoch,
        );
        final ts = msg.timeString;
        // Should be in HH:mm format (no date prefix)
        expect(ts, matches(RegExp(r'^\d{2}:\d{2}$')));
      });

      test('should show M/D HH:mm for past day messages', () {
        final pastDate = DateTime.now().subtract(const Duration(days: 2));
        final msg = Message(
          id: 'msg-p',
          from: MessageFrom(id: 'u', type: 'user', name: 'U'),
          type: MessageType.text,
          content: '',
          timestampMs: pastDate.millisecondsSinceEpoch,
        );
        final ts = msg.timeString;
        // Should contain date prefix like "1/15 10:30"
        expect(ts, matches(RegExp(r'^\d{1,2}/\d{1,2} \d{2}:\d{2}$')));
      });
    });

    group('Message.simple factory', () {
      test('should create message via simple factory', () {
        final now = DateTime.now();
        final msg = Message.simple(
          id: 'simple-1',
          channelId: 'ch-1',
          senderId: 'user-2',
          senderName: 'Bob',
          senderType: 'user',
          content: 'Hi there',
          timestamp: now,
          type: MessageType.text,
          replyToId: 'msg-0',
          metadata: {'key': 'value'},
        );

        expect(msg.id, 'simple-1');
        expect(msg.channelId, 'ch-1');
        expect(msg.from.id, 'user-2');
        expect(msg.from.name, 'Bob');
        expect(msg.from.type, 'user');
        expect(msg.content, 'Hi there');
        expect(msg.timestampMs, now.millisecondsSinceEpoch);
        expect(msg.replyTo, 'msg-0');
        expect(msg.metadata, {'key': 'value'});
      });
    });

    group('JSON serialization', () {
      test('fromJson should parse text message', () {
        final json = {
          'id': 'msg-json-1',
          'from': {'id': 'agent-1', 'type': 'agent', 'name': 'Bot'},
          'channel_id': 'ch-1',
          'type': 'text',
          'content': 'Response text',
          'timestamp': 1700000000000,
          'metadata': {'reply_to': 'msg-0'},
        };

        final msg = Message.fromJson(json);

        expect(msg.id, 'msg-json-1');
        expect(msg.from.id, 'agent-1');
        expect(msg.from.isAgent, true);
        expect(msg.channelId, 'ch-1');
        expect(msg.type, MessageType.text);
        expect(msg.content, 'Response text');
        expect(msg.timestampMs, 1700000000000);
        expect(msg.replyTo, 'msg-0');
      });

      test('fromJson should parse all message types', () {
        final types = {
          'text': MessageType.text,
          'image': MessageType.image,
          'file': MessageType.file,
          'audio': MessageType.audio,
          'system': MessageType.system,
          'permission_audit': MessageType.permissionAudit,
          'unknown_type': MessageType.text, // defaults to text
        };

        for (final entry in types.entries) {
          final msg = Message.fromJson({
            'id': 'msg',
            'from': {'id': 'u', 'type': 'user', 'name': 'U'},
            'type': entry.key,
            'content': '',
            'timestamp': 0,
          });
          expect(msg.type, entry.value,
              reason: 'Type "${entry.key}" should map to ${entry.value}');
        }
      });

      test('fromJson should handle missing/null fields gracefully', () {
        final msg = Message.fromJson({});

        expect(msg.id, '');
        expect(msg.content, '');
        expect(msg.type, MessageType.text);
        expect(msg.timestampMs, 0);
        expect(msg.to, isNull);
        expect(msg.replyTo, isNull);
      });

      test('fromJson should parse to field', () {
        final json = {
          'id': 'msg-to',
          'from': {'id': 'u1', 'type': 'user', 'name': 'Alice'},
          'to': {'id': 'agent-1', 'type': 'agent', 'name': 'Bot'},
          'type': 'text',
          'content': 'Hello',
          'timestamp': 1700000000000,
        };

        final msg = Message.fromJson(json);
        expect(msg.to, isNotNull);
        expect(msg.to!.id, 'agent-1');
        expect(msg.to!.isAgent, true);
      });

      test('toJson should produce correct output', () {
        final msg = Message(
          id: 'msg-ser',
          from: MessageFrom(id: 'user-1', type: 'user', name: 'Alice'),
          to: MessageFrom(id: 'agent-1', type: 'agent', name: 'Bot'),
          channelId: 'ch-1',
          type: MessageType.image,
          content: 'image_url',
          timestampMs: 1700000000000,
          metadata: {'reply_to': 'msg-0', 'extra': 'data'},
        );

        final json = msg.toJson();

        expect(json['id'], 'msg-ser');
        expect(json['from']['id'], 'user-1');
        expect(json['from']['type'], 'user');
        expect(json['from']['name'], 'Alice');
        expect(json['to']['id'], 'agent-1');
        expect(json['to']['type'], 'agent');
        expect(json['channel_id'], 'ch-1');
        expect(json['type'], 'image');
        expect(json['content'], 'image_url');
        expect(json['timestamp'], 1700000000000);
        expect(json['metadata']['reply_to'], 'msg-0');
      });

      test('toJson should handle null to field', () {
        final msg = Message(
          id: 'msg-no-to',
          from: MessageFrom(id: 'u', type: 'user', name: 'U'),
          type: MessageType.text,
          content: '',
          timestampMs: 0,
        );

        final json = msg.toJson();
        expect(json['to'], isNull);
      });
    });
  });
}
