import '../../cli_base.dart';
import '../../../services/instruction_set_service.dart';

/// `shepaw instructions list [--owner <agent_id>]`
class ListInstructionsCommand extends CliCommand {
  final _service = InstructionSetService.instance;

  @override
  String get name => 'list';

  @override
  String get description =>
      'List saved instructions (optionally filter by --owner)';

  @override
  String get usage => 'shepaw instructions list [--owner <agent_id>]';

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final owner = flags['owner']?.trim();
    final list = await _service.list(ownerAgentId: owner);
    return {
      'count': list.length,
      'instructions': [
        for (final item in list)
          {
            'name': item.name,
            'description': item.description ?? '',
            'owner_agent_id': item.ownerAgentId,
            'owner_agent_name': item.ownerAgentName,
            'updated_at': item.updatedAt,
          },
      ],
    };
  }
}
