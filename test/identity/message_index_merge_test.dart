import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/identity/utils/message_index_merge.dart';

void main() {
  group('mergeChannelMessagesWithIndex', () {
    test('synthesizes row for index-only message', () {
      final merged = mergeChannelMessagesWithIndex(
        indexRows: [
          {
            'message_id': 'msg-1',
            'channel_id': 'ch-1',
            'wall_time': 1000,
            'preview': 'Hello preview',
            'sender_name': 'Alice',
            'has_attachment': 0,
          },
        ],
        messageRows: const [],
      );

      expect(merged, hasLength(1));
      expect(merged.first['id'], 'msg-1');
      expect(merged.first['content'], 'Hello preview');
      expect(merged.first['sender_name'], 'Alice');
    });

    test('prefers cached body over preview when content present', () {
      final merged = mergeChannelMessagesWithIndex(
        indexRows: [
          {
            'message_id': 'msg-1',
            'channel_id': 'ch-1',
            'wall_time': 1000,
            'preview': 'Preview',
            'sender_name': 'Alice',
            'has_attachment': 0,
          },
        ],
        messageRows: [
          {
            'id': 'msg-1',
            'channel_id': 'ch-1',
            'content': 'Full body',
            'sender_name': 'Alice',
            'created_at': '2024-01-01T00:00:00.000Z',
          },
        ],
      );

      expect(merged.first['content'], 'Full body');
    });

    test('uses preview when cached row has empty content', () {
      final merged = mergeChannelMessagesWithIndex(
        indexRows: [
          {
            'message_id': 'msg-1',
            'channel_id': 'ch-1',
            'wall_time': 1000,
            'preview': 'Preview only',
            'sender_name': 'Alice',
            'has_attachment': 0,
          },
        ],
        messageRows: [
          {
            'id': 'msg-1',
            'channel_id': 'ch-1',
            'content': '',
            'sender_name': 'Alice',
            'created_at': '2024-01-01T00:00:00.000Z',
          },
        ],
      );

      expect(merged.first['content'], 'Preview only');
    });

    test('preserves index ordering', () {
      final merged = mergeChannelMessagesWithIndex(
        indexRows: [
          {
            'message_id': 'msg-new',
            'channel_id': 'ch-1',
            'wall_time': 2000,
            'preview': 'New',
            'sender_name': 'A',
            'has_attachment': 0,
          },
          {
            'message_id': 'msg-old',
            'channel_id': 'ch-1',
            'wall_time': 1000,
            'preview': 'Old',
            'sender_name': 'B',
            'has_attachment': 0,
          },
        ],
        messageRows: const [],
      );

      expect(merged.map((r) => r['id']).toList(), ['msg-new', 'msg-old']);
    });
  });
}
