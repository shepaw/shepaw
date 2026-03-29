import '../../cli_base.dart';
import '../../../services/os_tool_registry.dart';
import '../../../services/skill_registry.dart';
import '../../../services/ui_component_registry.dart';
import '../../../services/model_registry.dart';

/// Returns full parameter documentation for a specific tool.
class ToolsDetailCommand extends CliCommand {
  @override
  String get name => 'tools-detail';

  @override
  String get description =>
      'Get full parameter documentation for a specific tool (pass --name <tool-name>)';

  @override
  Map<String, dynamic> getHelp() => {
        'command': name,
        'description': description,
        'flags': {
          'name': {
            'description': 'Tool name to get full parameter documentation for',
            'required': true,
            'type': 'string',
          },
        },
        'usage': 'shepaw meta system.tools-detail --name <tool-name>',
        'note': 'Use "shepaw meta system.tools-list" to see all available tools',
      };

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final toolName = flags['name'] ?? '';
    if (toolName.isEmpty) {
      return {
        'error': 'Missing --name flag',
        'usage': 'shepaw system tools-detail --name <tool-name>',
      };
    }

    // Try to find the tool in each registry
    return _findToolDetails(toolName) ??
        {
          'error': 'Tool not found: $toolName',
          'hint': 'Call "shepaw system tools-list" to see all available tools',
        };
  }

  Map<String, dynamic>? _findToolDetails(String toolName) {
    // Check UI components
    for (final c in UIComponentRegistry.instance.components) {
      if (c.name == toolName) {
        return {
          'type': 'ui_component',
          'name': c.name,
          'description': c.description,
        };
      }
    }

    // Check OS tools
    for (final t in OsToolRegistry.instance.tools) {
      if (t.name == toolName) {
        return {
          'type': 'os_tool',
          'name': t.name,
          'description': t.description,
          'category': t.category,
          'supported_platforms': t.supportedPlatforms.toList(),
        };
      }
    }

    // Check skills
    for (final s in SkillRegistry.instance.skills) {
      if (s.toolName == toolName) {
        return {
          'type': 'skill',
          'name': s.toolName,
          'display_name': s.displayName,
          'description': s.description,
        };
      }
    }

    // Check model tools
    for (final m in ModelRegistry.instance.definitions) {
      if (m.toolName == toolName) {
        return {
          'type': 'model_tool',
          'name': m.toolName,
          'display_name': m.displayName,
          'description': m.description,
          'model_types': m.modelTypes.map((t) => t.name).toList(),
        };
      }
    }

    return null;
  }
}
