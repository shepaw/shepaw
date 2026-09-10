import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';
import '../logger_service.dart';
import 'group_orchestration_features.dart';
import 'group_task_archive_builder.dart';

/// Best-effort hooks wiring group chat orchestration to shared/tasks storage.
class GroupTaskBootstrap {
  GroupTaskBootstrap._();

  static const sessionHandoffDoneTaskThreshold = 5;
  static const sessionHandoffMessageThreshold = 80;
  static const maxHandoffHintChars = 400;

  /// Idempotently create task.json when a user message starts orchestration.
  static Future<GroupTask?> ensureTaskForUserMessage({
    required String groupId,
    required String orchestrationId,
    required String sessionId,
    required String userGoal,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return null;
    try {
      return await GroupWorkspaceService.instance.ensureTask(
        groupId: groupId,
        orchestrationId: orchestrationId,
        sessionId: sessionId,
        userGoal: userGoal,
      );
    } catch (e, st) {
      LoggerService().error(
        'ensure group task failed: $groupId/$orchestrationId',
        tag: 'GroupTaskBootstrap',
        error: e,
        stackTrace: st,
      );
      return null;
    }
  }

  static Future<({bool ok, String? error, GroupTask? task})> publishPlan({
    required String groupId,
    required String orchestrationId,
    required String sessionId,
    required GroupTaskPlan plan,
    required String requirementText,
    String requirementNotes = '',
    String? issuedBy,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) {
      return (ok: false, error: 'structured tasks disabled', task: null);
    }
    try {
      final ws = GroupWorkspaceService.instance;
      await ws.ensureTask(
        groupId: groupId,
        orchestrationId: orchestrationId,
        sessionId: sessionId,
        userGoal: plan.goal,
      );
      await ws.writeTaskRequirement(
        groupId: groupId,
        orchestrationId: orchestrationId,
        content: requirementText.trim(),
      );
      final published = await ws.writeTaskPlan(
        groupId: groupId,
        plan: GroupTaskPlan(
          orchestrationId: plan.orchestrationId,
          goal: plan.goal,
          acceptanceCriteria: plan.acceptanceCriteria,
          constraints: plan.constraints,
          steps: plan.steps,
          issuedBy: issuedBy,
          issuedAt: plan.issuedAt,
        ),
        requirementNotes: requirementNotes,
      );
      if (published == null) {
        return (ok: false, error: 'failed to write task plan', task: null);
      }
      return (ok: true, error: null, task: published.task);
    } catch (e, st) {
      LoggerService().error(
        'publish group plan failed: $groupId/$orchestrationId',
        tag: 'GroupTaskBootstrap',
        error: e,
        stackTrace: st,
      );
      return (ok: false, error: e.toString(), task: null);
    }
  }

  static Future<void> onDispatchDecision({
    required String groupId,
    required String orchestrationId,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return;
    try {
      final task = await GroupWorkspaceService.instance.readTask(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (task == null) return;
      if (task.status == GroupTask.statusExecuting ||
          task.status == GroupTask.statusSummarizing ||
          task.status == GroupTask.statusDone) {
        return;
      }
      await GroupWorkspaceService.instance.updateTaskStatus(
        groupId: groupId,
        orchestrationId: orchestrationId,
        status: GroupTask.statusExecuting,
      );
    } catch (e) {
      LoggerService().debug(
        'group task dispatch status update failed: $e',
        tag: 'GroupTaskBootstrap',
      );
    }
  }

  static Future<void> onSummarizeRound({
    required String groupId,
    required String orchestrationId,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return;
    try {
      final task = await GroupWorkspaceService.instance.readTask(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (task == null || task.status == GroupTask.statusDone) return;
      await GroupWorkspaceService.instance.updateTaskStatus(
        groupId: groupId,
        orchestrationId: orchestrationId,
        status: GroupTask.statusSummarizing,
      );
    } catch (e) {
      LoggerService().debug(
        'group task summarize status update failed: $e',
        tag: 'GroupTaskBootstrap',
      );
    }
  }

  /// Writes full task archive, marks task done, and updates index.json.
  ///
  /// [status] is the orchestration terminal state carried by the `finish`
  /// event (`done`/`paused`/`failed`). Only `done` counts as a completed
  /// delivery; cancelled/aborted/maxRounds/budget-exhausted exits land as
  /// `paused` (or `failed` on exceptions) so they are not mistaken for
  /// finished work. Legacy payloads without the field fall back to `done`;
  /// unknown values fall back to `paused`.
  static Future<void> onFinish({
    required String groupId,
    required String orchestrationId,
    required String sessionId,
    required String finalSummary,
    List<String> artifactUris = const [],
    String? finalSummaryUri,
    int? rounds,
    String? status,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return;
    try {
      final ws = GroupWorkspaceService.instance;
      final existing = await ws.readTask(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (existing == null) return;

      final archiveContent = await GroupTaskArchiveBuilder.build(
        ws: ws,
        groupId: groupId,
        orchestrationId: orchestrationId,
        sessionId: sessionId,
        task: existing,
        finalSummary: finalSummary,
        artifactUris: artifactUris,
        rounds: rounds,
      );

      await ws.writeTaskArchive(
        groupId: groupId,
        orchestrationId: orchestrationId,
        content: archiveContent,
        finalSummaryUri: finalSummaryUri,
      );

      await ws.updateTaskStatus(
        groupId: groupId,
        orchestrationId: orchestrationId,
        status: _terminalStatus(status),
      );
    } catch (e, st) {
      LoggerService().error(
        'group task finish/archive failed: $groupId/$orchestrationId',
        tag: 'GroupTaskBootstrap',
        error: e,
        stackTrace: st,
      );
    }
  }

  /// Maps a `finish` payload `terminal_status` to a stored terminal state.
  ///
  /// `null`（旧 payload 根本没这个字段）回退 [GroupTask.statusDone] 以兼容
  /// 修复前的行为；**未知值回退 paused 而不是 done** —— 宁可按未完成处理，
  /// 也不把来源不明的终态算作已交付（否则等于把「不冒充 done」的修复又开
  /// 了个后门）。
  static String _terminalStatus(String? status) {
    if (status == null) return GroupTask.statusDone;
    switch (status) {
      case GroupTask.statusDone:
      case GroupTask.statusFailed:
      case GroupTask.statusPaused:
        return status;
      default:
        return GroupTask.statusPaused;
    }
  }

  /// Optional admin hint after many completed tasks in one session.
  static Future<String?> sessionHandoffHint({
    required String groupId,
    required int channelMessageCount,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks ||
        !GroupOrchestrationFeatures.sessionHandoffHint) {
      return null;
    }
    try {
      final index = await GroupWorkspaceService.instance.readTaskIndex(groupId);
      final doneCount = index.recent
          .where((e) => e.status == GroupTask.statusDone)
          .length;
      if (doneCount < sessionHandoffDoneTaskThreshold) return null;
      if (channelMessageCount < sessionHandoffMessageThreshold) return null;
      return '本群已完成 $doneCount 个结构化任务且频道消息较多。'
          '若上下文噪声影响协作，可调用 `group_session_create`（reason=`noise_reduction`）'
          ' 创建新 session 并携带 handoff。';
    } catch (_) {
      return null;
    }
  }

  /// Non-empty suffix for admin summarize / finish turns (includes leading `\n\n`).
  static Future<String> sessionHandoffSuffix({
    required String groupId,
    required int channelMessageCount,
  }) async {
    final hint = await sessionHandoffHint(
      groupId: groupId,
      channelMessageCount: channelMessageCount,
    );
    if (hint == null || hint.isEmpty) return '';
    return '\n\n$hint';
  }

  /// One-line archive excerpt for handoff / cross-task injection.
  static Future<String?> archiveExcerpt({
    required String groupId,
    required String orchestrationId,
    int maxChars = maxHandoffHintChars,
  }) async {
    final archive = await GroupWorkspaceService.instance.readTaskArchive(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (archive == null || archive.trim().isEmpty) return null;
    for (final line in archive.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
      if (trimmed.length <= maxChars) return trimmed;
      return '${trimmed.substring(0, maxChars)}…';
    }
    return null;
  }
}
