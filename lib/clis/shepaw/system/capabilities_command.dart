import '../../cli_base.dart';
import '../os/os_tool_registry.dart';
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
  String get usage => 'shepaw meta system.capabilities';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    return {
      'cli_namespaces': [
        'context (profile.* / memory.* / agents.*)',
        'chat (channels / messages)',
        'tools (list / detail / categories)',
        'skills (list / detail)',
        'meta (datetime / system.*)',
        'help',
      ],
      'tool_categories': {
        'ui': UIComponentRegistry.instance.components
            .where((c) => c.isToolCallable)
            .length,
        'os': OsToolRegistry.instance.tools.length,
        'skills': SkillRegistry.instance.skills.length,
        'models': ModelRegistry.instance.definitions.length,
      },
      'hint': 'Call "shepaw meta system.tools-list" for detailed tool inventory, '
          'or "shepaw meta system.tools-detail --name <tool-name>" for any tool\'s full docs',
    };
  }
}
