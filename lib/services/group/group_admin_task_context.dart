import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';
import '../logger_service.dart';
import 'group_orchestration_features.dart';

/// Cross-task notes injected into admin `effectiveContent` when task-scoped
/// history is active (latest.md is injected separately).
class GroupAdminTaskContextLoader {
  GroupAdminTaskContextLoader._();

  static const maxRequirementChars = 4000;
  static const maxArchiveLineChars = 240;

  static Future<String> buildCrossTaskNotes({
    required String groupId,
    required String orchestrationId,
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
        if (entry.status != GroupTask.statusDone) continue;
        previous = entry;
        break;
      }

      if (previous != null) {
        final archiveLine = await _previousTaskLine(
          ws: ws,
          groupId: groupId,
          entry: previous,
        );
        if (archiveLine.isNotEmpty) {
          parts.add('[上一任务摘要]\n$archiveLine');
        }
      }

      final requirement = await ws.readTaskRequirement(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (requirement != null && requirement.trim().isNotEmpty) {
        parts.add(
          '[当前任务定稿需求（requirement.md）]\n'
          '${_truncate(requirement.trim(), maxRequirementChars)}',
        );
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
    required GroupWorkspaceService ws,
    required String groupId,
    required GroupTaskIndexEntry entry,
  }) async {
    final archive = await ws.readTaskArchive(
      groupId: groupId,
      orchestrationId: entry.orchestrationId,
    );
    if (archive != null && archive.trim().isNotEmpty) {
      for (final line in archive.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty || trimmed.startsWith('#')) continue;
        return _truncate(trimmed, maxArchiveLineChars);
      }
    }
    if (entry.title.isNotEmpty) {
      return _truncate(entry.title, maxArchiveLineChars);
    }
    return entry.orchestrationId;
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }
}
