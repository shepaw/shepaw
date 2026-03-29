import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 获取单个 Agent 详情
class GetCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'get';

  @override
  String get description => 'Get agent details, --id <agent_id>';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'id': {
            'description': 'Agent ID to retrieve details for',
            'required': true,
            'type': 'string',
          },
        },
        'usage': 'shepaw context agents.get --id <agent_id>',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flags['id'];
    if (id == null || id.isEmpty) {
      return {'error': 'Missing --id. Usage: shepaw agents get --id <agent_id>'};
    }
    final agent = await _db.getRemoteAgentById(id);
    if (agent == null) {
      return {'error': 'Agent not found: $id'};
    }
    return {
      'id': agent.id,
      'name': agent.name,
      'bio': agent.bio,
      'status': agent.status.name,
      'endpoint': agent.endpoint,
      'protocol': agent.protocol.name,
      'is_pinned': agent.isPinned,
      'is_she': agent.metadata['is_she'] == true,
      'provider': agent.metadata['llm_provider'],
      'model': agent.metadata['llm_model'],
      'created_at': agent.createdAt,
    };
  }
}
