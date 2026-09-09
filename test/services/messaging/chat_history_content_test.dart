import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/messaging/chat_history_content.dart';
import 'package:shepaw/services/group/group_member_history.dart';

Message _msg({
  required String id,
  required String content,
  required String fromId,
  bool isAgent = true,
  Map<String, dynamic>? metadata,
  int timestampMs = 1700000000000,
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: timestampMs,
    from: MessageFrom(
      id: fromId,
      type: isAgent ? 'agent' : 'user',
      name: isAgent ? 'Agent' : 'User',
    ),
    type: MessageType.text,
    metadata: metadata,
  );
}

void main() {
  group('ChatHistoryContent', () {
    test('replayContent uses message.content only', () {
      final m = _msg(
        id: 'm1',
        fromId: 'a1',
        content: 'Answer.',
        metadata: {'progress_content': 'Internal reasoning…'},
      );

      expect(ChatHistoryContent.replayContent(m), 'Answer.');
      expect(ChatHistoryContent.replayContent(m), isNot(contains('reasoning')));
    });

    test('replayContentFormatted prefixes user rows when formatter given', () {
      final user = _msg(
        id: 'u1',
        fromId: 'u1',
        isAgent: false,
        content: 'Hello',
        metadata: {'progress_content': 'ignored'},
      );

      expect(
        ChatHistoryContent.replayContentFormatted(user),
        'Hello',
      );
      expect(
        ChatHistoryContent.replayContentFormatted(
          user,
          formatUserTimestamp: (_) => '2026-01-01 12:00:00',
        ),
        '[2026-01-01 12:00:00] Hello',
      );
    });

    test('GroupHistoryContent delegates to ChatHistoryContent', () {
      final m = _msg(
        id: 'm1',
        fromId: 'a1',
        content: 'Done.',
        metadata: {'progress_content': 'thinking…'},
      );

      expect(GroupHistoryContent.replayContent(m), 'Done.');
      expect(
        GroupHistoryContent.uiOnlyMetadataKeys,
        ChatHistoryContent.uiOnlyMetadataKeys,
      );
    });
  });
}
