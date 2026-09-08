import '../../cli_base.dart';
import 'list_command.dart';
import 'show_command.dart';
import 'providers_command.dart';
import 'add_command.dart';
import 'update_command.dart';
import 'remove_command.dart';
import 'agent_main_command.dart';

/// models 命名空间 - AI 模型定义与配置管理
///
/// 让 She（或获得许可的 Agent）帮用户管理本地"模型注册中心"：
/// 查看服务商预设与已配模型、增删改模型定义（provider / apiBase / types /
/// apiKey）、把模型设为某 Agent 的主对话模型。
///
/// 典型场景：某服务商（如 DeepSeek）发布新模型，用户让 She 配好 ——
///   1. `shepaw models list` + `shepaw models providers` 看现状与预设；
///   2. `shepaw tools web.search` 向厂商官方文档核对精确 model id（不猜）；
///   3. `shepaw models add --provider <label> --name <model id>`（预设自动带出）；
///   4. 需要 Key 且未缓存 → `shepaw models update --id <id> --api_key <key>`；
///   5. 用户要切换 → `shepaw models agent-main --agent <agent> --model <id>`。
class ModelsNamespace extends CliNamespace {
  static final instance = ModelsNamespace._();
  ModelsNamespace._();

  @override
  String get namespace => 'models';

  @override
  String get description =>
      'AI model definitions — list/providers/add/update/remove/agent-main';

  @override
  String get usage => 'shepaw models <command> [flags]';

  @override
  Map<String, CliCommand> get commands => {
        'list': ModelsListCommand(),
        'show': ModelsShowCommand(),
        'providers': ModelsProvidersCommand(),
        'add': ModelsAddCommand(),
        'update': ModelsUpdateCommand(),
        'remove': ModelsRemoveCommand(),
        'agent-main': ModelsAgentMainCommand(),
      };

  @override
  Future<Map<String, dynamic>> getHelpAsync() async {
    final base = await super.getHelpAsync();
    base['what_she_needs_to_know'] = [
      'A "model" here is a ModelDefinition: display_name + route (provider type, '
          'exact model id, api base, optional api key, capability types). Agents '
          'reference it by id (main_model_id / scenario_models).',
      'Always check current state first: "shepaw models list" (ids + who uses them) '
          'and "shepaw models providers" (preset api bases / key policy). Never assume '
          'a model exists or that a release is configured.',
      'There is no remote model directory: to add a brand-new release, verify the '
          'exact model id from the provider official docs via '
          '"shepaw tools web.search", then add it manually with '
          '"shepaw models add --provider <label> --name <model id>".',
      'API keys are stored securely and are never printed back — outputs expose '
          'only has_api_key. A key cached for the same api_base is reused '
          'automatically when adding a model.',
      'Adding a model does not switch anyone to it. To "use" it, assign it to an '
          'agent with "shepaw models agent-main --agent <agent> --model <id>" '
          '(takes effect from that agent\'s next message).',
      'Confirm with the user before changing/removing a model that is in use — '
          '"shepaw models list"/"show" reports which agents reference a definition.',
    ];
    base['rules'] = [
      'Never echo an API key or include it in summaries — JSON outputs are sanitized.',
      'Removing a model also deletes its stored key; removing one still used by '
          'agents is refused unless --yes.',
    ];
    base['workflow_deepseek_example'] = [
      'shepaw tools web.search --query "DeepSeek API model list site:api-docs.deepseek.com" '
          '(confirm the exact model id)',
      'shepaw models add --provider DeepSeek --name <model id> --types text',
      'shepaw models update --id <id> --api_key <key>   (only when key missing)',
      'shepaw models agent-main --agent She --model <id>   (if the user wants to switch)',
    ];
    return base;
  }
}
