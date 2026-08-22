import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 读取 Agent 的简历（`RemoteAgent.bio`）。
///
/// 用法：
///   shepaw context agents.resume-get --id <agent_id>
class ResumeGetCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'resume-get';

  @override
  String get description => 'Get an agent\'s resume, --id <agent_id>';

  @override
  String get usage => 'shepaw context agents.resume-get --id <agent_id>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Agent ID whose resume to read',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {
        'error': 'Missing --id. Usage: shepaw context agents.resume-get --id <agent_id>',
      };
    }

    final agent = await _db.getRemoteAgentById(id);
    if (agent == null) {
      return {'error': 'Agent not found: $id'};
    }

    return {
      'agent_id': id,
      'name': agent.name,
      'resume': agent.bio ?? '',
    };
  }
}
