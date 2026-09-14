import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_orchestration_tools.dart';

void main() {
  group('GroupOrchestrationTools artifact tools', () {
    test('parseArtifactPlanArgs validates store_task_id', () {
      final missing = GroupOrchestrationTools.parseArtifactPlanArgs(
        {},
        orchestrationId: 'orch-1',
      );
      expect(missing.parseError, isNotNull);

      final ok = GroupOrchestrationTools.parseArtifactPlanArgs(
        {
          'store_task_id': 'orch-1',
          'notes': '统一目录',
          'slots': [
            {'filename': 'main.py', 'description': '入口'},
          ],
        },
        orchestrationId: 'orch-1',
      );
      expect(ok.parseError, isNull);
      expect(ok.storeTaskId, 'orch-1');
      expect(ok.slots.length, 1);
    });

    test('parseArtifactRegisterArgs requires valid store uris', () {
      final empty = GroupOrchestrationTools.parseArtifactRegisterArgs({});
      expect(empty.parseError, isNotNull);

      final ok = GroupOrchestrationTools.parseArtifactRegisterArgs({
        'artifacts': [
          {
            'uri': 'store://runtime/dev/gr/ch/artifacts/t/out.md',
            'label': '报告',
          },
        ],
      });
      expect(ok.parseError, isNull);
      expect(ok.entries.length, 1);
      expect(ok.entries.first.label, '报告');
    });
  });
}
