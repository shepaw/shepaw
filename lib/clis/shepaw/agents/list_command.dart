import '../../cli_base.dart';
import '../../../services/local_database_service.dart';

/// 列出所有 Agent
class ListCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'list';

  @override
  String get description => 'List agents, optional --status <online|offline|all>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    var agents = await _db.getAllRemoteAgents();
    final statusFilter = flags['status'];
    if (statusFilter != null && statusFilter != 'all') {
      agents = agents
          .where((a) => a.status.name.toLowerCase() == statusFilter.toLowerCase())
          .toList();
    }
    final list = agents
        .map((a) => {
              'id': a.id,
              'name': a.name,
              'bio': a.bio,
              'status': a.status.name,
              'is_she': a.metadata['is_she'] == true,
              'provider': a.metadata['llm_provider'],
              'model': a.metadata['llm_model'],
            })
        .toList();
    return {'agents': list, 'count': list.length};
  }
}
