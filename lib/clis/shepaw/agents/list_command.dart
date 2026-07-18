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
  String get usage => 'shepaw context agents.list [--status online|offline|all]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'status': {
        'description': 'Filter agents by status',
        'required': false,
        'type': 'string',
        'enum': ['online', 'offline', 'all'],
        'default': 'all',
      },
    };
    return base;
  }

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
              // 专长摘要（system_prompt 前 60 字符）：初选派发目标的关键信号
              'specialty': () {
                final s = (a.metadata['system_prompt'] as String? ?? '').trim();
                return s.length > 60 ? '${s.substring(0, 60)}…' : s;
              }(),
              'status': a.status.name,
              'is_she': a.metadata['is_she'] == true,
              'dispatch_confirm': a.metadata['dispatch_confirm'] == true,
              'provider': a.metadata['llm_provider'],
              'model': a.metadata['llm_model'],
            })
        .toList();
    return {
      'agents': list,
      'count': list.length,
      'hint': 'Use `shepaw context agents.get --id <id>` for the full '
          'capability profile before an important dispatch.',
    };
  }
}
