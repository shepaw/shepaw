import '../../services/acp_agent_connection.dart';
import '../../services/chat_service.dart';
import '../../services/group/she_group_approval_bridge.dart';
import '../../services/local_database_service.dart';
import '../../services/local_user_identity.dart';
import '../../services/logger_service.dart';
import '../helpers/scheduled_task_prompt.dart';
import '../models/scheduled_task.dart';
import 'scheduled_task_notifier.dart';
import 'task_executor.dart';

/// Executes a scheduled task by sending the instruction to a group channel.
///
/// Requires [task.channelId] and [task.agentIds] to be set.
/// Optionally uses [task.mentionedAgentIds] to @-mention specific agents.
///
/// Unlike a live chat send, this path is headless: it persists approval cards
/// onto group messages, upserts [PendingApprovalHub], and fires a system
/// notification so the user does not have to already have that group open.
class GroupTaskExecutor implements TaskExecutor {
  GroupTaskExecutor({
    ChatService? chat,
    LocalDatabaseService? db,
    SheGroupApprovalBridge? approvalBridge,
  })  : _chat = chat ?? ChatService(),
        _db = db ?? LocalDatabaseService(),
        _approvalBridge = approvalBridge ?? SheGroupApprovalBridge();

  final ChatService _chat;
  final LocalDatabaseService _db;
  final SheGroupApprovalBridge _approvalBridge;

  @override
  Future<void> execute(ScheduledTask task) async {
    if (task.channelId == null || task.channelId!.isEmpty) {
      throw Exception(
          'GroupTaskExecutor: task.channelId is null or empty for task ${task.id}');
    }
    if (task.agentIds.isEmpty) {
      throw Exception(
          'GroupTaskExecutor: task.agentIds is empty for task ${task.id}');
    }

    final channelId = task.channelId!;
    final channel = await _db.getChannelById(channelId);
    final groupName = channel?.name ?? task.description;

    await ScheduledTaskNotifier.notifyFired(
      task: task,
      groupName: groupName,
    );

    final token = ACPCancellationToken();
    await _chat.sendMessageToGroup(
      channelId: channelId,
      content: ScheduledTaskPrompt.groupUserContent(task),
      userId: LocalUserIdentity.id,
      userName: LocalUserIdentity.displayName,
      agentIds: task.agentIds,
      mentionedAgentIds: task.mentionedAgentIds,
      adminAgentId: channel?.adminAgentId,
      flowMode: channel?.flowMode ?? false,
      throwIfBusy: true,
      acpCancellationToken: token,
      onInteractionRequest: (agentId, agentName, interactionType, data) {
        return _approvalBridge.persistHeadlessInteraction(
          groupChannelId: channelId,
          agentId: agentId,
          agentName: agentName,
          interactionType: interactionType,
          data: data,
        );
      },
    );

    LoggerService().info(
      'Group scheduled task ${task.id} dispatched to $channelId',
      tag: 'GroupTaskExecutor',
    );
  }
}
