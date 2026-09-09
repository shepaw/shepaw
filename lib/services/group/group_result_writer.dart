import '../../models/group_task.dart';
import '../../models/remote_agent.dart';
import '../../storage/group_workspace_service.dart';
import '../acp_agent_connection.dart';
import '../logger_service.dart';
import 'group_member_history.dart';
import 'group_orchestration_features.dart';
import 'group_task_status.dart';
import 'group_turn_result.dart';

/// Writes structured member outcomes to `shared/tasks/<id>/results.json`.
class GroupResultWriter {
  GroupResultWriter._();

  static const maxSummaryChars = 240;
  static const maxPeerNoteChars = 1500;

  /// Build a [GroupTaskMemberResult] from one member turn (null = skip).
  static GroupTaskMemberResult? fromTurnResult({
    required String agentId,
    required String agentName,
    required GroupTurnResult turn,
    required int round,
    List<String> failedAgentNames = const [],
    List<String> stalledAgentNames = const [],
  }) {
    if (failedAgentNames.contains(agentName)) {
      return GroupTaskMemberResult(
        agentId: agentId,
        agentName: agentName,
        round: round,
        taskStatus: GroupTaskMemberResult.statusFailed,
        summary: '执行失败或超时',
      );
    }

    if (stalledAgentNames.contains(agentName)) {
      return GroupTaskMemberResult(
        agentId: agentId,
        agentName: agentName,
        round: round,
        taskStatus: GroupTaskMemberResult.statusStalled,
        summary: '超过 ${acpTaskTimeout.inMinutes} 分钟未响应',
      );
    }

    final info = turn.taskStatusInfo ?? GroupTaskStatusParser.parse(turn.content);
    if (!info.applicable) return null;

    final taskStatus = switch (info.status) {
      GroupMemberTaskStatus.done => GroupTaskMemberResult.statusDone,
      GroupMemberTaskStatus.pending => GroupTaskMemberResult.statusPending,
      GroupMemberTaskStatus.missing => GroupTaskMemberResult.statusPending,
    };

    final stripped = GroupTaskStatusParser.strip(turn.content);
    var summary = _firstLineSummary(stripped, maxSummaryChars);
    if (summary.isEmpty && info.reason != null && info.reason!.isNotEmpty) {
      summary = info.reason!.trim();
    }

    return GroupTaskMemberResult(
      agentId: agentId,
      agentName: agentName,
      round: round,
      taskStatus: taskStatus,
      summary: summary,
      artifactUris: GroupMemberHistory.extractStoreUris(turn.content),
    );
  }

  /// Upsert all member turns into `results.json`.
  static Future<GroupTaskResults?> persistFromTurns({
    required String groupId,
    required String orchestrationId,
    required Map<String, GroupTurnResult> turns,
    required List<RemoteAgent> agents,
    required int round,
    List<String> failedAgentNames = const [],
    List<String> stalledAgentNames = const [],
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks ||
        !GroupOrchestrationFeatures.structuredResults) {
      return null;
    }
    final byId = {for (final a in agents) a.id: a};
    GroupTaskResults? merged;
    try {
      final ws = GroupWorkspaceService.instance;
      for (final entry in turns.entries) {
        final agent = byId[entry.key];
        final member = fromTurnResult(
          agentId: entry.key,
          agentName: agent?.name ?? entry.key,
          turn: entry.value,
          round: round,
          failedAgentNames: failedAgentNames,
          stalledAgentNames: stalledAgentNames,
        );
        if (member == null) continue;
        merged = (await ws.upsertTaskMemberResult(
          groupId: groupId,
          orchestrationId: orchestrationId,
          memberResult: member,
        )) ??
            merged;
      }
    } catch (e) {
      LoggerService().debug(
        'persist task results failed: $groupId/$orchestrationId — $e',
        tag: 'GroupResultWriter',
      );
    }
    return merged;
  }

  /// Idempotent rebuild from a persisted `members_done` payload.
  static Future<GroupTaskResults?> persistFromMembersDonePayload({
    required String groupId,
    required String orchestrationId,
    required Map<String, dynamic> payload,
    required List<RemoteAgent> agents,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks ||
        !GroupOrchestrationFeatures.structuredResults) {
      return null;
    }
    final round = (payload['round'] as num?)?.toInt() ?? 0;
    final failed = (payload['failed_agents'] as List?)
            ?.map((e) => e.toString())
            .where((e) => e.trim().isNotEmpty)
            .toList() ??
        const <String>[];
    final raw = payload['member_results'];
    if (raw is! Map) return null;

    final byId = {for (final a in agents) a.id: a};
    final byName = {for (final a in agents) a.name: a};
    GroupTaskResults? merged;
    try {
      final ws = GroupWorkspaceService.instance;
      for (final entry in raw.entries) {
        final agentId = entry.key.toString();
        final value = entry.value;
        if (value is! Map) continue;
        final map = Map<String, dynamic>.from(value);
        final agent = byId[agentId] ?? byName[agentId];
        final name = agent?.name ?? agentId;
        final content = map['content']?.toString() ?? '';
        final turn = GroupTurnResult(
          content: content,
          taskStatusInfo: _statusInfoFromPayload(map),
        );
        final member = fromTurnResult(
          agentId: agent?.id ?? agentId,
          agentName: name,
          turn: turn,
          round: round,
          failedAgentNames: failed,
        );
        if (member == null) continue;
        final artifactUris = map['artifacts'] is List
            ? [
                for (final u in map['artifacts'] as List)
                  if (u is String && u.trim().isNotEmpty) u.trim(),
              ]
            : member.artifactUris;
        merged = (await ws.upsertTaskMemberResult(
          groupId: groupId,
          orchestrationId: orchestrationId,
          memberResult: GroupTaskMemberResult(
            agentId: member.agentId,
            agentName: member.agentName,
            round: member.round,
            taskStatus: member.taskStatus,
            summary: member.summary,
            artifactUris: artifactUris.isNotEmpty ? artifactUris : member.artifactUris,
            messageId: member.messageId,
            completedAt: member.completedAt,
          ),
        )) ??
            merged;
      }
    } catch (e) {
      LoggerService().debug(
        'persist members_done results failed: $groupId/$orchestrationId — $e',
        tag: 'GroupResultWriter',
      );
    }
    return merged;
  }

  static GroupMemberTaskStatusInfo? _statusInfoFromPayload(
    Map<String, dynamic> map,
  ) {
    final raw = map['task_status']?.toString();
    if (raw == null || raw.isEmpty) return null;
    final status = switch (raw) {
      'done' => GroupMemberTaskStatus.done,
      'pending' => GroupMemberTaskStatus.pending,
      'missing' => GroupMemberTaskStatus.missing,
      _ => null,
    };
    if (status == null) return null;
    final reason = map['task_status_reason']?.toString().trim();
    return GroupMemberTaskStatusInfo(
      status: status,
      reason: (reason != null && reason.isNotEmpty) ? reason : null,
    );
  }

  static Future<String> loadPeerResultsNote({
    required String groupId,
    required String orchestrationId,
    required String selfAgentId,
    int? round,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks ||
        !GroupOrchestrationFeatures.structuredResults) {
      return '';
    }
    try {
      final results = await GroupWorkspaceService.instance.readTaskResults(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      return buildPeerResultsNote(
        results: results,
        selfAgentId: selfAgentId,
        round: round,
      );
    } catch (_) {
      return '';
    }
  }

  /// Human-readable 【同轮完成情况】 block for member turns.
  static String buildPeerResultsNote({
    required GroupTaskResults? results,
    required String selfAgentId,
    int? round,
    int maxChars = maxPeerNoteChars,
  }) {
    if (results == null || results.members.isEmpty) return '';

    final lines = <String>[];
    for (final member in results.members) {
      if (member.agentId == selfAgentId) continue;
      if (round != null && member.round != null && member.round != round) {
        continue;
      }
      if (member.taskStatus != GroupTaskMemberResult.statusDone &&
          member.summary.isEmpty) {
        continue;
      }
      final summary = member.summary.isNotEmpty
          ? member.summary
          : member.taskStatus;
      lines.add('- ${member.agentName} (${member.taskStatus}): $summary');
    }
    if (lines.isEmpty) return '';

    var body = lines.join('\n');
    if (body.length > maxChars) {
      body = '${body.substring(0, maxChars)}…';
    }
    return '【同轮完成情况】\n$body';
  }

  static Future<String> loadAdminResultsBlock({
    required String groupId,
    required String orchestrationId,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks ||
        !GroupOrchestrationFeatures.structuredResults) {
      return '';
    }
    try {
      final results = await GroupWorkspaceService.instance.readTaskResults(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      return buildAdminResultsBlock(results);
    } catch (_) {
      return '';
    }
  }

  static String buildAdminResultsBlock(GroupTaskResults? results) {
    if (results == null || results.members.isEmpty) return '';
    final lines = <String>['【结构化成员结果（results.json）】'];
    for (final member in results.members) {
      final roundLabel =
          member.round != null ? '，第 ${member.round} 轮' : '';
      final summary =
          member.summary.isNotEmpty ? member.summary : '（无文字摘要）';
      lines.add(
        '- ${member.agentName} (${member.taskStatus}$roundLabel): $summary',
      );
      if (member.artifactUris.isNotEmpty) {
        lines.add('  ${member.artifactUris.join(' ')}');
      }
    }
    return '\n\n${lines.join('\n')}';
  }

  static String _firstLineSummary(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final line = trimmed.split('\n').first.trim();
    if (line.length <= maxChars) return line;
    return '${line.substring(0, maxChars)}…';
  }
}
