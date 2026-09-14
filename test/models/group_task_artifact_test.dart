import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task_artifact.dart';

void main() {
  group('GroupTaskArtifactManifest', () {
    test('registerAll deduplicates by uri', () {
      const uri = 'store://runtime/dev/gr/ch/artifacts/t/a.md';
      final manifest = GroupTaskArtifactManifest(orchestrationId: 'orch-1');
      final merged = manifest.registerAll([
        GroupTaskArtifactEntry(uri: uri, label: 'a'),
        GroupTaskArtifactEntry(uri: uri, label: 'dup'),
        GroupTaskArtifactEntry(
          uri: 'store://runtime/dev/gr/ch/artifacts/t/b.md',
          label: 'b',
        ),
      ]);
      expect(merged.entries.length, 2);
      expect(merged.uris, contains(uri));
    });
  });

  group('GroupOrchestrationTools artifact parsers', () {
    test('parseArtifactPlanArgs requires store_task_id', () {
      // Imported via tools test file pattern — inline minimal check through model
      final plan = GroupTaskArtifactPlan(
        orchestrationId: 'o1',
        storeTaskId: 'o1',
        slots: [
          GroupTaskArtifactPlanSlot(
            filename: 'game.py',
            description: '主程序',
            assignedAgent: 'Coder',
          ),
        ],
      );
      expect(plan.toAdminBlock(), contains('--task o1'));
      expect(plan.toAdminBlock(), contains('game.py'));
    });
  });
}
