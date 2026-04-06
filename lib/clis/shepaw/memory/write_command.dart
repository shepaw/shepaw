import '../../cli_base.dart';
import '../../../services/she_service.dart';
import '../../../services/she_memory_db_service.dart';
import '../../../services/cognition_service.dart';

/// 写入 Agent 的记忆（覆盖）
///
/// - She（she-builtin-agent-001）：使用 SheMemoryDbService（支持全部 key）
/// - 其他 Agent：使用 CognitionService（仅支持 soul / self_notes）
class WriteCommand extends CliCommand {
  final String agentId;

  WriteCommand({required this.agentId});

  bool get _isShe => agentId == SheService.sheId;

  @override
  String get name => 'write';

  @override
  String get description => 'Write memory, --key <key> --value <val>';

  @override
  String get usage => 'shepaw context memory.write --key <key> --value "..."';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'key': {
        'description': 'Memory key to write (replaces existing value)',
        'required': true,
        'type': 'string',
        'available_keys': _isShe
            ? [
                'soul (self-awareness — use write to replace entire entry)',
                'heartbeat (last conversation summary)',
                'user_info (overall impression of the user)',
                'capabilities (capability index)',
                'self_notes (prefer append command for incremental updates)',
                'long_term_memory (prefer append command for incremental updates)',
              ]
            : [
                'soul (self-awareness)',
                'self_notes (personal notes)',
              ],
      },
      'value': {
        'description': 'Value to set (replaces existing content)',
        'required': true,
        'type': 'string',
      },
    };
    base['note'] = 'For incremental updates to self_notes or long_term_memory, use the append command instead';
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final key = flags['key'];
    final value = flags['value'];
    if (key == null || key.isEmpty) {
      return {'error': 'Missing --key. Usage: shepaw memory write --key soul --value "..."'};
    }
    if (value == null) {
      return {'error': 'Missing --value parameter'};
    }

    if (_isShe) {
      // She 使用专用路径
      if (key == 'soul') {
        await SheService.instance.updateSoul(value);
      } else {
        await SheMemoryDbService.instance.setSheMemory(key, value);
      }
    } else {
      // 其他 Agent 使用 CognitionService
      switch (key) {
        case 'soul':
          await CognitionService.instance.updateAgentSoul(agentId, value);
        case 'self_notes':
          await CognitionService.instance.updateAgentSelfNotes(agentId, value);
        default:
          return {
            'error': 'Key "$key" is not supported for this agent. Supported keys: soul, self_notes',
          };
      }
    }

    return {'ok': true, 'key': key};
  }
}
