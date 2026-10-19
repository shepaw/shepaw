import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/messaging/local_llm_handler.dart';

void main() {
  group('LocalLLMHelpers.enrichHistoryContent', () {
    test('keeps fetch hint for store attachment', () {
      final m = Message(
        id: 'msg-1',
        from: MessageFrom(id: 'u', type: 'user', name: 'U'),
        type: MessageType.file,
        content: '📎 File: note.txt',
        timestampMs: 0,
        metadata: {
          'pouch_uri': 'pouch://files/note.txt',
          'name': 'note.txt',
        },
      );
      final enriched = LocalLLMHelpers.enrichHistoryContent(m, m.content);
      // History keeps only the message_id fetch hint; the store URI hint is
      // owned by the Hub now.
      expect(enriched, isNot(contains('[implicit]')));
      expect(enriched, contains('message_id=msg-1'));
      expect(enriched, contains('chat message get'));
    });

    test('text with pouch:// stays untouched', () {
      final m = Message(
        id: 'msg-2',
        from: MessageFrom(id: 'u', type: 'user', name: 'U'),
        type: MessageType.text,
        content: 'read pouch://files/a.txt please',
        timestampMs: 0,
      );
      final enriched = LocalLLMHelpers.enrichHistoryContent(m, m.content);
      expect(enriched, contains('pouch://files/a.txt'));
      expect(enriched, isNot(contains('[implicit]')));
      expect(enriched, isNot(contains('chat message get')));
    });
  });
}
