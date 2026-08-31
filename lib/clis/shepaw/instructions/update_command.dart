import '../../cli_base.dart';
import '../../../services/instruction_set_service.dart';
import 'instructions_namespace.dart';

/// `shepaw instructions update --name <name> [--new-name <name>] [--desc <text>] [--content <text>]`
///
/// 仅用户、She 或所属 agent 可操作。
class UpdateInstructionCommand extends CliCommand {
  final _service = InstructionSetService.instance;

  @override
  String get name => 'update';

  @override
  String get description =>
      'Update an instruction (only the user, She, or the owning agent)';

  @override
  String get usage =>
      'shepaw instructions update --name <name> --content <text> '
      '[--desc <text>] [--new-name <name>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name']?.trim() ?? '';
    if (name.isEmpty) {
      return {'error': 'Missing --name. Usage: $usage'};
    }
    final content = flags['content']?.trim();
    final desc = flags['desc'];
    final newName = flags['new-name']?.trim();

    if ((content == null || content.isEmpty) &&
        desc == null &&
        (newName == null || newName.isEmpty)) {
      return {
        'error': 'Nothing to update. Provide --content, --desc, or --new-name. '
            'Usage: $usage',
      };
    }

    final item = await _service.getByName(name);
    if (item == null) {
      return {'error': 'Instruction not found: $name'};
    }
    final denied = await instructionManageError(item);
    if (denied != null) return {'error': denied};

    final updated = await _service.update(
      id: item.id,
      name: newName?.isEmpty == true ? null : newName,
      description: desc,
      content: content,
    );
    return {
      'success': true,
      'id': updated.id,
      'name': updated.name,
      'owner_agent_id': updated.ownerAgentId,
      'owner_agent_name': updated.ownerAgentName,
    };
  }
}
