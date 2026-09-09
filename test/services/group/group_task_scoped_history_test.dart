import 'package:flutter_test/flutter_test.dart';
import 'package:shepaw/models/group_task.dart';
import 'package:shepaw/models/message.dart';
import 'package:shepaw/services/group/group_member_history.dart';
import 'package:shepaw/services/group/group_orchestration_features.dart';
import 'package:shepaw/services/group/group_orchestration_metadata.dart';

Message _msg({
  required String id,
  required String content,
  required String fromId,
  String name = 'X',
  bool isAgent = true,
  Map<String, dynamic>? metadata,
}) {
  return Message(
    id: id,
    content: content,
    timestampMs: DateTime.now().millisecondsSinceEpoch,
    from: MessageFrom(
      id: fromId,
      type: isAgent ? 'agent' : 'user',
      name: name,
    ),
    type: MessageType.text,
    metadata: metadata,
  );
}

Map<String, dynamic> _orchMeta(String orchestrationId, {int? round}) {
  return GroupOrchestrationMetadata.stamp(
    orchestrationId: orchestrationId,
    orchestrationRound: round,
  );
}

void main() {
  group('GroupMemberHistory.filterMessagesForOrchestration', () {
    test('keeps only messages tagged with the current orchestration id', () {
      const taskA = 'task-a-user';
      const taskB = 'task-b-user';
      final messages = [
        _msg(
          id: taskA,
          content: 'first task',
          fromId: 'user',
          isAgent: false,
          name: 'U',
          metadata: _orchMeta(taskA),
        ),
        _msg(
          id: 'a-admin',
          content: 'admin on task a',
          fromId: 'admin',
          metadata: _orchMeta(taskA, round: 1),
        ),
        _msg(
          id: 'a-member',
          content: 'member on task a',
          fromId: 'coder',
          metadata: _orchMeta(taskA, round: 1),
        ),
        _msg(
          id: taskB,
          content: 'second task',
          fromId: 'user',
          isAgent: false,
          name: 'U',
          metadata: _orchMeta(taskB),
        ),
        _msg(
          id: 'b-admin',
          content: 'admin on task b',
          fromId: 'admin',
          metadata: _orchMeta(taskB, round: 1),
        ),
      ];

      final scoped = GroupMemberHistory.filterMessagesForOrchestration(
        messages: messages,
        orchestrationId: taskB,
      );

      expect(scoped.map((m) => m.id), [taskB, 'b-admin']);
    });

    test('legacy untagged replies after trigger belong to current task', () {
      const orchId = 'user-trigger';
      final messages = [
        _msg(
          id: 'old-member',
          content: 'prior task chatter',
          fromId: 'coder',
        ),
        _msg(
          id: orchId,
          content: 'new user ask',
          fromId: 'user',
          isAgent: false,
          name: 'U',
        ),
        _msg(
          id: 'legacy-admin',
          content: 'admin without metadata yet',
          fromId: 'admin',
        ),
      ];

      final scoped = GroupMemberHistory.filterMessagesForOrchestration(
        messages: messages,
        orchestrationId: orchId,
      );

      expect(scoped.map((m) => m.id), [orchId, 'legacy-admin']);
    });

    test('honors excludeMessageId', () {
      const orchId = 'user-msg';
      final messages = [
        _msg(
          id: orchId,
          content: 'trigger',
          fromId: 'user',
          isAgent: false,
          name: 'U',
          metadata: _orchMeta(orchId),
        ),
        _msg(
          id: 'admin-reply',
          content: 'reply',
          fromId: 'admin',
          metadata: _orchMeta(orchId),
        ),
      ];

      final scoped = GroupMemberHistory.filterMessagesForOrchestration(
        messages: messages,
        orchestrationId: orchId,
        excludeMessageId: orchId,
      );

      expect(scoped.map((m) => m.id), ['admin-reply']);
    });
  });

  group('GroupMemberHistory.loadTaskScopedHistory', () {
    tearDown(() {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.task;
      GroupOrchestrationFeatures.structuredTasks = true;
    });

    test('returns full history when scope is channel', () {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.channel;
      const taskA = 'task-a';
      const taskB = 'task-b';
      final messages = [
        _msg(
          id: taskA,
          content: 'a',
          fromId: 'user',
          isAgent: false,
          metadata: _orchMeta(taskA),
        ),
        _msg(
          id: taskB,
          content: 'b',
          fromId: 'user',
          isAgent: false,
          metadata: _orchMeta(taskB),
        ),
      ];

      final scoped = GroupMemberHistory.loadTaskScopedHistory(
        messages: messages,
        orchestrationId: taskB,
      );

      expect(scoped.length, 2);
    });

    test('filters when scope is task', () {
      GroupOrchestrationFeatures.adminHistoryScope =
          GroupAdminHistoryScope.task;
      const taskA = 'task-a';
      const taskB = 'task-b';
      final messages = [
        _msg(
          id: 'a-member',
          content: 'old member',
          fromId: 'coder',
          metadata: _orchMeta(taskA),
        ),
        _msg(
          id: taskB,
          content: 'new ask',
          fromId: 'user',
          isAgent: false,
          metadata: _orchMeta(taskB),
        ),
      ];

      final scoped = GroupMemberHistory.loadTaskScopedHistory(
        messages: messages,
        orchestrationId: taskB,
      );

      expect(scoped.map((m) => m.id), [taskB]);
    });
  });
}
