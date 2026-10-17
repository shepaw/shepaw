import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/controllers/chat_message_reconciler.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/approval/cli_audit_fold.dart';
import 'package:shepaw/services/messaging/chat_history_content.dart';

Message _msg({
  required String id,
  required String fromId,
  required String fromType,
  int timestampMs = 1,
  String content = '',
  Map<String, dynamic>? metadata,
}) {
  return Message(
    id: id,
    from: MessageFrom(id: fromId, type: fromType, name: fromId),
    type: MessageType.text,
    content: content,
    timestampMs: timestampMs,
    metadata: metadata,
  );
}

Map<String, dynamic> _pending(String id, String tool, Map<String, dynamic> flags) {
  return {
    'confirmation_id': id,
    'confirmation_context': 'cli',
    'tool_name': tool,
    'flags': flags,
  };
}

void main() {
  test('foldDecided appends tool and params and drops the card', () {
    final folded = CliAuditFold.foldDecided({
      'action_confirmation': {
        ..._pending('c1', 'store.read', {'path': 'notes/a.md'}),
        'selected_action_id': 'allow',
      },
      'keep': true,
    });

    expect(folded.containsKey('action_confirmation'), isFalse);
    expect(folded['keep'], isTrue);
    expect(folded[CliAuditFold.hostFlag], isNot(true));
    final audit = CliAuditFold.read(folded);
    expect(audit, hasLength(1));
    expect(audit.single['tool_name'], 'store.read');
    expect(audit.single['decision'], 'allow');
    expect(audit.single['params'], {'path': 'notes/a.md'});
  });

  test('second fold appends and does not duplicate an id', () {
    final once = CliAuditFold.foldDecided({
      CliAuditFold.hostFlag: true,
      'action_confirmation': {
        ..._pending('c1', 'store.read', {'path': 'a'}),
        'selected_action_id': 'allow',
      },
    });
    final twice = CliAuditFold.foldDecided({
      ...once,
      'action_confirmation': {
        ..._pending('c1', 'store.read', {'path': 'a'}),
        'selected_action_id': 'allow',
      },
    });
    final third = CliAuditFold.foldDecided({
      ...twice,
      'action_confirmation': {
        ..._pending('c2', 'os.shell', {'command': 'ls'}),
        'selected_action_id': 'deny',
      },
    });

    final audit = CliAuditFold.read(third);
    expect(audit.map((e) => e['confirmation_id']), ['c1', 'c2']);
    expect(audit.last['decision'], 'deny');
    expect(
      third[ChatHistoryContent.historyExcludeMetaKey],
      isTrue,
    );
  });

  test('undecided card is left in place', () {
    final meta = {
      'action_confirmation': _pending('c1', 'store.read', {'path': 'a'}),
    };
    final folded = CliAuditFold.foldDecided(meta);
    expect(folded['action_confirmation'], isA<Map>());
    expect(CliAuditFold.read(folded), isEmpty);
  });

  test('attachPending reuses a decided host and refuses a busy one', () {
    final host = CliAuditFold.attachPending(
      metadata: const {},
      actionData: _pending('c1', 'store.read', {'path': 'a'}),
    )!;
    expect(CliAuditFold.isHost(host), isTrue);

    expect(
      CliAuditFold.attachPending(
        metadata: host,
        actionData: _pending('c2', 'store.write', {'path': 'b'}),
      ),
      isNull,
    );

    final decided = CliAuditFold.foldDecided({
      ...host,
      'action_confirmation': {
        ..._pending('c1', 'store.read', {'path': 'a'}),
        'selected_action_id': 'allow_session',
      },
    });
    final next = CliAuditFold.attachPending(
      metadata: decided,
      actionData: _pending('c2', 'store.write', {'path': 'b', 'content': 'hi'}),
    )!;

    expect(next['action_confirmation']['confirmation_id'], 'c2');
    expect(CliAuditFold.read(next).single['decision'], 'allow');
    expect(
      CliAuditFold.formatParams(
        Map<String, dynamic>.from(
          (next['action_confirmation'] as Map)['flags'] as Map,
        ),
      ),
      'path: b\ncontent: hi',
    );
  });

  test('findHost stays inside the current turn', () {
    final older = _msg(
      id: 'old',
      fromId: 'she',
      fromType: 'agent',
      timestampMs: 1,
      metadata: {CliAuditFold.hostFlag: true},
    );
    final user = _msg(
      id: 'u',
      fromId: 'me',
      fromType: 'user',
      timestampMs: 2,
      content: 'go',
    );
    final reply = _msg(
      id: 'reply',
      fromId: 'she',
      fromType: 'agent',
      timestampMs: 3,
      content: 'working',
    );

    expect(CliAuditFold.findHost([older, user, reply], 'she'), isNull);

    final current = _msg(
      id: 'audit',
      fromId: 'she',
      fromType: 'agent',
      timestampMs: 4,
      metadata: {CliAuditFold.hostFlag: true, CliAuditFold.metadataKey: []},
    );
    expect(
      CliAuditFold.findHost([older, user, reply, current], 'she')?.id,
      'audit',
    );
  });

  test('formatParams truncates long values', () {
    final text = CliAuditFold.formatParams(
      {'command': 'x' * 500},
      maxValueChars: 10,
    );
    expect(text, 'command: xxxxxxxxxx…');
  });

  test('reviewed audit bubble stays visible with empty content', () {
    final message = _msg(
      id: 'audit',
      fromId: 'she',
      fromType: 'agent',
      metadata: {
        CliAuditFold.hostFlag: true,
        CliAuditFold.metadataKey: [
          {
            'confirmation_id': 'c1',
            'tool_name': 'store.read',
            'params': {'path': 'a'},
            'decision': 'allow',
          },
        ],
      },
    );
    expect(ChatMessageReconciler.hasVisibleAgentContent(message), isTrue);
    expect(ChatMessageReconciler.hasVisibleTempContent(message), isTrue);
  });
}
