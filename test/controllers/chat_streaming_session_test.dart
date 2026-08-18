import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_streaming_text.dart';
import 'package:shepaw/models/message.dart';

Message _msg(
  String id, {
  String content = '',
  Map<String, dynamic>? metadata,
  String senderId = 'a1',
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: 1,
    from: MessageFrom(id: senderId, type: 'agent', name: 'Agent'),
    to: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
    metadata: metadata,
  );
}

void main() {
  group('ChatStreamingSession.onClear', () {
    test('fires when an active session is cleared', () {
      final s = ChatStreamingSession();
      var calls = 0;
      s.onClear = () => calls++;

      s.begin('streaming_1');
      expect(s.isActive, isTrue);
      s.clear();

      expect(calls, 1);
      expect(s.isActive, isFalse);
      expect(s.content, '');
    });

    test('does not fire when clearing an already-inactive session', () {
      final s = ChatStreamingSession();
      var calls = 0;
      s.onClear = () => calls++;

      s.clear(); // 从未 begin
      expect(calls, 0);

      s.begin('streaming_1');
      s.clear();
      s.clear(); // 重复 clear 不重复触发
      expect(calls, 1);
    });

    test('begin after clear starts a fresh cycle that fires again', () {
      final s = ChatStreamingSession();
      var calls = 0;
      s.onClear = () => calls++;

      s.begin('streaming_1');
      s.append('hello');
      s.clear();
      s.begin('streaming_2');
      expect(s.content, '');
      s.clear();

      expect(calls, 2);
    });
  });

  group('ChatStreamingSession 自愈查找', () {
    test('applyContentTo 改指到同发送者的 flush 部分行', () {
      final s = ChatStreamingSession()..begin('streaming_1', fromId: 'a1');
      s.append('Hello');

      // 模拟回合中途 reload：占位 streaming_1 被 mergeDmStreamingPlaceholders
      // 折叠进 DB 的 flush 行 msg_p1（status: streaming），id 已改名。
      final messages = [
        _msg('user_1', content: 'hi'),
        _msg('msg_p1', content: 'Hel', metadata: {'status': 'streaming'}),
      ];
      final map = {for (final m in messages) m.id: m};

      final updated = s.applyContentTo(messages, map);
      expect(updated, isNotNull);
      expect(updated!.id, 'msg_p1');
      expect(updated.content, 'Hello');
      expect(s.messageId, 'msg_p1'); // 锚点已改指
      expect(map['streaming_1'], isNull); // 旧占位映射被清掉
      expect(map['msg_p1']!.content, 'Hello');

      // 后续 chunk 继续命中，不再静默丢弃
      s.append(' World');
      s.applyContentTo(messages, map);
      expect(messages.last.content, 'Hello World');
    });

    test('applyContentTo 回退到幸存的 streaming_* 占位', () {
      final s = ChatStreamingSession()..begin('streaming_1', fromId: 'a1');
      s.append('Hi');

      final messages = [
        _msg('user_1', content: 'hi'),
        _msg('streaming_9', content: ''),
      ];
      final map = {for (final m in messages) m.id: m};

      final updated = s.applyContentTo(messages, map);
      expect(updated?.id, 'streaming_9');
      expect(updated?.content, 'Hi');
      expect(s.messageId, 'streaming_9');
    });

    test('applyContentTo 无宿主时不改指、返回 null', () {
      final s = ChatStreamingSession()..begin('streaming_1', fromId: 'a1');
      s.append('Hi');

      final messages = [_msg('user_1', content: 'hi')];
      final map = {for (final m in messages) m.id: m};

      expect(s.applyContentTo(messages, map), isNull);
      expect(s.messageId, 'streaming_1');
    });

    test('applyMetadataTo 折叠后同样改指', () {
      final s = ChatStreamingSession()..begin('streaming_1', fromId: 'a1');
      final messages = [
        _msg('msg_p1', content: 'Hel', metadata: {'status': 'streaming'}),
      ];
      final map = {for (final m in messages) m.id: m};

      final updated =
          s.applyMetadataTo(messages, map, {'trace_id': 't1'});
      expect(updated?.id, 'msg_p1');
      expect(updated?.metadata?['trace_id'], 't1');
      expect(s.messageId, 'msg_p1');
    });

    test('repointAnchor 锚点仍在时不做任何事', () {
      final s = ChatStreamingSession()..begin('streaming_1');
      final messages = [_msg('streaming_1', content: 'x')];
      expect(s.repointAnchor(messages), isFalse);
      expect(s.messageId, 'streaming_1');
    });

    test('findStreamingHost 按 fromId 过滤发送者', () {
      final messages = [
        _msg('msg_b', content: 'b', metadata: {'status': 'streaming'}, senderId: 'a2'),
        _msg('msg_a', content: 'a', metadata: {'status': 'streaming'}, senderId: 'a1'),
      ];
      expect(
        ChatStreamingText.findStreamingHost(messages, fromId: 'a1')?.id,
        'msg_a',
      );
      expect(
        ChatStreamingText.findStreamingHost(messages)?.id,
        'msg_a', // 不传 fromId 时取最新的同发送者匹配
      );
    });

    test('findStreamingHost group 模式只匹配群聊/工作流占位', () {
      final messages = [
        _msg('db1', content: '', metadata: {'status': 'streaming'}),
        _msg('group_streaming_1', content: ''),
        _msg('streaming_1', content: ''), // DM 占位，群聊模式不应命中
      ];
      expect(
        ChatStreamingText.findStreamingHost(messages, fromId: 'a1', group: true)?.id,
        'group_streaming_1',
      );
      expect(
        ChatStreamingText.findStreamingHost(messages, fromId: 'a1')?.id,
        'streaming_1',
      );
    });
  });
}
