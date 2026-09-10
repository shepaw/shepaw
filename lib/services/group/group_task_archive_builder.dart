import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';

/// Builds the human-readable task archive (`shared/tasks/<id>/archive.md`).
class GroupTaskArchiveBuilder {
  GroupTaskArchiveBuilder._();

  static const maxRequirementChars = 12000;
  static const maxPlanChars = 8000;
  static const maxExecutionChars = 8000;

  static Future<String> build({
    required GroupWorkspaceService ws,
    required String groupId,
    required String orchestrationId,
    required String sessionId,
    required GroupTask task,
    required String finalSummary,
    List<String> artifactUris = const [],
    int? rounds,
  }) async {
    final buffer = StringBuffer()
      ..writeln('# 任务卷宗 ${task.orchestrationId}')
      ..writeln()
      ..writeln('## 定稿需求');

    final requirement = await ws.readTaskRequirement(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (requirement != null && requirement.trim().isNotEmpty) {
      buffer.writeln(_truncate(requirement.trim(), maxRequirementChars));
    } else {
      buffer.writeln(task.userGoal.trim());
    }

    buffer
      ..writeln()
      ..writeln('## 计划');
    buffer.writeln(await _planSection(
      ws: ws,
      groupId: groupId,
      orchestrationId: orchestrationId,
    ));

    buffer
      ..writeln()
      ..writeln('## 执行摘要');
    buffer.writeln(await _executionSection(
      ws: ws,
      groupId: groupId,
      sessionId: sessionId,
      orchestrationId: orchestrationId,
      rounds: rounds,
    ));

    buffer
      ..writeln()
      ..writeln('## 最终结论')
      ..writeln(finalSummary.trim());

    if (artifactUris.isNotEmpty) {
      buffer
        ..writeln()
        ..writeln('## 产物');
      for (final uri in artifactUris) {
        buffer.writeln('- $uri');
      }
    }

    return buffer.toString().trim();
  }

  static Future<String> _planSection({
    required GroupWorkspaceService ws,
    required String groupId,
    required String orchestrationId,
  }) async {
    final planMd = await ws.readTaskPlanMarkdown(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (planMd != null && planMd.trim().isNotEmpty) {
      return _truncate(planMd.trim(), maxPlanChars);
    }

    final planJson = await ws.readTaskPlanJson(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (planJson != null) {
      return _truncate(planJson.toMarkdown(), maxPlanChars);
    }

    return '（未发布正式计划）';
  }

  static Future<String> _executionSection({
    required GroupWorkspaceService ws,
    required String groupId,
    required String sessionId,
    required String orchestrationId,
    int? rounds,
  }) async {
    final parts = <String>[];

    final maxRound = rounds ?? await ws.latestOrchestrationRound(
      groupId: groupId,
      sessionId: sessionId,
    );
    if (maxRound != null && maxRound > 0) {
      for (var round = 1; round <= maxRound; round++) {
        final dispatch = await ws.readRoundDispatch(
          groupId: groupId,
          sessionId: sessionId,
          round: round,
        );
        if (!_matchesOrchestration(dispatch, orchestrationId)) continue;

        final steps = dispatch!['steps'];
        if (steps is List && steps.isNotEmpty) {
          final lines = <String>['### 第 $round 轮派发'];
          for (final raw in steps) {
            if (raw is! Map) continue;
            final agents = raw['agents'];
            final taskText = raw['task']?.toString().trim() ?? '';
            final agentLabel = agents is List
                ? agents.map((a) => a.toString()).join('、')
                : agents?.toString() ?? '';
            if (agentLabel.isEmpty && taskText.isEmpty) continue;
            lines.add('- $agentLabel: $taskText');
          }
          if (lines.length > 1) parts.add(lines.join('\n'));
        }

        final state = await ws.readRoundState(
          groupId: groupId,
          sessionId: sessionId,
          round: round,
        );
        // dispatch 已通过编排过滤，同一轮的 state 同属本任务，无需再次比对。
        if (state?['status'] == 'members_done') {
          final memberLines = _formatMembersDoneState(state!);
          if (memberLines.isNotEmpty) {
            parts.add('### 第 $round 轮成员回报\n$memberLines');
          }
        }
      }
    }

    final results = await ws.readTaskResults(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (results != null && results.members.isNotEmpty) {
      parts.add(_formatResults(results));
    }

    if (parts.isEmpty) {
      return '（无结构化执行记录）';
    }
    return _truncate(parts.join('\n\n'), maxExecutionChars);
  }

  static bool _matchesOrchestration(
    Map<String, dynamic>? payload,
    String orchestrationId,
  ) {
    if (payload == null) return false;
    final id = payload['orchestration_id']?.toString().trim();
    // 无编排标记的 legacy round 无法归属到任何具体任务，一律排除——否则会
    // 被织入当前任务的 archive.md，污染卷宗（任务级成员结果仍由
    // results.json 保证，见 _formatResults）。
    if (id == null || id.isEmpty) return false;
    return id == orchestrationId;
  }

  static String _formatMembersDoneState(Map<String, dynamic> state) {
    final raw = state['member_results'];
    if (raw is! Map) return '';
    final lines = <String>[];
    for (final entry in raw.entries) {
      final value = entry.value;
      if (value is! Map) continue;
      final status = value['task_status']?.toString().trim();
      final content = value['content']?.toString().trim() ?? '';
      final summary = content.length <= 200 ? content : '${content.substring(0, 200)}…';
      lines.add('- ${entry.key}${status != null ? ' ($status)' : ''}: $summary');
    }
    return lines.join('\n');
  }

  static String _formatResults(GroupTaskResults results) {
    final lines = <String>['### 结构化成员结果（results.json）'];
    for (final member in results.members) {
      final roundLabel = member.round != null ? '，第 ${member.round} 轮' : '';
      final summary = member.summary.isNotEmpty
          ? member.summary
          : '（无摘要）';
      lines.add('- ${member.agentName} (${member.taskStatus}$roundLabel): $summary');
      if (member.artifactUris.isNotEmpty) {
        lines.add('  产物: ${member.artifactUris.join('、')}');
      }
    }
    return lines.join('\n');
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }
}
