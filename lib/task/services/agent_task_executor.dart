import '../../services/chat_service.dart';
import '../../services/remote_agent_service.dart';
import '../../service_locator.dart' show getIt;
import '../models/scheduled_task.dart';
import 'task_executor.dart';

/// Executes a scheduled task by sending the instruction to a single agent.
class AgentTaskExecutor implements TaskExecutor {
  @override
  Future<void> execute(ScheduledTask task) async {
    if (task.agentId == null) {
      throw Exception('AgentTaskExecutor: task.agentId is null for task ${task.id}');
    }

    final agentService = getIt<RemoteAgentService>();
    final agent = await agentService.getAgentById(task.agentId!);

    if (agent == null) {
      throw Exception('Agent not found: ${task.agentId}');
    }

    // Determine channel: use the task's channelId if set, otherwise let
    // ChatService create/reuse the default DM session for this agent.
    final channelId =
        (task.channelId != null && task.channelId!.isNotEmpty) ? task.channelId : null;

    // Inject a system-prompt context block so the agent understands this is
    // an automated scheduled trigger — not a live user message.
    // Key points for the agent:
    //   • The user is NOT actively online; this fired automatically on schedule.
    //   • "I" / "me" in the instruction always refers to the user (your master).
    //   • Just execute the instruction and reply; do not ask clarifying questions.
    final scheduledContext = _buildScheduledTaskContext(task);

    await ChatService().sendMessageToAgent(
      content: task.instruction,
      agent: agent,
      userId: 'user',
      userName: 'User',
      channelId: channelId,
      dmSystemPrompt: scheduledContext,
    );
  }

  /// Builds a concise system-prompt block that orients the agent to the
  /// scheduled-task context for this single invocation.
  String _buildScheduledTaskContext(ScheduledTask task) {
    final now = DateTime.now();
    final timeStr =
        '${now.year}/${now.month.toString().padLeft(2, '0')}/${now.day.toString().padLeft(2, '0')}'
        ' ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}';

    final descLine = task.description.isNotEmpty && task.description != task.instruction
        ? '\n- Task description: ${task.description}'
        : '';

    return '''
## Scheduled Task Trigger

The following message was sent automatically by the system at $timeStr — the user is NOT actively online right now.

Context:
- This is an automated scheduled task, not a live user conversation.$descLine
- Any reference to "I", "me", or "my" in the instruction means **the user (your master)**.
- Execute the instruction proactively and send a clear, complete response.
- Do NOT ask clarifying questions or wait for follow-up — just act.''';
  }
}
