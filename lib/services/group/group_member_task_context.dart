import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';
import '../logger_service.dart';
import 'group_dispatch_parser.dart';
import 'group_orchestration_features.dart';

/// Member-facing task slices loaded from `shared/tasks/<orchestrationId>/`.
class GroupMemberTaskContext {
  const GroupMemberTaskContext({
    required this.globalRequirement,
    this.taskPlanNote = '',
    this.requirementUri,
    this.planUri,
  });

  static const maxRequirementChars = 8000;
  static const maxPlanChars = 2000;

  final String globalRequirement;
  final String taskPlanNote;
  final String? requirementUri;
  final String? planUri;
}

/// Loads requirement/plan text for member dispatch turns.
class GroupMemberTaskContextLoader {
  GroupMemberTaskContextLoader._();

  static Future<GroupMemberTaskContext> load({
    required String groupId,
    required String orchestrationId,
    required String userMessageFallback,
  }) async {
    final fallback = userMessageFallback.trim();
    if (!GroupOrchestrationFeatures.structuredTasks || fallback.isEmpty) {
      return GroupMemberTaskContext(globalRequirement: fallback);
    }
    try {
      final ws = GroupWorkspaceService.instance;
      final task = await ws.readTask(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );

      var requirement = fallback;
      final reqText = await ws.readTaskRequirement(
        groupId: groupId,
        orchestrationId: orchestrationId,
      );
      if (reqText != null && reqText.trim().isNotEmpty) {
        requirement = _truncate(reqText.trim(), GroupMemberTaskContext.maxRequirementChars);
      }

      var taskPlanNote = '';
      if (task?.hasPublishedPlan ?? false) {
        taskPlanNote = await _loadTaskPlanNote(
          ws: ws,
          groupId: groupId,
          orchestrationId: orchestrationId,
          planUri: task?.planUri,
          planJsonUri: task?.planJsonUri,
        );
      }

      return GroupMemberTaskContext(
        globalRequirement: requirement,
        taskPlanNote: taskPlanNote,
        requirementUri: task?.requirementUri,
        planUri: task?.planUri,
      );
    } catch (e) {
      LoggerService().debug(
        'load member task context failed: $groupId/$orchestrationId — $e',
        tag: 'GroupMemberTaskContextLoader',
      );
      return GroupMemberTaskContext(globalRequirement: fallback);
    }
  }

  static Future<String> _loadTaskPlanNote({
    required GroupWorkspaceService ws,
    required String groupId,
    required String orchestrationId,
    String? planUri,
    String? planJsonUri,
  }) async {
    final planMd = await ws.readTaskPlanMarkdown(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (planMd != null && planMd.trim().isNotEmpty) {
      return GroupDispatchParser.buildTaskPlanNote(
        body: planMd.trim(),
        planUri: planUri ?? planJsonUri,
        maxChars: GroupMemberTaskContext.maxPlanChars,
      );
    }

    final planJson = await ws.readTaskPlanJson(
      groupId: groupId,
      orchestrationId: orchestrationId,
    );
    if (planJson != null) {
      return GroupDispatchParser.buildTaskPlanNote(
        body: planJson.toMarkdown(),
        planUri: planUri ?? planJsonUri,
        maxChars: GroupMemberTaskContext.maxPlanChars,
      );
    }
    return '';
  }

  static String _truncate(String text, int maxChars) {
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}…';
  }
}
