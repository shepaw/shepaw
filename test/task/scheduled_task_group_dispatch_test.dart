import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/services/group/group_channel_busy_exception.dart';
import 'package:shepaw/task/helpers/scheduled_task_prompt.dart';
import 'package:shepaw/task/models/scheduled_task.dart';
import 'package:shepaw/task/services/scheduled_task_notifier.dart';

ScheduledTask _task({
  String description = '晨报',
  String instruction = '汇总昨日进度',
}) {
  return ScheduledTask(
    id: 't1',
    channelId: 'g1',
    taskType: ScheduledTask.typeOnce,
    description: description,
    status: ScheduledTask.statusActive,
    instruction: instruction,
    schedulePattern: '0',
    nextRunAt: 0,
    executionCount: 0,
    failureCount: 0,
    createdAt: 0,
    updatedAt: 0,
    createdBy: 'user',
    executionTarget: ScheduledTask.targetGroup,
    agentIds: const ['a1'],
  );
}

void main() {
  group('ScheduledTaskPrompt.groupUserContent', () {
    test('includes title, instruction, and automated-trigger note', () {
      final content = ScheduledTaskPrompt.groupUserContent(
        _task(),
        now: DateTime(2026, 8, 27, 9, 5),
      );
      expect(content, contains('⏰ 晨报（2026/08/27 09:05 自动触发）'));
      expect(content, contains('汇总昨日进度'));
      expect(content, contains('用户未必在线'));
      expect(content, contains('不要追问'));
    });

    test('falls back to 定时任务 when description is empty', () {
      final content = ScheduledTaskPrompt.groupUserContent(
        _task(description: '  '),
        now: DateTime(2026, 1, 1, 0, 0),
      );
      expect(content, contains('⏰ 定时任务（2026/01/01 00:00 自动触发）'));
    });
  });

  group('ScheduledTaskNotifier.channelIdFromPayload', () {
    test('parses scheduled_task payload', () {
      expect(
        ScheduledTaskNotifier.channelIdFromPayload('scheduled_task:abc'),
        'abc',
      );
    });

    test('rejects other payloads', () {
      expect(ScheduledTaskNotifier.channelIdFromPayload(null), isNull);
      expect(ScheduledTaskNotifier.channelIdFromPayload('approval:x:y'), isNull);
      expect(ScheduledTaskNotifier.channelIdFromPayload('scheduled_task:'), isNull);
    });
  });

  test('GroupChannelBusyException names the channel', () {
    expect(
      const GroupChannelBusyException('ch-9').toString(),
      contains('ch-9'),
    );
  });
}
