import '../../cli_base.dart';
import '../../../services/instruction_set_service.dart';
import 'instructions_namespace.dart';

/// `shepaw instructions delete --name <name>`
///
/// 仅用户、She 或所属 agent 可操作。
class DeleteInstructionCommand extends CliCommand {
  final _service = InstructionSetService.instance;

  @override
  String get name => 'delete';

  @override
  String get description =>
      'Delete an instruction (only the user, She, or the owning agent)';

  @override
  String get usage => 'shepaw instructions delete --name <name>';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final name = flags['name']?.trim() ?? '';
    if (name.isEmpty) {
      return {'error': 'Missing --name. Usage: $usage'};
    }
    final item = await _service.getByName(name);
    if (item == null) {
      return {'error': 'Instruction not found: $name'};
    }
    final denied = await instructionManageError(item);
    if (denied != null) return {'error': denied};

    await _service.delete(item.id);
    return {'success': true, 'deleted': item.name};
  }
}
