import '../../models/group_task.dart';
import '../../models/remote_agent.dart';
import '../../storage/group_workspace_service.dart';
import '../acp_agent_connection.dart';
import '../logger_service.dart';
import 'group_member_history.dart';
import 'group_artifact_registry.dart';
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
    Map<String, String> failedAgentReasons = const {},
  }) {
    if (failedAgentNames.contains(agentName)) {
      final reason = failedAgentReasons[agentName]?.trim();
      return GroupTaskMemberResult(
        agentId: agentId,
        agentName: agentName,
        round: round,
        taskStatus: GroupTaskMemberResult.statusFailed,
        summary: (reason != null && reason.isNotEmpty)
            ? reason
            : '执行失败或超时',
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
    final artifactUris = GroupMemberHistory.extractStoreUris(turn.content);
    summary = _appendArtifactHint(summary, artifactUris);

    return GroupTaskMemberResult(
      agentId: agentId,
      agentName: agentName,
      round: round,
      taskStatus: taskStatus,
      summary: summary,
      artifactUris: artifactUris,
    );
  }

  /// When summary is clipped, point admin at the first artifact URI.
  static String _appendArtifactHint(String summary, List<String> artifactUris) {
    if (artifactUris.isEmpty) return summary;
    final uri = artifactUris.first;
    if (summary.contains(uri)) return summary;
    return summary.isEmpty ? '见 $uri' : '$summary（全文见 $uri）';
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
    Map<String, String> failedAgentReasons = const {},
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks ||
        !GroupOrchestrationFeatures.structuredResults) {
      return null;
    }
    final byId = {for (final a in agents) a.id: a};
    GroupTaskResults? merged;
    try {
      final ws = GroupWorkspaceService.instance;
      // 先内存汇总全部成员，再一次性 bulk upsert，避免每成员整文件读改写。
      final entries = <GroupTaskMemberResult>[];
      for (final entry in turns.entries) {
        final agent = byId[entry.key];
        final member = fromTurnResult(
          agentId: entry.key,
          agentName: agent?.name ?? entry.key,
          turn: entry.value,
          round: round,
          failedAgentNames: failedAgentNames,
          stalledAgentNames: stalledAgentNames,
          failedAgentReasons: failedAgentReasons,
        );
        if (member == null) continue;
        entries.add(member);
      }
      merged = await ws.upsertTaskMemberResults(
        groupId: groupId,
        orchestrationId: orchestrationId,
        entries: entries,
      );
      if (merged != null) {
        await GroupArtifactRegistry.syncFromTaskOutcomes(
          groupId: groupId,
          orchestrationId: orchestrationId,
          results: merged,
        );
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
  ///
  /// Replays the same entry set as [persistFromTurns] on the orchestrating
  /// device, so the payload must carry `failed_agents`, `stalled_agents`, and
  /// per-member `applicable` (lossless mirror of the live write path).
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
    final stalled = (payload['stalled_agents'] as List?)
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
      final entries = <GroupTaskMemberResult>[];
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
          stalledAgentNames: stalled,
        );
        if (member == null) continue;
        final artifactUris = map['artifacts'] is List
            ? [
                for (final u in map['artifacts'] as List)
                  if (u is String && u.trim().isNotEmpty) u.trim(),
              ]
            : member.artifactUris;
        entries.add(GroupTaskMemberResult(
          agentId: member.agentId,
          agentName: member.agentName,
          round: member.round,
          taskStatus: member.taskStatus,
          summary: member.summary,
          artifactUris:
              artifactUris.isNotEmpty ? artifactUris : member.artifactUris,
          messageId: member.messageId,
          completedAt: member.completedAt,
        ));
      }

      // 崩溃恢复路径：live 设备在发 members_done 之前已由 persistFromTurns
      // 落盘本轮结果。若本次要写的条目都已存在，重放是冗余的，跳过整写
      // （省一次 results/task/index 三文件写）。
      // 按**成员**而非「整轮」判断：只要缺一个成员就补写，否则本轮只写了一
      // 部分时，整轮判定会把剩下成员永久挡在重放之外。
      if (entries.isNotEmpty) {
        final existing = await ws.readTaskResults(
          groupId: groupId,
          orchestrationId: orchestrationId,
        );
        if (existing != null &&
            entries.every((e) => existing.members.any(
                  (m) => m.agentId == e.agentId && m.round == e.round,
                ))) {
          return existing;
        }
      }
      merged = await ws.upsertTaskMemberResults(
        groupId: groupId,
        orchestrationId: orchestrationId,
        entries: entries,
      );
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
    // 与 GroupTaskStatusParser.displayInfo 共用同一 wire→枚举映射（#12）。
    final status = GroupTaskStatusParser.statusFromWire(raw);
    if (status == null) return null;
    final reason = map['task_status_reason']?.toString().trim();
    // Live persistFromTurns 依据 turn.taskStatusInfo?.applicable 决定是否落库
    // （[SKIP]/空回合 applicable=false 不落库）。payload 必须带出该标记，
    // 否则重放会把这些回合重建为默认 applicable=true 的 pending 条目。
    final applicable = map['applicable'];
    return GroupMemberTaskStatusInfo(
      status: status,
      reason: (reason != null && reason.isNotEmpty) ? reason : null,
      applicable: applicable is bool ? applicable : true,
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

    // 派发发生在轮次执行之前：传入的 `round` 是「正在执行的轮」，其成员
    // 结果在本轮成员完成之后才落盘（persistFromTurns 在成员回报后调用）。
    // 因此当该轮尚无回报时，回退到最近一个已完成轮（≤ round），否则第 2 轮
    // 起库里只有已完成轮条目、精确匹配会令「同轮完成情况」恒为空。
    var targetRound = round;
    if (round != null) {
      final completed = results.members
          .map((m) => m.round)
          .whereType<int>()
          .where((r) => r <= round)
          .toSet()
          .toList()
        ..sort();
      if (completed.isNotEmpty && !completed.contains(round)) {
        targetRound = completed.last;
      }
    }

    final lines = <String>[];
    for (final member in results.members) {
      if (member.agentId == selfAgentId) continue;
      if (targetRound != null &&
          member.round != null &&
          member.round != targetRound) {
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
    // 回退到上一轮时标题必须说清轮次——否则成员会把它当成「本轮已完成」。
    final heading = (targetRound != null && targetRound != round)
        ? '【上一轮完成情况（第 $targetRound 轮，本轮尚未回报）】'
        : '【同轮完成情况】';
    return '$heading\n$body';
  }

  static Future<String> loadAdminResultsBlock({
    required String groupId,
    required String orchestrationId,
    int? round,
    bool includePriorRound = true,
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
      return buildAdminResultsBlock(
        results,
        round: round,
        includePriorRound: includePriorRound,
      );
    } catch (_) {
      return '';
    }
  }

  /// Admin summarize block. When [round] is set, only injects that round (and
  /// optionally the immediately prior round for delta context) — not the full
  /// multi-round history that previously bloated every admin turn.
  static String buildAdminResultsBlock(
    GroupTaskResults? results, {
    int? round,
    bool includePriorRound = true,
  }) {
    if (results == null || results.members.isEmpty) return '';

    final filtered = _filterMembersForAdminView(
      results.members,
      round: round,
      includePriorRound: includePriorRound,
    );
    if (filtered.isEmpty) return '';

    final heading = round != null
        ? '【结构化成员结果（第 $round 轮${includePriorRound && round > 1 ? '与上轮' : ''}）】'
        : '【结构化成员结果（results.json）】';
    final lines = <String>[heading];
    for (final member in filtered) {
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

  /// Latest entry per agent, optionally scoped to [round] ± prior round.
  static List<GroupTaskMemberResult> _filterMembersForAdminView(
    List<GroupTaskMemberResult> members, {
    int? round,
    bool includePriorRound = true,
  }) {
    if (round == null) return members;

    final allowedRounds = <int>{round};
    if (includePriorRound && round > 1) allowedRounds.add(round - 1);

    final byAgent = <String, GroupTaskMemberResult>{};
    for (final member in members) {
      final r = member.round;
      if (r == null || !allowedRounds.contains(r)) continue;
      final prev = byAgent[member.agentId];
      if (prev == null || (prev.round ?? 0) <= (r)) {
        byAgent[member.agentId] = member;
      }
    }
    final out = byAgent.values.toList()
      ..sort((a, b) {
        final ar = a.round ?? 0;
        final br = b.round ?? 0;
        if (ar != br) return ar.compareTo(br);
        return a.agentName.compareTo(b.agentName);
      });
    return out;
  }

  static String _firstLineSummary(String text, int maxChars) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final line = trimmed.split('\n').first.trim();
    if (line.length <= maxChars) return line;
    return '${line.substring(0, maxChars)}…';
  }
}
