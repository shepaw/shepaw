import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/task/task_models.dart';

ActiveTask _task() => ActiveTask(
      taskId: 't1',
      agentId: 'a1',
      agentName: 'Agent',
      channelId: 'c1',
      userMessageId: 'm1',
      userId: 'user',
      userName: 'User',
    );

void main() {
  group('ActiveTask.shouldFlush', () {
    test('empty content never flushes', () {
      final task = _task();
      expect(task.shouldFlush(flushIntervalMs: 0, contentThreshold: 1), isFalse);
    });

    test('flushes when content threshold is reached before first flush', () {
      final task = _task();
      task.accumulatedContent = 'x' * 500;
      expect(
        task.shouldFlush(flushIntervalMs: 60 * 1000, contentThreshold: 500),
        isTrue,
      );
    });

    test('flushes when interval is zero and content exists', () {
      final task = _task();
      task.accumulatedContent = 'hi';
      expect(
        task.shouldFlush(flushIntervalMs: 0, contentThreshold: 9999),
        isTrue,
      );
    });

    test('after recordFlush, needs new content or time again', () {
      final task = _task();
      task.accumulatedContent = 'hello world';
      task.recordFlush('partial-1');

      expect(task.partialMessageId, 'partial-1');
      expect(task.lastFlushedContentLength, 'hello world'.length);
      expect(
        task.shouldFlush(flushIntervalMs: 60 * 1000, contentThreshold: 500),
        isFalse,
      );

      task.accumulatedContent = '${task.accumulatedContent}${'y' * 500}';
      expect(
        task.shouldFlush(flushIntervalMs: 60 * 1000, contentThreshold: 500),
        isTrue,
      );
    });
  });

  group('ActiveTask.recordInterruption', () {
    test('marks interruption metadata', () {
      final task = _task();
      task.recordInterruption('user_cancelled');
      expect(task.isInterrupted, isTrue);
      expect(task.interruptionReason, 'user_cancelled');
      expect(task.interruptedAtMs, isNotNull);
    });
  });
}
