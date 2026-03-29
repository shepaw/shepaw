import '../../cli_base.dart';
import '../../../services/os_tool_registry.dart';
import '../../../services/skill_registry.dart';
import '../../../services/ui_component_registry.dart';
import '../../../services/model_registry.dart';

/// Returns a summary of system capabilities.
class CapabilitiesCommand extends CliCommand {
  @override
  String get name => 'capabilities';

  @override
  String get description => 'Return a summary of system capabilities';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return {
      'cli_namespaces': [
        'profile',
        'memory',
        'agents',
        'channels',
        'messages',
        'skills',
        'tools',
        'datetime',
        'system',
        'help'
      ],
      'tool_categories': {
        'ui': UIComponentRegistry.instance.components
            .where((c) => c.isToolCallable)
            .length,
        'os': OsToolRegistry.instance.tools.length,
        'skills': SkillRegistry.instance.skills.length,
        'models': ModelRegistry.instance.definitions.length,
      },
      'hint': 'Call "shepaw system tools-list" for detailed tool inventory, '
          'or "shepaw system tools-detail --name <tool-name>" for any tool\'s full docs',
    };
  }
}
