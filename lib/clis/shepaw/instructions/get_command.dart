import '../../cli_base.dart';
import '../../../services/instruction_set_service.dart';

/// `shepaw instructions get --name <name>`
class GetInstructionCommand extends CliCommand {
  final _service = InstructionSetService.instance;

  @override
  String get name => 'get';

  @override
  String get description => 'Get the full content of one instruction by name';

  @override
  String get usage => 'shepaw instructions get --name <name>';

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
    return {
      'success': true,
      'name': item.name,
      'description': item.description ?? '',
      'content': item.content,
      'owner_agent_id': item.ownerAgentId,
      'owner_agent_name': item.ownerAgentName,
      'created_at': item.createdAt,
      'updated_at': item.updatedAt,
    };
  }
}
