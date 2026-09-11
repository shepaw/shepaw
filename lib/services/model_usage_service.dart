import '../models/model_definition.dart';
import '../models/remote_agent.dart';
import 'local_database_service.dart';
import 'model_registry.dart';

/// 模型定义引用统计：哪些 agent 把某个定义用作主模型 / 场景模型。
///
/// 原先只存在于 CLI（`models_cli_helpers.dart`），UI 的模型管理删除前也需要
/// 同一份判断（CLI 有 `--yes` 引用保护，UI 没有）。上移到此处供两边共用，
/// 避免实现分叉。
class ModelUsageService {
  const ModelUsageService._();

  /// 统计 [agents] 对模型定义的引用。
  ///
  /// 返回 `defId -> {'main': [...], 'scenario': {modality: [...]}}`，
  /// 列表项为 `{'id': agentId, 'name': agentName}`；未被引用的定义不出现在
  /// 结果中。CLI 直接把这个结构序列化输出。
  ///
  /// [getDefinition] 用于按 tool name 反查定义（`enabled_tool_models` 里的
  /// 旧数据），默认走 [ModelRegistry.instance]。
  static Map<String, Map<String, dynamic>> build(
    List<RemoteAgent> agents, {
    ModelDefinition? Function(String toolName)? getDefinition,
  }) {
    final resolve = getDefinition ?? ModelRegistry.instance.getDefinition;
    final usage = <String, Map<String, dynamic>>{};

    void addMain(String defId, RemoteAgent a) {
      final main = usage.putIfAbsent(defId, _emptyEntry)['main']
          as List<Map<String, String>>;
      main.add({'id': a.id, 'name': a.name});
    }

    void addScenario(String defId, String modality, RemoteAgent a) {
      final scenarios = usage.putIfAbsent(defId, _emptyEntry)['scenario']
          as Map<String, List<Map<String, String>>>;
      scenarios.putIfAbsent(modality, () => []).add({'id': a.id, 'name': a.name});
    }

    for (final agent in agents) {
      final metadata = agent.metadata;
      final mainModelId = metadata['main_model_id'] as String?;
      if (mainModelId != null && mainModelId.isNotEmpty) {
        addMain(mainModelId, agent);
      }
      for (final modality in kConfigurableScenarioModalities) {
        final scenarioId = agent.scenarioModels.modelIdFor(modality);
        if (scenarioId != null && scenarioId.isNotEmpty) {
          addScenario(scenarioId, modality.name, agent);
        }
      }
      // 生成类场景模型也可能以 enabled_tool_models 形式启用（旧数据迁移前）。
      final enabled = metadata['enabled_tool_models'];
      if (enabled is List) {
        for (final toolName in enabled.cast<String>()) {
          final def = resolve(toolName);
          if (def == null || !def.isDelegatable) continue;
          addScenario(def.id, 'tool_model', agent);
        }
      }
    }
    return usage;
  }

  /// 读取全量 agents 后统计（DB 读取失败返回空表）。
  static Future<Map<String, Map<String, dynamic>>> usageByModelId() async {
    return build(await _allAgents());
  }

  /// 把单个定义的引用记录展平为去重后的 agent 名称列表。
  static List<String> referencedAgentNames(Map<String, dynamic> usage) {
    final names = <String>[];
    void addAll(List<dynamic> entries) {
      for (final entry in entries) {
        final name = (entry as Map)['name'] as String?;
        if (name != null && name.isNotEmpty && !names.contains(name)) {
          names.add(name);
        }
      }
    }

    addAll(usage['main'] as List<dynamic>? ?? const []);
    final scenario = usage['scenario'] as Map<String, dynamic>? ?? const {};
    for (final entries in scenario.values) {
      addAll(entries as List<dynamic>);
    }
    return names;
  }

  static Map<String, dynamic> _emptyEntry() => {
        'main': <Map<String, String>>[],
        'scenario': <String, List<Map<String, String>>>{},
      };

  /// 读取全量 agents（失败返回空列表，不阻塞命令）。
  static Future<List<RemoteAgent>> _allAgents() async {
    try {
      return await LocalDatabaseService().getAllRemoteAgents();
    } catch (_) {
      return const [];
    }
  }
}
