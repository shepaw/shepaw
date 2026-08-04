import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/messaging/streaming_flush_helper.dart';
import 'package:shepaw/services/task/task_models.dart';

void main() {
  group('finalizeActiveDmTaskAsStopped content', () {
    test('uses streaming override when present', () {
      final content = buildPeerFinalContent(
        answerContent: 'partial reply',
        progressContent: '',
        accumulatedContent: 'partial reply',
        resultContent: '[Stopped]',
        wasCancelled: true,
      );
      expect(content, 'partial reply\n\n[Stopped]');
    });

    test('empty override falls back to accumulated then marker', () {
      final content = buildPeerFinalContent(
        answerContent: '',
        progressContent: '',
        accumulatedContent: 'from task',
        resultContent: '[Stopped]',
        wasCancelled: true,
      );
      expect(content, 'from task\n\n[Stopped]');
    });

    test('no content yields bare stopped marker', () {
      final content = buildPeerFinalContent(
        answerContent: '',
        progressContent: '',
        accumulatedContent: '',
        resultContent: '[Stopped]',
        wasCancelled: true,
      );
      expect(content, '[Stopped]');
    });
  });

  group('ActiveTask user-stop reattach guard', () {
    test('isComplete prevents getActiveTask-style lookup', () {
      final task = ActiveTask(
        taskId: 't1',
        agentId: 'a1',
        agentName: 'Agent',
        channelId: 'c1',
        userMessageId: 'm1',
        userId: 'user',
        userName: 'User',
      );
      expect(task.isComplete, isFalse);
      task.isComplete = true;
      task.recordInterruption('user_cancelled');
      expect(task.isComplete, isTrue);
      expect(task.interruptionReason, 'user_cancelled');
    });
  });
}
