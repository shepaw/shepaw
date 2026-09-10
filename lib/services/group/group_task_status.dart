import '../../models/remote_agent.dart';
import 'group_member_stall.dart';
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

/// Member flagged `[NEED_ADMIN]` inside a pending reason — mid-loop admin wake.
class MemberAdminWakeRequest {
  final String agentId;
  final String name;
  final String? reason;

  const MemberAdminWakeRequest({
    required this.agentId,
    required this.name,
    this.reason,
  });
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

  /// Members put this in pending reason to wake admin before summarize (PR-8).
  static const needAdminTag = '[NEED_ADMIN]';

  static final RegExp _statusTag = RegExp(
    r'\[TASK_STATUS:\s*(done|pending)\s*\](?:\s*(?:原因|reason)\s*[:：]\s*(.*))?',
    caseSensitive: false,
  );

  /// One-entry memo for [strip]: bubble builds re-run this on the full
  /// accumulated text every streaming chunk.
  static String? _stripMemoInput;
  static String? _stripMemoOutput;

  /// Remove every `[TASK_STATUS]` annotation so bubbles / clipboard stay clean.
  static String strip(String content) {
    if (identical(_stripMemoInput, content) && _stripMemoOutput != null) {
      return _stripMemoOutput!;
    }
    final out = _stripUnmemoed(content);
    _stripMemoInput = content;
    _stripMemoOutput = out;
    return out;
  }

  static String _stripUnmemoed(String content) {
    if (content.isEmpty || !_statusTag.hasMatch(content)) return content;
    var out = content.replaceAll(_statusTag, '');
    out = out.replaceAll(RegExp(r'[ \t]+\n'), '\n');
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out.trim();
  }

  /// Wire 字符串 → 枚举（`done`/`pending`/`missing`，其余为 null）。
  ///
  /// 单一事实源：本类 `displayInfo`（metadata 侧）与 `GroupResultWriter` 的
  /// members_done 重放共用同一映射，避免两处内联漂移（#12）。
  static GroupMemberTaskStatus? statusFromWire(String raw) {
    return switch (raw) {
      'done' => GroupMemberTaskStatus.done,
      'pending' => GroupMemberTaskStatus.pending,
      'missing' => GroupMemberTaskStatus.missing,
      _ => null,
    };
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
      final status = statusFromWire(raw);
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

  /// Whether [info] requests a mid-loop admin decision (pending + [NEED_ADMIN]).
  static bool requestsAdminWake(GroupMemberTaskStatusInfo info) {
    if (!info.applicable || info.status != GroupMemberTaskStatus.pending) {
      return false;
    }
    final reason = info.reason?.trim() ?? '';
    return reason.contains(needAdminTag);
  }

  /// Members whose pending reason contains [needAdminTag].
  static List<MemberAdminWakeRequest> membersNeedingAdminWake({
    required Map<String, GroupTurnResult> turns,
    required List<RemoteAgent> agents,
  }) {
    final byId = {for (final a in agents) a.id: a};
    final out = <MemberAdminWakeRequest>[];
    for (final e in turns.entries) {
      final info = e.value.taskStatusInfo ?? parse(e.value.content);
      if (!requestsAdminWake(info)) continue;
      final agent = byId[e.key];
      out.add(MemberAdminWakeRequest(
        agentId: e.key,
        name: agent?.name ?? e.key,
        reason: e.value.taskStatusReason ?? info.reason,
      ));
    }
    return out;
  }

  static String adminStalledFollowUpNote(List<MemberStallRequest> requests) {
    if (requests.isEmpty) return '';
    final lines = requests.map((r) {
      final timeoutLabel = _formatTimeout(r.timeout);
      return '- ${r.name}：超过 $timeoutLabel 未响应'
          '${r.stallCount > 1 ? '（第 ${r.stallCount} 次超时）' : ''}';
    }).join('\n');
    return '[SYSTEM] 以下成员执行超时（stalled），需要你 **mid-loop** 跟进（不必等到 summarize）：\n'
        '$lines\n'
        '请在群内 @ 相关成员询问进度，或 `group_dispatch` 换人/缩小 scope；'
        '若仍无响应且已多次超时，系统会将该成员标为 failed。';
  }

  static String _formatTimeout(Duration timeout) {
    if (timeout.inMinutes >= 1) {
      return '${timeout.inMinutes} 分钟';
    }
    return '${timeout.inSeconds} 秒';
  }

  static String adminPendingWakeNote(List<MemberAdminWakeRequest> requests) {
    if (requests.isEmpty) return '';
    final lines = requests.map((r) {
      var detail = (r.reason ?? '').trim();
      if (detail.startsWith(needAdminTag)) {
        detail = detail.substring(needAdminTag.length).trim();
      }
      detail = detail.replaceFirst(RegExp(r'^[：:\s-]+'), '').trim();
      return detail.isEmpty
          ? '- ${r.name}：请求管理员决策'
          : '- ${r.name}：$detail';
    }).join('\n');
    return '[SYSTEM] 以下成员在 pending 原因中标记了 $needAdminTag，需要你 **mid-loop** 决策（不必等到 summarize）：\n'
        '$lines\n'
        '请结合任务 plan / 成员回复：`group_dispatch` 带决策 re-dispatch；'
        '能直接答复成员则 dispatch 补充 brief；无法决断则 `group_finish`（pause）或在回复中使用 `[ASK_USER]` 升级用户。';
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
