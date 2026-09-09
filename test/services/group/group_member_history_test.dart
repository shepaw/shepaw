import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/group/group_member_history.dart';

Message _msg({
  required String id,
  required String content,
  required String fromId,
  String name = 'X',
  bool isAgent = true,
  Map<String, dynamic>? metadata,
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: DateTime.now().millisecondsSinceEpoch,
    from: MessageFrom(
      id: fromId,
      type: isAgent ? 'agent' : 'user',
      name: name,
    ),
    type: MessageType.text,
    metadata: metadata,
  );
}

void main() {
  group('GroupHistoryContent.replayContent', () {
    test('uses message.content only, not metadata.progress_content', () {
      final m = _msg(
        id: 'm1',
        fromId: 'a1',
        content: 'Final answer.',
        metadata: {
          'progress_content': 'Step-by-step internal reasoning…',
          'collapsible': true,
        },
      );

      expect(GroupHistoryContent.replayContent(m), 'Final answer.');
      expect(
        GroupHistoryContent.replayContent(m),
        isNot(contains('internal reasoning')),
      );
    });

    test('GroupChatHistory default formatter omits progress_content', () {
      final selfId = 'a1';
      final rows = GroupChatHistory.toRoleMessages(
        messages: [
          _msg(
            id: 'm1',
            fromId: selfId,
            content: 'Done.',
            metadata: {'progress_content': 'thinking…'},
          ),
        ],
        selfAgentId: selfId,
      );

      expect(rows, hasLength(1));
      expect(rows.first['content'], 'Done.');
      expect(rows.first['content'], isNot(contains('thinking')));
    });
  });

  group('GroupMemberHistory.needsFullHistory', () {
    test('only admin and summarize/abort/close turns keep the full window', () {
      expect(
        GroupMemberHistory.needsFullHistory(
          isAdmin: true,
          isLoopSummarize: false,
          isAbortSummarize: false,
          isClosingSummary: false,
        ),
        isTrue,
      );
      expect(
        GroupMemberHistory.needsFullHistory(
          isAdmin: false,
          isLoopSummarize: true,
          isAbortSummarize: false,
          isClosingSummary: false,
        ),
        isTrue,
      );
      expect(
        GroupMemberHistory.needsFullHistory(
          isAdmin: false,
          isLoopSummarize: false,
          isAbortSummarize: true,
          isClosingSummary: false,
        ),
        isTrue,
      );
      expect(
        GroupMemberHistory.needsFullHistory(
          isAdmin: false,
          isLoopSummarize: false,
          isAbortSummarize: false,
          isClosingSummary: true,
        ),
        isTrue,
      );
      expect(
        GroupMemberHistory.needsFullHistory(
          isAdmin: false,
          isLoopSummarize: false,
          isAbortSummarize: false,
          isClosingSummary: false,
        ),
        isFalse,
      );
    });
  });

  group('GroupMemberHistory.buildPinSenderIds', () {
    test('merges user, siblings, and mentioners without self', () {
      expect(
        GroupMemberHistory.buildPinSenderIds(
          selfAgentId: 'coder',
          coAgentIds: ['coder', 'designer', 'qa'],
          extraPinSenderIds: ['user1', 'designer'],
        ),
        ['user1', 'designer', 'qa'],
      );
    });
  });

  group('GroupMemberHistory.pack', () {
    test('keeps a short conversation intact', () {
      final messages = [
        _msg(id: '1', content: 'hi', fromId: 'user', isAgent: false, name: 'U'),
        _msg(id: '2', content: 'hello', fromId: 'coder', name: 'Coder'),
      ];
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
      );
      expect(pack.kept.map((m) => m.id), ['1', '2']);
      expect(pack.dropped, isEmpty);
      expect(pack.rollupNote, isEmpty);
      expect(pack.artifactUriNote, isEmpty);
    });

    test('drops old turns beyond the recent tail and budget', () {
      final messages = List.generate(
        20,
        (i) => _msg(
          id: '$i',
          content: 'x' * 1000,
          fromId: i == 0 ? 'coder' : 'other',
          name: i == 0 ? 'Coder' : 'Other',
        ),
      );
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
        maxChars: 5000,
        keepRecentCount: 3,
        keepRecentChars: 3000,
        keepOwnCount: 1,
      );
      expect(pack.droppedAny, isTrue);
      expect(pack.kept.length, lessThan(messages.length));
      expect(pack.kept.last.id, '19');
      expect(
        pack.kept.fold<int>(0, (s, m) => s + m.content.length),
        lessThanOrEqualTo(5000),
      );
      expect(pack.rollupNote, contains('群消息已省略'));
    });

    test('pins the member\'s own older reply even when outside the recent tail',
        () {
      final messages = [
        _msg(
          id: 'own-old',
          content: 'I already wrote the parser',
          fromId: 'coder',
          name: 'Coder',
        ),
        ...List.generate(
          10,
          (i) => _msg(
            id: 'o$i',
            content: 'other $i',
            fromId: 'other',
            name: 'Other',
          ),
        ),
      ];
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
        maxChars: 4000,
        keepRecentCount: 3,
        keepRecentChars: 2000,
        keepOwnCount: 2,
      );
      expect(pack.kept.map((m) => m.id), contains('own-old'));
      expect(pack.kept.map((m) => m.id), contains('o9'));
    });

    test('lists store:// URIs from omitted messages only', () {
      final messages = [
        _msg(
          id: 'old',
          content: 'wrote store://workspaces/dev/a.md and store://files/dev/b.txt',
          fromId: 'other',
          name: 'Other',
        ),
        ...List.generate(
          8,
          (i) => _msg(
            id: 'r$i',
            content: i >= 5
                ? 'recent $i store://workspaces/dev/recent.md'
                : 'recent $i',
            fromId: 'other',
            name: 'Other',
          ),
        ),
      ];
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
        maxChars: 4000,
        keepRecentCount: 3,
        keepRecentChars: 2000,
        keepOwnCount: 0,
      );
      expect(pack.dropped.map((m) => m.id), contains('old'));
      expect(pack.artifactUriNote, contains('store://workspaces/dev/a.md'));
      expect(pack.artifactUriNote, contains('store://files/dev/b.txt'));
      expect(
        pack.artifactUriNote.contains('store://workspaces/dev/recent.md'),
        isFalse,
      );
    });

    test('pins co-dispatch sibling latest reply outside the recent tail', () {
      final messages = [
        _msg(
          id: 'sibling-old',
          content: 'I finished the schema draft',
          fromId: 'designer',
          name: 'Designer',
        ),
        ...List.generate(
          10,
          (i) => _msg(
            id: 'noise$i',
            content: 'noise $i',
            fromId: 'other',
            name: 'Other',
          ),
        ),
      ];
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
        maxChars: 4000,
        keepRecentCount: 3,
        keepRecentChars: 2000,
        keepOwnCount: 0,
        pinSenderIds: GroupMemberHistory.buildPinSenderIds(
          selfAgentId: 'coder',
          coAgentIds: ['designer'],
        ),
      );
      expect(pack.kept.map((m) => m.id), contains('sibling-old'));
    });

    test('pins the latest reply from a mentioner outside the recent tail', () {
      final messages = [
        _msg(
          id: 'mentioner-old',
          content: 'I need help with the API layer',
          fromId: 'helper',
          name: 'Helper',
        ),
        ...List.generate(
          10,
          (i) => _msg(
            id: 'noise$i',
            content: 'noise $i',
            fromId: 'other',
            name: 'Other',
          ),
        ),
      ];
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
        maxChars: 4000,
        keepRecentCount: 3,
        keepRecentChars: 2000,
        keepOwnCount: 0,
        pinSenderIds: ['helper'],
      );
      expect(pack.kept.map((m) => m.id), contains('mentioner-old'));
      expect(pack.kept.map((m) => m.id), contains('noise9'));
    });

    test('prefers dropping others before the member\'s own messages at budget',
        () {
      final messages = [
        _msg(id: 'own', content: 'mine' * 100, fromId: 'coder', name: 'Coder'),
        _msg(
          id: 'other',
          content: 'theirs' * 100,
          fromId: 'other',
          name: 'Other',
        ),
      ];
      final pack = GroupMemberHistory.pack(
        messages: messages,
        memberId: 'coder',
        maxChars: 450,
        keepRecentCount: 8,
        keepRecentChars: 6000,
        keepOwnCount: 6,
      );
      expect(pack.kept.map((m) => m.id), ['own']);
      expect(pack.dropped.map((m) => m.id), ['other']);
    });
  });

  group('GroupChatHistory.toRoleMessages', () {
    test('maps self turns to assistant and others to tagged user', () {
      final messages = [
        _msg(id: '1', content: 'hi', fromId: 'user', isAgent: false, name: 'U'),
        _msg(id: '2', content: 'hello', fromId: 'coder', name: 'Coder'),
        _msg(id: '3', content: 'next', fromId: 'other', name: 'Other'),
      ];
      final rows = GroupChatHistory.toRoleMessages(
        messages: messages,
        selfAgentId: 'coder',
      );
      expect(rows, [
        {'role': 'user', 'content': '[U(User)]: hi'},
        {'role': 'assistant', 'content': 'hello'},
        {'role': 'user', 'content': '[Other(Agent)]: next'},
      ]);
    });

    test('merges consecutive same-role turns and prefixes notes', () {
      final messages = [
        _msg(id: '1', content: 'a', fromId: 'user', isAgent: false, name: 'U'),
        _msg(id: '2', content: 'b', fromId: 'other', name: 'Other'),
        _msg(id: '3', content: 'c', fromId: 'coder', name: 'Coder'),
        _msg(id: '4', content: 'd', fromId: 'coder', name: 'Coder'),
      ];
      final rows = GroupChatHistory.toRoleMessages(
        messages: messages,
        selfAgentId: 'coder',
        truncationNote: '[省略 2 条]',
        earlierSummary: 'old plan',
      );
      expect(rows.length, 2);
      expect(rows[0]['role'], 'user');
      expect(rows[0]['content'], contains('[省略 2 条]'));
      expect(rows[0]['content'], contains('Earlier conversation summary'));
      expect(rows[0]['content'], contains('[U(User)]: a'));
      expect(rows[0]['content'], contains('[Other(Agent)]: b'));
      expect(rows[1], {'role': 'assistant', 'content': 'c\n\nd'});
    });
  });
}
