import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';
import '../logger_service.dart';
import 'group_orchestration_features.dart';
import 'group_task_bootstrap.dart';

/// Cross-task notes injected into admin `effectiveContent` when task-scoped
/// history is active (latest.md is injected separately).
class GroupAdminTaskContextLoader {
  GroupAdminTaskContextLoader._();

  static const maxRequirementChars = 4000;
  static const maxArchiveLineChars = 240;
  static const maxMemberPreviousTaskChars = 400;

  static Future<String> buildCrossTaskNotes({
    required String groupId,
    required String orchestrationId,
    String? userMessageFallback,
  }) async {
    if (!GroupOrchestrationFeatures.useTaskScopedAdminHistory) return '';
    if (groupId.isEmpty || orchestrationId.isEmpty) return '';

    final parts = <String>[];
    try {
      final ws = GroupWorkspaceService.instance;
      final index = await ws.readTaskIndex(groupId);
      GroupTaskIndexEntry? previous;
      for (final entry in index.recent) {
        if (entry.orchestrationId == orchestrationId) continue;
        // 上一任务只要已进入终态（done/paused/failed）就补摘要——pause 收尾
        // 的任务（澄清/取消/超轮）同样有卷宗可作跨任务上下文，否则新任务
        // 首个 admin 回合在 task 作用域历史下会近乎无上下文。
        if (!GroupTask.isTerminalStatus(entry.status)) continue;
        previous = entry;
        break;
      }

      if (previous != null) {
        final archiveLine = await _previousTaskLine(
          groupId: groupId,
          entry: previous,
        );
        if (archiveLine.isNotEmpty) {
          parts.add('[上一任务摘要]\n$archiveLine');
        }
      }

      if (!GroupOrchestrationFeatures.requirementUriOnlyPrompts) {
        final requirement = await ws.readTaskRequirement(
          groupId: groupId,
          orchestrationId: orchestrationId,
        );
        if (requirement != null && requirement.trim().isNotEmpty) {
          final req = requirement.trim();
          final user = userMessageFallback?.trim() ?? '';
          if (user.isEmpty || !_requirementRedundantWithUser(req, user)) {
            parts.add(
              '[当前任务定稿需求（requirement.md）]\n'
              '${_truncate(req, maxRequirementChars)}',
            );
          }
        }
      }
    } catch (e) {
      LoggerService().debug(
        'load admin task context failed: $groupId/$orchestrationId — $e',
        tag: 'GroupAdminTaskContextLoader',
      );
    }
    return parts.join('\n\n');
  }

  static Future<String> _previousTaskLine({
    required String groupId,
    required GroupTaskIndexEntry entry,
  }) async {
    // 与 GroupTaskBootstrap.archiveExcerpt 共用卷宗首行摘录逻辑（#12），
    // 仅在无卷宗可摘时回退 title/orchestrationId。
    final excerpt = await GroupTaskBootstrap.archiveExcerpt(
      groupId: groupId,
      orchestrationId: entry.orchestrationId,
      maxChars: maxArchiveLineChars,
    );
    if (excerpt != null) return excerpt;
    if (entry.title.isNotEmpty) {
      return _truncate(entry.title, maxArchiveLineChars);
    }
    return entry.orchestrationId;
  }

  /// Short cross-task note for member dispatch (previous task only).
  static Future<String> buildMemberCrossTaskNote({
    required String groupId,
    required String orchestrationId,
  }) async {
    if (!GroupOrchestrationFeatures.useTaskScopedAdminHistory) return '';
    if (groupId.isEmpty || orchestrationId.isEmpty) return '';
    try {
      final index =
          await GroupWorkspaceService.instance.readTaskIndex(groupId);
      for (final entry in index.recent) {
        if (entry.orchestrationId == orchestrationId) continue;
        if (!GroupTask.isTerminalStatus(entry.status)) continue;
        final line = await _previousTaskLine(
          groupId: groupId,
          entry: entry,
        );
        if (line.isEmpty) return '';
        return '\n\n[上一任务摘要（截断）]\n'
            '${_truncate(line, maxMemberPreviousTaskChars)}';
      }
    } catch (e) {
      LoggerService().debug(
        'load member cross-task note failed: $groupId/$orchestrationId — $e',
        tag: 'GroupAdminTaskContextLoader',
      );
    }
    return '';
  }

  static bool _requirementRedundantWithUser(String requirement, String user) {
    if (requirement == user) return true;
    if (user.length >= 80 && requirement.startsWith(user)) return true;
    if (requirement.length >= 80 && user.startsWith(requirement)) return true;
    return false;
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }
}
