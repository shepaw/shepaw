import '../../services/chat_service.dart';
import '../models/scheduled_task.dart';
import 'task_executor.dart';

/// Executes a scheduled task by sending the instruction to a group channel.
///
/// Requires [task.channelId] and [task.agentIds] to be set.
/// Optionally uses [task.mentionedAgentIds] to @-mention specific agents.
class GroupTaskExecutor implements TaskExecutor {
  @override
  Future<void> execute(ScheduledTask task) async {
    if (task.channelId == null || task.channelId!.isEmpty) {
      throw Exception('GroupTaskExecutor: task.channelId is null or empty for task ${task.id}');
    }
    if (task.agentIds.isEmpty) {
      throw Exception('GroupTaskExecutor: task.agentIds is empty for task ${task.id}');
    }

    await ChatService().sendMessageToGroup(
      channelId: task.channelId!,
      content: task.instruction,
      userId: 'user',
      userName: 'User',
      agentIds: task.agentIds,
      mentionedAgentIds: task.mentionedAgentIds,
    );
  }
}
