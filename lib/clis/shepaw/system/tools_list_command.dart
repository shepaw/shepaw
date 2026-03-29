import '../../cli_base.dart';
import '../../../services/os_tool_registry.dart';
import '../../../services/skill_registry.dart';
import '../../../services/ui_component_registry.dart';
import '../../../services/model_registry.dart';

/// Lists all available tools grouped by category.
class ToolsListCommand extends CliCommand {
  @override
  String get name => 'tools-list';

  @override
  String get description => 'List all available tools (UI, OS, skills, models)';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {},
        'usage': 'shepaw meta system.tools-list',
        'note': 'Use "shepaw meta system.tools-detail --name <tool>" for full docs of a specific tool',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return {
      'ui_components': UIComponentRegistry.instance.components
          .where((c) => c.isToolCallable)
          .map((c) => {'name': c.name, 'description': c.description})
          .toList(),
      'os_tools': OsToolRegistry.instance.tools
          .map((t) => {'name': t.name, 'description': t.description})
          .toList(),
      'skills': SkillRegistry.instance.skills
          .map((s) => {'name': s.toolName, 'description': s.description})
          .toList(),
      'model_tools': ModelRegistry.instance.definitions
          .map((m) => {
                'name': m.toolName,
                'description': m.description,
                'types': m.modelTypes.map((t) => t.name).toList(),
              })
          .toList(),
    };
  }
}
