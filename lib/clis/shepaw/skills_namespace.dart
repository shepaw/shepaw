import '../cli_base.dart';
import 'skills/list_command.dart';
import 'skills/detail_command.dart';

/// [TOOLING 层] skills 命名空间 - 已加载的 LLM 技能库
///
/// 管理用户通过 ~/shepaw/skills/ 导入的技能模块（SKILL.md 格式）。
/// 与 `tools` 命名空间的区别：
///   - skills = LLM 可直接调用的技能模块（如 PDF 提取、数学求解）
///   - tools  = 本地系统执行能力（如文件读写、进程管理）
///
/// Subcommands:
/// - `list`   列出所有已加载的技能
/// - `detail` 获取单个技能的完整文档（--name 参数）
class SkillsNamespace extends CliNamespace {
  static final instance = SkillsNamespace._();
  SkillsNamespace._();

  @override
  String get namespace => 'skills';

  @override
  String get description => 'Loaded LLM skill modules';

  @override
  Map<String, CliCommand> get commands => {
        'list': SkillsListCommand(),
        'detail': SkillsDetailCommand(),
      };

  @override
  Map<String, dynamic> getHelp() => {
        'namespace': namespace,
        'description': description,
        'subcommands': {
          'list': 'List all loaded skills',
          'detail': 'Get full documentation for a skill (--name <skill_name>)',
        },
        'examples': [
          'shepaw skills list',
          'shepaw skills detail --name extract_pdf',
        ],
      };
}
