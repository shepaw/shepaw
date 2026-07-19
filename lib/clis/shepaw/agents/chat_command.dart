import '../../cli_base.dart';
import '../../../models/dispatch_task.dart';
import '../../../services/agent_resolver.dart';
import '../../../services/dispatch/dispatch_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/she_service.dart';

/// 以 She 身份向 Agent 发送对话消息，回复自动回传。
///
/// 与 `agents.dispatch`（任务型，写状态卡片、以 [Dispatch Result] 汇报）不同：
/// chat 走对话转发语义——不写状态卡片，agent 回复以 [Agent Reply] 形式注入
/// 当前会话并重新唤起 She，由她决定继续对聊还是向用户汇报。连续自动接力受
/// [DispatchService.maxChatRelayTurns] 预算约束，防 She↔agent 无限对聊。
class ChatCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'chat';

  @override
  String get description =>
      'Send a message to agent as She; the reply arrives back here '
      'automatically as [Agent Reply], --id <agent_id_or_name> '
      '--message <text> [--channel <channel_id>] [--timeout-min N]';

  @override
  String get usage =>
      'shepaw context agents.chat --id <agent_id> --message "text" '
      '[--channel <channel_id>] [--timeout-min 15]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Target agent ID or registered display name',
        'required': true,
        'type': 'string',
      },
      'message': {
        'description': 'Message text to send',
        'required': true,
        'type': 'string',
      },
      'channel': {
        'description':
            'Target channel ID (auto-detected from most recent DM if not provided)',
        'required': false,
        'type': 'string',
      },
      'timeout-min': {
        'description':
            'Watchdog timeout in minutes waiting for the reply (default 15, max 180)',
        'required': false,
        'type': 'number',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    final message = flags['message'];

    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw agents chat --id <agent_id> --message <text> [--channel <channel_id>]'
      };
    }
    if (message == null || message.isEmpty) {
      return {
        'error':
            'Missing --message. Usage: shepaw agents chat --id <agent_id> --message <text>'
      };
    }

    // 群聊里禁用：群内派发走 ```json dispatch``` 块（群主流程）
    final groupContextId = flags['channel_id'];
    if (groupContextId != null && groupContextId.isNotEmpty) {
      final groupChannel = await _db.getChannelById(groupContextId);
      if (groupChannel?.isGroup == true) {
        return {
          'error':
              'agents.chat cannot delegate tasks inside a group chat. '
              'Output a ```json dispatch``` block in your reply instead — '
              'the system will create a workflow and run members in this group. '
              'agents.chat only sends to a private DM channel.',
        };
      }
    }

    // 回复回传目标（She↔用户 频道）必须可定位：优先运行时注入的 channel_id，
    // 兜底取 She 最近活跃的个人 DM（如从非常规入口调用时）。
    var sourceChannelId = flags['channel_id'];
    if (sourceChannelId == null || sourceChannelId.isEmpty) {
      final sheChans = (await _db.getChannelsForAgent(SheService.sheId))
          .where((c) => !c.isGroup && !c.isGroupBoundMemberSession);
      sourceChannelId = sheChans.isNotEmpty ? sheChans.first.id : null;
    }
    if (sourceChannelId == null || sourceChannelId.isEmpty) {
      return {
        'error': 'Cannot determine the current channel to report the reply '
            'back to. Run agents.chat from a She conversation.'
      };
    }

    final targetAgent = await AgentResolver.byIdOrName(_db, id);
    if (targetAgent == null) {
      return {'error': 'Agent not found: $id'};
    }

    if (SheService.isSheIdentity(targetAgent.id, targetAgent.metadata)) {
      return {'error': 'Cannot chat with She yourself.'};
    }

    // 目标频道：显式指定，或该 agent 最近活跃的个人 DM（排除群绑定成员会话）
    String? channelId =
        flags['channel']?.isNotEmpty == true ? flags['channel'] : null;
    if (channelId == null) {
      final agentChans = (await _db.getChannelsForAgent(targetAgent.id))
          .where((c) => !c.isGroupBoundMemberSession);
      if (agentChans.isNotEmpty) channelId = agentChans.first.id;
    }

    if (channelId == null || channelId.isEmpty) {
      return {
        'error':
            'No channel found for ${targetAgent.name}. Start a conversation in ShePaw first or specify --channel.'
      };
    }

    // 超时（分钟），默认 15，上限 180
    var timeoutMin = int.tryParse(flags['timeout-min'] ?? '') ?? 15;
    if (timeoutMin < 1) timeoutMin = 1;
    if (timeoutMin > 180) timeoutMin = 180;

    return DispatchService.instance.dispatch(
      sourceChannelId: sourceChannelId,
      targetAgent: targetAgent,
      targetChannelId: channelId,
      prompt: message,
      timeout: Duration(minutes: timeoutMin),
      kind: DispatchTask.kindChat,
    );
  }
}
