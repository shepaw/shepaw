import '../../cli_base.dart';
import '../../../services/agent_resolver.dart';
import '../../../services/dispatch/dispatch_service.dart';
import '../../../services/local_database_service.dart';
import '../../../services/she_service.dart';

/// 以 She 身份把任务派发给 Agent，并在执行完毕后自动把结果回传到当前会话。
///
/// 任务在 She 与该 agent 的绑定 DM（[SheRelaySessionService]）中执行，不污染
/// 用户与该 agent 的普通单聊。dispatch 会登记任务、跟踪执行、超时看门，完成后
/// 由 DispatchService 唤起 She 向用户汇报。与 `agents.chat`（对话转发，以
/// [Agent Reply] 唤起 She 继续对话）共享同一套闭环机制。
class DispatchCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'dispatch';

  @override
  String get description =>
      'Dispatch a task to an agent and auto-report the result back here, '
      '--id <agent_id_or_name> --task "<brief>" '
      '[--timeout-min N] [--confirm]';

  @override
  String get usage =>
      'shepaw context agents.dispatch --id <agent_id> --task "..." '
      '[--timeout-min 30] [--confirm]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Target agent ID or registered display name',
        'required': true,
        'type': 'string',
      },
      'task': {
        'description':
            'Self-contained task brief. The agent cannot see this conversation, '
                'so include all needed context.',
        'required': true,
        'type': 'string',
      },
      'timeout-min': {
        'description': 'Watchdog timeout in minutes (default 30, max 180)',
        'required': false,
        'type': 'number',
      },
      'confirm': {
        'description':
            'Pass "true" after the user explicitly confirmed a dispatch to an '
                'agent marked as requiring confirmation',
        'required': false,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    final task = flags['task'];

    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw context agents.dispatch --id <agent_id> --task "..."'
      };
    }
    if (task == null || task.isEmpty) {
      return {
        'error':
            'Missing --task. Usage: shepaw context agents.dispatch --id <agent_id> --task "..."'
      };
    }

    // 群聊里禁用：群内派发走 ```json dispatch``` 块（群主流程）
    final groupContextId = flags['channel_id'];
    if (groupContextId != null && groupContextId.isNotEmpty) {
      final groupChannel = await _db.getChannelById(groupContextId);
      if (groupChannel?.isGroup == true) {
        return {
          'error':
              'agents.dispatch cannot be used inside a group chat. '
              'Output a ```json dispatch``` block in your reply instead — '
              'the system will run members of this group.',
        };
      }
    }

    // 结果回传目标（She↔用户 频道）必须可定位
    final sourceChannelId = flags['channel_id'];
    if (sourceChannelId == null || sourceChannelId.isEmpty) {
      return {
        'error': 'Cannot determine the current channel to report the result '
            'back to. Run agents.dispatch from a She conversation.'
      };
    }

    final targetAgent = await AgentResolver.byIdOrName(_db, id);
    if (targetAgent == null) {
      return {'error': 'Agent not found: $id'};
    }

    if (SheService.isSheIdentity(targetAgent.id, targetAgent.metadata)) {
      return {'error': 'Cannot dispatch to She yourself.'};
    }

    // 超时（分钟），默认 30，上限 180
    var timeoutMin = int.tryParse(flags['timeout-min'] ?? '') ?? 30;
    if (timeoutMin < 1) timeoutMin = 1;
    if (timeoutMin > 180) timeoutMin = 180;

    // 需要用户确认的 agent：未带 --confirm 时发确认卡并拒绝
    if (targetAgent.metadata['dispatch_confirm'] == true &&
        flags['confirm'] != 'true') {
      await DispatchService.instance.requestConfirmation(
        sourceChannelId: sourceChannelId,
        targetAgent: targetAgent,
        task: task,
        timeoutMin: timeoutMin,
      );
      return {
        'requires_confirm': true,
        'error':
            'Agent ${targetAgent.name} requires user confirmation before dispatch.',
        'note': 'A confirmation card has been posted in this conversation. '
            'Tell your master to tap 确认派发 on the card, or explicitly confirm '
            'to you (then re-run with --confirm true). Never pass --confirm '
            'without the user\'s explicit approval.',
      };
    }

    // 执行频道由 DispatchService 内部确保（She 与该 agent 的绑定 DM）
    return DispatchService.instance.dispatch(
      sourceChannelId: sourceChannelId,
      targetAgent: targetAgent,
      prompt: task,
      timeout: Duration(minutes: timeoutMin),
    );
  }
}
