import '../../cli_base.dart';
import '../../../services/model_registry.dart';
import '../../../services/model_usage_service.dart';
import 'models_cli_helpers.dart';

/// 列出所有已配置的模型定义。
///
/// 输出按定义汇总（脱敏，不含 API Key），并标注每个定义被哪些 Agent
/// 用作主对话模型 / 场景模型，方便判断增删改的影响面。
class ModelsListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description =>
      'List configured model definitions (no secrets) and which agents use them';

  @override
  String get usage => 'shepaw models list';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'limit': 'Max entries (default 50), --limit 20',
    };
    base['note'] =
        'API keys are never printed — each entry only exposes has_api_key. '
        'Add new models with "shepaw models add --help".';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final limit = int.tryParse(flags['limit'] ?? '') ?? 50;
    final usage = await ModelUsageService.usageByModelId();
    final defs = ModelRegistry.instance.definitions;

    final list = defs.take(limit).map((def) {
      final entry = compactModelSummary(def);
      final u = usage[def.id];
      if (u != null) {
        entry['used_by'] = u;
      } else {
        entry['used_by'] = {'main': <dynamic>[], 'scenario': <dynamic>{}};
      }
      return entry;
    }).toList();

    return {
      'models': list,
      'count': defs.length,
      'shown': list.length,
      'hint': 'Detail: shepaw models show --id <id>. '
          'Add: shepaw models add --help. '
          'Assign as an agent main model: shepaw models agent-main --help.',
    };
  }
}
