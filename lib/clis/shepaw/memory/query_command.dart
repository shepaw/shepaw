import '../../cli_base.dart';
import '../../../services/she_memory_db_service.dart';
import '../../../services/cognition_service.dart';
import '../../../services/she_service.dart';

/// 查询 Agent 的记忆
///
/// - She（she-builtin-agent-001）：使用 SheMemoryDbService（支持全部 key）
/// - 其他 Agent：使用 CognitionService（仅支持 soul / self_notes）
class QueryCommand extends CliCommand {
  final String agentId;

  QueryCommand({required this.agentId});

  bool get _isShe => agentId == SheService.sheId;

  @override
  String get name => 'query';

  @override
  String get description => 'Query memory, optional --keys soul,heartbeat,...';

  @override
  String get usage => 'shepaw context memory.query [--keys soul,user_info,...]';

  @override
  Map<String, dynamic> getHelp() {
    final base = super.getHelp();
    base['flags'] = {
      'keys': {
        'description': 'Comma-separated memory keys to retrieve (omit for all)',
        'required': false,
        'type': 'string',
        'example': 'soul,user_info',
        'available_keys': _isShe
            ? [
                'soul (self-awareness, replace entire entry)',
                'self_notes (personal notes)',
                'long_term_memory (long-term memory)',
                'heartbeat (last conversation summary)',
                'user_info (overall impression of the user)',
                'capabilities (capability index)',
              ]
            : [
                'soul (self-awareness)',
                'self_notes (personal notes)',
              ],
      },
    };
    return base;
  }

  @override
  Future<Map<String, dynamic>> execute(Map<String, String> flags) async {
    final Map<String, String> allMemory;

    if (_isShe) {
      allMemory = await SheMemoryDbService.instance.getAllSheMemory();
    } else {
      // 其他 Agent 仅支持 soul 和 self_notes
      final soul = await CognitionService.instance.getAgentSoul(agentId);
      final selfNotes = await CognitionService.instance.getAgentSelfNotes(agentId);
      allMemory = {
        if (soul != null) 'soul': soul,
        if (selfNotes != null) 'self_notes': selfNotes,
      };
    }

    final keysArg = flags['keys'];
    if (keysArg != null && keysArg.isNotEmpty) {
      final requested = keysArg.split(',').map((s) => s.trim()).toSet();
      final filtered = Map.fromEntries(
        allMemory.entries.where((e) => requested.contains(e.key)),
      );
      return {'memory': filtered};
    }
    return {'memory': allMemory};
  }
}
