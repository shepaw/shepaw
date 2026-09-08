import '../../cli_base.dart';
import '../../../models/model_definition.dart';
import '../../../models/model_routing_config.dart';
import '../../../services/model_registry.dart';
import 'models_cli_helpers.dart';

/// 新增模型定义 —— She 帮用户配置新模型（如某服务商发布新版模型）的主命令。
///
/// 手动配置：`--name <model id> --provider <label|type>`（自动带出预设 apiBase、
/// 协议类型与 Key 策略）。新模型的 model id 需从厂商官方文档核对（web.search）
/// ——本机不维护/不依赖远端模型目录。
class ModelsAddCommand extends CliCommand {
  @override
  String get name => 'add';

  @override
  String get description =>
      'Add a model definition, --name <model id> [--provider <label>] [fields...]';

  @override
  String get usage =>
      'shepaw models add --provider DeepSeek --name deepseek-chat [--display_name ...] [--types text] [--api_key ...]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'name': 'Exact model id the provider API expects (e.g. deepseek-chat). Required',
      'display_name': 'Human-readable name (defaults to --name)',
      'provider': 'Built-in provider label or type (e.g. DeepSeek, openai) — fills api base & key policy',
      'api_base': 'Override API base URL (defaults to the provider preset)',
      'description': 'Short description (also shown to the LLM when used as a tool model)',
      'types': 'Comma-separated capability types (default text): text,imageUnderstanding,audioUnderstanding,videoUnderstanding,imageGeneration,tts,videoGeneration',
      'stream': 'Whether to stream responses (default true)',
      'api_path': 'Custom endpoint path (defaults to /chat/completions)',
      'request_body_template': 'Optional JSON template using \$model / \$prompt placeholders',
      'response_body_path': 'Optional dot-bracket JSON path for non-standard responses (e.g. data[0].url)',
      'api_key': 'API key. Never printed back. When omitted, the key cached for the same api_base is reused; if none and the provider requires one, the model is added but marked needs_api_key',
    };
    base['examples'] = [
      'shepaw models add --provider DeepSeek --name deepseek-chat --types text',
      'shepaw models add --provider DeepSeek --name deepseek-r1 --display_name "DeepSeek R1" --types text --api_key sk-xxx',
    ];
    base['note'] = 'Before adding a just-released model, verify the exact model id '
        'against the provider official docs ("shepaw tools web.search") — never guess. '
        'Duplicate (same model id + api base) is rejected — update the existing one '
        'with "shepaw models update" instead. After adding, assign it to an agent with '
        '"shepaw models agent-main".';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final nameFlag = flagValue(flags, 'name');
    if (nameFlag == null) {
      return {
        'error': 'Missing --name (model id)',
        'usage': usage,
        'example':
            'shepaw models add --provider DeepSeek --name deepseek-chat --types text',
      };
    }
    final model = nameFlag;
    final displayName = flagValue(flags, 'display_name') ?? model;
    final description = flagValue(flags, 'description') ?? '';

    // ── 服务商预设 → 协议类型 / apiBase / Key 策略 ─────────────────────────
    final providerLabel = flagValue(flags, 'provider');
    final preset = providerLabel != null ? resolveProvider(providerLabel) : null;
    final String providerType;
    final bool requiresApiKey;
    if (preset != null) {
      providerType = preset.providerType;
      requiresApiKey = preset.requiresApiKey;
    } else {
      providerType = providerLabel?.toLowerCase() ?? 'openai';
      requiresApiKey = true;
    }

    final apiBaseFlag = flagValue(flags, 'api_base');
    if (apiBaseFlag == null && preset == null) {
      return {
        'error': 'Missing --api_base (no built-in provider preset matched '
            '--provider "$providerLabel")',
        'suggestion': 'Pass --api_base, or use a preset label from '
            '"shepaw models providers"',
      };
    }
    final apiBase = apiBaseFlag ?? preset!.defaultApiBase;

    // ── 能力类型 ────────────────────────────────────────────────────────────
    final rawTypes = flagValue(flags, 'types');
    Set<ModelType> types;
    if (rawTypes != null) {
      final parsed = parseModelTypes(rawTypes);
      if (parsed.error != null) {
        return {'error': parsed.error, 'usage': usage};
      }
      types = parsed.types.isNotEmpty ? parsed.types : {ModelType.text};
    } else {
      types = {ModelType.text};
    }

    final parsedStream = parseBoolFlag(flagValue(flags, 'stream'), '--stream');
    if (parsedStream.error != null) {
      return {'error': parsedStream.error, 'usage': usage};
    }
    final stream = parsedStream.value ?? true;

    final apiPath = flagValue(flags, 'api_path');
    final requestBodyTemplate = flagValue(flags, 'request_body_template');
    final responseBodyPath = flagValue(flags, 'response_body_path');

    // ── 去重：同 model id + 同 apiBase 已存在 → 引导 update ───────────────
    final duplicate = ModelRegistry.instance.definitions
        .where((d) => d.route.model == model && d.route.apiBase == apiBase)
        .firstOrNull;
    if (duplicate != null) {
      return {
        'error': 'Model already configured: ${duplicate.displayName} '
            '(id ${duplicate.id}, ${duplicate.route.apiBase})',
        'suggestion':
            'Update it instead: shepaw models update --id ${duplicate.id} --help',
      };
    }

    // ── API Key（安全：只进不出；同 apiBase 缓存自动复用，与 UI 一致）─────
    final keyProvided = flagValue(flags, 'api_key');
    var key = keyProvided ?? '';
    var keySource = keyProvided != null ? 'provided' : 'none';
    if (key.isEmpty && requiresApiKey) {
      final cached = await resolveCachedApiKey(apiBase);
      if (cached.key.isNotEmpty) {
        key = cached.key;
        keySource = cached.source == 'model'
            ? 'reused_from_existing_definition'
            : 'reused_from_provider_cache';
      }
    }
    if (!requiresApiKey) keySource = 'not_required';

    // ── 写入注册中心 ────────────────────────────────────────────────────────
    final route = ModelRouteConfig(
      provider: providerType,
      model: model,
      apiBase: apiBase,
      apiKey: key.isEmpty ? null : key,
      stream: stream ? null : false,
      apiPath: apiPath,
      requestBodyTemplate: requestBodyTemplate,
      responseBodyPath: responseBodyPath,
    );

    final def = await ModelRegistry.instance.add(
      displayName: displayName,
      description: description,
      route: route,
      modelTypes: types,
    );

    final needsKey = requiresApiKey && key.isEmpty;
    final result = <String, dynamic>{
      'ok': true,
      'action': 'added',
      'id': def.id,
      'model': modelSummary(def),
      'requires_api_key': requiresApiKey,
      'api_key_source': keySource,
      'needs_api_key': needsKey,
    };
    final notes = <String>[];
    if (needsKey) {
      notes.add(
          'No API key yet (required by this provider) — set one with: '
          'shepaw models update --id ${def.id} --api_key <key>');
    }
    notes.add('To make an agent actually use it: shepaw models agent-main '
        '--agent <agent> --model ${def.id}');
    result['notes'] = notes;
    return result;
  }
}
