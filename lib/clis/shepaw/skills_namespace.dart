import '../cli_base.dart';
import '../../services/skill_registry.dart';

/// skills 命名空间 - 列出已加载的技能
class SkillsNamespace extends CliNamespace {
  static final instance = SkillsNamespace._();
  SkillsNamespace._();

  @override
  String get namespace => 'skills';

  @override
  String get description => 'Loaded skills';

  @override
  Map<String, CliCommand> get commands => {};

  /// skills 没有子命令，直接执行
  @override
  Future<Map<String, dynamic>> execute(String subcommand, Map<String, String> flags) async {
    final skills = SkillRegistry.instance.skills;
    final list = skills.map((s) => {
          'tool_name': s.toolName,
          'display_name': s.displayName,
          'description': s.description,
        }).toList();
    return {'skills': list, 'count': list.length};
  }

  @override
  Map<String, dynamic> getHelp() => {
    'namespace': namespace,
    'description': description,
    'subcommands': {'list': 'List all loaded skills'},
    'examples': ['shepaw skills'],
  };
}
