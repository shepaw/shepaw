import '../../cli_base.dart';
import '../chat/chat_agent_scope.dart';
import '../../../models/model_definition.dart';
import '../../../models/remote_agent.dart';
import '../../../services/local_database_service.dart';
import '../../../services/model_registry.dart';
import '../../../services/remote_agent_service.dart';
import '../../../services/she_service.dart';
import '../../../service_locator.dart';
import 'models_cli_helpers.dart';

/// 把一个模型定义设为某本地 Agent 的主对话模型（metadata['main_model_id']）。
///
/// 与 Agent 编辑页「主对话模型」下拉框写的是同一个字段：只存定义 id，
/// 运行时经 ModelRegistry 解析完整 route。默认目标为当前执行者（She）。
class ModelsAgentMainCommand extends CliCommand {
  @override
  String get name => 'agent-main';

  @override
  String get description =>
      'Set/switch/unset an agent main chat model, --agent <id|name> --model <model_id|model_name> [--unset]';

  @override
  String get usage =>
      'shepaw models agent-main --agent <agent_id|name> --model <model_id>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'agent':
          'Agent id or exact name. Omit to target the current executor (She by default)',
      'model':
          'Model definition id, or a route model name (+ --api_base if ambiguous)',
      'api_base': 'Disambiguate --model by api base',
      'unset': 'Remove the agent main model (no --model needed)',
    };
    base['examples'] = [
      'shepaw models agent-main --model <model_id>',
      'shepaw models agent-main --agent She --model <model_id>',
      'shepaw models agent-main --agent She --unset',
    ];
    base['note'] =
        'Only local LLM agents can be reconfigured here (peer/remote ACP '
        'agents manage their own models). Non-She agents may only change their own '
        'model. A change takes effect from the next message in the affected chat. '
        'Explicit scenario models (image/audio/video) still take priority over the '
        'main model for those modalities.';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final db = LocalDatabaseService();
    final callerId = ChatAgentScope.agentId;

    // ── 目标 agent ────────────────────────────────────────────────────────────
    final agentRef = flagValue(flags, 'agent');
    final String targetId;
    final RemoteAgent? targetAgent;
    if (agentRef != null) {
      final byId = await db.getRemoteAgentById(agentRef);
      if (byId != null) {
        targetAgent = byId;
        targetId = byId.id;
      } else {
        final all = await db.getAllRemoteAgents();
        final byName = all
            .where((a) => a.name.toLowerCase() == agentRef.toLowerCase())
            .toList();
        if (byName.isEmpty) {
          return {
            'error': 'Agent not found: $agentRef (no id or exact name match)',
            'hint':
                'Run "shepaw context agents.list" to see agent ids and names',
          };
        }
        if (byName.length > 1) {
          return {
            'error':
                'Multiple agents named "$agentRef" — pass the agent id instead',
            'matches': byName.map((a) => a.id).toList(),
          };
        }
        targetAgent = byName.first;
        targetId = byName.first.id;
      }
    } else {
      targetId = callerId;
      targetAgent = await db.getRemoteAgentById(targetId);
    }

    if (targetAgent == null) {
      return {'error': 'Target agent not found: $targetId'};
    }

    // ── 权限：非 She 只能改自己；远端/peer agent 由对端自管 ──────────────
    final isShe = callerId == SheService.sheId;
    if (!isShe && targetId != callerId) {
      return {
        'error':
            'Permission denied — only She can reconfigure another agent\'s model. '
                'You may only change your own (--agent $callerId).',
      };
    }
    if (!targetAgent.isLocal) {
      return {
        'error': '"${targetAgent.name}" is not a local LLM agent '
            '(remote/peer agents manage their own model configuration).',
      };
    }

    // ── 目标模型定义 ─────────────────────────────────────────────────────────
    final unset = flags.containsKey('unset') || flags['unset'] == 'true';
    ModelDefinition? def;
    if (!unset) {
      final modelRef = flagValue(flags, 'model');
      if (modelRef == null) {
        return {
          'error': 'Missing --model (or --unset)',
          'usage': usage,
          'hint': 'Model ids come from "shepaw models list"',
        };
      }
      final apiBase = flagValue(flags, 'api_base');
      final resolved = await resolveDefinition(
          id: modelRef, model: modelRef, apiBase: apiBase);
      if (resolved.error != null) {
        return {'error': resolved.error, 'usage': usage};
      }
      def = resolved.def;
    }

    // ── 写 metadata（与 Agent 编辑页同款字段约定）─────────────────────────
    final metadata = Map<String, dynamic>.from(targetAgent.metadata);
    final wasId = metadata['main_model_id'] as String?;
    if (unset) {
      metadata.remove('main_model_id');
    } else {
      final route = def!.route;
      metadata['main_model_id'] = def.id;
      metadata['llm_provider'] =
          (route.provider != null && route.provider!.isNotEmpty)
              ? route.provider!
              : 'openai';
      // 移除旧的内联 LLM 字段，避免干扰 ModelRegistry 解析。
      metadata.remove('llm_model');
      metadata.remove('llm_api_base');
      metadata.remove('llm_api_key');
    }

    final updated = targetAgent.copyWith(
      metadata: metadata,
      updatedAt: DateTime.now().millisecondsSinceEpoch,
    );
    await getIt<RemoteAgentService>().updateAgent(updated);
    // 对端共享推送由 updateAgent 内部 best-effort 处理。

    final result = <String, dynamic>{
      'ok': true,
      'action': unset ? 'unset_main_model' : 'set_main_model',
      'agent': {'id': targetId, 'name': targetAgent.name},
      'previous_main_model_id': wasId,
    };

    if (unset) {
      result['note'] =
          '"${targetAgent.name}" no longer has a main model — configure one before '
          'its next chat message, otherwise the LLM call will fail.';
      return result;
    }

    final setDef = def;
    if (setDef == null) {
      return {'error': 'Model not resolved — internal error', 'usage': usage};
    }

    final summary = modelSummary(setDef);
    result['model'] = summary;
    if (!(summary['has_api_key'] as bool)) {
      result['needs_api_key'] = true;
      result['key_warning'] =
          'This model has no API key yet — chat calls fail until you set one: '
          'shepaw models update --id ${setDef.id} --api_key <key>';
    }

    final notes = <String>[
      'Takes effect from the next message in "${targetAgent.name}"\'s chat.',
    ];
    // 显式场景模型优先于主模型，提示哪些模态不受本次切换影响。
    final explicitScenarios = targetAgent.scenarioModels;
    final overridden = <String>[];
    for (final modality in kInputScenarioModalities) {
      final scenarioId = explicitScenarios.modelIdFor(modality);
      if (scenarioId != null &&
          scenarioId.isNotEmpty &&
          scenarioId != setDef.id &&
          ModelRegistry.instance.getById(scenarioId) != null) {
        overridden.add(modality.name);
      }
    }
    if (overridden.isNotEmpty) {
      notes.add(
          'Explicit scenario models still take priority for: ${overridden.join(", ")} — '
          'route those via "shepaw models list" usage info or an agent editor.');
    }
    result['notes'] = notes;
    return result;
  }
}
