import '../../models/remote_agent.dart';
import 'group_turn_result.dart';

/// Parsed `[TASK_STATUS: …]` annotation from a group member reply.
enum GroupMemberTaskStatus {
  /// Member declared the task complete.
  done,

  /// Member declared the task unfinished (optionally with a reason).
  pending,

  /// Real reply with no parseable annotation.
  missing,
}

/// One member whose reply should block `group_finish(done)`.
class GroupPendingMember {
  final String agentId;
  final String name;
  final GroupMemberTaskStatus status;
  final String? reason;

  const GroupPendingMember({
    required this.agentId,
    required this.name,
    required this.status,
    this.reason,
  });

  String get display {
    if (status == GroupMemberTaskStatus.pending) {
      final r = reason?.trim();
      return (r != null && r.isNotEmpty) ? '$name（$r）' : '$name（pending）';
    }
    return '$name（未标注任务状态）';
  }
}

/// Pure parser for the member-facing `[TASK_STATUS: done|pending]` contract.
class GroupTaskStatusParser {
  GroupTaskStatusParser._();

  static const metadataStatusKey = 'task_status';
  static const metadataReasonKey = 'task_status_reason';

  static final RegExp _statusTag = RegExp(
    r'\[TASK_STATUS:\s*(done|pending)\s*\](?:\s*(?:原因|reason)\s*[:：]\s*(.*))?',
    caseSensitive: false,
  );

  /// Remove every `[TASK_STATUS]` annotation so bubbles / clipboard stay clean.
  static String strip(String content) {
    if (content.isEmpty || !_statusTag.hasMatch(content)) return content;
    var out = content.replaceAll(_statusTag, '');
    out = out.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out.trim();
  }

  /// Status to render on a member bubble. Prefers persisted metadata; falls
  /// back to a tag still sitting in [content] (streaming / older rows).
  ///
  /// Returns null when there is nothing to show: empty / `[SKIP]`, or a
  /// historical reply with neither metadata nor a tag (do not badge every
  /// pre-gate member message as unmarked).
  static GroupMemberTaskStatusInfo? displayInfo({
    required String content,
    Map<String, dynamic>? metadata,
  }) {
    final raw = metadata?[metadataStatusKey];
    if (raw is String) {
      final status = switch (raw) {
        'done' => GroupMemberTaskStatus.done,
        'pending' => GroupMemberTaskStatus.pending,
        'missing' => GroupMemberTaskStatus.missing,
        _ => null,
      };
      if (status != null) {
        final reason = metadata?[metadataReasonKey] as String?;
        final trimmed = reason?.trim();
        return GroupMemberTaskStatusInfo(
          status: status,
          reason: (trimmed != null && trimmed.isNotEmpty) ? trimmed : null,
        );
      }
    }
    final parsed = parse(content);
    if (!parsed.applicable) return null;
    if (parsed.status == GroupMemberTaskStatus.missing) return null;
    return parsed;
  }

  /// Parse the last `[TASK_STATUS]` tag in [content]. Empty / `[SKIP]` replies
  /// are not a status at all — callers should not treat them as blocking.
  static GroupMemberTaskStatusInfo parse(String content) {
    final trimmed = content.trim();
    if (trimmed.isEmpty || trimmed.contains('[SKIP]')) {
      return const GroupMemberTaskStatusInfo(
        status: GroupMemberTaskStatus.missing,
        applicable: false,
      );
    }
    GroupMemberTaskStatusInfo? last;
    for (final match in _statusTag.allMatches(trimmed)) {
      final kind = (match.group(1) ?? '').toLowerCase();
      final reason = match.group(2)?.trim();
      last = GroupMemberTaskStatusInfo(
        status: kind == 'pending'
            ? GroupMemberTaskStatus.pending
            : GroupMemberTaskStatus.done,
        reason: (reason != null && reason.isNotEmpty) ? reason : null,
        applicable: true,
      );
    }
    return last ??
        const GroupMemberTaskStatusInfo(
          status: GroupMemberTaskStatus.missing,
          applicable: true,
        );
  }

  /// Members whose replies must be handled before the admin may finish.
  ///
  /// Skipped / empty / failed-empty turns are ignored. A real reply that is
  /// `pending` or missing the annotation is blocking.
  static List<GroupPendingMember> blockingMembers({
    required Map<String, GroupTurnResult> turns,
    required List<RemoteAgent> agents,
  }) {
    final byId = {for (final a in agents) a.id: a};
    final out = <GroupPendingMember>[];
    for (final e in turns.entries) {
      final info = e.value.taskStatusInfo ?? parse(e.value.content);
      if (!info.applicable) continue;
      if (info.status == GroupMemberTaskStatus.done) continue;
      final agent = byId[e.key];
      out.add(GroupPendingMember(
        agentId: e.key,
        name: agent?.name ?? e.key,
        status: info.status,
        reason: e.value.taskStatusReason ?? info.reason,
      ));
    }
    return out;
  }

  static String adminNote(List<GroupPendingMember> pending) {
    if (pending.isEmpty) return '';
    final names = pending.map((p) => p.display).join('、');
    return '[SYSTEM] 以下成员本轮任务未完成，禁止调用 `group_finish`（action=`done`）：$names。'
        '请 `group_dispatch` 让他们补做，或 `group_finish`（action=`pause`）向用户说明并等待输入。';
  }

  static String nudgeSystemContent(List<GroupPendingMember> pending) {
    final names = pending.map((p) => p.display).join('、');
    return '[SYSTEM] 你刚刚试图结束编排，但以下成员任务仍未完成：$names。'
        '**禁止** `group_finish`（action=`done`）。请立刻 `group_dispatch` 重新派活，'
        '或 `group_finish`（action=`pause`）向用户澄清。';
  }

  static String exhaustedWarning(List<GroupPendingMember> pending) {
    final names = pending.map((p) => p.display).join('、');
    return '⚠️ 以下成员任务仍未完成，管理员已结束编排：$names。';
  }

  /// @-mention / all-agents paths have no admin finish gate — surface the
  /// same pending names so the user can follow up.
  static String mentionPathWarning(List<GroupPendingMember> pending) {
    if (pending.isEmpty) return '';
    final names = pending.map((p) => p.display).join('、');
    return '⚠️ 以下成员任务仍未完成：$names。可再次 @ 他们补做，或让管理员跟进。';
  }
}

class GroupMemberTaskStatusInfo {
  final GroupMemberTaskStatus status;
  final String? reason;

  /// False for empty / `[SKIP]` replies that are not real member output.
  final bool applicable;

  const GroupMemberTaskStatusInfo({
    required this.status,
    this.reason,
    this.applicable = true,
  });
}
