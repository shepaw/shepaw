import '../../cli_base.dart';
import 'models_cli_helpers.dart';
import '../../../services/model_registry.dart';
import '../../../services/model_usage_service.dart';

/// 删除模型定义（脱敏）。若仍被 Agent 引用则默认拒绝，需 --yes 确认。
class ModelsRemoveCommand extends CliCommand {
  @override
  String get name => 'remove';

  @override
  String get description =>
      'Remove a model definition, --id <model_id> [--yes] (refused while agents use it)';

  @override
  String get usage => 'shepaw models remove --id <model_id> [--yes]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'id': 'Model definition id (from "shepaw models list")',
      'model':
          'Alternatively resolve by route model name (see also --api_base)',
      'api_base':
          'Disambiguate when multiple definitions share the same model name',
      'yes':
          'Acknowledge removal even when agents still reference this definition',
    };
    base['note'] = 'Removing also deletes the securely-stored API key of this '
        'definition. Agents referencing it (as main/scenario model) will fall back '
        'to their legacy llm_* settings or report not-configured.';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final id = flagValue(flags, 'id');
    final model = flagValue(flags, 'model');
    final apiBase = flagValue(flags, 'api_base');
    if (id == null && model == null) {
      return {'error': 'Missing --id or --model', 'usage': usage};
    }

    final resolved =
        await resolveDefinition(id: id, model: model, apiBase: apiBase);
    if (resolved.error != null) {
      return {'error': resolved.error, 'usage': usage};
    }
    final def = resolved.def!;

    final usageByDef = await ModelUsageService.usageByModelId();
    final usedBy = usageByDef[def.id];
    final referenced = usedBy != null &&
        ((usedBy['main'] as List).isNotEmpty ||
            (usedBy['scenario'] as Map).isNotEmpty);

    final confirmed = flags.containsKey('yes') || flags['yes'] == 'true';
    if (referenced && !confirmed) {
      return {
        'error': 'Model "${def.displayName}" is still referenced by agents',
        'used_by': usedBy,
        'suggestion': 'Reassign those agents first (shepaw models agent-main '
            '--agent <agent> --model <other_id>), or confirm removal with --yes. '
            'Referencing agents fall back to legacy llm_* settings.',
      };
    }

    await ModelRegistry.instance.delete(def.id);

    final result = <String, dynamic>{
      'ok': true,
      'action': 'removed',
      'id': def.id,
      'display_name': def.displayName,
      'model': def.route.model,
      'api_base': def.route.apiBase,
    };
    if (referenced) {
      result['used_by'] = usedBy;
      result['note'] =
          'Removed anyway (--yes). Referencing agents fall back to '
          'legacy llm_* settings; reassign them if they should keep working.';
    }
    return result;
  }
}
