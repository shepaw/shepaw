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
