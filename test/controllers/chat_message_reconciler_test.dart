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
  });
}
