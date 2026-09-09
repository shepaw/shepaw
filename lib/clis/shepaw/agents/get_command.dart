import '../../cli_base.dart';
import '../../../services/agent_profile_service.dart';
import '../../../services/local_database_service.dart';

/// 获取单个 Agent 画像（默认仅 summary；用 `--sections` 按需拉取其他分类）。
class GetCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'get';

  @override
  String get description =>
      'Get agent profile by section, --id <agent_id> [--sections summary|identity|...|all]';

  @override
  String get usage =>
      'shepaw context agents.get --id <agent_id> [--sections summary|identity|capabilities|commands|models|experience|connection|all]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Agent ID to retrieve details for',
        'required': true,
        'type': 'string',
      },
      'sections': {
        'description':
            'Comma-separated profile sections to include. Default: summary only. '
            'Use "all" for every section.',
        'required': false,
        'type': 'string',
        'enum': AgentProfileService.allSectionIds + ['all'],
        'default': 'summary',
      },
    };
    base['sections'] = AgentProfileService.sectionCatalog;
    base['note'] =
        'Agent profiles are not in your system prompt. '
        'Call with default (no --sections) for a compact summary card; add sections only '
        'when you need deeper detail before dispatch.';
    return base;
  }

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

    final sections =
        AgentProfileService.parseSections(flags['sections'] ?? flags['section']);
    return AgentProfileService.instance.buildProfile(agent, sections);
  }
}
