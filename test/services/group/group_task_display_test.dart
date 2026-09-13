import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/services/group/group_task_display.dart';

void main() {
  group('GroupTaskDisplay.title', () {
    test('keeps a short goal unchanged', () {
      expect(
        GroupTaskDisplay.title('帮我写一个简版的数独小游戏'),
        '帮我写一个简版的数独小游戏',
      );
    });

    test('strips leading mentions and takes the first sentence', () {
      expect(
        GroupTaskDisplay.title(
          '@She @Claude 帮我写一个简版的数独小游戏。要求能在终端里玩，还要有提示。',
        ),
        '帮我写一个简版的数独小游戏。',
      );
    });

    test('collapses whitespace and truncates long text', () {
      final title = GroupTaskDisplay.title(
        '帮我把这段非常非常长的需求整理成可执行计划\n并且附带验收标准以及约束条件以及后续迭代安排',
        maxChars: 16,
      );
      expect(title.endsWith('…'), isTrue);
      expect(title.length <= 17, isTrue);
    });

    test('falls back when goal is empty', () {
      expect(GroupTaskDisplay.title('   ', fallback: 'orch-1'), 'orch-1');
    });
  });

  group('GroupTaskDisplay.artifactUris', () {
    test('collects member artifacts and skips task record files', () {
      final results = GroupTaskResults(
        orchestrationId: 'orch-1',
        members: [
          GroupTaskMemberResult(
            agentId: 'a1',
            agentName: 'Writer',
            taskStatus: GroupTaskMemberResult.statusDone,
            artifactUris: [
              'store://runtime/0123456789abcdef/owner/ch/artifacts/t/game.py',
            ],
          ),
        ],
      );
      final archive = '''
# 任务卷宗 orch-1
- store://workspaces/0123456789abcdef/group_x/shared/tasks/orch-1/archive.md
- store://runtime/0123456789abcdef/owner/ch/artifacts/t/readme.md
''';
      final uris = GroupTaskDisplay.artifactUris(
        results: results,
        archive: archive,
      );
      expect(
        uris,
        [
          'store://runtime/0123456789abcdef/owner/ch/artifacts/t/game.py',
          'store://runtime/0123456789abcdef/owner/ch/artifacts/t/readme.md',
        ],
      );
    });

    test('dedupes the same uri from results and archive', () {
      const uri =
          'store://runtime/0123456789abcdef/owner/ch/artifacts/t/out.md';
      final results = GroupTaskResults(
        orchestrationId: 'orch-1',
        members: [
          GroupTaskMemberResult(
            agentId: 'a1',
            agentName: 'Writer',
            taskStatus: GroupTaskMemberResult.statusDone,
            artifactUris: [uri],
          ),
        ],
      );
      expect(
        GroupTaskDisplay.artifactUris(results: results, archive: '- $uri'),
        [uri],
      );
    });
  });

  group('GroupTaskDisplay.artifactLabel', () {
    test('uses the filename segment', () {
      expect(
        GroupTaskDisplay.artifactLabel(
          'store://runtime/0123456789abcdef/owner/ch/artifacts/t/game.py',
        ),
        'game.py',
      );
    });
  });
}
