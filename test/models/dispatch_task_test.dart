import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/dispatch_task.dart';

void main() {
  group('DispatchTask model', () {
    const base = DispatchTask(
      id: 'dt-1',
      sourceChannelId: 'dm_she_user',
      targetAgentId: 'agent-1',
      targetAgentName: 'codebuddy',
      targetChannelId: 'dm_user_agent1',
      prompt: 'fix the bug in main.dart',
      status: DispatchTask.statusPending,
      createdAtMs: 1700000000000,
    );

    test('toJson/fromJson roundtrip preserves all fields', () {
      final full = base.copyWith(
        userMessageId: 'msg-1',
        statusMessageId: 'msg-2',
        status: DispatchTask.statusDone,
        resultSummary: 'done ok',
        errorMessage: null,
        completedAtMs: 1700000060000,
      );

      final restored = DispatchTask.fromJson(full.toJson());

      expect(restored.id, full.id);
      expect(restored.sourceChannelId, full.sourceChannelId);
      expect(restored.targetAgentId, full.targetAgentId);
      expect(restored.targetAgentName, full.targetAgentName);
      expect(restored.targetChannelId, full.targetChannelId);
      expect(restored.userMessageId, full.userMessageId);
      expect(restored.statusMessageId, full.statusMessageId);
      expect(restored.prompt, full.prompt);
      expect(restored.status, full.status);
      expect(restored.resultSummary, full.resultSummary);
      expect(restored.errorMessage, full.errorMessage);
      expect(restored.createdAtMs, full.createdAtMs);
      expect(restored.completedAtMs, full.completedAtMs);
    });

    test('isTerminal only for done/error/timeout', () {
      expect(base.copyWith(status: DispatchTask.statusPending).isTerminal, isFalse);
      expect(base.copyWith(status: DispatchTask.statusRunning).isTerminal, isFalse);
      expect(base.copyWith(status: DispatchTask.statusDone).isTerminal, isTrue);
      expect(base.copyWith(status: DispatchTask.statusError).isTerminal, isTrue);
      expect(base.copyWith(status: DispatchTask.statusTimeout).isTerminal, isTrue);
    });

    test('copyWith keeps untouched fields', () {
      final updated = base.copyWith(status: DispatchTask.statusRunning);
      expect(updated.status, DispatchTask.statusRunning);
      expect(updated.prompt, base.prompt);
      expect(updated.targetChannelId, base.targetChannelId);
      expect(updated.createdAtMs, base.createdAtMs);
      expect(updated.completedAtMs, isNull);
    });

    test('fromJson tolerates missing optional fields', () {
      final json = {
        'id': 'dt-2',
        'source_channel_id': 'c1',
        'target_agent_id': 'a1',
        'target_channel_id': 'c2',
        'prompt': 'p',
        'status': 'running',
        'created_at': 1,
      };
      final task = DispatchTask.fromJson(json);
      expect(task.targetAgentName, '');
      expect(task.userMessageId, isNull);
      expect(task.statusMessageId, isNull);
      expect(task.resultSummary, isNull);
      expect(task.completedAtMs, isNull);
    });
  });
}
