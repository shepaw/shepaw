import '../../models/group_task.dart';
import '../../storage/group_workspace_service.dart';
import 'group_orchestration_features.dart';

/// 判断用户交互回复是否应续接已有编排任务，而非创建新任务。
class GroupOrchestrationContinuation {
  GroupOrchestrationContinuation._();

  /// 交互类回复（表单/选择/上传）在存在活跃非终态任务时，续接其
  /// [GroupTaskIndex.activeOrchestrationId]，避免「澄清 + 表单」被拆成两个任务。
  static Future<String?> resolveForInteractionResponse({
    required String groupId,
  }) async {
    if (!GroupOrchestrationFeatures.structuredTasks) return null;
    if (groupId.isEmpty) return null;
    try {
      final index =
          await GroupWorkspaceService.instance.readTaskIndex(groupId);
      final activeId = index.activeOrchestrationId?.trim();
      if (activeId == null || activeId.isEmpty) return null;

      final task = await GroupWorkspaceService.instance.readTask(
        groupId: groupId,
        orchestrationId: activeId,
      );
      if (task == null || task.isTerminal) return null;
      return activeId;
    } catch (_) {
      return null;
    }
  }
}
