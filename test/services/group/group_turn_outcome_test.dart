import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_turn_outcome.dart';

void main() {
  group('GroupTurnOutcome.classifyFailure', () {
    test('beforeStream when streaming has not started', () {
      expect(
        GroupTurnOutcome.classifyFailure(
          streamingStarted: false,
          responseBuffer: StringBuffer('partial'),
        ),
        GroupTurnFailurePhase.beforeStream,
      );
    });

    test('beforeStream when started but buffer is still empty', () {
      expect(
        GroupTurnOutcome.classifyFailure(
          streamingStarted: true,
          responseBuffer: StringBuffer(),
        ),
        GroupTurnFailurePhase.beforeStream,
      );
    });

    test('midStream when started with buffered bytes', () {
      expect(
        GroupTurnOutcome.classifyFailure(
          streamingStarted: true,
          responseBuffer: StringBuffer('hello'),
        ),
        GroupTurnFailurePhase.midStream,
      );
    });
  });

  group('GroupTurnOutcome.failureNotice', () {
    test('pre-stream copy', () {
      expect(
        GroupTurnOutcome.failureNotice(
          agentName: 'Coder',
          error: 'timeout',
          phase: GroupTurnFailurePhase.beforeStream,
        ),
        '⚠️ Agent「Coder」调用失败：timeout',
      );
    });

    test('mid-stream copy', () {
      expect(
        GroupTurnOutcome.failureNotice(
          agentName: 'Coder',
          error: 'socket',
          phase: GroupTurnFailurePhase.midStream,
        ),
        '⚠️ Agent「Coder」输出被中断：socket',
      );
    });
  });
}
