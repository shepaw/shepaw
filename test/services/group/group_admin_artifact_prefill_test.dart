import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_admin_artifact_prefill.dart';
import 'package:shepaw/services/group/group_result_writer.dart';

GroupTaskMemberResult _member({
  required String id,
  required String summary,
  List<String> uris = const [],
  int round = 1,
}) =>
    GroupTaskMemberResult(
      agentId: id,
      agentName: id,
      round: round,
      taskStatus: GroupTaskMemberResult.statusDone,
      summary: summary,
      artifactUris: uris,
    );

void main() {
  group('GroupAdminArtifactPrefill', () {
    test('needsPrefill when summary mentions 全文见', () {
      final m = _member(
        id: 'b',
        summary: '…（全文见 store://workspaces/dev/b.md）',
        uris: ['store://workspaces/dev/b.md'],
      );
      expect(GroupAdminArtifactPrefill.needsPrefillForTest(m), isTrue);
    });

    test('selectMembers prioritizes clipped summaries', () {
      final selected = GroupAdminArtifactPrefill.selectMembersForTest(
        [
          _member(
            id: 'a',
            summary:
                '已完成：链路正常、无阻断项、产物 URI 已在上方摘要中完整引用，管理员可直接采纳本段结论。',
            uris: ['store://workspaces/dev/a.md'],
          ),
          _member(
            id: 'b',
            summary:
                '${'x' * GroupResultWriter.maxSummaryChars}（全文见 store://workspaces/dev/b.md）',
            uris: ['store://workspaces/dev/b.md'],
          ),
        ],
        round: 1,
      );
      expect(selected.first.agentId, 'b');
    });

    test('selectMembers filters by round', () {
      final selected = GroupAdminArtifactPrefill.selectMembersForTest(
        [
          _member(
            id: 'a',
            summary: 'r1',
            uris: ['store://x'],
            round: 1,
          ),
          _member(
            id: 'b',
            summary: 'r2',
            uris: ['store://y'],
            round: 2,
          ),
        ],
        round: 2,
      );
      expect(selected, hasLength(1));
      expect(selected.single.agentId, 'b');
    });
  });
}
