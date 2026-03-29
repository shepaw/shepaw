import '../../cli_base.dart';
import '../../../services/skill_registry.dart';

/// 列出所有已加载的技能
class SkillsListCommand extends CliCommand {
  @override
  String get name => 'list';

  @override
  String get description => 'List all loaded LLM skill modules';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final skills = SkillRegistry.instance.skills;
    final list = skills
        .map((s) => {
              'tool_name': s.toolName,
              'display_name': s.displayName,
              'description': s.description,
            })
        .toList();
    return {'skills': list, 'count': list.length};
  }
}
