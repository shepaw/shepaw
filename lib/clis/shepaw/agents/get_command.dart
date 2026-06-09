import '../../cli_base.dart';
import '../../../models/agent_scenario_models.dart';
import '../../../models/model_routing_config.dart';
import '../../../services/local_database_service.dart';
import '../../../services/model_registry.dart';

/// 获取单个 Agent 详情
class GetCommand extends CliCommand {
  final _db = LocalDatabaseService();

  @override
  String get name => 'get';

  @override
  String get description => 'Get agent details, --id <agent_id>';

  @override
  String get usage => 'shepaw context agents.get --id <agent_id>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': {
        'description': 'Agent ID to retrieve details for',
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
      return {'error': 'Missing --id. Usage: shepaw agents get --id <agent_id>'};
    }
    final agent = await _db.getRemoteAgentById(id);
    if (agent == null) {
      return {'error': 'Agent not found: $id'};
    }

    await ModelRegistry.instance.initialize();

    final metadata = agent.metadata;
    final scenarioModels =
        metadata['scenario_models'] as Map<String, dynamic>?;
    final routing = metadata['model_routing'] as Map<String, dynamic>?;
    final diagnostics = AgentScenarioModels.describeResolvedScenarios(
      metadata: metadata,
      enabledToolModels: agent.enabledToolModels,
      legacyRouting: ModelRoutingConfig.fromJson(routing),
      definitions: ModelRegistry.instance.definitions,
      registry: ModelRegistry.instance,
      supportsModality: agent.supportsModality,
    );

    return {
      'id': agent.id,
      'name': agent.name,
      'bio': agent.bio,
      'status': agent.status.name,
      'endpoint': agent.endpoint,
      'protocol': agent.protocol.name,
      'is_pinned': agent.isPinned,
      'is_she': metadata['is_she'] == true,
      'is_local': agent.isLocal,
      'provider': metadata['llm_provider'],
      'model': metadata['llm_model'],
      'main_model_id': metadata['main_model_id'],
      'scenario_models': scenarioModels ?? {},
      'enabled_tool_models': agent.enabledToolModels.toList(),
      'modality_support': diagnostics['modality_support'],
      'effective_routes': diagnostics['effective_routes'],
      'created_at': agent.createdAt,
    };
  }
}
