import 'dart:convert';
import 'package:uuid/uuid.dart';
import '../../models/planning_models.dart';
import '../local_database_service.dart';

/// Helpers for plan-mode message persistence and task status parsing.
class PlanningHelpers {
  final LocalDatabaseService _db;
  final Uuid _uuid;
  final void Function(String channelId) notifyChannelUpdate;

  PlanningHelpers({
    required LocalDatabaseService db,
    required Uuid uuid,
    required this.notifyChannelUpdate,
  })  : _db = db,
        _uuid = uuid;

  /// Strip [PLAN]...[/PLAN] from the last Admin message in the DB.
  /// Returns the message ID of the stripped message, or null if not found.
  Future<String?> stripPlanBlockFromLastMessage(String channelId, String agentId) async {
    final db = await _db.database;
    final results = await db.query(
      'messages',
      where: 'channel_id = ? AND sender_id = ?',
      whereArgs: [channelId, agentId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    final row = results.first;
    final msgId = row['id'] as String?;
    final rawContent = row['content'] as String? ?? '';
    final stripped = ExecutionPlan.stripPlanBlock(rawContent);
    if (stripped != rawContent) {
      await _db.updateMessage(messageId: row['id'] as String, content: stripped);
    }
    return msgId;
  }

  /// Strip [FLOW_PLAN]...[/FLOW_PLAN] from the last Admin message.
  Future<String?> stripFlowPlanBlockFromLastMessage(String channelId, String agentId) async {
    final db = await _db.database;
    final results = await db.query(
      'messages',
      where: 'channel_id = ? AND sender_id = ?',
      whereArgs: [channelId, agentId],
      orderBy: 'created_at DESC',
      limit: 1,
    );
    if (results.isEmpty) return null;
    final row = results.first;
    final msgId = row['id'] as String?;
    final rawContent = row['content'] as String? ?? '';
    final stripped = FlowPlan.stripFlowPlanBlock(rawContent);
    if (stripped != rawContent) {
      await _db.updateMessage(messageId: row['id'] as String, content: stripped);
    }
    return msgId;
  }

  /// Inject the approved plan as a system message visible to Admin.
  Future<void> injectApprovedPlanContext(
    String channelId,
    ExecutionPlan plan,
    // ignore: unused_element
    dynamic adminAgent,
  ) async {
    final msgId = _uuid.v4();
    final planJson = const JsonEncoder.withIndent('  ').convert(plan.toJson());
    await _db.createMessage(
      id: msgId,
      channelId: channelId,
      senderId: 'system',
      senderType: 'system',
      senderName: 'System',
      content: '[SYSTEM] 用户已批准以下执行计划，请按计划开始执行：\n\n$planJson\n\n'
          '执行时请在回复末尾用 [TASK_START:id]、[TASK_DONE:id]、[TASK_FAIL:id] 标记任务状态。',
      messageType: 'system',
    );
    await _db.markMessageAsRead(msgId);
  }

  /// Inject user plan feedback as a system message, triggering Admin revision.
  Future<void> injectPlanReviseContext(
    String channelId,
    String userId,
    String userName,
    String feedback,
    // ignore: unused_element
    dynamic adminAgent,
  ) async {
    final msgId = _uuid.v4();
    await _db.createMessage(
      id: msgId,
      channelId: channelId,
      senderId: userId,
      senderType: 'user',
      senderName: userName,
      content: '[计划修改意见] $feedback',
      messageType: 'text',
    );
    await _db.markMessageAsRead(msgId);
    notifyChannelUpdate(channelId);
  }

  /// Create a task board system message in the channel.
  Future<void> createTaskBoardMessage(
    String channelId,
    String msgId,
    ExecutionPlan plan,
  ) async {
    await _db.createMessage(
      id: msgId,
      channelId: channelId,
      senderId: 'task_board',
      senderType: 'agent',
      senderName: 'TaskBoard',
      content: '任务执行进度',
      messageType: 'task_board',
      metadata: {'task_board': plan.toJson()},
    );
    await _db.markMessageAsRead(msgId);
  }

  /// Update the task board message metadata with updated plan state.
  Future<void> updateTaskBoardMessage(
    String channelId,
    String msgId,
    ExecutionPlan plan,
  ) async {
    await _db.updateMessageMetadata(msgId, {'task_board': plan.toJson()});
  }

  /// Parse [TASK_START:id], [TASK_DONE:id], [TASK_FAIL:id] markers from Admin response.
  Map<String, TaskStatus> parseTaskStatusUpdates(String text) {
    final result = <String, TaskStatus>{};
    final startRe = RegExp(r'\[TASK_START:([^\]]+)\]', caseSensitive: false);
    final doneRe = RegExp(r'\[TASK_DONE:([^\]]+)\]', caseSensitive: false);
    final failRe = RegExp(r'\[TASK_FAIL:([^\]]+)\]', caseSensitive: false);
    for (final m in startRe.allMatches(text)) {
      result[m.group(1)!.trim()] = TaskStatus.inProgress;
    }
    for (final m in doneRe.allMatches(text)) {
      result[m.group(1)!.trim()] = TaskStatus.done;
    }
    for (final m in failRe.allMatches(text)) {
      result[m.group(1)!.trim()] = TaskStatus.failed;
    }
    return result;
  }

  /// Apply user modifications from approval result (skipped tasks, etc.).
  ExecutionPlan applyUserModifications(ExecutionPlan plan, Map<String, dynamic> approvalResult) {
    final skippedIds = (approvalResult['skipped_task_ids'] as List?)
            ?.map((e) => e.toString())
            .toSet() ??
        {};
    if (skippedIds.isEmpty) return plan;
    for (final task in plan.tasks) {
      if (skippedIds.contains(task.id)) {
        task.status = TaskStatus.skipped;
      }
    }
    return plan;
  }
}
