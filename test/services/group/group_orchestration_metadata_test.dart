import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_orchestration_metadata.dart';

void main() {
  group('GroupOrchestrationMetadata', () {
    test('stamp merges orchestration fields', () {
      final meta = GroupOrchestrationMetadata.stamp(
        base: {'foo': 1},
        orchestrationId: 'msg-abc',
        orchestrationRound: 2,
      );
      expect(meta['foo'], 1);
      expect(meta['orchestration_id'], 'msg-abc');
      expect(meta['orchestration_round'], 2);
    });

    test('readOrchestrationId ignores empty strings', () {
      expect(
        GroupOrchestrationMetadata.readOrchestrationId(
          {'orchestration_id': '  '},
        ),
        isNull,
      );
    });

    test('messageBelongsToTask uses metadata or triggering message id', () {
      expect(
        GroupOrchestrationMetadata.messageBelongsToTask(
          messageId: 'msg-1',
          metadata: {'orchestration_id': 'msg-1'},
          orchestrationId: 'msg-1',
        ),
        isTrue,
      );
      expect(
        GroupOrchestrationMetadata.messageBelongsToTask(
          messageId: 'msg-1',
          metadata: null,
          orchestrationId: 'msg-1',
        ),
        isTrue,
      );
      expect(
        GroupOrchestrationMetadata.messageBelongsToTask(
          messageId: 'reply-9',
          metadata: {'orchestration_id': 'msg-1'},
          orchestrationId: 'msg-1',
        ),
        isTrue,
      );
      expect(
        GroupOrchestrationMetadata.messageBelongsToTask(
          messageId: 'reply-9',
          metadata: {'orchestration_id': 'msg-2'},
          orchestrationId: 'msg-1',
        ),
        isFalse,
      );
    });
  });
}
