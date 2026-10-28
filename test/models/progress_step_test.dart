import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/progress_step.dart';

void main() {
  group('ProgressStep', () {
    test('parses the host step shape', () {
      final steps = ProgressStep.parseList([
        {
          'id': 'th-1',
          'type': 'thought',
          'title': 'Thinking',
          'status': 'completed',
          'started_at': 1000,
          'ended_at': 4000,
          'body': '想一下',
        },
        {
          'id': 't1',
          'type': 'tool',
          'title': 'Bash',
          'tool_kind': 'execute',
          'summary': 'pnpm test',
          'status': 'failed',
        },
        {'id': 'omitted', 'type': 'tool', 'title': 'x', 'omitted': 7},
      ]);
      expect(steps, hasLength(3));
      expect(steps[0].type, ProgressStepType.thought);
      expect(steps[0].duration, const Duration(seconds: 3));
      expect(steps[0].hasBody, isTrue);
      expect(steps[1].status, ProgressStepStatus.failed);
      expect(steps[1].toolKind, 'execute');
      expect(steps[1].summary, 'pnpm test');
      expect(steps[2].omitted, 7);
    });

    test('skips malformed entries instead of failing the bubble', () {
      expect(ProgressStep.parseList(null), isEmpty);
      expect(ProgressStep.parseList('nope'), isEmpty);
      expect(
        ProgressStep.parseList([
          1,
          {'title': 'no id'},
          {'id': 'ok', 'title': 'Read'},
        ]).map((s) => s.id),
        ['ok'],
      );
    });
  });
}
