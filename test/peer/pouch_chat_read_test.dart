import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/peer/pouch_turn_relay.dart';

void main() {
  test('chat read payload keeps reply and message type', () {
    final encoded = PouchChatReadBody.encode(
      count: 2,
      messages: [
        Message(
          id: 'm1',
          from: MessageFrom(id: 'u', type: 'user', name: '我'),
          channelId: 'ch',
          type: MessageType.permissionAudit,
          content: 'audit',
          timestampMs: 10,
          replyTo: 'm0',
        ),
      ],
    );

    final decoded = PouchChatReadBody.decode(encoded);
    expect(decoded.count, 2);
    expect(decoded.messages, hasLength(1));
    expect(decoded.messages.single.type, MessageType.permissionAudit);
    expect(decoded.messages.single.replyTo, 'm0');
    expect(decoded.messages.single.content, 'audit');
    expect(decoded.messages.single.timestampMs, 10);
  });

  test('compact preview drops progress text without changing the message', () {
    final message = Message(
      id: 'm1',
      from: MessageFrom(id: 'a', type: 'agent', name: 'She'),
      channelId: 'ch',
      type: MessageType.text,
      content: '正文',
      timestampMs: 10,
      metadata: {
        'progress_content': '很长的思考过程',
        'collapsible': true,
      },
    );

    final encoded = PouchChatReadBody.encode(
      messages: [message],
      compact: true,
    );
    final wire = (encoded['messages'] as List).single as Map;
    final meta = wire['metadata'] as Map;
    expect(meta.containsKey('progress_content'), isFalse);
    expect(meta['collapsible'], isTrue);
    expect(message.metadata?['progress_content'], '很长的思考过程');

    final decoded = PouchChatReadBody.decode(encoded);
    expect(decoded.messages.single.content, '正文');
    expect(
      decoded.messages.single.metadata?.containsKey('progress_content'),
      isFalse,
    );
  });

  test('interaction response completes the waiting turn', () async {
    final pending = PouchInteractionWait.wait('i1');
    PouchInteractionWait.complete({
      'interaction_id': 'i1',
      'result': {'approved': true, 'action_id': 'allow'},
    });
    expect(await pending, {'approved': true, 'action_id': 'allow'});

    final missing = PouchInteractionWait.wait('i2');
    PouchInteractionWait.complete({'interaction_id': 'i2'});
    expect(await missing, isNull);
  });
}
