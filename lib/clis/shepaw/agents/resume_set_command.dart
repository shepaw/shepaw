import 'dart:async';

import '../../cli_base.dart';
import '../../../services/local_database_service.dart';
import '../../../peer/services/peer_agent_host_service.dart';

/// 更新 Agent 自己的简历（`RemoteAgent.bio`）。
///
/// 用法：
///   shepaw context agents.resume-set --id <agent_id> --text "..."
///
/// 供 Agent 在聊天中自我修改简历；用户在创建/详情页填写的也是同一个字段。
class ResumeSetCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'resume-set';

  @override
  String get description => 'Update an agent\'s resume, --id <agent_id> --text "..."';

  @override
  String get usage =>
      'shepaw context agents.resume-set --id <agent_id> --text "..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Agent ID whose resume to update',
        'required': true,
        'type': 'string',
      },
      'text': {
        'description': 'New resume text (the agent\'s self-description)',
        'required': true,
        'type': 'string',
      },
    };
    base['note'] =
        'This is the resume others see about the agent. To read the current value, use agents.resume-get.';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error':
            'Missing --id. Usage: shepaw context agents.resume-set --id <agent_id> --text "..."',
      };
    }

    final text = flags['text'];
    if (text == null) {
      return {
        'error':
            'Missing --text. Usage: shepaw context agents.resume-set --id <agent_id> --text "..."',
      };
    }

    final agent = await _db.getRemoteAgentById(id);
    if (agent == null) {
      return {'error': 'Agent not found: $id'};
    }

    final resume = text.trim().isEmpty ? null : text.trim();
    await _db.updateRemoteAgent(agent.copyWith(bio: resume));

    // Agent 自我更新简历后，把最新列表推送给已连接且共享该 agent 的对端。
    unawaited(
      PeerAgentHostService.instance.pushAgentListToSharingPeers(id),
    );

    return {
      'ok': true,
      'agent_id': id,
      'name': agent.name,
      'resume': resume ?? '',
    };
  }
}
