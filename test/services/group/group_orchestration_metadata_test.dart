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
  });
}
