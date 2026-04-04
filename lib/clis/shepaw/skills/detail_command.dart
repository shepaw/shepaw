import 'dart:io';
import '../../cli_base.dart';
import '../../../services/skill_registry.dart';

/// 获取单个技能的完整文档
class SkillsDetailCommand extends CliCommand {
  @override
  String get name => 'detail';

  @override
  String get description => 'Get full documentation for a specific skill';

  @override
  String get usage => 'shepaw skills detail --name <skill_name>';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'name': {
        'description': 'Skill tool_name or display_name to get documentation for',
        'required': true,
        'type': 'string',
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name'];
    if (name == null || name.isEmpty) {
      return {
        'error': 'Missing required flag: --name',
        'usage': 'shepaw skills detail --name <skill_name>',
      };
    }

    final skills = SkillRegistry.instance.skills;
    final skill = skills.where((s) => s.toolName == name || s.displayName == name).firstOrNull;

    if (skill == null) {
      return {
        'error': 'Skill not found: $name',
        'available': skills.map((s) => s.toolName).toList(),
      };
    }

    // 读取 SKILL.md 的完整内容
    String? content;
    try {
      content = await File(skill.filePath).readAsString();
    } catch (_) {
      content = null;
    }

    return {
      'tool_name': skill.toolName,
      'display_name': skill.displayName,
      'description': skill.description,
      'file_path': skill.filePath,
      'directory_path': skill.directoryPath,
      'file_count': skill.fileCount,
      if (content != null) 'content': content,
    };
  }
}
