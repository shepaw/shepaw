import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_message_reconciler.dart';
import 'package:shepaw/models/message.dart';

Message _agent(
  String id, {
  required String agentId,
  String content = '',
  int ts = 1,
  Map<String, dynamic>? metadata,
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: ts,
    from: MessageFrom(id: agentId, type: 'agent', name: agentId),
    to: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
    metadata: metadata,
  );
}

Message _user(String id, {String content = 'hi', int ts = 1}) {
  return Message(
    id: id,
    content: content,
    timestampMs: ts,
    from: MessageFrom(id: 'u', type: 'user', name: 'U'),
    type: MessageType.text,
  );
}

void main() {
  group('ChatMessageReconciler.findReusableDmStreamingHost', () {
    test('prefers partialMessageId match', () {
      final partial = _agent(
        'partial_1',
        agentId: 'agent',
        content: 'Hello',
        metadata: {'status': 'streaming'},
      );
      final other = _agent(
        'partial_2',
        agentId: 'agent',
        content: 'Other',
        ts: 2,
        metadata: {'status': 'streaming'},
      );
      final found = ChatMessageReconciler.findReusableDmStreamingHost(
        messages: [partial, other],
        agentId: 'agent',
        partialMessageId: 'partial_1',
      );
      expect(found?.id, 'partial_1');
    });

    test('falls back to latest status=streaming for agent', () {
      final older = _agent(
        'p1',
        agentId: 'agent',
        content: 'a',
        ts: 1,
        metadata: {'status': 'streaming'},
      );
      final newer = _agent(
        'p2',
        agentId: 'agent',
        content: 'ab',
        ts: 2,
        metadata: {'status': 'streaming'},
      );
      final done = _agent('done', agentId: 'agent', content: 'old', ts: 0);
      final found = ChatMessageReconciler.findReusableDmStreamingHost(
        messages: [done, older, newer],
        agentId: 'agent',
        partialMessageId: null,
      );
      expect(found?.id, 'p2');
    });

    test('returns null when no streaming host', () {
      final found = ChatMessageReconciler.findReusableDmStreamingHost(
        messages: [_agent('done', agentId: 'agent', content: 'done')],
        agentId: 'agent',
      );
      expect(found, isNull);
    });
  });

  group('ChatMessageReconciler.mergeDmStreamingPlaceholders', () {
    test('returns db list when no streaming temps', () {
      final db = [_user('u1'), _agent('a1', agentId: 'agent')];
      final merged = ChatMessageReconciler.mergeDmStreamingPlaceholders(
        current: db,
        dbMessages: db,
      );
      expect(merged, same(db));
    });

    test('keeps visible streaming temp when DB has no agent row', () {
      final temp = _agent(
        'streaming_1',
        agentId: 'agent',
        content: 'partial',
        ts: 20,
      );
      final db = [_user('u1', ts: 10)];
      final merged = ChatMessageReconciler.mergeDmStreamingPlaceholders(
        current: [...db, temp],
        dbMessages: db,
      );
      expect(merged.map((m) => m.id), ['u1', 'streaming_1']);
    });

    test('fills empty DB shell with richer streaming content', () {
      final temp = _agent(
        'streaming_1',
        agentId: 'agent',
        content: 'Hello',
        ts: 30,
        metadata: {'progress_content': 'thinking'},
      );
      final shell = _agent(
        'db_shell',
        agentId: 'agent',
        content: '',
        ts: 25,
        metadata: {'status': 'streaming'},
      );
      final merged = ChatMessageReconciler.mergeDmStreamingPlaceholders(
        current: [_user('u1', ts: 10), temp],
        dbMessages: [_user('u1', ts: 10), shell],
      );
      final agent = merged.firstWhere((m) => m.id == 'db_shell');
      expect(agent.content, 'Hello');
      expect(agent.metadata?['progress_content'], 'thinking');
      expect(agent.metadata?['status'], 'streaming');
      expect(merged.any((m) => m.id == 'streaming_1'), isFalse);
    });

    test('folds live temp into flushed partial that already has text', () {
      final temp = _agent(
        'streaming_reattach_1',
        agentId: 'agent',
        content: 'Hello world',
        ts: 30,
      );
      final flushed = _agent(
        'partial_db',
        agentId: 'agent',
        content: 'Hello',
        ts: 25,
        metadata: {'status': 'streaming', 'is_partial': true},
      );
      final prior = _agent(
        'older_done',
        agentId: 'agent',
        content: 'previous turn',
        ts: 5,
      );
      final merged = ChatMessageReconciler.mergeDmStreamingPlaceholders(
        current: [_user('u1', ts: 10), prior, flushed, temp],
        dbMessages: [_user('u1', ts: 10), prior, flushed],
      );
      expect(merged.map((m) => m.id), ['older_done', 'u1', 'partial_db']);
      final host = merged.firstWhere((m) => m.id == 'partial_db');
      expect(host.content, 'Hello world');
      expect(host.metadata?['status'], 'streaming');
      expect(merged.any((m) => m.id.startsWith('streaming_')), isFalse);
    });

    test('ignores empty streaming temps', () {
      final temp = _agent('streaming_1', agentId: 'agent', content: '');
      final db = [_user('u1'), _agent('a1', agentId: 'agent', content: 'done')];
      final merged = ChatMessageReconciler.mergeDmStreamingPlaceholders(
        current: [...db, temp],
        dbMessages: db,
      );
      expect(merged.map((m) => m.id), ['u1', 'a1']);
    });
  });

  group('ChatMessageReconciler.reconcileGroupMessages', () {
    test('replaces with db when no temps', () {
      final db = [_user('u1'), _agent('a1', agentId: 'a')];
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [_user('old')],
        dbMessages: db,
      );
      expect(result.messages.map((m) => m.id), ['u1', 'a1']);
      expect(result.pendingKeyMigrations, isEmpty);
    });

    test('pass1 matches exact content and reports migration', () {
      final temp = _agent(
        'group_streaming_a_1',
        agentId: 'a',
        content: 'Answer',
        ts: 20,
      );
      final dbMsg = _agent('db1', agentId: 'a', content: 'Answer', ts: 21);
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [_user('temp_user_1', ts: 10), temp],
        dbMessages: [_user('u_db', content: 'hi', ts: 10), dbMsg],
      );
      expect(result.pendingKeyMigrations['group_streaming_a_1'], 'db1');
      expect(result.messages.any((m) => m.id == 'db1'), isTrue);
      expect(result.messages.any((m) => m.id == 'group_streaming_a_1'), isFalse);
    });

    test('pass2 matches unique sender when content differs', () {
      final temp = _agent(
        'group_streaming_a_1',
        agentId: 'a',
        content: 'Alpha: Answer',
        ts: 20,
      );
      final dbMsg = _agent('db1', agentId: 'a', content: 'Answer', ts: 21);
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [temp],
        dbMessages: [dbMsg],
      );
      expect(result.pendingKeyMigrations['group_streaming_a_1'], 'db1');
      expect(result.messages.single.id, 'db1');
    });

    test('keeps unmatched group_streaming with content when DB save missing', () {
      final temp = _agent(
        'group_streaming_a_1',
        agentId: 'a',
        content: 'only copy',
        ts: 20,
      );
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [_user('temp_user_1', ts: 10), temp],
        dbMessages: [_user('u_db', content: 'hi', ts: 10)],
      );
      expect(result.messages.any((m) => m.id == 'group_streaming_a_1'), isTrue);
      expect(result.messages.any((m) => m.id == 'temp_user_1'), isFalse);
    });

    test('drops empty unmatched temps', () {
      final temp = _agent(
        'group_streaming_a_1',
        agentId: 'a',
        content: '',
        ts: 20,
      );
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [temp],
        dbMessages: [_user('u_db', ts: 10)],
      );
      expect(result.messages.any((m) => m.id.startsWith('group_streaming_')), isFalse);
    });

    test('appends unmatched db rows', () {
      final temp = _agent(
        'group_streaming_a_1',
        agentId: 'a',
        content: 'x',
        ts: 20,
      );
      final dbMatched = _agent('db1', agentId: 'a', content: 'x', ts: 21);
      final dbExtra = _agent('db2', agentId: 'b', content: 'other', ts: 22);
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [temp],
        dbMessages: [dbMatched, dbExtra],
      );
      expect(result.messages.map((m) => m.id).toList(), ['db1', 'db2']);
    });

    test('keeps unresolved group_peer_approval host beside same-agent db row',
        () {
      final approvalHost = _agent(
        'group_peer_approval_cid1',
        agentId: 'peer-a',
        content: 'Allow shell?',
        ts: 20,
        metadata: {
          'action_confirmation': {
            'confirmation_id': 'cid1',
            'confirmation_context': 'peer',
            'prompt': 'Allow shell?',
            'actions': [
              {'id': 'allow', 'label': 'Allow'},
            ],
          },
        },
      );
      final dbReply = _agent(
        'db_peer_reply',
        agentId: 'peer-a',
        content: 'working…',
        ts: 21,
      );
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [approvalHost],
        dbMessages: [dbReply],
      );
      // Pass-2 adopts the host onto the DB row but must keep the card.
      final adopted = result.messages.firstWhere((m) => m.id == 'db_peer_reply');
      expect(
        adopted.metadata?['action_confirmation']?['confirmation_id'],
        'cid1',
      );
      expect(result.pendingKeyMigrations['group_peer_approval_cid1'], 'db_peer_reply');
    });

    test('drops resolved group_peer_approval host when same-agent db exists',
        () {
      final approvalHost = _agent(
        'group_peer_approval_cid2',
        agentId: 'peer-a',
        content: 'Allow shell?',
        ts: 20,
        metadata: {
          'action_confirmation': {
            'confirmation_id': 'cid2',
            'selected_action_id': 'allow',
          },
        },
      );
      final dbReply = _agent(
        'db_peer_reply',
        agentId: 'peer-a',
        content: 'done',
        ts: 21,
        metadata: {
          'action_confirmation': {
            'confirmation_id': 'cid2',
            'selected_action_id': 'allow',
          },
        },
      );
      final result = ChatMessageReconciler.reconcileGroupMessages(
        current: [approvalHost],
        dbMessages: [dbReply],
      );
      expect(
        result.messages.any((m) => m.id == 'group_peer_approval_cid2'),
        isFalse,
      );
      expect(
        result.messages
            .firstWhere((m) => m.id == 'db_peer_reply')
            .metadata?['action_confirmation']?['selected_action_id'],
        'allow',
      );
    });
  });

  group('ChatMessageReconciler.dbHasTurnReply', () {
    test('本回合 flush 行（时间戳在回合开始后）→ true', () {
      final db = [
        _agent(
          'old_partial',
          agentId: 'a1',
          content: 'old',
          ts: 5,
          metadata: {'status': 'streaming'},
        ),
        _agent(
          'msg_p1',
          agentId: 'a1',
          content: 'Hello',
          ts: 20,
          metadata: {'status': 'streaming'},
        ),
      ];
      expect(
        ChatMessageReconciler.dbHasTurnReply(
          dbMessages: db,
          turnBeganAtMs: 10,
        ),
        isTrue,
      );
    });

    test('只有回合开始前的旧 flush 行 → false', () {
      final db = [
        _agent(
          'old_partial',
          agentId: 'a1',
          content: 'old',
          ts: 5,
          metadata: {'status': 'streaming'},
        ),
      ];
      expect(
        ChatMessageReconciler.dbHasTurnReply(
          dbMessages: db,
          turnBeganAtMs: 10,
        ),
        isFalse,
      );
    });

    test('终态行（无 status: streaming）不算回复 → false', () {
      final db = [_agent('db_reply', agentId: 'a1', content: 'done', ts: 20)];
      expect(
        ChatMessageReconciler.dbHasTurnReply(
          dbMessages: db,
          turnBeganAtMs: 10,
        ),
        isFalse,
      );
    });

    test('用户消息不算回复 → false', () {
      final db = [_user('user_1', ts: 20)];
      expect(
        ChatMessageReconciler.dbHasTurnReply(
          dbMessages: db,
          turnBeganAtMs: 10,
        ),
        isFalse,
      );
    });

    test('回合开始时间为 null（无流式会话）→ false', () {
      final db = [
        _agent(
          'msg_p1',
          agentId: 'a1',
          content: 'Hello',
          ts: 20,
          metadata: {'status': 'streaming'},
        ),
      ];
      expect(
        ChatMessageReconciler.dbHasTurnReply(
          dbMessages: db,
          turnBeganAtMs: null,
        ),
        isFalse,
      );
    });
  });
}
