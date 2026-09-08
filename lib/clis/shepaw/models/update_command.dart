import '../../cli_base.dart';
import '../../../models/model_definition.dart';
import '../../../models/model_routing_config.dart';
import '../../../services/model_registry.dart';
import 'models_cli_helpers.dart';

/// 更新已有模型定义（display_name / model / api_base / provider / types /
/// stream / api_key 等）。任何输出都脱敏。
class ModelsUpdateCommand extends CliCommand {
  @override
  String get name => 'update';

  @override
  String get description =>
      'Update a model definition, --id <model_id> [fields...] (secrets never echoed)';

  @override
  String get usage =>
      'shepaw models update --id <model_id> --display_name "..." [--types text,image]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': 'Model definition id (from "shepaw models list") — required',
      'display_name': 'New display name',
      'description': 'New description (use --clear_description to remove)',
      'model': 'New route model id (exact string the provider expects)',
      'api_base': 'New API base URL',
      'provider':
          'New provider preset label/type — sets the provider type field only (api_base is untouched unless --api_base is passed)',
      'types': 'Comma-separated capability types, e.g. text,imageUnderstanding',
      'stream': 'true / false',
      'api_path': 'Custom endpoint path (--clear_api_path to remove)',
      'request_body_template':
          'JSON template with \$model / \$prompt (--clear_request_body_template to remove)',
      'response_body_path':
          'Response JSON path (--clear_response_body_path to remove)',
      'api_key': 'Set / replace the API key (stored securely, never echoed)',
      'clear_api_key': 'Remove the stored API key (no value needed)',
    };
    base['examples'] = [
      'shepaw models update --id <model_id> --api_key sk-xxx',
      'shepaw models update --id <model_id> --display_name "DeepSeek R1" --types text',
      'shepaw models update --id <model_id> --api_base https://api.deepseek.com/v1 --model deepseek-chat',
    ];
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flagValue(flags, 'id');
    if (id == null) {
      return {
        'error': 'Missing --id',
        'usage': usage,
        'hint': 'Run "shepaw models list" to see ids',
      };
    }

    final resolved = await resolveDefinition(id: id);
    if (resolved.error != null) {
      return {'error': resolved.error, 'usage': usage};
    }
    final def = resolved.def!;
    final oldRoute = def.route;

    var displayName = def.displayName;
    var description = def.description;
    var providerType = oldRoute.provider;
    var model = oldRoute.model;
    var apiBase = oldRoute.apiBase;
    var stream = oldRoute.stream;
    var apiPath = oldRoute.apiPath;
    var requestBodyTemplate = oldRoute.requestBodyTemplate;
    var responseBodyPath = oldRoute.responseBodyPath;
    var apiKey = oldRoute.apiKey;
    var modelTypes = Set<ModelType>.from(def.modelTypes);

    var changed = false;
    final changes = <String>[];

    // display_name
    final dn = flagValue(flags, 'display_name');
    if (dn != null && dn != displayName) {
      displayName = dn;
      changed = true;
      changes.add('display_name');
    }
    // description
    if (flags.containsKey('clear_description')) {
      description = '';
      changed = true;
      changes.add('description');
    } else {
      final d = flagValue(flags, 'description');
      if (d != null && d != description) {
        description = d;
        changed = true;
        changes.add('description');
      }
    }
    // model / api_base
    final m = flagValue(flags, 'model');
    if (m != null && m != model) {
      model = m;
      changed = true;
      changes.add('model');
    }
    final ab = flagValue(flags, 'api_base');
    if (ab != null && ab != apiBase) {
      apiBase = ab;
      changed = true;
      changes.add('api_base');
    }
    // provider（只改类型字段，不擅自改 apiBase）
    final p = flagValue(flags, 'provider');
    if (p != null) {
      final preset = resolveProvider(p);
      final nextProvider =
          preset != null ? preset.providerType : p.toLowerCase();
      if (nextProvider != providerType) {
        providerType = nextProvider;
        changed = true;
        changes.add('provider');
      }
    }
    // types
    final t = flagValue(flags, 'types');
    if (t != null) {
      final parsed = parseModelTypes(t);
      if (parsed.error != null) return {'error': parsed.error, 'usage': usage};
      modelTypes = parsed.types;
      changed = true;
      changes.add('types');
    }
    // stream
    final s = flagValue(flags, 'stream');
    if (s != null) {
      final parsed = parseBoolFlag(s, '--stream');
      if (parsed.error != null) return {'error': parsed.error, 'usage': usage};
      final nextStream = parsed.value;
      if (nextStream != null && nextStream != (stream ?? true)) {
        stream = nextStream;
        changed = true;
        changes.add('stream');
      }
    }
    // optional route strings
    final ap = flagValue(flags, 'api_path');
    if (flags.containsKey('clear_api_path')) {
      if (apiPath != null) {
        apiPath = null;
        changed = true;
        changes.add('api_path');
      }
    } else if (ap != null && ap != apiPath) {
      apiPath = ap;
      changed = true;
      changes.add('api_path');
    }
    final rbt = flagValue(flags, 'request_body_template');
    if (flags.containsKey('clear_request_body_template')) {
      if (requestBodyTemplate != null) {
        requestBodyTemplate = null;
        changed = true;
        changes.add('request_body_template');
      }
    } else if (rbt != null && rbt != requestBodyTemplate) {
      requestBodyTemplate = rbt;
      changed = true;
      changes.add('request_body_template');
    }
    final rb = flagValue(flags, 'response_body_path');
    if (flags.containsKey('clear_response_body_path')) {
      if (responseBodyPath != null) {
        responseBodyPath = null;
        changed = true;
        changes.add('response_body_path');
      }
    } else if (rb != null && rb != responseBodyPath) {
      responseBodyPath = rb;
      changed = true;
      changes.add('response_body_path');
    }
    // api key
    if (flags.containsKey('clear_api_key')) {
      if (apiKey != null && apiKey.isNotEmpty) {
        apiKey = null;
        changed = true;
        changes.add('api_key');
      }
    } else {
      final k = flagValue(flags, 'api_key');
      if (k != null) {
        if (k != apiKey) {
          apiKey = k;
          changed = true;
          changes.add('api_key');
        }
      }
    }

    if (!changed) {
      return {
        'error': 'Nothing to update — pass at least one field',
        'usage': usage,
      };
    }

    if (displayName.trim().isEmpty) {
      return {'error': 'display_name cannot be empty'};
    }
    if ((model ?? '').isEmpty || (apiBase ?? '').isEmpty) {
      return {
        'error': 'model and api_base cannot be empty — restore them or delete '
            'and re-add this definition'
      };
    }

    // 改 apiBase 时若换了厂商，Key 仍随定义保留（同一 id），仅提示核对。
    final baseChanged = oldRoute.apiBase != apiBase;

    final route = ModelRouteConfig(
      provider: providerType,
      model: model,
      apiBase: apiBase,
      apiKey: apiKey,
      stream: stream == false ? false : null,
      apiPath: apiPath,
      requestBodyTemplate: requestBodyTemplate,
      responseBodyPath: responseBodyPath,
    );

    final updated = def.copyWith(
      displayName: displayName,
      description: description,
      route: route,
      modelTypes: modelTypes,
    );
    await ModelRegistry.instance.update(updated);

    final summary = modelSummary(updated);
    final result = <String, dynamic>{
      'ok': true,
      'action': 'updated',
      'changes': changes,
      'model': summary,
    };
    final notes = <String>[];
    if (baseChanged && (apiKey?.isNotEmpty ?? false)) {
      notes.add(
          'api_base changed while an API key was set — verify the key still '
          'belongs to the new endpoint (shepaw models show --id $id).');
    }
    if (!(summary['has_api_key'] as bool)) {
      final preset = resolveProvider(providerType ?? '') ??
          providerForApiBase(apiBase ?? '');
      if (preset?.requiresApiKey ?? true) {
        notes.add('This definition has no API key — set one with: '
            'shepaw models update --id $id --api_key <key>');
      }
    }
    if (notes.isNotEmpty) result['notes'] = notes;
    return result;
  }
}
