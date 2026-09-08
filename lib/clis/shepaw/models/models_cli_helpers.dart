import '../../../models/llm_provider_config.dart';
import '../../../models/model_definition.dart';
import '../../../models/remote_agent.dart';
import '../../../services/local_database_service.dart';
import '../../../services/model_registry.dart';
import '../../../services/secure_key_manager.dart';

/// `models` 命名空间的共享工具：provider 预设解析、能力类型解析、
/// ModelDefinition 查找/汇总、agent 引用扫描、API Key 缓存复用。
///
/// 安全约定：任何命令输出都不得包含 API Key 明文，只暴露 `has_api_key`
/// 之类的布尔状态。密钥只写入 [SecureKeyManager] / [ModelRegistry] 持久化。

/// 读取 flag，空白值视为未提供。
String? flagValue(Map<String, String> flags, String key) {
  final v = flags[key]?.trim();
  return (v == null || v.isEmpty) ? null : v;
}

/// 按名称（大小写不敏感）或 providerType 匹配内置服务商预设。
LLMProviderConfig? resolveProvider(String labelOrType) {
  if (labelOrType.isEmpty) return null;
  final needle = labelOrType.toLowerCase();
  for (final p in llmProviders) {
    if (p.name.toLowerCase() == needle ||
        p.providerType.toLowerCase() == needle) {
      return p;
    }
  }
  return null;
}

/// 按默认 apiBase 匹配内置服务商预设；无匹配返回 null（自定义 endpoint）。
LLMProviderConfig? providerForApiBase(String apiBase) {
  if (apiBase.isEmpty) return null;
  final base = apiBase.endsWith('/')
      ? apiBase.substring(0, apiBase.length - 1)
      : apiBase;
  for (final p in llmProviders) {
    if (p.defaultApiBase == base) return p;
  }
  return null;
}

/// 解析逗号分隔的能力类型字符串（接受枚举名与常用别名）。
///
/// 合法输入示例：`text,imageUnderstanding`、`text,image`、`image_gen,tts`。
/// 返回 `(types, error)`：解析成功时 error 为 null。
({Set<ModelType> types, String? error}) parseModelTypes(String raw) {
  final segments = raw
      .split(',')
      .map((s) => s.trim().toLowerCase())
      .where((s) => s.isNotEmpty);
  final types = <ModelType>{};
  final unknown = <String>[];
  for (final seg in segments) {
    final t = _aliasToType[seg] ?? _enumNameToType[seg];
    if (t != null) {
      types.add(t);
    } else {
      unknown.add(seg);
    }
  }
  if (unknown.isNotEmpty) {
    return (
      types: types,
      error: 'Unknown model type(s): ${unknown.join(", ")}. '
          'Available: text, imageUnderstanding (image), audioUnderstanding, '
          'videoUnderstanding, imageGeneration (image_gen), tts, videoGeneration (video_gen).',
    );
  }
  return (types: types, error: null);
}

const Map<String, ModelType> _aliasToType = {
  'image': ModelType.imageUnderstanding,
  'vision': ModelType.imageUnderstanding,
  'imageunderstanding': ModelType.imageUnderstanding,
  'audio': ModelType.audioUnderstanding,
  'audiounderstanding': ModelType.audioUnderstanding,
  'video': ModelType.videoUnderstanding,
  'videounderstanding': ModelType.videoUnderstanding,
  'img': ModelType.imageGeneration,
  'imagegen': ModelType.imageGeneration,
  'imagegeneration': ModelType.imageGeneration,
  'tts': ModelType.tts,
  'voice': ModelType.tts,
  'speech': ModelType.tts,
  'videogen': ModelType.videoGeneration,
  'videogeneration': ModelType.videoGeneration,
};

final Map<String, ModelType> _enumNameToType = {
  for (final t in ModelType.values) t.name.toLowerCase(): t,
};

/// 布尔 flag 解析：true/false/1/0/yes/no。
({bool? value, String? error}) parseBoolFlag(String? raw, String label) {
  if (raw == null) return (value: null, error: null);
  final v = raw.trim().toLowerCase();
  if (v == 'true' || v == '1' || v == 'yes') return (value: true, error: null);
  if (v == 'false' || v == '0' || v == 'no') return (value: false, error: null);
  return (value: null, error: '$label must be true or false, got "$raw"');
}

/// 模型列表条目（紧凑、脱敏，不含 API Key）。
Map<String, dynamic> compactModelSummary(ModelDefinition def) {
  final route = def.route;
  return {
    'id': def.id,
    'tool_name': def.toolName,
    'display_name': def.displayName,
    'provider': route.provider,
    'model': route.model,
    'api_base': route.apiBase,
    'stream': route.stream ?? true,
    'model_types': def.modelTypes.map((t) => t.name).toList(),
    'has_api_key': hasApiKey(def),
  };
}

/// 模型完整汇总（脱敏，不含 API Key）。
Map<String, dynamic> modelSummary(ModelDefinition def) {
  final route = def.route;
  return {
    ...compactModelSummary(def),
    'description': def.description,
    'api_path': route.apiPath,
    'request_body_template': route.requestBodyTemplate,
    'response_body_path': route.responseBodyPath,
  };
}

/// 定义是否持有 API Key（内存态；应用启动时 [ModelRegistry.initialize]
/// 已把 SecureKeyManager 中的密钥回填到 route.apiKey）。
bool hasApiKey(ModelDefinition def) {
  final key = def.route.apiKey;
  return key != null && key.isNotEmpty;
}

/// 读取全量 agents（失败返回空列表，不阻塞命令）。
Future<List<RemoteAgent>> allAgents() async {
  try {
    return await LocalDatabaseService().getAllRemoteAgents();
  } catch (_) {
    return const [];
  }
}

/// 统计每个模型定义被哪些 agent 引用（主模型 / 各场景模型）。
///
/// 返回 `defId -> {'main': [...], 'scenario': {modality: [...]}}`，
/// 列表项为 `{'id': agentId, 'name': agentName}`。
Future<Map<String, Map<String, dynamic>>> usageByModelId() async {
  final agents = await allAgents();
  final usage = <String, Map<String, dynamic>>{};

  void addMain(String defId, RemoteAgent a) {
    final main = usage.putIfAbsent(
        defId,
        () => {
              'main': <Map<String, String>>[],
              'scenario': <String, List<Map<String, String>>>{},
            })['main'] as List<Map<String, String>>;
    main.add({'id': a.id, 'name': a.name});
  }

  void addScenario(String defId, String modality, RemoteAgent a) {
    final scenarios = usage.putIfAbsent(
        defId,
        () => {
              'main': <Map<String, String>>[],
              'scenario': <String, List<Map<String, String>>>{},
            })['scenario'] as Map<String, List<Map<String, String>>>;
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
        final def = ModelRegistry.instance.getDefinition(toolName);
        if (def == null || !def.isDelegatable) continue;
        addScenario(def.id, 'tool_model', agent);
      }
    }
  }
  return usage;
}

/// 按 id 或 route.model（可选 apiBase 消歧）解析 ModelDefinition。
Future<({ModelDefinition? def, String? error})> resolveDefinition({
  String? id,
  String? model,
  String? apiBase,
}) async {
  final registry = ModelRegistry.instance;
  if (id != null) {
    final def = registry.getById(id);
    if (def == null) {
      return (def: null, error: 'Model definition not found: $id');
    }
    return (def: def, error: null);
  }
  if (model != null) {
    final candidates = registry.definitions
        .where((d) => d.route.model == model)
        .where((d) => apiBase == null || d.route.apiBase == apiBase)
        .toList();
    if (candidates.isEmpty) {
      return (
        def: null,
        error: 'No model definition with model "$model"'
            '${apiBase != null ? ' and api_base "$apiBase"' : ''} found. '
            'Run "shepaw models list" to see current definitions.'
      );
    }
    if (candidates.length > 1) {
      return (
        def: null,
        error: 'Multiple definitions match model "$model" — pass --api_base to '
            'disambiguate. Candidates: '
            '${candidates.map((d) => '${d.id} (${d.displayName}, ${d.route.apiBase})').join("; ")}',
      );
    }
    return (def: candidates.first, error: null);
  }
  return (
    def: null,
    error:
        'Missing --id (or --model). Usage: shepaw models <command> --id <model_id> '
        '— get ids from "shepaw models list".',
  );
}

/// 为指定 apiBase 查找可复用的 API Key（UI 同款策略）：
/// 1. 已注册定义中同 apiBase 的 Key；2. provider 级安全缓存。
Future<({String key, String source})> resolveCachedApiKey(
    String apiBase) async {
  for (final def in ModelRegistry.instance.definitions) {
    final key = def.route.apiKey ?? '';
    if (def.route.apiBase == apiBase && key.isNotEmpty) {
      return (key: key, source: 'model');
    }
  }
  try {
    final cached = await SecureKeyManager.getSecureValue(
          SecureKeyManager.providerApiKeyStorageKey(apiBase),
        ) ??
        '';
    if (cached.isNotEmpty) return (key: cached, source: 'provider_cache');
  } catch (_) {}
  return (key: '', source: 'none');
}

/// 构造脱敏后的 provider 预设描述（供 providers 命令输出）。
Map<String, dynamic> providerSummary(LLMProviderConfig p) => {
      'name': p.name,
      'provider_type': p.providerType,
      'default_api_base': p.defaultApiBase,
      'default_model': p.defaultModel,
      'requires_api_key': p.requiresApiKey,
      'icon': p.icon,
    };
