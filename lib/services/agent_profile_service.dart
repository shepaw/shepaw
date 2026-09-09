import '../models/agent_scenario_models.dart';
import '../models/model_routing_config.dart';
import '../models/remote_agent.dart';
import 'agent_memory_store_service.dart';
import 'agent_soul_service.dart';
import 'chat_service.dart';
import 'local_database_service.dart';
import 'logger_service.dart';
import 'model_registry.dart';
import 'she_agent_impression_service.dart';

/// Agent 画像的分层读取：供 `agents.get --sections` 按需拉取，避免 token 浪费。
class AgentProfileService {
  AgentProfileService._();
  static final AgentProfileService instance = AgentProfileService._();

  static const String sectionSummary = 'summary';
  static const String sectionIdentity = 'identity';
  static const String sectionCapabilities = 'capabilities';
  static const String sectionCommands = 'commands';
  static const String sectionModels = 'models';
  static const String sectionExperience = 'experience';
  static const String sectionConnection = 'connection';

  static const List<String> allSectionIds = [
    sectionSummary,
    sectionIdentity,
    sectionCapabilities,
    sectionCommands,
    sectionModels,
    sectionExperience,
    sectionConnection,
  ];

  /// 供 She 选择下一层资料时的目录说明。
  static const Map<String, String> sectionCatalog = {
    sectionSummary: 'Compact card — role + dispatch hint (default)',
    sectionIdentity:
        'Full soul (master-authored specialty) + resume/bio (agent self-description)',
    sectionCapabilities: 'Capability tags, enabled skills, OS tools',
    sectionCommands: 'Agent-advertised slash commands',
    sectionModels: 'LLM provider, model routing, modality support',
    sectionExperience:
        'Dispatch stats + learnings (She observations, supplementary)',
    sectionConnection:
        'Endpoint, protocol, local/remote, dispatch confirmation flag',
  };

  final _db = LocalDatabaseService();
  final _log = LoggerService();

  /// 解析 `--sections`：缺省为 [sectionSummary]；`all` 返回全部分类。
  static Set<String> parseSections(String? raw) {
    if (raw == null || raw.trim().isEmpty) {
      return {sectionSummary};
    }
    final trimmed = raw.trim().toLowerCase();
    if (trimmed == 'all') {
      return allSectionIds.toSet();
    }
    return trimmed
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// 构建分层画像。未知 section id 会被忽略并在 [unknown_sections] 中列出。
  Future<Map<String, dynamic>> buildProfile(
    RemoteAgent agent,
    Set<String> sections,
  ) async {
    final requested = sections.isEmpty ? {sectionSummary} : sections;
    final unknown = requested.difference(allSectionIds.toSet()).toList()
      ..sort();
    final effective = requested.intersection(allSectionIds.toSet());
    final included = effective.toList()..sort();

    final result = <String, dynamic>{
      'id': agent.id,
      'name': agent.name,
      'sections_included': included,
      'available_sections': sectionCatalog,
    };
    if (unknown.isNotEmpty) {
      result['unknown_sections'] = unknown;
    }
    if (!effective.contains(sectionSummary) || effective.length > 1) {
      result['hint'] =
          'Default is summary only. Add --sections identity,capabilities,... '
          'or --sections all for full profile.';
    }

    var soul = '';
    if (effective.contains(sectionSummary) ||
        effective.contains(sectionIdentity)) {
      try {
        soul = (await AgentSoulService.instance.getSoul(agent)).trim();
      } catch (e) {
        _log.warning('read soul for profile ${agent.id}: $e', tag: 'AgentProfile');
      }
    }

    if (effective.contains(sectionSummary)) {
      final impression =
          await SheAgentImpressionService.instance.getImpression(agent.id);
      final role = SheAgentImpressionService.buildOneLineRole(agent, soul);
      result.addAll({
        'status': agent.status.name,
        'role': role,
        'experience_hint': impression?.experienceHint ??
            SheAgentImpressionService.buildExperienceHint(stats: const {}),
        'dispatch_confirm': agent.metadata['dispatch_confirm'] == true,
      });
    }

    if (effective.contains(sectionIdentity)) {
      result.addAll({
        'specialty': soul,
        'bio': agent.bio ?? '',
      });
    }

    if (effective.contains(sectionCapabilities)) {
      result.addAll({
        'capabilities': agent.capabilities,
        'skills': agent.enabledSkills.toList(),
        'os_tools': agent.enabledOsTools.toList(),
      });
    }

    if (effective.contains(sectionCommands)) {
      result['slash_commands'] = _slashCommands(agent.id);
    }

    if (effective.contains(sectionModels)) {
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
      result.addAll({
        'provider': metadata['llm_provider'],
        'model': metadata['llm_model'],
        'main_model_id': metadata['main_model_id'],
        'scenario_models': scenarioModels ?? {},
        'enabled_tool_models': agent.enabledToolModels.toList(),
        'modality_support': diagnostics['modality_support'],
        'effective_routes': diagnostics['effective_routes'],
      });
    }

    if (effective.contains(sectionExperience)) {
      result.addAll({
        'dispatch_stats': await _dispatchStats(agent.id),
        'dispatch_learnings': await _dispatchLearnings(agent.id),
      });
    }

    if (effective.contains(sectionConnection)) {
      final metadata = agent.metadata;
      result.addAll({
        'status': agent.status.name,
        'endpoint': agent.endpoint,
        'protocol': agent.protocol.name,
        'is_pinned': agent.isPinned,
        'is_she': metadata['is_she'] == true,
        'is_local': agent.isLocal,
        'dispatch_confirm': metadata['dispatch_confirm'] == true,
        'created_at': agent.createdAt,
      });
    }

    return result;
  }

  List<Map<String, String>> _slashCommands(String agentId) {
    try {
      return ChatService()
          .getSlashCommandsSnapshot(agentId)
          .map((c) => {
                'name': '/${c.name}',
                if (c.description != null) 'description': c.description!,
              })
          .toList();
    } catch (e) {
      _log.warning('slash snapshot failed: $e', tag: 'AgentProfile');
      return const [];
    }
  }

  Future<Map<String, int>> _dispatchStats(String agentId) async {
    try {
      return await _db.getDispatchStatsForAgent(agentId);
    } catch (e) {
      _log.warning('dispatch stats failed: $e', tag: 'AgentProfile');
      return const {};
    }
  }

  Future<List<String>> _dispatchLearnings(String agentId) async {
    try {
      final mems = await AgentMemoryStoreService.forAgent(agentId)
          .queryByKeyword('dispatch', limit: 3);
      return mems.map((m) => m.memoryContent).toList();
    } catch (e) {
      _log.warning('dispatch learnings failed: $e', tag: 'AgentProfile');
      return const [];
    }
  }
}
