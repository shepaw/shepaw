import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/she_service.dart';

/// She 的 DM 工作流 playbook prompt 内容断言（纯字符串，无 DB）。
void main() {
  group('SheService.buildDmWorkflowPlaybookBlock', () {
    final block = SheService.buildDmWorkflowPlaybookBlock();

    test('restricts every step agent to exactly "She"', () {
      expect(block, contains('"She"'));
      expect(block, contains("Every step's `agent` MUST be exactly"));
    });

    test('instructs to end the turn after workflow create', () {
      expect(block, contains('pending_approval'));
      expect(block, contains('end your turn'));
    });

    test('marks dispatch / complete / fail as forbidden during DM flow', () {
      expect(block, contains('workflow dispatch` (group-only)'));
      expect(block, contains('do NOT call `workflow complete/fail`'));
      expect(
        block,
        contains('never call `workflow create/complete/fail/cancel` inside a step'),
      );
    });

    test('requires self-contained step instructions', () {
      expect(block, contains('self-contained'));
    });

    test('covers rejection feedback re-planning', () {
      expect(block, contains('rejects with feedback'));
      expect(block, contains('call `workflow create` again'));
    });

    test('documents status check command', () {
      expect(block, contains('shepaw workflow status'));
    });
  });
}
