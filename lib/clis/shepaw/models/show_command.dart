import '../../cli_base.dart';
import 'models_cli_helpers.dart';

/// 查看单个模型定义的完整配置（脱敏）。
class ModelsShowCommand extends CliCommand {
  @override
  String get name => 'show';

  @override
  String get description =>
      'Show full detail of one model definition, --id <model_id> (or --model)';

  @override
  String get usage => 'shepaw models show --id <model_id>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': 'Model definition id (from "shepaw models list")',
      'model': 'Alternatively resolve by route model name (e.g. deepseek-chat)',
      'api_base':
          'Disambiguate when multiple definitions share the same model name',
    };
    base['note'] =
        'Output never contains the API key — only has_api_key. Key changes: '
        'shepaw models update --id <model_id> --api_key ...';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flagValue(flags, 'id');
    final model = flagValue(flags, 'model');
    final apiBase = flagValue(flags, 'api_base');

    if (id == null && model == null) {
      return {
        'error': 'Missing --id or --model',
        'usage': usage,
        'hint': 'Run "shepaw models list" to see current model definitions',
      };
    }

    final resolved =
        await resolveDefinition(id: id, model: model, apiBase: apiBase);
    if (resolved.error != null) {
      return {'error': resolved.error, 'usage': usage};
    }
    final def = resolved.def!;

    final detail = modelSummary(def);
    final usageByDef = await usageByModelId();
    detail['used_by'] =
        usageByDef[def.id] ?? {'main': <dynamic>[], 'scenario': <dynamic>{}};

    final next = <String>[];
    next.add(
        'Assign as main model: shepaw models agent-main --agent <agent> --model ${def.id}');
    if (!(detail['has_api_key'] as bool)) {
      next.add('This model has NO API key — calls will fail. '
          'Set it with: shepaw models update --id ${def.id} --api_key <key>');
    }
    detail['next_steps'] = next;
    return detail;
  }
}
