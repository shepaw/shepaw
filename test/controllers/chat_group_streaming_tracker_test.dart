import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_group_streaming_tracker.dart';
import 'package:shepaw/controllers/group_mention_resolver.dart';
import 'package:shepaw/models/mention_entry.dart';
import 'package:shepaw/models/message.dart';

Message _msg(String id, {String content = '', Map<String, dynamic>? metadata}) {
  return Message(
    id: id,
    content: content,
    timestampMs: 1,
    from: MessageFrom(id: 'a1', type: 'agent', name: 'Alpha'),
    to: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
    metadata: metadata,
  );
}

void main() {
  group('ChatGroupStreamingTracker', () {
    test('begin / appendAndApply / finish lifecycle', () {
      final tracker = ChatGroupStreamingTracker();
      tracker.begin('a1', 'sid-1');
      expect(tracker.idFor('a1'), 'sid-1');

      final messages = [_msg('sid-1')];
      final map = <String, Message>{'sid-1': messages.first};

      tracker.appendAndApply('a1', 'Hi', messages, map);
      tracker.appendAndApply('a1', '!', messages, map);
      expect(messages.first.content, 'Hi!');
      expect(map['sid-1']?.content, 'Hi!');

      final finished = tracker.finish('a1');
      expect(finished, 'sid-1');
      expect(tracker.isEmpty, isTrue);
      expect(tracker.idFor('a1'), isNull);
    });

    test('appendAndApply preserves metadata', () {
      final tracker = ChatGroupStreamingTracker()..begin('a1', 'sid-1');
      final messages = [
        _msg('sid-1', metadata: {'progress_content': '…'}),
      ];
      final map = <String, Message>{'sid-1': messages.first};
      tracker.appendAndApply('a1', 'x', messages, map);
      expect(messages.first.metadata?['progress_content'], '…');
    });

    test('applyContent 自愈：占位被 reconcile 折叠进 DB 行后改指', () {
      final tracker = ChatGroupStreamingTracker()..begin('a1', 'group_streaming_1');
      var messages = [_msg('group_streaming_1')];
      var map = <String, Message>{'group_streaming_1': messages.first};
      tracker.appendAndApply('a1', 'Hi', messages, map);
      expect(messages.first.content, 'Hi');

      // 模拟回合中途 reconcileGroupMessages：占位折叠进 DB 行 db1
      // （id 改名、messageIdMap 重建），旧 sid 从 map 中消失。
      messages = [
        _msg('user_1', content: 'hi'),
        _msg('db1', content: 'Hi', metadata: {'status': 'streaming'}),
      ];
      map = {for (final m in messages) m.id: m};

      tracker.appendAndApply('a1', '!', messages, map);
      expect(messages.last.content, 'Hi!');
      expect(tracker.idFor('a1'), 'db1'); // sid 已改指
    });

    test('applyContent 无宿主存活时不改指、返回 null', () {
      final tracker = ChatGroupStreamingTracker()..begin('a1', 'group_streaming_1');
      tracker.append('a1', 'x');
      final messages = [_msg('user_1', content: 'hi')];
      final map = {for (final m in messages) m.id: m};

      expect(tracker.applyContent('a1', messages, map), isNull);
      expect(tracker.idFor('a1'), 'group_streaming_1');
    });

    test('putMetadataKey merges nested interaction payload', () {
      final messages = [_msg('sid-1', metadata: {'k': 1})];
      final map = <String, Message>{'sid-1': messages.first};
      ChatGroupStreamingTracker.putMetadataKey(
        'sid-1',
        'action_confirmation',
        {'confirmation_id': 'c1'},
        messages,
        map,
      );
      expect(messages.first.metadata?['k'], 1);
      expect(
        (messages.first.metadata?['action_confirmation'] as Map)['confirmation_id'],
        'c1',
      );
    });
  });

  group('GroupMentionResolver', () {
    const agents = [
      (id: 'a1', name: 'Alpha'),
      (id: 'a2', name: 'Beta'),
    ];

    test('structured notify mentions win over text', () {
      final ids = GroupMentionResolver.resolveAgentIds(
        content: '@Alpha please',
        mentions: const [
          MentionEntry(id: 'a2', name: 'Beta', notify: true),
          MentionEntry(id: 'a1', name: 'Alpha', notify: false),
        ],
        agents: agents,
      );
      expect(ids, ['a2']);
    });

    test('@all structured mention expands to every agent', () {
      final ids = GroupMentionResolver.resolveAgentIds(
        content: 'hi',
        mentions: const [
          MentionEntry(id: 'all', name: 'all', notify: true),
        ],
        agents: agents,
      );
      expect(ids, ['a1', 'a2']);
    });

    test('text fallback parses @name and @all', () {
      expect(
        GroupMentionResolver.parseFromContent('@Beta hello', agents),
        ['a2'],
      );
      expect(
        GroupMentionResolver.parseFromContent('hey @all', agents),
        ['a1', 'a2'],
      );
    });
  });
}
