import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/she_service.dart';

/// She 的 DM 工作流 playbook prompt 内容断言（纯字符串，无 DB）。
void main() {
  group('SheService.buildDmWorkflowPlaybookBlock', () {
    final block = SheService.buildDmWorkflowPlaybookBlock();

    test('allows She and other exact agent names', () {
      expect(block, contains('"She"'));
      expect(block, contains('agents.list'));
      expect(block, contains('exact display name'));
      expect(block, isNot(contains("Every step's `agent` MUST be exactly")));
    });

    test('documents parallel same-stage different agents', () {
      expect(block, contains('same stage'));
      expect(block, contains('parallel'));
    });

    test('keeps standalone dispatch as an option', () {
      expect(block, contains('agents.dispatch'));
      expect(block, contains('independent of workflows'));
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
